# Working with `instameow`

Notes on the upstream library the Instagram backend wraps, taken from termeownal's `AGENTS.md` §6 at commit `bb046f1` and trimmed to what dmbar uses. "The pump" is `internal/engine` here.


Names below are from `mautrix/meta` `main` as of 27 Oct 2026. Upstream is an **internal, unstable API**: verify against the pinned version before relying on a detail, and update this section when it changes.

### 6.1 Client
`instameow.NewClient(instameow.ClientParams{Cookies, Log, Settings, EventHandler, SeqID, SeqIDTS, DisableTyping, NativeSession})`. `Cookies` is a `*cookies.Cookies{Platform: types.Instagram}` from `pkg/messagix/cookies`. Leave `DisableTyping` unset: it stops incoming typing too, so `send_typing = false` (§7.7) is applied in `app`, which then never calls `Backend.Typing`. See `igconnector/login.go` → `getInstaClient` for a working example.

Other client methods: `LoadState`, `DumpState`, `SetSeqID`, `HasSeqID`, `GetOwnFBID`, `GetCookies`, `IsAuthenticated`, `SetLogger`, `SetEventHandler`, `GetHTTP`.

### 6.2 Calls

| Need | Call |
|---|---|
| Login check + full snapshot | `LoadIndex(ctx)` → viewer, mailbox |
| Refresh tokens only | `ReloadIndex(ctx)` |
| Threads | `GetMailbox`, `PaginateMailbox` |
| One thread | `GetThread(ctx, slidetypes.MakeGetThreadInfoRequest(shortID))` |
| History | `PaginateMessages(&PaginateMessagesRequest{ThreadID: shortID, OlderThanMessageID, FirstN})` |
| Send text | `SendMessage(&SendTextRequest{IGThreadIGID: &shortID, Text, OfflineThreadingID, ReplyToMessageID})`; first message to a new user: `RecipientIGIDs: []string{userFBID}` and no `IGThreadIGID` |
| Mark read | `MarkRead(req)` then `MarkReadValidation(req)`, `req.Metadata.IGThreadIGID = longID`, `req.Data.MessageID` |
| Typing out | `SetTyping(ctx, shortID, bool)` (no-op when `DisableTyping` is set; fails before `Connect`) |
| Search / new DM | `SearchUsers`, `GetUserForNewDM(ctx, fbid)`, `GetProfile`, `FetchThreadID(ctx, userFBID)` |
| Reactions, edit, unsend | `SendReaction` (short ID), `EditMessage` (short ID, new OTID), `UnsendMessage` (**long** ID in `SendData.ThreadID`) |
| Mute | `MuteThread` (short ID; `MuteSeconds` -1 forever, 0 unmutes; new OTID) |
| Message requests | `AcceptMessageRequest` |
| Media | `FetchMedia`; sending = `GetHTTP().SendMercuryUploadRequest` then `SendMedia` |
| ID lookup | `FetchThreadID(ctx, threadKey)` → `ThreadIGIDs{LongID, ShortID}` (verified with 1:1 keys) |
| Socket | `Connect(ctx)`, `Disconnect()`, `ForceReconnect()` |
| Generate OTID | `methods.GenerateEpochID()` (`pkg/messagix/methods`) |

### 6.3 ⚠️ Thread IDs — read this before touching anything thread-related

| `ThreadInfo` field | Type | Call it | Used by |
|---|---|---|---|
| `ThreadKey` | int64 | **key** | `core.ThreadID`; `FetchThreadID`. 1:1: the **other user's FBID**. Group: **equal to the short ID**. |
| `ID` | string | **short ID** (JSON `id`; equals `thread_fbid`) | `PaginateMessages`, `GetThread`, `SendMessage`, `SetTyping`, **and every live delta** |
| `ThreadID` | string | **long ID** (JSON `thread_id`; 39 digits, keep as a string) | `MarkRead`, incoming typing notifications |

- The delta field is named `ThreadIGID` but its JSON tag is `thread_fbid` — it holds the **short** ID. If empty, fall back to `Message.ThreadFBID`. Trust JSON tags, not Go field names.
- Deltas with an empty `thread_fbid` are ignored types (e.g. `Create1To1Thread`); don't look them up.
- Typing notifications carry the **long** ID and the sender's **IGID**, so keep long → key and IGID → FBID maps too (from thread user lists, which exclude the viewer). An unknown long ID or IGID is logged at `debug` and dropped: typing is transient, not worth a lookup.
- `ids.go` maintains `key ↔ short ↔ long` in memory from every mailbox, thread and `FetchThreadID` response; it isn't persisted. Unknown short ID in a delta → `GetThread`, store mappings, send the thread as `ThreadUpdated`, then apply the delta. A key with no mapping (e.g. a cached thread opened before the first `Snapshot`) → `FetchThreadID(key)`, and if that fails `GetThread(key)` (a group's key is its short ID): the adapter can't tell a 1:1 key from a group's.
- Users: `core.UserID` = FBID (`SenderFBID`, `GetOwnFBID`); store IGID and username alongside. A thread's `users` list excludes the viewer.
- `docs/ids.md` is the verified source of truth. Read it before touching IDs.

### 6.4 Events and durability
The handler receives `slidetypes.ClientEvent`: `Connected`, `Disconnected`, `ReconnectionStateUpdate`, `SeqIDUpdate`, `ResnapshotRequired`, `AuthError`, `TypingNotification`, and `Delta` (wrapping `NewMessageEvent`, `AdminMessageEvent`, `EditMessageEvent`, `DeleteMessageEvent`, `Create/DeleteReactionEvent`, `ReadReceiptEvent`, `MarkRead/UnreadEvent`, `DeleteThreadEvent`, `UpdateThreadName/Image/FolderEvent`, `ParticipantJoin/LeaveEvent`, `AdminChangeEvent`, `MuteThreadEvent`, `PinThread/MessageEvent`, `UnknownEvent`, `IgnoredEvent`).

How upstream calls it (`instameow/socket.go`): once per delta in a batch, **then** one `SeqIDUpdate` for the batch. Live batches are usually one delta; the catch-up after connect is one large batch. A handler error makes the socket reconnect.

Rules:
- Translate and push onto a buffered channel. If full, **block** (with `ctx`). Never drop.
- `SeqIDUpdate` → `core.SeqAdvanced` on the **same channel**. The pump saves the seq ID only after the preceding deltas are written, so a crash can't save a seq ID ahead of stored data.
- Delivery is **at-least-once**: deltas after the last saved seq ID are replayed on connect, and some (`ReadReceipt`, `MarkRead`) arrive twice anyway. Applying a delta twice must be harmless: upsert by message ID, keep the highest watermark, match echoes by OTID.
- Return an error only for real failures (e.g. cancelled context, or `GetThread` failing for an unknown short ID, so the delta is delivered again). Log unknown events at `debug` and return `nil`.
- Keep the handler free of disk work. Its only network call is `GetThread`, for an unknown short ID or a thread rename.
- `ReconnectionStateUpdate` and `AuthError` arrive on the goroutine of whichever call is running (`LoadIndex` sends the new state), so they never wait on the channel: the adapter keeps them in fields.
- `ResnapshotRequired`, or a refresh falling due (§6.5), → `Connect` returns `nil` after sending `ResyncNeeded`. `AuthError`, or `Disconnected` with an unauthorized error, → `Connect` stops and returns `ErrSessionExpired`, as does every later `Connect`.

### 6.5 Resume logic (mirror `igconnector/client.go` → `connectWithRetry`)
1. (termeownal shows its SQLite cache here. dmbar has no cache and always starts cold, so only the cold path below runs at launch; warm starts happen on the 20 h refresh.)
2. Build the client with saved cookies; `SetSeqID` if saved.
3. **Fast:** saved state, `LoadState` succeeds, `HasSeqID()`.
   **Warm:** seq ID but state unusable (`ErrCachedStateTooOld` after 24 h) → `ReloadIndex`, save `DumpState()`.
   **Cold:** no seq ID → `LoadIndex`, save state.
4. Store a fresh mailbox, **then** `Connect`: the pump stores `Backend.Snapshot` (`LoadIndex`'s mailbox on a cold start, otherwise `GetMailbox`) before it asks for a connection, so live events always apply on top of it. Don't refresh the mailbox in the background after `Connected`: it would race the replay. After `Connected`, gap-fill the open thread (the UI reloads its newest page and marks the other threads' stale).
5. `ErrPleaseReloadPage` → delete saved state, cold start.

`Restore` does steps 2 and the `LoadState` half of 3 without touching the network; `Snapshot` makes the calls. A cold start's seq ID waits until `Connect`, since `Snapshot` never sends events.
6. Force a full reconnect every 20 h (config `force_refresh_interval`, 0 disables), never more than once an hour. Like upstream's `FullReconnect(false, true)`, it drops the saved state and keeps the seq ID: `Connect` cancels the client's `Connect`, sends `ResyncNeeded` and returns `nil`, and the next `Snapshot` is a warm start on the same client. A cancelled `Client.Connect` can be called again; `Disconnect` can't. `ForceReconnect()` on detected sleep/wake (wall-clock jump > 2 min past a 30 s tick, read with `Round(0)`: the monotonic clock stops while a Mac sleeps).
7. Reconnect backoff when the library gives up: 1 s doubling to 60 s, with jitter. The pump retries a failed `Snapshot` or `Connect` this way, except on the auth errors of §6.6, and starts the backoff again after a connection that lasted over a minute.

### 6.6 Errors
| Error | Handling |
|---|---|
| `httpclient.ErrRateLimited` | "Instagram is rate-limiting this account…"; back off |
| `ErrChallengeRequired`, `ErrCheckpointRequired` | "Instagram wants to verify this login. Complete the check in the app or website, then log in again." |
| `ErrConsentRequired` | "Accept Instagram's pending terms, then retry." |
| `ErrAccountSuspended` | "This account is suspended." |
| `ErrTokenInvalidated`, `types.ErrorResponse` code `1357053`, `AuthError` event | `AuthFailed` → state `login_required` |
| `ErrCachedStateTooOld`, `ErrPleaseReloadPage` | silent: drop state, cold start |
| `ErrThreadNotFound` (new DM) | not an error: show empty chat |
| anything else | generic message + log path; wrap with `%w` |

Check with `errors.Is` / `errors.As`, never by string matching.

### 6.7 Upstream code to read before implementing
| Area | File(s) |
|---|---|
| Cookie login | `pkg/igconnector/login.go` (`loginWithCookies`, `submitInstagramCookies`) |
| Password login | `pkg/igconnector/login_native.go`; `pkg/instameow/login_web*.go`, `login_account_manager.go` |
| Connect / resume / refresh | `pkg/igconnector/client.go` |
| Inbox processing | `pkg/igconnector/chatsync.go`, `client.go` (`processMailbox`) |
| Deltas, ID resolution | `pkg/igconnector/handlemeta.go` (`ensurePortal`, `getAndResyncThread`) |
| Sending, IDs, mark read | `pkg/igconnector/handlematrix.go`, `startchat.go` |
| History | `pkg/igconnector/backfill.go` |
| Content types | `pkg/instameow/slidetypes/messagecontent.go`, `pkg/msgconv/` |
| Log redaction | `pkg/instameow/redactlog.go`, `slidetypes.SensitiveString` |

Read upstream to learn; never copy `igconnector` wholesale and never import it.

---

