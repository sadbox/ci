#!/usr/bin/env bash
# golangci-config.sh MODULE_DIR: the golangci-lint configuration for the
# module at MODULE_DIR (relative to the caller's checkout, the current
# directory), as an absolute path: $GOLANGCI_CONFIG_INPUT (the
# golangci-config input) if set, else the module's own
# .golangci.{yml,yaml,toml,json}, else sadbox/ci's configs/golangci.yml.
set -euo pipefail

dir=$1
if [ -n "${GOLANGCI_CONFIG_INPUT:-}" ]; then
  if [ ! -f "$GOLANGCI_CONFIG_INPUT" ]; then
    echo "::error::golangci-config: no file $GOLANGCI_CONFIG_INPUT" >&2
    exit 1
  fi
  realpath "$GOLANGCI_CONFIG_INPUT"
  exit 0
fi
for f in .golangci.yml .golangci.yaml .golangci.toml .golangci.json; do
  if [ -f "$dir/$f" ]; then
    realpath "$dir/$f"
    exit 0
  fi
done
echo "${SADBOX_CI:?}/configs/golangci.yml"
