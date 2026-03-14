# TriOnyx — What OpenClaw would be if security came first

A complete agent runtime that tracks what agents have *seen*, not just what they can *do*.

![Agent topology showing taint and sensitivity propagation](docs/agent-graph.png)

## The core problem

OpenClaw sandboxes **capability** — restrict filesystem access, disable shell, limit network. This misses the point. An LLM that has ingested a prompt injection is dangerous regardless of what tools it has. The real threat is **information**: what enters an agent's context, and where it flows next.

## What TriOnyx does

- **Isolated agent containers** — each agent runs in its own Docker container with a per-agent FUSE filesystem, network rules, and no shared state
- **Taint and sensitivity tracking** — two independent axes (Biba integrity, Bell-LaPadula confidentiality) that measure what each agent has been exposed to
- **Information flow enforcement** — the gateway intercepts all inter-agent communication and blocks flows that would violate integrity or confidentiality constraints
- **Bandwidth-Constrained Protocol** — tainted agents can communicate with clean agents through structured, human-approvable message formats
- **Browser sessions** — agents can get a headless Chromium browser with persistent login sessions from the host
- **Plugin system** — reusable agent extensions (news aggregation, bookmarks, diary, etc.) installable from git repos
- **Web dashboard** — real-time agent topology graph, classification matrix, and log viewer
- **Auditable everything** — structured logs for file access, tool calls, message routing, and policy violations
- **Risk reduction, not elimination** — the security model makes attacks harder and detectable, not theoretically impossible

Built on Elixir/OTP. Designed for a single operator running their own agents.

See [how TriOnyx compares to OpenClaw](comparison-table.md) for a detailed side-by-side.

---

**New here?** Start with the [Getting Started guide](docs/getting-started.md) for a complete walkthrough from clone to running agents.

## Quick start

### Prerequisites

- Docker

### Build

```bash
# Gateway image (Elixir/OTP)
docker build -f gateway.Dockerfile -t tri-onyx-gateway:latest .

# Agent runtime image (Python + FUSE sandbox)
docker build -f agent.Dockerfile -t tri-onyx-agent:latest .

# Connector image (Python, for Matrix chat bridge)
docker build -f connector.Dockerfile -t connector:latest .
```

The agent image requires a pre-built FUSE driver binary at `fuse/tri-onyx-fs`. See `fuse/README.md` for build instructions.

### Run

```bash
docker compose up
```

Or run the gateway standalone:

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
  -v $(pwd)/fuse:/src -w /src golang:1.22 \
  bash -c "apt-get update -qq && apt-get install -y -qq fuse3 2>/dev/null && go test ./..."

# Python connector tests
docker run --rm -v $(pwd)/connector:/app -w /app connector:latest uv run pytest
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
browser: false
---

You are a code reviewer. Analyze the code at /workspace/repo/src and
provide feedback on quality, security issues, and style.
```

The frontmatter declares permissions (tools, filesystem access, network policy, browser access). The body is the system prompt. The gateway translates these into Docker container configuration, FUSE policy, and iptables rules.

### Skills

The `skills` field loads skill files into the agent's context at session start. Place skills in `workspace/.claude/skills/<skill-name>/SKILL.md`. When an agent declares a skill, the FUSE driver grants read access to that skill's directory. Undeclared skills are not readable.

### Plugins

Plugins are reusable agent extensions that live in `workspace/plugins/`. Each plugin is a directory of files that agents can read/write via FUSE paths like `/plugins/<name>/**`.

```bash
uv run scripts/tri-onyx-plugin.py add <git-url> [--name NAME] [--ref TAG/BRANCH]
uv run scripts/tri-onyx-plugin.py upgrade <name>
uv run scripts/tri-onyx-plugin.py remove <name>
uv run scripts/tri-onyx-plugin.py list
```

See [Plugins](docs/plugins.md) for details.

---

## Architecture

```
                External Triggers
                (webhooks, chat, cron, email)
                        |
                        v
+------------------------------------------+
|          Elixir/OTP Gateway              |
|                                          |
|  * Agent lifecycle (supervision trees)   |
|  * Taint & sensitivity tracking          |
|  * Message interception & validation     |
|  * Risk scoring & violation detection    |
|  * Credential management (sole holder)   |
|  * Graph analysis (transitive risk)      |
|  * BCP approval queue                    |
|  * Webhook receiver & routing            |
|  * Cron scheduler & heartbeats           |
|                                          |
|  Non-agentic. No LLM. No autonomy.      |
|  Deterministic security boundary.        |
+---------+--------------+-----------------+
          |              |
          v              v
+-------------+  +-------------+       +-------------+
| Agent A     |  | Agent B     |       | Connector   |
|             |  |             |       | (Python)    |
| Python +    |  | Python +    |       |             |
| Claude SDK  |  | Claude SDK  |       | Matrix      |
|             |  |             |       | adapter     |
| +---------+ |  | +---------+ |       +-------------+
| |FUSE     | |  | |FUSE     | |
| |Driver   | |  | |Driver   | |
| |(Go)     | |  | |(Go)     | |
| +---------+ |  | +---------+ |
| Docker      |  | Docker      |
| Container   |  | Container   |
+-------------+  +-------------+
```

**Gateway (Elixir/OTP)** — Non-agentic control plane. Manages agent lifecycles, intercepts all inter-agent messages, tracks information exposure, computes risk scores, enforces security policies, and routes webhooks, emails, and scheduled triggers.

**Agent Runtime (Python)** — Drives Claude sessions via the Claude Agent SDK inside Docker containers. Communicates with the gateway over JSON Lines on stdin/stdout. Optionally runs a headless browser for web interaction.

**FUSE Driver (Go)** — Passthrough filesystem enforcing per-file read/write policies inside each container. Logs all access and denials as structured events.

**Connector (Python)** — Bridges the gateway to chat platforms via WebSocket. Currently supports Matrix.

**Web Dashboard** — Static HTML frontends served by the gateway for monitoring agent topology, classification matrices, and session logs.

---

## Web UI

The gateway serves a web dashboard at `http://localhost:4000` with several views:

- **Frontend** (`/`) — Agent overview and control panel
- **Graph** (`/graph`) — Real-time agent topology with taint/sensitivity propagation visualization
- **Matrix** (`/matrix`) — Classification matrix showing taint, sensitivity, and capability levels
- **Log Viewer** (`/logs`) — Session log browser with structured event display

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
lib/tri_onyx/               Elixir gateway (OTP application)
  application.ex                OTP application supervisor
  router.ex                     HTTP API (Plug/Bandit)
  agent_session.ex              Per-session GenServer (taint, risk, lifecycle)
  agent_port.ex                 Elixir Port to Python subprocess
  agent_supervisor.ex           DynamicSupervisor for sessions
  agent_loader.ex               Loads agent definitions from disk
  definition_watcher.ex         Watches for definition file changes
  sandbox.ex                    Translates definitions into docker run args
  information_classifier.ex     Taint/sensitivity classification from data sources
  risk_scorer.ex                Risk matrix computation
  graph_analyzer.ex             Transitive risk propagation and violation detection
  taint_matrix.ex               Taint state per agent
  sensitivity_matrix.ex         Sensitivity state per agent
  sanitizer.ex                  Input/output sanitization
  workspace.ex                  Risk manifest, Git commits, human review
  tool_registry.ex              Tool metadata registry
  event_bus.ex                  Pub/sub for SSE streaming and connectors
  connector_handler.ex          WebSocket handler for connectors
  session_logger.ex             Structured session logging
  audit_log.ex                  Audit log persistence
  git_provenance.ex             Git-based file provenance tracking
  action_approval_queue.ex      Human-in-the-loop action approvals
  webhook_receiver.ex           Incoming webhook processing
  webhook_endpoint.ex           Webhook endpoint CRUD
  webhook_registry.ex           Webhook endpoint storage
  webhook_signature.ex          HMAC signature verification
  webhook_rate_limiter.ex       Per-endpoint rate limiting
  trigger_router.ex             Routes triggers to target agents
  bcp/                          Bandwidth-Constrained Protocol
    approval_queue.ex               Human approval queue for BCP messages
    bandwidth.ex                    Bandwidth level computation
    channel.ex                      BCP channel management
    escalation.ex                   Escalation handling
    query.ex                        Structured query format
    validator.ex                    BCP message validation
  connectors/                   Built-in connectors (Elixir side)
    email.ex                        IMAP/SMTP email connector
    calendar.ex                     CalDAV calendar connector
  triggers/                     Trigger subsystem
    webhook.ex                      Webhook trigger handler
    external_message.ex             External message trigger
    inter_agent.ex                  Inter-agent message trigger
    cron_scheduler.ex               Cron-based scheduling
    scheduler.ex                    Heartbeat scheduler
  workspace/
    prompt_assembler.ex             Assembles agent prompts from definitions + skills

runtime/                      Python agent runtime (bind-mounted into containers)
  agent_runner.py               Claude Agent SDK bridge (stdin/stdout JSON Lines)
  protocol.py                   Message types and emitters
  entrypoint.sh                 Container startup (FUSE mount, iptables, exec agent)
  browser-stealth.js            Headless browser anti-detection patches

fuse/                         Go FUSE driver
  cmd/tri-onyx-fs/              CLI entry point
  internal/fs/                  FUSE node implementation
  internal/policy/              JSON policy parser and glob expansion
  internal/pathtrie/            Path trie for O(1) access checks

connector/                    Chat platform bridge (Python)
  connector/main.py             Connector entry point
  connector/gateway_client.py   WebSocket connection to gateway
  connector/protocol.py         Connector-gateway message protocol
  connector/config.py           Configuration loading
  connector/formatting.py       Message formatting and chunking
  connector/transcriber.py      Conversation transcription
  connector/adapters/           Platform adapters
    base.py                         Abstract adapter interface
    matrix.py                       Matrix (Element) adapter

webgui/                       Web dashboard (static HTML)
  frontend.html                 Agent overview and control panel
  graph.html                    Agent topology visualization
  matrix.html                   Classification matrix view
  log-viewer.html               Session log browser

scripts/                      Utility scripts
  test-agent.py                 End-to-end test harness
  screenshot.py                 Page screenshot tool (Playwright)
  tri-onyx-plugin.py            Plugin management CLI
  explain-risk.py               Risk score explainer
  log-viewer.py                 CLI log viewer
  generate-templates.py         Generate .env.example, connector config, workspace templates
  install-hooks.sh              Install pre-commit hooks (secret leak prevention)
  safe-push.sh                  Pre-push safety checks

workspace/agent-definitions/  Agent definitions (markdown + YAML frontmatter)
workspace/plugins/            Installed plugins (newsagg, bookmarks, diary, etc.)
```

---

## Further reading

### Security model

- [Security Model](adr/SECURITY_MODEL.md) — Three-axis risk model (taint, sensitivity, capability), enforcement layers, violation detection
- [Architecture](adr/ARCHITECTURE.md) — System architecture overview
- [Bandwidth-Constrained Protocol](docs/bcp.md) — How tainted agents communicate with clean agents safely

### Agent runtime

- [Agent Runtime](docs/agent-runtime.md) — Agent execution lifecycle
- [Gateway-Runtime Protocol](docs/protocol.md) — JSON Lines protocol specification
- [FUSE Driver](docs/fuse-driver-spec.md) — Filesystem policy enforcement
- [Browser Sessions](docs/browser-sessions.md) — Persistent browser sessions for agents
- [Plugins](docs/plugins.md) — Plugin system and management

### Guides

- [Webhook Receiver](docs/webhook-receiver-design.md) — Webhook ingress security model and Cloudflare Tunnel setup
- [Matrix Setup](docs/matrix-guide.md) — Chat connector configuration
- [Email Setup](docs/email-setup.md) — Email connector configuration
- [Outlook OAuth2](docs/email-outlook-oauth2.md) — OAuth2 setup for Microsoft email accounts
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
| [010](adr/010-lethal-trifecta.md) | The lethal trifecta — taint, sensitivity, and capability |
