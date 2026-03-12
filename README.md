# TriOnyx — What OpenClaw would be if security came first

A complete agent runtime that tracks what agents have *seen*, not just what they can *do*.

![Agent topology showing taint and sensitivity propagation](docs/agent-graph.png)

## The core problem

OpenClaw sandboxes **capability** — restrict filesystem access, disable shell, limit network. This misses the point. An LLM that has ingested a prompt injection is dangerous regardless of what tools it has. The real threat is **information**: what enters an agent's context, and where it flows next.

## What TriOnyx does

- **Isolated agent containers** — each agent runs in its own Docker container with a per-agent FUSE filesystem, network rules, and no shared state
- **Taint and sensitivity tracking** — two independent axes (Biba integrity, Bell-LaPadula confidentiality) that measure what each agent has been exposed to
- **Information flow enforcement** — the gateway intercepts all inter-agent communication and blocks flows that would violate integrity or confidentiality constraints
- **Auditable everything** — structured logs for file access, tool calls, message routing, and policy violations
- **Risk reduction, not elimination** — the security model makes attacks harder and detectable, not theoretically impossible

Built on Elixir/OTP. Designed for a single operator running their own agents.

---

## Quick start

### Prerequisites

- Docker

### Build

```bash
# Gateway image (Elixir/OTP)
docker build -f gateway.Dockerfile -t tri-onyx-gateway:latest .

# Agent runtime image (Python + FUSE sandbox)
docker build -f agent.Dockerfile -t tri-onyx-agent:latest .
```

The agent image requires a pre-built FUSE driver binary at `fuse/tri-onyx-fs`. See `fuse/README.md` for build instructions.

### Run

```bash
docker run --rm -p 4000:4000 \
  -v $(pwd):/app -w /app \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e TRI_ONYX_HOST_ROOT=$(pwd) \
  --env-file .env \
  tri-onyx-gateway:latest mix run --no-halt
```

`TRI_ONYX_HOST_ROOT` tells the gateway the real host path so that agent container bind mounts resolve correctly.

### Test

```bash
# Elixir gateway tests
docker run --rm -v $(pwd):/app -w /app tri-onyx-gateway:latest mix test

# Go FUSE driver tests
docker run --rm --device /dev/fuse --cap-add SYS_ADMIN \
  --security-opt apparmor=unconfined \
  -v $(pwd)/fuse:/src -w /src golang:1.22 go test ./...
```

---

## Agent definitions

Agents are defined as markdown files with YAML frontmatter in `workspace/agent-definitions/`:

```markdown
---
name: code-reviewer
description: Reviews code for quality, security, and style
model: claude-sonnet-4-20250514
tools: Read, Grep, Glob
network: none
fs_read:
  - /workspace/repo/src/**/*
  - /workspace/repo/tests/**/*
skills: code-review-standards, security-checklist
---

You are a code reviewer. Analyze the code at /workspace/repo/src and
provide feedback on quality, security issues, and style.
```

The frontmatter declares permissions (tools, filesystem access, network policy). The body is the system prompt. The gateway translates these into Docker container configuration, FUSE policy, and iptables rules.

### Skills

The `skills` field loads skill files into the agent's context at session start. Place skills in `workspace/.claude/skills/<skill-name>/SKILL.md`. When an agent declares a skill, the FUSE driver grants read access to that skill's directory. Undeclared skills are not readable.

---

## Architecture

```
                External Triggers
                (webhooks, chat, cron)
                        │
                        ▼
┌──────────────────────────────────────────┐
│          Elixir/OTP Gateway              │
│                                          │
│  • Agent lifecycle (supervision trees)   │
│  • Taint & sensitivity tracking           │
│  • Message interception & validation     │
│  • Risk scoring & violation detection    │
│  • Credential management (sole holder)   │
│  • Graph analysis (transitive risk)      │
│                                          │
│  Non-agentic. No LLM. No autonomy.      │
│  Deterministic security boundary.        │
└─────────┬──────────────┬─────────────────┘
          │              │
          ▼              ▼
┌─────────────┐  ┌─────────────┐
│ Agent A     │  │ Agent B     │
│             │  │             │
│ Python +    │  │ Python +    │
│ Claude SDK  │  │ Claude SDK  │
│             │  │             │
│ ┌─────────┐ │  │ ┌─────────┐ │
│ │FUSE     │ │  │ │FUSE     │ │
│ │Driver   │ │  │ │Driver   │ │
│ │(Go)     │ │  │ │(Go)     │ │
│ └─────────┘ │  │ └─────────┘ │
│ Docker      │  │ Docker      │
│ Container   │  │ Container   │
└─────────────┘  └─────────────┘
```

**Gateway (Elixir/OTP)** — Non-agentic control plane. Manages agent lifecycles, intercepts all inter-agent messages, tracks information exposure, computes risk scores, and enforces security policies.

**Agent Runtime (Python)** — Drives Claude sessions via the Claude Agent SDK inside Docker containers. Communicates with the gateway over JSON Lines on stdin/stdout.

**FUSE Driver (Go)** — Passthrough filesystem enforcing per-file read/write policies inside each container. Logs all access and denials as structured events.

---

## API

### Agents

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/agents` | List agents with risk scores |
| `GET` | `/agents/:name` | Agent detail with taint status |
| `POST` | `/agents/:name/start` | Start an agent session |
| `POST` | `/agents/:name/stop` | Stop an agent session |
| `POST` | `/agents/:name/prompt` | Send prompt to running agent |
| `GET` | `/agents/:name/events` | SSE stream of agent events |

### Triggers

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/hooks/:endpoint_id` | Authenticated webhook ingress (internet-facing) |
| `POST` | `/messages` | External message with Bearer token auth |

### Webhook endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/webhook-endpoints` | List webhook endpoints |
| `POST` | `/webhook-endpoints` | Create webhook endpoint |
| `GET` | `/webhook-endpoints/:id` | Webhook endpoint detail |
| `PUT` | `/webhook-endpoints/:id` | Update webhook endpoint |
| `DELETE` | `/webhook-endpoints/:id` | Delete webhook endpoint |
| `POST` | `/webhook-endpoints/:id/rotate-secret` | Rotate signing secret |

### BCP approvals

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/bcp/approvals` | List pending BCP approval items |
| `POST` | `/bcp/approvals/:id/approve` | Approve a pending BCP item |
| `POST` | `/bcp/approvals/:id/reject` | Reject a pending BCP item |

### Action approvals

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/actions/approvals` | List pending action approval items |
| `POST` | `/actions/approvals/:id/approve` | Approve a pending action |
| `POST` | `/actions/approvals/:id/reject` | Reject a pending action |

### Observability

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/graph/analysis` | Graph analysis with risk propagation |
| `GET` | `/api/matrix` | Classification matrix (taint, sensitivity, capability) |
| `GET` | `/audit?since=YYYY-MM-DD` | Query audit log |
| `GET` | `/logs` | List agents with session logs |
| `GET` | `/logs/:agent_name` | List sessions for an agent |
| `GET` | `/logs/:agent_name/:session_id` | Session log (JSONL) |
| `GET` | `/health` | Health check |

### Connectors

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/connectors/ws` | WebSocket upgrade for external connectors |
| `GET` | `/connectors` | List active connectors |

### Heartbeats

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/heartbeats` | List heartbeat schedules |
| `PUT` | `/heartbeats/enabled` | Enable/disable heartbeat scheduler |
| `POST` | `/heartbeats/:agent_name` | Schedule heartbeat for agent |
| `DELETE` | `/heartbeats/:agent_name` | Cancel heartbeat for agent |

### Human review

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/review` | Mark artifacts as human-reviewed (resets taint) |

---

## Project structure

```
lib/tri_onyx/           Elixir gateway (OTP application)
  agent_session.ex          Per-session GenServer (taint, risk, lifecycle)
  agent_port.ex             Elixir Port to Python subprocess
  agent_supervisor.ex       DynamicSupervisor for sessions
  sandbox.ex                Translates definitions into docker run args
  information_classifier.ex Taint/sensitivity classification from data sources
  risk_scorer.ex            Risk matrix computation
  graph_analyzer.ex         Transitive risk propagation and violation detection
  workspace.ex              Risk manifest, Git commits, human review
  tool_registry.ex          Tool metadata registry
  router.ex                 HTTP API (Plug/Bandit)
  event_bus.ex              Pub/sub for SSE streaming and connectors
  triggers/                 Webhook, message, inter-agent, scheduler

runtime/                  Python agent runtime
  agent_runner.py           Claude Agent SDK bridge (stdin/stdout JSON Lines)
  protocol.py               Message types and emitters
  entrypoint.sh             Container startup (FUSE mount, iptables, exec agent)

fuse/                     Go FUSE driver
  cmd/tri-onyx-fs/        CLI entry point
  internal/fs/              FUSE node implementation
  internal/policy/          JSON policy parser and glob expansion
  internal/pathtrie/        Path trie for O(1) access checks

connector/                Chat platform bridge (Python)
  connector/gateway_client.py  WebSocket connection to gateway
  connector/adapters/          Matrix, Slack, Discord adapters

workspace/agent-definitions/   Agent definitions (markdown + YAML frontmatter)
```

---

## Further reading

### Security model

- [Security Model](adr/SECURITY_MODEL.md) — Two-axis risk model, enforcement layers, violation detection
- [Bandwidth-Constrained Protocol](docs/bcp.md) — How tainted agents communicate with clean agents safely

### Architecture

- [Agent Runtime](docs/agent-runtime.md) — Agent execution lifecycle
- [Gateway-Runtime Protocol](docs/protocol.md) — JSON Lines protocol specification
- [FUSE Driver](docs/fuse-driver-spec.md) — Filesystem policy enforcement

### Guides

- [Webhook Receiver](docs/webhook-receiver-design.md) — Webhook ingress security model and Cloudflare Tunnel setup
- [Matrix Setup](docs/matrix-guide.md) — Chat connector configuration
- [Email Setup](docs/email-setup.md) — Email connector configuration
- [E2E Testing](docs/e2e-testing.md) — End-to-end test harness

### Architecture Decision Records

| ADR | Decision |
|-----|----------|
| [001](adr/001-information-is-the-threat.md) | Information is the threat, not capability |
| [002](adr/002-elixir-gateway.md) | Elixir/OTP for the gateway |
| [003](adr/003-python-agent-runtime.md) | Python for the agent runtime and connector |
| [004](adr/004-go-fuse-driver.md) | Go FUSE driver for filesystem policy enforcement |
| [005](adr/005-bandwidth-constrained-trust.md) | Bandwidth restriction as taint containment |
| [006](adr/006-gateway-credential-secrecy.md) | Gateway as sole credential holder with automatic sensitivity |
| [007](adr/007-biba-blp-violation-detection.md) | Independent Biba and Bell-LaPadula violation detection |
| [008](adr/008-risk-manifest-provenance.md) | Risk manifest for file-level provenance tracking |
| [009](adr/009-graph-analysis-transitive-risk.md) | Graph analysis for transitive risk propagation |
