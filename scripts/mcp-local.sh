#!/usr/bin/env bash
# scripts/mcp-local.sh — stdio MCP entry point for opencode.
#
# 1. ensure.sh guarantees the shared HTTP stack is up (idempotent, locked).
# 2. mcp-remote bridges this process's stdio ↔ the HTTP MCP endpoint, so
#    opencode (which spawns us as a local subprocess) transparently talks to
#    the shared SearXNG backend.
#
# Multiple opencode sessions: each spawns its own mcp-remote bridge, but they
# all share ONE HTTP MCP container — no per-session container churn, no per-
# session SearXNG/Valkey, no manual ./scripts/up.sh.

set -euo pipefail
IFS=$'\n\t'

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${MCP_HTTP_PORT:-3000}"
URL="http://127.0.0.1:${PORT}/mcp"

"${REPO_ROOT}/scripts/ensure.sh"

# --transport http-only: this stack only speaks Streamable HTTP; skip the
#   legacy SSE fallback handshake to keep startup tight.
# --allow-http: required because the backend is plain http:// on localhost.
exec npx -y mcp-remote@0.1.38 "${URL}" \
  --transport http-only \
  --allow-http
