#!/usr/bin/env python3
"""Stream AI Agent Gateway activity into AiSOC as AI-agent telemetry.

The gateway enforces and records; AiSOC detects and investigates. This bridge
reads what the gateway recorded and pushes it through AiSOC's ingest API (the
same door every AiSOC connector uses), so a rogue agent becomes a SOC alert.

Two sources, two AiSOC connector types:

  gateway access log (GET /api/v1/analytics/logs, needs the analytics profile)
    every tools/call (allowed or refused) ... ai_runtime telemetry; no alert by itself

  gateway LLM log (GET /api/v1/analytics/llm-logs)
    every model call (Claude Code, SDKs) .... ai_runtime telemetry: model, tokens, cost
    a model outside APPROVED_MODELS ......... the same event, marked finding_type
                                              "unapproved_model" (AiSOC rule below)

  gateway container log (docker), because a request with a bad key has no
  tenant and so never reaches the access log
    "authentication failed" / "authentication rate limited" ... one ai_guardrail
    finding per poll (an alert), high when the brute-force lockout tripped

The detections are AiSOC's own, reading the ai_runtime fields:
  * det-application-086  "AI Agent Tool Call Denied" (low, T1078): every refusal
  * wd-ai-agent-tool-denials  "AI agent repeatedly denied a tool call" (high, T1078):
    one agent refused 10+ times within 5 minutes
  * det-application-082  "AI Agent Used an Unapproved Model" (medium): only when
    APPROVED_MODELS is set (comma-separated prefixes, e.g. claude-sonnet,claude-opus)
  Alerts are then correlated per agent and triaged by AiSOC's AI like any other.

Usage (from the ai-agent-gateway folder):
    GATEWAY_ADMIN_KEY=gk_... AISOC_INGEST_TOKEN=... python3 demo/gateway_to_aisoc.py           # keep streaming
    ... python3 demo/gateway_to_aisoc.py --once --since 30m                                    # backfill, then exit
    ... python3 demo/gateway_to_aisoc.py --dry-run --once                                      # print, send nothing

demo/run_bridge.sh fills in both credentials for you. Standard library only.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import deque
from datetime import datetime, timedelta, timezone

UTC = timezone.utc

GATEWAY_API = os.environ.get("GATEWAY_API_URL", "http://localhost:18081/api/v1").rstrip("/")
AISOC_INGEST = os.environ.get("AISOC_INGEST_URL", "http://localhost:8081").rstrip("/")
ADMIN_KEY = os.environ.get("GATEWAY_ADMIN_KEY", "").strip()
INGEST_TOKEN = os.environ.get("AISOC_INGEST_TOKEN", "").strip()
GATEWAY_HOST = os.environ.get("GATEWAY_NAME", "tuskira-ai-gateway")
CONNECTOR_ID = "tuskira-ai-gateway"
APPROVED_MODELS = [m.strip() for m in os.environ.get("APPROVED_MODELS", "").split(",") if m.strip()]
_WARNED = {"access": False}

# Only calls that DO something are telemetry; handshakes and listings are noise.
ACTION_METHODS = {"tools/call", "prompts/get", "resources/read"}

# JSON-RPC error codes the gateway uses for a policy refusal (docs/profiles.md).
POLICY_DENIED = {"-32003"}


# --------------------------------------------------------------------------- http
def _http(method: str, url: str, *, token: str = "", body: dict | None = None, timeout: float = 20) -> tuple[int, str]:
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:  # noqa: S310 - local URLs
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        return 0, str(e)


def _iso(t: datetime) -> str:
    return t.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def _parse_ts(raw: str) -> datetime | None:
    if not raw:
        return None
    raw = raw.replace("Z", "+00:00")
    # Go timestamps can carry nanoseconds; fromisoformat takes at most 6 digits.
    raw = re.sub(r"(\.\d{6})\d+", r"\1", raw)
    try:
        t = datetime.fromisoformat(raw)
    except ValueError:
        return None
    return t if t.tzinfo else t.replace(tzinfo=UTC)


# ---------------------------------------------------------------- gateway reads
def lookup_names() -> tuple[dict[str, str], dict[str, str]]:
    """key id -> key name, connector id -> slug, so alerts name agents, not UUIDs."""
    keys, conns = {}, {}
    status, body = _http("GET", f"{GATEWAY_API}/api-keys?limit=500", token=ADMIN_KEY)
    if status == 200:
        for k in json.loads(body).get("items", []):
            keys[str(k.get("id"))] = k.get("name") or k.get("prefix") or str(k.get("id"))
    status, body = _http("GET", f"{GATEWAY_API}/connectors?limit=500", token=ADMIN_KEY)
    if status == 200:
        for c in json.loads(body).get("items", []):
            conns[str(c.get("id"))] = c.get("slug") or c.get("name") or str(c.get("id"))
    return keys, conns


def fetch_access_logs(since: datetime) -> list[dict]:
    """Every access-log row from `since` on, oldest first."""
    rows: list[dict] = []
    offset = 0
    while True:
        q = urllib.parse.urlencode({"from": _iso(since), "limit": 500, "offset": offset})
        status, body = _http("GET", f"{GATEWAY_API}/analytics/logs?{q}", token=ADMIN_KEY)
        if status == 404:
            # No ClickHouse: tool calls are unavailable, model calls (Postgres) still flow.
            if not _WARNED["access"]:
                print(
                    "  ! gateway tool-call log unavailable (needs the analytics profile / ClickHouse); "
                    "forwarding model calls only",
                    file=sys.stderr,
                )
                _WARNED["access"] = True
            return []
        if status in (401, 403):
            raise SystemExit("The gateway refused GATEWAY_ADMIN_KEY. Unset it and run demo/run_bridge.sh to mint one.")
        if status != 200:
            raise RuntimeError(f"gateway logs: HTTP {status} {body[:200]}")
        page = json.loads(body).get("items") or []
        rows.extend(page)
        if len(page) < 500:
            break
        offset += 500
    rows.sort(key=lambda r: str(r.get("timestamp", "")))
    return rows


def fetch_llm_logs(since: datetime) -> list[dict]:
    """Every model call from `since` on, oldest first (Postgres fallback works without ClickHouse)."""
    rows: list[dict] = []
    offset = 0
    while True:
        q = urllib.parse.urlencode({"from": _iso(since), "limit": 500, "offset": offset})
        status, body = _http("GET", f"{GATEWAY_API}/analytics/llm-logs?{q}", token=ADMIN_KEY)
        if status != 200:
            print(f"  ! gateway llm-logs: HTTP {status} {body[:160]}", file=sys.stderr)
            return rows
        page = json.loads(body).get("items") or []
        rows.extend(page)
        if len(page) < 500:
            break
        offset += 500
    rows.sort(key=lambda r: str(r.get("timestamp", "")))
    return rows


def _approved(model: str) -> bool:
    return not APPROVED_MODELS or any(model.startswith(p) for p in APPROVED_MODELS)


def llm_to_aisoc(rows: list[dict], key_names: dict[str, str]) -> list[dict]:
    """LLM-log rows -> ai_runtime events (model calls made through the gateway)."""
    out = []
    for r in rows:
        key_id = str(r.get("key_id") or "")
        agent = key_names.get(key_id) or r.get("principal") or "unknown-agent"
        model = str(r.get("resolved_model") or r.get("model") or r.get("requested_model") or "")
        status = int(r.get("status_code") or 0)
        rid = str(r.get("request_id") or "")
        ev = {
            "timestamp": r.get("timestamp"),
            "external_id": f"gw-llm-{rid}",
            "request_id": rid,
            "event_type": "ai_model_call",
            "agent_id": agent,
            "agent_name": r.get("profile") or agent,
            "client_name": r.get("client_name") or "",
            "user_agent": r.get("user_agent") or "",
            "on_behalf_of": r.get("user") or "",
            "model": model,
            "provider": r.get("provider") or r.get("resolved_vendor") or "",
            "input_tokens": r.get("input_tokens"),
            "output_tokens": r.get("output_tokens"),
            "cost_usd": r.get("cost_usd"),
            "http_status": status,
            "outcome": "success" if 200 <= status < 300 else ("denied" if status in (401, 403) else "error"),
            "session_id": r.get("session_id") or "",
            "source_ip": r.get("client_ip") or "",
            "src_ip": r.get("client_ip") or "",
            "hostname": GATEWAY_HOST,
            "host": GATEWAY_HOST,
            "latency_ms": r.get("duration_ms"),
            "severity": "info",
        }
        if model and not _approved(model):
            ev["finding_type"] = "unapproved_model"
            ev["finding_reason"] = f"model {model} is not in APPROVED_MODELS ({', '.join(APPROVED_MODELS)})"
        out.append(ev)
    return out


def fetch_auth_failures(since: datetime) -> tuple[int, int, str]:
    """(failed auths, rate-limited, last timestamp) from the gateway container's own log."""
    try:
        cid = subprocess.run(
            ["docker", "compose", "-f", "deploy/docker-compose.yml", "ps", "-q", "gateway"],
            capture_output=True, text=True, timeout=20, check=False,
        ).stdout.strip()
        if not cid:
            return 0, 0, ""
        out = subprocess.run(
            ["docker", "logs", "--since", _iso(since), cid],
            capture_output=True, text=True, timeout=30, check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return 0, 0, ""
    failed = limited = 0
    last = ""
    for line in (out.stdout + out.stderr).splitlines():
        msg, ts = "", ""
        if line.startswith("{"):
            try:
                rec = json.loads(line)
                msg, ts = rec.get("msg", ""), rec.get("time", "")
            except ValueError:
                pass
        else:  # development mode: slog text handler
            m = re.search(r'msg="([^"]*)"', line)
            t = re.search(r"time=(\S+)", line)
            msg, ts = (m.group(1) if m else ""), (t.group(1) if t else "")
        if msg == "authentication failed":
            failed += 1
            last = ts or last
        elif msg == "authentication rate limited":
            limited += 1
            last = ts or last
    return failed, limited, last


# ------------------------------------------------------------------- mapping
def to_aisoc(rows: list[dict], key_names: dict[str, str], conn_names: dict[str, str]) -> list[dict]:
    """Access-log rows -> ai_runtime events (AiSOC's own rules turn refusals into alerts)."""
    runtime = []
    for r in rows:
        if r.get("method") not in ACTION_METHODS:
            continue
        key_id = str(r.get("key_id") or "")
        agent = key_names.get(key_id) or r.get("principal") or "unknown-agent"
        tool = str(r.get("tool_name") or "")
        server = conn_names.get(str(r.get("connector_id") or ""), tool.split("__", 1)[0] if "__" in tool else "")
        code = str(r.get("error_code") or "")
        status = int(r.get("status_code") or 0)
        if code in POLICY_DENIED or status in (401, 403):
            outcome = "denied"
        elif status == 200 and not code:
            outcome = "success"
        else:
            outcome = "error"
        rid = str(r.get("request_id") or "")
        base = {
            "timestamp": r.get("timestamp"),
            "external_id": f"gw-{rid}",
            "request_id": rid,
            "event_type": "ai_tool_call",
            "agent_id": agent,
            "agent_name": r.get("profile") or agent,
            "on_behalf_of": r.get("user") or "",
            "tool_name": tool,
            "server_name": server,
            "outcome": outcome,
            "jsonrpc_error_code": code,
            "http_status": status,
            "profile": r.get("profile") or "",
            "session_id": r.get("session_id") or "",
            "source_ip": r.get("client_ip") or "",
            "src_ip": r.get("client_ip") or "",
            "hostname": GATEWAY_HOST,
            "host": GATEWAY_HOST,
            "latency_ms": r.get("duration_ms"),
            "severity": "info",
        }
        runtime.append(base)
    return runtime


def auth_finding(failed: int, limited: int, last: str) -> dict | None:
    if not failed and not limited:
        return None
    when = last or _iso(datetime.now(UTC))
    locked = limited > 0
    return {
        "timestamp": when,
        "external_id": f"gw-auth-{when}",
        "finding_id": f"gw-auth-{when}",
        "finding_type": "gateway_auth_bruteforce" if locked else "gateway_auth_failures",
        "event_type": "authentication",
        "outcome": "failure",
        "title": (
            f"AI Agent Gateway locked out a client after repeated invalid API keys ({failed} failed, {limited} blocked)"
            if locked
            else f"{failed} requests with an invalid API key at the AI Agent Gateway"
        ),
        "description": (
            "Someone presented API keys the gateway does not know. "
            + ("Enough failures arrived to trip the gateway's brute-force lockout (HTTP 429)." if locked else "")
        ),
        "severity": "high" if locked else ("medium" if failed >= 5 else "low"),
        "mitre_technique": "T1110",
        "hostname": GATEWAY_HOST,
        "host": GATEWAY_HOST,
    }


# ---------------------------------------------------------------------- send
def send(connector_type: str, events: list[dict], *, dry_run: bool) -> bool:
    if not events:
        return True
    payload = {"connector_id": CONNECTOR_ID, "connector_type": connector_type, "source_format": "json", "events": events}
    if dry_run:
        print(json.dumps(payload, indent=2, default=str))
        return True
    for i in range(0, len(events), 200):
        chunk = dict(payload, events=events[i : i + 200])
        status, body = _http("POST", f"{AISOC_INGEST}/v1/ingest/batch", token=INGEST_TOKEN, body=chunk)
        if status != 200:
            print(f"  ! AiSOC ingest refused {connector_type}: HTTP {status} {body[:200]}", file=sys.stderr)
            return False
    return True


def _parse_since(s: str) -> timedelta:
    m = re.fullmatch(r"(\d+)([smh])", s)
    if not m:
        raise SystemExit("--since takes e.g. 90s, 30m or 2h")
    unit = {"s": "seconds", "m": "minutes", "h": "hours"}[m.group(2)]
    return timedelta(**{unit: int(m.group(1))})


def main() -> int:
    ap = argparse.ArgumentParser(description="Stream AI Agent Gateway activity into AiSOC.")
    ap.add_argument("--since", default="15m", help="how far back to start (default 15m)")
    ap.add_argument("--interval", type=float, default=10, help="seconds between polls (default 10)")
    ap.add_argument("--once", action="store_true", help="one pass, then exit")
    ap.add_argument("--dry-run", action="store_true", help="print what would be sent, send nothing")
    ap.add_argument("--no-docker-logs", action="store_true", help="skip the auth-failure source")
    args = ap.parse_args()

    if not ADMIN_KEY:
        print("GATEWAY_ADMIN_KEY is not set. Use demo/run_bridge.sh, or export it first.", file=sys.stderr)
        return 1
    if not INGEST_TOKEN and not args.dry_run:
        print("AISOC_INGEST_TOKEN is not set. Use demo/run_bridge.sh, which mints one.", file=sys.stderr)
        return 1

    since = datetime.now(UTC) - _parse_since(args.since)
    auth_since = since
    seen: deque[str] = deque(maxlen=20000)
    seen_set: set[str] = set()
    print(f"Bridge: gateway {GATEWAY_API}  ->  AiSOC {AISOC_INGEST}   (Ctrl+C to stop)")
    totals = {"runtime": 0, "findings": 0}

    while True:
        poll_started = datetime.now(UTC)
        key_names, conn_names = lookup_names()
        # Re-read a 60 s overlap: the access log is written in batches, so a row can
        # land after a later one was already read. request_id keeps it exactly-once.
        rows = [r for r in fetch_access_logs(since - timedelta(seconds=60)) if str(r.get("request_id")) not in seen_set]
        runtime = to_aisoc(rows, key_names, conn_names)
        llm_rows = [r for r in fetch_llm_logs(since - timedelta(seconds=60)) if f"llm-{r.get('request_id')}" not in seen_set]
        runtime += llm_to_aisoc(llm_rows, key_names)
        findings: list[dict] = []
        if not args.no_docker_logs:
            f = auth_finding(*fetch_auth_failures(auth_since))
            if f:
                findings.append(f)
            auth_since = poll_started

        ok = send("ai_runtime", runtime, dry_run=args.dry_run) and send("ai_guardrail", findings, dry_run=args.dry_run)
        if ok:
            for rid in [str(r.get("request_id")) for r in rows] + [f"llm-{r.get('request_id')}" for r in llm_rows]:
                if len(seen) == seen.maxlen:
                    seen_set.discard(seen[0])
                seen.append(rid)
                seen_set.add(rid)
            if rows or llm_rows:
                stamps = (_parse_ts(str(r.get("timestamp", ""))) for r in rows + llm_rows)
                latest = max(stamps, default=None, key=lambda t: t or since)
                since = max(since, latest or since)
            totals["runtime"] += len(runtime)
            totals["findings"] += len(findings)
            if runtime or findings:
                tools = [e for e in runtime if e["event_type"] == "ai_tool_call"]
                models = [e for e in runtime if e["event_type"] == "ai_model_call"]
                denied = sum(1 for e in tools if e["outcome"] == "denied")
                print(
                    f"{datetime.now().strftime('%H:%M:%S')}  sent {len(tools)} tool call(s) ({denied} refused), "
                    f"{len(models)} model call(s) and {len(findings)} finding(s) to AiSOC"
                )
                for e in models:
                    if e.get("finding_type") == "unapproved_model":
                        print(f"           [UNAPPROVED MODEL] {e['agent_id']} used {e['model']}")
                for f in findings:
                    print(f"           [{f['severity'].upper():6}] {f['title']}")
        if args.once:
            print(f"Done: {totals['runtime']} event(s), {totals['findings']} finding(s).")
            return 0 if ok else 1
        time.sleep(args.interval)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\nBridge stopped.")
