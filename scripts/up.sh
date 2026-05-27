#!/usr/bin/env bash
# scripts/up.sh — idempotent startup for the searxng-mcp-stack.
#
# Generates SEARXNG_SECRET_KEY on first run, renders settings.rendered.yml from
# the committed settings.yml template, brings the three-service compose stack
# up, then polls the MCP HTTP endpoint until tools/list returns a populated
# tool array. Hard ceiling: 60 seconds — exits non-zero on timeout so callers
# (and CI) fail loudly instead of silently hanging.
#
# Safe to re-run: an existing non-empty SEARXNG_SECRET_KEY is preserved.

set -euo pipefail
IFS=$'\n\t'

trap 'echo "[up] FAILED at line $LINENO" >&2' ERR

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# ---------------------------------------------------------------------------
# Step 1 — Secret generation (idempotent).
# ---------------------------------------------------------------------------
if [[ ! -f .env ]]; then
  cp .env.example .env
  echo "[up] .env created from .env.example"
fi

# Pull the current value (may be empty on first run). Tolerate the line being
# absent entirely by defaulting to empty.
current_secret="$(awk -F= '/^SEARXNG_SECRET_KEY=/{ sub(/^SEARXNG_SECRET_KEY=/, ""); print; exit }' .env || true)"

if [[ -z "${current_secret}" ]]; then
  SECRET="$(openssl rand -hex 32)"
  # Use a portable BSD/GNU sed -i form via explicit .bak suffix, then remove
  # the backup so the working tree stays clean.
  sed -i.bak "s|^SEARXNG_SECRET_KEY=.*|SEARXNG_SECRET_KEY=${SECRET}|" .env
  rm -f .env.bak
  echo "[up] secret key: generated"
else
  echo "[up] secret key: preserved"
fi

# ---------------------------------------------------------------------------
# Step 2 — Render runtime settings.
# settings.yml is committed with a literal __SEARXNG_SECRET_KEY__ placeholder.
# Render the rendered sibling atomically (write-temp + mv) so partial writes
# can never leave podman bind-mounting a half-rendered file.
# ---------------------------------------------------------------------------
set -a
# shellcheck source=/dev/null
. ./.env
set +a

if [[ -z "${SEARXNG_SECRET_KEY:-}" ]]; then
  echo "[up] FAIL: SEARXNG_SECRET_KEY is empty after .env load" >&2
  exit 1
fi

# Defensive: a previous `podman-compose up` against a missing rendered file
# can leave behind an empty *directory* at that path. Remove that here so
# we can replace it with the real file.
if [[ -d searxng-config/settings.rendered.yml ]]; then
  rmdir searxng-config/settings.rendered.yml
fi

sed "s|__SEARXNG_SECRET_KEY__|${SEARXNG_SECRET_KEY}|" \
  searxng-config/settings.yml \
  > searxng-config/settings.rendered.yml.tmp
mv searxng-config/settings.rendered.yml.tmp searxng-config/settings.rendered.yml
echo "[up] settings.rendered.yml written"

# ---------------------------------------------------------------------------
# Step 3 — Bring the stack up.
# ---------------------------------------------------------------------------
podman-compose up -d

# ---------------------------------------------------------------------------
# Step 4 — Readiness poll (60-second hard ceiling).
#
# mcp-searxng 1.0.5 speaks Streamable HTTP (MCP protocolVersion 2025-03-26):
#   - `tools/list` is REJECTED with HTTP 400 unless the caller has completed
#     the initialize handshake and supplies the resulting `Mcp-Session-Id`
#     header. We therefore do the full three-step dance on every poll cycle:
#       1) POST initialize  → harvest `mcp-session-id` from response headers
#       2) POST notifications/initialized with that header (server → 202)
#       3) POST tools/list  with that header, parse the SSE body
#   - Responses are framed as Server-Sent Events: lines look like
#     `event: message` / `data: <json>` / blank. We pluck the first
#     `data:` payload and feed THAT to jq.
# Any failure (connection refused, HTTP 5xx, malformed body, empty tools
# array) simply triggers another retry until the 60-second deadline.
# ---------------------------------------------------------------------------
MCP_PORT="${MCP_HTTP_PORT:-23000}"
MCP_URL="http://127.0.0.1:${MCP_PORT}/mcp"
DEADLINE=$(( $(date +%s) + 60 ))

echo "[up] waiting for MCP at ${MCP_URL} (up to 60s)..."

INIT_REQ='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"searxng-mcp-stack-up.sh","version":"1.0"}}}'
INITIALIZED_REQ='{"jsonrpc":"2.0","method":"notifications/initialized"}'
LIST_REQ='{"jsonrpc":"2.0","id":2,"method":"tools/list"}'

mcp_ready() {
  local hdr_file body sid payload list_body
  hdr_file="$(mktemp)"
  # Step 4a — initialize, capturing headers for the session id.
  body="$(curl -fsS -D "${hdr_file}" -X POST "${MCP_URL}" \
      -H 'Content-Type: application/json' \
      -H 'Accept: application/json, text/event-stream' \
      -d "${INIT_REQ}" 2>/dev/null)" || { rm -f "${hdr_file}"; return 1; }
  sid="$(awk 'tolower($1) == "mcp-session-id:" { gsub(/\r/, "", $2); print $2; exit }' "${hdr_file}")"
  rm -f "${hdr_file}"
  [[ -n "${sid}" ]] || return 1

  # Confirm the initialize response itself includes a result frame.
  payload="$(printf '%s\n' "${body}" | sed -n 's/^data: //p' | head -n 1)"
  printf '%s' "${payload}" | jq -e '.result.protocolVersion' >/dev/null 2>&1 || return 1

  # Step 4b — send the initialized notification (server replies 202, no body).
  curl -fsS -o /dev/null -X POST "${MCP_URL}" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H "Mcp-Session-Id: ${sid}" \
    -d "${INITIALIZED_REQ}" 2>/dev/null || return 1

  # Step 4c — tools/list and verify the array is non-empty.
  list_body="$(curl -fsS -X POST "${MCP_URL}" \
      -H 'Content-Type: application/json' \
      -H 'Accept: application/json, text/event-stream' \
      -H "Mcp-Session-Id: ${sid}" \
      -d "${LIST_REQ}" 2>/dev/null)" || return 1
  payload="$(printf '%s\n' "${list_body}" | sed -n 's/^data: //p' | head -n 1)"
  [[ -n "${payload}" ]] || payload="${list_body}"
  printf '%s' "${payload}" | jq -e '.result.tools | length > 0' >/dev/null 2>&1
}

while true; do
  if mcp_ready; then
    break
  fi
  if (( $(date +%s) > DEADLINE )); then
    echo "[up] FAIL: MCP not ready after 60s" >&2
    exit 1
  fi
  sleep 2
done

echo "[up] MCP ready"

# ---------------------------------------------------------------------------
# Step 5 — Final summary.
# ---------------------------------------------------------------------------
echo "[up] stack healthy: searxng=ok valkey=ok mcp=ok"
