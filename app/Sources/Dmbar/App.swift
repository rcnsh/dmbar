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
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
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
                // DMBAR_ROUTE=settings, menu, or a thread ID, picks the screen.
                switch ProcessInfo.processInfo.environment["DMBAR_ROUTE"] {
                case "settings": model.route = .settings
                case "menu": showMenu(); return
                case let id? where !id.isEmpty: model.open(id)
                default: break
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

    /// A left click toggles the popover; a right or control-click opens the menu.
    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            toggle()
        }
    }

    /// Pops the menu from the item. Setting `menu` only for this click keeps
    /// the left click for the popover, and lets AppKit place and highlight it.
    /// A hidden item (see `show()`) has nowhere to drop from, so the menu
    /// then pops from the same anchor the popover uses.
    private func showMenu() {
        popover.performClose(nil)
        let menu = makeMenu()
        if let button = statusItem.button, let window = button.window, window.frame.height > 1,
           window.occlusionState.contains(.visible) {
            statusItem.menu = menu
            button.performClick(nil)
            statusItem.menu = nil
        } else if let view = fallbackAnchor() {
            NSApp.activate()
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.minY), in: view)
            anchor?.orderOut(nil)
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let inbox = model.inbox
        let loggedIn = inbox.connection != .loggedOut && inbox.connection != .loginRequired

        let unread = inbox.threads.filter { !$0.muted && inbox.isUnread($0) }
        if loggedIn, !unread.isEmpty {
            menu.addItem(.sectionHeader(title: "Unread"))
            for t in unread.prefix(Self.menuThreads) {
                let item = ActionItem(t.title) { [weak self] in
                    self?.model.open(t.id)
                    self?.show()
                }
                item.image = NSImage(systemSymbolName: t.isGroup ? "person.2" : "person", accessibilityDescription: nil)
                if model.settings.notificationPreviews, let m = t.lastMessage { item.subtitle = Self.oneLine(m.summary) }
                menu.addItem(item)
            }
            if unread.count > Self.menuThreads {
                menu.addItem(ActionItem("\(unread.count - Self.menuThreads) more…") { [weak self] in
                    self?.model.route = .list
                    self?.show()
                })
            }
            menu.addItem(.separator())
        }

        menu.addItem(ActionItem("Open dmbar") { [weak self] in self?.show() })
        if loggedIn {
            let markAll = ActionItem("Mark All as Read") { [weak self] in self?.model.markAllRead() }
            // Offline, Instagram can't be told and the marks would be undone.
            markAll.isEnabled = inbox.connection == .connected && !model.markableUnread.isEmpty
            menu.addItem(markAll)
        } else {
            menu.addItem(ActionItem("Log In…") { [weak self] in self?.showLogin() })
        }
        menu.addItem(.separator())

        let notifications = ActionItem("Notifications") { [weak self] in
            guard let self else { return }
            self.model.settings.notifications.toggle()
        }
        notifications.state = model.settings.notifications ? .on : .off
        menu.addItem(notifications)
        menu.addItem(ActionItem("Settings…", key: ",") { [weak self] in
            self?.model.route = .settings
            self?.show()
        })
        menu.addItem(.separator())
        menu.addItem(ActionItem("Quit dmbar", key: "q") { NSApp.terminate(nil) })
        return menu
    }

    /// How many unread conversations the menu lists by name.
    private static let menuThreads = 5

    /// A message as one short line, so a long one can't stretch the menu.
    private static func oneLine(_ text: String, limit: Int = 60) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count > limit ? flat.prefix(limit - 1) + "…" : flat
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

/// A menu item that runs a closure, so menus need no selector per item. The
/// item keeps the closure's target alive: `target` alone is weak.
private func ActionItem(_ title: String, key: String = "", run: @escaping () -> Void) -> NSMenuItem {
    let action = MenuAction(run)
    let item = NSMenuItem(title: title, action: #selector(MenuAction.fire), keyEquivalent: key)
    item.target = action
    item.representedObject = action
    return item
}

private final class MenuAction: NSObject {
    private let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire() { run() }
}
