# Interview demo: AiSOC + AI Agent Gateway attack simulations

Two open-source tools, one laptop, two attack simulations:

| Tool | What it is | What the simulation shows |
|---|---|---|
| **AiSOC** (`beenuar/AiSOC`) | AI Security Operations Center: ingests telemetry, runs detection rules, correlates alerts, AI triage | A 7-stage intrusion ("Operation Paper Trail") going in as raw logs and coming out as **11 rule-based detections**, mapped to MITRE ATT&CK, with a benign event that correctly stays quiet |
| **AI Agent Gateway** (`Tuskira/ai-agent-gateway`) | One authenticated, logged choke point between AI agents and their tools (MCP) and models | A "rogue agent" trying 9 attacks (stolen key, prompt-injected tool call, profile spoofing, SSRF to cloud metadata, brute force). **12 controls hold**, plus one real misconfiguration shown and fixed |

Everything runs locally. No real attacks are executed: the AiSOC simulation sends *log events that describe* an attack (made-up hosts, documentation IP ranges), and the gateway simulation only talks to the gateway and a local reference tool server.

---

## 1. Requirements

- **Docker Desktop** (macOS/Windows) or Docker Engine + Compose v2.24+ (Linux). In Docker Desktop → Settings → Resources, give Docker **at least 10 GB memory** (12 GB if you can) and make sure 25 GB of disk is free.
- `git`, `python3` (3.9+), `make`, `curl`, `jq`, and **Node.js** (for `npx`).
  - macOS: `brew install jq node` (git, make, python3, curl come with Xcode tools: `xcode-select --install`)
  - Windows: use **WSL2 (Ubuntu)** and run everything inside it: `sudo apt install -y make jq python3 nodejs npm curl git`
- RAM guide: AiSOC core ≈ 8 GB, gateway ≈ 1–2 GB (≈ 4 GB with the analytics profile). **16 GB laptop: run both together. 8 GB laptop: run one at a time** (`make down` in AiSOC before starting the gateway).

## 2. Install AiSOC (≈ 15–25 min the first time)

```bash
git clone https://github.com/pabankashyap555/AiSOC.git
cd AiSOC
make up
```

`make up` generates all secrets, starts 16 containers, downloads a ~2 GB local AI model, creates an admin and **prints the admin password once. Copy it somewhere.** (Lost it? `make bootstrap ARGS=--reset-password`.)

Check it works:

```bash
make doctor     # health of every service
make smoke      # pushes one real event through the pipeline: expect "PASS: 10/10 stages"
```

Console: **http://localhost:3000**. Sign in with `admin` and the printed password.

### 2b. Laptop with 8 GB RAM? Run AiSOC in GitHub Codespaces instead

AiSOC's repo ships a Codespaces setup that automatically picks a 4-core / 16 GB cloud machine. A free GitHub account includes 120 core-hours a month, which is about 30 hours on that machine. The default spending limit is $0, so it stops rather than charges you.

1. Open https://github.com/pabankashyap555/AiSOC, click the green **Code** button, then the **Codespaces** tab, then **Create codespace on main**. It opens VS Code in your browser (first start takes a few minutes).
2. In its terminal (bottom panel) run `make up`. Save the admin password it prints.
3. Run `make smoke` and expect `PASS: 10/10 stages`.
4. Open the **Ports** tab (next to Terminal), find port **3000**, and click the globe icon to open the console.
5. Run the simulation in the same terminal: `./demo/run_attack_sim.sh --pause 20`
6. **Stop the codespace when you finish** so it doesn't use up your hours: github.com/codespaces, then `...` next to it, then **Stop codespace**. It also stops by itself after 30 minutes idle. Stopping keeps everything; next time click it to resume and run `make up` again (fast, as the images are already downloaded).

The gateway still runs on your laptop (it needs only 1–2 GB): follow section 3 inside your WSL Ubuntu terminal.

## 3. Install the AI Agent Gateway (≈ 5 min)

```bash
git clone https://github.com/pabankashyap555/ai-agent-gateway.git
cd ai-agent-gateway
GATEWAY_SINKS_CLICKHOUSE_ENABLED=true \
  docker compose -f deploy/docker-compose.yml -f demo/docker-compose.demo-ports.yml --profile analytics up --build -d
until curl -sf localhost:18081/api/v1/health >/dev/null; do sleep 2; done && echo "gateway up"
```

`demo/docker-compose.demo-ports.yml` moves the gateway to **18080/18081/18082** because AiSOC already uses 8080, 8081 and 8090. (On an 8 GB laptop, drop the `GATEWAY_SINKS_CLICKHOUSE_ENABLED=true` and `--profile analytics` parts; you lose only the access-log step.)

Create a console user (prints a one-time password you change on first login):

```bash
docker compose -f deploy/docker-compose.yml -f demo/docker-compose.demo-ports.yml \
  exec gateway /gateway create-user -tenant default -username admin -role admin
```

Console: **http://localhost:18081**

## 4. Run the simulations

**AiSOC** (from the AiSOC folder):

```bash
./demo/run_attack_sim.sh               # quick run, ~2 min including waiting for detections
./demo/run_attack_sim.sh --pause 20    # slower, one stage every 20 s, for presenting
```

Then in the console: **Alerts** (the detections, each naming its rule and ATT&CK technique), **Incidents** (alerts grouped by host/user), click an alert → the **Investigation Rail** shows the local AI model's triage verdict and its reasoning in the Investigation Ledger.

If, on the day, a rule does not fire, `./demo/run_attack_sim.sh --findings` sends the same story as vendor findings, which AiSOC always turns into alerts.

Bonus, no Docker needed: `cd services/purple-team && python3 -m app.adversary.canned` runs AiSOC's built-in adversary-emulation campaign and prints a detection scoreboard and auto-filed detection-gap proposals. (It is a scripted offline demo with a canned detection oracle, so present it as "how the purple-team feature works", not as a live result.)

**Gateway** (from the ai-agent-gateway folder):

```bash
./demo/attack_sim.sh            # all 9 attacks, ~1 min
./demo/attack_sim.sh --pause    # press Enter between attacks, for presenting
```

Step 9 (brute force) deliberately locks your IP out of the MCP plane for 30 s. Run it last, or use `--skip-lockout`.

Then in the console: **Access Logs** (every attempt with key, tool, profile and result), **API Keys** (support-bot bound to its profile), **Profiles**.

## 5. What each simulation step proves (talk track)

### AiSOC: Operation Paper Trail

One attacker (203.0.113.66) compromises `p.nguyen` and walks a finance workstation all the way to ransomware staging.

| # | Stage | ATT&CK | Detection that fires |
|---|---|---|---|
| 1 | Password spray across 3 accounts, brute force on one, then a successful login (Okta) | T1110, T1110.003 | `wd-password-spray`, `wd-bruteforce-auth`: **windowed** rules. 13 individual login events, but the alerts are the *pattern*, not 13 tickets |
| 2 | Word macro launches hidden, encoded PowerShell with `-exec bypass` | T1059.001, T1027 | `det-endpoint-005` |
| 3 | `certutil` downloads and decodes a second stage | T1105, T1140, T1218 | `det-endpoint-001`, `-086`, `-087` |
| 4 | Mimikatz `sekurlsa::logonpasswords` | T1003 | `det-endpoint-093` |
| 5 | PsExec to the HR server | T1021.002 | `det-endpoint-111` |
| 6 | `rclone` copies the finance share to cloud storage | T1567.002 | `det-data-exfil-003` |
| 7 | `vssadmin delete shadows` (ransomware precursor) | T1490 | `det-endpoint-012`, `-075` |
| 8 | Benign control: an admin runs `Get-Process` | none | Nothing fires, which is correct |

Points worth making:
- Stages 2–7 arrive as **raw process telemetry**, a connector type AiSOC does not alert on by itself, so every alert you see was produced by AiSOC's own detection engine reading the command line. That's real detection, not "the event said severity: high".
- The benign control matters as much as the hits. Alert fatigue is the SOC's real enemy.
- The AI triage runs on a **local** model (Ollama, llama3.2 3B). No data leaves the laptop, and every prompt and tool call is in the Investigation Ledger, so the AI's reasoning is auditable.
- Honest limits: it's a 3B CPU model, so triage is slow-ish and not frontier-quality; the rule library is large but "executable" means "reachable", not "proven against every variant".

### AI Agent Gateway: Rogue Agent

Setup: a tool server (the official MCP reference server, which includes a dangerous `get-env` tool), a **support-bot** agent bound to a profile that allows only `echo` and `get-sum`, an **ops-admin** profile with everything, and a **legacy-agent** key that someone forgot to bind.

| # | Attack | Expected result | Why it matters |
|---|---|---|---|
| 1 | Call the MCP plane with no key | 401 | Every agent request is authenticated |
| 2 | Forged key | 401 | |
| 3 | Stolen agent key tries to mint an admin key / read connectors | 403, 403 | Agent role ≠ admin role: a leaked agent key can't escalate |
| 4 | Prompt-injected agent calls `get-env` | JSON-RPC -32003 | Tool scoping is enforced on **every call**, not just hidden from the list. This is the core defence against prompt injection turning into data theft |
| 5 | Agent sends `X-Agent-Profile-Name: ops-admin` | -32003 | A bound key can't pick a stronger profile |
| 6 | **Unbound** legacy key, no profile header → `get-env` **succeeds**. Then bind the key → blocked immediately | ALLOWED, then -32003 | A real finding: scoping is opt-in by default (`mcp.require_profile=false`). Recommend binding every agent key and turning on `require_profile` |
| 7 | Register a "tool server" at cloud metadata (`169.254.169.254`, in 3 spellings) and an internal IP | 400 `egress_blocked` | SSRF protection: the gateway can't be used to steal cloud credentials or pivot inside the network |
| 8 | Audit trail | Access-log rows for every attempt | Who did what, with which key and profile, and what was refused |
| 9 | 12 random keys in a row | 401 ×10, then 429 | Brute-force lockout per IP, per plane |

Step 6 is the one to dwell on. It shows you didn't just run a script that prints green: you found where the default configuration leaves a gap, explained the risk, and fixed it.

## 6. A 10-minute demo plan

1. **(1 min)** Architecture in one sentence each. AiSOC: logs → rules → correlation → AI triage → human-approved response. Gateway: agents → gateway (auth, scope, log) → tools/models.
2. **(4 min)** AiSOC: `./demo/run_attack_sim.sh --pause 20`, narrating each stage from the table. Then open the console: Alerts, an Incident, an AI verdict.
3. **(4 min)** Gateway: `./demo/attack_sim.sh --pause`, narrating each attack. Spend a minute on step 6. Then show Access Logs.
4. **(1 min)** Close: how the two fit together. The gateway's access logs are exactly the kind of telemetry AiSOC should ingest: an agent being refused a tool 50 times is an incident. A natural next step is a connector that ships gateway logs into AiSOC.

## 7. Rehearsal checklist (before Wednesday)

- [ ] Both stacks start cleanly from cold (`make down` / `docker compose ... down`, then up again)
- [ ] `make smoke` passes
- [ ] Both simulations run end to end at least twice
- [ ] Screenshots of: AiSOC alerts list, one AI verdict, gateway access logs, gateway script summary (fallback if the live demo fails)
- [ ] Optional: screen-record one full run (macOS: Cmd+Shift+5)
- [ ] On the day: start both stacks **30 minutes early**, since the first AiSOC triage can be slow while the model warms up

## 8. Troubleshooting

| Symptom | Fix |
|---|---|
| `make up` fails or a container keeps restarting | `make doctor` names the cause. Usually Docker memory is too low: raise it in Docker Desktop → Resources |
| Port already in use | AiSOC moves its own ports automatically. For the gateway, check nothing else is on 18080–18082 |
| `!override` error from compose | Update Docker Desktop (needs Compose v2.24+) |
| AiSOC script: alerts don't appear | Wait a minute and check the console. Then `docker compose logs fusion --tail 50`. Fallback: `--findings` |
| Gateway step 0 hangs at "starting the MCP reference tool server" | First run downloads it via npx. Check `demo/.toolserver.log` |
| Gateway step 8 shows HTTP 404 | Started without the analytics profile. Restart with the command in section 3 |
| Gateway calls return 429 | You're in the 30 s brute-force lockout from step 9. Wait it out |
| Stop everything | AiSOC: `make down`. Gateway: `docker compose -f deploy/docker-compose.yml -f demo/docker-compose.demo-ports.yml --profile analytics down` and `kill $(cat demo/.toolserver.pid)` |
