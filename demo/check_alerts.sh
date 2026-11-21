#!/usr/bin/env bash
# Why is there no AiSOC alert for Claude Code? Checks the alert path hop by hop.
#
#   cd /workspaces/ai-agent-gateway && ./demo/check_alerts.sh
#
# Path: Claude Code -> gateway LLM plane (stores a redacted copy) -> bridge -> AiSOC ingest -> rule -> alert
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

AISOC_DIR="${AISOC_DIR:-/workspaces/AiSOC}"
API="http://localhost:${GW_API_PORT:-18081}/api/v1"
GW=(docker compose -f deploy/docker-compose.yml -f demo/docker-compose.demo-ports.yml)
ok()   { echo "  [OK]   $*"; }
bad()  { echo "  [FAIL] $*"; }
info() { echo "         $*"; }

echo "1. Gateway is up and keeps a copy of model calls"
if ! curl -sf "$API/health" >/dev/null; then bad "gateway not answering on $API"; exit 1; fi
cid="$("${GW[@]}" ps -q gateway 2>/dev/null)"
if docker inspect "$cid" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep -qx 'GATEWAY_LLM_PROXY_CAPTURE_STORE_BODIES=true'; then
  ok "body capture on (secret redaction can run)"
else
  bad "body capture off: run 'git pull' then: ${GW[*]} up -d"
fi

if [[ -z "${GATEWAY_ADMIN_KEY:-}" ]]; then
  GATEWAY_ADMIN_KEY="$("${GW[@]}" exec -T gateway /gateway bootstrap-key --force 2>/dev/null)"
fi
H=(-H "Authorization: Bearer $GATEWAY_ADMIN_KEY")

echo "2. Claude Code's model calls go through the gateway (last 2 hours)"
since="$(date -u -d '-2 hours' +%Y-%m-%dT%H:%M:%SZ)"
logs="$(curl -s "${H[@]}" "$API/analytics/llm-logs?from=$since&limit=500")"
n="$(jq -r '.items | length' <<<"$logs" 2>/dev/null || echo 0)"
if [[ "$n" =~ ^[1-9] ]]; then
  ok "$n model call(s) recorded; models: $(jq -r '[.items[].model] | unique | join(", ")' <<<"$logs")"
else
  bad "no model calls recorded: start Claude Code with 'source /workspaces/ai-agent-gateway/demo/claude-code.env && claude' so ANTHROPIC_BASE_URL points at the gateway"
fi

echo "3. The gateway redacted a secret in a stored prompt"
found=""
for rid in $(jq -r '.items[].request_id' <<<"$logs" 2>/dev/null | head -50); do
  det="$(curl -s "${H[@]}" "$API/analytics/llm-logs/$rid")"
  kinds="$(jq -r '[.request_body, .messages, .system] | map(select(. != null)) | .[]' <<<"$det" 2>/dev/null \
    | while read -r b; do (echo "$b" | base64 -d 2>/dev/null || echo "$b"); done \
    | grep -oE '\[REDACTED:[a-z_]+\]' | sort -u | tr '\n' ' ')"
  if [[ -n "$kinds" ]]; then found="$kinds"; break; fi
done
if [[ -n "$found" ]]; then ok "found in a stored prompt: $found"
else bad "no [REDACTED:...] marker in the stored prompts: ask Claude Code to read leaky_app.py (after body capture is on)"; fi

echo "4. AiSOC alerts (last 24 hours)"
if [[ -d "$AISOC_DIR" ]]; then
  tok="$(cd "$AISOC_DIR" && docker compose run --rm -T api python -m app.scripts.mint_api_token --quiet 2>/dev/null)"
  alerts="$(curl -s -H "Authorization: Bearer $tok" "http://localhost:8000/api/v1/alerts?limit=200")"
  total="$(jq -r '.items | length' <<<"$alerts" 2>/dev/null || echo "?")"
  info "$total alert(s) in AiSOC; AI-agent ones:"
  jq -r '.items[] | select((.title // "") | test("AI Agent|AI agent|Credential Material|Unapproved Model|Gateway"; "i")) | "           [\(.severity)] \(.title)  (\(.created_at // ""))"' <<<"$alerts" 2>/dev/null | head -15
  if jq -e '.items[] | select((.title // "") | test("Credential Material"; "i"))' >/dev/null 2>&1 <<<"$alerts"; then
    ok "'Credential Material Present in an AI Prompt' is there: open Alerts in the console"
  else
    bad "no secret alert yet. Is the bridge running? (APPROVED_MODELS=claude-sonnet,claude-opus ./demo/run_bridge.sh) It should print [SECRET IN PROMPT]"
  fi
else
  info "AiSOC folder not found at $AISOC_DIR"
fi
