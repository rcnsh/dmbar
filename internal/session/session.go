// dmbar — Instagram DMs in the macOS menu bar.
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version. See LICENSE.

// Package session keeps the Instagram login on disk, encrypted with
// XChaCha20-Poly1305 under a random key held in the macOS Keychain.
//
// The file holds cookies and cached client state, which together are too
// large for a Keychain item. The encryption protects copies of the file,
// such as backups; it doesn't protect against other programs running as the
// same user, which can read the Keychain item through /usr/bin/security.
package session

import (
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"

	"github.com/zalando/go-keyring"
	"golang.org/x/crypto/chacha20poly1305"

	"github.com/rcnsh/dmbar/internal/core"
)

const (
	fileName = "session.enc"
	// service names the Keychain item. Its account is the file's path, so
	// each data directory has its own key.
	service = "dmbar"
)

var (
	// ErrNone means no session is saved.
	ErrNone = errors.New("session: none saved")
	// ErrUnreadable means the saved session can't be decrypted: the file is
	// damaged or its key is gone. Logging in again replaces it.
	ErrUnreadable = errors.New("session: saved session unreadable")
)

// File is the session file in one data directory. It is not safe for
// concurrent use.
type File struct {
	path string
	key  []byte
}

// New returns the session file in dir. It creates nothing.
func New(dir string) *File {
	return &File{path: filepath.Join(dir, fileName)}
}

// Load reads the saved login. Only the login data is kept: dmbar starts cold
// each time, so it saves no event sequence ID.
func (f *File) Load() (core.Session, error) {
	data, err := os.ReadFile(f.path)
	if errors.Is(err, fs.ErrNotExist) {
		return core.Session{}, ErrNone
	}
	if err != nil {
		return core.Session{}, fmt.Errorf("read session: %w", err)
	}
	if len(data) < chacha20poly1305.NonceSizeX {
		return core.Session{}, fmt.Errorf("%w: file too short", ErrUnreadable)
	}
	key, err := f.loadKey()
	if err != nil {
		return core.Session{}, err
	}
	aead, err := chacha20poly1305.NewX(key)
	if err != nil {
		return core.Session{}, err
	}
	nonce, sealed := data[:chacha20poly1305.NonceSizeX], data[chacha20poly1305.NonceSizeX:]
	auth, err := aead.Open(nil, nonce, sealed, nil)
	if err != nil {
		return core.Session{}, fmt.Errorf("%w: decryption failed", ErrUnreadable)
	}
	f.key = key
	return core.Session{Auth: auth}, nil
}

// Save writes s's login data, replacing what was saved. The first save
// creates the key.
func (f *File) Save(s core.Session) error {
	if f.key == nil {
		key, err := f.loadKey()
		if errors.Is(err, ErrUnreadable) {
			key = make([]byte, chacha20poly1305.KeySize)
			if _, err = rand.Read(key); err == nil {
				err = keyring.Set(service, f.path, base64.StdEncoding.EncodeToString(key))
			}
		}
		if err != nil {
			return fmt.Errorf("session key: %w", err)
		}
		f.key = key
	}
	aead, err := chacha20poly1305.NewX(f.key)
	if err != nil {
		return err
	}
	nonce := make([]byte, chacha20poly1305.NonceSizeX)
	if _, err := rand.Read(nonce); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(f.path), 0o700); err != nil {
		return fmt.Errorf("save session: %w", err)
	}
	// Written beside the file and renamed, so a crash can't leave half of it.
	tmp, err := os.CreateTemp(filepath.Dir(f.path), fileName+".*")
	if err != nil {
		return fmt.Errorf("save session: %w", err)
	}
	defer os.Remove(tmp.Name())
	_, err = tmp.Write(aead.Seal(nonce, nonce, s.Auth, nil))
	if closeErr := tmp.Close(); err == nil {
		err = closeErr
	}
	if err == nil {
		err = os.Rename(tmp.Name(), f.path)
	}
	if err != nil {
		return fmt.Errorf("save session: %w", err)
	}
	return nil
}

// Delete removes the saved session and its key. Deleting nothing is not an
// error.
func (f *File) Delete() error {
	f.key = nil
	err := os.Remove(f.path)
	if errors.Is(err, fs.ErrNotExist) {
		err = nil
	}
	if kerr := keyring.Delete(service, f.path); kerr != nil && !errors.Is(kerr, keyring.ErrNotFound) {
		err = errors.Join(err, kerr)
	}
	if err != nil {
		return fmt.Errorf("delete session: %w", err)
	}
	return nil
}

// loadKey reads the key from the Keychain, or returns ErrUnreadable if it
// isn't there.
func (f *File) loadKey() ([]byte, error) {
	enc, err := keyring.Get(service, f.path)
	if errors.Is(err, keyring.ErrNotFound) {
		return nil, fmt.Errorf("%w: no key in the keychain", ErrUnreadable)
	}
	if err != nil {
		return nil, fmt.Errorf("read keychain: %w", err)
	}
	key, err := base64.StdEncoding.DecodeString(enc)
	if err != nil || len(key) != chacha20poly1305.KeySize {
		return nil, fmt.Errorf("%w: bad key in the keychain", ErrUnreadable)
	}
	return key, nil
}
