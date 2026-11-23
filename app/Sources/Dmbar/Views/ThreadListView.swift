import SwiftUI

/// The inbox: one row per conversation, most recent first.
struct ThreadListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.inbox.threads.isEmpty {
                if model.inbox.connection == .connected {
                    MessageScreen(symbol: "tray", title: "No messages", detail: "New conversations show up here.")
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.inbox.threads) { thread in
                            ThreadRow(thread: thread, unread: model.inbox.isUnread(thread), me: model.inbox.me?.id)
                                .contentShape(.rect)
                                .onTapGesture { model.open(thread.id) }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 10)
                }
                .scrollIndicators(.never)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Messages").font(.title2.weight(.bold))
                status
            }
            Spacer()
            GlassIconButton(symbol: "gearshape", label: "Settings") { model.route = .settings }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    @ViewBuilder private var status: some View {
        switch model.inbox.connection {
        case .connected:
            if let me = model.inbox.me, !me.username.isEmpty {
                Text("@\(me.username)").font(.caption).foregroundStyle(.secondary)
            }
        case .reconnecting:
            Label("Reconnecting…", systemImage: "wifi.exclamationmark").font(.caption).foregroundStyle(.orange)
        default:
            Label("Connecting…", systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct ThreadRow: View {
    var thread: ChatThread
    var unread: Bool
    var me: String?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 11) {
            Avatar(thread: thread, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(thread.title)
                        .font(.body.weight(unread ? .semibold : .medium))
                        .lineLimit(1)
                    if thread.muted {
                        Image(systemName: "bell.slash.fill").font(.caption2).foregroundStyle(.tertiary)
                            .accessibilityLabel("Muted")
                    }
                }
                Text(preview)
                    .font(.callout)
                    .foregroundStyle(unread ? .primary : .secondary)
                    .fontWeight(unread ? .medium : .regular)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 6) {
                Text(Format.short(thread.newestMs))
                    .font(.caption)
                    .foregroundStyle(unread ? .primary : .tertiary)
                    .monospacedDigit()
                Circle()
                    .fill(Theme.unread)
                    .frame(width: 9, height: 9)
                    .opacity(unread ? 1 : 0)
                    .accessibilityHidden(!unread)
                    .accessibilityLabel("Unread")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(.primary.opacity(hovering ? 0.07 : 0), in: .rect(cornerRadius: 14, style: .continuous))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var preview: String {
        guard let m = thread.lastMessage else { return "No messages yet" }
        if m.senderId == me { return "You: \(m.summary)" }
        if thread.isGroup, let who = thread.member(m.senderId) {
            return "\(who.displayName.split(separator: " ").first.map(String.init) ?? who.displayName): \(m.summary)"
        }
        return m.summary
    }
}
