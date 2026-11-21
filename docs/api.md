# dmbard API

`dmbard` serves this on a loopback port. It is the only interface between the menu bar app and Instagram. `internal/api` implements it; change the two together.

## Starting the daemon

```sh
DMBAR_TOKEN=<random> dmbard -exit-with-stdin
```

It prints one JSON line on stdout once it is listening, then logs to stderr:

```json
{"addr":"127.0.0.1:53211"}
```

| Flag | Default | Meaning |
|---|---|---|
| `-addr` | `127.0.0.1:0` | Loopback address. Port 0 picks a free one, reported in the ready line. |
| `-data-dir` | `~/Library/Application Support/dmbar` | Holds the encrypted login (`session.enc`) and a lock file. One daemon per directory. |
| `-log-level` | `info` | `debug`, `info`, `warn` or `error`. |
| `-exit-with-stdin` | off | Exit when stdin closes, so the daemon ends with the app that started it. |
| `-demo` | off | Serve a made-up inbox with no account, no network and no files. Sent messages echo back. For working on the app. |

The app passes the token in `DMBAR_TOKEN`. Without it, `dmbard` makes one up and adds `"token"` to the ready line; that is for running it by hand.

## Requests

Every request needs `Authorization: Bearer <token>`. Bodies and replies are JSON.

- IDs are strings. Thread and user IDs are 64-bit numbers; message IDs are opaque.
- Times are Unix milliseconds, `0` for none.
- A successful call with nothing to return replies `{}`.

Errors reply with a status and:

```json
{"error":{"code":"rate_limited","message":"send: rate limited: ..."}}
```

| Code | Status | Meaning |
|---|---|---|
| `unauthorized` | 401 | Missing or wrong token. |
| `bad_request` | 400 | The path, query or body is wrong. |
| `not_found` | 404 | No such endpoint, or the wrong method for it. |
| `not_logged_in` | 409 | No working login. Log in first. |
| `no_login_in_progress` | 409 | `login/submit` without `login/start`. |
| `session_expired` | 409 | Instagram no longer accepts the login. |
| `verification_required` | 409 | Instagram wants a check done in its app or website. |
| `consent_required` | 409 | Pending terms must be accepted on Instagram. |
| `account_suspended` | 409 | The account can't be used. |
| `rate_limited` | 429 | Wait before trying again. |
| `timeout` | 504 | Instagram didn't answer within 30 s. |
| `instagram` | 502 | Anything else Instagram or the network did. |
| `shutting_down` | 503 | The daemon is exiting. |

## State

### `GET /v1/state`

```json
{
  "state": "connected",
  "error": "",
  "me": {"id": "17841400000000001", "username": "me", "name": "Me", "avatar_url": ""},
  "threads": [
    {
      "id": "17841400000000002",
      "title": "Alice",
      "is_group": false,
      "image_url": "",
      "members": [{"id": "17841400000000002", "username": "alice", "name": "Alice", "avatar_url": "https://…"}],
      "last_activity_ms": 1700000000123,
      "unread": true,
      "muted": false,
      "last_message": { "...": "a message, or null" },
      "read_up_to_ms": {"17841400000000002": 1700000000000}
    }
  ]
}
```

`state` is one of:

| State | Meaning |
|---|---|
| `logged_out` | No login is saved. `me` is null. |
| `login_required` | The saved login stopped working; `error` says why. Log in again. |
| `connecting` | Loading the inbox or opening the live connection. |
| `connected` | Live. |
| `reconnecting` | The connection dropped and is being retried. |

`error` is the last failure in words, empty once things work. `threads` is the first page of the inbox, most recent activity first. `members` excludes the logged-in user. `avatar_url` is a member's profile picture and `image_url` a group's own picture; either can be empty, and both are signed links that expire, so fetch them when shown rather than storing them. `me.avatar_url` is always empty. `read_up_to_ms` says how far each other member has read.

A message:

```json
{
  "id": "mid.$abc",
  "thread_id": "17841400000000002",
  "sender_id": "17841400000000002",
  "at_ms": 1700000000123,
  "text": "hi",
  "content_type": "TEXT",
  "otid": "7123456789012345678",
  "reply_to": {"id": "mid.$xyz", "sender_id": "17841400000000001", "text": "quoted", "content_type": "TEXT"},
  "reactions": [{"user_id": "17841400000000001", "emoji": "❤", "id": "mid.$r1"}],
  "edited_at_ms": 0,
  "unsent": false,
  "media": [{"kind": "image", "url": "https://scontent.cdninstagram.com/…", "preview_url": "https://…", "width": 1080, "height": 1350}]
}
```

`text` is empty for non-text messages: show something for `content_type` instead, or `media` when it isn't empty. `reply_to` is null when the message isn't a reply. `otid` is the ID the sender chose when sending; see Send.

`media` lists the photos, videos, GIFs and stickers a message carries, in order, and is `[]` otherwise. `kind` is `image`, `video`, `gif` or `sticker`. `url` is the full image, or the video or animation to play; `preview_url` is a still for it. Either can be `""`, not both. `width` and `height` are the preview's pixel size, 0 if unknown. The URLs point at Instagram's CDN, need no login, and are signed to expire, so don't keep them: fetching the history again gives fresh ones. View-once photos and videos are left out, so opening one here can't use up its view.

### `GET /v1/events`

A server-sent event stream. The first event is `state`, with the same body as `GET /v1/state`, so a client needs nothing else to start. Events after it are in order. A comment line arrives every 25 s while idle.

The stream ends if the client falls 256 events behind or the daemon exits. Reconnect; the new `state` event replaces everything.

| Event | Body | Meaning |
|---|---|---|
| `state` | as `GET /v1/state` | Replaces everything: sent first, and after a login, a logout or a reloaded inbox. |
| `status` | `{state, error}` | The state or error changed. |
| `message_added` | `{message}` | A new message, or the echo of one sent from here or another device. |
| `thread_updated` | `{thread}` | A thread's details: sent before the first message of a thread not in the inbox yet, and on a rename. |
| `thread_read` | `{thread_id, until_ms}` | The user read the thread, here or on another device. |
| `read_receipt` | `{thread_id, user_id, up_to_ms}` | Another member read up to that time. Can repeat or arrive late: keep the latest. |
| `typing` | `{thread_id, user_id, active}` | A member started or stopped typing. Without a stop, it ends a few seconds after the last start. |
| `reaction_added` | `{thread_id, message_id, reaction}` | A member reacted, replacing their earlier reaction to that message. |
| `reaction_removed` | `{thread_id, message_id, user_id, reaction_id}` | A reaction was removed. Instagram may name only the reaction: `user_id` is then `"0"` and `message_id` may not be the message reacted to, so find the reaction by `reaction_id`. |
| `message_edited` | `{thread_id, message_id, text, at_ms}` | A message's text changed. Ignore one older than the message's `edited_at_ms`. |
| `message_unsent` | `{thread_id, message_id}` | A message was taken back. |
| `thread_muted` | `{thread_id, muted}` | The thread was muted or unmuted, here or on another device. |

Delivery is at least once: applying an event twice must change nothing. To notify, act on a `message_added` whose `sender_id` isn't `me.id`, in a thread that isn't muted.

## Login

The session is saved in the data directory, encrypted under a key in the Keychain, and restored when the daemon starts.

### `POST /v1/login/cookies`

The path for an app that runs Instagram's login in its own web view: read the cookies for `instagram.com` afterwards and pass them by name.

```json
{"cookies": {"sessionid": "...", "csrftoken": "...", "ds_user_id": "...", "mid": "...", "ig_did": "..."}}
```

`sessionid`, `csrftoken` and `ds_user_id` are required. `mid`, `ig_did`, `rur`, `shbid` and `shbts` are used if present; send them. The reply is a final login step (below), and a `state` event follows.

### `POST /v1/login/start` and `POST /v1/login/submit`

An interactive login, one step at a time, for a client without a web view. `start` takes no body and returns the first step. `submit` answers it and returns the next:

```json
{"values": {"login_method": "Username and password"}}
```

A step:

```json
{
  "instructions": "Log in with your Instagram username and password. ...",
  "fields": [
    {"id": "username", "label": "Email or username", "secret": false, "optional": false, "options": []},
    {"id": "password", "label": "Password", "secret": true, "optional": false, "options": []}
  ],
  "done": false,
  "me": null
}
```

Ask for each field and submit the answers keyed by `id`. A field with `options` takes only those values. A step with no fields and `done` false is a wait, such as for an approval in the Instagram app: show the instructions and submit `{"values": {}}` at once; the reply comes when the wait is over. `done` true ends the login and `me` is the account.

The password login ends with an error when Instagram asks for something only a browser can do, such as a CAPTCHA. Use the cookie login then.

### `POST /v1/logout`

Stops the account and deletes the saved login. It doesn't end the session on Instagram's side.

## Threads and messages

`{thread}` is a thread's `id`.

| Request | Body | Reply |
|---|---|---|
| `GET /v1/threads/{thread}/messages?before=<message id>&limit=<1-100>` | — | `{messages, more}` |
| `POST /v1/otid` | — | `{otid}` |
| `POST /v1/threads/{thread}/messages` | `{text, otid?, reply_to?}` | `{otid}` |
| `PATCH /v1/threads/{thread}/messages/{message}` | `{text}` | `{}` |
| `DELETE /v1/threads/{thread}/messages/{message}` | — | `{}` |
| `PUT /v1/threads/{thread}/messages/{message}/reaction` | `{emoji}` | `{}` |
| `DELETE /v1/threads/{thread}/messages/{message}/reaction` | `{emoji}` | `{}` |
| `POST /v1/threads/{thread}/read` | `{message_id, at_ms}` | `{}` |
| `POST /v1/threads/{thread}/mute` | `{muted}` | `{}` |
| `POST /v1/threads/{thread}/typing` | `{active}` | `{}` |

- **History** returns messages oldest first. Without `before` it returns the newest; `limit` defaults to 30. `more` says whether older ones remain. The daemon keeps no history, so each call goes to Instagram.
- **Send** succeeds when Instagram accepts the message. The message itself arrives as a `message_added` with the same `otid`: show it as pending until then. To retry a failed send, pass the `otid` the first attempt used, and Instagram won't duplicate it. A failed attempt returns none, so get one from `POST /v1/otid` before the first attempt and send with it.
- **Edit** and **unsend** work on the user's own messages and arrive back as `message_edited` and `message_unsent`.
- **Reaction**: a member has at most one reaction per message, so `PUT` replaces. `DELETE` must name the emoji being removed.
- **Read** takes the thread's newest message and its exact `at_ms`. A `thread_read` event follows.
- **Mute** changes the setting on Instagram, for every device.
- **Typing** needs the live connection. Send `active: false` when the user stops.

## Not there yet

Starting a new conversation, message requests, sending media, inbox pages past the first, and searching users. `instameow` has calls for all of them (`docs/instameow.md` §6.2).
