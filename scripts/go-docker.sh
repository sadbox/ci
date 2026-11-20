#!/usr/bin/env bash
# go-docker.sh PHASE: go-check.sh PHASE inside the caller's test image
# ($IMAGE, built for $PLATFORM), in the image's working directory: the
# module root, holding the sources exactly as the Dockerfile builds them.
# Mounted: sadbox/ci (read-only), the Go build cache the workflow keeps
# between runs, a module cache shared by this job's steps, and the tools'
# directory (writable only to build them).
set -euo pipefail

phase=$1
ci=${SADBOX_CI:-$RUNNER_TEMP/sadbox-ci}
cache=$RUNNER_TEMP/sadbox-ci-gocache
bin=$RUNNER_TEMP/sadbox-ci-bin
mkdir -p "$cache" "$bin"

args=(
  --rm --platform "$PLATFORM"
  -v "$ci:/sadbox-ci:ro"
  -v "$cache:/sadbox-ci-gocache"
  -e GOCACHE=/sadbox-ci-gocache/go-build
  -e GOLANGCI_LINT_CACHE=/sadbox-ci-gocache/golangci-lint
  -e SADBOX_CI=/sadbox-ci
  -e SADBOX_CI_BIN=/sadbox-ci-bin
  -e GO_TEST_FLAGS
)
# The module cache as a named volume at the image's GOMODCACHE: Docker
# fills an empty volume from the image, so modules the Dockerfile
# downloaded are kept, and any fetched here are shared by the later steps.
gomodcache=$(docker run --rm --platform "$PLATFORM" --entrypoint go "$IMAGE" env GOMODCACHE)
args+=(-v "sadbox-ci-gomodcache:$gomodcache")
if [ "$phase" = tools ]; then
  args+=(-v "$bin:/sadbox-ci-bin")
else
  args+=(-v "$bin:/sadbox-ci-bin:ro")
fi
if [ "$phase" = lint ]; then
  # Beside the sources, so the configuration's relative paths resolve
  # against the module root; the extension tells golangci-lint the format.
  workdir=$(docker image inspect -f '{{.Config.WorkingDir}}' "$IMAGE")
  workdir=${workdir:-/}
  cfg=$(SADBOX_CI=$ci bash "$ci/scripts/golangci-config.sh" "$CONTEXT")
  in_image=${workdir%/}/.sadbox-ci-golangci.${cfg##*.}
  echo "golangci-lint configuration: $cfg"
  args+=(-v "$cfg:$in_image:ro" -e "GOLANGCI_CONFIG=$in_image")
fi
docker run "${args[@]}" --entrypoint bash "$IMAGE" /sadbox-ci/scripts/go-check.sh "$phase"
