#!/usr/bin/env bash
# Bootstraps the current directory as a Basic Memory vault: registers it as
# an isolated BM project, installs the note-writing skill, and starts
# background services (mcpo bridge, and - if the folder is git-tracked -
# a commit watcher and push timer) via launchd.
#
# Usage: cd into the folder you want to become a vault (fresh, or already
# git-tracked, or nested inside another repo - all supported), then:
#
#   gh api -H "Accept: application/vnd.github.raw" \
#     /repos/ivan-avramov/memvault-infra/contents/install.sh \
#     | bash -s -- personal-vault
#
# `gh api` (not curl) so this works against a private memvault-infra repo too,
# riding your existing `gh auth login` session.
#
# The vault name is used as: the Basic Memory project name, the isolated
# config dir under ~/.memvault-infra/config/<name>/, and the launchd service
# label suffix. Run it once per vault (work vault, personal vault - each in
# its own directory) - every vault gets its own fully isolated BM config dir
# and its own mcpo/port, so a client attached to one vault's mcpo port cannot
# see the other vault's projects at all.
set -euo pipefail

REPO_SLUG="${MEMVAULT_INFRA_REPO:-ivan-avramov/memvault-infra}"
INFRA_HOME="$HOME/.memvault-infra"
INFRA_DIR="$INFRA_HOME/repo"

VAULT_DIR="$(pwd)"
VAULT_NAME="${1:-$(basename "$VAULT_DIR")}"
CONFIG_DIR="$INFRA_HOME/config/$VAULT_NAME"
LOG_DIR="$INFRA_HOME/logs/$VAULT_NAME"
PORTS_FILE="$INFRA_HOME/ports.txt"

log() { printf '\n==> %s\n' "$1"; }

# --- 0. sanity ---------------------------------------------------------
if [[ "$VAULT_DIR" == "$HOME" ]]; then
  echo "Refusing to install into \$HOME directly - cd into a dedicated vault directory first." >&2
  exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "gh CLI not found - install it (https://cli.github.com) and 'gh auth login', then re-run." >&2
  exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
  echo "gh CLI is installed but not authenticated - run 'gh auth login', then re-run." >&2
  exit 1
fi

log "Bootstrapping vault '$VAULT_NAME' at $VAULT_DIR"

# --- 1. fetch/refresh the infra repo itself -----------------------------
mkdir -p "$INFRA_HOME"
if [[ -d "$INFRA_DIR/.git" ]]; then
  log "Updating existing memvault-infra checkout"
  git -C "$INFRA_DIR" pull --quiet
else
  log "Cloning memvault-infra to $INFRA_DIR"
  gh repo clone "$REPO_SLUG" "$INFRA_DIR" -- --quiet
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

UVX_PATH="$(command -v uvx)"

# --- 3. vault directory setup ---------------------------------------------
# No git init, ever - the folder may intentionally be un-tracked, or already
# be its own repo, or be nested inside a larger one. Detect and adapt.
HAS_GIT=0
GIT_ROOT=""
if git -C "$VAULT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  HAS_GIT=1
  GIT_ROOT="$(git -C "$VAULT_DIR" rev-parse --show-toplevel)"
  if [[ "$GIT_ROOT" != "$VAULT_DIR" ]]; then
    log "Vault is nested inside an existing repo at $GIT_ROOT"
  fi
fi

if [[ "$HAS_GIT" == "1" ]]; then
  GITIGNORE="$VAULT_DIR/.gitignore"
  touch "$GITIGNORE"
  for pattern in ".DS_Store" ".basic-memory/"; do
    grep -qxF "$pattern" "$GITIGNORE" || echo "$pattern" >> "$GITIGNORE"
  done
else
  log "No git repo detected - skipping .gitignore, commit watcher, and push timer"
fi

mkdir -p "$VAULT_DIR/.claude/skills/memnote"
cp -f "$INFRA_DIR/skills/memnote/SKILL.md" "$VAULT_DIR/.claude/skills/memnote/SKILL.md"

# --- 4. isolated Basic Memory project registration ------------------------
log "Registering '$VAULT_NAME' as an isolated Basic Memory project"
mkdir -p "$CONFIG_DIR" "$LOG_DIR"
BASIC_MEMORY_CONFIG_DIR="$CONFIG_DIR" "$UVX_PATH" basic-memory project add "$VAULT_NAME" "$VAULT_DIR" --quiet 2>/dev/null \
  || BASIC_MEMORY_CONFIG_DIR="$CONFIG_DIR" "$UVX_PATH" basic-memory project add "$VAULT_NAME" "$VAULT_DIR"

# --- 5. port assignment ----------------------------------------------------
mkdir -p "$(dirname "$PORTS_FILE")"; touch "$PORTS_FILE"
PORT="$(awk -v n="$VAULT_NAME" '$1==n{print $2}' "$PORTS_FILE")"
if [[ -z "$PORT" ]]; then
  PORT=8100
  while grep -q " $PORT\$" "$PORTS_FILE"; do PORT=$((PORT + 1)); done
  echo "$VAULT_NAME $PORT" >> "$PORTS_FILE"
fi
log "mcpo will serve this vault on http://127.0.0.1:$PORT"

# --- 6. mcpo config ---------------------------------------------------------
sed -e "s|__VAULT_NAME__|$VAULT_NAME|g" \
    -e "s|__CONFIG_DIR__|$CONFIG_DIR|g" \
    -e "s|__UVX_PATH__|$UVX_PATH|g" \
    "$INFRA_DIR/mcpo/config.template.json" > "$CONFIG_DIR/mcpo-config.json"

# --- 7. launchd services -----------------------------------------------------
PLIST_DIR="$HOME/Library/LaunchAgents"
mkdir -p "$PLIST_DIR"
CURRENT_PATH="$PATH"

install_plist() {
  local template="$1" label_suffix="$2"
  local out="$PLIST_DIR/com.memvault-infra.$VAULT_NAME.$label_suffix.plist"
  sed -e "s|__VAULT_NAME__|$VAULT_NAME|g" \
      -e "s|__VAULT_DIR__|$VAULT_DIR|g" \
      -e "s|__INFRA_DIR__|$INFRA_DIR|g" \
      -e "s|__CONFIG_DIR__|$CONFIG_DIR|g" \
      -e "s|__LOG_DIR__|$LOG_DIR|g" \
      -e "s|__PORT__|$PORT|g" \
      -e "s|__UVX_PATH__|$UVX_PATH|g" \
      -e "s|__PATH__|$CURRENT_PATH|g" \
      "$INFRA_DIR/launchd/templates/$template" > "$out"
  launchctl unload "$out" >/dev/null 2>&1 || true
  launchctl load -w "$out"
  echo "  loaded: $out"
}

log "Installing launchd services"
install_plist "mcpo.plist.template" "mcpo"
SERVICES="mcpo"
if [[ "$HAS_GIT" == "1" ]]; then
  install_plist "watch.plist.template" "watch"
  install_plist "push.plist.template" "push"
  SERVICES="mcpo,watch,push"
fi

# --- 7b. memvaultctl -------------------------------------------------------
for bindir in /opt/homebrew/bin /usr/local/bin; do
  if [[ -w "$bindir" ]]; then
    ln -sf "$INFRA_DIR/scripts/memvaultctl.sh" "$bindir/memvaultctl"
    log "memvaultctl linked to $bindir/memvaultctl - see 'memvaultctl status'"
    break
  fi
done

# --- 8. integration instructions --------------------------------------------
INSTRUCTIONS="$VAULT_DIR/INTEGRATIONS.md"
{
cat <<EOF
# Connecting clients to the '$VAULT_NAME' vault

Generated by memvault-infra/install.sh - re-run the installer to regenerate.

## Claude Code (stdio, no bridge)

Don't hand-edit \`.mcp.json\` - project-scoped servers defined there need an
explicit approval step (\`⏸ Pending approval\` in \`claude mcp get\`) before
Claude Code will actually connect, and it's easy to miss that they're sitting
unapproved rather than connected. Use the CLI instead, which registers under
\`local\` scope (your personal config, not a committed file - no approval
prompt):

\`\`\`bash
claude mcp add-json $VAULT_NAME '{"command": "$UVX_PATH", "args": ["basic-memory", "mcp"], "env": {"BASIC_MEMORY_CONFIG_DIR": "$CONFIG_DIR", "BASIC_MEMORY_MCP_PROJECT": "$VAULT_NAME"}}' --scope local
\`\`\`

Verify with \`claude mcp list\` (should show \`✔ Connected\`, not pending) before
testing a write. The project-level \`.claude/skills/memnote/SKILL.md\`
was already installed by this script and loads automatically - skill loading
and tool connection are independent, so seeing the skill in Claude's skill
list does **not** mean the MCP server is connected.

## Claude Desktop / OpenCode (stdio, no bridge)

Same underlying command, different config surface per client:

\`\`\`json
{
  "mcpServers": {
    "$VAULT_NAME": {
      "command": "$UVX_PATH",
      "args": ["basic-memory", "mcp"],
      "env": {
        "BASIC_MEMORY_CONFIG_DIR": "$CONFIG_DIR",
        "BASIC_MEMORY_MCP_PROJECT": "$VAULT_NAME"
      }
    }
  }
}
\`\`\`

Claude Desktop: paste into \`~/Library/Application Support/Claude/claude_desktop_config.json\`,
fully quit and reopen the app (no hot reload). OpenCode: this JSON shape
doesn't apply directly - add via \`opencode mcp add $VAULT_NAME --url ...\` for
a remote server, or hand-edit \`~/.config/opencode/opencode.json\`'s \`mcp\` key
with \`{"type": "local", "command": ["$UVX_PATH", "basic-memory", "mcp"],
"environment": {...}}\` for this stdio case (verified working - \`opencode mcp
list\` should report \`connected\`). OpenCode doesn't read \`SKILL.md\` - copy
this file's contents into the vault directory as \`AGENTS.md\` instead.

## Zed

Command palette -> \`agent: create skill from url\`, pointing at the copy
already installed in this vault - **not** a raw.githubusercontent.com URL:
Zed's URL import has no GitHub auth of its own, so it 404s against a private
memvault-infra repo (or a fork someone forgot to make public). The file was
already fetched via an authenticated \`gh repo clone\`, so just point at it
locally:

file://$VAULT_DIR/.claude/skills/memnote/SKILL.md

Add an MCP context server using the same command/args/env block above.

## Open WebUI (via mcpo)

mcpo is already running on port $PORT, proxying this vault only. Add it as a
tool server in OWUI pointing at \`http://127.0.0.1:$PORT/$VAULT_NAME\` - use
this host-resolvable URL, not \`host.docker.internal\`: OWUI's tool-server
calls are made client-side, from your browser, not proxied through its
backend container, so \`host.docker.internal\` (container-only) silently
fails there even though OWUI's backend could reach it fine.
Create a custom skill in OWUI's Skills workspace by pasting the contents of
\`skills/memnote/SKILL.md\` from the memvault-infra repo.

Both the tool server and the skill are disabled by default - toggle them on
per-chat, or attach them to the model in Workspace -> Models, before testing.
If you skip that, OWUI's own built-in Notes feature will silently answer
instead: same-looking \`write_note\`/\`search_notes\` names, but the result
won't match this skill's schema (e.g. no \`date\` field).

## Isolation reminder

If you also run a second vault (work vs. personal), never attach both
vaults' tool servers / MCP configs to the same client session or OWUI
workspace at once - the server-side config is isolated per vault
(BASIC_MEMORY_CONFIG_DIR, separate mcpo ports), but nothing stops a client
from being pointed at both at the same time except discipline. Keep them in
separate workspaces/presets per client.
EOF

if [[ "$HAS_GIT" == "0" ]]; then
cat <<EOF

## No git detected

The commit watcher and push timer were **not** installed - there's no git
repo here yet. Run \`git init\` (or nest this folder in one you already have)
and re-run the installer to add them.
EOF
elif [[ "$GIT_ROOT" != "$VAULT_DIR" ]]; then
cat <<EOF

## Nested in an existing repo

This vault lives inside a larger repo rooted at \`$GIT_ROOT\`. The commit
watcher only stages/commits changes under \`$VAULT_DIR\` (pathspec-scoped -
it will not touch unrelated files elsewhere in that repo). The push timer,
however, pulls/pushes the **whole repo's current branch** every 5 minutes -
that includes any other commits you've made there, not just vault ones. If
that's not what you want, give the vault its own dedicated repo instead.
EOF
fi
} > "$INSTRUCTIONS"

log "Wrote $INSTRUCTIONS"
cat "$INSTRUCTIONS"

log "Done. Services running: com.memvault-infra.$VAULT_NAME.{$SERVICES}"
echo "Logs: $LOG_DIR"
