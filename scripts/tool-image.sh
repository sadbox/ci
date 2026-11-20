#!/usr/bin/env bash
# tool-image.sh TOOL: the image reference (tag@digest) of TOOL's stage in
# tools/Dockerfile, the one place the tool images are pinned.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
ref=$(awk -v t="$1" 'toupper($1) == "FROM" && toupper($3) == "AS" && $4 == t { print $2 }' "$here/tools/Dockerfile")
if [ -z "$ref" ]; then
  echo "::error::tools/Dockerfile has no stage named $1" >&2
  exit 1
fi
echo "$ref"
