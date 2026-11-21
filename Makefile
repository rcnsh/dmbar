.PHONY: build run test check

# Builds the daemon into bin/dmbard.
build:
	CGO_ENABLED=0 go build -o bin/dmbard ./cmd/dmbard

# Runs the daemon on a fixed port with a fixed token, for poking at with curl.
run:
	DMBAR_TOKEN=dev go run ./cmd/dmbard -addr 127.0.0.1:7878 -log-level debug

test:
	go test ./...

# Everything to pass before a change is done.
check:
	test -z "$$(gofmt -l cmd internal)"
	go vet ./...
	go test -race ./...
