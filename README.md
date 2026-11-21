# dmbar

Instagram DMs as a small macOS menu bar box, with notifications and replying.

This repo holds the backend so far: `dmbard`, a local daemon that logs in to Instagram, keeps the live connection up and serves a small HTTP API on loopback. The menu bar app is built on top of that API and isn't written yet.

Personal project. It uses Instagram's unofficial web protocol, which Instagram's terms don't allow: the account can be challenged or locked.

## How it fits together

```
menu bar app (to build)
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

## Running it

Needs Go 1.26 or newer.

```sh
make run     # 127.0.0.1:7878, token "dev", debug logs
make check   # gofmt, vet, tests with the race detector
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
