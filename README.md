# dmbar

Instagram DMs as a small macOS menu bar box, with notifications and replying.

Two parts: `dmbard`, a Go daemon that logs in to Instagram, keeps the live connection up and serves a small HTTP API on loopback; and the menu bar app in `app/`, native Swift with Liquid Glass, which starts the daemon and talks only to that API.

v1 reads and sends text: the inbox, conversations with history, replies, reactions and read state shown, typing both ways, notifications with an inline reply. Photos, reels and voice notes show as a labelled placeholder. Starting a conversation, message requests and sending media aren't there yet.

Personal project. It uses Instagram's unofficial web protocol, which Instagram's terms don't allow: the account can be challenged or locked.

## How it fits together

```
app/                the menu bar app (SwiftUI in an NSPopover), macOS 26+
      │  HTTP + server-sent events on 127.0.0.1, bearer token   → docs/api.md
cmd/dmbard
      │
internal/api        JSON and event stream
internal/engine     one account: login, reconnects, inbox in memory, event fan-out
internal/session    the login on disk, encrypted under a Keychain key
internal/instagram  the Instagram backend, taken from termeownal
internal/core       the types and interfaces between the two, taken from termeownal
      │
go.mau.fi/mautrix-meta/pkg/instameow   the protocol itself (upstream)
```

`internal/core` and `internal/instagram` come from [termeownal](https://github.com/ericliswan/termeownal) at commit `bb046f1`, with its tests. They are the part that knows how to drive `instameow`: restoring a session, loading the inbox, the three kinds of thread ID, turning Instagram's deltas into events, reconnecting after sleep. termeownal's terminal UI, SQLite cache and passphrase fallback were left behind.

## The app

Needs Go 1.26 or newer and Xcode 26 or newer.

```sh
make install    # build, copy to /Applications/dmbar.app and open
make app-demo   # the built app on a made-up inbox, popover open; no account
make check      # gofmt, vet, Go tests with the race detector, Swift tests
```

The app lives in the menu bar only. Log in on Instagram's own page from the welcome screen; the session is kept on this Mac. ⌃⌥I opens it from anywhere, and the shortcut, read receipts, typing indicator, notifications and launch at login are in its settings. If a menu bar manager hides the icon, the shortcut still opens the box, hanging from the top right of the screen.

The daemon's log is `~/Library/Logs/dmbar/dmbard.log`.

## The daemon on its own

```sh
make run     # 127.0.0.1:7878, token "dev", debug logs
make demo    # the same on a made-up inbox
make build   # bin/dmbard
```

With `make run` going:

```sh
curl -s -H 'Authorization: Bearer dev' 127.0.0.1:7878/v1/state
curl -N -H 'Authorization: Bearer dev' 127.0.0.1:7878/v1/events
```

To log in by hand, copy the `sessionid`, `csrftoken`, `ds_user_id`, `mid` and `ig_did` cookies from a browser logged in to instagram.com:

```sh
curl -s -H 'Authorization: Bearer dev' 127.0.0.1:7878/v1/login/cookies \
  -d '{"cookies":{"sessionid":"…","csrftoken":"…","ds_user_id":"…","mid":"…","ig_did":"…"}}'
```

The login is saved in `~/Library/Application Support/dmbar` and restored on the next start.

## Docs

- [docs/api.md](docs/api.md): the HTTP API.
- [docs/instameow.md](docs/instameow.md): how the upstream library behaves and how the backend uses it.
- [docs/instagram-ids.md](docs/instagram-ids.md): the thread and user IDs, verified against a real account by termeownal.

## Licence

AGPL-3.0, because `mautrix-meta` and termeownal are. The files taken from termeownal keep its copyright notice.
