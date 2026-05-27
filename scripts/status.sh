#!/usr/bin/env bash
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

# shellcheck source=/dev/null
if [ -f .env ]; then set -a; . ./.env; set +a; fi

UA='Mozilla/5.0 (X11; Linux x86_64; rv:120.0) Gecko/20100101 Firefox/120.0'

# Probe searxng
searxng_status="down"
if podman ps --filter 'name=^searxng$' --filter 'status=running' --format '{{.Names}}' 2>/dev/null | grep -q '^searxng$'; then
  if curl -fsS -A "$UA" "http://127.0.0.1:${SEARXNG_PORT:-28080}/healthz" >/dev/null 2>&1; then
    searxng_status="ok"
  else
    searxng_status="degraded"
  fi
fi

# Probe valkey
valkey_status="down"
if podman ps --filter 'name=^valkey$' --filter 'status=running' --format '{{.Names}}' 2>/dev/null | grep -q '^valkey$'; then
  if podman exec valkey valkey-cli ping 2>/dev/null | grep -q 'PONG'; then
    valkey_status="ok"
  else
    valkey_status="degraded"
  fi
fi

# Probe mcp-searxng (requires initialize handshake for session)
mcp_status="down"
if podman ps --filter 'name=^mcp-searxng$' --filter 'status=running' --format '{{.Names}}' 2>/dev/null | grep -q '^mcp-searxng$'; then
  mcp_session_id="$(curl -fsS -D - -X POST "http://127.0.0.1:${MCP_HTTP_PORT:-23000}/mcp" \
      -H 'Content-Type: application/json' \
      -H 'Accept: application/json, text/event-stream' \
      -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"status-probe","version":"0.1.0"}}}' 2>/dev/null \
      | grep -i '^mcp-session-id:' | head -1 | sed 's/^[Mm]cp-[Ss]ession-[Ii]d:[[:space:]]*//' | tr -d '[:space:]')"
  if [ -n "$mcp_session_id" ]; then
    if curl -fsS -X POST "http://127.0.0.1:${MCP_HTTP_PORT:-23000}/mcp" \
        -H 'Content-Type: application/json' \
        -H 'Accept: application/json, text/event-stream' \
        -H "Mcp-Session-Id: $mcp_session_id" \
        -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' 2>/dev/null \
        | grep -q 'searxng_web_search'; then
      mcp_status="ok"
    else
      mcp_status="degraded"
    fi
  else
    mcp_status="degraded"
  fi
fi

echo "[status] searxng=${searxng_status} valkey=${valkey_status} mcp=${mcp_status}"

if [ "$searxng_status" = "ok" ] && [ "$valkey_status" = "ok" ] && [ "$mcp_status" = "ok" ]; then
  exit 0
elif [ "$searxng_status" = "down" ] && [ "$valkey_status" = "down" ] && [ "$mcp_status" = "down" ]; then
  exit 2
else
  exit 1
fi
