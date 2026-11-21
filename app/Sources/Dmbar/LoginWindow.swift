import AppKit
import WebKit

/// Instagram's own login page in a window. Instagram handles the password,
/// two-factor codes and any checks; once its session cookies exist they are
/// handed to the daemon and the window closes.
///
/// The web view keeps nothing on disk, so each login starts clean and
/// closing the window leaves no second session behind.
final class LoginWindow: NSObject, NSWindowDelegate, WKHTTPCookieStoreObserver {
    /// The cookies the daemon uses, of which the first three are required.
    private static let wanted = ["sessionid", "csrftoken", "ds_user_id", "mid", "ig_did", "rur", "shbid", "shbts"]

    private var window: NSWindow?
    private var store: WKHTTPCookieStore?
    private var submitted = false
    /// Logs in with the cookies and returns nil, or says why it failed.
    private let login: ([String: String]) async -> String?

    init(login: @escaping ([String: String]) async -> String?) {
        self.login = login
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config)
        store = config.websiteDataStore.httpCookieStore
        store?.add(self)
        submitted = false

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 720),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = "Log in to Instagram"
        w.contentView = web
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        window = w
        web.load(URLRequest(url: URL(string: "https://www.instagram.com/accounts/login/")!))
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor in await check() }
    }

    private func check() async {
        guard !submitted, let store else { return }
        var found: [String: String] = [:]
        for cookie in await store.allCookies() where cookie.domain.hasSuffix("instagram.com") && Self.wanted.contains(cookie.name) {
            found[cookie.name] = cookie.value
        }
        // sessionid only exists once Instagram has finished logging in.
        guard !(found["sessionid"] ?? "").isEmpty, found["ds_user_id"] != nil, found["csrftoken"] != nil else { return }
        submitted = true
        if let problem = await login(found) {
            submitted = false
            let alert = NSAlert()
            alert.messageText = "Couldn't finish logging in"
            alert.informativeText = problem
            if let window { await alert.beginSheetModal(for: window) }
        } else {
            close()
        }
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        if let store { store.remove(self) }
        store = nil
        window = nil
    }
}
