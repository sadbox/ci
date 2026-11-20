#!/usr/bin/env bash
# go-modules.sh PHASE: go-check.sh PHASE in each module of $MODULES
# (whitespace-separated directories relative to the checkout), on the
# runner (setup-go mode). Every module runs; the step fails if any did.
set -uo pipefail

phase=$1
ci=${SADBOX_CI:-$RUNNER_TEMP/sadbox-ci}
export SADBOX_CI=$ci SADBOX_CI_BIN=$RUNNER_TEMP/sadbox-ci-bin
failed=()
for m in ${MODULES:?}; do
  echo "::group::$phase: $m"
  if [ "$phase" = lint ]; then
    if ! GOLANGCI_CONFIG=$(bash "$ci/scripts/golangci-config.sh" "$m"); then
      failed+=("$m")
      echo "::endgroup::"
      continue
    fi
    export GOLANGCI_CONFIG
    echo "golangci-lint configuration: $GOLANGCI_CONFIG"
  fi
  (cd "$m" && bash "$ci/scripts/go-check.sh" "$phase") || failed+=("$m")
  echo "::endgroup::"
done
if [ ${#failed[@]} -gt 0 ]; then
  echo "::error::$phase failed in: ${failed[*]}"
  exit 1
fi
