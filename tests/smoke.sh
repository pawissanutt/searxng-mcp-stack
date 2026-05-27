#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1
set -a; # shellcheck source=/dev/null
. "${REPO_ROOT}/.env"; set +a
UA='Mozilla/5.0 (X11; Linux x86_64; rv:120.0) Gecko/20100101 Firefox/120.0'
S="http://127.0.0.1:${SEARXNG_PORT:-8080}"
M="http://127.0.0.1:${MCP_HTTP_PORT:-3000}/mcp"
f=0
# Probe 1: SearXNG /healthz → body OK
if b="$(curl -fsS -A "$UA" "${S}/healthz" 2>/dev/null)" && [ "$b" = "OK" ]; then
  echo "[smoke] probe-1: PASS"
else echo "[smoke] probe-1: FAIL (healthz: ${b:-<empty>})"; f=$((f+1))
fi
# Probe 2: SearXNG /search?q=github&format=json → results > 0
if r="$(curl -fsS -A "$UA" "${S}/search?q=github&format=json" 2>/dev/null \
    | jq -e '.results | length > 0' 2>/dev/null)" && [ "$r" = "true" ]; then
  echo "[smoke] probe-2: PASS"
else echo "[smoke] probe-2: FAIL (search: ${r:-<empty>})"; f=$((f+1))
fi
# Probe 3: MCP tools/list → searxng_web_search AND web_url_read
h="$(mktemp)"; curl -fsS -A "$UA" -D "$h" -X POST "$M" \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"smoke","version":"0.1"}}}' >/dev/null 2>/dev/null || true
sid="$(awk 'tolower($1)=="mcp-session-id:"{gsub(/\r/,"",$2);print $2;exit}' "$h")"; rm -f "$h"
if [ -n "${sid:-}" ]; then
  p="$(curl -fsS -A "$UA" -X POST "$M" -H 'Content-Type: application/json' \
      -H 'Accept: application/json, text/event-stream' -H "Mcp-Session-Id: ${sid}" \
      -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' 2>/dev/null \
      | sed -n 's/^data: //p' | head -n1)"
  if [ -n "${p:-}" ] && echo "$p" | jq -e '.result.tools|length>0' >/dev/null 2>&1 \
      && echo "$p" | jq -r '.result.tools[].name' | grep -q '^searxng_web_search$' \
      && echo "$p" | jq -r '.result.tools[].name' | grep -q '^web_url_read$'; then
    echo "[smoke] probe-3: PASS"
  else echo "[smoke] probe-3: FAIL (tools missing)"; f=$((f+1))
  fi
else echo "[smoke] probe-3: FAIL (no session id)"; f=$((f+1))
fi
[ "$f" -gt 0 ] && exit 1
./scripts/status.sh >/dev/null && echo "[smoke] PASS"
