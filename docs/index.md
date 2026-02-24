# TriOnyx — What OpenClaw would be if security came first

A complete agent runtime that tracks what agents have *seen*, not just what they can *do*.

## The core problem

OpenClaw sandboxes **capability** — restrict filesystem access, disable shell, limit network. This misses the point. An LLM that has ingested a prompt injection is dangerous regardless of what tools it has. The real threat is **information**: what enters an agent's context, and where it flows next.

## What TriOnyx does

- **Isolated agent containers** — each agent runs in its own Docker container with a per-agent FUSE filesystem, network rules, and no shared state
- **Taint and sensitivity tracking** — two independent axes (Biba integrity, Bell-LaPadula confidentiality) that measure what each agent has been exposed to
- **Information flow enforcement** — the gateway intercepts all inter-agent communication and blocks flows that would violate integrity or confidentiality constraints
- **Auditable everything** — structured logs for file access, tool calls, message routing, and policy violations
- **Risk reduction, not elimination** — the security model makes attacks harder and detectable, not theoretically impossible

Built on Elixir/OTP. Designed for a single operator running their own agents.

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
│  • Taint & sensitivity tracking          │
│  • Message interception & validation     │
│  • Risk scoring & violation detection    │
│  • Credential management (sole holder)   │
│  • Graph analysis (transitive risk)      │
└─────────┬──────────────┬─────────────────┘
          │              │
          ▼              ▼
┌─────────────┐  ┌─────────────┐
│ Agent A     │  │ Agent B     │
│ Python +    │  │ Python +    │
│ Claude SDK  │  │ Claude SDK  │
│ FUSE (Go)   │  │ FUSE (Go)   │
│ Docker      │  │ Docker      │
└─────────────┘  └─────────────┘
```

**Gateway (Elixir/OTP)** — The non-agentic control plane. Manages agent lifecycles, intercepts and validates every inter-agent message, tracks information exposure, computes risk scores, and enforces security policies.

**Agent Runtime (Python)** — Drives Claude sessions via the Claude Agent SDK inside Docker containers. Communicates with the gateway over JSON Lines on stdin/stdout.

**FUSE Driver (Go)** — A passthrough filesystem that enforces per-file read/write policies inside each container. Pre-computes a path trie from glob patterns for O(1) access decisions.

## Two-Axis Risk Model

TriOnyx tracks information exposure on two independent axes:

- **Taint (integrity — Biba model):** How trustworthy is the data the agent has seen? High taint means potential prompt injection exposure.
- **Sensitivity (confidentiality — Bell-LaPadula model):** How sensitive is the data the agent has seen? High sensitivity means the agent has accessed confidential data.

Both axes are **monotonic** — they can only increase during a session. When effective risk exceeds the agent's policy threshold, the gateway kills the session.

## Documentation

- [Agent Runtime](agent-runtime.md) — Agent execution lifecycle
- [Protocol](protocol.md) — Gateway-runtime JSON Lines protocol
- [FUSE Driver](fuse-driver-spec.md) — FUSE driver specification
- [BCP](bcp.md) — Bandwidth-Constrained Trust Protocol
- [Matrix Setup](matrix-guide.md) — Matrix chat integration
- [E2E Testing](e2e-testing.md) — End-to-end testing guide
