#!/usr/bin/env bash
# report.sh: report-publish's one step (action.yml). One line of Influx line
# protocol per image, which Grafana Cloud stores as two series:
#
#   sadbox_image_published_timestamp_seconds{name="<name>", version="<7>"} <now>
#   sadbox_image_published_commits{name="<name>", version="<7>"} <position>
#
# The position is the commit's place in the repository's history: how many
# commits it has behind it, itself included (GitHub's API, with the job's
# own token). History on a default branch only grows, so a build with a
# higher position is the newer one, whatever order the reports came in.
#
# Two modes:
#   REPORT_NAMES: the images this run just made :latest, at GITHUB_SHA.
#   REPORT_LATEST_OF: image repositories (ghcr.io/owner/name); what each
#     one's :latest is now, by its org.opencontainers.image.revision label
#     (a scheduled run: it repairs a report that was missed).
# And REPORT_URL, REPORT_AUTH (<id>:<token>), GH_TOKEN, GITHUB_REPOSITORY;
# REPORT_VERSION overrides the first mode's version (GITHUB_SHA's first 7
# characters). Says nothing of the endpoint or the credentials: the caller
# may be a public repository.
set -euo pipefail

fail() {
  echo "::error::report-publish: $*"
  exit 1
}

[ -n "${REPORT_URL:-}" ] && [ -n "${REPORT_AUTH:-}" ] ||
  fail "no url or auth: is the job in the publish environment, on the default branch?"
read -r -a names <<<"${REPORT_NAMES:-}"
read -r -a images <<<"${REPORT_LATEST_OF:-}"
if [ "${#names[@]}" -gt 0 ] && [ "${#images[@]}" -gt 0 ]; then fail "names and latest-of are either-or"; fi
[ "${#names[@]}" -gt 0 ] || [ "${#images[@]}" -gt 0 ] || fail "no names and no latest-of"

# position <full sha>: the commit's place in this repository's history.
position() {
  local n
  # shellcheck disable=SC2016 # GraphQL's variables, not the shell's
  n=$(gh api graphql \
    -f query='query($o: String!, $n: String!, $oid: GitObjectID!) { repository(owner: $o, name: $n) { object(oid: $oid) { ... on Commit { history { totalCount } } } } }' \
    -f o="${GITHUB_REPOSITORY%/*}" -f n="${GITHUB_REPOSITORY#*/}" -f oid="$1" \
    --jq '.data.repository.object.history.totalCount // empty' 2>/dev/null) || n=
  [[ $n =~ ^[1-9][0-9]*$ ]] || fail "no place in ${GITHUB_REPOSITORY}'s history for commit $1 (the job needs contents: read)"
  echo "$n"
}

now=$(date +%s)
body=
said=()
add() { # add <name> <version> <full sha>
  [[ $1 =~ ^[a-z0-9][a-z0-9-]*$ ]] || fail "not a container name: '$1'"
  [[ $2 =~ ^[0-9a-f]{7}$ ]] || fail "version must be 7 hex characters: '$2'"
  local n
  n=$(position "$3")
  body+="sadbox_image_published,name=$1,version=$2 timestamp_seconds=${now},commits=${n}"$'\n'
  said+=("$1 at $2 (commit $n)")
}

if [ "${#names[@]}" -gt 0 ]; then
  [[ ${GITHUB_SHA:-} =~ ^[0-9a-f]{40}$ ]] || fail "no GITHUB_SHA"
  version=${REPORT_VERSION:-}
  [ -n "$version" ] || version=${GITHUB_SHA:0:7}
  for name in "${names[@]}"; do add "$name" "$version" "$GITHUB_SHA"; done
else
  for image in "${images[@]}"; do
    [[ $image =~ ^[a-z0-9][a-z0-9./-]*/[a-z0-9][a-z0-9-]*$ ]] || fail "not an image repository: '$image'"
    # Every platform of the index carries the label; they must agree.
    rev=$(docker buildx imagetools inspect "${image}:latest" --format '{{json .Image}}' 2>/dev/null |
      jq -r '[.. | objects | .Labels? | objects | .["org.opencontainers.image.revision"] // empty] | unique | if length == 1 then .[0] else empty end' 2>/dev/null) || rev=
    [[ $rev =~ ^[0-9a-f]{40}$ ]] || fail "no single org.opencontainers.image.revision on ${image##*/}:latest (is the job logged in to the registry?)"
    add "${image##*/}" "${rev:0:7}" "$rev"
  done
fi

# The credentials by a config file on stdin, not argv; the body from a
# file. Retries what may pass (timeouts, 408, 429, 5xx, a refused
# connection), not a 4xx. curl's own messages name the host, so they are
# dropped: the status and the exit code say enough.
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
printf '%s' "$body" >"$tmp"
# In curl's config syntax a quoted value escapes \ and " with a backslash.
[[ $REPORT_AUTH != *$'\n'* ]] || fail "auth has a newline in it"
auth=${REPORT_AUTH//\\/\\\\}
auth=${auth//\"/\\\"}
rc=0
status=$(printf 'user = "%s"\n' "$auth" | curl --config - --silent --fail \
  --retry 5 --retry-connrefused --retry-max-time 120 --max-time 20 \
  --header 'Content-Type: text/plain' --data-binary "@$tmp" \
  --output /dev/null --write-out '%{http_code}' "$REPORT_URL" 2>/dev/null) || rc=$?
[ "$rc" = 0 ] || fail "the report was not accepted (HTTP ${status:-none}, curl exit $rc)"
printf 'reported %s\n' "${said[@]}"
