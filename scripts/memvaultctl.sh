#!/usr/bin/env bash
# Manage per-vault launchd services (mcpo, watch, push) without hand-typing
# launchctl commands and plist paths. Install once as `memvaultctl`:
#   ln -sf ~/.memvault-infra/repo/scripts/memvaultctl.sh /opt/homebrew/bin/memvaultctl
set -euo pipefail

PLIST_DIR="$HOME/Library/LaunchAgents"
LOG_DIR_ROOT="$HOME/.memvault-infra/logs"
SERVICES=(mcpo watch push)

usage() {
  cat >&2 <<EOF
Usage:
  memvaultctl status [vault]              # all vaults, or one vault's services
  memvaultctl start   <vault> [service]   # default: all installed services
  memvaultctl stop    <vault> [service]
  memvaultctl restart <vault> [service]
  memvaultctl logs    <vault> [service] [-f]
  memvaultctl uninstall <vault>           # stop + remove plists, isolated
                                           # config/log dirs, and the port
                                           # assignment. Does NOT touch the
                                           # vault directory or its git repo.

service defaults to all three (mcpo, watch, push) where applicable - a vault
installed without git only has mcpo, the others are silently skipped.
EOF
  exit 1
}

plist_path() { echo "$PLIST_DIR/com.memvault-infra.$1.$2.plist"; }
label() { echo "com.memvault-infra.$1.$2"; }

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
}

cmd_status() {
  local vault="${1:-}"
  local vaults
  if [[ -n "$vault" ]]; then vaults="$vault"; else vaults="$(all_vaults)"; fi
  if [[ -z "$vaults" ]]; then echo "No vaults installed."; return; fi
  for v in $vaults; do
    echo "$v:"
    for svc in $(installed_services "$v"); do
      local lbl status
      lbl="$(label "$v" "$svc")"
      status="$(launchctl list | awk -v l="$lbl" '$3==l{print "pid="$1" last_exit="$2}')"
      if [[ -n "$status" ]]; then
        echo "  $svc  running ($status)"
      else
        echo "  $svc  not running"
      fi
    done
  done
}

cmd_stop() {
  local vault="${1:?vault name required}" svc="${2:-}"
  for s in ${svc:-$(installed_services "$vault")}; do
    launchctl unload "$(plist_path "$vault" "$s")" 2>/dev/null || true
    echo "stopped $vault/$s"
  done
}

cmd_start() {
  local vault="${1:?vault name required}" svc="${2:-}"
  for s in ${svc:-$(installed_services "$vault")}; do
    launchctl load -w "$(plist_path "$vault" "$s")"
    echo "started $vault/$s"
  done
}

cmd_restart() {
  local vault="${1:?vault name required}" svc="${2:-}"
  cmd_stop "$vault" "$svc"
  cmd_start "$vault" "$svc"
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
  tail $follow "$LOG_DIR_ROOT/$vault/$svc.out.log" "$LOG_DIR_ROOT/$vault/$svc.err.log"
}

cmd_uninstall() {
  local vault="${1:?vault name required}"
  cmd_stop "$vault"
  for s in "${SERVICES[@]}"; do rm -f "$(plist_path "$vault" "$s")"; done
  rm -rf "$HOME/.memvault-infra/config/$vault" "$LOG_DIR_ROOT/$vault"
  local ports="$HOME/.memvault-infra/ports.txt"
  [[ -f "$ports" ]] && grep -v "^$vault " "$ports" > "$ports.tmp" && mv "$ports.tmp" "$ports"
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
