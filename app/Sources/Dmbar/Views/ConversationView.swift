import SwiftUI

/// One conversation: its history, live messages and the composer.
struct ConversationView: View {
    @Environment(AppModel.self) private var model
    var threadId: String

    @State private var draft = ""
    @State private var replyingTo: Message?
    @State private var position = ScrollPosition(edge: .bottom)
    @FocusState private var composerFocused: Bool

    private var thread: ChatThread? { model.inbox.thread(threadId) }
    private var messages: [Message] { model.inbox.messages[threadId] ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            header
            history
            composer
        }
        .onAppear { composerFocused = true }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            GlassIconButton(symbol: "chevron.left", label: "Back") { model.route = .list }
            if let thread {
                Avatar(thread: thread, size: 30)
                VStack(alignment: .leading, spacing: 0) {
                    Text(thread.title).font(.headline).lineLimit(1)
                    Text(subtitle(thread)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private func subtitle(_ thread: ChatThread) -> String {
        if thread.isGroup { return "\(thread.members.count + 1) people" }
        if let u = thread.members.first, !u.username.isEmpty { return "@\(u.username)" }
        return "Instagram"
    }

    // MARK: History

    private var history: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if model.inbox.hasOlder[threadId] == true {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.vertical, 10)
                        .onAppear(perform: loadOlder)
                }
                ForEach(Array(messages.enumerated()), id: \.element.id) { i, message in
                    let previous = i > 0 ? messages[i - 1] : nil
                    let next = i + 1 < messages.count ? messages[i + 1] : nil
                    if previous.map({ !Calendar.current.isDate($0.date, inSameDayAs: message.date) }) ?? true {
                        Text(Format.day(message.date))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.top, 12)
                            .padding(.bottom, 6)
                    }
                    MessageRow(
                        message: message,
                        mine: message.senderId == model.inbox.me?.id,
                        sender: thread?.member(message.senderId),
                        showsSender: thread?.isGroup == true,
                        startsRun: previous?.senderId != message.senderId,
                        endsRun: next?.senderId != message.senderId,
                        quoteAuthor: quoteAuthor(message),
                        onReply: { replyingTo = message; composerFocused = true }
                    )
                    .id(message.id)
                }
                if let seen = seenLabel {
                    Text(seen)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.top, 3)
                }
                ForEach(model.inbox.pending(in: threadId)) { p in
                    PendingRow(pending: p, retry: { model.retry(p.id) }, discard: { model.discard(p.id) })
                        .id(p.id)
                }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let typists = model.inbox.typists(in: threadId, now: context.date)
                    if !typists.isEmpty {
                        HStack(spacing: 6) {
                            TypingDots()
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(.primary.opacity(0.08), in: .rect(cornerRadius: 18, style: .continuous))
                            if thread?.isGroup == true {
                                Text(typists.map(\.displayName).joined(separator: ", "))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.top, 6)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                Color.clear.frame(height: 8).id("bottom")
            }
            .scrollTargetLayout()
            .padding(.horizontal, 12)
        }
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom)
        .scrollIndicators(.never)
        .overlay {
            if messages.isEmpty, model.loading.contains(threadId) {
                ProgressView().controlSize(.small)
            }
        }
        .onChange(of: messages.last?.id) { scrollToBottom() }
        .onChange(of: model.inbox.pending(in: threadId).count) { scrollToBottom() }
    }

    private func scrollToBottom() {
        withAnimation(.snappy(duration: 0.25)) { position.scrollTo(edge: .bottom) }
    }

    /// Loads the page before the first message and keeps that message where
    /// it was, so the view doesn't jump.
    private func loadOlder() {
        guard let anchor = messages.first?.id else { return }
        Task {
            await model.loadOlder(threadId)
            position.scrollTo(id: anchor, anchor: .top)
        }
    }

    private func quoteAuthor(_ m: Message) -> String? {
        guard let q = m.replyTo else { return nil }
        if q.senderId == model.inbox.me?.id { return "You" }
        return thread?.member(q.senderId)?.displayName
    }

    /// "Seen" under the user's newest message once the other person in a
    /// one-to-one chat has read it.
    private var seenLabel: String? {
        guard let thread, !thread.isGroup, let last = messages.last, last.senderId == model.inbox.me?.id,
              model.inbox.pending(in: threadId).isEmpty,
              let other = thread.members.first, (thread.readUpToMs[other.id] ?? 0) >= last.atMs else { return nil }
        return "Seen"
    }

    // MARK: Composer

    private var composer: some View {
        VStack(spacing: 6) {
            if let replyingTo {
                HStack(spacing: 8) {
                    Capsule().fill(Theme.mine).frame(width: 3, height: 28)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Replying to \(replyingTo.senderId == model.inbox.me?.id ? "yourself" : (thread?.member(replyingTo.senderId)?.displayName ?? "message"))")
                            .font(.caption.weight(.semibold))
                        Text(replyingTo.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button { self.replyingTo = nil } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Cancel reply")
                }
                .padding(.horizontal, 6)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            GlassEffectContainer(spacing: 8) {
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Message…", text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...5)
                        .focused($composerFocused)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .glassEffect(.regular, in: .rect(cornerRadius: 19, style: .continuous))
                        .onKeyPress(.return, phases: .down) { press in
                            if press.modifiers.contains(.shift) {
                                draft += "\n"
                            } else {
                                send()
                            }
                            return .handled
                        }
                        .onChange(of: draft) { _, new in
                            model.typing(in: threadId, active: !new.isEmpty)
                        }
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 14, weight: .bold))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.circle)
                    .tint(Color(red: 0.5, green: 0.34, blue: 0.96))
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                    .accessibilityLabel("Send")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 12)
        .animation(Theme.slide, value: replyingTo?.id)
    }

    private func send() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = ""
        model.send(text, to: threadId, replyTo: replyingTo)
        replyingTo = nil
    }
}

// MARK: Rows

private struct MessageRow: View {
    var message: Message
    var mine: Bool
    var sender: User?
    var showsSender: Bool
    var startsRun: Bool
    var endsRun: Bool
    var quoteAuthor: String?
    var onReply: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if mine { Spacer(minLength: 46) }
            if showsSender, !mine {
                if endsRun, let sender { Avatar(user: sender, size: 24) } else { Color.clear.frame(width: 24, height: 1) }
            }
            VStack(alignment: mine ? .trailing : .leading, spacing: 2) {
                if showsSender, !mine, startsRun, let sender {
                    Text(sender.displayName).font(.caption2).foregroundStyle(.secondary).padding(.leading, 12)
                }
                if let quote = message.replyTo {
                    VStack(alignment: .leading, spacing: 1) {
                        if let quoteAuthor { Text(quoteAuthor).font(.caption2.weight(.semibold)) }
                        Text(quote.text.isEmpty ? ContentLabel.label(for: quote.contentType) : quote.text)
                            .font(.caption).lineLimit(2)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.primary.opacity(0.05), in: .rect(cornerRadius: 12, style: .continuous))
                }
                bubble
                if !message.reactions.isEmpty {
                    Text(reactionText)
                        .font(.caption)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .glassEffect(.regular, in: .capsule)
                        .offset(y: -6)
                        .padding(.bottom, -6)
                        .padding(.horizontal, 8)
                        .accessibilityLabel("Reactions: \(reactionText)")
                }
            }
            if !mine { Spacer(minLength: 46) }
        }
        .padding(.top, startsRun ? 8 : 2)
        .contextMenu {
            if !message.unsent {
                Button("Reply", systemImage: "arrowshape.turn.up.left", action: onReply)
                if !message.text.isEmpty {
                    Button("Copy", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.text, forType: .string)
                    }
                }
            }
        }
        .help(message.date.formatted(date: .abbreviated, time: .shortened))
    }

    @ViewBuilder private var bubble: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        Group {
            if message.unsent {
                Text("Message unsent").italic().foregroundStyle(.secondary)
            } else if message.text.isEmpty {
                Label(ContentLabel.label(for: message.contentType), systemImage: ContentLabel.symbol(for: message.contentType))
                    .foregroundStyle(mine ? AnyShapeStyle(.white.opacity(0.9)) : AnyShapeStyle(.secondary))
            } else {
                Text(message.text)
                    .foregroundStyle(mine ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    .textSelection(.enabled)
            }
        }
        .font(.body)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background {
            if mine, !message.unsent { shape.fill(Theme.mine) } else { shape.fill(.primary.opacity(0.08)) }
        }
        .overlay(alignment: .bottomTrailing) {
            if message.editedAtMs > 0, !message.unsent {
                Text("edited").font(.system(size: 9)).foregroundStyle(.tertiary).offset(y: 12)
            }
        }
        .padding(.bottom, message.editedAtMs > 0 && !message.unsent ? 12 : 0)
    }

    /// Each emoji once, with a count when more than one person used it.
    private var reactionText: String {
        var counts: [(String, Int)] = []
        for r in message.reactions {
            if let i = counts.firstIndex(where: { $0.0 == r.emoji }) { counts[i].1 += 1 } else { counts.append((r.emoji, 1)) }
        }
        return counts.map { $0.1 > 1 ? "\($0.0) \($0.1)" : $0.0 }.joined(separator: " ")
    }
}

private struct PendingRow: View {
    var pending: Pending
    var retry: () -> Void
    var discard: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Spacer(minLength: 46)
            if pending.failed {
                Menu {
                    Button("Try again", systemImage: "arrow.clockwise", action: retry)
                    Button("Delete", systemImage: "trash", role: .destructive, action: discard)
                } label: {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Not sent")
                .accessibilityLabel("Not sent. Options")
            }
            Text(pending.text)
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Theme.mine, in: .rect(cornerRadius: 18, style: .continuous))
                .opacity(pending.failed ? 0.45 : 0.6)
        }
        .padding(.top, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(pending.failed ? "Not sent: \(pending.text)" : "Sending: \(pending.text)")
    }
}
