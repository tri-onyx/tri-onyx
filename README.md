# TriOnyx

An autonomous agent gateway that secures multi-agent LLM systems by tracking what agents have *seen*, not just what they can *do*.

Built on Elixir/OTP. Runs Claude-powered agents in isolated Docker containers with FUSE filesystem policies, network sandboxing, and two-axis risk scoring derived from the Biba and Bell-LaPadula information security models. Designed for a single operator managing their own agents — not a multi-tenant platform.

---

## The Problem with Agent Security Today

Every agent framework gets security wrong in the same way: they sandbox **capability**. Restrict filesystem access. Disable shell execution. Limit network calls. The assumption is that a capable agent is a dangerous agent, so reduce capability to reduce risk.

This is backwards.

An LLM with full shell access that has only seen trusted data is safe — it has no adversarial influence and will execute exactly what you expect. An LLM with read-only access that has ingested a prompt injection is dangerous — it can craft messages that manipulate downstream agents, produce misleading outputs that corrupt human decisions, and encode sensitive data in seemingly innocuous text. The agent that "can't do anything" is the one that poisons your entire system.

The real threat to LLM agents is **information**, not capability:

- **Prompt injection** is an information attack. Adversarial instructions embedded in data propagate through attention mechanisms and influence every subsequent output. Once the context is poisoned, there is no reliable way to detect which outputs are compromised.
- **Data exfiltration** is an information problem. An agent does not need file-write access to leak your data — it needs to have *seen* your data and to have *any* output channel: a message to another agent, a text response, a tool call with parameters.
- **Multi-agent propagation** is an information flow problem. Agent A ingests a malicious web page. Agent A sends a summary to Agent B. Agent B, which has shell access, follows the embedded instructions. The attack traverses the capability boundary through data, not through tools.

Capability-only sandboxing hides these risks. A "read-only" agent looks safe. A "no network" agent looks contained. But if the read-only agent sends messages to the shell-capable agent, and the no-network agent writes files that a networked agent reads, the security model is theater.

TriOnyx tracks **information exposure** — what each agent has seen and where that information flows — and uses it as the primary dimension of security enforcement.

---

## How TriOnyx Works

### Architecture

![Agent topology graph showing taint and sensitivity propagation between agents](docs/agent-graph.png)

*Live agent topology rendered by the gateway's graph analysis endpoint. Edges carry taint (T) and sensitivity (S) levels that determine what data can flow between agents.*

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

**Gateway (Elixir/OTP)** — The non-agentic control plane. Contains no LLM logic. Manages agent lifecycles through OTP supervision trees, intercepts and validates every inter-agent message, tracks information exposure on two independent axes, computes risk scores, and enforces security policies. Each agent session is a BEAM process — lightweight, isolated, independently supervisable.

**Agent Runtime (Python)** — Drives Claude sessions via the Claude Agent SDK inside Docker containers. Communicates with the gateway over JSON Lines on stdin/stdout. The agent operates autonomously within its sandbox — the gateway configures constraints before launch, not during execution.

**FUSE Driver (Go)** — A passthrough filesystem that enforces per-file read/write policies inside each container. Pre-computes a path trie from glob patterns for O(1) access decisions. Checks the risk manifest on every read to enforce taint and sensitivity thresholds. Logs all writes and denials as structured events.

### Two-Axis Risk Model

TriOnyx tracks information exposure on two independent axes, derived from established information security models:

**Taint (integrity — Biba model):** How trustworthy is the data the agent has seen? High taint means the agent has ingested raw internet content, webhook payloads, or other data that may contain prompt injection. Taint tracks the risk of the agent being *manipulated*.

**Sensitivity (confidentiality — Bell-LaPadula model):** How sensitive is the data the agent has seen? High sensitivity means the agent has received data obtained through authenticated tool calls — internal databases, private APIs, user records. Sensitivity rises when the agent has seen confidential data. Sensitivity tracks the risk of the agent *leaking* information.

These axes are independent. An agent can be high-taint and low-sensitivity (ingested untrusted public data), low-taint and high-sensitivity (queried a trusted internal database), or high on both. Each combination produces different risks:

|                    | sensitivity: low | sensitivity: medium | sensitivity: high |
|--------------------|-----------------|---------------------|-------------------|
| taint: low         | low             | low                 | moderate          |
| taint: medium      | low             | moderate            | high              |
| taint: high        | moderate        | high                | critical          |

Capability (which tools an agent has) is controlled at the agent definition level and is not part of the runtime risk formula.

Both axes are **monotonic** — they can only increase during a session. You cannot un-see a prompt injection or un-learn a database record. When effective risk exceeds the agent's policy threshold, the gateway kills the session. No downgrade, no capability revocation — kill and restart clean.

### Bandwidth-Constrained Trust Protocol (BCTP)

The hardest problem in multi-agent security: how do you extract useful information from a tainted agent without contaminating the receiver?

TriOnyx's answer is to treat inter-agent communication as a **channel capacity problem**. Instead of trying to detect prompt injection in free text (an arms race), BCTP constrains the *bandwidth* of the channel through which tainted data reaches clean agents:

**Category 1 — Structured Primitives (~1-10 bits).** Booleans, enums, bounded integers. Validated by deterministic code. At 7 bits of channel capacity, there is no encoding that can represent a coherent instruction. Prompt injection is not probabilistically reduced — it is *structurally impossible*.

**Category 2 — Constrained Q&A (~50-400 bits).** Specific questions with word limits and format constraints. Validated by length, format, cross-question consistency, and anomaly detection. Below the ~1,000 bits needed for a convincing natural-language instruction.

**Category 3 — Constrained Summary (~1,000+ bits).** Free-text summaries with word limits. At this bandwidth, prompt injection *is* possible. Requires mandatory human-in-the-loop approval before the clean agent processes it.

The untainted agent always controls the dialogue structure. The tainted agent cannot negotiate for a wider channel. Escalation from lower to higher categories is budget-limited, requires justification, and (for Category 3) requires human approval of the escalation itself.

Every query carries a theoretical bandwidth in bits. The system maintains a running total per task, giving operators a quantitative measure of exposure — not "seems safe" but "47 bits from tainted sources, of which 6.9 were deterministically validated."

### Security Enforcement Layers

| Layer | Mechanism | What it enforces |
|-------|-----------|-----------------|
| **Message routing** | Gateway intercepts all inter-agent communication | Biba integrity (no taint flowing to cleaner agents without BCTP), BLP confidentiality (no sensitivity flowing to network-capable agents) |
| **Filesystem** | FUSE driver with pre-computed path trie | Per-file read/write globs, risk-manifest-based taint/sensitivity filtering |
| **Network** | iptables rules per container | Host allowlists, deny-all with Claude API exception |
| **Credentials** | Gateway as sole secret holder | Agents never receive tokens; sensitivity auto-classified from auth usage |
| **Risk manifest** | Per-file provenance in `.tri-onyx/risk-manifest.json` | Git commit trailers for audit trail; human review resets taint |
| **Graph analysis** | DFS traversal of agent topology | Transitive risk propagation, multi-hop laundering detection |

These layers are independent. A failure in one does not compromise the others.

### Violation Detection

The graph analyzer runs two independent checks against the agent topology — statically, at definition time, before any agent runs:

**Biba violations (inbound threat):** Flags data flows where tainted output reaches a cleaner agent. Catches prompt injection propagation through filesystem overlaps and messaging channels.

**Bell-LaPadula violations (outbound threat):** Flags data flows where sensitive output reaches a lower-sensitivity agent with network access. Catches exfiltration paths through the agent topology.

Both checks run across filesystem path overlaps and declared messaging channels. The visualization renders violations as highlighted edges in the agent graph, with a matrix panel showing all (writer, reader) pairs.

---

## Agent Definitions

Agents are defined as markdown files with YAML frontmatter in `agents/`:

```markdown
---
name: code-reviewer
description: Reviews code for quality, security, and style
model: sonnet
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

The `skills` field loads Claude Code skill files into the agent's context at session start. Skills are markdown files that teach the agent how to perform a specific type of task.

Place skills in `workspace/.claude/skills/<skill-name>/SKILL.md`:

```
workspace/
└── .claude/
    └── skills/
        └── code-review-standards/
            └── SKILL.md
```

Each skill needs a name and description in its frontmatter:

```markdown
---
name: code-review-standards
description: Apply project code review standards when reviewing pull requests or code changes
---

## Code Review Checklist

- Check for...
```

When an agent declares a skill, the FUSE driver grants read access to that skill's directory. Undeclared skills in `.claude/skills/` are not readable by the agent.

---

## Prerequisites

- Docker

## Building

```bash
# Gateway image (Elixir/OTP)
docker build -f gateway.Dockerfile -t tri-onyx-gateway:latest .

# Agent runtime image (Python + FUSE sandbox)
docker build -f agent.Dockerfile -t tri-onyx-agent:latest .
```

The agent image requires a pre-built FUSE driver binary at `fuse/tri-onyx-fs`. See `fuse/README.md` for build instructions.

## Running

Start the gateway:

```bash
docker run --rm -p 4000:4000 \
  -v $(pwd):/app -w /app \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e TRI_ONYX_HOST_ROOT=$(pwd) \
  --env-file .env \
  tri-onyx-gateway:latest mix run --no-halt
```

`TRI_ONYX_HOST_ROOT` tells the gateway the real host path so that agent container bind mounts resolve correctly.

## API

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/agents` | List agents with risk scores |
| `GET` | `/agents/:name` | Agent detail with taint status |
| `POST` | `/agents/:name/start` | Start an agent session |
| `POST` | `/agents/:name/stop` | Stop an agent session |
| `POST` | `/agents/:name/prompt` | Send prompt to running agent |
| `GET` | `/agents/:name/events` | SSE stream of agent events |
| `POST` | `/hooks/:endpoint_id` | Authenticated webhook ingress (internet-facing) |
| `POST` | `/messages` | External message with Bearer token auth |
| `GET` | `/webhook-endpoints` | List/create/update/delete webhook endpoints |
| `GET` | `/graph/analysis` | Graph analysis with risk propagation |
| `GET` | `/audit?since=YYYY-MM-DD` | Query audit log |
| `GET` | `/health` | Health check |

## Testing

```bash
# Elixir gateway tests
docker run --rm -v $(pwd):/app -w /app tri-onyx-gateway:latest mix test

# Go FUSE driver tests
docker run --rm --device /dev/fuse --cap-add SYS_ADMIN \
  --security-opt apparmor=unconfined \
  -v $(pwd)/fuse:/src -w /src golang:1.22 go test ./...
```

## Cloudflare Tunnel Setup

The gateway receives webhooks from external services via a Cloudflare Tunnel that exposes only the `/hooks/*` path. All management endpoints stay local-only. See [docs/webhook-receiver-design.md](docs/webhook-receiver-design.md) for the full webhook security model.

---

## Project Structure

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

agents/                   Agent definitions (markdown + YAML frontmatter)
```

## Documentation

- [docs/bctp.md](docs/bctp.md) — Bandwidth-Constrained Trust Protocol specification
- [docs/protocol.md](docs/protocol.md) — Gateway-runtime JSON Lines protocol
- [docs/agent-runtime.md](docs/agent-runtime.md) — Agent execution lifecycle
- [docs/fuse-driver-spec.md](docs/fuse-driver-spec.md) — FUSE driver specification
- [docs/webhook-receiver-design.md](docs/webhook-receiver-design.md) — Webhook ingress security model

## Architecture Decision Records

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
