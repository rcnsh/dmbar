// dmbar — Instagram DMs in the macOS menu bar.
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version. See LICENSE.

package engine

import (
	"context"
	"fmt"

	"github.com/rcnsh/dmbar/internal/core"
)

// LoginStart begins an interactive login, dropping any in progress, and
// returns its first step.
func (e *Engine) LoginStart(ctx context.Context) (core.LoginStep, error) {
	f := &flow{Login: e.opts.NewLogin()}
	e.loginMu.Lock()
	e.login = f
	e.loginMu.Unlock()
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.Start(ctx)
}

// LoginSubmit answers the current step. When the returned step has Result
// set, the login is saved and the account is connecting. It returns
// ErrNoLogin if another login replaced this one while it waited.
func (e *Engine) LoginSubmit(ctx context.Context, values map[string]string) (core.LoginStep, error) {
	e.loginMu.Lock()
	f := e.login
	e.loginMu.Unlock()
	if f == nil {
		return core.LoginStep{}, ErrNoLogin
	}
	f.mu.Lock()
	step, err := f.Submit(ctx, values)
	f.mu.Unlock()
	if err != nil || step.Result == nil {
		return step, err
	}
	e.loginMu.Lock()
	replaced := e.login != f
	if !replaced {
		e.login = nil
	}
	e.loginMu.Unlock()
	if replaced {
		return core.LoginStep{}, ErrNoLogin
	}
	return e.finish(step)
}

// LoginCookies logs in with Instagram's cookies by name, as taken from a web
// view that ran the login. It replaces any login in progress.
func (e *Engine) LoginCookies(ctx context.Context, cookies map[string]string) (core.LoginStep, error) {
	e.loginMu.Lock()
	e.login = nil
	e.loginMu.Unlock()
	step, err := e.opts.NewLogin().Cookies(ctx, cookies)
	if err != nil || step.Result == nil {
		return step, err
	}
	return e.finish(step)
}

// finish saves a finished login and starts its account.
func (e *Engine) finish(step core.LoginStep) (core.LoginStep, error) {
	s := core.Session{Auth: step.Result.Auth}
	e.life.Lock()
	defer e.life.Unlock()
	e.end(true) // before the save, so the old account's last save can't follow it
	if err := e.opts.Sessions.Save(s); err != nil {
		// The old account is stopped and the new one can't be kept, so
		// nothing is logged in.
		err = fmt.Errorf("save login: %w", err)
		e.reset(LoginRequired, err)
		return core.LoginStep{}, err
	}
	e.begin(s, step.Result.Me)
	return step, nil
}

// Logout stops the account and deletes the saved login. It doesn't end the
// session on Instagram's side.
func (e *Engine) Logout() error {
	e.life.Lock()
	defer e.life.Unlock()
	e.end(true)
	err := e.opts.Sessions.Delete()
	e.reset(LoggedOut, nil)
	return err
}

// backend returns the running backend and a context bounded by callTimeout.
func (e *Engine) backend(ctx context.Context) (core.Backend, context.Context, context.CancelFunc, error) {
	e.mu.Lock()
	r, closed, state := e.run, e.closed, e.state
	e.mu.Unlock()
	switch {
	case closed:
		return nil, nil, nil, ErrClosed
	case r == nil || state == LoginRequired:
		return nil, nil, nil, ErrNotLoggedIn
	}
	ctx, cancel := context.WithTimeout(ctx, callTimeout)
	return r.b, ctx, cancel, nil
}

// History returns up to n messages of thread older than before, oldest
// first, and whether older ones remain. An empty before means the newest.
func (e *Engine) History(ctx context.Context, thread core.ThreadID, before core.MessageID, n int) ([]core.Message, bool, error) {
	b, ctx, cancel, err := e.backend(ctx)
	if err != nil {
		return nil, false, err
	}
	defer cancel()
	return b.History(ctx, thread, before, n)
}

// NewOTID returns a fresh ID for a send. A caller that picks it before
// sending can retry with the same one even when the first attempt's reply
// never arrived.
func (e *Engine) NewOTID() (string, error) {
	b, _, cancel, err := e.backend(context.Background())
	if err != nil {
		return "", err
	}
	cancel()
	return b.NewOTID(), nil
}

// Send sends text to thread, as a reply to replyTo unless it is "". otid
// identifies the send: pass the same one to retry without a duplicate, or ""
// for a new one. It returns the otid used; the sent message arrives as a
// MessageAdded carrying it.
func (e *Engine) Send(ctx context.Context, thread core.ThreadID, text, otid string, replyTo core.MessageID) (string, error) {
	b, ctx, cancel, err := e.backend(ctx)
	if err != nil {
		return "", err
	}
	defer cancel()
	if otid == "" {
		otid = b.NewOTID()
	}
	return otid, b.Send(ctx, thread, text, otid, replyTo)
}

// MarkRead marks upTo's thread read up to and including upTo, which needs
// its ID, Thread and At.
func (e *Engine) MarkRead(ctx context.Context, upTo core.Message) error {
	b, ctx, cancel, err := e.backend(ctx)
	if err != nil {
		return err
	}
	defer cancel()
	if err := b.MarkRead(ctx, upTo); err != nil {
		return err
	}
	// Instagram doesn't always echo our own read, so apply it here too.
	read := core.ThreadRead{Thread: upTo.Thread, Until: upTo.At}
	e.mu.Lock()
	defer e.mu.Unlock()
	e.readLocked(read.Thread, read.Until)
	e.publishLocked(read)
	return nil
}

// React sets the user's reaction to msg, or with remove clears it; emoji is
// then the reaction being cleared.
func (e *Engine) React(ctx context.Context, thread core.ThreadID, msg core.MessageID, emoji string, remove bool) error {
	b, ctx, cancel, err := e.backend(ctx)
	if err != nil {
		return err
	}
	defer cancel()
	return b.React(ctx, thread, msg, emoji, remove)
}

// Edit replaces the text of one of the user's own messages.
func (e *Engine) Edit(ctx context.Context, thread core.ThreadID, msg core.MessageID, text string) error {
	b, ctx, cancel, err := e.backend(ctx)
	if err != nil {
		return err
	}
	defer cancel()
	return b.Edit(ctx, thread, msg, text)
}

// Unsend takes back one of the user's own messages, for everyone.
func (e *Engine) Unsend(ctx context.Context, thread core.ThreadID, msg core.MessageID) error {
	b, ctx, cancel, err := e.backend(ctx)
	if err != nil {
		return err
	}
	defer cancel()
	return b.Unsend(ctx, thread, msg)
}

// Mute turns thread's notifications off on Instagram until turned on again,
// or with muted false turns them on.
func (e *Engine) Mute(ctx context.Context, thread core.ThreadID, muted bool) error {
	b, ctx, cancel, err := e.backend(ctx)
	if err != nil {
		return err
	}
	defer cancel()
	if err := b.Mute(ctx, thread, muted); err != nil {
		return err
	}
	// An echo isn't certain, so apply it once Instagram accepts it.
	ev := core.ThreadMuted{Thread: thread, Muted: muted}
	e.mu.Lock()
	defer e.mu.Unlock()
	if t, ok := e.threads[thread]; ok {
		t.Muted = muted
		e.threads[thread] = t
	}
	e.publishLocked(ev)
	return nil
}

// Typing tells thread's members whether the user is typing. It needs the
// live connection.
func (e *Engine) Typing(ctx context.Context, thread core.ThreadID, active bool) error {
	b, ctx, cancel, err := e.backend(ctx)
	if err != nil {
		return err
	}
	defer cancel()
	return b.Typing(ctx, thread, active)
}
