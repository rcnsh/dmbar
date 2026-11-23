# dmbar

Instagram DMs in the macOS menu bar. Personal tool for one user and one account, installed on his Mac only: no notarisation, no updater, no release builds. The repo is public (github.com/rcnsh/dmbar), so nothing in it may hold real account data: tests, docs and screenshots use the made-up inbox in `internal/fake`. README screenshots are in `docs/screenshots`; retake them with `make app-demo` and the window capture below when the UI changes visibly. The Go daemon `dmbard` is at the root; the Swift app is in `app/`. README.md has the layout and what v1 covers.

## Before finishing a change

Run `make check`. It must pass. For anything visible, look at it: `make app-demo` opens the real app on a made-up inbox (`DMBAR_ROUTE=settings`, `menu` for the right-click menu, or a thread ID such as `101`, picks the screen). Never test against the real account by sending messages; Jacob does the real sends.

To screenshot the popover, capture its window only, never the screen: find the window ID of the `Dmbar` process with `CGWindowListCopyWindowInfo` and pass it to `screencapture -x -o -l <id>`. A lone window capture shows the glass as opaque.

## The app (`app/`)

- SwiftPM, built into a bundle by `app/build.sh`, the way terminus's Mac app is. Swift 6 with main-actor default isolation; types that cross actors or are tested as values are marked `nonisolated`.
- `Inbox` is a value type holding everything known about the account. Events from the daemon go in through `apply`; it makes no calls, so its tests need nothing running. `AppModel` owns it, the `Client` and the `Daemon` process, and is the only thing views call.
- `DaemonTests` runs the Swift client against the real `bin/dmbard -demo`, so a wire-format change that breaks the app fails a test.
- Liquid Glass goes on the controls layer only (buttons, the composer, chips, toasts). Message bubbles and list rows are plain fills: glass on scrolling content is costly and hard to read.
- The popover hangs from the menu bar item. A menu bar manager can hide the item, leaving its window with no height, so `show()` falls back to an invisible anchor under the menu bar. Jacob runs Thaw, so this path is the usual one on his Mac.
- NSApplication holds its delegate weakly: keep `Main.delegate` static.
- The composer is an `NSTextView` (`ComposerField`), driven through the `Composer` object, not a SwiftUI `TextField`. Text or caret changes made to a `TextField`'s binding while keys were arriving didn't always reach the screen: a sent message stayed in the field and went out again, and an inserted emoji was typed over or crashed on a stale caret. Change the composer's text only through `Composer`.
- `:shortcode:` names and the picker's emoji come from GitHub's gemoji. `EmojiData.swift` is generated: rerun `app/Support/make-emoji.sh` to update it, never edit it.
- Photos load straight from Instagram's CDN (no login needed) into `ImageCache`, in memory only. The URLs expire, which is fine while history is fetched fresh each launch. A file opened in Preview goes to `$TMPDIR/dmbar-opened`, emptied on first use each run; Save to Downloads is the only lasting copy.
- Read receipts off: opening a conversation records the newest message's time in `Inbox.seenMs` (saved in UserDefaults) and tells Instagram nothing. The unread mark is `thread.unread && newest > seen`.

## Rules

- The HTTP API is the contract with the app. `docs/api.md` and `internal/api` change together.
- Only `internal/instagram` imports `go.mau.fi/mautrix-meta`. Everything it returns is a `core` type.
- Before touching anything about thread or user IDs, read `docs/instagram-ids.md`. A thread has three IDs and each call wants a particular one.
- `instameow` is an unstable internal API of the upstream bridge. `docs/instameow.md` records how it behaves at the pinned version; check the pinned source in the module cache before relying on a detail, and update that file when it changes.
- Never log or commit cookies, the API token or message text. Login errors must not quote what the user pasted.
- Files with a termeownal copyright header came from it. Keep the header when editing them, and the first time one is changed, add `// Modified for dmbar in 2026; its git history has the changes.` under its copyright line (AGPL §5a). New files get the dmbar header that `internal/instagram/cookies.go` has.
- The licence is AGPL-3.0 and has to stay that way while the code links `mautrix-meta`.

## Design decisions

- **A separate daemon, not a library in the app.** The protocol code is Go and changes upstream every month. A process boundary lets the app be Swift and lets `go get -u go.mau.fi/mautrix-meta` be the whole fix when Instagram changes something.
- **HTTP and server-sent events on loopback, with a bearer token.** `URLSession` speaks both, and `curl` can drive it. The token is needed because any local program or web page can reach a loopback port. The app passes it in `DMBAR_TOKEN`, never in arguments.
- **No message cache.** The daemon starts cold on each launch, keeps the first inbox page and each thread's newest message in memory, and fetches history from Instagram on demand. So it saves no event sequence ID, and nothing is replayed at start. If the app needs offline history or missed-message catch-up, that is when to add a store; termeownal's `internal/store` and its pump show how the sequence ID has to be saved only after the events before it.
- **The login is a file, not a Keychain item.** Cookies plus cached client state are too big for one. The file is encrypted under a random key that is in the Keychain.
- **IDs are strings and times are milliseconds in JSON**, so 64-bit IDs survive any reader and a message's time is exact when marking it read.

## Updating upstream

`go get go.mau.fi/mautrix-meta@main && go mod tidy && make check`. The `replace` for `github.com/imroc/req/v3` in `go.mod` must match the one in mautrix-meta's `go.mod`. If the build breaks, the fix is in `internal/instagram`; termeownal's history is a good reference for how it adapted to the same change.

## `termeownal/`

A reference checkout of ericliswan/termeownal, ignored by git. The extraction is done, so nothing reads from it; delete the folder and its `.gitignore` entry when it stops being useful.
