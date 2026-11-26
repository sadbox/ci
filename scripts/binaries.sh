#!/usr/bin/env bash
# binaries.sh: no binary file is tracked unless the repository says so
# (STANDARDS.md, Binary files). Run from the root of the caller's checkout.
# git decides both halves: a tracked file whose content it takes for binary
# (git ls-files --eol: i/-text) must carry the `binary` attribute, from a
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
while IFS= read -r -d '' rec; do
  # "i/<index> w/<worktree> attr/<attrs> \t<path>"
  path=${rec#*$'\t'}
  case $rec in
  i/-text*) ;;
  *) continue ;;
  esac
  size=$(git cat-file -s ":$path")
  declared=$(git check-attr binary -- "$path")
  case $declared in
  *": binary: set")
    if [ "$size" -gt "$max" ]; then
      echo "::error file=$path::$path: a declared binary file of $size bytes, over the $max allowed (binary-max-bytes)"
      bad=1
    else
      echo "$path: declared binary, $size bytes"
    fi
    ;;
  *)
    echo "::error file=$path::$path: a binary file ($size bytes) that no .gitattributes line declares \`binary\`: remove it, or declare it if it belongs"
    bad=1
    ;;
  esac
done < <(git ls-files --eol -z)
exit "$bad"
