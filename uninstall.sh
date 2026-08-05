#!/usr/bin/env bash
# Fully removes memvault from this machine: every registered vault's
# container/services, the memvaultctl symlink, ~/.memvault (repo checkout,
# config, logs, port/vault registries), the per-user skill, and any
# memvault:* Docker images. Never touches vault directories or their git
# history - same rule as `memvaultctl uninstall <vault>`, applied to all of
# them at once plus the system-level install.
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
if [[ -n "$VAULTS" ]]; then
  echo "$VAULTS" | sed 's/^/  - vault: /'
else
  echo "  (no registered vaults found in $VAULTS_FILE)"
fi
if [[ -n "$BINDIR" ]]; then
  echo "  - $BINDIR/memvaultctl"
else
  echo "  (no memvaultctl symlink found)"
fi
echo "  - $INFRA_HOME (repo checkout, config, logs, port/vault registries)"
echo "  - $SKILL_DIR"
if [[ -n "$IMAGES" ]]; then
  echo "$IMAGES" | sed 's/^/  - docker image: /'
else
  echo "  (no memvault docker images found)"
fi
echo
echo "Vault directories and their git history are never touched by this."

if [[ "$YES" != "1" ]]; then
  log "Dry run - nothing removed. Re-run with --yes to actually remove all of the above."
  exit 0
fi

if [[ -n "$VAULTS" && -f "$INFRA_DIR/scripts/memvaultctl.sh" ]]; then
  for v in $VAULTS; do
    log "Uninstalling vault: $v"
    bash "$INFRA_DIR/scripts/memvaultctl.sh" uninstall "$v" || true
  done
fi

if [[ -n "$BINDIR" ]]; then
  log "Removing $BINDIR/memvaultctl"
  rm -f "$BINDIR/memvaultctl"
fi

if [[ -n "$IMAGES" ]]; then
  log "Removing memvault Docker images"
  echo "$IMAGES" | xargs -r docker rmi >/dev/null 2>&1 || true
fi

log "Removing $SKILL_DIR"
rm -rf "$SKILL_DIR"

log "Removing $INFRA_HOME"
rm -rf "$INFRA_HOME"

log "Done. memvault has been removed from this machine. Vault directories were left untouched."
