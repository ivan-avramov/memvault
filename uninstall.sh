#!/usr/bin/env bash
# Removes the memvault *tool* from this machine: the memvaultctl symlink,
# the repo checkout (~/.memvault/repo), the backend marker
# (~/.memvault/backend), the per-user skill, and any unused memvault:*
# Docker images. Deliberately does NOT touch any vault - no vault's
# container or launchd services are stopped or removed, and
# ~/.memvault/config, ~/.memvault/logs, ports.txt, and vaults.txt (all
# vault-specific state, including a vault's basic-memory index) are left
# exactly as they are. Vault directories and their git history are never
# touched either. To remove one specific vault, use
# `memvaultctl uninstall <vault>` instead - this script won't do that.
#
# Usage:
#
#   curl -fsSL https://raw.githubusercontent.com/ivan-avramov/memvault/main/uninstall.sh \
#     | bash
#
# Defaults to a dry run - prints exactly what would be removed and does
# nothing else. Pass --yes to actually remove it:
#
#   curl -fsSL https://raw.githubusercontent.com/ivan-avramov/memvault/main/uninstall.sh \
#     | bash -s -- --yes
set -euo pipefail

INFRA_HOME="$HOME/.memvault"
INFRA_DIR="$INFRA_HOME/repo"
BACKEND_FILE="$INFRA_HOME/backend"
VAULTS_FILE="$INFRA_HOME/vaults.txt"
SKILL_DIR="$HOME/.claude/skills/vnote"

log() { printf '\n==> %s\n' "$1"; }

YES=0
for arg in "$@"; do
  [[ "$arg" == "--yes" || "$arg" == "-y" ]] && YES=1
done

VAULTS=""
[[ -f "$VAULTS_FILE" ]] && VAULTS="$(awk '{print $1}' "$VAULTS_FILE")"

BINDIR=""
for d in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin"; do
  if [[ "$(readlink "$d/memvaultctl" 2>/dev/null || true)" == *".memvault/repo/scripts/memvaultctl.sh" ]]; then
    BINDIR="$d"
    break
  fi
done

IMAGES=""
if command -v docker >/dev/null 2>&1; then
  IMAGES="$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep '^memvault:' || true)"
fi

log "This will remove:"
if [[ -n "$BINDIR" ]]; then
  echo "  - $BINDIR/memvaultctl"
else
  echo "  (no memvaultctl symlink found)"
fi
echo "  - $INFRA_DIR (repo checkout)"
echo "  - $BACKEND_FILE"
echo "  - $SKILL_DIR"
if [[ -n "$IMAGES" ]]; then
  echo "$IMAGES" | sed 's/^/  - docker image (only if unused by a running vault): /'
else
  echo "  (no memvault docker images found)"
fi

log "This will NOT touch:"
if [[ -n "$VAULTS" ]]; then
  echo "$VAULTS" | sed 's/^/  - vault (container\/services left running): /'
else
  echo "  (no registered vaults found in $VAULTS_FILE)"
fi
echo "  - $INFRA_HOME/config, $INFRA_HOME/logs, ports.txt, vaults.txt (vault-specific state)"
echo "  - vault directories or their git history"
echo
echo "To remove a specific vault instead, use: memvaultctl uninstall <vault>"

if [[ "$YES" != "1" ]]; then
  log "Dry run - nothing removed. Re-run with --yes to actually remove the tool."
  exit 0
fi

if [[ -n "$BINDIR" ]]; then
  log "Removing $BINDIR/memvaultctl"
  rm -f "$BINDIR/memvaultctl"
fi

if [[ -n "$IMAGES" ]]; then
  log "Removing unused memvault Docker images (in-use ones are skipped, not forced)"
  echo "$IMAGES" | xargs -r docker rmi >/dev/null 2>&1 || true
fi

log "Removing $SKILL_DIR"
rm -rf "$SKILL_DIR"

log "Removing $INFRA_DIR"
rm -rf "$INFRA_DIR"

log "Removing $BACKEND_FILE"
rm -f "$BACKEND_FILE"

log "Done. The memvault tool has been removed. Any registered vaults are still running - use memvaultctl uninstall <vault> for those, or reinstall to manage them again."
