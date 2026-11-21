package engine_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/rs/zerolog"

	"github.com/rcnsh/dmbar/internal/core"
	"github.com/rcnsh/dmbar/internal/engine"
	"github.com/rcnsh/dmbar/internal/fake"
)

var (
	me    = core.User{ID: 1, Username: "me", Name: "Me"}
	alice = core.User{ID: 2, Username: "alice", Name: "Alice"}
	t0    = time.UnixMilli(1_700_000_000_000)
)

func inbox() []core.Thread {
	return []core.Thread{
		{ID: 10, Title: "Old", LastActivity: t0},
		{ID: 20, Title: "Alice", Members: []core.User{alice}, LastActivity: t0.Add(time.Hour), Messages: []core.Message{
			{ID: "m1", Thread: 20, Sender: alice.ID, At: t0, Text: "older"},
			{ID: "m2", Thread: 20, Sender: alice.ID, At: t0.Add(time.Hour), Text: "newest"},
		}},
	}
}

// harness is an engine over fake parts. backends holds each backend made.
type harness struct {
	*engine.Engine
	sessions *fake.Sessions
	backends chan *fake.Backend
}

func start(t *testing.T, saved bool, script func(*fake.Backend)) *harness {
	t.Helper()
	h := &harness{sessions: &fake.Sessions{}, backends: make(chan *fake.Backend, 4)}
	if saved {
		h.sessions.Saved = &core.Session{Auth: core.AuthData("saved")}
	}
	h.Engine = engine.New(engine.Options{
		Log:      zerolog.Nop(),
		Sessions: h.sessions,
		NewBackend: func() core.Backend {
			b := &fake.Backend{Me: me, Threads: inbox()}
			if script != nil {
				script(b)
			}
			h.backends <- b
			return b
		},
		NewLogin: func() engine.Login { return fake.Login{Me: me} },
	})
	t.Cleanup(h.Close)
	h.Start()
	return h
}

// until reads events until one satisfies ok, failing after two seconds.
func until(t *testing.T, ch <-chan any, what string, ok func(any) bool) {
	t.Helper()
	deadline := time.After(2 * time.Second)
	for {
		select {
		case ev, open := <-ch:
			if !open {
				t.Fatalf("subscription closed before %s", what)
			}
			if ok(ev) {
				return
			}
		case <-deadline:
			t.Fatalf("timed out waiting for %s", what)
		}
	}
}

func connected(ev any) bool {
	s, ok := ev.(engine.StatusEvent)
	return ok && s.State == engine.Connected
}

func waitConnected(t *testing.T, h *harness) (<-chan any, *fake.Backend) {
	t.Helper()
	snap, ch, cancel := h.Subscribe()
	t.Cleanup(cancel)
	if snap.State != engine.Connected {
		until(t, ch, "connected", connected)
	}
	return ch, <-h.backends
}

func TestRestoreAndLiveMessage(t *testing.T) {
	h := start(t, true, nil)
	ch, b := waitConnected(t, h)

	snap := h.Snapshot()
	if snap.Me != me || len(snap.Threads) != 2 || snap.Threads[0].ID != 20 {
		t.Fatalf("snapshot = %+v, want me and both threads, newest first", snap)
	}
	if got := snap.Threads[0].Messages; len(got) != 1 || got[0].ID != "m2" {
		t.Fatalf("thread keeps %v, want only its newest message", got)
	}

	// A message from Alice in the older thread moves it up and marks it unread.
	msg := core.Message{ID: "m3", Thread: 10, Sender: alice.ID, At: t0.Add(2 * time.Hour), Text: "hi"}
	b.Emit(core.ThreadRead{Thread: 10, Until: t0})
	b.Emit(core.MessageAdded{Message: msg})
	until(t, ch, "the message", func(ev any) bool { _, ok := ev.(core.MessageAdded); return ok })
	top := h.Snapshot().Threads[0]
	if top.ID != 10 || !top.Unread || top.Messages[0].ID != "m3" || !top.LastActivity.Equal(msg.At) {
		t.Fatalf("after a new message the top thread is %+v", top)
	}

	if err := h.MarkRead(context.Background(), msg); err != nil {
		t.Fatal(err)
	}
	if h.Snapshot().Threads[0].Unread {
		t.Fatal("thread still unread after MarkRead")
	}
	if _, read := b.Calls(); len(read) != 1 || read[0] != "m3" {
		t.Fatalf("backend marked %v read, want m3", read)
	}

	// The user's own message, sent from another device, isn't unread.
	b.Emit(core.MessageAdded{Message: core.Message{ID: "m4", Thread: 10, Sender: me.ID, At: t0.Add(3 * time.Hour)}})
	until(t, ch, "own message", func(ev any) bool {
		m, ok := ev.(core.MessageAdded)
		return ok && m.Message.ID == "m4"
	})
	if h.Snapshot().Threads[0].Unread {
		t.Fatal("own message marked the thread unread")
	}
}

func TestSendUsesOrMakesAnOTID(t *testing.T) {
	h := start(t, true, nil)
	_, b := waitConnected(t, h)
	got, err := h.Send(context.Background(), 20, "hello", "", "")
	if err != nil || got != "otid-1" {
		t.Fatalf("Send = %q, %v; want a new otid", got, err)
	}
	got, err = h.Send(context.Background(), 20, "again", "mine", "")
	if err != nil || got != "mine" {
		t.Fatalf("Send = %q, %v; want the caller's otid", got, err)
	}
	if sent, _ := b.Calls(); len(sent) != 2 {
		t.Fatalf("backend sent %v", sent)
	}
}

func TestLoginThenLogout(t *testing.T) {
	h := start(t, false, nil)
	if s := h.Snapshot(); s.State != engine.LoggedOut {
		t.Fatalf("state with nothing saved = %s", s.State)
	}
	if _, err := h.Send(context.Background(), 20, "x", "", ""); !errors.Is(err, engine.ErrNotLoggedIn) {
		t.Fatalf("Send while logged out = %v, want ErrNotLoggedIn", err)
	}
	if _, err := h.LoginSubmit(context.Background(), nil); !errors.Is(err, engine.ErrNoLogin) {
		t.Fatalf("LoginSubmit with no login = %v, want ErrNoLogin", err)
	}
	if _, err := h.LoginCookies(context.Background(), map[string]string{}); !errors.Is(err, core.ErrSessionExpired) {
		t.Fatalf("LoginCookies without cookies = %v", err)
	}

	step, err := h.LoginCookies(context.Background(), map[string]string{"sessionid": "abc"})
	if err != nil || step.Result == nil || step.Result.Me != me {
		t.Fatalf("LoginCookies = %+v, %v", step, err)
	}
	if saved, _ := h.sessions.Get(); saved == nil || string(saved.Auth) != "auth:abc" {
		t.Fatalf("saved session = %v, want the login's", saved)
	}
	_, b := waitConnected(t, h)

	if err := h.Logout(); err != nil {
		t.Fatal(err)
	}
	s := h.Snapshot()
	if s.State != engine.LoggedOut || s.Me != (core.User{}) || len(s.Threads) != 0 {
		t.Fatalf("after Logout: %+v", s)
	}
	// The stopped backend must not save its login again over the deletion.
	if saved, _ := h.sessions.Get(); saved != nil || !b.Closed() {
		t.Fatalf("after Logout: saved=%v closed=%v", saved, b.Closed())
	}
}

func TestCloseSavesTheLogin(t *testing.T) {
	h := start(t, true, nil)
	waitConnected(t, h)
	h.Close()
	if saved, _ := h.sessions.Get(); saved == nil || string(saved.Auth) != "exported" {
		t.Fatalf("after Close the saved login is %v, want the backend's export", saved)
	}
}

func TestExpiredLoginStopsRetrying(t *testing.T) {
	h := start(t, true, func(b *fake.Backend) { b.SnapshotErr = core.ErrSessionExpired })
	snap, ch, cancel := h.Subscribe()
	defer cancel()
	if snap.State != engine.LoginRequired {
		until(t, ch, "login_required", func(ev any) bool {
			s, ok := ev.(engine.StatusEvent)
			return ok && s.State == engine.LoginRequired && s.Error != ""
		})
	}
	if _, err := h.Send(context.Background(), 20, "x", "", ""); !errors.Is(err, engine.ErrNotLoggedIn) {
		t.Fatalf("Send with an expired login = %v, want ErrNotLoggedIn", err)
	}
	// A new login recovers.
	if _, err := h.LoginCookies(context.Background(), map[string]string{"sessionid": "new"}); err != nil {
		t.Fatal(err)
	}
	if s := h.Snapshot().State; s == engine.LoginRequired || s == engine.LoggedOut {
		t.Fatalf("state after a new login = %s", s)
	}
}

func TestSlowSubscriberIsDropped(t *testing.T) {
	h := start(t, true, nil)
	_, b := waitConnected(t, h)
	_, slow, cancel := h.Subscribe()
	defer cancel()
	for i := range 400 {
		b.Emit(core.Typing{Thread: 20, User: alice.ID, Active: i%2 == 0})
	}
	// The engine must keep going: a fresh subscriber still sees new events.
	_, fresh, cancelFresh := h.Subscribe()
	defer cancelFresh()
	b.Emit(core.ThreadMuted{Thread: 20, Muted: true})
	until(t, fresh, "an event after the flood", func(ev any) bool { _, ok := ev.(core.ThreadMuted); return ok })
	deadline := time.After(2 * time.Second)
	for {
		select {
		case _, open := <-slow:
			if !open {
				return
			}
		case <-deadline:
			t.Fatal("the slow subscriber was never closed")
		}
	}
}

func thread(h *harness, id core.ThreadID) core.Thread {
	for _, t := range h.Snapshot().Threads {
		if t.ID == id {
			return t
		}
	}
	return core.Thread{}
}

// flush waits until the engine has applied everything emitted so far.
func flush(t *testing.T, ch <-chan any, b *fake.Backend) {
	t.Helper()
	b.Emit(core.Typing{Thread: 999, User: 999})
	until(t, ch, "the marker", func(ev any) bool { ty, ok := ev.(core.Typing); return ok && ty.Thread == 999 })
}

func TestRedeliveredAndLateMessagesDontMarkUnread(t *testing.T) {
	h := start(t, true, nil)
	ch, b := waitConnected(t, h)
	msg := core.Message{ID: "m3", Thread: 20, Sender: alice.ID, At: t0.Add(2 * time.Hour)}
	b.Emit(core.MessageAdded{Message: msg})
	flush(t, ch, b)
	if err := h.MarkRead(context.Background(), msg); err != nil {
		t.Fatal(err)
	}
	b.Emit(core.MessageAdded{Message: msg}) // delivered again
	b.Emit(core.MessageAdded{Message: core.Message{ID: "m1", Thread: 20, Sender: alice.ID, At: t0}})
	flush(t, ch, b)
	if got := thread(h, 20); got.Unread || got.Messages[0].ID != "m3" {
		t.Fatalf("after a repeat and a late message: unread=%v newest=%s", got.Unread, got.Messages[0].ID)
	}
}

func TestMarkReadWhenActivityIsLaterThanTheNewestMessage(t *testing.T) {
	h := start(t, true, func(b *fake.Backend) {
		b.Threads[1].Unread = true
		b.Threads[1].LastActivity = t0.Add(time.Hour + time.Second) // e.g. a reaction
	})
	waitConnected(t, h)
	if err := h.MarkRead(context.Background(), thread(h, 20).Messages[0]); err != nil {
		t.Fatal(err)
	}
	if thread(h, 20).Unread {
		t.Fatal("thread still unread after its newest message was marked read")
	}
}

func TestThreadUpdatedIsPublishedAsStored(t *testing.T) {
	h := start(t, true, func(b *fake.Backend) { b.Threads[1].Muted = true })
	ch, b := waitConnected(t, h)
	b.Emit(core.ThreadUpdated{Thread: core.Thread{ID: 20, Title: "Renamed", LastActivity: t0.Add(time.Hour)}})
	var pub core.Thread
	until(t, ch, "the update", func(ev any) bool {
		u, ok := ev.(core.ThreadUpdated)
		pub = u.Thread
		return ok
	})
	got := thread(h, 20)
	if pub.Title != "Renamed" || !pub.Muted || len(pub.Messages) != 1 || got.Muted != pub.Muted || len(got.Messages) != 1 {
		t.Fatalf("published %+v, stored %+v; want both renamed, still muted, message kept", pub, got)
	}
}

func TestReactionsReachTheNewestMessage(t *testing.T) {
	h := start(t, true, nil)
	ch, b := waitConnected(t, h)
	b.Emit(core.ReactionAdded{Thread: 20, Message: "m2", Reaction: core.Reaction{User: alice.ID, Emoji: "a", ID: "r1"}})
	b.Emit(core.ReactionAdded{Thread: 20, Message: "m2", Reaction: core.Reaction{User: alice.ID, Emoji: "b", ID: "r2"}})
	b.Emit(core.ReactionAdded{Thread: 20, Message: "older", Reaction: core.Reaction{User: alice.ID, Emoji: "c", ID: "r3"}})
	flush(t, ch, b)
	if got := thread(h, 20).Messages[0].Reactions; len(got) != 1 || got[0].Emoji != "b" {
		t.Fatalf("reactions = %+v, want only Alice's latest", got)
	}
	b.Emit(core.ReactionRemoved{Thread: 20, Message: "other", ID: "r2"}) // names only the reaction
	flush(t, ch, b)
	if got := thread(h, 20).Messages[0].Reactions; len(got) != 0 {
		t.Fatalf("reactions after removal = %+v", got)
	}
}

// failingSessions fails Save once fail is set.
type failingSessions struct {
	*fake.Sessions
	fail bool
}

func (s *failingSessions) Save(v core.Session) error {
	if s.fail {
		return errors.New("keychain says no")
	}
	return s.Sessions.Save(v)
}

func TestLoginThatCantBeSavedLeavesNothingLoggedIn(t *testing.T) {
	sessions := &failingSessions{Sessions: &fake.Sessions{Saved: &core.Session{Auth: core.AuthData("saved")}}}
	e := engine.New(engine.Options{
		Log: zerolog.Nop(), Sessions: sessions,
		NewBackend: func() core.Backend { return &fake.Backend{Me: me, Threads: inbox()} },
		NewLogin:   func() engine.Login { return fake.Login{Me: me} },
	})
	t.Cleanup(e.Close)
	e.Start()
	snap, ch, cancel := e.Subscribe()
	defer cancel()
	if snap.State != engine.Connected {
		until(t, ch, "connected", connected)
	}
	sessions.fail = true
	if _, err := e.LoginCookies(context.Background(), map[string]string{"sessionid": "new"}); err == nil {
		t.Fatal("LoginCookies succeeded though the login couldn't be saved")
	}
	s := e.Snapshot()
	if s.State != engine.LoginRequired || s.Error == "" || s.Me != (core.User{}) || len(s.Threads) != 0 {
		t.Fatalf("state after the failed save: %+v", s)
	}
	until(t, ch, "a state event", func(ev any) bool {
		sn, ok := ev.(engine.SnapshotEvent)
		return ok && sn.State == engine.LoginRequired
	})
}

// waitingLogin's Submit blocks until its context is done.
type waitingLogin struct{ fake.Login }

func (waitingLogin) Submit(ctx context.Context, _ map[string]string) (core.LoginStep, error) {
	<-ctx.Done()
	return core.LoginStep{}, ctx.Err()
}

func TestWaitingLoginDoesntBlockANewOne(t *testing.T) {
	e := engine.New(engine.Options{
		Log: zerolog.Nop(), Sessions: &fake.Sessions{},
		NewBackend: func() core.Backend { return &fake.Backend{Me: me, Threads: inbox()} },
		NewLogin:   func() engine.Login { return waitingLogin{fake.Login{Me: me}} },
	})
	t.Cleanup(e.Close)
	if _, err := e.LoginStart(context.Background()); err != nil {
		t.Fatal(err)
	}
	stuck, release := context.WithCancel(context.Background())
	defer release()
	go e.LoginSubmit(stuck, nil) //nolint:errcheck // it only waits
	time.Sleep(50 * time.Millisecond)

	done := make(chan error, 2)
	go func() { _, err := e.LoginStart(context.Background()); done <- err }()
	go func() {
		_, err := e.LoginCookies(context.Background(), map[string]string{"sessionid": "abc"})
		done <- err
	}()
	for range 2 {
		select {
		case err := <-done:
			if err != nil {
				t.Fatal(err)
			}
		case <-time.After(2 * time.Second):
			t.Fatal("a new login waited behind the stuck one")
		}
	}
}

func TestStartThenCloseManyTimes(t *testing.T) {
	for range 300 {
		e := engine.New(engine.Options{
			Log: zerolog.Nop(), Sessions: &fake.Sessions{Saved: &core.Session{Auth: core.AuthData("saved")}},
			NewBackend: func() core.Backend { return &fake.Backend{Me: me, Threads: inbox()} },
			NewLogin:   func() engine.Login { return fake.Login{Me: me} },
		})
		e.Start()
		e.Close()
	}
}
