import Foundation
import Observation

/// Which screen the popover shows.
nonisolated enum Route: Hashable, Sendable {
    case list
    case thread(String)
    case settings
}

/// The app's state and everything it can do. Views read it and call it;
/// nothing else talks to the daemon.
@Observable
final class AppModel {
    let settings: Settings
    private(set) var inbox = Inbox()
    var route: Route = .list
    /// Whether the popover is on screen. Reading a conversation only counts
    /// while it is.
    var popoverVisible = false {
        didSet { if popoverVisible { markOpenThreadRead() } }
    }
    /// Why the daemon can't be reached, when it can't.
    private(set) var daemonError: String?
    /// Threads whose history is being fetched.
    private(set) var loading: Set<String> = []
    private(set) var loginInProgress = false
    /// A failed action, in words, shown briefly.
    var toast: String?

    /// Called when a new message should be announced.
    var notify: ((ChatThread, Message) -> Void)?
    /// Called when the menu bar count may have changed.
    var onChange: (() -> Void)?

    private let daemon = Daemon()
    private var client: Client?
    private var runner: Task<Void, Never>?
    private var lastTypingSent: [String: Date] = [:]

    init(settings: Settings = Settings()) {
        self.settings = settings
        inbox.seenMs = settings.seenMs
    }

    // MARK: Lifecycle

    /// Starts the daemon and follows its events until `stop`. If the daemon
    /// or the stream dies, it starts again after a pause.
    func start() {
        guard runner == nil else { return }
        daemon.onExit = { [weak self] in self?.restart() }
        runner = Task { [weak self] in
            var delay = 1.0
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    let endpoint = try await self.daemon.start()
                    let client = Client(base: endpoint.base, token: endpoint.token)
                    self.client = client
                    self.daemonError = nil
                    for try await event in client.events() {
                        delay = 1
                        self.handle(event)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    if Task.isCancelled { return }
                    self.daemonError = error.localizedDescription
                }
                self.client = nil
                self.inbox.apply(.status(.connecting, error: ""))
                self.onChange?()
                try? await Task.sleep(for: .seconds(delay))
                delay = min(delay * 2, 30)
            }
        }
    }

    func stop() {
        runner?.cancel()
        runner = nil
        daemon.stop()
    }

    private func restart() {
        runner?.cancel()
        runner = nil
        client = nil
        start()
    }

    private func handle(_ event: ServerEvent) {
        if case .messageAdded(let m) = event, settings.notifications, inbox.shouldNotify(m),
           let thread = inbox.thread(m.threadId), !(popoverVisible && route == .thread(m.threadId)) {
            notify?(thread, m)
        }
        inbox.apply(event)
        if case .state = event {
            // A fresh inbox: what was loaded for the open thread may have gaps.
            if case .thread(let id) = route {
                if inbox.thread(id) == nil { route = .list } else { Task { await loadNewest(id) } }
            }
            if inbox.connection == .loggedOut || inbox.connection == .loginRequired, route != .settings {
                route = .list
            }
        }
        markOpenThreadRead()
        onChange?()
    }

    // MARK: Reading

    func open(_ thread: String) {
        route = .thread(thread)
        if inbox.messages[thread] == nil { Task { await loadNewest(thread) } }
        markOpenThreadRead()
    }

    private func loadNewest(_ thread: String) async {
        await load(thread, before: nil)
        markOpenThreadRead()
    }

    func loadOlder(_ thread: String) async {
        guard inbox.hasOlder[thread] == true, let first = inbox.messages[thread]?.first else { return }
        await load(thread, before: first.id)
    }

    private func load(_ thread: String, before: String?) async {
        guard let client, !loading.contains(thread) else { return }
        loading.insert(thread)
        defer { loading.remove(thread) }
        do {
            let page = try await client.history(thread: thread, before: before)
            inbox.load(page.messages, more: page.more, thread: thread, before: before)
        } catch {
            toast = "Couldn't load messages: \(error.localizedDescription)"
        }
    }

    /// Marks the open conversation read, if it is on screen and has
    /// something unread: on Instagram when read receipts are on, otherwise
    /// only here.
    private func markOpenThreadRead() {
        guard popoverVisible, case .thread(let id) = route, let thread = inbox.thread(id),
              inbox.isUnread(thread), let newest = thread.lastMessage else { return }
        markRead(thread: id, newest: newest)
    }

    private func markRead(thread: String, newest: Message) {
        // Hidden here at once, either way.
        inbox.seenMs[thread] = max(inbox.seenMs[thread] ?? 0, newest.atMs)
        settings.seenMs = inbox.seenMs
        onChange?()
        guard settings.readReceipts, let client else { return }
        Task {
            try? await client.markRead(thread: thread, messageId: newest.id, atMs: newest.atMs)
        }
    }

    // MARK: Writing

    /// Sends text to a thread. It shows at once as pending and is replaced
    /// by Instagram's copy when that arrives.
    func send(_ text: String, to thread: String, replyTo: Message? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let quote = replyTo.map { Quote(id: $0.id, senderId: $0.senderId, text: $0.text, contentType: $0.contentType) }
        let p = Pending(id: UUID(), threadId: thread, text: trimmed, replyTo: quote, createdAt: .now)
        inbox.pending.append(p)
        lastTypingSent[thread] = nil
        deliver(p.id)
    }

    func retry(_ id: UUID) {
        guard let i = inbox.pending.firstIndex(where: { $0.id == id }) else { return }
        inbox.pending[i].failed = false
        deliver(id)
    }

    func discard(_ id: UUID) {
        inbox.pending.removeAll { $0.id == id }
    }

    private func deliver(_ id: UUID) {
        guard let p = inbox.pending.first(where: { $0.id == id }) else { return }
        guard let client else {
            fail(id)
            return
        }
        Task {
            do {
                let otid = try await client.send(thread: p.threadId, text: p.text, otid: p.otid, replyTo: p.replyTo?.id)
                // The echo may have come first and removed it already.
                if let i = inbox.pending.firstIndex(where: { $0.id == id }) {
                    let echoed = inbox.messages[p.threadId]?.contains { $0.otid == otid } ?? false
                    if echoed { inbox.pending.remove(at: i) } else { inbox.pending[i].otid = otid }
                }
            } catch {
                fail(id)
                toast = "Not sent: \(error.localizedDescription)"
            }
        }
    }

    private func fail(_ id: UUID) {
        if let i = inbox.pending.firstIndex(where: { $0.id == id }) { inbox.pending[i].failed = true }
    }

    /// Tells the other side the user is typing, at most every few seconds,
    /// or that they stopped.
    func typing(in thread: String, active: Bool) {
        guard settings.sendTyping, let client else { return }
        if active {
            if let last = lastTypingSent[thread], Date.now.timeIntervalSince(last) < 4 { return }
            lastTypingSent[thread] = .now
        } else {
            guard lastTypingSent[thread] != nil else { return }
            lastTypingSent[thread] = nil
        }
        Task { try? await client.typing(thread: thread, active: active) }
    }

    /// A reply typed into a notification.
    func reply(_ text: String, to thread: String) {
        send(text, to: thread)
        if settings.readReceipts, let t = inbox.thread(thread), let newest = t.lastMessage {
            markRead(thread: thread, newest: newest)
        }
    }

    // MARK: Account

    func login(cookies: [String: String]) async -> String? {
        guard let client else { return "dmbar's backend isn't running." }
        loginInProgress = true
        defer { loginInProgress = false }
        do {
            try await client.login(cookies: cookies)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func logout() {
        guard let client else { return }
        Task {
            do { try await client.logout() } catch { toast = "Couldn't log out: \(error.localizedDescription)" }
        }
        route = .list
    }
}
