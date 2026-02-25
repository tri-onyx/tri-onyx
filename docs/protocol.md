# TriOnyx Runtime Protocol

## Overview

The runtime protocol defines the structured JSON messages exchanged between the
Elixir gateway and the Python agent runtime.  This is a line-based protocol:
each message is a single JSON object terminated by a newline (JSON Lines).

The gateway spawns the runtime as a subprocess via `uv run runtime/agent_runner.py`
and communicates using three channels:

| Channel | Direction          | Purpose                                        |
|---------|--------------------|------------------------------------------------|
| stdin   | Gateway -> Runtime | Configuration, prompts, interrupts, shutdown   |
| stdout  | Runtime -> Gateway | Events, results, errors (structured protocol)  |
| stderr  | Runtime -> (logs)  | Diagnostic logging (not part of protocol)      |

**Important:** The agent executes its own tools via the Claude Agent SDK.  The
gateway does NOT proxy tool calls.  Events on stdout are **observational** --
the gateway uses them for taint tracking and audit logging, not for mediating
tool execution.

---

## Lifecycle

```
Gateway                              Runtime
  |                                    |
  |--- spawn via `uv run` ----------->|
  |                                    | (process starts)
  |                                    |
  |--- {"type":"start",...} --------->|
  |                                    | (configure SDK)
  |<-- {"type":"ready"}  -------------|
  |                                    |
  |--- {"type":"prompt",...} -------->|
  |                                    | (drive SDK session)
  |<-- {"type":"text",...}  ----------|  \
  |<-- {"type":"tool_use",...} -------|   | streaming events
  |<-- {"type":"tool_result",...} ----|  /
  |<-- {"type":"result",...} ---------|
  |                                    |
  |--- {"type":"prompt",...} -------->|  (another trigger)
  |     ...                            |
  |                                    |
  |--- {"type":"shutdown",...} ------>|
  |                                    | (exit cleanly)
```

1. **Gateway spawns runtime** via `uv run runtime/agent_runner.py`
2. **Gateway sends `start`** with agent configuration
3. **Runtime replies `ready`** once SDK is configured
4. **Gateway sends `prompt`** messages to trigger agent sessions
5. **Runtime streams events** (`text`, `tool_use`, `tool_result`) during each session
6. **Runtime sends `result`** when each session completes
7. **Gateway sends `shutdown`** (or closes stdin) to terminate the runtime

---

## Inbound Messages (Gateway -> Runtime)

### `start`

Configures the agent.  Must be the first message sent after spawning.

```json
{
  "type": "start",
  "agent": {
    "name": "code-reviewer",
    "tools": ["Read", "Grep", "Glob"],
    "model": "claude-sonnet-4-20250514",
    "system_prompt": "You are a code reviewer...",
    "max_turns": 10,
    "cwd": "/workspace"
  }
}
```

| Field                | Type       | Required | Default                      | Description                                   |
|----------------------|------------|----------|------------------------------|-----------------------------------------------|
| `agent.name`         | string     | yes      | `"unnamed"`                  | Agent identifier (from agent definition)      |
| `agent.tools`        | string[]   | yes      | `[]`                         | Allowed tools (SDK `allowed_tools`)           |
| `agent.model`        | string     | no       | `"claude-sonnet-4-20250514"` | LLM model identifier                         |
| `agent.system_prompt` | string    | no       | `""`                         | System prompt (appended to `claude_code` preset) |
| `agent.max_turns`    | integer    | no       | `10`                         | Maximum SDK turns per session                 |
| `agent.cwd`          | string     | no       | `"/workspace"`               | Working directory for the agent               |
| `agent.skills`       | string[]   | no       | `[]`                         | List of skill names to load into the agent's context |

### `prompt`

Delivers a trigger payload to drive an agent session.

```json
{
  "type": "prompt",
  "content": "Review the changes in the last commit",
  "metadata": {
    "trigger": "cron",
    "session_id": "a3f2c"
  }
}
```

| Field      | Type   | Required | Description                                    |
|------------|--------|----------|------------------------------------------------|
| `content`  | string | yes      | The prompt text to send to the LLM             |
| `metadata` | object | no       | Opaque metadata from the gateway (not sent to LLM) |

### `interrupt`

Requests cancellation of the active prompt.  The runtime should cancel the
in-flight SDK call, drain any stale response queues, and emit an `interrupted`
message once ready for the next prompt.

```json
{
  "type": "interrupt",
  "reason": "user_message"
}
```

| Field    | Type   | Required | Description                          |
|----------|--------|----------|--------------------------------------|
| `reason` | string | no       | Why the interrupt was requested      |

### `shutdown`

Requests a graceful shutdown.  The runtime should finish any active session
and exit cleanly.

```json
{
  "type": "shutdown",
  "reason": "Agent stopped by operator"
}
```

| Field    | Type   | Required | Description              |
|----------|--------|----------|--------------------------|
| `reason` | string | no       | Human-readable reason    |

---

## Outbound Messages (Runtime -> Gateway)

### `ready`

Signals that the runtime has processed the `start` message and is ready to
receive prompts.

```json
{
  "type": "ready"
}
```

### `interrupted`

Signals that the runtime has cancelled the active prompt in response to an
`interrupt` message and is ready for the next prompt.

```json
{
  "type": "interrupted",
  "reason": "user_message"
}
```

| Field    | Type   | Description                            |
|----------|--------|----------------------------------------|
| `reason` | string | Echo of the interrupt reason           |

### `text`

Streams LLM text output during a session.  The gateway logs these for
auditability.

```json
{
  "type": "text",
  "content": "I'll review the changes now..."
}
```

| Field     | Type   | Description          |
|-----------|--------|----------------------|
| `content` | string | LLM-generated text   |

### `tool_use`

Reports that the agent invoked a tool.  **Observational only** -- the SDK
already executed the tool.  The gateway uses this for audit logging.

```json
{
  "type": "tool_use",
  "id": "toolu_01abc",
  "name": "Read",
  "input": {
    "file_path": "/workspace/src/main.py"
  }
}
```

| Field   | Type   | Description                        |
|---------|--------|------------------------------------|
| `id`    | string | Tool use ID (from SDK)             |
| `name`  | string | Tool name (e.g., "Read", "Bash")   |
| `input` | object | Tool input parameters              |

### `tool_result`

Reports a tool's return value.  **Observational only** -- the gateway uses
this for **taint tracking**: if a tool accessed untrusted external data, the
gateway marks the session as tainted.

Tool result content is truncated to 4096 characters to avoid flooding the
protocol channel.

```json
{
  "type": "tool_result",
  "tool_use_id": "toolu_01abc",
  "content": "def main():\n    print('hello')\n...",
  "is_error": false
}
```

| Field         | Type    | Description                                    |
|---------------|---------|------------------------------------------------|
| `tool_use_id` | string  | Correlates with the preceding `tool_use.id`    |
| `content`     | string  | Tool result content (may be truncated)         |
| `is_error`    | boolean | Whether the tool returned an error             |

### `result`

Reports session completion with execution metadata.

```json
{
  "type": "result",
  "duration_ms": 12345,
  "num_turns": 5,
  "cost_usd": 0.042,
  "is_error": false
}
```

| Field         | Type    | Description                                     |
|---------------|---------|-------------------------------------------------|
| `duration_ms` | integer | Wall-clock session duration in milliseconds      |
| `num_turns`   | integer | Number of LLM turns (assistant messages)         |
| `cost_usd`    | float   | Estimated API cost in USD                        |
| `is_error`    | boolean | Whether the session ended due to an error        |

### `error`

Reports an error.  May be followed by a `result` with `is_error: true`, or
may be a standalone protocol error (e.g., malformed input).

```json
{
  "type": "error",
  "message": "Session timeout after 300s"
}
```

| Field     | Type   | Description               |
|-----------|--------|---------------------------|
| `message` | string | Human-readable error text |

---

## Error Handling

| Condition                   | Behavior                                              |
|-----------------------------|-------------------------------------------------------|
| Malformed JSON on stdin     | Log to stderr, send `error` on stdout, continue       |
| Unknown message type        | Log to stderr, send `error` on stdout, continue       |
| `prompt` before `start`    | Send `error` on stdout, continue waiting for `start`  |
| Empty prompt content        | Send `error` on stdout, continue                      |
| SDK session exception       | Send `error` + `result` (is_error=true) on stdout     |
| Stdin EOF                   | Treat as shutdown, exit cleanly                        |
| SIGTERM                     | Finish active work, exit cleanly                       |

---

## SDK Configuration Mapping

The `start` message fields map to Claude Agent SDK options:

| Protocol Field        | SDK Option          | Notes                                    |
|-----------------------|---------------------|------------------------------------------|
| `agent.tools`         | `allowed_tools`     | Hard boundary -- SDK rejects unlisted tools |
| `agent.system_prompt` | `system_prompt`     | Appended to `claude_code` preset         |
| `agent.model`         | `model`             | Full model ID or short name              |
| `agent.max_turns`     | `max_turns`         | Prevents runaway loops                   |
| `agent.cwd`           | `cwd`               | Working directory for tool execution     |
| (implicit)            | `permission_mode`   | Always `"acceptEdits"` for autonomous ops |

---

## Implementation Files

| File                        | Language | Purpose                            |
|-----------------------------|----------|------------------------------------|
| `runtime/agent_runner.py`   | Python   | Main runner script (PEP 723)       |
| `runtime/protocol.py`       | Python   | Message types and emitter functions |
| `lib/tri_onyx/agent_port.ex` | Elixir | GenServer wrapping the Elixir Port |
