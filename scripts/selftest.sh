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
for t in actionlint zizmor shellcheck hadolint ruff osv-scanner uv node tofu tflint; do
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
if git ls-files --error-unmatch .github/workflows/actions.lock >/dev/null 2>&1; then want=true; else want=false; fi
grep -qx "actions-lock=$want" <<<"$out" || fail "detect.sh got actions-lock wrong (want $want)"

# files.sh: shebang detection, $EXCLUDE, and Dockerfiles but not their
# .dockerignore files; OpenTofu directories, each once, and roots (by
# their lockfile).
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
  mkdir -p infra/a infra/mod
  printf "x\n" >infra/a/main.tf
  printf "x\n" >infra/a/vars.tf
  printf "x\n" >infra/a/.terraform.lock.hcl
  printf "x\n" >infra/mod/m.tofu
  printf "x\n" >top.tf
  git add .
  [ "$(bash "$root/scripts/files.sh" shell | tr '\0' ' ')" = "run.sh tool " ] || fail "files.sh shell: $(bash "$root/scripts/files.sh" shell | tr '\0' ' ')"
  [ "$(EXCLUDE='^tool$' bash "$root/scripts/files.sh" shell | tr '\0' ' ')" = "run.sh " ] || fail "files.sh: EXCLUDE"
  [ "$(bash "$root/scripts/files.sh" dockerfile | tr '\0' ' ')" = "Dockerfile.dev app.Dockerfile " ] || fail "files.sh dockerfile: $(bash "$root/scripts/files.sh" dockerfile | tr '\0' ' ')"
  [ "$(bash "$root/scripts/files.sh" tofu | tr "\0" " ")" = ". infra/a infra/mod " ] || fail "files.sh tofu: $(bash "$root/scripts/files.sh" tofu | tr "\0" " ")"
  [ "$(bash "$root/scripts/files.sh" tofuroot | tr "\0" " ")" = "infra/a " ] || fail "files.sh tofuroot: $(bash "$root/scripts/files.sh" tofuroot | tr "\0" " ")"
)

# binaries.sh: text passes; a binary file fails until .gitattributes
# declares it, and then fails again over the size allowed; every offender
# is named. detect.sh always runs it.
grep -qx 'binaries=true' <<<"$out" || fail "detect.sh left the binaries check out"
git init -q "$tmp/bin"
(
  cd "$tmp/bin"
  mkdir -p img build
  printf 'text\n' >notes.txt
  : >empty
  git add .
  bash "$root/scripts/binaries.sh" >/dev/null || fail "binaries.sh failed a repository of text"
  printf 'GIF89a\0\0\1' >img/a.gif
  printf '\177ELF\0\0\0' >build/tool
  git add .
  if got=$(bash "$root/scripts/binaries.sh"); then fail "binaries.sh passed undeclared binary files"; fi
  grep -q 'file=img/a.gif::' <<<"$got" || fail "binaries.sh didn't name img/a.gif: $got"
  grep -q 'file=build/tool::' <<<"$got" || fail "binaries.sh didn't name build/tool: $got"
  if grep -q 'notes.txt\|empty' <<<"$got"; then fail "binaries.sh named a text file: $got"; fi
  printf 'img/*.gif binary\n' >.gitattributes
  git add .
  if got=$(bash "$root/scripts/binaries.sh"); then fail "binaries.sh passed build/tool, which nothing declares"; fi
  if grep -q 'file=img/a.gif::' <<<"$got"; then fail "binaries.sh failed a declared file: $got"; fi
  git rm -q --cached build/tool
  bash "$root/scripts/binaries.sh" >/dev/null || fail "binaries.sh failed with every binary declared"
  if BINARY_MAX_BYTES=8 bash "$root/scripts/binaries.sh" >/dev/null; then fail "binaries.sh passed a declared file over the size allowed"; fi
  if BINARY_MAX_BYTES=5MB bash "$root/scripts/binaries.sh" >/dev/null 2>&1; then fail "binaries.sh took a size that isn't a number"; fi
  # A path that reads as a revision (":0:small" is stage 0 of small): its
  # own size counts, not small's.
  printf 'x\n' >small
  printf 'GIF89a\0\0\1 and more' >'0:small'
  printf 'img/*.gif binary\n0:small binary\n' >.gitattributes
  git add .
  if got=$(BINARY_MAX_BYTES=10 bash "$root/scripts/binaries.sh"); then fail "binaries.sh sized 0:small as another file: $got"; fi
  grep -q 'file=0:small::' <<<"$got" || fail "binaries.sh didn't name 0:small: $got"
  git rm -q --cached small '0:small'
  # -text alone (no end-of-line conversion) is not a declaration.
  printf 'img/*.gif -text\n' >.gitattributes
  git add .
  if bash "$root/scripts/binaries.sh" >/dev/null; then fail "binaries.sh took -text for a declaration"; fi
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

# report-publish/report.sh, against a local listener that records what it
# was sent (testdata/report-publish/listen.py), with stand-ins for gh (a
# commit's place in history) and docker (an image's revision label): one
# line per image, the credentials as basic auth; a refused report or a bad
# input fails, and never names the endpoint (a public repository's log).
command -v python3 >/dev/null || fail "selftest needs python3 (report-publish's listener)"
command -v jq >/dev/null || fail "selftest needs jq (report-publish)"
mkdir -p "$tmp/rp/bin"
a=$(printf 'a%.0s' $(seq 40)) b=$(printf 'b%.0s' $(seq 40)) head=0123456789abcdef0123456789abcdef01234567
cat >"$tmp/rp/bin/gh" <<SH
#!/usr/bin/env bash
# gh api graphql ... -f o=<owner> -f n=<repo> -f oid=<sha>: the commit's totalCount.
[[ " \$* " == *" o=sadbox "* && " \$* " == *" n=ci "* ]] || exit 1
case " \$* " in
*" oid=$head "*) echo 192 ;;
*" oid=$a "*) echo 584 ;;
*" oid=$b "*) echo 585 ;;
*) ;; # not a commit here: nothing
esac
SH
cat >"$tmp/rp/bin/docker" <<SH
#!/usr/bin/env bash
# docker buildx imagetools inspect <ref>:latest --format '{{json .Image}}'
index() { printf '{"linux/amd64":{"config":{"Labels":{"org.opencontainers.image.revision":"%s"}}},"linux/arm64":{"config":{"Labels":{"org.opencontainers.image.revision":"%s"}}}}\n' "\$1" "\$2"; }
case "\$4" in
ghcr.io/x/sprobot:latest) index $a $a ;;
ghcr.io/x/threadbot:latest) index $b $b ;;
ghcr.io/x/mixed:latest) index $a $b ;;
ghcr.io/x/elsewhere:latest) index ${a//a/c} ${a//a/c} ;;
ghcr.io/x/nolabel:latest) echo '{"linux/amd64":{"config":{"Labels":{}}}}' ;;
*) exit 1 ;;
esac
SH
chmod +x "$tmp/rp/bin/gh" "$tmp/rp/bin/docker"
listen() { # listen <status>: sets $port and $listener
  rm -f "$tmp/rp/got" "$tmp/rp/port"
  python3 "$root/testdata/report-publish/listen.py" "$tmp/rp/got" "$1" >"$tmp/rp/port" &
  listener=$!
  for _ in $(seq 50); do
    if [ -s "$tmp/rp/port" ]; then break; fi
    sleep 0.1
  done
  port=$(cat "$tmp/rp/port")
  [ -n "$port" ] || fail "report-publish: the listener didn't start"
}
report() {
  env -i PATH="$tmp/rp/bin:$PATH" GITHUB_SHA=$head GITHUB_REPOSITORY=sadbox/ci GH_TOKEN=x "$@" bash "$root/report-publish/report.sh"
}

# The images a run just published, at its own commit.
listen 204
report REPORT_NAMES="sprobot stickybot" REPORT_URL="http://127.0.0.1:$port/api/v1/push/influx/write" REPORT_AUTH='12345:glc_to"k\en=' >"$tmp/rp/out" 2>&1 ||
  { cat "$tmp/rp/out"; fail "report-publish: an accepted report failed"; }
kill "$listener"
{
  IFS= read -r path && IFS= read -r auth && IFS= read -r ctype && IFS= read -r one && IFS= read -r two
} <"$tmp/rp/got" || fail "report-publish: the listener got $(cat "$tmp/rp/got")"
[ "$path" = /api/v1/push/influx/write ] || fail "report-publish: path $path"
[ "$auth" = '12345:glc_to"k\en=' ] || fail "report-publish: basic auth was $auth"
[ "$ctype" = text/plain ] || fail "report-publish: content type $ctype"
[[ $one =~ ^sadbox_image_published,name=sprobot,version=0123456\ timestamp_seconds=[0-9]{10},commits=192$ ]] || fail "report-publish: first line: $one"
[[ $two =~ ^sadbox_image_published,name=stickybot,version=0123456\ timestamp_seconds=[0-9]{10},commits=192$ ]] || fail "report-publish: second line: $two"
grep -qx 'reported sprobot at 0123456 (commit 192)' "$tmp/rp/out" || fail "report-publish: said $(cat "$tmp/rp/out")"

# What :latest is now (the scheduled run): each image's own revision.
listen 204
report REPORT_LATEST_OF="ghcr.io/x/sprobot ghcr.io/x/threadbot" REPORT_URL="http://127.0.0.1:$port/w" REPORT_AUTH=1:t >"$tmp/rp/out" 2>&1 ||
  { cat "$tmp/rp/out"; fail "report-publish: latest-of failed"; }
kill "$listener"
grep -Eqx 'sadbox_image_published,name=sprobot,version=aaaaaaa timestamp_seconds=[0-9]{10},commits=584' "$tmp/rp/got" || fail "report-publish: latest-of sent $(cat "$tmp/rp/got")"
grep -Eqx 'sadbox_image_published,name=threadbot,version=bbbbbbb timestamp_seconds=[0-9]{10},commits=585' "$tmp/rp/got" || fail "report-publish: latest-of sent $(cat "$tmp/rp/got")"

listen 401
if report REPORT_NAMES=sprobot REPORT_URL="http://127.0.0.1:$port/secret-path" REPORT_AUTH=12345:wrong >"$tmp/rp/out" 2>&1; then
  fail "report-publish: a refused report passed"
fi
kill "$listener"
grep -q 'HTTP 401' "$tmp/rp/out" || fail "report-publish: a refused report didn't give the status: $(cat "$tmp/rp/out")"
if grep -q -e 127.0.0.1 -e secret-path -e wrong "$tmp/rp/out"; then fail "report-publish: a failure named the endpoint or the credentials"; fi

# Nothing is sent for a bad name, version or image, a commit or a label
# that can't be found, both modes at once, neither, or without the secrets.
listen 204
for bad in 'REPORT_NAMES=Sprobot' 'REPORT_NAMES=a,b=c' 'REPORT_NAMES=' 'REPORT_VERSION=0123456789' 'REPORT_VERSION=main' \
  'REPORT_AUTH=' 'REPORT_URL=' "GITHUB_SHA=$b$b" "GITHUB_SHA=${a//a/d}" 'REPORT_LATEST_OF=ghcr.io/x/sprobot' \
  'REPORT_NAMES= REPORT_LATEST_OF=ghcr.io/x/mixed' 'REPORT_NAMES= REPORT_LATEST_OF=ghcr.io/x/nolabel' \
  'REPORT_NAMES= REPORT_LATEST_OF=ghcr.io/x/missing' 'REPORT_NAMES= REPORT_LATEST_OF=ghcr.io/x/elsewhere' \
  'REPORT_NAMES= REPORT_LATEST_OF=sprobot' 'REPORT_NAMES= REPORT_LATEST_OF=ghcr.io/x/Sprobot:latest'; do
  read -r -a override <<<"$bad"
  args=(REPORT_NAMES=sprobot REPORT_URL="http://127.0.0.1:$port/" REPORT_AUTH=1:t "${override[@]}")
  if report "${args[@]}" >"$tmp/rp/out" 2>&1; then fail "report-publish accepted $bad"; fi
  [ ! -e "$tmp/rp/got" ] || fail "report-publish sent a report for $bad"
done
kill "$listener"

# newer-than-latest/newer.sh, with stand-ins for docker (what :latest was
# built from) and gh (how that commit stands to this one): false only when
# :latest is ahead; true when there is nothing to move back from; a
# registry or an API that doesn't answer fails rather than guess.
mkdir -p "$tmp/nl/bin"
rev() { printf "$1%.0s" $(seq 40); }
cat >"$tmp/nl/bin/docker" <<SH
#!/usr/bin/env bash
index() { printf '{"linux/amd64":{"config":{"Labels":{"org.opencontainers.image.revision":"%s"}}},"linux/arm64":{"config":{"Labels":{"org.opencontainers.image.revision":"%s"}}}}\n' "\$1" "\$1"; }
case "\$4" in
ghcr.io/x/older:latest) index $(rev a) ;;
ghcr.io/x/later:latest) index $(rev b) ;;
ghcr.io/x/same:latest) index $head ;;
ghcr.io/x/elsewhere:latest) index $(rev c) ;;
ghcr.io/x/apidown:latest) index $(rev d) ;;
ghcr.io/x/branchy:latest) index $(rev e) ;;
ghcr.io/x/nolabel:latest) echo '{"linux/amd64":{"config":{"Labels":{}}}}' ;;
ghcr.io/x/missing:latest) echo "ERROR: ghcr.io/x/missing:latest: not found" >&2 && exit 1 ;;
*) echo "ERROR: connection refused" >&2 && exit 1 ;;
esac
SH
cat >"$tmp/nl/bin/gh" <<SH
#!/usr/bin/env bash
# gh api repos/<repo>/compare/<base>...<head> --jq .status
case "\$2" in
repos/sadbox/ci/compare/$(rev a)...$head) echo ahead ;;
repos/sadbox/ci/compare/$(rev b)...$head) echo behind ;;
repos/sadbox/ci/compare/$(rev e)...$head) echo diverged ;;
repos/sadbox/ci/compare/$(rev c)...$head) echo "gh: Not Found (HTTP 404)" >&2 && exit 1 ;;
*) echo "gh: Server Error (HTTP 500)" >&2 && exit 1 ;;
esac
SH
chmod +x "$tmp/nl/bin/docker" "$tmp/nl/bin/gh"
newer() { # newer <image>: prints what it wrote to GITHUB_OUTPUT
  : >"$tmp/nl/out"
  env -i PATH="$tmp/nl/bin:$PATH" GITHUB_SHA=$head GITHUB_REPOSITORY=sadbox/ci GH_TOKEN=x GITHUB_OUTPUT="$tmp/nl/out" \
    IMAGE="$1" bash "$root/newer-than-latest/newer.sh" >"$tmp/nl/log" 2>&1 || return 1
  cat "$tmp/nl/out"
}
for image in older same elsewhere branchy nolabel missing; do
  [ "$(newer "ghcr.io/x/$image")" = newer=true ] || { cat "$tmp/nl/log"; fail "newer-than-latest: $image should be newer=true"; }
done
[ "$(newer ghcr.io/x/later)" = newer=false ] || { cat "$tmp/nl/log"; fail "newer-than-latest: a later :latest should be newer=false"; }
grep -q 'not moving it back' "$tmp/nl/log" || fail "newer-than-latest: didn't say why: $(cat "$tmp/nl/log")"
for image in ghcr.io/x/apidown ghcr.io/x/regdown 'ghcr.io/x/Bad:latest' older; do
  if newer "$image" >/dev/null; then fail "newer-than-latest decided for $image"; fi
  [ ! -s "$tmp/nl/out" ] || fail "newer-than-latest wrote an output for $image"
done

echo "selftest: ok"
