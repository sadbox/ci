#!/usr/bin/env bash
# files.sh KIND: the repository's tracked files of KIND, NUL-separated,
# run from the root of the caller's checkout. KIND is one of:
#   shell       *.sh, *.bash, *.ksh, *.dash, and any file whose first line
#               is a sh/bash/dash/ksh shebang
#   dockerfile  Dockerfile, Dockerfile.*, Containerfile*, *.Dockerfile
#   python      *.py
#   uvlock      uv.lock
#   npm         directories holding a package-lock.json
# Paths matching the extended regex $EXCLUDE (if set) are left out.
set -euo pipefail

kind=$1
exclude=${EXCLUDE:-}

tracked() {
  if [ -n "$exclude" ]; then
    git ls-files -z | grep -zEv -- "$exclude" || true
  else
    git ls-files -z
  fi
}

shebang='^#![[:space:]]*(/usr/bin/env[[:space:]]+(-S[[:space:]]+)?)?([^[:space:]]*/)?(sh|bash|dash|ksh)([[:space:]]|$)'

tracked | while IFS= read -r -d '' f; do
  if [ ! -f "$f" ]; then continue; fi # a submodule, or deleted in the worktree
  base=${f##*/}
  case $kind in
  shell)
    case $base in
    *.sh | *.bash | *.ksh | *.dash) printf '%s\0' "$f" ;;
    *.*) ;; # another extension: not a shell script, whatever its shebang
    *) if head -n 1 "$f" 2>/dev/null | grep -qE "$shebang"; then printf '%s\0' "$f"; fi ;;
    esac
    ;;
  dockerfile)
    case $base in
    Dockerfile | Dockerfile.* | Containerfile | Containerfile.* | *.Dockerfile | *.dockerfile) printf '%s\0' "$f" ;;
    esac
    ;;
  python)
    case $base in *.py) printf '%s\0' "$f" ;; esac
    ;;
  uvlock)
    if [ "$base" = uv.lock ]; then printf '%s\0' "$f"; fi
    ;;
  npm)
    if [ "$base" = package-lock.json ]; then
      d=${f%/*}
      if [ "$d" = "$f" ]; then d=.; fi
      printf '%s\0' "$d"
    fi
    ;;
  *)
    echo "files.sh: unknown kind $kind" >&2
    exit 2
    ;;
  esac
done
