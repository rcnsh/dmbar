// dmbar — Instagram DMs in the macOS menu bar.
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version. See LICENSE.

// Package api serves the engine over HTTP on the loopback interface: JSON
// requests and a server-sent event stream. docs/api.md is its reference;
// change the two together.
package api

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/rs/zerolog"

	"github.com/rcnsh/dmbar/internal/core"
	"github.com/rcnsh/dmbar/internal/engine"
)

// maxBody caps a request body. Cookies and message text are far smaller.
const maxBody = 1 << 20

// heartbeat is how often an idle event stream sends a comment, so a dead
// connection is noticed.
const heartbeat = 25 * time.Second

// defaultHistory and maxHistory bound a page of messages.
const (
	defaultHistory = 30
	maxHistory     = 100
)

// Engine is the part of engine.Engine the API serves.
type Engine interface {
	Snapshot() engine.Snapshot
	Subscribe() (engine.Snapshot, <-chan any, func())
	LoginStart(ctx context.Context) (core.LoginStep, error)
	LoginSubmit(ctx context.Context, values map[string]string) (core.LoginStep, error)
	LoginCookies(ctx context.Context, cookies map[string]string) (core.LoginStep, error)
	Logout() error
	History(ctx context.Context, thread core.ThreadID, before core.MessageID, n int) ([]core.Message, bool, error)
	Send(ctx context.Context, thread core.ThreadID, text, otid string, replyTo core.MessageID) (string, error)
	MarkRead(ctx context.Context, upTo core.Message) error
	React(ctx context.Context, thread core.ThreadID, msg core.MessageID, emoji string, remove bool) error
	Edit(ctx context.Context, thread core.ThreadID, msg core.MessageID, text string) error
	Unsend(ctx context.Context, thread core.ThreadID, msg core.MessageID) error
	Mute(ctx context.Context, thread core.ThreadID, muted bool) error
	Typing(ctx context.Context, thread core.ThreadID, active bool) error
}

var _ Engine = (*engine.Engine)(nil)

// New returns the API's handler. Every request must carry token as a bearer
// token.
func New(e Engine, token string, log zerolog.Logger) http.Handler {
	s := &server{e: e, log: log}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/state", s.state)
	mux.HandleFunc("GET /v1/events", s.events)
	mux.HandleFunc("POST /v1/login/start", s.loginStart)
	mux.HandleFunc("POST /v1/login/submit", s.loginSubmit)
	mux.HandleFunc("POST /v1/login/cookies", s.loginCookies)
	mux.HandleFunc("POST /v1/logout", s.logout)
	mux.HandleFunc("GET /v1/threads/{thread}/messages", s.history)
	mux.HandleFunc("POST /v1/threads/{thread}/messages", s.send)
	mux.HandleFunc("PATCH /v1/threads/{thread}/messages/{message}", s.edit)
	mux.HandleFunc("DELETE /v1/threads/{thread}/messages/{message}", s.unsend)
	mux.HandleFunc("PUT /v1/threads/{thread}/messages/{message}/reaction", s.react)
	mux.HandleFunc("DELETE /v1/threads/{thread}/messages/{message}/reaction", s.unreact)
	mux.HandleFunc("POST /v1/threads/{thread}/read", s.read)
	mux.HandleFunc("POST /v1/threads/{thread}/mute", s.mute)
	mux.HandleFunc("POST /v1/threads/{thread}/typing", s.typing)
	// Catches unknown paths, and known paths with the wrong method, so every
	// reply is the documented JSON.
	mux.HandleFunc("/", func(w http.ResponseWriter, _ *http.Request) {
		fail(w, http.StatusNotFound, "not_found", "no such endpoint, or wrong method for it")
	})
	return authorize(token, mux)
}

// authorize rejects requests without the token. The server only listens on
// loopback, but any local program, and any web page through the browser,
// can reach that, so the token is what keeps them out.
func authorize(token string, next http.Handler) http.Handler {
	want := []byte("Bearer " + token)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if subtle.ConstantTimeCompare([]byte(r.Header.Get("Authorization")), want) != 1 {
			fail(w, http.StatusUnauthorized, "unauthorized", "missing or wrong bearer token")
			return
		}
		next.ServeHTTP(w, r)
	})
}

type server struct {
	e   Engine
	log zerolog.Logger
}

func (s *server) state(w http.ResponseWriter, _ *http.Request) {
	reply(w, toState(s.e.Snapshot()))
}

// events streams the state, then everything that changes it.
func (s *server) events(w http.ResponseWriter, r *http.Request) {
	rc := http.NewResponseController(w)
	snap, ch, cancel := s.e.Subscribe()
	defer cancel()
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusOK)
	if writeEvent(w, "state", toState(snap)) != nil || rc.Flush() != nil {
		return
	}
	tick := time.NewTicker(heartbeat)
	defer tick.Stop()
	for {
		select {
		case <-r.Context().Done():
			return
		case <-tick.C:
			if _, err := io.WriteString(w, ": ping\n\n"); err != nil {
				return
			}
		case ev, ok := <-ch:
			if !ok {
				return // fell behind or shutting down; the client reconnects
			}
			name, body := toEvent(ev)
			if name == "" {
				continue
			}
			if writeEvent(w, name, body) != nil {
				return
			}
		}
		if rc.Flush() != nil {
			return
		}
	}
}

func writeEvent(w io.Writer, name string, body any) error {
	data, err := json.Marshal(body)
	if err != nil {
		return err
	}
	_, err = fmt.Fprintf(w, "event: %s\ndata: %s\n\n", name, data)
	return err
}

func (s *server) loginStart(w http.ResponseWriter, r *http.Request) {
	step, err := s.e.LoginStart(r.Context())
	s.loginReply(w, step, err)
}

func (s *server) loginSubmit(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Values map[string]string `json:"values"`
	}
	if !decode(w, r, &req) {
		return
	}
	step, err := s.e.LoginSubmit(r.Context(), req.Values)
	s.loginReply(w, step, err)
}

func (s *server) loginCookies(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Cookies map[string]string `json:"cookies"`
	}
	if !decode(w, r, &req) {
		return
	}
	step, err := s.e.LoginCookies(r.Context(), req.Cookies)
	s.loginReply(w, step, err)
}

func (s *server) loginReply(w http.ResponseWriter, step core.LoginStep, err error) {
	if err != nil {
		s.failWith(w, err)
		return
	}
	reply(w, toLoginStep(step))
}

func (s *server) logout(w http.ResponseWriter, _ *http.Request) {
	if err := s.e.Logout(); err != nil {
		s.failWith(w, err)
		return
	}
	reply(w, struct{}{})
}

func (s *server) history(w http.ResponseWriter, r *http.Request) {
	thread, ok := threadID(w, r)
	if !ok {
		return
	}
	n := defaultHistory
	if v := r.URL.Query().Get("limit"); v != "" {
		var err error
		if n, err = strconv.Atoi(v); err != nil || n < 1 || n > maxHistory {
			fail(w, http.StatusBadRequest, "bad_request", fmt.Sprintf("limit must be 1 to %d", maxHistory))
			return
		}
	}
	msgs, more, err := s.e.History(r.Context(), thread, core.MessageID(r.URL.Query().Get("before")), n)
	if err != nil {
		s.failWith(w, err)
		return
	}
	reply(w, map[string]any{"messages": toMessages(msgs), "more": more})
}

func (s *server) send(w http.ResponseWriter, r *http.Request) {
	thread, ok := threadID(w, r)
	if !ok {
		return
	}
	var req struct {
		Text    string `json:"text"`
		OTID    string `json:"otid"`
		ReplyTo string `json:"reply_to"`
	}
	if !decode(w, r, &req) {
		return
	}
	if strings.TrimSpace(req.Text) == "" {
		fail(w, http.StatusBadRequest, "bad_request", "text is empty")
		return
	}
	otid, err := s.e.Send(r.Context(), thread, req.Text, req.OTID, core.MessageID(req.ReplyTo))
	if err != nil {
		s.failWith(w, err)
		return
	}
	reply(w, map[string]string{"otid": otid})
}

func (s *server) edit(w http.ResponseWriter, r *http.Request) {
	thread, ok := threadID(w, r)
	if !ok {
		return
	}
	var req struct {
		Text string `json:"text"`
	}
	if !decode(w, r, &req) {
		return
	}
	if strings.TrimSpace(req.Text) == "" {
		fail(w, http.StatusBadRequest, "bad_request", "text is empty")
		return
	}
	s.done(w, s.e.Edit(r.Context(), thread, messageID(r), req.Text))
}

func (s *server) unsend(w http.ResponseWriter, r *http.Request) {
	if thread, ok := threadID(w, r); ok {
		s.done(w, s.e.Unsend(r.Context(), thread, messageID(r)))
	}
}

func (s *server) react(w http.ResponseWriter, r *http.Request) { s.reaction(w, r, false) }

func (s *server) unreact(w http.ResponseWriter, r *http.Request) { s.reaction(w, r, true) }

// reaction sets or clears a reaction. Clearing names the emoji too, as
// Instagram wants it.
func (s *server) reaction(w http.ResponseWriter, r *http.Request, remove bool) {
	thread, ok := threadID(w, r)
	if !ok {
		return
	}
	var req struct {
		Emoji string `json:"emoji"`
	}
	if !decode(w, r, &req) {
		return
	}
	if req.Emoji == "" {
		fail(w, http.StatusBadRequest, "bad_request", "emoji is empty")
		return
	}
	s.done(w, s.e.React(r.Context(), thread, messageID(r), req.Emoji, remove))
}

func (s *server) read(w http.ResponseWriter, r *http.Request) {
	thread, ok := threadID(w, r)
	if !ok {
		return
	}
	var req struct {
		MessageID string `json:"message_id"`
		AtMS      int64  `json:"at_ms"`
	}
	if !decode(w, r, &req) {
		return
	}
	if req.MessageID == "" || req.AtMS <= 0 {
		fail(w, http.StatusBadRequest, "bad_request", "message_id and at_ms of the newest message are required")
		return
	}
	s.done(w, s.e.MarkRead(r.Context(), core.Message{ID: core.MessageID(req.MessageID), Thread: thread, At: time.UnixMilli(req.AtMS)}))
}

func (s *server) mute(w http.ResponseWriter, r *http.Request) {
	thread, ok := threadID(w, r)
	if !ok {
		return
	}
	var req struct {
		Muted *bool `json:"muted"`
	}
	if !decode(w, r, &req) {
		return
	}
	if req.Muted == nil {
		fail(w, http.StatusBadRequest, "bad_request", "muted is required")
		return
	}
	s.done(w, s.e.Mute(r.Context(), thread, *req.Muted))
}

func (s *server) typing(w http.ResponseWriter, r *http.Request) {
	thread, ok := threadID(w, r)
	if !ok {
		return
	}
	var req struct {
		Active *bool `json:"active"`
	}
	if !decode(w, r, &req) {
		return
	}
	if req.Active == nil {
		fail(w, http.StatusBadRequest, "bad_request", "active is required")
		return
	}
	s.done(w, s.e.Typing(r.Context(), thread, *req.Active))
}

// done replies with an empty object, or with err.
func (s *server) done(w http.ResponseWriter, err error) {
	if err != nil {
		s.failWith(w, err)
		return
	}
	reply(w, struct{}{})
}

func threadID(w http.ResponseWriter, r *http.Request) (core.ThreadID, bool) {
	v, err := strconv.ParseInt(r.PathValue("thread"), 10, 64)
	if err != nil || v <= 0 {
		fail(w, http.StatusBadRequest, "bad_request", "thread ID must be a positive integer")
		return 0, false
	}
	return core.ThreadID(v), true
}

func messageID(r *http.Request) core.MessageID { return core.MessageID(r.PathValue("message")) }

// decode reads a JSON body into v, replying with the error if it can't.
func decode(w http.ResponseWriter, r *http.Request, v any) bool {
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxBody))
	dec.DisallowUnknownFields()
	if err := dec.Decode(v); err != nil {
		fail(w, http.StatusBadRequest, "bad_request", "body isn't the JSON this endpoint takes")
		return false
	}
	return true
}

func reply(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}

func fail(w http.ResponseWriter, status int, code, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]any{"error": map[string]string{"code": code, "message": message}})
}

// failures maps the errors callers branch on to a status and a code. The
// first match wins.
var failures = []struct {
	err    error
	status int
	code   string
}{
	{core.ErrInvalidInput, http.StatusBadRequest, "bad_request"},
	{engine.ErrNotLoggedIn, http.StatusConflict, "not_logged_in"},
	{engine.ErrNoLogin, http.StatusConflict, "no_login_in_progress"},
	{engine.ErrClosed, http.StatusServiceUnavailable, "shutting_down"},
	{core.ErrSessionExpired, http.StatusConflict, "session_expired"},
	{core.ErrVerificationRequired, http.StatusConflict, "verification_required"},
	{core.ErrConsentRequired, http.StatusConflict, "consent_required"},
	{core.ErrAccountSuspended, http.StatusConflict, "account_suspended"},
	{core.ErrRateLimited, http.StatusTooManyRequests, "rate_limited"},
	{context.DeadlineExceeded, http.StatusGatewayTimeout, "timeout"},
}

// failWith replies with err: one of the known codes, or "instagram" for
// anything else Instagram or the network did.
func (s *server) failWith(w http.ResponseWriter, err error) {
	for _, f := range failures {
		if errors.Is(err, f.err) {
			fail(w, f.status, f.code, err.Error())
			return
		}
	}
	s.log.Warn().Err(err).Msg("request failed")
	fail(w, http.StatusBadGateway, "instagram", err.Error())
}
