#!/usr/bin/env bash
# dep-review-triggers.sh: configs/zizmor.yml exempts the dep-review gate's
# caller (any dep-review.yaml) from zizmor's dangerous-triggers audit, which
# it needs for workflow_run. That exemption covers the whole file, so refuse
# pull_request_target in it here: it would run with the repository's
# secrets in the default branch's context. Run from the repository root.
set -euo pipefail

status=0
while IFS= read -r -d '' f; do
  if grep -nE '(^|[^A-Za-z0-9_-])pull_request_target([^A-Za-z0-9_-]|$)' "$f"; then
    echo "::error file=$f::pull_request_target is not allowed in the dep-review gate's caller"
    status=1
  fi
done < <(find . -path ./.git -prune -o -type f \( -name dep-review.yaml -o -name dep-review.yml \) -print0)
exit $status
