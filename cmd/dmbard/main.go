// dmbar — Instagram DMs in the macOS menu bar.
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version. See LICENSE.

// Command dmbard is dmbar's backend: it holds one Instagram login, keeps the
// live connection up and serves docs/api.md on the loopback interface. The
// menu bar app starts it and talks to it; it can also be run by hand.
package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/rs/zerolog"

	"github.com/rcnsh/dmbar/internal/api"
	"github.com/rcnsh/dmbar/internal/core"
	"github.com/rcnsh/dmbar/internal/engine"
	"github.com/rcnsh/dmbar/internal/fake"
	"github.com/rcnsh/dmbar/internal/instagram"
	"github.com/rcnsh/dmbar/internal/session"
)

// refreshEvery is how long a connection lasts before a full refresh, as the
// upstream bridge does.
const refreshEvery = 20 * time.Hour

// tokenEnv names the variable the app passes the API token in, so it never
// shows in the process list.
const tokenEnv = "DMBAR_TOKEN"

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "dmbard:", err)
		os.Exit(1)
	}
}

func run() error {
	addr := flag.String("addr", "127.0.0.1:0", "loopback address to listen on; port 0 picks a free one")
	dataDir := flag.String("data-dir", defaultDataDir(), "directory for the saved login")
	level := flag.String("log-level", "info", "zerolog level for stderr: debug, info, warn or error")
	parent := flag.Bool("exit-with-stdin", false, "exit when stdin closes, so the daemon ends with the app that started it")
	demo := flag.Bool("demo", false, "serve a made-up inbox with no account and no network, for working on the app")
	flag.Parse()

	lvl, err := zerolog.ParseLevel(*level)
	if err != nil {
		return fmt.Errorf("-log-level: %w", err)
	}
	log := zerolog.New(zerolog.ConsoleWriter{Out: os.Stderr, TimeFormat: time.TimeOnly}).Level(lvl).With().Timestamp().Logger()

	host, _, err := net.SplitHostPort(*addr)
	if ip := net.ParseIP(host); err != nil || ip == nil || !ip.IsLoopback() {
		return errors.New("-addr must be a loopback IP and a port, such as 127.0.0.1:0")
	}
	// Absolute, because the Keychain key is filed under the directory's path.
	if *dataDir, err = filepath.Abs(*dataDir); err != nil {
		return err
	}
	if !*demo { // the demo touches no files, so it can run beside the real one
		if err := os.MkdirAll(*dataDir, 0o700); err != nil {
			return err
		}
		unlock, err := lock(*dataDir)
		if err != nil {
			return err
		}
		defer unlock()
	}

	token, generated := os.Getenv(tokenEnv), false
	if token == "" {
		raw := make([]byte, 24)
		if _, err := rand.Read(raw); err != nil {
			return err
		}
		token, generated = hex.EncodeToString(raw), true
	}

	opts := engine.Options{
		Log:        log,
		Sessions:   session.New(*dataDir),
		NewBackend: func() core.Backend { return instagram.New(log, refreshEvery) },
		NewLogin:   func() engine.Login { return instagram.NewLogin(log) },
	}
	if *demo {
		opts.Sessions = fake.DemoSessions()
		opts.NewBackend = func() core.Backend { return fake.Demo() }
		opts.NewLogin = func() engine.Login { return fake.Login{} }
	}
	eng := engine.New(opts)
	defer eng.Close()

	ln, err := net.Listen("tcp", *addr)
	if err != nil {
		return err
	}
	srv := &http.Server{Handler: api.New(eng, token, log), ReadHeaderTimeout: 10 * time.Second}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if *parent {
		go func() {
			_, _ = io.Copy(io.Discard, os.Stdin)
			stop()
		}()
	}

	// One line on stdout says where to connect. The token is only printed
	// when dmbard made it up.
	ready := map[string]string{"addr": ln.Addr().String()}
	if generated {
		ready["token"] = token
	}
	if err := json.NewEncoder(os.Stdout).Encode(ready); err != nil {
		return err
	}

	eng.Start()
	served := make(chan error, 1)
	go func() { served <- srv.Serve(ln) }()
	select {
	case err := <-served:
		return err
	case <-ctx.Done():
	}
	log.Info().Msg("shutting down")
	eng.Close() // ends the event streams, which Shutdown would otherwise wait for
	shut, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	return srv.Shutdown(shut)
}

// defaultDataDir is ~/Library/Application Support/dmbar on macOS.
func defaultDataDir() string {
	dir, err := os.UserConfigDir()
	if err != nil {
		return "."
	}
	return filepath.Join(dir, "dmbar")
}

// lock takes the data directory for this process: two daemons on one login
// would connect twice and overwrite each other's saves.
func lock(dir string) (func(), error) {
	f, err := os.OpenFile(filepath.Join(dir, "dmbard.lock"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		return nil, fmt.Errorf("another dmbard is using %s", dir)
	}
	return func() { f.Close() }, nil
}
