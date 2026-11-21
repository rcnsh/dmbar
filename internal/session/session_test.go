package session

import (
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/zalando/go-keyring"

	"github.com/rcnsh/dmbar/internal/core"
)

func TestRoundTrip(t *testing.T) {
	keyring.MockInit()
	dir := t.TempDir()

	if _, err := New(dir).Load(); !errors.Is(err, ErrNone) {
		t.Fatalf("Load with nothing saved = %v, want ErrNone", err)
	}
	f := New(dir)
	if err := f.Save(core.Session{Auth: core.AuthData("first")}); err != nil {
		t.Fatal(err)
	}
	if err := f.Save(core.Session{Auth: core.AuthData("second")}); err != nil {
		t.Fatal(err)
	}
	got, err := New(dir).Load()
	if err != nil || string(got.Auth) != "second" {
		t.Fatalf("Load = %q, %v; want the last save", []byte(got.Auth), err)
	}
	raw, _ := os.ReadFile(filepath.Join(dir, fileName))
	if len(raw) == 0 || string(raw) == "second" {
		t.Fatal("the file isn't encrypted")
	}

	if err := f.Delete(); err != nil {
		t.Fatal(err)
	}
	if _, err := New(dir).Load(); !errors.Is(err, ErrNone) {
		t.Fatalf("Load after Delete = %v, want ErrNone", err)
	}
	if err := f.Delete(); err != nil {
		t.Fatalf("second Delete = %v, want nil", err)
	}
}

func TestLostKey(t *testing.T) {
	keyring.MockInit()
	dir := t.TempDir()
	f := New(dir)
	if err := f.Save(core.Session{Auth: core.AuthData("x")}); err != nil {
		t.Fatal(err)
	}
	if err := keyring.Delete(service, f.path); err != nil {
		t.Fatal(err)
	}
	if _, err := New(dir).Load(); !errors.Is(err, ErrUnreadable) {
		t.Fatalf("Load without its key = %v, want ErrUnreadable", err)
	}
	// A new login replaces it.
	fresh := New(dir)
	if err := fresh.Save(core.Session{Auth: core.AuthData("y")}); err != nil {
		t.Fatal(err)
	}
	if got, err := New(dir).Load(); err != nil || string(got.Auth) != "y" {
		t.Fatalf("Load after a new save = %q, %v", []byte(got.Auth), err)
	}
}
