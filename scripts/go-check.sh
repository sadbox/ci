#!/usr/bin/env bash
# go-check.sh PHASE: one of go.yml's Go checks, run in the module's root
# directory: inside the caller's test image (docker mode, via
# go-docker.sh) or on the runner after setup-go (setup-go mode).
#   fmt    gofmt -l over the module's .go files (not vendor/, testdata/,
#          node_modules/ or dot directories)
#   vet    go vet ./...
#   test   go test -race $GO_TEST_FLAGS ./...
#   lint   golangci-lint run --config $GOLANGCI_CONFIG ./...
#   vuln   govulncheck ./...
#   tools  build golangci-lint and govulncheck (tools/go's tool directives)
#          into $SADBOX_CI_BIN with this Go
# $SADBOX_CI is sadbox/ci's checkout, $SADBOX_CI_BIN the tools' directory.
set -euo pipefail

phase=$1
bin=${SADBOX_CI_BIN:?}

case $phase in
fmt)
  unformatted=$(find . \( -name vendor -o -name testdata -o -name node_modules -o -name '.?*' \) -prune \
    -o -type f -name '*.go' -print0 | xargs -0 -r gofmt -l)
  if [ -n "$unformatted" ]; then
    echo "::error::not gofmt-formatted (run gofmt -w):"
    echo "$unformatted"
    exit 1
  fi
  ;;
vet)
  go vet ./...
  ;;
test)
  # -race needs cgo, whatever the image's CGO_ENABLED (often 0 for the
  # static build); the golang image and the runners have a C compiler.
  # shellcheck disable=SC2086 # GO_TEST_FLAGS is a list of flags
  CGO_ENABLED=1 go test -race ${GO_TEST_FLAGS:-} ./...
  ;;
lint)
  "$bin/golangci-lint" run --config "${GOLANGCI_CONFIG:?}" ./...
  ;;
vuln)
  "$bin/govulncheck" ./...
  ;;
tools)
  # Static, with no caller GOFLAGS (e.g. -mod=vendor), into a fresh build
  # cache: the binaries are cached by the workflow, keyed on this Go.
  GOBIN=$bin CGO_ENABLED=0 GOFLAGS='' GOCACHE=$(mktemp -d) go -C "${SADBOX_CI:?}/tools/go" install tool
  "$bin/golangci-lint" version
  "$bin/govulncheck" -version
  ;;
*)
  echo "go-check.sh: unknown phase $phase" >&2
  exit 2
  ;;
esac
