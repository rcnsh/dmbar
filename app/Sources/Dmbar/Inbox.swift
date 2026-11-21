import Foundation

/// A message typed here that Instagram hasn't echoed back yet.
nonisolated struct Pending: Identifiable, Hashable, Sendable {
    let id: UUID
    var threadId: String
    var text: String
    var replyTo: Quote?
    /// The daemon's ID for this send, once it has answered. A retry passes it
    /// back so Instagram can't deliver the message twice.
    var otid: String?
    var failed = false
    var createdAt: Date
}

/// Everything the app knows about the account, as a value: the daemon's
/// events go in through `apply`, and the views read the result. It makes no
/// calls, so it is tested on its own.
nonisolated struct Inbox: Sendable {
    var connection: Connection = .connecting
    var error = ""
    var me: User?
    /// Most recent activity first.
    var threads: [ChatThread] = []
    /// Loaded history per thread, oldest first. A thread that isn't a key
    /// hasn't been opened.
    var messages: [String: [Message]] = [:]
    /// Whether older history remains, per loaded thread.
    var hasOlder: [String: Bool] = [:]
    var pending: [Pending] = []
    /// When each member's typing indicator runs out, per thread.
    var typing: [String: [String: Date]] = [:]
    /// The time of the newest message seen here, per thread. It hides the
    /// unread mark in this app without telling Instagram, for when read
    /// receipts are off.
    var seenMs: [String: Int64] = [:]

    /// The time of the newest message counted per thread, so one delivered
    /// again, or an older one arriving late, isn't announced. A thread first
    /// heard of through `thread_updated` starts at 0: the daemon sends that
    /// just before the thread's new message, which must still be announced.
    private(set) var countedMs: [String: Int64] = [:]

    /// How long a typing indicator lasts without a stop.
    static let typingLifetime: TimeInterval = 8

    func thread(_ id: String) -> ChatThread? { threads.first { $0.id == id } }

    func isUnread(_ t: ChatThread) -> Bool {
        t.unread && t.newestMs > (seenMs[t.id] ?? 0)
    }

    /// Unread threads that aren't muted: the menu bar count.
    var unreadCount: Int { threads.count { !$0.muted && isUnread($0) } }

    func pending(in thread: String) -> [Pending] { pending.filter { $0.threadId == thread } }

    func typists(in thread: String, now: Date) -> [User] {
        guard let t = self.thread(thread), let until = typing[thread] else { return [] }
        return t.members.filter { (until[$0.id] ?? .distantPast) > now }
    }

    /// Whether a new message deserves a notification: from someone else, in
    /// a thread that isn't muted, and newer than anything already counted.
    func shouldNotify(_ m: Message) -> Bool {
        guard let me, m.senderId != me.id, let t = thread(m.threadId), !t.muted else { return false }
        return m.atMs > (countedMs[m.threadId] ?? 0)
    }

    mutating func apply(_ event: ServerEvent, now: Date = .now) {
        switch event {
        case .state(let s):
            if s.me?.id != me?.id {
                // Another account, or none: nothing kept belongs to it.
                messages = [:]; hasOlder = [:]; pending = []; typing = [:]
            }
            connection = s.state; error = s.error; me = s.me; threads = s.threads
            // Everything in a fresh inbox is old news.
            countedMs = Dictionary(uniqueKeysWithValues: s.threads.map { ($0.id, $0.newestMs) })
            sortThreads()
        case .status(let c, let e):
            connection = c; error = e
        case .threadUpdated(let t):
            if let i = threads.firstIndex(where: { $0.id == t.id }) {
                threads[i] = t
            } else {
                threads.append(t)
                countedMs[t.id] = 0
            }
            sortThreads()
        case .messageAdded(let m):
            add(m)
        case .threadRead(let id, let until):
            update(id) { if until >= $0.newestMs { $0.unread = false } }
        case .readReceipt(let id, let user, let upTo):
            update(id) { $0.readUpToMs[user] = max($0.readUpToMs[user] ?? 0, upTo) }
        case .typing(let id, let user, let active):
            typing[id, default: [:]][user] = active ? now.addingTimeInterval(Self.typingLifetime) : nil
        case .reactionAdded(let id, let messageId, let reaction):
            editMessage(id, messageId) {
                $0.reactions.removeAll { $0.userId == reaction.userId }
                $0.reactions.append(reaction)
            }
        case .reactionRemoved(let id, let messageId, let user, let reactionId):
            // Instagram may name only the reaction, so look on every message.
            editEveryMessage(id) { m in
                m.reactions.removeAll { r in
                    reactionId.isEmpty ? (m.id == messageId && r.userId == user) : r.id == reactionId
                }
            }
        case .messageEdited(let id, let messageId, let text, let at):
            editMessage(id, messageId) {
                if at >= $0.editedAtMs { $0.text = text; $0.editedAtMs = at }
            }
        case .messageUnsent(let id, let messageId):
            editMessage(id, messageId) {
                $0.unsent = true; $0.text = ""; $0.contentType = ""; $0.reactions = []
            }
        case .threadMuted(let id, let muted):
            update(id) { $0.muted = muted }
        }
    }

    /// Puts a page of history in place: the newest page when `before` is
    /// nil, otherwise the page older than that message.
    mutating func load(_ page: [Message], more: Bool, thread: String, before: String?) {
        var all = before == nil ? [] : (messages[thread] ?? [])
        // Keep live messages that arrived while the newest page loaded.
        let live = before == nil ? (messages[thread] ?? []).filter { m in !page.contains { $0.id == m.id } && m.atMs >= (page.last?.atMs ?? 0) } : []
        let known = Set(all.map(\.id))
        all = page.filter { !known.contains($0.id) } + all + live
        messages[thread] = all.sorted { ($0.atMs, $0.id) < ($1.atMs, $1.id) }
        hasOlder[thread] = more
        // A send whose echo was missed, say while reconnecting, is in the
        // history: its pending copy has done its job.
        let sent = Set(page.lazy.filter { !$0.otid.isEmpty }.map(\.otid))
        pending.removeAll { $0.threadId == thread && $0.otid.map(sent.contains) == true }
    }

    private mutating func add(_ m: Message) {
        // The echo of a send from here replaces its pending copy.
        if m.senderId == me?.id {
            if let i = pending.firstIndex(where: { $0.otid == m.otid && !m.otid.isEmpty })
                ?? pending.firstIndex(where: { $0.otid == nil && $0.threadId == m.threadId && $0.text == m.text }) {
                pending.remove(at: i)
            }
        }
        if var list = messages[m.threadId], !list.contains(where: { $0.id == m.id }) {
            let i = list.lastIndex { ($0.atMs, $0.id) < (m.atMs, m.id) }.map { $0 + 1 } ?? 0
            list.insert(m, at: i)
            messages[m.threadId] = list
        }
        typing[m.threadId]?[m.senderId] = nil
        countedMs[m.threadId] = max(countedMs[m.threadId] ?? 0, m.atMs)
        let fromMe = m.senderId == me?.id
        update(m.threadId) { t in
            if let last = t.lastMessage, last.id == m.id { return }  // delivered again
            if (t.lastMessage?.atMs ?? .min) < m.atMs {
                t.lastMessage = m
                t.unread = !fromMe
            }
            t.lastActivityMs = max(t.lastActivityMs, m.atMs)
        }
        sortThreads()
    }

    private mutating func update(_ id: String, _ change: (inout ChatThread) -> Void) {
        guard let i = threads.firstIndex(where: { $0.id == id }) else { return }
        change(&threads[i])
    }

    private mutating func editMessage(_ thread: String, _ id: String, _ change: (inout Message) -> Void) {
        editEveryMessage(thread) { if $0.id == id { change(&$0) } }
    }

    private mutating func editEveryMessage(_ thread: String, _ change: (inout Message) -> Void) {
        if var list = messages[thread] {
            for i in list.indices { change(&list[i]) }
            messages[thread] = list
        }
        update(thread) { t in
            if var last = t.lastMessage { change(&last); t.lastMessage = last }
        }
    }

    private mutating func sortThreads() {
        threads.sort { ($0.lastActivityMs, $0.id) > ($1.lastActivityMs, $1.id) }
    }
}
