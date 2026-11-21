# dmbar

Instagram DMs in the macOS menu bar. Personal tool for one user and one account. The Go daemon `dmbard` exists; the menu bar app does not yet. README.md has the layout.

## Before finishing a change

Run `make check`. It must pass.

## Rules

- The HTTP API is the contract with the app. `docs/api.md` and `internal/api` change together.
- Only `internal/instagram` imports `go.mau.fi/mautrix-meta`. Everything it returns is a `core` type.
- Before touching anything about thread or user IDs, read `docs/instagram-ids.md`. A thread has three IDs and each call wants a particular one.
- `instameow` is an unstable internal API of the upstream bridge. `docs/instameow.md` records how it behaves at the pinned version; check the pinned source in the module cache before relying on a detail, and update that file when it changes.
- Never log or commit cookies, the API token or message text. Login errors must not quote what the user pasted.
- Files with a termeownal copyright header came from it. Keep the header when editing them.
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
