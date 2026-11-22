# Progress

> Honesty note: I built the Round 0 demo with AI help the integerstion.
> Claude helped me draft the C0.1 diagram and these notes to get a understanding of the architecture.
> I redrew the diagram by hand and checked every port and key against the scripts myself.

## C0.1 – Event path diagram

Diagram: docs/c0.1-event-path.jpg.jpeg

In short: Claude Code sends its work down three paths. Tool calls and model calls
go through the gateway, which checks the key and the allowed tools. Its own local
actions (Bash, file edits) go straight to AiSOC, because they never touch the gateway.
The bridge copies the gateway's logs into AiSOC every 10 seconds. Inside AiSOC,
events go ingest → Kafka → detect
ion rules → alerts in Postgres.

### Silent failures (circled on the diagram)

- **(3) Claude Code → AiSOC logs:** If AiSOC's log receiver is switched off,
  Claude Code's logs just disappear. Claude Code shows no error. This happened
  to me: every `make up` turned the receiver off again, and I only noticed
  because Hunt was empty.
  
- **(4) Bridge → gateway access logs:** If the gateway runs without its log
  database (light mode), the bridge gets a 404. It prints one warning, then
  keeps running and sends nothing for tool calls. AiSOC just looks quiet, as if
  nothing happened.

The gateway keeps its record of tool calls in a separate database (ClickHouse, the “analytics” part). To save memory, you can start the gateway without that database. That’s what “light mode” means.

In light mode, when the bridge asks for the tool-call record, the gateway answers “404 – not found”, meaning “I don’t have that page.”

What the bridge does with that answer
It prints one warning in its terminal, the first time only.
It then treats every later answer as “no tool calls”.
It keeps running happily and keeps sending model calls (those come from a different place, llm-logs, which still works).

So nothing crashes, nothing turns red, and the bridge looks healthy.


  
- **(8) Bridge → docker logs:** The AI gateways does not store the failed authentication logs anywhere other than its own local docker container. When the bridge is trying to fetch those logs and lets say for some
  reason the call was unsuccessful then the gateway does not return any error to the bridge.

### What I did
- Started from the hint in `setup_claude_code.sh`. The comment at the top shows the three paths.
- Checked each port and key in `run_bridge.sh`, `gateway_to_aisoc.py`,
  `claude-code.env` and AiSOC's `docker-compose.yml`.
- Drew it by hand, added the missing labels, and uploaded the photo.



## C0.3 – Three decisions I'd defend

> Honesty note: my demo was built with AI help, so "my demo uses" below means
> choices I ran and accepted, not code I wrote alone. The three ideas for
> production are mine; Claude helped me check them against the real design.
> None of the production changes are built yet.

**1. A polling bridge.** My demo uses a small Python bridge that polls the gateway
every 10 seconds and maps each log row into AiSOC's format, because the gateway
can't push logs and AiSOC has no gateway connector. It costs up to 10 seconds of
delay, one more script that can stop silently, mappings that break quietly if a
field is renamed, and the lost-event bugs from C0.2. In production I'd have the
gateway push events through OpenTelemetry into AiSOC, with a tested schema and a
durable queue. (Not built yet.)

**2. Storing prompt text.** My demo stores prompts in the gateway and sends
Claude Code's prompt text to AiSOC, because AiSOC can only alert on a secret if
the prompt is kept. It costs privacy: prompts, including any personal data, sit
in two places. Only known secret patterns are masked, only in the gateway's copy;
PII isn't masked, and the real secret still reaches the model. In production I'd
mask or block secrets and PII at the gateway before forwarding, turn prompt
logging off, and keep data briefly. (Not built yet.)

**3. An admin key for the bridge.** My demo gives the bridge a full gateway admin
key over plain HTTP, because it was the quickest key that could read logs. It
costs a lot if the bridge machine is hacked: the attacker could create keys and
change agent permissions, not just read logs. In production I'd give the bridge a
read-only role, keep a short-lived key in a secrets manager, and use mutual TLS
with a private CA that renews certificates automatically. (Not built yet.)