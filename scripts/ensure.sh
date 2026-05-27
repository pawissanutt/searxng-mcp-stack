#!/usr/bin/env bash
# scripts/ensure.sh — fast idempotent stack-up.
#
# Probes the MCP HTTP endpoint. If healthy, returns immediately. Otherwise
# acquires a per-repo flock and runs ./scripts/up.sh exactly once — concurrent
# callers wait on the lock and re-probe, so spawning N opencode sessions
# simultaneously triggers exactly ONE cold-start.

set -euo pipefail
IFS=$'\n\t'

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${MCP_HTTP_PORT:-3000}"
URL="http://127.0.0.1:${PORT}/mcp"

# Per-repo lock path (hash REPO_ROOT so multiple checkouts don't collide).
LOCK_HASH="$(printf '%s' "${REPO_ROOT}" | sha256sum | cut -c1-12)"
LOCK="/tmp/searxng-mcp-stack-ensure-${LOCK_HASH}.lock"

probe() {
  # POST initialize is the lightest valid MCP call that proves the server
  # is fully up (TCP accept + HTTP framework + MCP handler all responsive).
  # 2s timeout: hot stack answers in <50ms; anything slower means cold/sick.
  curl -fsS -m 2 -o /dev/null -X POST "${URL}" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"ensure","version":"1.0"}}}' \
    2>/dev/null
}

# Fast path — already healthy.
if probe; then
  exit 0
fi

# Slow path — serialize cold-start across concurrent callers.
exec {LOCK_FD}>"${LOCK}"
flock -x "${LOCK_FD}"

# Re-probe under the lock: another caller may have brought the stack up
# while we waited.
if probe; then
  exit 0
fi

echo "[ensure] MCP not responding at ${URL} — running up.sh" >&2
"${REPO_ROOT}/scripts/up.sh" >&2
