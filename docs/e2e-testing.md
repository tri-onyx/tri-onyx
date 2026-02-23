# End-to-End Testing Guide

This guide is written for an autonomous agent (Claude Code) debugging TriOnyx.
It explains how to drive agents through the full production path and what to look at
when something goes wrong.

## The test harness

`scripts/test-agent.py` emulates the Matrix connector. It connects to the gateway
over WebSocket using the same connector protocol the real Matrix adapter uses. From
the gateway's perspective there is no difference between the test harness and a live
Matrix room.

### Prerequisites

```bash
export TRI_ONYX_CONNECTOR_TOKEN=<token from gateway config>
export TRI_ONYX_GATEWAY=ws://localhost:4000   # default
```

The stack must be running. Start it with:

```bash
docker compose up -d
```

### Basic usage

```bash
# Single turn
uv run scripts/test-agent.py <agent-name> "<prompt>"

# Multi-turn with explicit BCP approval
uv run scripts/test-agent.py <agent-name> --turns '[
  {"type": "message", "content": "<prompt>"},
  {"type": "react",   "emoji":  "👍"}
]'

# Auto-approve all BCP Cat-3 requests
uv run scripts/test-agent.py <agent-name> "<prompt>" --auto-approve

# Lower-trust trigger (maps to :unverified_input in the gateway)
uv run scripts/test-agent.py <agent-name> "<prompt>" --trust unverified

# Extend timeout for slow agents (seconds)
uv run scripts/test-agent.py <agent-name> "<prompt>" --timeout 180
```

### Output format

Every frame the gateway sends back is printed as a JSON line (JSONL) to stdout.
Pipe through `jq .` for readable output, or `jq 'select(.type == "agent_text")'`
to filter to just the agent's words.

| Frame type      | Meaning |
|-----------------|---------|
| `agent_typing`  | Agent started or stopped thinking |
| `agent_step`    | A tool call (`step_type: tool_use`) or its result (`step_type: tool_result`) |
| `agent_text`    | Text chunk produced by the agent |
| `agent_result`  | Session complete — exit 0 |
| `agent_error`   | Runtime error — exit 1 |
| `approval_request` | Cat-3 BCP response needs human sign-off |
| `timeout`       | Harness gave up waiting |

### Exit codes

- `0` — agent finished normally (`agent_result` received)
- `1` — agent errored, timed out, or registration failed

---

## What the harness can and cannot see

The harness subscribes to the **triggering agent's** EventBus session only. This is
the same scope the real Matrix connector has.

**Visible to the harness:**

- Everything the triggered agent does: tool calls, tool results, text output, risk
  escalations
- `approval_request` frames — these are broadcast to **all registered connectors**,
  so the harness always receives them regardless of which agent triggered the BCP
  query
- The BCP tool result that arrives back to the triggered agent after approval

**Not visible to the harness:**

- Events from agents spawned as a side-effect (e.g. a `researcher` session started
  because `main` called `BCPQuery` or `SendMessage`). Those sessions are not
  triggered by the connector and their EventBus is never subscribed.
- Internal inter-agent message routing steps

To observe what a side-effect agent did, read its session log (see below).

---

## Multi-agent flow example

Flow: user → `main` → `researcher` (BCP Cat-3) → approval → `main` responds.

What the harness sees in order:

```
{"type":"agent_typing","is_typing":true,...}
{"type":"agent_step","step_type":"tool_use","name":"BCPQuery",...}
{"type":"approval_request","approval_id":"...","from_agent":"main","to_agent":"researcher","response_content":"...","anomalies":[...]}
  ← harness sends reaction 👍 here (--auto-approve or react turn)
{"type":"agent_step","step_type":"tool_result","name":"BCPQuery","content":"..."}
{"type":"agent_typing","is_typing":true,...}
{"type":"agent_text","content":"..."}
{"type":"agent_result",...}
```

Everything researcher did internally (its tool calls, what it read) is not in this
stream. Read researcher's session log to diagnose researcher-side failures.

---

## Session logs

The gateway writes a JSONL log for every session:

```
logs/<agent-name>/<session-id>.jsonl
```

Each line is a timestamped JSON event — every tool call, tool result, text output,
risk escalation, and session start/stop.

### Finding the right log

The harness prints the `session_id` inside every frame (`"session_id": "abc123"`).
To find a side-effect agent's session (e.g. researcher), list its log directory:

```bash
ls -lt logs/researcher/    # most recent first
```

### Reading a log

```bash
# Pretty-print the whole session
cat logs/main/abc123.jsonl | jq .

# Just tool calls and results
cat logs/main/abc123.jsonl | jq 'select(.type == "tool_use" or .type == "tool_result")'

# FUSE write events (filesystem access)
cat logs/main/abc123.jsonl | jq 'select(.type == "fuse_write")'

# Risk escalations only
cat logs/main/abc123.jsonl | jq 'select(.type == "risk_escalation")'

# Session summary (first and last events)
head -1 logs/main/abc123.jsonl | jq .
tail -1 logs/main/abc123.jsonl | jq .
```

The log also exists via HTTP if the gateway is running:

```bash
curl -s http://localhost:4000/logs/main/abc123 | jq .
```

---

## Docker Compose logs

Session logs capture what the gateway observed. Docker Compose logs capture
everything the individual containers printed — including Python runtime output,
FUSE driver messages, and container startup errors that never make it into the
session log.

### Viewing logs

```bash
# All services, last 100 lines, follow
docker compose logs -f --tail=100

# Gateway only (Elixir — routing, taint, risk scoring, session lifecycle)
docker compose logs -f gateway

# Agent container (Python runtime, FUSE mount, Claude SDK)
# Agent containers are ephemeral — use --tail to catch recent output
docker compose logs --tail=200 agent

# Connector (Matrix adapter, WebSocket client)
docker compose logs -f connector
```

### What to look for

**Gateway logs** — search for the session ID printed by the harness:

```bash
docker compose logs gateway 2>&1 | grep abc123
```

Look for:
- `AgentSession starting` / `AgentSession stopped` — lifecycle events
- `port_spawn_failed` — Docker failed to start the agent container
- `risk_escalation` — taint or secrecy level was elevated
- `violation` — Biba/Bell-LaPadula policy was breached and session was killed
- `BCP.Channel` lines — query routing and validation

**Agent container logs** — the Python runtime and FUSE driver:

```bash
docker compose logs agent 2>&1 | tail -200
```

Look for:
- `FUSE: deny` — a file operation was blocked by the policy trie. The log line
  includes the denied path and operation. This is the first thing to check when
  an agent reports it cannot read or write a file.
- `FUSE: allow` — the operation was permitted (useful to confirm policy is working
  as intended)
- `RuntimeError` / `Exception` — Python-side crash in the agent runner
- `tool_use` / `tool_result` lines — the Python runner echoes each tool invocation

**Connector logs:**

```bash
docker compose logs connector 2>&1 | tail -100
```

Look for Matrix sync errors, WebSocket reconnect loops, or decryption failures if
E2E encryption is in use.

---

## Diagnosing common failures

### Agent produces no output / times out

1. Check `docker compose logs gateway` for `port_spawn_failed` — the agent
   container may not have started.
2. Check `docker compose logs agent` for Python import errors or FUSE mount
   failures at startup.
3. Check whether the ANTHROPIC_API_KEY env var is set in the agent container.

### Agent cannot read or write a file

1. Look for `FUSE: deny` in `docker compose logs agent`. The log line shows the
   exact path and operation that was blocked.
2. Check the agent definition (`workspace/agent-definitions/<name>.md`) — the
   `fs_read` and `fs_write` frontmatter fields control what the FUSE policy
   allows.
3. Check `Sandbox.build_fuse_policy/1` in `lib/tri_onyx/sandbox.ex` — this is
   where the policy is assembled from the definition. Every agent automatically
   gets `/agents/<name>/**` as a writable path for its memory files.
4. After changing the definition or sandbox code, rebuild the agent image:
   ```bash
   docker run --rm -v $(pwd)/fuse:/src -w /src golang:1.22 go build -o tri-onyx-fs ./cmd/tri-onyx-fs
   docker build --no-cache -t tri-onyx-agent:latest -f agent.Dockerfile .
   ```

### BCP approval request never arrives

1. Confirm the researcher's response actually reached Cat-3 validation — check
   `docker compose logs gateway` for `BCP.Channel: Cat-3` log lines.
2. Check `ApprovalQueue` state via HTTP: `curl http://localhost:4000/bcp/approvals`
3. If `approval_request` was sent but the harness missed it, the harness may have
   connected after the broadcast. Restart the test.

### Risk escalation kills the session

The session log will contain a `risk_escalation` event followed by `session_stop`.
Read the escalation event to see which tool result or trigger caused the elevation:

```bash
cat logs/main/abc123.jsonl | jq 'select(.type == "risk_escalation" or .type == "session_stop")'
```

Cross-reference with `lib/tri_onyx/information_classifier.ex` to understand
why that tool result was classified at that level.
