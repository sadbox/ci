#!/usr/bin/env bash
# lint.sh TOOL: run one of lint.yml's linters over the caller's checkout
# (the current directory). The tool images come from tools/Dockerfile
# (tool-image.sh); the checkout is mounted read-only, except for npm, which
# installs node_modules into it. Configuration, for the tools that take
# one: the *_CONFIG input if set, else the caller's own file where the tool
# looks for it, else sadbox/ci's configs/.
set -euo pipefail

tool=$1
ci=${SADBOX_CI:-$RUNNER_TEMP/sadbox-ci}
image() { bash "$ci/scripts/tool-image.sh" "$1"; }
files() { bash "$ci/scripts/files.sh" "$1"; }

# config INPUT DEFAULT CANDIDATE...: the configuration to pass, as a path
# under /repo (the caller's file) or /sadbox-ci (ours), or nothing when the
# caller has one the tool finds by itself.
config() {
  local input=$1 default=$2
  shift 2
  if [ -n "$input" ]; then
    if [ ! -f "$input" ]; then
      echo "::error::no configuration file $input" >&2
      return 1
    fi
    echo "/repo/$input"
    return 0
  fi
  local c
  for c in "$@"; do
    if [ -f "$c" ]; then
      echo "using the repository's $c" >&2
      return 0
    fi
  done
  echo "/sadbox-ci/configs/$default"
}

run() {
  docker run --rm -v "$PWD:/repo:ro" -v "$ci:/sadbox-ci:ro" -w /repo "$@"
}

case $tool in
actionlint)
  cfg=$(config "${ACTIONLINT_CONFIG:-}" actionlint.yaml .github/actionlint.yaml .github/actionlint.yml)
  args=()
  if [ -n "$cfg" ]; then args+=(-config-file "$cfg"); fi
  # The image carries shellcheck, which actionlint runs on every run: block.
  run --entrypoint /usr/local/bin/actionlint "$(image actionlint)" -color "${args[@]}"
  ;;

zizmor)
  # configs/zizmor.yml ignores dangerous-triggers in dep-review.yaml for its
  # workflow_run; pull_request_target there must still fail.
  bash "$ci/scripts/dep-review-triggers.sh"
  cfg=$(config "${ZIZMOR_CONFIG:-}" zizmor.yml zizmor.yml zizmor.yaml .github/zizmor.yml .github/zizmor.yaml)
  args=(--format=github)
  if [ -n "$cfg" ]; then args+=(--config "$cfg"); fi
  if [ "${ZIZMOR_ONLINE:-true}" = true ]; then
    # The job's read-only token: zizmor's online audits (known-vulnerable
    # actions, impostor commits, ref confusion) query the GitHub API.
    run -e GH_TOKEN "$(image zizmor)" "${args[@]}" .
  else
    run "$(image zizmor)" --offline "${args[@]}" .
  fi
  ;;

actions-lock)
  # gh-actions-lock, pinned here by version and the release asset's sha256
  # (bump both together; Dependabot can't see this pin). Run as a plain
  # binary: no gh CLI or extension install on the runner.
  version=v0.4.1
  sha256=39deb2fe714dbf74b073d8245fc7f3d50cd0eee18d5c0900e9e849ae933ae17e
  bin=$RUNNER_TEMP/gh-actions-lock
  curl -fsSL --proto '=https' -o "$bin" \
    "https://github.com/github/gh-actions-lock/releases/download/$version/linux-amd64"
  echo "$sha256  $bin" | sha256sum -c -
  chmod +x "$bin"
  # Frozen check, the job's read-only token for the API lookups: fails if
  # the lockfile is incomplete or the runner would reject a pin.
  "$bin" --verify --no-interactive
  ;;

shellcheck)
  mapfile -d '' list < <(files shell)
  printf '%s\n' "${list[@]}"
  # Configuration: the caller's .shellcheckrc, which shellcheck finds
  # from each script's directory upwards.
  run --entrypoint /bin/shellcheck "$(image shellcheck)" -- "${list[@]}"
  ;;

hadolint)
  mapfile -d '' list < <(files dockerfile)
  cfg=$(config "${HADOLINT_CONFIG:-}" hadolint.yaml .hadolint.yaml .hadolint.yml)
  args=()
  if [ -n "$cfg" ]; then args+=(--config "$cfg"); fi
  run --entrypoint /bin/hadolint "$(image hadolint)" "${args[@]}" -- "${list[@]}"
  ;;

ruff)
  mapfile -d '' list < <(files python)
  # Configuration: the caller's ruff.toml, .ruff.toml or pyproject.toml
  # [tool.ruff], which ruff finds itself; otherwise ruff's defaults.
  run "$(image ruff)" check --no-cache --force-exclude --output-format=github -- "${list[@]}"
  ;;

osv-scanner)
  mapfile -d '' list < <(files uvlock)
  args=()
  for f in "${list[@]}"; do args+=(--lockfile "$f"); done
  # Configuration: an osv-scanner.toml beside each lockfile (ignored
  # vulnerabilities, with a reason and an expiry), found by osv-scanner.
  run "$(image osv-scanner)" scan source "${args[@]}"
  ;;

npm-ci | npm-audit | npm-signatures | eslint)
  mapfile -d '' dirs < <(files npm)
  node=$(image node)
  failed=()
  for d in "${dirs[@]}"; do
    echo "::group::$tool: $d"
    case $tool in
    npm-ci)
      # Scripts off: nothing from the dependencies runs. Writable mount:
      # node_modules lands in the checkout for the steps that follow.
      cmd=(npm ci --ignore-scripts --no-audit --no-fund)
      ;;
    npm-audit) cmd=(npm audit --omit=dev) ;;
    npm-signatures)
      # npm audit signatures fails outright when nothing is installed.
      if [ -z "$(find "$d/node_modules" -mindepth 1 -maxdepth 1 ! -name .package-lock.json 2>/dev/null)" ]; then
        echo "no dependencies installed in $d: nothing to verify"
        echo "::endgroup::"
        continue
      fi
      cmd=(npm audit signatures)
      ;;
    eslint)
      cmd=()
      for c in eslint.config.js eslint.config.mjs eslint.config.cjs eslint.config.ts eslint.config.mts eslint.config.cts \
        .eslintrc.js .eslintrc.cjs .eslintrc.json .eslintrc.yml .eslintrc.yaml .eslintrc; do
        if [ -f "$d/$c" ]; then cmd=(npx --no-install eslint .); fi
      done
      if [ ${#cmd[@]} -eq 0 ]; then
        echo "no eslint configuration in $d: skipped"
        echo "::endgroup::"
        continue
      fi
      ;;
    esac
    docker run --rm -v "$PWD:/repo" -w "/repo/$d" "$node" "${cmd[@]}" || failed+=("$d")
    echo "::endgroup::"
  done
  if [ ${#failed[@]} -gt 0 ]; then
    echo "::error::$tool failed in: ${failed[*]}"
    exit 1
  fi
  ;;

*)
  echo "lint.sh: unknown tool $tool" >&2
  exit 2
  ;;
esac
