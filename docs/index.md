# TriOnyx

An autonomous agent gateway that secures multi-agent LLM systems by tracking what agents have *seen*, not just what they can *do*.

Built on Elixir/OTP. Runs Claude-powered agents in isolated Docker containers with FUSE filesystem policies, network sandboxing, and two-axis risk scoring derived from the Biba and Bell-LaPadula information security models.

## The Problem with Agent Security Today

Every agent framework gets security wrong in the same way: they sandbox **capability**. Restrict filesystem access. Disable shell execution. Limit network calls. The assumption is that a capable agent is a dangerous agent, so reduce capability to reduce risk.

This is backwards.

The real threat to LLM agents is **information**, not capability:

- **Prompt injection** is an information attack — adversarial instructions embedded in data propagate through attention mechanisms and influence every subsequent output.
- **Data exfiltration** is an information problem — an agent doesn't need file-write access to leak data, it needs to have *seen* the data and to have *any* output channel.
- **Multi-agent propagation** is an information flow problem — attacks traverse capability boundaries through data, not through tools.

TriOnyx tracks **information exposure** — what each agent has seen and where that information flows — and uses it as the primary dimension of security enforcement.

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
