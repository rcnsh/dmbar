import AppKit
import Carbon.HIToolbox
import Observation
import ServiceManagement

/// A global keyboard shortcut: a key and its modifiers.
nonisolated struct Shortcut: Codable, Equatable, Sendable {
    var keyCode: UInt32
    /// Carbon modifier flags (`controlKey`, `optionKey`, …).
    var modifiers: UInt32
    /// The key as typed, for showing.
    var key: String

    static let standard = Shortcut(keyCode: UInt32(kVK_ANSI_I), modifiers: UInt32(controlKey | optionKey), key: "I")

    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + key.uppercased()
    }

    /// The shortcut for a key press, or nil if it has no modifier besides
    /// Shift, which would swallow ordinary typing.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var m: UInt32 = 0
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        guard m & ~UInt32(shiftKey) != 0, let key = event.charactersIgnoringModifiers, !key.isEmpty else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: m, key: key)
    }

    init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }
}

/// The user's choices, kept in UserDefaults.
@Observable
final class Settings {
    private let defaults: UserDefaults

    /// Tell the sender when a conversation has been read.
    var readReceipts: Bool { didSet { defaults.set(readReceipts, forKey: "readReceipts") } }
    /// Tell the other side when typing.
    var sendTyping: Bool { didSet { defaults.set(sendTyping, forKey: "sendTyping") } }
    /// Post a notification for new messages.
    var notifications: Bool { didSet { defaults.set(notifications, forKey: "notifications") } }
    /// Show the message's text in its notification.
    var notificationPreviews: Bool { didSet { defaults.set(notificationPreviews, forKey: "notificationPreviews") } }
    var shortcut: Shortcut? {
        // No shortcut is saved as empty data, which is not "never set".
        didSet { defaults.set(shortcut.flatMap { try? JSONEncoder().encode($0) } ?? Data(), forKey: "shortcut") }
    }
    /// Per-thread marks for conversations seen here with read receipts off.
    var seenMs: [String: Int64] { didSet { defaults.set(seenMs, forKey: "seenMs") } }
    /// Emoji the user picked or reacted with, most recent first.
    private(set) var recentEmoji: [String] { didSet { defaults.set(recentEmoji, forKey: "recentEmoji") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            "readReceipts": true, "sendTyping": true, "notifications": true, "notificationPreviews": true,
            "launchAtLoginSet": false,
        ])
        readReceipts = defaults.bool(forKey: "readReceipts")
        sendTyping = defaults.bool(forKey: "sendTyping")
        notifications = defaults.bool(forKey: "notifications")
        notificationPreviews = defaults.bool(forKey: "notificationPreviews")
        if defaults.object(forKey: "shortcut") == nil {
            shortcut = .standard
        } else {
            shortcut = defaults.data(forKey: "shortcut").flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) }
        }
        seenMs = (defaults.dictionary(forKey: "seenMs") as? [String: Int64]) ?? [:]
        recentEmoji = defaults.stringArray(forKey: "recentEmoji") ?? []
    }

    /// Puts an emoji first among the recent ones.
    func useEmoji(_ emoji: String) {
        recentEmoji = Array(([emoji] + recentEmoji.filter { $0 != emoji }).prefix(24))
    }

    /// Whether macOS opens dmbar at login. The system owns the answer.
    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("dmbar: launch at login not changed: \(error.localizedDescription)")
            }
        }
    }

    /// Turns launch at login on the first time the app runs, as it defaults
    /// to on; after that the choice is the user's.
    func applyFirstRunDefaults() {
        guard !defaults.bool(forKey: "launchAtLoginSet") else { return }
        defaults.set(true, forKey: "launchAtLoginSet")
        launchAtLogin = true
    }
}
