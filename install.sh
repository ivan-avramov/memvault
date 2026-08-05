#!/usr/bin/env bash
# One-time, user-level native backend install - not tied to any vault.
# Installs uv/fswatch/basic-memory/mcpo, clones/updates the memvault repo,
# and puts memvaultctl on PATH. macOS-only (launchd-based vaults).
#
# Usage (run once per machine, from anywhere):
#
#   curl -fsSL https://raw.githubusercontent.com/ivan-avramov/memvault/main/install.sh \
#     | bash
#
# After this, create vaults with `memvaultctl create <name>` from inside
# whatever directory you want to become a vault. Re-run this same command
# later to pull a newer memvault release from scratch, but day to day prefer
# `memvaultctl upgrade` instead - same pull-and-upgrade, no network
# dependency beyond git once this has run once.
set -euo pipefail

REPO_SLUG="${MEMVAULT_REPO:-ivan-avramov/memvault}"
INFRA_HOME="$HOME/.memvault"
INFRA_DIR="$INFRA_HOME/repo"

log() { printf '\n==> %s\n' "$1"; }

log "Installing memvault (native backend)"

# --- 1. fetch/refresh the infra repo itself -----------------------------
mkdir -p "$INFRA_HOME"
if [[ -d "$INFRA_DIR/.git" ]]; then
  log "Updating existing memvault checkout"
  git -C "$INFRA_DIR" pull --quiet
else
  log "Cloning memvault to $INFRA_DIR"
  git clone --quiet "https://github.com/$REPO_SLUG.git" "$INFRA_DIR"
fi

# --- 2. dependencies ------------------------------------------------------
if ! command -v uv >/dev/null 2>&1; then
  log "Installing uv (Python tool runner - see https://docs.astral.sh/uv/)"
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
fi

if ! command -v fswatch >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    log "Installing fswatch via Homebrew"
    brew install fswatch
  else
    echo "fswatch not found and Homebrew isn't available - install fswatch manually, then re-run." >&2
    exit 1
  fi
fi

log "Installing/updating basic-memory and mcpo (uv tool)"
uv tool install --quiet basic-memory >/dev/null || uv tool upgrade --quiet basic-memory >/dev/null
# mcpo 0.0.20 (latest as of writing) imports a name that mcp>=2.0 renamed
# (streamablehttp_client -> streamable_http_client) and crash-loops on
# startup if uv resolves a bare `mcp` dependency to 2.x. Pin mcp<2 until
# mcpo publishes a release compatible with the new name.
uv tool install --quiet mcpo --with "mcp<2" >/dev/null || uv tool upgrade --quiet mcpo --with "mcp<2" >/dev/null

# --- 3. memvaultctl -------------------------------------------------------
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

# --- 4. per-user skill install - so it's loaded in every session, not just
#        ones started from inside a vault directory. memvaultctl create still
#        also installs a project-level copy (Zed/OpenCode need a real file in
#        the vault directory; they have no per-user skill concept to use
#        instead).
mkdir -p "$HOME/.claude/skills/vnote"
cp -f "$INFRA_DIR/skills/vnote/SKILL.md" "$HOME/.claude/skills/vnote/SKILL.md"

# --- 5. record the backend choice - one per machine, not per vault ---------
BACKEND_FILE="$INFRA_HOME/backend"
if [[ -f "$BACKEND_FILE" && "$(cat "$BACKEND_FILE")" != "native" ]]; then
  log "Switching this machine's backend from $(cat "$BACKEND_FILE") to native - existing vaults keep working, new vaults will use native"
fi
echo "native" > "$BACKEND_FILE"

log "Done. Create a vault with: cd <your-folder> && memvaultctl create <name>"
