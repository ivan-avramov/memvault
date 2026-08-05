#!/usr/bin/env bash
# One-time, user-level Docker backend install - not tied to any vault.
# Clones/updates the memvault repo, builds the image, and puts memvaultctl
# on PATH. Cross-platform; recommended for anyone who isn't on macOS or
# doesn't want this touching global host tools.
#
# Usage (run once per machine, from anywhere):
#
#   gh api -H "Accept: application/vnd.github.raw" \
#     /repos/ivan-avramov/memvault/contents/install-docker.sh \
#     | bash
#
# After this, create vaults with `memvaultctl create <name>` from inside
# whatever directory you want to become a vault. Re-run this same command
# later to pull a newer memvault release from scratch, but day to day prefer
# `memvaultctl upgrade` instead - same pull-and-rebuild, no `gh`/network
# dependency once this has run once.
set -euo pipefail

REPO_SLUG="${MEMVAULT_REPO:-ivan-avramov/memvault}"
INFRA_HOME="$HOME/.memvault"
INFRA_DIR="$INFRA_HOME/repo"

log() { printf '\n==> %s\n' "$1"; }

# --- 0. sanity ---------------------------------------------------------
if ! command -v gh >/dev/null 2>&1; then
  echo "gh CLI not found - install it (https://cli.github.com) and 'gh auth login', then re-run." >&2
  exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
  echo "gh CLI is installed but not authenticated - run 'gh auth login', then re-run." >&2
  exit 1
fi
if ! command -v docker >/dev/null 2>&1; then
  echo "docker not found - install Docker Desktop or OrbStack, then re-run." >&2
  exit 1
fi
if ! docker info >/dev/null 2>&1; then
  echo "docker CLI found but the daemon isn't running/reachable - start it, then re-run." >&2
  exit 1
fi

log "Installing memvault (Docker backend)"

# --- 1. fetch/refresh the infra repo ---------------------------------------
mkdir -p "$INFRA_HOME"
if [[ -d "$INFRA_DIR/.git" ]]; then
  log "Updating existing memvault checkout"
  git -C "$INFRA_DIR" pull --quiet
else
  log "Cloning memvault to $INFRA_DIR"
  gh repo clone "$REPO_SLUG" "$INFRA_DIR" -- --quiet
fi

# --- 2. build the image ----------------------------------------------------
IMAGE_SHA_TAG="memvault:$(git -C "$INFRA_DIR" rev-parse --short HEAD)"
log "Building $IMAGE_SHA_TAG (also tagged memvault:local)"
docker build -q -t "$IMAGE_SHA_TAG" -t memvault:local -f "$INFRA_DIR/docker/Dockerfile" "$INFRA_DIR" >/dev/null

# --- 3. memvaultctl ----------------------------------------------------------
LINKED=0
for bindir in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin"; do
  if [[ -w "$bindir" ]]; then
    mkdir -p "$bindir"
    ln -sf "$INFRA_DIR/scripts/memvaultctl.sh" "$bindir/memvaultctl"
    log "memvaultctl linked to $bindir/memvaultctl - see 'memvaultctl status'"
    LINKED=1
    break
  fi
done
if [[ "$LINKED" == "0" ]]; then
  log "No writable directory found on PATH to link memvaultctl"
  echo "Add one (e.g. 'mkdir -p ~/.local/bin' and add it to PATH), then re-run," >&2
  echo "or invoke it directly: bash $INFRA_DIR/scripts/memvaultctl.sh <command>" >&2
fi

# --- 4. record the backend choice - one per machine, not per vault ---------
BACKEND_FILE="$INFRA_HOME/backend"
if [[ -f "$BACKEND_FILE" && "$(cat "$BACKEND_FILE")" != "docker" ]]; then
  log "Switching this machine's backend from $(cat "$BACKEND_FILE") to docker - existing vaults keep working, new vaults will use docker"
fi
echo "docker" > "$BACKEND_FILE"

log "Done. Create a vault with: cd <your-folder> && memvaultctl create <name>"
