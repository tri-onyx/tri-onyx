# TriOnyx Architecture

## Overview

TriOnyx is an autonomous persistent AI assistant built on the principle that
**information is the threat, not capability**. Unlike traditional agent frameworks
that try to sandbox tools, TriOnyx treats untrusted input as the primary attack
vector and uses a non-agentic gateway to enforce security boundaries around
LLM sessions.

## Core Principle

An intelligent, untainted agent with destructive tools is safe.
A tainted agent with read-only tools is dangerous.

Security is a function of: **taint × sensitivity**

---

## Technology

- **Gateway:** Elixir/OTP on the BEAM VM
- **Agent runtime:** Python (>=3.11) via Claude Agent SDK, managed by UV
- **Agent definitions:** Markdown files with YAML frontmatter

The gateway is built on Elixir because TriOnyx's architecture maps directly
onto OTP primitives. Each agent session is a BEAM process — lightweight,
isolated, independently supervisable. The gateway's supervision tree manages
agent lifecycles with automatic restart strategies and fault isolation. A
crashing agent session never takes down the gateway. Message routing between
agents is native to the BEAM's process messaging model, and the gateway
process can pattern-match, validate, and sanitize every message in transit.

The agent runtime remains Python because the Claude Agent SDK is a Python
library. The gateway spawns agent processes via `uv run` and streams their
output through Elixir Ports.

---

## System Components

### 1. Gateway (Control Plane)

The gateway is the heart of TriOnyx. It is **non-agentic** — it contains no
LLM logic and makes no autonomous decisions. It is a deterministic security
boundary that mediates all external access. It is an Elixir/OTP application.

**Responsibilities:**

- **Agent lifecycle management** — spawn, stop, and monitor agent sessions
- **Sandbox configuration** — read agent definitions and build the execution
  environment before launch: Docker container, FUSE policy, network rules,
  allowed tool list. Once the agent is running, the sandbox enforces the rules —
  the gateway does not intercept individual tool calls at runtime
- **Message routing** — route triggers to agents and mediate inter-agent
  communication with sanitization
- **Taint tracking** — track which agent sessions have been exposed to untrusted
  input and compute effective risk
- **Risk reporting** — calculate and display risk scores for each agent so the
  human operator can make informed decisions. The gateway warns but does not
  block — the human is the final authority
- **Sender verification** — authenticate external message senders before
  routing to agents

### 2. Agent (LLM Session)

An agent **is** an LLM session. There is no wrapper process, no separate runtime.
The agent is defined by a markdown file that serves as a complete contract between
the human operator and the gateway.

**Agent Definition Format:**

```markdown
---
name: agent-name
description: What this agent does
model: sonnet
tools: Read, Grep, Glob
network: none
fs_read:
  - "/repo/src/**/*.py"
  - "/repo/docs/**/*.md"
fs_write:
  - "/repo/src/output/**"
---

System prompt that defines the agent's identity, task, and behavior.
```

**Properties:**

- `name` — unique identifier
- `description` — human-readable purpose
- `model` — which LLM backs this session (e.g. sonnet, opus, haiku)
- `tools` — allowed tool list, passed to the Claude Agent SDK at launch
- `network` — network access policy (see Sandboxing below)
- `fs_read` — glob patterns for filesystem read access (default: none)
- `fs_write` — glob patterns for filesystem write access (default: none; implies read)

The agent and the LLM are one — they run in the same process inside a
Docker container. The agent talks to the Claude API directly and executes
its own tools. The gateway does not sit in the middle of tool execution.
Instead, the gateway configures the sandbox (Docker, FUSE, network rules,
allowed tools) before launch, and the agent operates autonomously within
those constraints.

### 3. Triggers

Triggers are events that cause the gateway to spawn or invoke an agent session.

| Trigger           | Source              | Trust Level | Notes                                    |
|-------------------|---------------------|-------------|------------------------------------------|
| External message  | Chat platform       | Trusted     | Sender verification enforced by gateway  |
| Heartbeat         | Internal timer      | Trusted     | No external input                        |
| Cron              | Scheduled time      | Trusted     | No external input                        |
| Webhook           | External system     | Untrusted   | No sender identity; payload sanitized    |
| Inter-agent message | Another agent     | Sanitized   | Gateway mediates and sanitizes           |

### 4. Tools

Tools are capabilities the agent executes inside its container. The agent
runs its own tools directly — the gateway does not proxy tool calls. Instead,
the gateway constrains what tools can do by configuring the sandbox before
launch: the FUSE driver limits filesystem access, iptables limits network
access, and the Claude Agent SDK's `allowed_tools` parameter limits which
tools the LLM can invoke.

Tools themselves are not dangerous — they are inert functions. Risk arises
only when a tainted agent directs their use. Capability (which tools an agent
has) is controlled at the agent definition level and is not part of the
runtime risk formula.

---

## Sandboxing

Agents operate under a **default-deny** security model. An agent starts with zero
access — no tools, no network, no filesystem. Every capability must be explicitly
granted in the agent definition and is enforced by the gateway at spawn time.

### Permission Dimensions

| Dimension    | Declaration            | Enforcement Mechanism                  | Default |
|--------------|------------------------|----------------------------------------|---------|
| Tools        | `tools:`               | Claude Agent SDK `allowed_tools`       | None    |
| Network      | `network:`             | Docker network namespace + iptables    | None    |
| Filesystem   | `fs_read:`/`fs_write:` | Docker container + FUSE driver         | None    |

### Filesystem Sandboxing (Two-Layer)

Filesystem isolation uses two complementary enforcement layers:

**Layer 1: Docker container** — process-level isolation. Each agent runs in its
own container with no host mounts by default. The gateway bind-mounts only the
necessary source directory into the container at `/mnt/host`.

**Layer 2: FUSE driver (`tri-onyx-fs`)** — fine-grained access control. A
passthrough FUSE filesystem is mounted inside the container at `/workspace`. It
intercepts every syscall (`open`, `stat`, `readdir`, `write`) and checks it
against the glob patterns from `fs_read` and `fs_write`. Denied operations return
`EACCES`. The FUSE driver is a Go binary using `hanwen/go-fuse/v2`.

```
┌─────────────────────────────────────┐
│         Docker Container            │
│                                     │
│   Agent Process (Python/Claude SDK) │
│         │  syscalls                 │
│         ▼                           │
│   /workspace  (FUSE mount)          │
│         │                           │
│   tri-onyx-fs (FUSE driver)       │
│         │  allowed → passthrough    │
│         │  denied  → EACCES         │
│         ▼                           │
│   /mnt/host  (bind mount from host) │
└─────────────────────────────────────┘
```

**Access rules:**
- `fs_write` implies `fs_read` for the same paths
- Intermediate directories are traversable if they lead to allowed paths
- `readdir` filters entries to only show paths reachable by the policy (information hiding)
- Denial events are logged as structured JSON to stderr for the audit system
- Policy is static for the lifetime of the mount (fail-closed on parse errors)

See `docs/fuse-driver-spec.md` for the full FUSE driver specification.

### Network Sandboxing

Network access is controlled via Docker network namespaces and iptables rules
applied when the container is created.

```yaml
network: none                # default — no outbound access
network: outbound            # unrestricted outbound
network:                     # allowlisted hosts
  - api.github.com
  - "*.openai.com"
  - internal-service:8080
```

- `none` — the container has no network interfaces beyond loopback
- `outbound` — unrestricted outbound access
- Host list — outbound allowed only to matching hosts (with optional port)
- Inbound access is never granted to agents

---

## Security Model

### Taint Propagation

An agent session becomes tainted when untrusted information enters its
LLM context. This happens through:

1. **Trigger input** — webhook payloads, unsanitized inter-agent messages
2. **Tool results** — a tool that reads external/uncontrolled data returns
   content that may contain prompt injection (e.g. web pages, uploaded files,
   email bodies, API responses)

Once tainted, a session cannot become untainted. The gateway tracks this.

### Risk Scoring

```
effective_risk = taint × sensitivity
```

- **taint** — **computed by the gateway**, not declared by the author.
  The gateway infers this from the agent's actual input sources: what triggers
  it, what data its tools access, and whether any of those sources are
  untrusted. A cron-triggered agent reading local files has low taint.
  An agent processing webhooks and fetching web pages has high taint.
- **sensitivity** — determined by whether the agent has seen confidential data,
  based on authenticated tool calls and declared data sensitivity of tools

The gateway computes this at agent creation and displays it to the operator:

```
Agent: email-processor
  Taint:          high (processes external email)
  Sensitivity:    low (no authenticated data sources)
  Effective risk: moderate

Agent: deployer
  Taint:          low (cron triggered, no external input)
  Sensitivity:    medium (authenticated tool calls)
  Effective risk: low

Agent: webhook-handler
  Taint:          high (unvalidated webhook payload)
  Sensitivity:    high (accesses sensitive internal data)
  Effective risk: critical ⚠
```

The gateway does **not** block high-risk combinations. It highlights the risk
and the human decides. Transparency over restriction.

### Inter-Agent Communication

When agent A sends a message to agent B, the gateway mediates:

1. Agent A requests to send a message (tool call)
2. The gateway intercepts and **sanitizes** the message before delivering
   to agent B
3. Sanitization prevents prompt injection from propagating between agents

Sanitization strategy: **TBD** — initial approach is strict schema validation
where inter-agent messages must conform to declared structured formats, not
freeform text.

### Webhook Sanitization

Webhook payloads are untrusted by definition. The gateway applies strict
validation against declared schemas before passing content to agents.

Sanitization strategy: **TBD** — strict regularization of allowed values.

---

## Data Flow

```
  ┌─ Docker Container A ──────────────┐  ┌─ Docker Container B ──────────────┐
  │                                   │  │                                   │
  │  Agent A (= LLM session)         │  │  Agent B (= LLM session)         │
  │  model: opus                     │  │  model: haiku                    │
  │       │                          │  │       │                          │
  │       │ Claude API (direct)      │  │       │ Claude API (direct)      │
  │       │ Tool execution (local)   │  │       │ Tool execution (local)   │
  │       │                          │  │       │                          │
  │  ┌────┴─────────────────────┐    │  │  ┌────┴─────────────────────┐    │
  │  │ Sandbox enforcement      │    │  │  │ Sandbox enforcement      │    │
  │  │  FUSE: fs_read/fs_write  │    │  │  │  FUSE: fs_read/fs_write  │    │
  │  │  iptables: network rules │    │  │  │  iptables: network rules │    │
  │  │  SDK: allowed_tools      │    │  │  │  SDK: allowed_tools      │    │
  │  └──────────────────────────┘    │  │  └──────────────────────────┘    │
  └──────────────┬───────────────────┘  └──────────────┬───────────────────┘
                 │ inter-agent msgs                    │
                 │ lifecycle events                    │
                 │                                     │
  ┌──────────────┴─────────────────────────────────────┴──────────────┐
  │                           GATEWAY                                 │
  │                        (Control Plane)                            │
  │                                                                   │
  │  ┌────────────┐  ┌────────────┐  ┌──────────────────────────┐    │
  │  │ Trigger    │  │ Taint      │  │ Sandbox Builder          │    │
  │  │ Router     │  │ Tracker    │  │ (reads agent definition, │    │
  │  └─────┬──────┘  └─────┬──────┘  │  configures Docker +    │    │
  │        │               │         │  FUSE + iptables + SDK)  │    │
  │        │               │         └──────────────────────────┘    │
  │  ┌─────┴───────────────┴──────────────────────────────────────┐  │
  │  │  Inter-Agent Sanitizer (mediates messages between agents)  │  │
  │  └────────────────────────────────────────────────────────────┘  │
  └──────────┬──────────────────┬──────────────────┬────────────────┘
             │                  │                  │
        ┌────┴───┐       ┌──────┴────┐      ┌─────┴────┐
        │External│       │  Cron /   │      │ Webhook  │
        │Message │       │ Heartbeat │      │          │
        │(verified)│      │ (clean)   │      │(untrusted)│
        └────────┘       └───────────┘      └──────────┘
```

---

## Design Principles

1. **Information is the threat, not capability.** Restrict what an agent sees,
   not what tools exist.

2. **The gateway is deterministic.** No LLM logic in the control plane. It
   configures sandboxes and enforces rules mechanically.

3. **Agents are autonomous within their sandbox.** The agent is the LLM
   session. It talks to the Claude API directly and executes its own tools.
   The gateway builds the sandbox before launch; it does not proxy tool calls.

4. **Transparency over restriction.** The gateway computes and displays risk.
   The human decides.

5. **Taint is permanent per session.** Once untrusted input enters a session,
   it stays tainted. Design agents with this in mind.

6. **Inter-agent communication is mediated.** Agents never talk directly.
   The gateway sanitizes every message crossing agent boundaries.
