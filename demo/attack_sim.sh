#!/usr/bin/env bash
#
# AI Agent Gateway attack simulation: "Rogue Agent".
#
# Sets up a realistic deployment (one MCP tool server, a narrowly-scoped
# "support-bot" agent, an admin), then plays the attacker against it:
#
#   1  No credentials on the MCP plane                       -> expect 401
#   2  Forged / guessed API key                               -> expect 401
#   3  Compromised agent key tries admin actions              -> expect 403 (reads are allowed by design: a finding)
#   4  Prompt-injected agent calls a tool it was not granted  -> expect -32003
#   5  Agent spoofs a more powerful profile header            -> expect -32003
#   6  Misconfiguration: unbound key, no profile header       -> ALLOWED (the risk), then fixed
#   7  SSRF: connector pointed at cloud metadata / internal   -> expect 400 egress_blocked
#   8  Audit trail: every call above, attributed              -> access log (analytics profile)
#   9  Credential brute force                                 -> expect 401 x10, then 429 lockout
#
# Nothing here attacks anything outside your laptop: the "tool server" is the
# official MCP reference server (@modelcontextprotocol/server-everything)
# started locally, and the SSRF step only asks the gateway to *register*
# blocked addresses; the gateway refuses before connecting.
#
# Run from the repo root, with the stack up via the demo overlay:
#   docker compose -f deploy/docker-compose.yml -f demo/docker-compose.demo-ports.yml up --build -d
#   ./demo/attack_sim.sh                 # everything
#   ./demo/attack_sim.sh --skip-lockout  # skip step 9 (it locks this IP out of the MCP plane for 30s)
#   ./demo/attack_sim.sh --pause         # wait for Enter between steps (for presenting live)
#   ./demo/attack_sim.sh --burst         # step 4 repeats the forbidden call 12 times, so AiSOC's
#                                        # "AI agent repeatedly denied a tool call" rule fires
#                                        # (run demo/run_bridge.sh to stream these into AiSOC)
#
# Needs: docker compose, curl, jq, node/npx.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

MCP_PORT="${GW_MCP_PORT:-18080}"
API_PORT="${GW_API_PORT:-18081}"
MCP_URL="http://localhost:${MCP_PORT}/mcp"
API="http://localhost:${API_PORT}/api/v1"
TOOLSRV_PORT="${TOOLSRV_PORT:-23014}"

COMPOSE=(docker compose -f deploy/docker-compose.yml)
if [[ -f demo/docker-compose.demo-ports.yml ]]; then
  COMPOSE+=(-f demo/docker-compose.demo-ports.yml)
fi

SKIP_LOCKOUT=false
PAUSE=false
BURST=false
for arg in "$@"; do
  case "$arg" in
    --skip-lockout) SKIP_LOCKOUT=true ;;
    --pause) PAUSE=true ;;
    --burst) BURST=true ;;
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# output helpers
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  B=$'\e[1m'; R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'; N=$'\e[0m'
else
  B=""; R=""; G=""; Y=""; C=""; N=""
fi
HELD=0; FAILED=0; FINDINGS=0
step()    { echo; echo "${B}${C}== $* ==${N}"; }
attack()  { echo "  ${Y}attacker:${N} $*"; }
held()    { echo "  ${G}BLOCKED${N}  $*"; HELD=$((HELD + 1)); }
broke()   { echo "  ${R}NOT BLOCKED${N}  $*"; FAILED=$((FAILED + 1)); }
note()    { echo "  ${B}note:${N} $*"; }
pause()   { if [[ "$PAUSE" == true ]]; then read -r -p "  (Enter for next step) " _; fi; }

for c in docker curl jq npx; do
  command -v "$c" >/dev/null || { echo "'$c' is required" >&2; exit 1; }
done

port_open() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

# mcp <key> <profile-header-or-empty> <method> [params-json]
# Opens a fresh MCP session for <key>, then sends one request.
# Leaves: MCP_HTTP (HTTP status), MCP_BODY (response body).
mcp() {
  local key="$1" profile="$2" method="$3" params="${4:-}"
  local hdrs; hdrs="$(mktemp)"
  local auth=()
  [[ -n "$key" ]] && auth=(-H "Authorization: Bearer $key")
  local prof=()
  [[ -n "$profile" ]] && prof=(-H "X-Agent-Profile-Name: $profile")
  local common=(-sS -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream")

  local init out
  init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"rogue-agent-demo","version":"1.0"}}}'
  # The handshake carries only the key; the profile header (honest or spoofed)
  # rides the request under test, so a refusal is attributed to that request.
  out="$(curl "${common[@]}" ${auth[@]+"${auth[@]}"} -D "$hdrs" -w '\n%{http_code}' -d "$init" "$MCP_URL")"
  MCP_HTTP="${out##*$'\n'}"; MCP_BODY="${out%$'\n'*}"
  if [[ "$MCP_HTTP" != "200" ]]; then rm -f "$hdrs"; return 0; fi

  local sid
  sid="$(grep -i '^Mcp-Session-Id:' "$hdrs" | tail -n1 | sed -E 's/^[^:]+:[[:space:]]*//' | tr -d '\r\n' || true)"
  if [[ -z "$sid" ]] || jq -e '.error' >/dev/null 2>&1 <<<"$MCP_BODY"; then rm -f "$hdrs"; return 0; fi
  rm -f "$hdrs"
  curl "${common[@]}" ${auth[@]+"${auth[@]}"} -H "Mcp-Session-Id: $sid" -o /dev/null \
    -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' "$MCP_URL"

  local body
  if [[ -n "$params" ]]; then
    body="$(jq -nc --arg m "$method" --argjson p "$params" '{jsonrpc:"2.0",id:2,method:$m,params:$p}')"
  else
    body="$(jq -nc --arg m "$method" '{jsonrpc:"2.0",id:2,method:$m}')"
  fi
  out="$(curl "${common[@]}" ${auth[@]+"${auth[@]}"} ${prof[@]+"${prof[@]}"} -H "Mcp-Session-Id: $sid" -w '\n%{http_code}' -d "$body" "$MCP_URL")"
  MCP_HTTP="${out##*$'\n'}"; MCP_BODY="${out%$'\n'*}"
}

# api <method> <path> <key> [json-body]  -> leaves API_HTTP, API_BODY
api() {
  local method="$1" path="$2" key="$3" data="${4:-}"
  local args=(-sS -X "$method" -H "Authorization: Bearer $key" -w '\n%{http_code}')
  [[ -n "$data" ]] && args+=(-H "Content-Type: application/json" -d "$data")
  local out; out="$(curl "${args[@]}" "$API$path")"
  API_HTTP="${out##*$'\n'}"; API_BODY="${out%$'\n'*}"
}

# ---------------------------------------------------------------------------
# 0. setup: the "victim" deployment
# ---------------------------------------------------------------------------
step "0. Setting up the target: a tool server, an admin, and a narrowly-scoped support bot"

curl -sf "http://localhost:${API_PORT}/api/v1/health" >/dev/null || {
  echo "The gateway is not answering on :${API_PORT}. Start it with:" >&2
  echo "  docker compose -f deploy/docker-compose.yml -f demo/docker-compose.demo-ports.yml up --build -d" >&2
  exit 1
}

if port_open "$TOOLSRV_PORT"; then
  note "MCP tool server already running on :$TOOLSRV_PORT"
else
  note "starting the MCP reference tool server on :$TOOLSRV_PORT (first run downloads it)"
  PORT="$TOOLSRV_PORT" npx -y @modelcontextprotocol/server-everything@2026.8.31 streamableHttp \
    >"$ROOT_DIR/demo/.toolserver.log" 2>&1 &
  echo $! >"$ROOT_DIR/demo/.toolserver.pid"
  for _ in $(seq 1 90); do port_open "$TOOLSRV_PORT" && break; sleep 1; done
  port_open "$TOOLSRV_PORT" || { echo "tool server did not start; see demo/.toolserver.log" >&2; exit 1; }
fi

if [[ -n "${GATEWAY_ADMIN_KEY:-}" ]]; then
  ADMIN_KEY="$GATEWAY_ADMIN_KEY"
else
  ADMIN_KEY="$("${COMPOSE[@]}" exec -T gateway /gateway bootstrap-key 2>/dev/null || true)"
  [[ -n "$ADMIN_KEY" ]] || ADMIN_KEY="$("${COMPOSE[@]}" exec -T gateway /gateway bootstrap-key --force 2>/dev/null || true)"
fi
[[ -n "$ADMIN_KEY" ]] || { echo "could not obtain an admin key (set GATEWAY_ADMIN_KEY)" >&2; exit 1; }
note "admin key ready (${ADMIN_KEY:0:11}...)"

api GET "/connectors?limit=500" "$ADMIN_KEY"
CONNECTOR_ID="$(jq -r '.items[]? | select(.slug=="everything") | .id' <<<"$API_BODY" | head -n1)"
if [[ -z "$CONNECTOR_ID" ]]; then
  api POST /connectors "$ADMIN_KEY" "{\"name\":\"everything\",\"slug\":\"everything\",\"endpoint\":\"http://host.docker.internal:${TOOLSRV_PORT}/mcp\"}"
  CONNECTOR_ID="$(jq -r '.id' <<<"$API_BODY")"
fi
api POST "/connectors/$CONNECTOR_ID/discover" "$ADMIN_KEY"
TOOL_TOTAL="$(jq -r '.total' <<<"$API_BODY")"
note "connector 'everything' registered with $TOOL_TOTAL tools (incl. get-env, which can read the server's environment)"

ensure_profile() {  # ensure_profile <name> <tools-json>  -> PROFILE_ID
  api GET "/profiles?limit=500" "$ADMIN_KEY"
  PROFILE_ID="$(jq -r --arg n "$1" '.items[]? | select(.name==$n) | .id' <<<"$API_BODY" | head -n1)"
  if [[ -z "$PROFILE_ID" ]]; then
    api POST /profiles "$ADMIN_KEY" "$(jq -nc --arg n "$1" '{name:$n}')"
    PROFILE_ID="$(jq -r '.id' <<<"$API_BODY")"
  fi
  api PUT "/profiles/$PROFILE_ID/tools" "$ADMIN_KEY" "$2"
}

ensure_profile "support-bot" "$(jq -nc --arg c "$CONNECTOR_ID" '{tools:[{connector_id:$c,tool_name:"echo"},{connector_id:$c,tool_name:"get-sum"}]}')"
SUPPORT_PROFILE_ID="$PROFILE_ID"
api POST "/connectors/$CONNECTOR_ID/discover" "$ADMIN_KEY"
ALL_TOOLS="$(jq -c --arg c "$CONNECTOR_ID" '{tools:[.items[] | {connector_id:$c, tool_name:.tool_name}]}' <<<"$API_BODY")"
ensure_profile "ops-admin" "$ALL_TOOLS"
note "profiles: 'support-bot' (echo, get-sum only) and 'ops-admin' (all $TOOL_TOTAL tools)"

api POST /api-keys "$ADMIN_KEY" "$(jq -nc --arg p "$SUPPORT_PROFILE_ID" '{name:"support-bot", role:"agent", profile_id:$p}')"
BOT_KEY="$(jq -r '.key' <<<"$API_BODY")"
api POST /api-keys "$ADMIN_KEY" '{"name":"legacy-agent", "role":"agent"}'
LEGACY_KEY="$(jq -r '.key' <<<"$API_BODY")"
LEGACY_KEY_ID="$(jq -r '.id' <<<"$API_BODY")"
note "agent keys: 'support-bot' (bound to its profile) and 'legacy-agent' (role agent, NOT bound)"
pause

# ---------------------------------------------------------------------------
step "1. Unauthenticated access to the MCP plane"
attack "calls tools/list with no API key"
mcp "" "" tools/list
if [[ "$MCP_HTTP" == "401" ]]; then held "HTTP 401 - every request must carry a gateway-issued key"; else broke "HTTP $MCP_HTTP"; fi
pause

# ---------------------------------------------------------------------------
step "2. Forged API key"
FAKE="gk_$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 40)"
attack "guesses a key that looks real: ${FAKE:0:14}..."
mcp "$FAKE" "" tools/list
if [[ "$MCP_HTTP" == "401" ]]; then held "HTTP 401 - keys are looked up, not pattern-matched"; else broke "HTTP $MCP_HTTP"; fi
pause

# ---------------------------------------------------------------------------
step "3. Stolen agent key used for privilege escalation"
attack "uses the support-bot's key to mint itself an admin key on the control plane"
api POST /api-keys "$BOT_KEY" '{"name":"backdoor","role":"admin"}'
if [[ "$API_HTTP" == "403" ]]; then held "HTTP 403 - agent-role keys cannot touch the control plane"; else broke "HTTP $API_HTTP $API_BODY"; fi
attack "tries to read the gateway's configuration (list of connectors)"
api GET /connectors "$BOT_KEY"
if [[ "$API_HTTP" == "403" ]]; then
  held "HTTP 403"
elif [[ "$API_HTTP" == "200" ]]; then
  echo "  ${Y}ALLOWED (by design)${N}  HTTP 200 - the built-in agent role includes *.read (read-only; secret header values come back masked)"
  note "finding: a stolen agent key can map connectors and endpoints. Hardening: a custom role with only mcp.* (auth.roles)"
  FINDINGS=$((FINDINGS + 1))
else
  broke "HTTP $API_HTTP"
fi
pause

# ---------------------------------------------------------------------------
step "4. Prompt injection: the agent is tricked into calling a tool it was never given"
attack "support-bot calls everything__get-env (would dump the tool server's environment variables)"
mcp "$BOT_KEY" "" tools/call '{"name":"everything__get-env","arguments":{}}'
code="$(jq -r '.error.code // empty' <<<"$MCP_BODY")"
if [[ "$code" == "-32003" ]]; then held "JSON-RPC -32003: $(jq -r '.error.message' <<<"$MCP_BODY")"; else broke "HTTP $MCP_HTTP code=${code:-none}"; fi
mcp "$BOT_KEY" "" tools/list
note "what support-bot can see: $(jq -r '[.result.tools[]?.name] | join(", ")' <<<"$MCP_BODY")"
mcp "$BOT_KEY" "" tools/call '{"name":"everything__echo","arguments":{"message":"hello from support-bot"}}'
note "its allowed tool still works: $(jq -r '.result.content[0].text // .error.message' <<<"$MCP_BODY")"
if [[ "$BURST" == true ]]; then
  attack "keeps probing: 12 more get-env attempts in a row (a hijacked agent rarely stops at one)"
  refused=0
  for _ in $(seq 1 12); do
    mcp "$BOT_KEY" "" tools/call '{"name":"everything__get-env","arguments":{}}'
    [[ "$(jq -r '.error.code // empty' <<<"$MCP_BODY")" == "-32003" ]] && refused=$((refused + 1))
  done
  if [[ "$refused" == 12 ]]; then held "all 12 refused (-32003); AiSOC's rule wd-ai-agent-tool-denials fires at 10 in 5 min"; else broke "only $refused of 12 refused"; fi
fi
pause

# ---------------------------------------------------------------------------
step "5. Profile spoofing"
attack "support-bot sends 'X-Agent-Profile-Name: ops-admin' to claim the admin tool set"
mcp "$BOT_KEY" "ops-admin" tools/call '{"name":"everything__get-env","arguments":{}}'
code="$(jq -r '.error.code // empty' <<<"$MCP_BODY")"
if [[ "$code" == "-32003" ]]; then held "JSON-RPC -32003 - a key bound to a profile cannot name another one"; else broke "HTTP $MCP_HTTP code=${code:-none}"; fi
pause

# ---------------------------------------------------------------------------
step "6. Misconfiguration: an agent key that was never bound to a profile"
attack "legacy-agent sends no profile header at all"
mcp "$LEGACY_KEY" "" tools/list
note "legacy-agent can see $(jq -r '.result.tools | length' <<<"$MCP_BODY") tools"
mcp "$LEGACY_KEY" "" tools/call '{"name":"everything__get-env","arguments":{}}'
if jq -e '.result' >/dev/null <<<"$MCP_BODY"; then
  echo "  ${R}ALLOWED${N}  get-env ran ($(jq -r '.result.content[0].text // ""' <<<"$MCP_BODY" | wc -c | tr -d ' ') bytes of environment returned; not printed here)"
  note "this is the gateway's documented default (mcp.require_profile=false): scoping is opt-in"
else
  note "call was refused ($(jq -c '.error' <<<"$MCP_BODY")) - require_profile may already be on"
fi
echo "  ${B}fix:${N} bind the key to a profile (PATCH /api-keys/{id} {\"profile_id\": ...})"
api PATCH "/api-keys/$LEGACY_KEY_ID" "$ADMIN_KEY" "$(jq -nc --arg p "$SUPPORT_PROFILE_ID" '{profile_id:$p}')"
sleep 1
mcp "$LEGACY_KEY" "" tools/call '{"name":"everything__get-env","arguments":{}}'
code="$(jq -r '.error.code // empty' <<<"$MCP_BODY")"
if [[ "$code" == "-32003" ]]; then held "after binding: JSON-RPC -32003, effective immediately, no restart"; else broke "after binding: HTTP $MCP_HTTP code=${code:-none}"; fi
pause

# ---------------------------------------------------------------------------
step "7. SSRF: registering a 'tool server' that is really cloud metadata or the internal network"
for url in \
  "http://169.254.169.254/latest/meta-data/iam/security-credentials/" \
  "http://2852039166/latest/meta-data/" \
  "http://[::ffff:169.254.169.254]/latest/meta-data/" \
  "http://10.0.0.5:8080/mcp"; do
  attack "registers a connector at $url"
  api POST /connectors "$ADMIN_KEY" "$(jq -nc --arg u "$url" --arg s "ssrf-$RANDOM" '{name:$s, slug:$s, endpoint:$u}')"
  etype="$(jq -r '.error.type // empty' <<<"$API_BODY" 2>/dev/null || true)"
  if [[ "$API_HTTP" == "400" && "$etype" == "egress_blocked" ]]; then
    held "HTTP 400 egress_blocked"
  else
    broke "HTTP $API_HTTP ${API_BODY:0:160}"
  fi
done
pause

# ---------------------------------------------------------------------------
step "8. Audit trail: what did the agents actually do?"
api GET "/analytics/logs?limit=15" "$ADMIN_KEY"
if [[ "$API_HTTP" == "200" ]]; then
  jq -r '.items[]? | [ .timestamp, (.principal // .key_id // "-"), .method, (.tool_name // "-"), (.profile // "-"), (.status_code|tostring), (.error_code // "" | tostring) ] | @tsv' <<<"$API_BODY" \
    | column -t -s $'\t' | sed 's/^/  /' | head -n 15
  note "full view: console -> Access Logs (http://localhost:${API_PORT})"
else
  note "access log API returned HTTP $API_HTTP. It needs ClickHouse: start the stack with"
  note "  GATEWAY_SINKS_CLICKHOUSE_ENABLED=true docker compose -f deploy/docker-compose.yml -f demo/docker-compose.demo-ports.yml --profile analytics up -d"
fi
pause

# ---------------------------------------------------------------------------
if [[ "$SKIP_LOCKOUT" == true ]]; then
  step "9. Credential brute force (skipped: --skip-lockout)"
else
  step "9. Credential brute force against the MCP plane"
  attack "fires 12 random keys in a row"
  codes=()
  for _ in $(seq 1 12); do
    k="gk_$(head -c 20 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 40)"
    codes+=("$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $k" -H 'Content-Type: application/json' \
      -H 'Accept: application/json, text/event-stream' -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' "$MCP_URL")")
  done
  note "responses: ${codes[*]}"
  if [[ " ${codes[*]} " == *" 429 "* ]]; then
    held "IP locked out (429 + Retry-After) after 10 failures"
  else
    broke "no lockout observed"
  fi
  mcp "$BOT_KEY" "" tools/list
  note "even the real support-bot key now gets HTTP $MCP_HTTP from this IP until the lockout expires (30s in the demo overlay, 5m by default)"
fi

# ---------------------------------------------------------------------------
echo
echo "${B}================================================================${N}"
echo "${B}Result: ${G}${HELD} controls held${N}${B}, ${R}${FAILED} failed${N}"
echo "${B}Findings: ${FINDINGS} by-design read access (step 3), plus one misconfiguration demonstrated and fixed (step 6).${N}"
echo "Console: http://localhost:${API_PORT}   (log in, then Access Logs / API Keys / Profiles)"
echo "Stop the tool server: kill \$(cat demo/.toolserver.pid)"
echo "${B}================================================================${N}"
[[ "$FAILED" == 0 ]]
