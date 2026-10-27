# macos-setup: host-side customization of a stopped Lima macOS guest (see main.go).
# Pure Go, no cgo.

BIN := macos-setup

# Build as a standalone module even if a go.work in a parent directory (e.g. ~/Developer/go.work)
# doesn't list this one.
export GOWORK := off

.PHONY: build vet fmt clean

build: $(BIN)

$(BIN): $(wildcard *.go) go.mod go.sum
	CGO_ENABLED=0 go build -o $@ .

vet:
	go vet ./...

fmt:
	gofmt -l -w .

clean:
	rm -f $(BIN)
