import AppKit
import SwiftUI

@main
enum Main {
    /// NSApplication holds its delegate weakly, so it is kept here: a local
    /// would be released after its last use, before `run` returns.
    private static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)  // menu bar only, no Dock icon
        app.run()
    }
}

/// Owns the menu bar item, its popover and the pieces around the model.
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let model = AppModel()
    private let notifier = Notifier()
    private let hotKey = HotKey()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    /// Where the popover hangs from when the menu bar item is hidden.
    private var anchor: NSWindow?
    private lazy var loginWindow = LoginWindow { [model] cookies in await model.login(cookies: cookies) }

    static let popoverSize = NSSize(width: 372, height: 540)

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggle)
        statusItem.button?.imagePosition = .imageLeading

        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = Self.popoverSize
        popover.contentViewController = NSHostingController(
            rootView: RootView(showLogin: { [weak self] in self?.showLogin() })
                .environment(model)
                .frame(width: Self.popoverSize.width, height: Self.popoverSize.height))

        // The demo is for development: it must not register a login item.
        if ProcessInfo.processInfo.environment["DMBAR_DEMO"] == nil { model.settings.applyFirstRunDefaults() }
        model.onChange = { [weak self] in self?.refreshStatusItem() }
        model.notify = { [weak self] thread, message in
            guard let self else { return }
            self.notifier.post(thread: thread, message: message, preview: self.model.settings.notificationPreviews)
        }
        notifier.onOpen = { [weak self] thread in
            self?.model.open(thread)
            self?.show()
        }
        notifier.onReply = { [weak self] text, thread in self?.model.reply(text, to: thread) }
        notifier.start()

        hotKey.onPress = { [weak self] in self?.toggle() }
        hotKey.set(model.settings.shortcut)
        observeShortcut()

        refreshStatusItem()
        model.start()
        // For working on the app: open the popover without a click.
        if ProcessInfo.processInfo.environment["DMBAR_SHOW"] != nil {
            Task {
                try? await Task.sleep(for: .seconds(1))
                // DMBAR_ROUTE=settings, or a thread ID, picks the screen.
                switch ProcessInfo.processInfo.environment["DMBAR_ROUTE"] {
                case "settings": model.route = .settings
                case let id?: model.open(id)
                case nil: break
                }
                show()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }

    /// Re-registers the global shortcut whenever the setting changes.
    private func observeShortcut() {
        withObservationTracking {
            _ = model.settings.shortcut
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.hotKey.set(self.model.settings.shortcut)
                self.observeShortcut()
            }
        }
    }

    private func refreshStatusItem() {
        guard let button = statusItem.button else { return }
        let count = model.inbox.unreadCount
        let symbol = count > 0 ? "paperplane.fill" : "paperplane"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "dmbar")
        button.title = count > 0 ? " \(count)" : ""
        button.setAccessibilityLabel(count > 0 ? "dmbar, \(count) unread" : "dmbar")
        if case .thread(let id) = model.route, model.popoverVisible { notifier.clear(thread: id) }
    }

    @objc private func toggle() {
        if popover.isShown { popover.performClose(nil) } else { show() }
    }

    private func show() {
        guard let button = statusItem.button, !popover.isShown else { return }
        NSApp.activate()
        // A menu bar manager (Ice, Thaw, Bartender) or a full menu bar can hide
        // the item; its window then has no height and a popover can't hang
        // from it. Hang it from the top right of the screen instead, so the
        // shortcut and notifications still open dmbar.
        if let window = button.window, window.frame.height > 1, window.occlusionState.contains(.visible) {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        } else if let view = fallbackAnchor() {
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        }
        popover.contentViewController?.view.window?.makeKey()
    }

    /// An invisible sliver just under the menu bar, near the right edge of
    /// the screen with the pointer, for the popover to hang from.
    private func fallbackAnchor() -> NSView? {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return nil }
        let frame = NSRect(x: area.maxX - Self.popoverSize.width / 2 - 24, y: area.maxY - 1, width: 2, height: 1)
        if anchor == nil {
            let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.ignoresMouseEvents = true
            w.level = .statusBar
            w.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
            w.isReleasedWhenClosed = false
            anchor = w
        }
        anchor?.setFrame(frame, display: false)
        anchor?.orderFrontRegardless()
        return anchor?.contentView
    }

    private func showLogin() {
        popover.performClose(nil)
        loginWindow.show()
    }

    func popoverDidShow(_ notification: Notification) {
        model.popoverVisible = true
        refreshStatusItem()
    }

    func popoverDidClose(_ notification: Notification) {
        model.popoverVisible = false
        anchor?.orderOut(nil)
    }
}
