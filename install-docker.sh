#!/usr/bin/env bash
# Docker-based alternative to install.sh - one container per vault (mcpo +
# basic-memory + optional git watch/push loops), instead of native
# uv-tool-installs + launchd services. Cross-platform; recommended for
# anyone who isn't on macOS or doesn't want this touching global host tools.
#
# Usage: cd into the folder you want to become a vault, then:
#
#   gh api -H "Accept: application/vnd.github.raw" \
#     /repos/ivan-avramov/memvault-infra/contents/install-docker.sh \
#     | bash -s -- personal-vault
set -euo pipefail

REPO_SLUG="${MEMVAULT_INFRA_REPO:-ivan-avramov/memvault-infra}"
INFRA_HOME="$HOME/.memvault-infra"
INFRA_DIR="$INFRA_HOME/repo"
IMAGE_TAG="memvault-infra:local"

VAULT_DIR="$(pwd)"
VAULT_NAME="${1:-$(basename "$VAULT_DIR")}"
CONFIG_DIR="$INFRA_HOME/config/$VAULT_NAME"
CONTAINER_NAME="memvault-$VAULT_NAME"

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
if ! command -v docker >/dev/null 2>&1; then
  echo "docker not found - install Docker Desktop or OrbStack, then re-run." >&2
  exit 1
fi
if ! docker info >/dev/null 2>&1; then
  echo "docker CLI found but the daemon isn't running/reachable - start it, then re-run." >&2
  exit 1
fi

log "Bootstrapping vault '$VAULT_NAME' at $VAULT_DIR (container: $CONTAINER_NAME)"

# --- 1. fetch/refresh the infra repo (needed for the Dockerfile/scripts) --
mkdir -p "$INFRA_HOME"
if [[ -d "$INFRA_DIR/.git" ]]; then
  log "Updating existing memvault-infra checkout"
  git -C "$INFRA_DIR" pull --quiet
else
  log "Cloning memvault-infra to $INFRA_DIR"
  gh repo clone "$REPO_SLUG" "$INFRA_DIR" -- --quiet
fi

# --- 2. build the image ----------------------------------------------------
log "Building $IMAGE_TAG (local build)"
docker build -q -t "$IMAGE_TAG" -f "$INFRA_DIR/docker/Dockerfile" "$INFRA_DIR" >/dev/null

# --- 3. vault directory setup - same rule as install.sh: never git init ---
HAS_GIT=0
if git -C "$VAULT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  HAS_GIT=1
  GITIGNORE="$VAULT_DIR/.gitignore"
  touch "$GITIGNORE"
  for pattern in ".DS_Store" ".basic-memory/"; do
    grep -qxF "$pattern" "$GITIGNORE" || echo "$pattern" >> "$GITIGNORE"
  done
else
  log "No git repo detected - container will skip the commit watcher and push timer"
fi

mkdir -p "$VAULT_DIR/.claude/skills/memnote"
cp -f "$INFRA_DIR/skills/memnote/SKILL.md" "$VAULT_DIR/.claude/skills/memnote/SKILL.md"
mkdir -p "$CONFIG_DIR"

# --- 4. run the container ---------------------------------------------------
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

RUN_ARGS=(
  -d --name "$CONTAINER_NAME" --restart unless-stopped
  -p 8000
  -e "VAULT_NAME=$VAULT_NAME"
  -v "$VAULT_DIR:/vault"
  -v "$CONFIG_DIR:/data"
)
if [[ "$HAS_GIT" == "1" && -f "$HOME/.gitconfig" ]]; then
  log "Mounting host ~/.gitconfig for commit identity"
  RUN_ARGS+=(-v "$HOME/.gitconfig:/root/.gitconfig:ro")
fi
if [[ "$HAS_GIT" == "1" ]]; then
  # Two mechanisms, mounted together, because which one actually works
  # depends on how you authenticate to git remotes - and it's common to
  # have neither, one, or the other, not always what you'd guess:
  #   - ~/.ssh mounted read-only: covers static identity-file auth (the
  #     SSH client's own default id_ed25519/id_rsa lookup) - no running
  #     agent required. This is a real trust boundary: it makes your
  #     private key readable inside the container.
  #   - SSH_AUTH_SOCK forwarded: covers a running agent with loaded
  #     identities. Only reliable on a native Linux Docker host - on
  #     macOS (Docker Desktop/OrbStack), the daemon runs inside a Linux
  #     VM and a plain bind-mount of the host's agent socket does not
  #     cross that boundary; it shows up as an empty path inside the
  #     container and connecting to it fails with "Connection refused."
  #     No known simple/native fix at the container-run level for this -
  #     if you're on macOS and specifically need agent-based auth (e.g. a
  #     hardware key with no exportable identity file), the ~/.ssh mount
  #     above won't help you either; you're limited to whatever your
  #     Docker Desktop/OrbStack version's own SSH-forwarding feature (if
  #     any) provides outside of what this script does.
  if [[ -d "$HOME/.ssh" ]]; then
    log "Mounting host ~/.ssh read-only for git push (private key becomes readable inside the container)"
    RUN_ARGS+=(-v "$HOME/.ssh:/root/.ssh:ro")
  fi
  if [[ -n "${SSH_AUTH_SOCK:-}" && -S "${SSH_AUTH_SOCK:-}" ]]; then
    log "Also forwarding host SSH agent (works reliably on Linux hosts; unreliable on macOS - see comment above)"
    RUN_ARGS+=(-v "$SSH_AUTH_SOCK:/ssh-agent" -e "SSH_AUTH_SOCK=/ssh-agent")
  fi
  if [[ ! -d "$HOME/.ssh" && ! ( -n "${SSH_AUTH_SOCK:-}" && -S "${SSH_AUTH_SOCK:-}" ) ]]; then
    log "No ~/.ssh and no SSH agent detected - commits will work, git push will not until one is available"
  fi
fi

log "Starting container"
docker run "${RUN_ARGS[@]}" "$IMAGE_TAG" >/dev/null
sleep 1
PORT="$(docker port "$CONTAINER_NAME" 8000/tcp | head -1 | cut -d: -f2)"
log "mcpo serving this vault on http://127.0.0.1:$PORT"

# --- 5. memvaultctl ----------------------------------------------------------
for bindir in /opt/homebrew/bin /usr/local/bin; do
  if [[ -w "$bindir" ]]; then
    ln -sf "$INFRA_DIR/scripts/memvaultctl.sh" "$bindir/memvaultctl"
    log "memvaultctl linked to $bindir/memvaultctl - see 'memvaultctl status'"
    break
  fi
done

# --- 6. integration instructions --------------------------------------------
INSTRUCTIONS="$VAULT_DIR/INTEGRATIONS.md"
cat > "$INSTRUCTIONS" <<EOF
# Connecting clients to the '$VAULT_NAME' vault (Docker)

Generated by memvault-infra/install-docker.sh - re-run to regenerate. The
mcpo host port is randomly assigned per container start and can change on
restart - look it up with:

\`\`\`bash
docker port $CONTAINER_NAME 8000/tcp
\`\`\`
Currently: **$PORT**

## Claude Code / Claude Desktop / OpenCode (stdio via docker exec)

\`\`\`json
{
  "mcpServers": {
    "$VAULT_NAME": {
      "command": "docker",
      "args": ["exec", "-i", "$CONTAINER_NAME", "uvx", "basic-memory", "mcp"],
      "env": { "BASIC_MEMORY_MCP_PROJECT": "$VAULT_NAME" }
    }
  }
}
\`\`\`

Claude Code: register with
\`claude mcp add-json $VAULT_NAME '{"command":"docker","args":["exec","-i","$CONTAINER_NAME","uvx","basic-memory","mcp"],"env":{"BASIC_MEMORY_MCP_PROJECT":"$VAULT_NAME"}}' --scope local\`
(not a hand-edited \`.mcp.json\` - see the native install.sh's INTEGRATIONS.md
for why). Project-level \`.claude/skills/memnote/SKILL.md\` was already
installed and loads automatically.

## Zed

Command palette -> \`agent: create skill from url\`, pointing at the copy
already installed in this vault - **not** a raw.githubusercontent.com URL:
Zed's URL import has no GitHub auth of its own, so it 404s against a private
memvault-infra repo (or a fork someone forgot to make public). The file was
already fetched via an authenticated \`gh repo clone\`, so just point at it
locally:

file://$VAULT_DIR/.claude/skills/memnote/SKILL.md

Add an MCP context server with the same command/args/env block above.

## Open WebUI (via mcpo, already running in the container)

Tool server URL: \`http://127.0.0.1:$PORT/$VAULT_NAME\` (re-check the port
after any container restart) - use this host-resolvable URL, not
\`host.docker.internal\`: OWUI's tool-server calls are made client-side, from
your browser, not proxied through its backend container, so
\`host.docker.internal\` (container-only) silently fails there even though
OWUI's backend could reach it fine. Paste \`skills/memnote/SKILL.md\` into
OWUI's Skills workspace as a custom skill.

Both the tool server and the skill are disabled by default - toggle them on
per-chat, or attach them to the model in Workspace -> Models, before testing.
If you skip that, OWUI's own built-in Notes feature will silently answer
instead: same-looking \`write_note\`/\`search_notes\` names, but the result
won't match this skill's schema (e.g. no \`date\` field).

## Isolation reminder

Never attach two vaults' tool servers/MCP configs to the same client
session or OWUI workspace at once - server-side isolation
(per-container \`/data\`) doesn't stop a client from being pointed at both.

## Managing this container

\`memvaultctl {status,start,stop,restart,logs,uninstall} $VAULT_NAME\` -
same commands as the native install, backed by \`docker\` instead of
\`launchctl\`.
EOF

log "Wrote $INSTRUCTIONS"
cat "$INSTRUCTIONS"
log "Done."
