// dmbar — Instagram DMs in the macOS menu bar.
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version. See LICENSE.

// Package fake is a core.Backend, a login and a session store that never
// touch the network or the Keychain, for tests.
package fake

import (
	"context"
	"errors"
	"strconv"
	"sync"
	"time"

	"github.com/rcnsh/dmbar/internal/core"
)

// Backend is a scripted core.Backend. Set its fields before it is used;
// Emit plays a live event.
type Backend struct {
	Me      core.User
	Threads []core.Thread
	// SnapshotErr, if set, fails every Snapshot.
	SnapshotErr error
	// SendErr, if set, fails every Send.
	SendErr error
	Older   []core.Message
	// Histories, if it has the thread, is its full history, oldest first,
	// and History pages through it.
	Histories map[core.ThreadID][]core.Message
	// Echo makes Send play the sent message back as a live event, as
	// Instagram does.
	Echo bool

	mu     sync.Mutex
	closed bool
	otid   int
	// Sent holds the text of each Send, Read the ID of each MarkRead.
	Sent []string
	Read []core.MessageID

	once   sync.Once
	events chan core.Event
	done   chan struct{}
}

var _ core.Backend = (*Backend)(nil)

func (b *Backend) init() {
	b.once.Do(func() {
		b.events = make(chan core.Event, 64)
		b.done = make(chan struct{})
	})
}

// Emit plays ev as a live event.
func (b *Backend) Emit(ev core.Event) {
	b.init()
	b.events <- ev
}

// Closed reports whether Close was called.
func (b *Backend) Closed() bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.closed
}

// Calls returns what was sent and what was marked read.
func (b *Backend) Calls() (sent []string, read []core.MessageID) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return append([]string{}, b.Sent...), append([]core.MessageID{}, b.Read...)
}

func (b *Backend) Restore(_ context.Context, s core.Session) error {
	b.init()
	if len(s.Auth) == 0 {
		return core.ErrSessionExpired
	}
	return nil
}

func (b *Backend) Snapshot(context.Context) (core.User, []core.Thread, error) {
	if b.SnapshotErr != nil {
		return core.User{}, nil, b.SnapshotErr
	}
	return b.Me, b.Threads, nil
}

func (b *Backend) History(_ context.Context, thread core.ThreadID, before core.MessageID, n int) ([]core.Message, bool, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	all, ok := b.Histories[thread]
	if !ok {
		return b.Older, false, nil
	}
	end := len(all)
	if before != "" {
		for i, m := range all {
			if m.ID == before {
				end = i
			}
		}
	}
	start := max(0, end-n)
	return append([]core.Message{}, all[start:end]...), start > 0, nil
}

func (b *Backend) NewOTID() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.otid++
	return "otid-" + strconv.Itoa(b.otid)
}

func (b *Backend) Send(_ context.Context, thread core.ThreadID, text, otid string, replyTo core.MessageID) error {
	if b.SendErr != nil {
		return b.SendErr
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	b.Sent = append(b.Sent, text)
	if b.Echo && !b.closed {
		m := core.Message{
			ID: core.MessageID("sent-" + otid), Thread: thread, Sender: b.Me.ID, At: time.Now(),
			Text: text, ContentType: "TEXT", OTID: otid, ReplyTo: core.Quote{ID: replyTo},
		}
		b.Histories[thread] = append(b.Histories[thread], m)
		select {
		case b.events <- core.MessageAdded{Message: m}:
		default:
		}
	}
	return nil
}

func (b *Backend) MarkRead(_ context.Context, upTo core.Message) error {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.Read = append(b.Read, upTo.ID)
	return nil
}

func (*Backend) React(context.Context, core.ThreadID, core.MessageID, string, bool) error {
	return nil
}
func (*Backend) Edit(context.Context, core.ThreadID, core.MessageID, string) error { return nil }
func (*Backend) Unsend(context.Context, core.ThreadID, core.MessageID) error       { return nil }
func (*Backend) Mute(context.Context, core.ThreadID, bool) error                   { return nil }
func (*Backend) Typing(context.Context, core.ThreadID, bool) error                 { return nil }

// Connect reports Connected, then blocks until ctx is done or Close.
func (b *Backend) Connect(ctx context.Context) error {
	b.init()
	// Under the lock, so it can't send on a channel Close is closing.
	b.mu.Lock()
	if b.closed {
		b.mu.Unlock()
		return nil
	}
	select {
	case b.events <- core.StatusChanged{Status: core.Connected}:
	default: // full; the test isn't reading
	}
	b.mu.Unlock()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-b.done:
		return nil
	}
}

func (b *Backend) Events() <-chan core.Event {
	b.init()
	return b.events
}

func (*Backend) ExportAuth() (core.AuthData, error) { return core.AuthData("exported"), nil }

func (b *Backend) Close() {
	b.init()
	b.mu.Lock()
	defer b.mu.Unlock()
	if !b.closed {
		b.closed = true
		close(b.done)
		close(b.events)
	}
}

// Sessions is an in-memory session store.
type Sessions struct {
	mu    sync.Mutex
	Saved *core.Session
	// Saves counts Save calls.
	Saves int
}

func (s *Sessions) Load() (core.Session, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.Saved == nil {
		return core.Session{}, errors.New("fake: no session")
	}
	return *s.Saved, nil
}

func (s *Sessions) Save(v core.Session) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.Saved, s.Saves = &v, s.Saves+1
	return nil
}

func (s *Sessions) Delete() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.Saved = nil
	return nil
}

// Get returns the saved session and how many times one was saved.
func (s *Sessions) Get() (*core.Session, int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.Saved, s.Saves
}

// Login is a login that accepts any cookies with a sessionid, as Me.
type Login struct{ Me core.User }

func (Login) Start(context.Context) (core.LoginStep, error) {
	return core.LoginStep{Fields: []core.LoginField{{ID: "sessionid", Label: "sessionid", Secret: true}}}, nil
}

func (l Login) Submit(ctx context.Context, values map[string]string) (core.LoginStep, error) {
	return l.Cookies(ctx, values)
}

func (l Login) Cookies(_ context.Context, values map[string]string) (core.LoginStep, error) {
	if values["sessionid"] == "" {
		return core.LoginStep{}, core.ErrSessionExpired
	}
	return core.LoginStep{Result: &core.LoginResult{Me: l.Me, Auth: core.AuthData("auth:" + values["sessionid"])}}, nil
}
