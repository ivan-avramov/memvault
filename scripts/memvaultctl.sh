#!/usr/bin/env bash
# The one control surface for memvault: create vaults, manage per-vault
# backends (native launchd services, or a Docker container), and upgrade the
# shared tool install. Auto-detects which backend a given vault uses.
# Installed once as `memvaultctl` by install.sh/install-docker.sh:
#   ln -sf ~/.memvault/repo/scripts/memvaultctl.sh /opt/homebrew/bin/memvaultctl
set -euo pipefail

INFRA_HOME="$HOME/.memvault"
INFRA_DIR="$INFRA_HOME/repo"
PLIST_DIR="$HOME/Library/LaunchAgents"
LOG_DIR_ROOT="$INFRA_HOME/logs"
CONFIG_DIR_ROOT="$INFRA_HOME/config"
PORTS_FILE="$INFRA_HOME/ports.txt"
VAULTS_FILE="$INFRA_HOME/vaults.txt"
BACKEND_FILE="$INFRA_HOME/backend"
SERVICES=(mcpo watch push)

log() { printf '\n==> %s\n' "$1"; }

usage() {
  cat >&2 <<EOF
Usage:
  memvaultctl create  <name> [--port N]
                                           # provisions \$(pwd) as a vault,
                                           # using whichever backend was
                                           # chosen at system-install time
                                           # (~/.memvault/backend) - not a
                                           # per-vault choice.
  memvaultctl upgrade                     # pulls memvault, rebuilds/upgrades
                                           # the shared image/tools. Global,
                                           # not per-vault. Does not restart
                                           # any running vault - see below.
  memvaultctl status [vault]              # all vaults, or one vault's services
  memvaultctl start   <vault> [service]   # native: [service] default all.
                                           # docker: recreates the container
                                           # from the current memvault:local
                                           # image - this is how a vault
                                           # picks up an upgrade.
  memvaultctl stop    <vault> [service]
  memvaultctl restart <vault> [service]
  memvaultctl logs    <vault> [service] [-f]
  memvaultctl uninstall <vault>           # stop + remove services/config/etc.
                                           # Does NOT touch the vault
                                           # directory or its git repo.

Works with both backends transparently - native (launchd, macOS-only) and
Docker (one container per vault). [service] only applies to the native
backend (mcpo/watch/push are separate services there); Docker vaults are one
container, so start/stop/restart/logs act on the whole thing.
EOF
  exit 1
}

plist_path() { echo "$PLIST_DIR/com.memvault.$1.$2.plist"; }
label() { echo "com.memvault.$1.$2"; }
container_name() { echo "memvault-$1"; }

backend_of() {
  local vault="$1"
  if [[ -f "$(plist_path "$vault" "mcpo")" ]]; then
    echo "native"
  elif docker inspect "$(container_name "$vault")" >/dev/null 2>&1; then
    echo "docker"
  else
    echo "none"
  fi
}

installed_services() {
  local vault="$1" svc
  for svc in "${SERVICES[@]}"; do
    [[ -f "$(plist_path "$vault" "$svc")" ]] && echo "$svc"
  done
}

all_vaults() {
  local f
  for f in "$PLIST_DIR"/com.memvault.*.mcpo.plist; do
    [[ -e "$f" ]] || continue
    basename "$f" .mcpo.plist | sed 's/^com\.memvault\.//'
  done
  if command -v docker >/dev/null 2>&1; then
    docker ps -a --filter "name=^memvault-" --format '{{.Names}}' 2>/dev/null | sed 's/^memvault-//'
  fi
}

# --- registries: ports.txt (<name> <port>) and vaults.txt (<name> <backend> <dir>) ---

registry_remove() {
  local file="$1" vault="$2"
  [[ -f "$file" ]] || return 0
  grep -v "^$vault " "$file" > "$file.tmp" 2>/dev/null || true
  mv -f "$file.tmp" "$file"
}

port_of() { [[ -f "$PORTS_FILE" ]] && awk -v n="$1" '$1==n{print $2}' "$PORTS_FILE"; }

port_assign() {
  local vault="$1" requested="${2:-}"
  mkdir -p "$(dirname "$PORTS_FILE")"; touch "$PORTS_FILE"
  local existing; existing="$(port_of "$vault")"
  if [[ -n "$existing" ]]; then
    echo "$existing"
    return
  fi
  local port
  if [[ -n "$requested" ]]; then
    local holder; holder="$(awk -v p="$requested" '$2==p{print $1}' "$PORTS_FILE")"
    if [[ -n "$holder" ]]; then
      echo "Port $requested is already assigned to vault '$holder' - pick a different --port." >&2
      exit 1
    fi
    port="$requested"
  else
    port=8100
    while grep -q " $port\$" "$PORTS_FILE"; do port=$((port + 1)); done
  fi
  echo "$vault $port" >> "$PORTS_FILE"
  echo "$port"
}

vaults_set() {
  local vault="$1" backend="$2" dir="$3"
  mkdir -p "$(dirname "$VAULTS_FILE")"; touch "$VAULTS_FILE"
  registry_remove "$VAULTS_FILE" "$vault"
  echo "$vault $backend $dir" >> "$VAULTS_FILE"
}
vaults_get_dir() { [[ -f "$VAULTS_FILE" ]] && awk -v n="$1" '$1==n{print $3}' "$VAULTS_FILE"; }

# --- docker: shared run routine, used by create/start/restart -------------

docker_start_vault() {
  local vault="$1" vault_dir="$2" port="$3"
  local config_dir="$CONFIG_DIR_ROOT/$vault"
  local cname; cname="$(container_name "$vault")"
  mkdir -p "$config_dir"

  local has_git=0
  git -C "$vault_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 && has_git=1

  docker rm -f "$cname" >/dev/null 2>&1 || true

  local run_args=(
    -d --name "$cname" --restart unless-stopped
    -p "$port:8000"
    -e "VAULT_NAME=$vault"
    -v "$vault_dir:/vault"
    -v "$config_dir:/data"
  )
  if [[ "$has_git" == "1" && -f "$HOME/.gitconfig" ]]; then
    run_args+=(-v "$HOME/.gitconfig:/root/.gitconfig:ro")
  fi
  if [[ "$has_git" == "1" ]]; then
    # Two mechanisms, mounted together, because which one actually works
    # depends on how you authenticate to git remotes:
    #   - ~/.ssh mounted read-only: covers static identity-file auth, no
    #     running agent required. Real trust boundary - makes your private
    #     key readable inside the container.
    #   - SSH_AUTH_SOCK forwarded: covers a running agent. Only reliable on
    #     a native Linux Docker host - on macOS (Docker Desktop/OrbStack)
    #     the daemon runs inside a Linux VM and a plain bind-mount of the
    #     host's agent socket does not cross that boundary.
    if [[ -d "$HOME/.ssh" ]]; then
      run_args+=(-v "$HOME/.ssh:/root/.ssh:ro")
    fi
    if [[ -n "${SSH_AUTH_SOCK:-}" && -S "${SSH_AUTH_SOCK:-}" ]]; then
      run_args+=(-v "$SSH_AUTH_SOCK:/ssh-agent" -e "SSH_AUTH_SOCK=/ssh-agent")
    fi
  fi

  docker run "${run_args[@]}" memvault:local >/dev/null
}

docker_ensure_backend() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "docker not found - install Docker Desktop or OrbStack, then re-run." >&2
    exit 1
  fi
  if ! docker info >/dev/null 2>&1; then
    echo "docker CLI found but the daemon isn't running/reachable - start it, then re-run." >&2
    exit 1
  fi
  if ! docker image inspect memvault:local >/dev/null 2>&1; then
    log "memvault:local image not found - building it now"
    docker build -q -t memvault:local -f "$INFRA_DIR/docker/Dockerfile" "$INFRA_DIR" >/dev/null
  fi
}

native_ensure_backend() {
  if ! command -v uv >/dev/null 2>&1; then
    log "uv not found - installing"
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
  fi
  if ! command -v fswatch >/dev/null 2>&1; then
    if command -v brew >/dev/null 2>&1; then
      log "fswatch not found - installing via Homebrew"
      brew install fswatch
    else
      echo "fswatch not found and Homebrew isn't available - install fswatch manually, then re-run." >&2
      exit 1
    fi
  fi
  if ! uv tool list 2>/dev/null | grep -q '^basic-memory'; then
    log "Installing basic-memory/mcpo (uv tool)"
    uv tool install --quiet basic-memory >/dev/null
    # mcp<2 pin: mcpo 0.0.20 imports a name mcp>=2.0 renamed
    # (streamablehttp_client -> streamable_http_client) and crash-loops
    # otherwise. Drop only once mcpo ships a release compatible with mcp>=2.
    uv tool install --quiet mcpo --with "mcp<2" >/dev/null
  fi
}

install_plist() {
  local vault="$1" vault_dir="$2" config_dir="$3" log_dir="$4" port="$5" uvx_path="$6" template="$7" label_suffix="$8"
  local out; out="$(plist_path "$vault" "$label_suffix")"
  sed -e "s|__VAULT_NAME__|$vault|g" \
      -e "s|__VAULT_DIR__|$vault_dir|g" \
      -e "s|__INFRA_DIR__|$INFRA_DIR|g" \
      -e "s|__CONFIG_DIR__|$config_dir|g" \
      -e "s|__LOG_DIR__|$log_dir|g" \
      -e "s|__PORT__|$port|g" \
      -e "s|__UVX_PATH__|$uvx_path|g" \
      -e "s|__PATH__|$PATH|g" \
      "$INFRA_DIR/launchd/templates/$template" > "$out"
  launchctl unload "$out" >/dev/null 2>&1 || true
  launchctl load -w "$out"
  echo "  loaded: $out"
}

native_create_vault() {
  local vault="$1" vault_dir="$2" port="$3" has_git="$4"
  local uvx_path; uvx_path="$(command -v uvx)"
  local config_dir="$CONFIG_DIR_ROOT/$vault"
  local log_dir="$LOG_DIR_ROOT/$vault"
  mkdir -p "$config_dir" "$log_dir"

  log "Registering '$vault' as an isolated Basic Memory project"
  BASIC_MEMORY_CONFIG_DIR="$config_dir" "$uvx_path" basic-memory project add "$vault" "$vault_dir" --quiet 2>/dev/null \
    || BASIC_MEMORY_CONFIG_DIR="$config_dir" "$uvx_path" basic-memory project add "$vault" "$vault_dir"

  sed -e "s|__VAULT_NAME__|$vault|g" \
      -e "s|__CONFIG_DIR__|$config_dir|g" \
      -e "s|__UVX_PATH__|$uvx_path|g" \
      "$INFRA_DIR/mcpo/config.template.json" > "$config_dir/mcpo-config.json"

  mkdir -p "$PLIST_DIR"
  log "Installing launchd services"
  install_plist "$vault" "$vault_dir" "$config_dir" "$log_dir" "$port" "$uvx_path" "mcpo.plist.template" "mcpo"
  if [[ "$has_git" == "1" ]]; then
    install_plist "$vault" "$vault_dir" "$config_dir" "$log_dir" "$port" "$uvx_path" "watch.plist.template" "watch"
    install_plist "$vault" "$vault_dir" "$config_dir" "$log_dir" "$port" "$uvx_path" "push.plist.template" "push"
  fi
}

write_integrations_docker() {
  local vault="$1" vault_dir="$2" port="$3"
  local cname; cname="$(container_name "$vault")"
  local out="$vault_dir/INTEGRATIONS.md"
  cat > "$out" <<EOF
# Connecting clients to the '$vault' vault (Docker)

Generated by \`memvaultctl create\` - the port below is stable across
restarts and upgrades (\`memvaultctl restart $vault\` recreates the
container but keeps the same port).

mcpo is serving this vault on **http://127.0.0.1:$port**

## Claude Code / Claude Desktop / OpenCode (stdio via docker exec)

\`\`\`json
{
  "mcpServers": {
    "$vault": {
      "command": "docker",
      "args": ["exec", "-i", "$cname", "uvx", "basic-memory", "mcp"],
      "env": { "BASIC_MEMORY_MCP_PROJECT": "$vault" }
    }
  }
}
\`\`\`

Claude Code: register with
\`claude mcp add-json $vault '{"command":"docker","args":["exec","-i","$cname","uvx","basic-memory","mcp"],"env":{"BASIC_MEMORY_MCP_PROJECT":"$vault"}}' --scope local\`
(not a hand-edited \`.mcp.json\` - project-scoped servers there need an
explicit approval step Claude Code doesn't surface clearly). Project-level
\`.claude/skills/memnote/SKILL.md\` was already installed and loads
automatically.

## Zed

Command palette -> \`agent: create skill from url\`, pointing at the copy
already installed in this vault - **not** a raw.githubusercontent.com URL:
Zed's URL import has no GitHub auth of its own, so it 404s against a private
memvault repo. Point at the local copy instead:

file://$vault_dir/.claude/skills/memnote/SKILL.md

Add an MCP context server with the same command/args/env block above.

## Open WebUI (via mcpo, already running in the container)

Tool server URL: \`http://127.0.0.1:$port/$vault\` - use this
host-resolvable URL, not \`host.docker.internal\`: OWUI's tool-server calls
are made client-side, from your browser, not proxied through its backend
container, so \`host.docker.internal\` (container-only) silently fails there
even though OWUI's backend could reach it fine. Paste
\`skills/memnote/SKILL.md\` into OWUI's Skills workspace as a custom skill.

Both the tool server and the skill are disabled by default - toggle them on
per-chat, or attach them to the model in Workspace -> Models, before testing.
If you skip that, OWUI's own built-in Notes feature will silently answer
instead: same-looking \`write_note\`/\`search_notes\` names, but the result
won't match this skill's schema (e.g. no \`date\` field).

## Isolation reminder

Never attach two vaults' tool servers/MCP configs to the same client
session or OWUI workspace at once - server-side isolation (per-container
\`/data\`) doesn't stop a client from being pointed at both.

## Managing this vault

\`memvaultctl {status,start,stop,restart,logs,uninstall} $vault\`.
\`memvaultctl upgrade\` rebuilds the shared image; \`memvaultctl restart
$vault\` is the separate, explicit step that actually moves this vault onto
the new build.
EOF
  log "Wrote $out"
}

write_integrations_native() {
  local vault="$1" vault_dir="$2" port="$3" has_git="$4" git_root="$5"
  local uvx_path; uvx_path="$(command -v uvx)"
  local config_dir="$CONFIG_DIR_ROOT/$vault"
  local out="$vault_dir/INTEGRATIONS.md"
  {
  cat <<EOF
# Connecting clients to the '$vault' vault

Generated by \`memvaultctl create\` - the port below is stable across
restarts and upgrades.

mcpo is serving this vault on **http://127.0.0.1:$port**

## Claude Code (stdio, no bridge)

Don't hand-edit \`.mcp.json\` - project-scoped servers defined there need an
explicit approval step (\`⏸ Pending approval\` in \`claude mcp get\`) before
Claude Code will actually connect, and it's easy to miss that they're sitting
unapproved rather than connected. Use the CLI instead, which registers under
\`local\` scope (your personal config, not a committed file - no approval
prompt):

\`\`\`bash
claude mcp add-json $vault '{"command": "$uvx_path", "args": ["basic-memory", "mcp"], "env": {"BASIC_MEMORY_CONFIG_DIR": "$config_dir", "BASIC_MEMORY_MCP_PROJECT": "$vault"}}' --scope local
\`\`\`

Verify with \`claude mcp list\` (should show \`✔ Connected\`, not pending) before
testing a write. The project-level \`.claude/skills/memnote/SKILL.md\`
was already installed and loads automatically - skill loading and tool
connection are independent, so seeing the skill in Claude's skill list does
**not** mean the MCP server is connected.

## Claude Desktop / OpenCode (stdio, no bridge)

Same underlying command, different config surface per client:

\`\`\`json
{
  "mcpServers": {
    "$vault": {
      "command": "$uvx_path",
      "args": ["basic-memory", "mcp"],
      "env": {
        "BASIC_MEMORY_CONFIG_DIR": "$config_dir",
        "BASIC_MEMORY_MCP_PROJECT": "$vault"
      }
    }
  }
}
\`\`\`

Claude Desktop: paste into \`~/Library/Application Support/Claude/claude_desktop_config.json\`,
fully quit and reopen the app (no hot reload). OpenCode: this JSON shape
doesn't apply directly - add via \`opencode mcp add $vault --url ...\` for
a remote server, or hand-edit \`~/.config/opencode/opencode.json\`'s \`mcp\` key
with \`{"type": "local", "command": ["$uvx_path", "basic-memory", "mcp"],
"environment": {...}}\` for this stdio case. OpenCode doesn't read
\`SKILL.md\` - copy this file's contents into the vault directory as
\`AGENTS.md\` instead.

## Zed

Command palette -> \`agent: create skill from url\`, pointing at the copy
already installed in this vault - **not** a raw.githubusercontent.com URL:
Zed's URL import has no GitHub auth of its own, so it 404s against a private
memvault repo. Point at the local copy instead:

file://$vault_dir/.claude/skills/memnote/SKILL.md

Add an MCP context server using the same command/args/env block above.

## Open WebUI (via mcpo)

mcpo is already running on port $port, proxying this vault only. Add it as a
tool server in OWUI pointing at \`http://127.0.0.1:$port/$vault\` - use
this host-resolvable URL, not \`host.docker.internal\`: OWUI's tool-server
calls are made client-side, from your browser, not proxied through its
backend container, so \`host.docker.internal\` (container-only) silently
fails there even though OWUI's backend could reach it fine.
Create a custom skill in OWUI's Skills workspace by pasting the contents of
\`skills/memnote/SKILL.md\` from the memvault repo.

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

## Managing this vault

\`memvaultctl {status,start,stop,restart,logs,uninstall} $vault\`.
\`memvaultctl upgrade\` upgrades the shared uv tools; \`memvaultctl restart
$vault\` reloads this vault's services against them.
EOF

if [[ "$has_git" == "0" ]]; then
cat <<EOF

## No git detected

The commit watcher and push timer were **not** installed - there's no git
repo here yet. Run \`git init\` (or nest this folder in one you already have)
and re-create the vault to add them.
EOF
elif [[ "$git_root" != "$vault_dir" ]]; then
cat <<EOF

## Nested in an existing repo

This vault lives inside a larger repo rooted at \`$git_root\`. The commit
watcher only stages/commits changes under \`$vault_dir\` (pathspec-scoped -
it will not touch unrelated files elsewhere in that repo). The push timer,
however, pulls/pushes the **whole repo's current branch** every 5 minutes -
that includes any other commits you've made there, not just vault ones. If
that's not what you want, give the vault its own dedicated repo instead.
EOF
fi
  } > "$out"
  log "Wrote $out"
}

# --- commands ---------------------------------------------------------------

cmd_status() {
  local vault="${1:-}"
  local vaults
  if [[ -n "$vault" ]]; then vaults="$vault"; else vaults="$(all_vaults)"; fi
  if [[ -z "$vaults" ]]; then echo "No vaults installed."; return; fi
  for v in $vaults; do
    local backend; backend="$(backend_of "$v")"
    echo "$v ($backend):"
    local p; p="$(port_of "$v")"
    [[ -n "$p" ]] && echo "  port: $p"
    case "$backend" in
      native)
        for svc in $(installed_services "$v"); do
          local lbl status
          lbl="$(label "$v" "$svc")"
          status="$(launchctl list | awk -v l="$lbl" '$3==l{print "pid="$1" last_exit="$2}')"
          if [[ -n "$status" ]]; then echo "  $svc  running ($status)"; else echo "  $svc  not running"; fi
        done
        ;;
      docker)
        docker ps -a --filter "name=^$(container_name "$v")\$" --format '  {{.Status}} ({{.Ports}})'
        ;;
      none)
        echo "  not found"
        ;;
    esac
  done
}

cmd_stop() {
  local vault="${1:?vault name required}" svc="${2:-}"
  case "$(backend_of "$vault")" in
    native)
      for s in ${svc:-$(installed_services "$vault")}; do
        launchctl unload "$(plist_path "$vault" "$s")" 2>/dev/null || true
        echo "stopped $vault/$s"
      done
      ;;
    docker)
      docker stop "$(container_name "$vault")" >/dev/null
      echo "stopped $vault (container)"
      ;;
    none) echo "vault '$vault' not found" >&2; exit 1 ;;
  esac
}

cmd_start() {
  local vault="${1:?vault name required}" svc="${2:-}"
  case "$(backend_of "$vault")" in
    native)
      for s in ${svc:-$(installed_services "$vault")}; do
        launchctl load -w "$(plist_path "$vault" "$s")"
        echo "started $vault/$s"
      done
      ;;
    docker)
      local vault_dir port
      vault_dir="$(vaults_get_dir "$vault")"
      port="$(port_of "$vault")"
      if [[ -z "$vault_dir" || -z "$port" ]]; then
        echo "vault '$vault' is missing registry data (vaults.txt/ports.txt) - re-create it, or add the entries by hand." >&2
        exit 1
      fi
      docker_start_vault "$vault" "$vault_dir" "$port"
      echo "started $vault (container recreated from memvault:local)"
      ;;
    none) echo "vault '$vault' not found" >&2; exit 1 ;;
  esac
}

cmd_restart() {
  local vault="${1:?vault name required}" svc="${2:-}"
  case "$(backend_of "$vault")" in
    docker) cmd_start "$vault" ;;
    *) cmd_stop "$vault" "$svc"; cmd_start "$vault" "$svc" ;;
  esac
}

cmd_logs() {
  local vault="${1:?vault name required}"; shift || true
  local svc="mcpo" follow=""
  for a in "$@"; do
    case "$a" in
      -f) follow="-f" ;;
      *) svc="$a" ;;
    esac
  done
  case "$(backend_of "$vault")" in
    native) tail $follow "$LOG_DIR_ROOT/$vault/$svc.out.log" "$LOG_DIR_ROOT/$vault/$svc.err.log" ;;
    docker) docker logs $follow "$(container_name "$vault")" ;;
    none) echo "vault '$vault' not found" >&2; exit 1 ;;
  esac
}

cmd_create() {
  local vault="${1:?vault name required}"; shift || true
  local port=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --port) port="$2"; shift 2 ;;
      *) echo "unknown option: $1" >&2; usage ;;
    esac
  done
  if [[ ! -d "$INFRA_DIR/.git" ]]; then
    echo "memvault isn't installed yet - run the system installer first (install.sh or install-docker.sh)." >&2
    exit 1
  fi
  # Backend is a one-time, whole-machine choice made by whichever system
  # installer you ran (install.sh -> native, install-docker.sh -> docker),
  # recorded in ~/.memvault/backend - not a per-vault option. Every vault on
  # this machine uses the same backend.
  local backend; backend="$(cat "$BACKEND_FILE" 2>/dev/null || true)"
  if [[ "$backend" != "docker" && "$backend" != "native" ]]; then
    echo "no backend recorded at $BACKEND_FILE - run install.sh or install-docker.sh first." >&2
    exit 1
  fi
  if [[ "$(backend_of "$vault")" != "none" ]]; then
    echo "vault '$vault' already exists ($(backend_of "$vault")) - use 'memvaultctl start/restart $vault' instead." >&2
    exit 1
  fi

  local vault_dir; vault_dir="$(pwd)"
  if [[ "$vault_dir" == "$HOME" ]]; then
    echo "Refusing to create a vault in \$HOME directly - cd into a dedicated vault directory first." >&2
    exit 1
  fi

  log "Creating vault '$vault' at $vault_dir ($backend)"

  # Fail fast on a port collision before touching the vault directory or any
  # registry file - an explicit --port that's taken must abort cleanly, not
  # leave partial state behind.
  local assigned_port; assigned_port="$(port_assign "$vault" "$port")"
  log "Port: $assigned_port"

  # No git init, ever - the folder may intentionally be un-tracked, or
  # already be its own repo, or be nested inside a larger one.
  local has_git=0 git_root=""
  if git -C "$vault_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    has_git=1
    git_root="$(git -C "$vault_dir" rev-parse --show-toplevel)"
    [[ "$git_root" != "$vault_dir" ]] && log "Vault is nested inside an existing repo at $git_root"
  fi
  if [[ "$has_git" == "1" ]]; then
    local gitignore="$vault_dir/.gitignore"
    touch "$gitignore"
    for pattern in ".DS_Store" ".basic-memory/"; do
      grep -qxF "$pattern" "$gitignore" || echo "$pattern" >> "$gitignore"
    done
  else
    log "No git repo detected - skipping .gitignore, commit watcher, and push timer"
  fi
  mkdir -p "$vault_dir/.claude/skills/memnote"
  cp -f "$INFRA_DIR/skills/memnote/SKILL.md" "$vault_dir/.claude/skills/memnote/SKILL.md"

  vaults_set "$vault" "$backend" "$vault_dir"

  if [[ "$backend" == "docker" ]]; then
    docker_ensure_backend
    docker_start_vault "$vault" "$vault_dir" "$assigned_port"
    write_integrations_docker "$vault" "$vault_dir" "$assigned_port"
  else
    native_ensure_backend
    native_create_vault "$vault" "$vault_dir" "$assigned_port" "$has_git"
    write_integrations_native "$vault" "$vault_dir" "$assigned_port" "$has_git" "$git_root"
  fi

  log "Done. memvaultctl status $vault"
}

cmd_upgrade() {
  if [[ ! -d "$INFRA_DIR/.git" ]]; then
    echo "memvault isn't installed yet - run the system installer first (install.sh or install-docker.sh)." >&2
    exit 1
  fi
  local backend; backend="$(cat "$BACKEND_FILE" 2>/dev/null || true)"
  if [[ "$backend" != "docker" && "$backend" != "native" ]]; then
    echo "no backend recorded at $BACKEND_FILE - run install.sh or install-docker.sh first." >&2
    exit 1
  fi

  log "Pulling latest memvault"
  git -C "$INFRA_DIR" pull --quiet

  if [[ "$backend" == "docker" ]]; then
    local sha; sha="$(git -C "$INFRA_DIR" rev-parse --short HEAD)"
    log "Rebuilding memvault:$sha (docker backend)"
    docker build -q -t "memvault:$sha" -t memvault:local -f "$INFRA_DIR/docker/Dockerfile" "$INFRA_DIR" >/dev/null
    local old_tag
    for old_tag in $(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep '^memvault:' | grep -v "^memvault:local$" | grep -v "^memvault:$sha$"); do
      docker rmi "$old_tag" >/dev/null 2>&1 || true
    done
  else
    log "Upgrading basic-memory and mcpo (native backend)"
    uv tool upgrade --quiet basic-memory >/dev/null
    uv tool upgrade --quiet mcpo --with "mcp<2" >/dev/null
  fi

  log "Done. Run 'memvaultctl restart <vault>' for each vault you want on the new build."
}

cmd_uninstall() {
  local vault="${1:?vault name required}"
  case "$(backend_of "$vault")" in
    native)
      cmd_stop "$vault"
      for s in "${SERVICES[@]}"; do rm -f "$(plist_path "$vault" "$s")"; done
      rm -rf "$CONFIG_DIR_ROOT/$vault" "$LOG_DIR_ROOT/$vault"
      ;;
    docker)
      docker rm -f "$(container_name "$vault")" >/dev/null
      rm -rf "$CONFIG_DIR_ROOT/$vault"
      ;;
    none) echo "vault '$vault' not found" >&2; exit 1 ;;
  esac
  registry_remove "$PORTS_FILE" "$vault"
  registry_remove "$VAULTS_FILE" "$vault"
  echo "uninstalled $vault (vault directory and its git history untouched)"
}

[[ $# -ge 1 ]] || usage
cmd="$1"; shift || true
case "$cmd" in
  create) cmd_create "$@" ;;
  upgrade) cmd_upgrade "$@" ;;
  status) cmd_status "$@" ;;
  start) cmd_start "$@" ;;
  stop) cmd_stop "$@" ;;
  restart) cmd_restart "$@" ;;
  logs) cmd_logs "$@" ;;
  uninstall) cmd_uninstall "$@" ;;
  *) usage ;;
esac
