#!/usr/bin/env bash
# go-workflow.sh: every Go module in the caller's checkout (the current
# directory) is checked by sadbox/ci's go.yml (STANDARDS.md, Go), so no
# repository keeps a hand-rolled Go CI that misses a check (golangci-lint,
# govulncheck, a platform). A module is a directory with a tracked go.mod,
# outside testdata/, vendor/ and dot directories (as go-check.sh's gofmt).
#
# A workflow call of go.yml (`uses: sadbox/ci/.github/workflows/go.yml@…`,
# or `./.github/workflows/go.yml` in sadbox/ci itself) covers its `context`
# (Docker mode, default ".") and the directories in its `modules` (setup-go
# mode, default "."). A value with a ${{ }} expression can't be read here:
# it counts as covering every module, with a notice. The workflows are
# read line by line, not parsed: a `uses:` line starts a call, which ends
# at the next line indented no deeper than it.
#
# $GO_EXEMPT lists modules not to require (whitespace-separated), each a
# deviation recorded in STANDARDS.md; an entry that names no module fails.
set -euo pipefail

norm() {
  local d=${1#./}
  d=${d%/}
  [ -n "$d" ] || d=.
  printf '%s\n' "$d"
}

mapfile -t modules < <(git ls-files -- 'go.mod' '*/go.mod' |
  grep -vE '(^|/)(testdata|vendor|\.[^/]+)/' |
  while IFS= read -r m; do norm "$(dirname "$m")"; done | sort -u)

exempt=()
status=0
for e in ${GO_EXEMPT:-}; do
  e=$(norm "$e")
  if ! printf '%s\n' "${modules[@]}" | grep -qxF -- "$e"; then
    echo "::error::go-exempt: $e has no go.mod (a stale exemption)"
    status=1
  fi
  exempt+=("$e")
done

if [ ${#modules[@]} -eq 0 ]; then
  exit $status
fi

# covered: one directory per line, or "*" for a call this can't read.
# shellcheck disable=SC2016 # an awk program, and a literal ${{, not shell
covered=$(git ls-files -z -- '.github/workflows/*.yml' '.github/workflows/*.yaml' |
  xargs -0 -r awk '
    function indent(s) { match(s, /^ */); return RLENGTH }
    function val(s) {
      sub(/^[^:]*:[ \t]*/, "", s); sub(/[ \t]+#.*$/, "", s)
      gsub(/^["\047]|["\047]$/, "", s)
      return s
    }
    function flush() {
      if (!incall) return
      if (ctx == "") ctx = "."
      if (mods == "") mods = "."
      print ctx
      n = split(mods, m, /[ \t]+/)
      for (i = 1; i <= n; i++) if (m[i] != "") print m[i]
      incall = 0; ctx = ""; mods = ""; block = ""
    }
    FNR == 1 { flush() }
    /^[ \t]*#/ { next }
    {
      if (incall && $0 !~ /^[ \t]*$/ && indent($0) <= callindent && $0 !~ /^[ \t]*(with|secrets|needs|if|permissions|name|strategy):/) flush()
      if (block != "") {
        if ($0 ~ /^[ \t]*$/ || indent($0) > blockindent) { mods = mods " " $0; next }
        block = ""
      }
    }
    /^[ \t-]*uses:[ \t]*["\047]?(sadbox\/ci\/|\.\/)\.github\/workflows\/go\.yml/ {
      flush(); incall = 1; callindent = indent($0); sub(/^ *- */, "", $0); next
    }
    incall && /^[ \t]*context:/ { ctx = val($0); next }
    incall && /^[ \t]*modules:/ {
      v = val($0)
      if (v ~ /^[|>]/) { block = "modules"; blockindent = indent($0); mods = "" } else mods = v
      next
    }
    END { flush() }
  ' | while IFS= read -r d; do
    d=$(echo "$d" | xargs)
    [ -n "$d" ] || continue
    case $d in
    *'${{'*) echo '*' ;;
    *) norm "$d" ;;
    esac
  done | sort -u)

if grep -qxF '*' <<<"$covered"; then
  echo "::notice::go-workflow: a go.yml call takes its context or modules from an expression; counted as covering every module"
  exit $status
fi

for m in "${modules[@]}"; do
  if printf '%s\n' "${exempt[@]}" | grep -qxF -- "$m"; then
    echo "go-workflow: $m exempt (go-exempt; see STANDARDS.md, Deviations)"
    continue
  fi
  if grep -qxF -- "$m" <<<"$covered"; then
    echo "go-workflow: $m checked by go.yml"
  else
    echo "::error::go-workflow: the Go module in $m isn't checked by sadbox/ci's go.yml (STANDARDS.md, Go): call it with context: $m (Docker mode) or modules: $m (setup-go mode), or record a deviation and list it in go-exempt"
    status=1
  fi
done
exit $status
