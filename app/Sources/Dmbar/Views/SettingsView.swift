import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                GlassIconButton(symbol: "chevron.left", label: "Back") { model.route = .list }
                Text("Settings").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            ScrollView {
                VStack(spacing: 14) {
                    account
                    Card("Privacy") {
                        ToggleRow("Read receipts", "Others see “Seen” when you open a conversation. When off, opening one clears it here only.", isOn: $settings.readReceipts)
                        Divider()
                        ToggleRow("Typing indicator", "Others see when you are typing.", isOn: $settings.sendTyping)
                    }
                    Card("Notifications") {
                        ToggleRow("New messages", "Muted conversations never notify.", isOn: $settings.notifications)
                        Divider()
                        ToggleRow("Show message text", "When off, a notification says only who wrote.", isOn: $settings.notificationPreviews)
                            .disabled(!settings.notifications)
                    }
                    Card("General") {
                        ToggleRow("Open at login", "Start dmbar when you log in to this Mac.", isOn: Binding(
                            get: { settings.launchAtLogin }, set: { settings.launchAtLogin = $0 }))
                        Divider()
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Shortcut")
                                Text("Opens dmbar from anywhere.").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            ShortcutRecorder(shortcut: $settings.shortcut)
                        }
                    }
                    Button("Quit dmbar") { NSApp.terminate(nil) }
                        .buttonStyle(.glass)
                        .keyboardShortcut("q")
                    Text("dmbar \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev") · unofficial")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 14)
            }
            .scrollIndicators(.never)
        }
    }

    @ViewBuilder private var account: some View {
        Card("Account") {
            if let me = model.inbox.me {
                HStack(spacing: 10) {
                    Avatar(user: me, size: 34)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(me.displayName).fontWeight(.medium)
                        if !me.username.isEmpty {
                            Text("@\(me.username)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Log out", role: .destructive) { model.logout() }
                        .buttonStyle(.glass)
                        .help("Forgets the login on this Mac. The session stays valid on Instagram until it expires.")
                }
            } else {
                Text("Not logged in").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// A titled group of rows.
private struct Card<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
            VStack(spacing: 10) { content }
                .padding(12)
                .frame(maxWidth: .infinity)
                .background(.primary.opacity(0.06), in: .rect(cornerRadius: 16, style: .continuous))
        }
    }
}

private struct ToggleRow: View {
    var title: String
    var detail: String
    @Binding var isOn: Bool

    init(_ title: String, _ detail: String, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        _isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }
}

/// Shows the global shortcut and records a new one: click, then press the
/// keys. Escape cancels and Delete removes the shortcut.
private struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button(action: toggle) {
            Text(recording ? "Press keys…" : (shortcut?.display ?? "None"))
                .font(.callout.monospaced())
                .frame(minWidth: 74)
        }
        .buttonStyle(.glass)
        .onDisappear(perform: stop)
        .help("Click, then press a shortcut. Delete removes it.")
    }

    private func toggle() {
        if recording { stop() } else { start() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 53: break  // Escape: keep the current shortcut
            case 51, 117: shortcut = nil  // Delete
            default:
                guard let new = Shortcut(event: event) else { return nil }  // needs a modifier; keep listening
                shortcut = new
            }
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
