#!/usr/bin/env bash
# Start the gateway -> AiSOC bridge with both credentials filled in.
#
#   ./demo/run_bridge.sh                  # stream continuously (Ctrl+C to stop)
#   ./demo/run_bridge.sh --once --since 1h
#
# Needs: the gateway up with the analytics profile, and AiSOC up (make up).
# AISOC_DIR points at your AiSOC checkout (default /workspaces/AiSOC).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

AISOC_DIR="${AISOC_DIR:-/workspaces/AiSOC}"
GW=(docker compose -f deploy/docker-compose.yml -f demo/docker-compose.demo-ports.yml)

if [[ -z "${GATEWAY_ADMIN_KEY:-}" ]]; then
  echo "GATEWAY_ADMIN_KEY not set: minting a new gateway admin key for the bridge..."
  GATEWAY_ADMIN_KEY="$("${GW[@]}" exec -T gateway /gateway bootstrap-key --force)"
  echo "  key: $GATEWAY_ADMIN_KEY   (export it to reuse: export GATEWAY_ADMIN_KEY=...)"
fi
export GATEWAY_ADMIN_KEY

if [[ -z "${AISOC_INGEST_TOKEN:-}" ]]; then
  [[ -d "$AISOC_DIR" ]] || { echo "AiSOC not found at $AISOC_DIR (set AISOC_DIR)" >&2; exit 1; }
  echo "Minting an AiSOC ingest token..."
  AISOC_COMPOSE=(docker compose)
  [[ -f "$AISOC_DIR/docker-compose.ports.yml" ]] && AISOC_COMPOSE+=(-f docker-compose.yml -f docker-compose.ports.yml)
  AISOC_INGEST_TOKEN="$(cd "$AISOC_DIR" && "${AISOC_COMPOSE[@]}" run --rm -T api python -m app.scripts.mint_ingest_token --quiet)"
  ingest_port="$(cd "$AISOC_DIR" && "${AISOC_COMPOSE[@]}" port ingest-worker 8080 2>/dev/null | sed -E 's/.*:([0-9]+)$/\1/' || true)"
  export AISOC_INGEST_URL="http://localhost:${ingest_port:-8081}"
fi
export AISOC_INGEST_TOKEN

exec python3 demo/gateway_to_aisoc.py "$@"
