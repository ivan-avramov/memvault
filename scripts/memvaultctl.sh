#!/usr/bin/env bash
# Manage per-vault backends (native launchd services, or a Docker container)
# without hand-typing launchctl/docker commands and paths. Auto-detects which
# backend a given vault uses. Install once as `memvaultctl`:
#   ln -sf ~/.memvault-infra/repo/scripts/memvaultctl.sh /opt/homebrew/bin/memvaultctl
set -euo pipefail

PLIST_DIR="$HOME/Library/LaunchAgents"
LOG_DIR_ROOT="$HOME/.memvault-infra/logs"
SERVICES=(mcpo watch push)

usage() {
  cat >&2 <<EOF
Usage:
  memvaultctl status [vault]              # all vaults, or one vault's services
  memvaultctl start   <vault> [service]   # native only; service default: all
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

plist_path() { echo "$PLIST_DIR/com.memvault-infra.$1.$2.plist"; }
label() { echo "com.memvault-infra.$1.$2"; }
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
  for f in "$PLIST_DIR"/com.memvault-infra.*.mcpo.plist; do
    [[ -e "$f" ]] || continue
    basename "$f" .mcpo.plist | sed 's/^com\.memvault-infra\.//'
  done
  if command -v docker >/dev/null 2>&1; then
    docker ps -a --filter "name=^memvault-" --format '{{.Names}}' 2>/dev/null | sed 's/^memvault-//'
  fi
}

cmd_status() {
  local vault="${1:-}"
  local vaults
  if [[ -n "$vault" ]]; then vaults="$vault"; else vaults="$(all_vaults)"; fi
  if [[ -z "$vaults" ]]; then echo "No vaults installed."; return; fi
  for v in $vaults; do
    local backend; backend="$(backend_of "$v")"
    echo "$v ($backend):"
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
      docker start "$(container_name "$vault")" >/dev/null
      echo "started $vault (container)"
      ;;
    none) echo "vault '$vault' not found" >&2; exit 1 ;;
  esac
}

cmd_restart() {
  local vault="${1:?vault name required}" svc="${2:-}"
  case "$(backend_of "$vault")" in
    docker) docker restart "$(container_name "$vault")" >/dev/null; echo "restarted $vault (container)" ;;
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

cmd_uninstall() {
  local vault="${1:?vault name required}"
  case "$(backend_of "$vault")" in
    native)
      cmd_stop "$vault"
      for s in "${SERVICES[@]}"; do rm -f "$(plist_path "$vault" "$s")"; done
      rm -rf "$HOME/.memvault-infra/config/$vault" "$LOG_DIR_ROOT/$vault"
      local ports="$HOME/.memvault-infra/ports.txt"
      [[ -f "$ports" ]] && grep -v "^$vault " "$ports" > "$ports.tmp" && mv "$ports.tmp" "$ports"
      ;;
    docker)
      docker rm -f "$(container_name "$vault")" >/dev/null
      rm -rf "$HOME/.memvault-infra/config/$vault"
      ;;
    none) echo "vault '$vault' not found" >&2; exit 1 ;;
  esac
  echo "uninstalled $vault (vault directory and its git history untouched)"
}

[[ $# -ge 1 ]] || usage
cmd="$1"; shift || true
case "$cmd" in
  status) cmd_status "$@" ;;
  start) cmd_start "$@" ;;
  stop) cmd_stop "$@" ;;
  restart) cmd_restart "$@" ;;
  logs) cmd_logs "$@" ;;
  uninstall) cmd_uninstall "$@" ;;
  *) usage ;;
esac
