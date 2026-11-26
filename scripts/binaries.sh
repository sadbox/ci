#!/usr/bin/env bash
# binaries.sh: no binary file is tracked unless the repository says so
# (STANDARDS.md, Binary files). Run from the root of the caller's checkout.
# git decides both halves: a tracked file whose content it takes for binary
# (git ls-files: eolinfo -text) must carry the `binary` attribute, from a
# .gitattributes line such as
#   cmd/app/photos/*.jpg binary
# and a declared one must be no larger than $BINARY_MAX_BYTES (default
# 5 MiB), so that a pattern can't let a build in. Every offender is named,
# then the script fails. $EXCLUDE does not apply here: the declaration is
# the way to keep a binary.
set -euo pipefail

max=${BINARY_MAX_BYTES:-5242880}
case $max in
'' | *[!0-9]*)
  echo "::error::binary-max-bytes: not a number of bytes: $max" >&2
  exit 1
  ;;
esac

bad=0
# One record per tracked file, NUL-terminated: what git makes of the index
# content, the blob's size, the path. Sizes and attributes are asked for by
# record, never by a revision built from the path (":<path>" reads a path
# like "0:x" as stage 0 of x).
while IFS= read -r -d '' rec; do
  eol=${rec%%$'\t'*}
  rest=${rec#*$'\t'}
  size=${rest%%$'\t'*}
  path=${rest#*$'\t'}
  if [ "$eol" != -text ]; then continue; fi
  # As the log shows it: a path's own line breaks can't start a line (and
  # with it a workflow command) of their own.
  shown=${path//%/%25}
  shown=${shown//$'\n'/%0A}
  shown=${shown//$'\r'/%0D}
  # check-attr -z: <path> NUL <attribute> NUL <value> NUL
  mapfile -d '' -t attr < <(printf '%s\0' "$path" | git check-attr -z --stdin binary)
  if [ "${attr[2]:-}" = set ]; then
    if [ "$size" -gt "$max" ]; then
      echo "::error file=$shown::$shown: a declared binary file of $size bytes, over the $max allowed (binary-max-bytes)"
      bad=1
    else
      echo "$shown: declared binary, $size bytes"
    fi
  else
    echo "::error file=$shown::$shown: a binary file ($size bytes) that no .gitattributes line declares \`binary\`: remove it, or declare it if it belongs"
    bad=1
  fi
done < <(git ls-files -z --format='%(eolinfo:index)%x09%(objectsize)%x09%(path)')
exit "$bad"
