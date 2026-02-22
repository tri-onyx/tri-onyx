# ADR-002: Elixir/OTP for the Gateway

- **Status:** Accepted
- **Date:** 2026-02-17
- **Deciders:** Sondre

## Context

TriOnyx needs a gateway process that acts as the non-agentic control plane between untrusted AI agent sessions and the outside world. The gateway must:

- Manage many concurrent agent sessions, each with independent lifecycle and state
- Route and intercept every message between agents and between agents and external services
- Enforce taint propagation, tool-call authorization, and risk scoring on every message in transit
- Survive individual agent crashes without affecting other sessions or the gateway itself
- Support hot-reload of agent definitions and configuration without downtime
- Remain deterministic — no LLM logic, no autonomous decisions

## Decision

Use **Elixir on the BEAM VM (OTP)** as the implementation language for the gateway.

## Rationale

### Process model maps directly to agent sessions

Each agent session becomes a BEAM process — lightweight (~2 KB initial heap), preemptively scheduled, and garbage-collected independently. The gateway can manage thousands of concurrent sessions without thread pools, async runtimes, or manual memory management. There is no impedance mismatch between the domain concept (isolated agent session) and the runtime primitive (BEAM process).

### Supervision trees provide fault isolation by design

OTP supervisors give us restart strategies (one-for-one, rest-for-one) out of the box. A crashing agent session is restarted automatically without affecting sibling sessions. The "let it crash" philosophy aligns with TriOnyx's security model: if an agent session enters an unexpected state, kill it and start fresh rather than trying to recover corrupted state.

### Message passing is native and interceptable

BEAM processes communicate exclusively through message passing. The gateway process sits in the message path between agents and can pattern-match, validate, sanitize, and annotate every message. Taint propagation and tool-call authorization are implemented as message transformations — not middleware bolted onto an HTTP framework.

### Pattern matching simplifies security policy enforcement

Elixir's pattern matching on function heads and message shapes makes security rules declarative and auditable. A malformed or unauthorized message fails to match and is rejected at the language level rather than through conditional logic.

### Ports and external processes

The BEAM's Port abstraction manages external OS processes (Python agent runtimes spawned via `uv run`) with built-in monitoring. If an agent's Python process exits, the owning BEAM process is notified immediately. There is no polling or PID file management.

### Hot code reloading

OTP supports hot code upgrades, enabling live-reload of agent definitions and gateway configuration without dropping active sessions.

## Alternatives Considered

### Go

Strong concurrency via goroutines, but lacks supervision trees and structured fault isolation. Error handling is manual and pervasive. No built-in equivalent to OTP's process linking and monitoring. Would require building a supervision layer from scratch.

### Rust

Excellent performance and memory safety, but async Rust (tokio) adds significant complexity for a message-routing application. No equivalent to BEAM's lightweight processes or supervision trees. The gateway is I/O-bound, not CPU-bound — Rust's performance advantages are not material here.

### Python (asyncio)

The agent runtime already uses Python, which would reduce the language count. However, asyncio's cooperative scheduling means a misbehaving coroutine can block the event loop. No fault isolation between tasks — one unhandled exception can take down the process. The GIL limits true parallelism. Python is the right choice for the agent runtime (where the Claude SDK lives), but not for the security-critical gateway.

### Node.js (TypeScript)

Single-threaded event loop with the same cooperative scheduling limitations as Python asyncio. No process isolation. Error handling for concurrent streams is fragile. Would require external process managers (PM2, cluster module) to approximate what OTP provides natively.

## Consequences

- **Positive:** The gateway implementation is concise, fault-tolerant, and maps cleanly to the domain. Concurrent agent sessions, message interception, and crash recovery are handled by the runtime rather than application code.
- **Positive:** The Elixir ecosystem (Phoenix, LiveView) provides a natural path for adding a web dashboard and real-time monitoring.
- **Negative:** Elixir is a less common language, which narrows the contributor pool.
- **Negative:** Introduces a second language into the stack (alongside Python for the agent runtime), increasing operational complexity.
- **Accepted trade-off:** The architectural fit outweighs the operational cost of a two-language stack. The gateway and agent runtime have fundamentally different requirements — using a single language would mean compromising one or the other.
