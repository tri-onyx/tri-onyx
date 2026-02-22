# ADR-003: Python for the Agent Runtime and Communication Entrypoint

- **Status:** Accepted
- **Date:** 2026-02-17
- **Deciders:** Sondre

## Context

TriOnyx agents need a runtime that can drive LLM sessions via the Claude Agent SDK, expose tools to the model, and communicate with the Elixir gateway over a structured protocol. The runtime executes inside a sandboxed Docker container with a FUSE-based filesystem and network policy enforcement.

Additionally, TriOnyx needs a connector process that bridges external communication platforms (Matrix, Slack, Discord) to the gateway over WebSocket, translating platform-specific messages into the gateway's internal protocol.

Both of these components — the agent runtime and the connector — are Python.

## Decision

Use **Python (>=3.11)** as the language for:

1. **The agent runtime** (`runtime/agent_runner.py`) — the process that drives Claude sessions inside each agent container
2. **The connector** (`connector/`) — the process that bridges chat platforms to the gateway via WebSocket

## Rationale

### The Claude Agent SDK is a Python library

The Claude Agent SDK (`claude-agent-sdk`) provides `ClaudeSDKClient`, streaming response handling, and MCP tool hosting. It is the primary interface for driving Claude sessions programmatically. The SDK is Python-only. Using Python for the agent runtime is not a preference — it is a constraint imposed by the SDK.

### PEP 723 inline scripts eliminate dependency management overhead

The agent runner uses PEP 723 inline script metadata rather than a full `pyproject.toml`. Dependencies are declared at the top of the script file and resolved by UV at execution time. During container build, `uv run --script` pre-caches dependencies so no network access is needed at runtime. This keeps the agent runtime as a single file with no project scaffolding.

### UV provides hermetic, fast dependency resolution

UV replaces pip, venv, and virtualenv. It resolves and installs dependencies deterministically, caches aggressively, and integrates with PEP 723 inline scripts. The agent container copies UV from `ghcr.io/astral-sh/uv:latest` and pre-warms the cache during image build. Agent processes share the cached environment via `/opt/uv-cache`.

### asyncio supports concurrent message handling within the runtime

The agent runner uses `asyncio` to multiplex stdin reading, SDK response streaming, and inter-agent message routing (SendMessage, BCP queries) without threads. The `InboundDispatcher` decouples the stdin reader from message handlers using `asyncio.Queue`, allowing the runtime to block on a SendMessage response while continuing to process control messages.

### The connector is I/O-bound glue code

The connector maintains a persistent WebSocket connection to the gateway and adapts platform-specific APIs (Matrix via `matrix-nio`, future Slack/Discord adapters) into the gateway's protocol. This is straightforward async I/O — exactly what Python's `asyncio` and `websockets` libraries handle well. There is no performance-critical path in the connector.

### Python is the lingua franca for AI tooling

Agent tools, MCP servers, and integration libraries are predominantly available in Python first. Using Python for the runtime means new tools and SDK features are available immediately without language bindings or FFI.

## Architecture

### Agent Runtime

The gateway spawns one Python process per agent session via Elixir's `Port.open()`:

```
AgentSession (Elixir GenServer)
  └─ AgentPort (Elixir GenServer)
       └─ Port.open() → docker run ... uv run --script agent_runner.py
```

Communication uses JSON Lines over stdin/stdout:

- **stdin** (gateway → runtime): `start`, `prompt`, `shutdown`, `send_message_response`, `bcp_query`, `bcp_response_delivery`
- **stdout** (runtime → gateway): `ready`, `text`, `tool_use`, `tool_result`, `result`, `error`, `send_message_request`, `bcp_query_request`, `bcp_response`
- **stderr**: diagnostic logging only, plus FUSE write events from the filesystem driver

The runtime creates a `ClaudeSDKClient` on `start`, drives it with prompts, and streams every response block back as a protocol message. Inter-agent tools (SendMessage, BCPQuery, BCPRespond) are hosted as in-process MCP tools via the SDK's `@tool()` decorator — no external MCP server process.

### Connector

The connector runs as a separate Python process outside the agent sandbox:

```
Connector Process
  ├─ GatewayClient (WebSocket, auto-reconnect with exponential backoff)
  └─ Adapter Registry
       ├─ MatrixAdapter (matrix-nio)
       └─ (future: Slack, Discord, etc.)
```

It registers with the gateway on connect, receives outbound messages (agent text, results, errors, typing indicators), and forwards inbound messages from chat platforms as trigger payloads.

## Alternatives Considered

### TypeScript/Node.js for the connector

Would work for the connector (good WebSocket and async I/O support), but introduces a third language into the stack. The connector shares protocol types with the agent runtime — keeping both in Python avoids duplication and drift.

### Rust or Go for the agent runtime

Neither has a Claude Agent SDK. Would require reimplementing the SDK client, streaming response handling, and MCP tool hosting. The agent runtime is not performance-critical — it spends most of its time waiting on LLM API responses.

### Python for the gateway (single-language stack)

Rejected in [ADR-002](002-elixir-gateway.md). Python's cooperative scheduling (asyncio), lack of process isolation, and the GIL make it unsuitable for the security-critical gateway. The runtime and gateway have fundamentally different requirements.

## Consequences

- **Positive:** Direct access to the Claude Agent SDK with no bindings or wrappers. New SDK features are available immediately.
- **Positive:** PEP 723 + UV keeps the agent runtime as a single file with cached, hermetic dependencies. No project scaffolding per agent.
- **Positive:** The connector and runtime share Python protocol types, reducing duplication.
- **Negative:** Python is the slower runtime in the stack. This is acceptable because the agent runtime is I/O-bound (waiting on LLM API calls) and the connector is similarly I/O-bound (WebSocket + chat platform APIs).
- **Negative:** Two languages in the stack (Elixir + Python) increases operational complexity. Mitigated by clear separation: Elixir owns the gateway, Python owns everything that touches the Claude SDK or external chat platforms.
- **Accepted trade-off:** The JSON Lines protocol over stdin/stdout adds serialization overhead compared to in-process function calls. This is the cost of process isolation — and process isolation is a security requirement, not an optimization target.
