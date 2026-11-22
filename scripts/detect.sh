#!/usr/bin/env bash
# detect.sh: which of lint.yml's linters apply to the caller's checkout
# (the current directory), as KEY=true|false lines on stdout (and in
# $GITHUB_OUTPUT when set), plus linters=<JSON list of those that run>.
# $SKIP lists linters not to run (whitespace- or comma-separated); the
# rest run when the repository has files for them:
#   - actionlint, zizmor: always (every repository has workflows)
#   - shellcheck: shell scripts (files.sh's "shell" kind)
#   - hadolint: Dockerfiles
#   - ruff: *.py
#   - osv-scanner: uv.lock
#   - npm: package-lock.json (npm audit, npm audit signatures, and eslint
#     where configured, unless eslint is skipped)
#   - ansible: the $ANSIBLE_DIRECTORY directory
#   - actions-lock: a tracked .github/workflows/actions.lock (gh
#     actions-lock --verify; a repository not yet onboarded skips it)
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
skip=" $(echo "${SKIP:-}" | tr ',' ' ' | xargs) "
known=" actionlint zizmor shellcheck hadolint ruff osv-scanner npm eslint ansible actions-lock "
for s in $skip; do
  case $known in
  *" $s "*) ;;
  *)
    echo "::error::skip: unknown linter $s (known:$known)" >&2
    exit 1
    ;;
  esac
done

# Any file of the kind: files.sh's output is non-empty.
has() { [ "$(bash "$here/files.sh" "$1" | wc -c)" -gt 0 ]; }

# applies TOOL: whether the repository has files for TOOL.
applies() {
  case $1 in
  actionlint | zizmor) return 0 ;;
  shellcheck) has shell ;;
  hadolint) has dockerfile ;;
  ruff) has python ;;
  osv-scanner) has uvlock ;;
  npm) has npm ;;
  ansible) [ -d "${ANSIBLE_DIRECTORY:-ansible}" ] ;;
  actions-lock) git ls-files --error-unmatch .github/workflows/actions.lock >/dev/null 2>&1 ;;
  esac
}

list=()
out=${GITHUB_OUTPUT:-/dev/null}
for k in actionlint zizmor shellcheck hadolint ruff osv-scanner npm ansible actions-lock; do
  v=false
  case $skip in
  *" $k "*) ;;
  *) if applies "$k"; then v=true; fi ;;
  esac
  echo "$k=$v" | tee -a "$out"
  if [ "$v" = true ]; then list+=("\"$k\""); fi
done
eslint=true
case $skip in *" eslint "*) eslint=false ;; esac
echo "eslint=$eslint" | tee -a "$out"
linters="[$(IFS=,; echo "${list[*]}")]"
echo "linters=$linters" | tee -a "$out"
