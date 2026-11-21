import SwiftUI

/// The popover's content: one screen at a time, sliding between them.
struct RootView: View {
    @Environment(AppModel.self) private var model
    var showLogin: () -> Void

    var body: some View {
        ZStack {
            switch screen {
            case .problem(let text):
                MessageScreen(symbol: "exclamationmark.triangle", title: "dmbar can't start its backend", detail: text)
            case .welcome:
                WelcomeView(showLogin: showLogin)
                    .transition(.opacity)
            case .route(.list):
                ThreadListView()
                    .transition(.move(edge: .leading).combined(with: .opacity))
            case .route(.thread(let id)):
                ConversationView(threadId: id)
                    .id(id)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            case .route(.settings):
                SettingsView()
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(Theme.slide, value: screen)
        .overlay {
            if let viewing = model.viewing {
                MediaViewer(viewing: viewing)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: model.viewing == nil)
        .overlay(alignment: .bottom) { toast }
        .onChange(of: model.route) { model.viewing = nil }
        .onExitCommand {
            if model.viewing != nil {
                model.viewing = nil
            } else if model.route != .list { model.route = .list } else { NSApp.keyWindow?.performClose(nil) }
        }
    }

    private enum Screen: Hashable {
        case problem(String), welcome, route(Route)
    }

    private var screen: Screen {
        if model.route == .settings { return .route(.settings) }
        if let problem = model.daemonError { return .problem(problem) }
        switch model.inbox.connection {
        case .loggedOut, .loginRequired: return .welcome
        default: return .route(model.route)
        }
    }

    @ViewBuilder private var toast: some View {
        if let text = model.toast {
            Text(text)
                .font(.callout)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .glassEffect(.regular, in: .capsule)
                .padding(.bottom, 64)
                .padding(.horizontal, 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: text) {
                    try? await Task.sleep(for: .seconds(4))
                    withAnimation { model.toast = nil }
                }
        }
    }
}

/// A centred symbol, title and line of detail.
struct MessageScreen: View {
    var symbol: String
    var title: String
    var detail: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Shown while no account is logged in.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    var showLogin: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "paperplane.fill")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 76, height: 76)
                .background(Theme.brand, in: .rect(cornerRadius: 22, style: .continuous))
                .shadow(color: .pink.opacity(0.35), radius: 18, y: 8)
            VStack(spacing: 6) {
                Text("Instagram messages,\nin your menu bar")
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button(action: showLogin) {
                Text(model.loginInProgress ? "Logging in…" : "Log in to Instagram")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(model.loginInProgress)
            .padding(.top, 6)
            Spacer()
            HStack {
                Text("Unofficial. Not affiliated with Instagram.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                GlassIconButton(symbol: "gearshape", label: "Settings") { model.route = .settings }
            }
        }
        .padding(24)
    }

    private var detail: String {
        if model.inbox.connection == .loginRequired {
            return model.inbox.error.isEmpty ? "Your login stopped working. Log in again to carry on." : "Log in again to carry on. Instagram said: \(model.inbox.error)"
        }
        return "You log in on Instagram's own page. dmbar keeps the session on this Mac."
    }
}
