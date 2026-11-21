// dmbar — Instagram DMs in the macOS menu bar.
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version. See LICENSE.

// Package engine runs one Instagram account: it restores the saved login,
// keeps the live connection up, holds the inbox in memory and fans events
// out to subscribers. It is the layer the HTTP API sits on.
//
// It follows termeownal's pump (internal/app/pump.go there) without the
// SQLite cache: dmbar starts cold on every launch and keeps only each
// thread's newest message, so there is nothing to replay and no event
// sequence ID to save.
package engine

import (
	"cmp"
	"context"
	"errors"
	"fmt"
	"math/rand/v2"
	"slices"
	"sync"
	"sync/atomic"
	"time"

	"github.com/rs/zerolog"

	"github.com/rcnsh/dmbar/internal/core"
)

// State is where the account is.
type State string

// Account states.
const (
	// LoggedOut means no login is saved.
	LoggedOut State = "logged_out"
	// LoginRequired means the saved login stopped working.
	LoginRequired State = "login_required"
	Connecting    State = "connecting"
	Connected     State = "connected"
	Reconnecting  State = "reconnecting"
)

var (
	// ErrNotLoggedIn means the call needs a working login.
	ErrNotLoggedIn = errors.New("not logged in")
	// ErrNoLogin means LoginSubmit was called with no login in progress.
	ErrNoLogin = errors.New("no login in progress")
	// ErrClosed means the engine was closed.
	ErrClosed = errors.New("engine closed")
)

// callTimeout bounds one call to Instagram, so a stalled one can't hold up
// the caller.
const callTimeout = 30 * time.Second

// subBuffer is how many events wait for a subscriber before it is dropped.
const subBuffer = 256

// Sessions is where the login is saved.
type Sessions interface {
	// Load returns the saved login, or an error if there is none to use.
	Load() (core.Session, error)
	Save(core.Session) error
	Delete() error
}

// Login is an interactive login that can also take cookies directly.
type Login interface {
	core.Authenticator
	Cookies(ctx context.Context, values map[string]string) (core.LoginStep, error)
}

// Options configure an Engine. All fields are required.
type Options struct {
	Log        zerolog.Logger
	Sessions   Sessions
	NewBackend func() core.Backend
	NewLogin   func() Login
}

// Snapshot is the whole state at one moment.
type Snapshot struct {
	State State
	// Error is the last failure, in words; empty once things work again.
	Error string
	// Me is the zero User while logged out.
	Me core.User
	// Threads are the inbox, most recent activity first. Each holds at most
	// its newest message.
	Threads []core.Thread
}

// StatusEvent means State or Error changed.
type StatusEvent struct {
	State State
	Error string
}

// SnapshotEvent replaces everything a subscriber knows: after a login, a
// logout or a fresh inbox load.
type SnapshotEvent struct{ Snapshot }

// Engine runs one account. Its methods are safe for concurrent use.
type Engine struct {
	opts Options
	wait func(n int) time.Duration

	// life serialises Start, a finished login, Logout and Close.
	life sync.Mutex
	// loginMu guards login, the login in progress. It is never held across
	// a call to Instagram, so a new login can always replace a stuck one.
	loginMu sync.Mutex
	login   *flow

	mu      sync.Mutex
	closed  bool
	state   State
	errText string
	me      core.User
	threads map[core.ThreadID]core.Thread
	run     *run
	subs    map[chan any]struct{}
}

// flow is one interactive login. mu makes its steps take turns, as a Login
// isn't safe for concurrent use.
type flow struct {
	mu sync.Mutex
	Login
}

// run is one backend and the goroutines serving it.
type run struct {
	b      core.Backend
	cancel context.CancelFunc
	done   chan struct{}
	// discard is set when the run ends because its login is being replaced
	// or deleted, so its login data must not be saved again.
	discard atomic.Bool
}

// New returns an Engine. Call Start to restore the saved login.
func New(opts Options) *Engine {
	return &Engine{opts: opts, wait: backoff, state: LoggedOut, subs: map[chan any]struct{}{}}
}

// Start restores the saved login, if there is one, and begins connecting.
// It returns at once; progress arrives as events.
func (e *Engine) Start() {
	e.life.Lock()
	defer e.life.Unlock()
	s, err := e.opts.Sessions.Load()
	if err != nil {
		// Nothing saved, or nothing readable: either way, log in.
		e.opts.Log.Info().Err(err).Msg("no saved login")
		return
	}
	e.begin(s, core.User{})
}

// begin starts a backend from session s for account me, replacing the one
// running. life must be held.
func (e *Engine) begin(s core.Session, me core.User) {
	e.end(true)
	b := e.opts.NewBackend()
	if err := b.Restore(context.Background(), s); err != nil {
		b.Close()
		e.reset(LoginRequired, err)
		return
	}
	ctx, cancel := context.WithCancel(context.Background())
	r := &run{b: b, cancel: cancel, done: make(chan struct{})}
	e.mu.Lock()
	if e.closed {
		e.mu.Unlock()
		cancel()
		b.Close()
		return
	}
	e.run, e.me, e.threads = r, me, nil
	e.state, e.errText = Connecting, ""
	e.publishLocked(SnapshotEvent{e.snapshotLocked()})
	e.mu.Unlock()
	go e.pump(ctx, r)
}

// end stops the running backend, if there is one, and waits for it. With
// discard its login data isn't saved on the way out. life must be held.
func (e *Engine) end(discard bool) {
	e.mu.Lock()
	r := e.run
	e.run = nil
	e.mu.Unlock()
	if r == nil {
		return
	}
	r.discard.Store(discard)
	r.cancel()
	r.b.Close() // closes Events, which ends the pump
	<-r.done
}

// pump loads the inbox, then applies events until the backend closes its
// Events channel. It is the only reader of that channel.
func (e *Engine) pump(ctx context.Context, r *run) {
	defer close(r.done)
	connect := make(chan struct{}, 1)
	var wg sync.WaitGroup
	wg.Go(func() { e.connectLoop(ctx, r, connect) })
	e.sync(ctx, r, connect)
	for ev := range r.b.Events() {
		e.apply(ctx, r, ev, connect)
	}
	// Login data can change without a SessionChanged, so save it once more.
	if !r.discard.Load() {
		e.saveAuth(r)
	}
	wg.Wait()
}

// sync loads the inbox from the backend, then asks for a connection. A
// failure is retried with backoff until ctx is done, unless logging in again
// is the fix.
func (e *Engine) sync(ctx context.Context, r *run, connect chan<- struct{}) {
	var me core.User
	var threads []core.Thread
	for n := 0; ; n++ {
		var err error
		if me, threads, err = r.b.Snapshot(ctx); err == nil {
			break
		}
		if ctx.Err() != nil {
			return
		}
		e.report(fmt.Errorf("load inbox: %w", err))
		if AuthError(err) || !sleep(ctx, e.wait(n)) {
			return
		}
	}
	e.mu.Lock()
	if me.Username == "" && me.ID == e.me.ID {
		me = e.me // a warm start doesn't say the username
	}
	e.me, e.errText = me, ""
	e.threads = make(map[core.ThreadID]core.Thread, len(threads))
	for _, t := range threads {
		e.threads[t.ID] = newestOnly(t)
	}
	e.publishLocked(SnapshotEvent{e.snapshotLocked()})
	e.mu.Unlock()
	select {
	case connect <- struct{}{}:
	default: // a connection is already pending
	}
}

// connectLoop runs the live connection each time sync asks for one, until
// ctx is done. Connect reconnects on its own, so an error means it gave up:
// it is called again with backoff, unless logging in again is the fix.
func (e *Engine) connectLoop(ctx context.Context, r *run, connect <-chan struct{}) {
	for {
		select {
		case <-ctx.Done():
			return
		case <-connect:
		}
		for n := 0; ; n++ {
			began := time.Now()
			err := r.b.Connect(ctx)
			if err == nil || ctx.Err() != nil {
				break
			}
			e.report(fmt.Errorf("connection: %w", err))
			if AuthError(err) {
				break
			}
			if time.Since(began) > maxBackoff {
				n = 0 // it worked for a while, so start the backoff again
			}
			if !sleep(ctx, e.wait(n)) {
				return
			}
		}
	}
}

// apply folds ev into the state and passes it on to subscribers.
func (e *Engine) apply(ctx context.Context, r *run, ev core.Event, connect chan<- struct{}) {
	switch ev := ev.(type) {
	case core.SeqAdvanced:
		return // nothing is stored, so there is nothing to resume from
	case core.SessionChanged:
		e.saveAuth(r)
		return
	case core.ResyncNeeded:
		// The connection has ended; it's back once Connect reports it.
		e.setStatus(Connecting, nil)
		e.sync(ctx, r, connect)
		return
	case core.AuthFailed:
		e.report(ev.Err)
		return
	case core.StatusChanged:
		e.setStatus(map[core.Status]State{
			core.Connecting: Connecting, core.Connected: Connected, core.Reconnecting: Reconnecting,
		}[ev.Status], nil)
		return
	}

	e.mu.Lock()
	defer e.mu.Unlock()
	switch ev := ev.(type) {
	case core.ThreadUpdated:
		t := newestOnly(ev.Thread)
		if old, ok := e.threads[t.ID]; ok {
			t.Muted = old.Muted // only a snapshot or ThreadMuted says
			if len(t.Messages) == 0 {
				t.Messages = old.Messages
			}
		}
		e.setThreadLocked(t)
		ev.Thread = t // subscribers get what the state holds
		e.publishLocked(ev)
		return
	case core.MessageAdded:
		if t, ok := e.threads[ev.Message.Thread]; ok {
			last := lastMessage(t)
			switch {
			case last != nil && last.ID == ev.Message.ID:
				// Delivered again: nothing changes.
			case last == nil || ev.Message.At.After(last.At):
				// Only a message newer than the newest changes whether the
				// thread is unread; a late older one doesn't.
				t.Messages = []core.Message{ev.Message}
				t.Unread = ev.Message.Sender != e.me.ID
			}
			if ev.Message.At.After(t.LastActivity) {
				t.LastActivity = ev.Message.At
			}
			e.threads[t.ID] = t
		}
	case core.ThreadRead:
		e.readLocked(ev.Thread, ev.Until)
	case core.ReactionAdded:
		e.editLastLocked(ev.Thread, ev.Message, func(m *core.Message) {
			kept := slices.DeleteFunc(slices.Clone(m.Reactions), func(r core.Reaction) bool { return r.User == ev.Reaction.User })
			m.Reactions = append(kept, ev.Reaction)
		})
	case core.ReactionRemoved:
		// The removal may name only the reaction's ID, and a message that
		// isn't the one reacted to, so look on the newest message whatever
		// its ID.
		if t, ok := e.threads[ev.Thread]; ok && len(t.Messages) > 0 {
			e.editLastLocked(ev.Thread, t.Messages[0].ID, func(m *core.Message) {
				m.Reactions = slices.DeleteFunc(slices.Clone(m.Reactions), func(r core.Reaction) bool {
					if ev.ID != "" {
						return r.ID == ev.ID
					}
					return m.ID == ev.Message && r.User == ev.User
				})
			})
		}
	case core.ReadReceipt:
		if t, ok := e.threads[ev.Thread]; ok && ev.UpTo.After(t.ReadUpTo[ev.User]) {
			upTo := make(map[core.UserID]time.Time, len(t.ReadUpTo)+1)
			for u, at := range t.ReadUpTo {
				upTo[u] = at
			}
			upTo[ev.User] = ev.UpTo
			t.ReadUpTo = upTo
			e.threads[t.ID] = t
		}
	case core.ThreadMuted:
		if t, ok := e.threads[ev.Thread]; ok {
			t.Muted = ev.Muted
			e.threads[t.ID] = t
		}
	case core.MessageEdited:
		e.editLastLocked(ev.Thread, ev.Message, func(m *core.Message) {
			if ev.At.After(m.EditedAt) {
				m.Text, m.EditedAt = ev.Text, ev.At
			}
		})
	case core.MessageUnsent:
		e.editLastLocked(ev.Thread, ev.Message, func(m *core.Message) {
			m.Unsent, m.Text, m.ContentType, m.Reactions = true, "", "", nil
		})
	}
	e.publishLocked(ev)
}

// readLocked marks thread read if until reaches its newest message, or its
// last activity when no message is known. The last activity can be later
// than the newest message, as a reaction counts as activity.
func (e *Engine) readLocked(thread core.ThreadID, until time.Time) {
	t, ok := e.threads[thread]
	if !ok {
		return
	}
	newest := t.LastActivity
	if last := lastMessage(t); last != nil {
		newest = last.At
	}
	if !until.Before(newest) {
		t.Unread = false
		e.threads[thread] = t
	}
}

// reset replaces the whole state and tells subscribers. No backend may be
// running.
func (e *Engine) reset(s State, err error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.state, e.errText, e.me, e.threads = s, "", core.User{}, nil
	if err != nil {
		e.errText = err.Error()
	}
	e.publishLocked(SnapshotEvent{e.snapshotLocked()})
}

// editLastLocked changes thread's newest message if it is message id.
func (e *Engine) editLastLocked(thread core.ThreadID, id core.MessageID, change func(*core.Message)) {
	t, ok := e.threads[thread]
	if !ok || len(t.Messages) == 0 || t.Messages[0].ID != id {
		return
	}
	m := t.Messages[0]
	change(&m)
	t.Messages = []core.Message{m}
	e.threads[thread] = t
}

func (e *Engine) setThreadLocked(t core.Thread) {
	if e.threads == nil {
		e.threads = map[core.ThreadID]core.Thread{}
	}
	e.threads[t.ID] = t
}

// newestOnly returns t holding only its newest message.
func newestOnly(t core.Thread) core.Thread {
	if n := len(t.Messages); n > 1 {
		t.Messages = []core.Message{t.Messages[n-1]}
	}
	return t
}

func lastMessage(t core.Thread) *core.Message {
	if len(t.Messages) == 0 {
		return nil
	}
	return &t.Messages[len(t.Messages)-1]
}

// saveAuth saves r's current login data.
func (e *Engine) saveAuth(r *run) {
	auth, err := r.b.ExportAuth()
	if err == nil {
		err = e.opts.Sessions.Save(core.Session{Auth: auth})
	}
	if err != nil {
		e.opts.Log.Warn().Err(err).Msg("login not saved")
	}
}

// report records a failure: LoginRequired if logging in again is the fix,
// otherwise the same state with the error in words.
func (e *Engine) report(err error) {
	e.opts.Log.Error().Err(err).Msg("sync failed")
	e.mu.Lock()
	state := e.state
	e.mu.Unlock()
	if AuthError(err) {
		state = LoginRequired
	}
	e.setStatus(state, err)
}

// setStatus sets the state and error and tells subscribers if either
// changed. LoginRequired stays until a new login.
func (e *Engine) setStatus(s State, err error) {
	text := ""
	if err != nil {
		text = err.Error()
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.state == LoginRequired && s != LoginRequired {
		return
	}
	if e.state == s && e.errText == text {
		return
	}
	e.state, e.errText = s, text
	e.publishLocked(StatusEvent{State: s, Error: text})
}

// AuthError reports whether logging in again is the fix for err, so
// retrying is pointless.
func AuthError(err error) bool {
	for _, auth := range []error{core.ErrSessionExpired, core.ErrVerificationRequired, core.ErrConsentRequired, core.ErrAccountSuspended} {
		if errors.Is(err, auth) {
			return true
		}
	}
	return false
}

// Snapshot returns the current state.
func (e *Engine) Snapshot() Snapshot {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.snapshotLocked()
}

func (e *Engine) snapshotLocked() Snapshot {
	threads := make([]core.Thread, 0, len(e.threads))
	for _, t := range e.threads {
		threads = append(threads, t)
	}
	slices.SortFunc(threads, func(a, b core.Thread) int {
		return cmp.Or(b.LastActivity.Compare(a.LastActivity), cmp.Compare(a.ID, b.ID))
	})
	return Snapshot{State: e.state, Error: e.errText, Me: e.me, Threads: threads}
}

// Subscribe returns the current state and a channel of what happens after
// it: core.Event values, StatusEvent and SnapshotEvent, in order. The
// channel is closed by cancel, by Close, or when the subscriber falls
// subBuffer events behind; it should then subscribe again.
func (e *Engine) Subscribe() (Snapshot, <-chan any, func()) {
	ch := make(chan any, subBuffer)
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.closed {
		close(ch)
		return e.snapshotLocked(), ch, func() {}
	}
	e.subs[ch] = struct{}{}
	return e.snapshotLocked(), ch, func() {
		e.mu.Lock()
		defer e.mu.Unlock()
		if _, ok := e.subs[ch]; ok {
			delete(e.subs, ch)
			close(ch)
		}
	}
}

func (e *Engine) publishLocked(ev any) {
	for ch := range e.subs {
		select {
		case ch <- ev:
		default:
			delete(e.subs, ch)
			close(ch)
		}
	}
}

// Close stops the account and closes every subscription. The login stays
// saved.
func (e *Engine) Close() {
	e.life.Lock()
	defer e.life.Unlock()
	e.end(false)
	e.mu.Lock()
	defer e.mu.Unlock()
	e.closed = true
	for ch := range e.subs {
		delete(e.subs, ch)
		close(ch)
	}
}

// maxBackoff is the longest wait between retries.
const maxBackoff = time.Minute

// backoff is the wait before retry n: 1 s doubling to a minute, less up to a
// fifth at random.
func backoff(n int) time.Duration {
	d := min(time.Second<<min(n, 6), maxBackoff)
	return d - rand.N(d/5)
}

// sleep waits for d, or returns false once ctx is done.
func sleep(ctx context.Context, d time.Duration) bool {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-t.C:
		return true
	}
}
