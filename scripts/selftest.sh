#!/usr/bin/env bash
# selftest.sh: the scripts' failure paths, which CI's fixtures (clean by
# design) never reach. Run from the repository root, with Go on PATH.
set -euo pipefail

root=$PWD
tmp=$(mktemp -d)
fail() {
  echo "::error::selftest: $*"
  exit 1
}

# Every tool stage resolves to a tag@sha256 reference.
for t in actionlint zizmor shellcheck hadolint ruff osv-scanner uv node; do
  ref=$(bash scripts/tool-image.sh "$t")
  [[ $ref == *:*@sha256:* ]] || fail "tools/Dockerfile: $t is not tag@sha256: $ref"
done
if bash scripts/tool-image.sh nonesuch 2>/dev/null; then fail "tool-image.sh found a stage that doesn't exist"; fi

# gofmt: an unformatted file fails; vendor/, testdata/ and dot directories
# are left alone.
mkdir -p "$tmp/mod/vendor/x" "$tmp/mod/testdata" "$tmp/mod/.hidden"
printf 'module m\n\ngo 1.26.0\n' >"$tmp/mod/go.mod"
printf 'package m\n' >"$tmp/mod/m.go"
for d in vendor/x testdata .hidden; do printf 'package  x\n' >"$tmp/mod/$d/x.go"; done
(cd "$tmp/mod" && SADBOX_CI_BIN=/nonexistent bash "$root/scripts/go-check.sh" fmt) || fail "gofmt flagged vendor/, testdata/ or a dot directory"
printf 'package  m\n' >"$tmp/mod/m.go"
if (cd "$tmp/mod" && SADBOX_CI_BIN=/nonexistent bash "$root/scripts/go-check.sh" fmt); then fail "gofmt passed an unformatted file"; fi

# go-modules.sh fails when any module does, after running them all.
printf 'package m\n' >"$tmp/mod/m.go"
mkdir -p "$tmp/bad"
printf 'module b\n\ngo 1.26.0\n' >"$tmp/bad/go.mod"
printf 'package b\n\nfunc f() { var x int }\n' >"$tmp/bad/b.go"
if (cd "$tmp" && SADBOX_CI=$root RUNNER_TEMP=$tmp MODULES="bad mod" bash "$root/scripts/go-modules.sh" vet >"$tmp/out" 2>&1); then
  fail "go-modules.sh passed a module that doesn't vet"
fi
grep -q 'vet failed in: bad$' "$tmp/out" || { cat "$tmp/out"; fail "go-modules.sh didn't name the failing module"; }

# golangci-config.sh: the input, then the module's own file, then ours.
mkdir -p "$tmp/cfg/m"
(
  cd "$tmp/cfg"
  [ "$(SADBOX_CI=/ci bash "$root/scripts/golangci-config.sh" m)" = /ci/configs/golangci.yml ] || fail "golangci-config.sh: default"
  touch m/.golangci.toml
  [ "$(SADBOX_CI=/ci bash "$root/scripts/golangci-config.sh" m)" = "$(realpath m/.golangci.toml)" ] || fail "golangci-config.sh: the module's file"
  touch other.yml
  [ "$(GOLANGCI_CONFIG_INPUT=other.yml SADBOX_CI=/ci bash "$root/scripts/golangci-config.sh" m)" = "$(realpath other.yml)" ] || fail "golangci-config.sh: the input"
  if GOLANGCI_CONFIG_INPUT=missing.yml SADBOX_CI=/ci bash "$root/scripts/golangci-config.sh" m 2>/dev/null; then fail "golangci-config.sh: a missing input file"; fi
)

# detect.sh: an unknown linter in skip is an error; skipped linters don't run.
if SKIP=nonesuch bash scripts/detect.sh >/dev/null 2>&1; then fail "detect.sh accepted an unknown linter"; fi
out=$(SKIP="zizmor, npm" bash scripts/detect.sh)
grep -qx 'zizmor=false' <<<"$out" || fail "detect.sh ran a skipped linter"
grep -qx 'npm=false' <<<"$out" || fail "detect.sh ran a skipped linter"
grep -qx 'shellcheck=true' <<<"$out" || fail "detect.sh missed this repository's shell scripts"

# files.sh: shebang detection, $EXCLUDE, and Dockerfiles but not their
# .dockerignore files.
git init -q "$tmp/repo"
(
  cd "$tmp/repo"
  printf '#!/usr/bin/env bash\n' >tool
  printf '#!/bin/sh\n' >run.sh
  printf '#!/usr/bin/env python3\n' >py
  printf '#!/bin/zsh\n' >z
  printf 'FROM x\n' >Dockerfile.dev
  printf 'FROM x\n' >app.Dockerfile
  printf '*\n' >Dockerfile.dockerignore
  printf '*\n' >app.Dockerfile.dockerignore
  git add .
  [ "$(bash "$root/scripts/files.sh" shell | tr '\0' ' ')" = "run.sh tool " ] || fail "files.sh shell: $(bash "$root/scripts/files.sh" shell | tr '\0' ' ')"
  [ "$(EXCLUDE='^tool$' bash "$root/scripts/files.sh" shell | tr '\0' ' ')" = "run.sh " ] || fail "files.sh: EXCLUDE"
  [ "$(bash "$root/scripts/files.sh" dockerfile | tr '\0' ' ')" = "Dockerfile.dev app.Dockerfile " ] || fail "files.sh dockerfile: $(bash "$root/scripts/files.sh" dockerfile | tr '\0' ' ')"
)

# dep-review-triggers.sh: the gate's caller may use workflow_run, never
# pull_request_target (zizmor's exemption for the file would hide it).
mkdir -p "$tmp/dr/.github/workflows"
(
  cd "$tmp/dr"
  printf 'on:\n  workflow_run:\n    workflows: [dep-review-trigger]\n  schedule:\n    - cron: "17 * * * *"\n' >.github/workflows/dep-review.yaml
  bash "$root/scripts/dep-review-triggers.sh" >/dev/null || fail "dep-review-triggers.sh refused a workflow_run caller"
  printf 'on:\n  workflow_run:\n    workflows: [dep-review-trigger]\n  pull_request_target:\n' >.github/workflows/dep-review.yaml
  if bash "$root/scripts/dep-review-triggers.sh" >/dev/null; then fail "dep-review-triggers.sh passed pull_request_target"; fi
  printf 'on: [workflow_run, pull_request_target]\n' >.github/workflows/dep-review.yml
  printf 'on:\n  workflow_run:\n' >.github/workflows/dep-review.yaml
  if bash "$root/scripts/dep-review-triggers.sh" >/dev/null; then fail "dep-review-triggers.sh passed pull_request_target in dep-review.yml"; fi
)

echo "selftest: ok"
