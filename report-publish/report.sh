#!/usr/bin/env bash
# report.sh: report-publish's one step (action.yml). One line of Influx line
# protocol per image, which Grafana Cloud stores as
#
#   sadbox_image_published_timestamp_seconds{name="<name>", version="<7>"} <now>
#
# REPORT_NAMES (space-separated), REPORT_URL, REPORT_AUTH (<id>:<token>);
# REPORT_VERSION defaults to GITHUB_SHA's first 7 characters. Says nothing
# of the endpoint or the credentials: the caller may be a public repository.
set -euo pipefail

fail() {
  echo "::error::report-publish: $*"
  exit 1
}

[ -n "${REPORT_URL:-}" ] && [ -n "${REPORT_AUTH:-}" ] ||
  fail "no url or auth: is the job in the publish environment, on the default branch?"
version=${REPORT_VERSION:-}
[ -n "$version" ] || version=${GITHUB_SHA:0:7}
[[ $version =~ ^[0-9a-f]{7}$ ]] || fail "version must be 7 hex characters: '$version'"
read -r -a names <<<"${REPORT_NAMES:-}"
[ "${#names[@]}" -gt 0 ] || fail "no names"

now=$(date +%s)
body=
for name in "${names[@]}"; do
  [[ $name =~ ^[a-z0-9][a-z0-9-]*$ ]] || fail "not a container name: '$name'"
  body+="sadbox_image_published,name=${name},version=${version} timestamp_seconds=${now}"$'\n'
done

# The credentials by a config file on stdin, not argv; the body from a
# file. Retries what may pass (timeouts, 408, 429, 5xx, a refused
# connection), not a 4xx. curl's own messages name the host, so they are
# dropped: the status and the exit code say enough.
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
printf '%s' "$body" >"$tmp"
rc=0
# In curl's config syntax a quoted value escapes \ and " with a backslash.
[[ $REPORT_AUTH != *$'\n'* ]] || fail "auth has a newline in it"
auth=${REPORT_AUTH//\\/\\\\}
auth=${auth//\"/\\\"}
status=$(printf 'user = "%s"\n' "$auth" | curl --config - --silent --fail \
  --retry 5 --retry-connrefused --retry-max-time 120 --max-time 20 \
  --header 'Content-Type: text/plain' --data-binary "@$tmp" \
  --output /dev/null --write-out '%{http_code}' "$REPORT_URL" 2>/dev/null) || rc=$?
[ "$rc" = 0 ] || fail "the report was not accepted (HTTP ${status:-none}, curl exit $rc)"
echo "reported ${names[*]} at $version"
