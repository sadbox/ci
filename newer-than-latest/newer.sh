#!/usr/bin/env bash
# newer.sh: newer-than-latest's one step (action.yml). Writes newer=true or
# newer=false to GITHUB_OUTPUT: false only when IMAGE's :latest was built
# from a commit ahead of GITHUB_SHA in GITHUB_REPOSITORY's history, i.e.
# when moving :latest to this build would move it back (a re-run of an old
# publish, after a newer one).
#
# True when there is nothing to move back from: no :latest yet, one with
# no revision label, or one whose commit isn't in this history. What can't
# be decided (the registry or the API not answering) fails the job rather
# than guess: a re-run decides again.
set -euo pipefail

fail() {
  echo "::error::newer-than-latest: $*"
  exit 1
}
decide() { # decide <true|false> <why>
  echo "newer=$1" >>"$GITHUB_OUTPUT"
  echo "::notice::newer-than-latest: ${IMAGE##*/}: $2"
  exit 0
}

IMAGE=${IMAGE:-}
[[ $IMAGE =~ ^[a-z0-9][a-z0-9./-]*/[a-z0-9][a-z0-9-]*$ ]] || fail "not an image repository: '$IMAGE'"
[[ ${GITHUB_SHA:-} =~ ^[0-9a-f]{40}$ ]] || fail "no GITHUB_SHA"

err=$(mktemp)
trap 'rm -f "$err"' EXIT
if ! inspected=$(docker buildx imagetools inspect "${IMAGE}:latest" --format '{{json .Image}}' 2>"$err"); then
  if grep -qi 'not found' "$err"; then decide true "no :latest yet"; fi
  fail "can't read ${IMAGE##*/}:latest (is the job logged in to the registry?)"
fi
# Every platform of the index carries the label; they must agree.
rev=$(jq -r '[.. | objects | .Labels? | objects | .["org.opencontainers.image.revision"] // empty] | unique | if length == 1 then .[0] else empty end' <<<"$inspected")
[[ $rev =~ ^[0-9a-f]{40}$ ]] || decide true ":latest has no single revision label"
[ "$rev" != "$GITHUB_SHA" ] || decide true ":latest is this commit's"

# base...head: how head (this commit) stands to base (:latest's).
if ! status=$(gh api "repos/${GITHUB_REPOSITORY}/compare/${rev}...${GITHUB_SHA}" --jq .status 2>"$err"); then
  if grep -q 'HTTP 404' "$err"; then decide true ":latest's commit ${rev:0:7} isn't in this repository's history"; fi
  fail "can't compare ${rev:0:7} with ${GITHUB_SHA:0:7} (the job needs contents: read)"
fi
case $status in
ahead) decide true "this commit is ahead of :latest's (${rev:0:7})" ;;
behind) decide false ":latest is at ${rev:0:7}, a later commit than this one (${GITHUB_SHA:0:7}): not moving it back" ;;
diverged) decide true ":latest's commit ${rev:0:7} is off this branch's history" ;;
*) fail "compare said '$status'" ;;
esac
