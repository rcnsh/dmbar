import SwiftUI

/// One conversation: its history, live messages and the composer.
struct ConversationView: View {
    @Environment(AppModel.self) private var model
    var threadId: String

    @State private var draft = Composer()
    @State private var showsEmoji = false
    /// The highlighted `:shortcode:` suggestion.
    @State private var suggestion = 0
    /// A shortcode the user dismissed with Escape, until they type on.
    @State private var dismissedCode: String?
    @State private var replyingTo: Message?
    @State private var position = ScrollPosition(edge: .bottom)

    private var thread: ChatThread? { model.inbox.thread(threadId) }
    private var messages: [Message] { model.inbox.messages[threadId] ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            header
            history
            composer
        }
        .task { draft.focus() }
        .onChange(of: model.viewing == nil) { _, closed in if closed { draft.focus() } }
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
                        // Redrawn each minute so "Today" becomes "Yesterday" at midnight.
                        TimelineView(.everyMinute) { context in
                            Text(Format.day(message.date, now: context.date))
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.top, 12)
                                .padding(.bottom, 6)
                        }
                    }
                    MessageRow(
                        message: message,
                        mine: message.senderId == model.inbox.me?.id,
                        sender: thread?.member(message.senderId),
                        showsSender: thread?.isGroup == true,
                        startsRun: previous?.senderId != message.senderId,
                        endsRun: next?.senderId != message.senderId,
                        quoteAuthor: quoteAuthor(message),
                        myReaction: message.reactions.first { $0.userId == model.inbox.me?.id }?.emoji,
                        onReply: { replyingTo = message; draft.focus() },
                        onReact: { model.toggleReaction($0, on: message) },
                        onOpenMedia: { model.viewing = Viewing(media: message.media, index: $0) }
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
            if !suggestions.isEmpty {
                ShortcodeSuggestions(emoji: suggestions, highlighted: suggestion) { completeShortcode(with: $0) }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            GlassEffectContainer(spacing: 8) {
                HStack(alignment: .bottom, spacing: 8) {
                    HStack(alignment: .bottom, spacing: 4) {
                        ComposerField(composer: draft, placeholder: "Message", onKey: key)
                            .frame(height: draft.height)
                            .overlay(alignment: .topLeading) {
                                if draft.text.isEmpty {
                                    Text("Message…").foregroundStyle(.tertiary).allowsHitTesting(false)
                                }
                            }
                            .padding(.vertical, 9)
                        Button { showsEmoji.toggle() } label: {
                            Image(systemName: "face.smiling")
                                .font(.system(size: 15))
                                .foregroundStyle(.secondary)
                                .frame(width: 24, height: 36)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .help("Emoji (or type : and a name, like :fire:)")
                        .accessibilityLabel("Emoji")
                        .popover(isPresented: $showsEmoji, arrowEdge: .top) {
                            EmojiPicker { e in
                                draft.insert(e)
                                draft.focus()
                            }
                        }
                    }
                    .padding(.leading, 14)
                    .padding(.trailing, 6)
                    .glassEffect(.regular, in: .rect(cornerRadius: 19, style: .continuous))
                    .onChange(of: draft.text) {
                        model.typing(in: threadId, active: !draft.text.isEmpty)
                        suggestion = 0
                        if partialCode?.query != dismissedCode { dismissedCode = nil }
                        expandTypedCode()
                    }
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 14, weight: .bold))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.circle)
                    .tint(Color(red: 0.5, green: 0.34, blue: 0.96))
                    .disabled(draft.isBlank || model.viewing != nil)
                    .keyboardShortcut(.return, modifiers: .command)
                    .accessibilityLabel("Send")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 12)
        .animation(Theme.slide, value: replyingTo?.id)
        .animation(.snappy(duration: 0.18), value: suggestions.isEmpty)
    }

    // MARK: Emoji in the composer

    /// The `:shortcode` being typed before the caret.
    private var partialCode: (range: Range<String.Index>, query: String)? {
        Shortcode.partial(in: draft.text, before: draft.caretIndex)
    }

    private var suggestions: [Emoji] {
        guard let code = partialCode, code.query != dismissedCode else { return [] }
        return EmojiCatalog.search(code.query, limit: 6)
    }

    /// Keys from the composer: Return sends, unless suggestions are showing,
    /// when it, Tab, the arrows and Escape work the suggestions.
    private func key(_ key: ComposerKey) -> Bool {
        let shown = suggestions
        if suggestion >= shown.count { suggestion = 0 }  // the list got shorter as the caret moved
        switch key {
        case .send:
            if let e = shown[safe: suggestion] { completeShortcode(with: e) } else { send() }
            return true
        case .tab:
            guard let e = shown[safe: suggestion] else { return false }
            completeShortcode(with: e)
            return true
        case .up, .down:
            guard !shown.isEmpty else { return false }
            suggestion = (suggestion + (key == .up ? -1 : 1) + shown.count) % shown.count
            return true
        case .escape:
            guard let code = partialCode?.query, !shown.isEmpty else { return false }
            dismissedCode = code
            return true
        }
    }

    private func completeShortcode(with emoji: Emoji) {
        guard let code = partialCode else { return }
        draft.replace(code.range, with: emoji.char + " ")
        model.settings.useEmoji(emoji.char)
    }

    /// Turns a `:code:` into its emoji as its closing colon is typed.
    private func expandTypedCode() {
        guard let (range, emoji) = Shortcode.closed(in: draft.text, before: draft.caretIndex) else { return }
        draft.replace(range, with: emoji)
    }

    private func send() {
        // Sent as shown: codes became emoji while typing, or were left as text.
        let text = draft.text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft.clear()
        dismissedCode = nil
        model.send(text, to: threadId, replyTo: replyingTo)
        replyingTo = nil
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
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
    /// The user's own reaction to this message.
    var myReaction: String?
    var onReply: () -> Void
    var onReact: (String) -> Void
    var onOpenMedia: (Int) -> Void

    @State private var hovering = false
    @State private var reacting = false

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
                HStack(alignment: .center, spacing: 4) {
                    if mine { reactButton }
                    VStack(alignment: mine ? .trailing : .leading, spacing: 2) {
                        if !message.media.isEmpty, !message.unsent {
                            MediaGrid(media: message.media, open: onOpenMedia)
                        }
                        if message.media.isEmpty || !message.text.isEmpty || message.unsent { bubble }
                    }
                    if !mine { reactButton }
                }
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
        .onHover { hovering = $0 }
        .contextMenu {
            if !message.unsent {
                Button("Reply", systemImage: "arrowshape.turn.up.left", action: onReply)
                Menu("React", systemImage: "face.smiling") {
                    ForEach(QuickReactions.all, id: \.self) { e in
                        Button(myReaction.map(e.sameEmoji) == true ? "\(e)  ✓" : e) { onReact(e) }
                    }
                }
                if let myReaction {
                    Button("Remove Reaction", systemImage: "minus.circle") { onReact(myReaction) }
                }
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

    /// A smiley beside the bubble while the pointer is over the message,
    /// opening the reactions.
    private var reactButton: some View {
        Button { reacting = true } label: {
            Image(systemName: "face.smiling")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .opacity(!message.unsent && (hovering || reacting) ? 1 : 0)
        .allowsHitTesting(!message.unsent)
        .help("React")
        .accessibilityLabel("React")
        .popover(isPresented: $reacting, arrowEdge: .top) {
            ReactionPicker(current: myReaction) { e in
                reacting = false
                onReact(e)
            }
        }
    }

    @ViewBuilder private var bubble: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        if !message.unsent, let count = message.text.jumboEmojiCount {
            Text(message.text)
                .font(.system(size: count == 1 ? 46 : 34))
                .textSelection(.enabled)
                .padding(.vertical, 2)
        } else {
            plainBubble(shape)
        }
    }

    @ViewBuilder private func plainBubble(_ shape: RoundedRectangle) -> some View {
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
        // Grouped without variation selectors: "❤️" and "❤" are one heart.
        var counts: [(String, Int)] = []
        for r in message.reactions {
            if let i = counts.firstIndex(where: { $0.0.sameEmoji(as: r.emoji) }) { counts[i].1 += 1 } else { counts.append((r.emoji, 1)) }
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
