#!/usr/bin/env bash
# Watches a vault directory and commits every change immediately, scoped to
# that directory even if it's nested inside a larger repo (pathspec-limited
# add/diff, so unrelated files elsewhere in the parent repo are never staged).
# Intended to run as a long-lived launchd service (KeepAlive), one per vault.
set -euo pipefail

VAULT_DIR="${1:?usage: watch-commit.sh <vault-dir>}"
GIT_ROOT="$(git -C "$VAULT_DIR" rev-parse --show-toplevel)"

if ! command -v fswatch >/dev/null 2>&1; then
  echo "fswatch not found - install with: brew install fswatch" >&2
  exit 1
fi

echo "watch-commit: monitoring $VAULT_DIR (repo root: $GIT_ROOT)"

fswatch -o --exclude '/\.git/' "$VAULT_DIR" | while read -r _; do
  git -C "$GIT_ROOT" add -A -- "$VAULT_DIR"
  if ! git -C "$GIT_ROOT" diff --cached --quiet -- "$VAULT_DIR"; then
    git -C "$GIT_ROOT" commit -q -m "auto: vault update $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  fi
done
