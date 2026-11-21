package api_test

import (
	"bufio"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/rs/zerolog"

	"github.com/rcnsh/dmbar/internal/api"
	"github.com/rcnsh/dmbar/internal/core"
	"github.com/rcnsh/dmbar/internal/engine"
	"github.com/rcnsh/dmbar/internal/fake"
	"github.com/rcnsh/dmbar/internal/instagram"
)

const token = "test-token"

var (
	me    = core.User{ID: 9007199254740993, Username: "me", Name: "Me"} // past 2^53
	alice = core.User{ID: 2, Username: "alice", Name: "Alice"}
	t0    = time.UnixMilli(1_700_000_000_123)
)

type fixture struct {
	url     string
	backend *fake.Backend
}

// serve runs the API over an engine with a fake backend. With login the
// account is connected before it returns.
func serve(t *testing.T, login bool, script func(*fake.Backend)) fixture {
	t.Helper()
	b := &fake.Backend{Me: me, Threads: []core.Thread{{
		ID: 20, Title: "Alice", Members: []core.User{alice}, LastActivity: t0,
		Messages: []core.Message{{ID: "m1", Thread: 20, Sender: alice.ID, At: t0, Text: "hi"}},
	}}, Older: []core.Message{{ID: "m0", Thread: 20, Sender: alice.ID, At: t0.Add(-time.Minute), Text: "earlier"}}}
	if script != nil {
		script(b)
	}
	sessions := &fake.Sessions{}
	if login {
		sessions.Saved = &core.Session{Auth: core.AuthData("saved")}
	}
	eng := engine.New(engine.Options{
		Log:        zerolog.Nop(),
		Sessions:   sessions,
		NewBackend: func() core.Backend { return b },
		NewLogin:   func() engine.Login { return fake.Login{Me: me} },
	})
	srv := httptest.NewServer(api.New(eng, token, zerolog.Nop()))
	t.Cleanup(func() { eng.Close(); srv.Close() })
	eng.Start()
	if login {
		deadline := time.Now().Add(2 * time.Second)
		for eng.Snapshot().State != engine.Connected {
			if time.Now().After(deadline) {
				t.Fatal("never connected")
			}
			time.Sleep(5 * time.Millisecond)
		}
	}
	return fixture{url: srv.URL, backend: b}
}

// call makes a request and decodes the JSON reply into a generic value.
func (f fixture) call(t *testing.T, method, path, body, auth string) (int, map[string]any) {
	t.Helper()
	req, err := http.NewRequest(method, f.url+path, strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	if auth != "" {
		req.Header.Set("Authorization", auth)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var out map[string]any
	raw, _ := io.ReadAll(resp.Body)
	if err := json.Unmarshal(raw, &out); err != nil {
		t.Fatalf("%s %s: reply isn't JSON: %q", method, path, raw)
	}
	return resp.StatusCode, out
}

func code(body map[string]any) string {
	e, _ := body["error"].(map[string]any)
	c, _ := e["code"].(string)
	return c
}

func TestTokenIsRequired(t *testing.T) {
	f := serve(t, true, nil)
	for _, auth := range []string{"", "Bearer wrong", token, "Bearer " + token + "x"} {
		if status, body := f.call(t, "GET", "/v1/state", "", auth); status != http.StatusUnauthorized || code(body) != "unauthorized" {
			t.Errorf("auth %q: %d %v, want 401", auth, status, body)
		}
	}
}

func TestStateAndHistory(t *testing.T) {
	f := serve(t, true, nil)
	status, body := f.call(t, "GET", "/v1/state", "", "Bearer "+token)
	if status != 200 || body["state"] != "connected" {
		t.Fatalf("state: %d %v", status, body)
	}
	// IDs are strings, so one past 2^53 survives.
	if id := body["me"].(map[string]any)["id"]; id != "9007199254740993" {
		t.Fatalf("me.id = %v, want the exact ID as a string", id)
	}
	thread := body["threads"].([]any)[0].(map[string]any)
	last := thread["last_message"].(map[string]any)
	if thread["id"] != "20" || last["id"] != "m1" || last["at_ms"] != float64(t0.UnixMilli()) {
		t.Fatalf("thread = %v", thread)
	}

	status, body = f.call(t, "GET", "/v1/threads/20/messages?limit=5", "", "Bearer "+token)
	if status != 200 || body["more"] != false || body["messages"].([]any)[0].(map[string]any)["id"] != "m0" {
		t.Fatalf("history: %d %v", status, body)
	}
	for _, path := range []string{"/v1/threads/abc/messages", "/v1/threads/20/messages?limit=0", "/v1/threads/20/messages?limit=101"} {
		if status, body := f.call(t, "GET", path, "", "Bearer "+token); status != 400 || code(body) != "bad_request" {
			t.Errorf("%s: %d %v, want 400", path, status, body)
		}
	}
}

func TestSendAndRead(t *testing.T) {
	f := serve(t, true, nil)
	auth := "Bearer " + token
	status, body := f.call(t, "POST", "/v1/threads/20/messages", `{"text":"hello"}`, auth)
	if status != 200 || body["otid"] != "otid-1" {
		t.Fatalf("send: %d %v", status, body)
	}
	for _, bad := range []string{`{"text":"  "}`, `{"txt":"x"}`, `not json`} {
		if status, body := f.call(t, "POST", "/v1/threads/20/messages", bad, auth); status != 400 {
			t.Errorf("send %s: %d %v, want 400", bad, status, body)
		}
	}
	if status, body := f.call(t, "POST", "/v1/threads/20/read", `{"message_id":"m1","at_ms":1700000000123}`, auth); status != 200 {
		t.Fatalf("read: %d %v", status, body)
	}
	if status, _ := f.call(t, "POST", "/v1/threads/20/read", `{"message_id":"m1"}`, auth); status != 400 {
		t.Fatalf("read without at_ms: %d, want 400", status)
	}
	if status, _ := f.call(t, "POST", "/v1/threads/20/mute", `{}`, auth); status != 400 {
		t.Fatalf("mute without muted: %d, want 400", status)
	}
	sent, read := f.backend.Calls()
	if len(sent) != 1 || sent[0] != "hello" || len(read) != 1 || read[0] != "m1" {
		t.Fatalf("backend got sent=%v read=%v", sent, read)
	}
}

func TestErrorsHaveCodes(t *testing.T) {
	f := serve(t, true, func(b *fake.Backend) { b.SendErr = core.ErrRateLimited })
	if status, body := f.call(t, "POST", "/v1/threads/20/messages", `{"text":"x"}`, "Bearer "+token); status != 429 || code(body) != "rate_limited" {
		t.Fatalf("rate-limited send: %d %v", status, body)
	}

	out := serve(t, false, nil)
	if status, body := out.call(t, "POST", "/v1/threads/20/messages", `{"text":"x"}`, "Bearer "+token); status != 409 || code(body) != "not_logged_in" {
		t.Fatalf("send while logged out: %d %v", status, body)
	}
	if status, body := out.call(t, "POST", "/v1/login/submit", `{"values":{}}`, "Bearer "+token); status != 409 || code(body) != "no_login_in_progress" {
		t.Fatalf("submit with no login: %d %v", status, body)
	}
}

func TestLoginOverHTTP(t *testing.T) {
	f := serve(t, false, nil)
	auth := "Bearer " + token
	status, body := f.call(t, "POST", "/v1/login/start", "", auth)
	if status != 200 || body["done"] != false || len(body["fields"].([]any)) != 1 {
		t.Fatalf("login start: %d %v", status, body)
	}
	status, body = f.call(t, "POST", "/v1/login/cookies", `{"cookies":{"sessionid":"abc"}}`, auth)
	if status != 200 || body["done"] != true || body["me"].(map[string]any)["username"] != "me" {
		t.Fatalf("login cookies: %d %v", status, body)
	}
	if status, body = f.call(t, "POST", "/v1/logout", "", auth); status != 200 {
		t.Fatalf("logout: %d %v", status, body)
	}
	if _, body = f.call(t, "GET", "/v1/state", "", auth); body["state"] != "logged_out" || body["me"] != nil {
		t.Fatalf("state after logout: %v", body)
	}
}

func TestEventStream(t *testing.T) {
	f := serve(t, true, nil)
	req, _ := http.NewRequest("GET", f.url+"/v1/events", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if ct := resp.Header.Get("Content-Type"); ct != "text/event-stream" {
		t.Fatalf("Content-Type = %q", ct)
	}
	events := make(chan [2]string, 8)
	go func() {
		defer close(events)
		var name string
		sc := bufio.NewScanner(resp.Body)
		for sc.Scan() {
			if v, ok := strings.CutPrefix(sc.Text(), "event: "); ok {
				name = v
			} else if v, ok := strings.CutPrefix(sc.Text(), "data: "); ok {
				events <- [2]string{name, v}
			}
		}
	}()
	next := func() [2]string {
		t.Helper()
		select {
		case ev, ok := <-events:
			if !ok {
				t.Fatal("stream ended")
			}
			return ev
		case <-time.After(2 * time.Second):
			t.Fatal("no event")
		}
		return [2]string{}
	}

	first := next()
	if first[0] != "state" || !strings.Contains(first[1], `"state":"connected"`) || !strings.Contains(first[1], `"id":"20"`) {
		t.Fatalf("first event = %v, want the whole state", first)
	}
	f.backend.Emit(core.MessageAdded{Message: core.Message{ID: "m2", Thread: 20, Sender: alice.ID, At: t0.Add(time.Second), Text: "yo"}})
	f.backend.Emit(core.SeqAdvanced{SeqID: 5}) // never reaches clients
	f.backend.Emit(core.Typing{Thread: 20, User: alice.ID, Active: true})
	if ev := next(); ev[0] != "message_added" || !strings.Contains(ev[1], `"text":"yo"`) || !strings.Contains(ev[1], `"thread_id":"20"`) {
		t.Fatalf("second event = %v", ev)
	}
	if ev := next(); ev[0] != "typing" || !strings.Contains(ev[1], `"active":true`) {
		t.Fatalf("third event = %v", ev)
	}
}

func TestUnknownRoutesAndBadLoginInputAreJSON(t *testing.T) {
	f := serve(t, false, nil)
	auth := "Bearer " + token
	for _, c := range [][2]string{{"GET", "/v1/nope"}, {"PUT", "/v1/state"}, {"GET", "/"}} {
		if status, body := f.call(t, c[0], c[1], "", auth); status != 404 || code(body) != "not_found" {
			t.Errorf("%s %s: %d %v, want 404 not_found", c[0], c[1], status, body)
		}
	}
}

func TestInvalidInputIsABadRequest(t *testing.T) {
	// The real login rejects these before any network call.
	eng := engine.New(engine.Options{
		Log: zerolog.Nop(), Sessions: &fake.Sessions{},
		NewBackend: func() core.Backend { return &fake.Backend{} },
		NewLogin:   func() engine.Login { return instagram.NewLogin(zerolog.Nop()) },
	})
	srv := httptest.NewServer(api.New(eng, token, zerolog.Nop()))
	t.Cleanup(func() { eng.Close(); srv.Close() })
	f := fixture{url: srv.URL}
	auth := "Bearer " + token

	status, body := f.call(t, "POST", "/v1/login/cookies", `{"cookies":{"sessionid":"SECRETVALUE"}}`, auth)
	msg, _ := body["error"].(map[string]any)["message"].(string)
	if status != 400 || code(body) != "bad_request" || !strings.Contains(msg, "csrftoken") || strings.Contains(msg, "SECRETVALUE") {
		t.Fatalf("cookies without the required ones: %d %v", status, body)
	}
	f.call(t, "POST", "/v1/login/start", "", auth)
	if status, body := f.call(t, "POST", "/v1/login/submit", `{"values":{"login_method":"bogus"}}`, auth); status != 400 || code(body) != "bad_request" {
		t.Fatalf("unknown login method: %d %v", status, body)
	}
}

func TestOTIDAndLineBreakSafeEvents(t *testing.T) {
	f := serve(t, true, nil)
	if status, body := f.call(t, "POST", "/v1/otid", "", "Bearer "+token); status != 200 || body["otid"] == "" {
		t.Fatalf("otid: %d %v", status, body)
	}
	req, _ := http.NewRequest("GET", f.url+"/v1/events", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	f.backend.Emit(core.MessageAdded{Message: core.Message{ID: "nel", Thread: 20, Sender: alice.ID, At: t0.Add(time.Second), Text: "caf\u0085e"}})
	buf := make([]byte, 0, 4096)
	deadline := time.Now().Add(2 * time.Second)
	for !strings.Contains(string(buf), `"id":"nel"`) {
		if time.Now().After(deadline) {
			t.Fatalf("no event; got %q", buf)
		}
		chunk := make([]byte, 2048)
		n, err := resp.Body.Read(chunk)
		buf = append(buf, chunk[:n]...)
		if err != nil {
			t.Fatal(err)
		}
	}
	if strings.Contains(string(buf), "\u0085") || !strings.Contains(string(buf), `caf\u0085e`) {
		t.Fatalf("U+0085 isn't escaped in the stream: %q", buf)
	}
}
