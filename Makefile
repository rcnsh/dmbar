.PHONY: build run demo test check app install app-demo

# Builds the daemon into bin/dmbard.
build:
	CGO_ENABLED=0 go build -o bin/dmbard ./cmd/dmbard

# Runs the daemon on a fixed port with a fixed token, for poking at with curl.
run:
	DMBAR_TOKEN=dev go run ./cmd/dmbard -addr 127.0.0.1:7878 -log-level debug

# The same, serving a made-up inbox: no account, no network, no files.
demo:
	DMBAR_TOKEN=dev go run ./cmd/dmbard -demo -addr 127.0.0.1:7878

test:
	go test ./...
	cd app && swift test

# Everything to pass before a change is done. The Swift tests drive
# bin/dmbard, so it is built first.
check: build
	test -z "$$(gofmt -l cmd internal)"
	go vet ./...
	go test -race ./...
	cd app && swift test

# Builds app/build/dmbar.app, with the daemon inside it.
app:
	app/build.sh

# Builds the app, copies it to /Applications and opens it.
install:
	app/build.sh install

# Opens the built app on the made-up inbox with its popover showing, without
# touching the real login. DMBAR_ROUTE=settings, menu or a thread ID (101, 900)
# picks the screen.
app-demo: app
	-pkill -x Dmbar
	DMBAR_DEMO=1 DMBAR_SHOW=1 app/build/dmbar.app/Contents/MacOS/Dmbar
