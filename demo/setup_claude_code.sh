#!/usr/bin/env bash
#
# Route a real AI agent (Claude Code) through the AI Agent Gateway, and send
# everything it does to AiSOC.
#
#   Claude Code ── MCP tool calls ──▶ gateway :18080 (profile "claude-code") ─┐
#        │        model calls ──────▶ gateway :18082 (LLM plane)            ─┤─▶ demo/run_bridge.sh ─▶ AiSOC
#        └─ its own OpenTelemetry events (prompts, Bash, file edits) ─────────────▶ AiSOC OTLP receiver :8081/v1/logs
#
# Why both paths: the gateway only sees what passes through it (model calls and
# MCP tools). Claude Code's built-in tools (Bash, Read, Edit) run locally and
# never touch the gateway, so its own telemetry is how AiSOC sees those.
#
# What this script does (safe to re-run):
#   1. makes sure the gateway has the "everything" tool server registered
#   2. creates a "claude-code" profile (echo + get-sum only) and an agent key bound to it
#   3. registers the gateway as Claude Code's MCP server (user scope)
#   4. switches on AiSOC's OTLP logs receiver and mints a token for it
#   5. writes demo/claude-code.env: source it, then run `claude`
#
# Run from the ai-agent-gateway folder, with both stacks up:
#   ./demo/setup_claude_code.sh
# Needs: docker, curl, jq, npx; the AiSOC checkout at $AISOC_DIR (default /workspaces/AiSOC).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

AISOC_DIR="${AISOC_DIR:-/workspaces/AiSOC}"
API="http://localhost:${GW_API_PORT:-18081}/api/v1"
MCP_URL="http://localhost:${GW_MCP_PORT:-18080}/mcp"
LLM_URL="http://localhost:${GW_LLM_PORT:-18082}"
TOOLSRV_PORT="${TOOLSRV_PORT:-23014}"
PROFILE_NAME="claude-code"
GW=(docker compose -f deploy/docker-compose.yml -f demo/docker-compose.demo-ports.yml)

say()  { echo; echo "== $* =="; }
note() { echo "   $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

for c in docker curl jq npx; do command -v "$c" >/dev/null || die "'$c' is required"; done
curl -sf "$API/health" >/dev/null || die "the gateway is not answering on $API (start it first)"
[[ -d "$AISOC_DIR" ]] || die "AiSOC not found at $AISOC_DIR (set AISOC_DIR)"
[[ -f "$AISOC_DIR/demo/docker-compose.otlp.yml" ]] || die "$AISOC_DIR is missing demo/docker-compose.otlp.yml: run 'git pull' there first"

api() {  # api <method> <path> [json]  -> API_HTTP, API_BODY
  local args=(-sS -X "$1" -H "Authorization: Bearer $GATEWAY_ADMIN_KEY" -w '\n%{http_code}')
  [[ -n "${3:-}" ]] && args+=(-H "Content-Type: application/json" -d "$3")
  local out; out="$(curl "${args[@]}" "$API$2")"
  API_HTTP="${out##*$'\n'}"; API_BODY="${out%$'\n'*}"
}
port_open() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

# ---------------------------------------------------------------------------
say "1. Gateway: admin key and tool server"
if [[ -z "${GATEWAY_ADMIN_KEY:-}" ]]; then
  GATEWAY_ADMIN_KEY="$("${GW[@]}" exec -T gateway /gateway bootstrap-key --force)"
  note "minted an admin key: $GATEWAY_ADMIN_KEY"
fi
export GATEWAY_ADMIN_KEY

if ! port_open "$TOOLSRV_PORT"; then
  note "starting the MCP reference tool server on :$TOOLSRV_PORT"
  PORT="$TOOLSRV_PORT" npx -y @modelcontextprotocol/server-everything@2026.8.31 streamableHttp \
    >"$ROOT_DIR/demo/.toolserver.log" 2>&1 &
  echo $! >"$ROOT_DIR/demo/.toolserver.pid"
  for _ in $(seq 1 90); do port_open "$TOOLSRV_PORT" && break; sleep 1; done
  port_open "$TOOLSRV_PORT" || die "tool server did not start; see demo/.toolserver.log"
fi
api GET "/connectors?limit=500"
CONNECTOR_ID="$(jq -r '.items[]? | select(.slug=="everything") | .id' <<<"$API_BODY" | head -n1)"
if [[ -z "$CONNECTOR_ID" ]]; then
  api POST /connectors "{\"name\":\"everything\",\"slug\":\"everything\",\"endpoint\":\"http://host.docker.internal:${TOOLSRV_PORT}/mcp\"}"
  CONNECTOR_ID="$(jq -r '.id' <<<"$API_BODY")"
fi
api POST "/connectors/$CONNECTOR_ID/discover"
note "tool server 'everything' has $(jq -r '.total' <<<"$API_BODY") tools"

# ---------------------------------------------------------------------------
say "2. Gateway: '$PROFILE_NAME' profile and a key bound to it"
api GET "/profiles?limit=500"
PROFILE_ID="$(jq -r --arg n "$PROFILE_NAME" '.items[]? | select(.name==$n) | .id' <<<"$API_BODY" | head -n1)"
if [[ -z "$PROFILE_ID" ]]; then
  api POST /profiles "$(jq -nc --arg n "$PROFILE_NAME" '{name:$n}')"
  PROFILE_ID="$(jq -r '.id' <<<"$API_BODY")"
fi
api PUT "/profiles/$PROFILE_ID/tools" "$(jq -nc --arg c "$CONNECTOR_ID" '{tools:[{connector_id:$c,tool_name:"echo"},{connector_id:$c,tool_name:"get-sum"}]}')"
api POST /api-keys "$(jq -nc --arg p "$PROFILE_ID" '{name:"claude-code", role:"agent", profile_id:$p}')"
CC_KEY="$(jq -r '.key' <<<"$API_BODY")"
[[ "$CC_KEY" == gk_* ]] || die "could not mint the claude-code key: HTTP $API_HTTP $API_BODY"
note "profile '$PROFILE_NAME' allows: echo, get-sum (get-env and the other 11 tools are refused)"
note "agent key 'claude-code' minted and bound to it"

# ---------------------------------------------------------------------------
say "3. Claude Code: install (if needed) and register the gateway as its MCP server"
if ! command -v claude >/dev/null; then
  note "installing Claude Code (npm install -g @anthropic-ai/claude-code)"
  npm install -g @anthropic-ai/claude-code >/dev/null
fi
claude mcp remove tusk-ai-gateway -s user >/dev/null 2>&1 || true
claude mcp add --transport http --scope user tusk-ai-gateway "$MCP_URL" \
  --header "Authorization: Bearer ${CC_KEY}" \
  --header "X-Agent-Profile-Name: ${PROFILE_NAME}" >/dev/null
note "registered: tusk-ai-gateway -> $MCP_URL (check with: claude mcp list)"

# ---------------------------------------------------------------------------
say "4. AiSOC: switch on the OpenTelemetry logs receiver and mint a token for it"
AISOC=(docker compose -f docker-compose.yml)
[[ -f "$AISOC_DIR/docker-compose.ports.yml" ]] && AISOC+=(-f docker-compose.ports.yml)
AISOC+=(-f demo/docker-compose.otlp.yml)
(cd "$AISOC_DIR" && "${AISOC[@]}" up -d --no-deps ingest-worker >/dev/null 2>&1)
ingest_port="$(cd "$AISOC_DIR" && "${AISOC[@]}" port ingest-worker 8080 2>/dev/null | sed -E 's/.*:([0-9]+)$/\1/' || true)"
INGEST="http://localhost:${ingest_port:-8081}"
for _ in $(seq 1 60); do curl -sf "$INGEST/health" >/dev/null && break; sleep 2; done
curl -sf "$INGEST/health" >/dev/null || die "AiSOC ingest did not come back on $INGEST"
AISOC_API_TOKEN="$(cd "$AISOC_DIR" && "${AISOC[@]}" run --rm -T api python -m app.scripts.mint_api_token --quiet)"
out="$(curl -sS -X POST "http://localhost:8000/api/v1/inbox/tokens" \
  -H "Authorization: Bearer $AISOC_API_TOKEN" -H 'Content-Type: application/json' \
  -d '{"template_id": "otlp-logs", "label": "claude-code"}')"
OTLP_TOKEN="$(jq -r '.token // empty' <<<"$out")"
[[ -n "$OTLP_TOKEN" ]] || die "could not mint an otlp-logs token: $out"
code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$INGEST/v1/logs" -H "X-Inbox-Token: $OTLP_TOKEN" \
  -H 'Content-Type: application/json' -d '{"resourceLogs":[]}')"
note "receiver on $INGEST/v1/logs answered HTTP $code to an empty test batch"

# ---------------------------------------------------------------------------
say "5. Writing demo/claude-code.env"
cat >"$ROOT_DIR/demo/claude-code.env" <<ENV
# Generated by demo/setup_claude_code.sh. Holds live keys: do not commit.
# Usage:  source demo/claude-code.env && claude

# Model calls -> the gateway's LLM plane. Claude Code keeps its own Anthropic
# login (or ANTHROPIC_API_KEY); the gateway key rides in a separate header.
export ANTHROPIC_BASE_URL="${LLM_URL}"
export ANTHROPIC_CUSTOM_HEADERS="X-Gateway-Key: ${CC_KEY}"

# Claude Code's own telemetry -> AiSOC's OTLP logs receiver.
export CLAUDE_CODE_ENABLE_TELEMETRY=1
export OTEL_LOGS_EXPORTER=otlp
export OTEL_METRICS_EXPORTER=none          # AiSOC takes logs, not metrics
export OTEL_EXPORTER_OTLP_PROTOCOL=http/json
export OTEL_EXPORTER_OTLP_LOGS_ENDPOINT="${INGEST}/v1/logs"
export OTEL_EXPORTER_OTLP_HEADERS="X-Inbox-Token=${OTLP_TOKEN}"
export OTEL_LOGS_EXPORT_INTERVAL=2000
export OTEL_LOG_TOOL_DETAILS=1             # include Bash commands and file paths
export OTEL_LOG_USER_PROMPTS=1             # include prompt text (demo only; off by default for privacy)
export OTEL_SERVICE_NAME=claude-code
export OTEL_RESOURCE_ATTRIBUTES="host.name=$(hostname)"
ENV
note "done"

echo
echo "Next:"
echo "  1. Keep the bridge running in its own terminal:   APPROVED_MODELS=claude-sonnet,claude-opus ./demo/run_bridge.sh"
echo "  2. In this terminal:                               source demo/claude-code.env && claude"
echo "     (first time: Claude Code asks you to log in with your Claude account or an API key)"
