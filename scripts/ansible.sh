#!/usr/bin/env bash
# ansible.sh PHASE: lint.yml's ansible checks, run from the root of the
# caller's checkout, on the directory $ANSIBLE_DIRECTORY.
#   setup   uv onto the runner (copied out of tools/Dockerfile's uv image)
#           and the environments: the caller's own (its pyproject.toml and
#           uv.lock in the ansible directory, if it has them) and
#           sadbox/ci's ansible-lint (tools/ansible), both --locked
#   syntax  ansible-playbook --syntax-check on each playbook, with the
#           caller's environment (else tools/ansible's ansible-core)
#   lint    ansible-lint, from tools/ansible, with the caller's
#           environment's collections
# Playbooks: $ANSIBLE_PLAYBOOKS (relative to the ansible directory), else
# its top-level *.yml/*.yaml files that name hosts or import playbooks.
set -euo pipefail

phase=$1
ci=${SADBOX_CI:-$RUNNER_TEMP/sadbox-ci}
dir=${ANSIBLE_DIRECTORY:-ansible}
bin=$RUNNER_TEMP/sadbox-ci-bin
tools=$ci/tools/ansible
export PATH=$bin:$PATH UV_NO_PROGRESS=1

root=$PWD
own=false
if [ -f "$dir/pyproject.toml" ] && [ -f "$dir/uv.lock" ]; then own=true; fi

case $phase in
setup)
  mkdir -p "$bin"
  id=$(docker create "$(bash "$ci/scripts/tool-image.sh" uv)")
  docker cp "$id:/uv" "$bin/uv"
  docker rm "$id" >/dev/null
  uv --version
  uv sync --locked --no-dev --project "$tools"
  if [ "$own" = true ]; then
    (cd "$dir" && uv sync --locked --no-dev)
  else
    echo "no pyproject.toml and uv.lock in $dir: ansible-core from sadbox/ci's tools/ansible"
  fi
  ;;

syntax)
  cd "$dir"
  if [ -n "${ANSIBLE_PLAYBOOKS:-}" ]; then
    read -r -a playbooks <<<"$ANSIBLE_PLAYBOOKS"
  else
    playbooks=()
    for f in *.yml *.yaml; do
      if [ -f "$f" ] && grep -qE '^[[:space:]-]*(hosts|import_playbook|ansible\.builtin\.import_playbook):' "$f"; then
        playbooks+=("$f")
      fi
    done
  fi
  if [ ${#playbooks[@]} -eq 0 ]; then
    echo "::error::no playbooks found in $dir (set ansible-playbooks)"
    exit 1
  fi
  if [ "$own" = true ]; then
    pb=(uv run --locked --no-dev ansible-playbook)
  else
    pb=(uv run --locked --no-dev --project "$tools" ansible-playbook)
  fi
  failed=()
  for p in "${playbooks[@]}"; do
    echo "::group::--syntax-check $p"
    "${pb[@]}" --syntax-check "$p" || failed+=("$p")
    echo "::endgroup::"
  done
  if [ ${#failed[@]} -gt 0 ]; then
    echo "::error::--syntax-check failed: ${failed[*]}"
    exit 1
  fi
  ;;

lint)
  cd "$dir"
  if [ "$own" = true ]; then
    # The caller's site-packages holds its collections (the `ansible`
    # package installs them under ansible_collections/).
    ANSIBLE_COLLECTIONS_PATH=$(uv run --locked --no-dev python -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')
    export ANSIBLE_COLLECTIONS_PATH
  fi
  args=(--offline --project-dir .)
  if [ -n "${ANSIBLE_LINT_CONFIG:-}" ]; then
    # Relative to the repository root, like every other input.
    args+=(-c "$root/$ANSIBLE_LINT_CONFIG")
  elif [ -f .ansible-lint ] || [ -f .ansible-lint.yml ] || [ -f .config/ansible-lint.yml ] || [ -f .config/ansible-lint.yaml ]; then
    echo "using the repository's ansible-lint configuration"
  else
    args+=(-c "$ci/configs/ansible-lint.yml")
  fi
  uv run --locked --no-dev --project "$tools" ansible-lint "${args[@]}"
  ;;

*)
  echo "ansible.sh: unknown phase $phase" >&2
  exit 2
  ;;
esac
