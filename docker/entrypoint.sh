#!/usr/bin/env bash
set -euo pipefail

: "${VAULT_NAME:?VAULT_NAME env var is required (docker run -e VAULT_NAME=...)}"
UVX_PATH="$(command -v uvx)"
mkdir -p /data

echo "==> Registering '$VAULT_NAME' -> /vault"
"$UVX_PATH" basic-memory project add "$VAULT_NAME" /vault --quiet 2>/dev/null \
  || "$UVX_PATH" basic-memory project add "$VAULT_NAME" /vault \
  || echo "(project already registered, continuing)"

MCPO_CONFIG=/data/mcpo-config.json
cat > "$MCPO_CONFIG" <<EOF
{
  "mcpServers": {
    "$VAULT_NAME": {
      "command": "$UVX_PATH",
      "args": ["basic-memory", "mcp"],
      "env": {
        "BASIC_MEMORY_CONFIG_DIR": "/data",
        "BASIC_MEMORY_MCP_PROJECT": "$VAULT_NAME"
      }
    }
  }
}
EOF

if git -C /vault rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "==> /vault is a git repo - starting commit watcher and push timer"
  /opt/memvault/scripts/watch-commit.sh /vault &
  ( while true; do
      sleep 300
      /opt/memvault/scripts/push-timer.sh /vault || true
    done ) &
else
  echo "==> /vault is not a git repo - skipping commit watcher and push timer"
fi

echo "==> Starting mcpo on port ${MCPO_PORT}"
exec "$UVX_PATH" mcpo --port "$MCPO_PORT" --config "$MCPO_CONFIG"
