#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

trap 'echo "[down] FAILED at line $LINENO" >&2' ERR

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PROJECT_NAME="$(basename "$REPO_ROOT")"

echo "[down] stopping stack (project=${PROJECT_NAME})"

# Step 1: podman-compose down --remove-orphans (exit code is inconsistent, always guard)
podman-compose down --remove-orphans 2>&1 || true

# Step 2: Remove any remaining containers matching the project label
while read -r CID; do
  [ -z "$CID" ] && continue
  echo "[down] removing leftover container: $CID"
  podman rm -f "$CID" >/dev/null 2>&1 || true
done < <(podman ps -a --filter "label=io.podman.compose.project=${PROJECT_NAME}" --format '{{.ID}}')

# Step 3: Remove any remaining pods matching the project label
while read -r POD; do
  [ -z "$POD" ] && continue
  echo "[down] removing leftover pod: $POD"
  podman pod rm -f "$POD" >/dev/null 2>&1 || true
done < <(podman pod ps --filter "label=io.podman.compose.project=${PROJECT_NAME}" --format '{{.Name}}' 2>/dev/null || true)

# Step 4: Verify nothing left — check for the 3 named containers
REMAINING=$(podman ps -a \
  --filter 'name=^searxng$' \
  --filter 'name=^valkey$' \
  --filter 'name=^mcp-searxng$' \
  --format '{{.Names}}' 2>/dev/null | wc -l)

if [ "$REMAINING" -gt 0 ]; then
  echo "[down] WARNING: some containers still present" >&2
  exit 1
fi

echo "[down] stack stopped"
