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
events go ingest → Kafka → detection rules → alerts in Postgres.

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

