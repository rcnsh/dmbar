import AppKit
import WebKit

/// Instagram's own login page in a window. Instagram handles the password,
/// two-factor codes and any checks; once its session cookies exist they are
/// handed to the daemon and the window closes.
///
/// The web view keeps nothing on disk, so each login starts clean and
/// closing the window leaves no second session behind.
final class LoginWindow: NSObject, NSWindowDelegate, WKHTTPCookieStoreObserver, WKNavigationDelegate {
    /// The cookies the daemon uses, of which the first three are required.
    private static let wanted = ["sessionid", "csrftoken", "ds_user_id", "mid", "ig_did", "rur", "shbid", "shbts"]

    /// The home page, which shows the login form to a logged-out visitor.
    /// `/accounts/login/` answers an embedded web view with an empty 429.
    private static let start = URL(string: "https://www.instagram.com/")!

    private var window: NSWindow?
    private var store: WKHTTPCookieStore?
    private var submitted = false
    /// A check is reading the cookies.
    private var checking = false
    /// The cookies changed while a check was reading them.
    private var recheck = false
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
        web.navigationDelegate = self
        web.load(URLRequest(url: Self.start))
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor in await check() }
    }

    private func check() async {
        // Cookie changes arrive in bursts: one check at a time, and one more
        // after it if anything changed while it read.
        guard !checking else {
            recheck = true
            return
        }
        guard !submitted, let store else { return }
        checking = true
        var found: [String: String] = [:]
        repeat {
            recheck = false
            found = [:]
            for cookie in await store.allCookies() where cookie.domain.hasSuffix("instagram.com") && Self.wanted.contains(cookie.name) {
                found[cookie.name] = cookie.value
            }
        } while recheck
        checking = false
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

    /// Says so when Instagram refuses the page, which would otherwise be a
    /// blank window.
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if response.isForMainFrame, let http = response.response as? HTTPURLResponse, http.statusCode >= 400 {
            let why = http.statusCode == 429
                ? "Instagram is limiting requests from this network. Wait a few minutes and try again."
                : "Instagram answered with an error (\(http.statusCode))."
            Task { await self.fail(why) }
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        Task { await self.fail(error.localizedDescription) }
    }

    private func fail(_ why: String) async {
        guard let window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Couldn't open Instagram's login page"
        alert.informativeText = why
        alert.addButton(withTitle: "Try Again")
        alert.addButton(withTitle: "Close")
        if await alert.beginSheetModal(for: window) == .alertFirstButtonReturn {
            (window.contentView as? WKWebView)?.load(URLRequest(url: Self.start))
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
