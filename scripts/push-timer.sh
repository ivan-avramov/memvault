#!/usr/bin/env bash
# Pulls (rebase, autostash) then pushes a vault's repo root. Runs once and
# exits - intended to be invoked on a schedule via launchd's StartInterval,
# not as an internal sleep loop. Operates on the whole repo (pull/push are
# repo-level, not path-scoped) - if the vault is nested inside a larger repo,
# this pushes that repo's entire current branch, not just the vault subtree.
set -euo pipefail

VAULT_DIR="${1:?usage: push-timer.sh <vault-dir>}"
GIT_ROOT="$(git -C "$VAULT_DIR" rev-parse --show-toplevel)"

# Nothing to sync if no remote is configured yet (e.g. work vault before
# IT/security has approved a remote - see the still-open item in
# DESIGN.md). Silently no-op rather than erroring the launchd job.
if ! git -C "$GIT_ROOT" remote get-url origin >/dev/null 2>&1; then
  exit 0
fi

# --autostash covers the case where the watcher (a separate process) commits
# mid-rebase; --rebase keeps history linear against a second writer (the
# eventual mobile/always-on-host path) without merge commits.
git -C "$GIT_ROOT" pull --rebase --autostash --quiet
git -C "$GIT_ROOT" push --quiet
