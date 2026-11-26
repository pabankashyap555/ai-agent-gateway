"""C0.2 test (bug 2): a failed send to AiSOC must not lose the secret-in-prompt flag.

What it does (no Docker, no gateway, no AiSOC needed):
  1. Pretends the gateway logged one model call whose stored prompt had an AWS key redacted.
  2. Pretends AiSOC is DOWN for the first send, then back UP.
  3. Runs two loops of the bridge.
  4. PASS if the model call that reaches AiSOC on loop 2 still carries prompt_secret_kinds.

Run:  python3 demo/test_bridge_secret_flag.py
"""
import os
import sys
from datetime import datetime, timedelta, timezone

os.environ.setdefault("GATEWAY_ADMIN_KEY", "gk_test")
os.environ.setdefault("AISOC_INGEST_TOKEN", "test")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gateway_to_aisoc as bridge  # noqa: E402

CALL_TIME = datetime.now(timezone.utc) - timedelta(seconds=1)
MODEL_CALL = {
    "request_id": "r1",
    "session_id": "s1",
    "timestamp": bridge._iso(CALL_TIME),
    "model": "claude-sonnet",
    "status_code": 200,
}
delivered = []          # model-call events AiSOC actually received
aisoc_up = [False]      # AiSOC starts DOWN
loops = [0]


class StopTest(Exception):
    pass


def fake_llm_logs(since):
    # The gateway's LLM log holds one model call; it is returned while the window covers it.
    return [dict(MODEL_CALL)] if since <= CALL_TIME else []


def fake_redacted_kinds(request_id):
    # The gateway replaced an AWS key in that call's stored prompt with [REDACTED:aws_key_id].
    return ["aws_key_id"] if request_id == "r1" else []


def fake_send(connector_type, events, *, dry_run):
    if not events:
        return True
    if not aisoc_up[0]:
        return False            # AiSOC is down: the send fails
    if connector_type == "ai_runtime":
        delivered.extend(e for e in events if e.get("event_type") == "ai_model_call")
    return True


def fake_sleep(_seconds):
    loops[0] += 1
    aisoc_up[0] = True          # AiSOC comes back after the first loop
    if loops[0] >= 2:
        raise StopTest


bridge.lookup_names = lambda: ({}, {})
bridge.fetch_access_logs = lambda since: []
bridge.fetch_llm_logs = fake_llm_logs
bridge.redacted_kinds = fake_redacted_kinds
bridge.send = fake_send
bridge.time.sleep = fake_sleep

sys.argv = ["gateway_to_aisoc.py", "--since", "5m", "--interval", "0", "--no-docker-logs"]
try:
    bridge.main()
except StopTest:
    pass

flagged = [e for e in delivered if e.get("prompt_secret_kinds")]
if flagged:
    print("PASS: the model call reached AiSOC with its secret flag after AiSOC came back up.")
    sys.exit(0)
if delivered:
    print("FAIL: the model call reached AiSOC, but its secret flag was lost on the retry.")
else:
    print("FAIL: the model call never reached AiSOC.")
sys.exit(1)