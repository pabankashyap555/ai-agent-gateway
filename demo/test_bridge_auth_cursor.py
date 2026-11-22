"""C0.2 test: a failed send to AiSOC must not lose the failed-login finding.

What it does (no Docker, no gateway, no AiSOC needed):
  1. Pretends the gateway logged 3 failed logins just now.
  2. Pretends AiSOC is DOWN for the first send, then back UP.
  3. Runs two loops of the bridge.
  4. PASS if the failed-login finding reaches AiSOC on the second loop.

Run:  python3 demo/test_bridge_auth_cursor.py
"""
import os
import sys
from datetime import datetime, timedelta, timezone

os.environ.setdefault("GATEWAY_ADMIN_KEY", "gk_test")
os.environ.setdefault("AISOC_INGEST_TOKEN", "test")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gateway_to_aisoc as bridge  # noqa: E402

FAILED_LOGIN_TIME = datetime.now(timezone.utc) - timedelta(seconds=1)
delivered = []          # findings AiSOC actually received
aisoc_up = [False]      # AiSOC starts DOWN
loops = [0]


class StopTest(Exception):
    pass


def fake_auth_failures(since):
    # The gateway log has 3 failed logins at FAILED_LOGIN_TIME.
    # `docker logs --since X` only returns them if X is before that time.
    if since <= FAILED_LOGIN_TIME:
        return 3, 0, bridge._iso(FAILED_LOGIN_TIME)
    return 0, 0, ""


def fake_send(connector_type, events, *, dry_run):
    if not events:
        return True
    if not aisoc_up[0]:
        return False            # AiSOC is down: the send fails
    if connector_type == "ai_guardrail":
        delivered.extend(events)
    return True


def fake_sleep(_seconds):
    loops[0] += 1
    aisoc_up[0] = True          # AiSOC comes back after the first loop
    if loops[0] >= 2:
        raise StopTest


bridge.lookup_names = lambda: ({}, {})
bridge.fetch_access_logs = lambda since: []
bridge.fetch_llm_logs = lambda since: []
bridge.fetch_auth_failures = fake_auth_failures
bridge.send = fake_send
bridge.time.sleep = fake_sleep

sys.argv = ["gateway_to_aisoc.py", "--since", "5m", "--interval", "0"]
try:
    bridge.main()
except StopTest:
    pass

if delivered:
    print("PASS: the failed-login finding reached AiSOC after it came back up.")
    sys.exit(0)
print("FAIL: AiSOC was down for one loop and the failed-login finding was lost for good.")
sys.exit(1)