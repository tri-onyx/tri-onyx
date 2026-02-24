# Agent Runtime

## Overview

The agent runtime is the execution layer that the gateway uses to drive LLM
sessions. TriOnyx uses the **Claude Agent SDK** (`claude-agent-sdk`) as
its runtime — a Python library that provides a streaming, tool-aware interface
to Claude models. The gateway invokes this runtime for each agent session,
enforcing the agent definition as hard constraints on the SDK configuration.

The runtime is not agentic itself. It is a controlled loop: send a prompt,
stream responses, intercept tool requests, execute approved tools, feed
results back, repeat until done.

---

## Runtime Stack

- **Language:** Python (>=3.11)
- **Package manager:** UV — handles dependency resolution and virtual environments
- **LLM interface:** `claude-agent-sdk` — async streaming agent loop
- **Authentication:** `CLAUDE_CODE_OAUTH_TOKEN` environment variable, read
  automatically by the SDK

---

## Agent Execution Lifecycle

When the gateway spawns an agent, it translates the agent definition into
SDK configuration and runs the agent loop:

### 1. Configuration

The gateway reads the agent definition file and constructs `ClaudeAgentOptions`:

```python
from claude_agent_sdk import ClaudeAgentOptions

options = ClaudeAgentOptions(
    cwd=working_directory,
    system_prompt={
        "type": "preset",
        "preset": "claude_code",
        "append": agent_definition.system_prompt,
    },
    allowed_tools=agent_definition.tools,   # Hard boundary from definition
    permission_mode="acceptEdits",          # Non-interactive execution
    max_turns=agent_definition.max_turns,   # Prevent runaway loops
    setting_sources=None,                   # Ignore local user settings
)
```

Key constraints enforced at this stage:

- **`allowed_tools`** — only the tools declared in the agent definition.
  The SDK will not execute any tool not in this list.
- **`permission_mode="acceptEdits"`** — required for autonomous operation.
  No human-in-the-loop prompts during execution.
- **`setting_sources=None`** — prevents local Claude settings from overriding
  the gateway's configuration. The agent definition is the sole authority.

### 2. Invocation

The gateway creates a persistent client that maintains conversation context
across the entire session, then sends prompts and streams the responses:

```python
from claude_agent_sdk import ClaudeSDKClient, AssistantMessage, ResultMessage
from claude_agent_sdk import TextBlock, ToolUseBlock, UserMessage, ToolResultBlock

# Create a persistent client that maintains conversation context
client = ClaudeSDKClient(options=options)
await client.connect()

# Send a prompt and stream the response
await client.query(prompt=prompt)
async for message in client.receive_response():
    if isinstance(message, AssistantMessage):
        for block in message.content:
            if isinstance(block, TextBlock):
                # Agent reasoning / response text
                gateway.log_text(agent_id, block)
            elif isinstance(block, ToolUseBlock):
                # Agent requested a tool — the SDK executes it
                # (only if in allowed_tools)
                gateway.log_tool_use(agent_id, block)
    elif isinstance(message, UserMessage):
        # Tool results come back in UserMessage
        for block in message.content:
            if isinstance(block, ToolResultBlock):
                # Gateway tracks taint based on tool results
                gateway.log_tool_result(agent_id, block)
    elif isinstance(message, ResultMessage):
        # Single turn complete; client remains connected for next prompt
        gateway.log_result(agent_id, message)
        break
```

### 3. Tool Execution

During each agent turn, the LLM may request tool calls (Read, Write, Bash,
etc.). The flow is:

1. LLM emits a `ToolUseBlock` requesting a specific tool with parameters
2. The SDK checks the tool against `allowed_tools` — rejects if not listed
3. If allowed, the SDK executes the tool and captures the result
4. The result is fed back into the LLM context as a `UserMessage` with
   `ToolResultBlock` — the persistent client handles this automatically
5. The LLM continues reasoning with the new information within the same turn

The gateway observes this loop (via streamed events) to add its own enforcement
layer: taint tracking (marking the session as tainted if a tool returns
untrusted external data) and logging (recording every tool call and result
for auditability).

### 4. Completion

The agent loop ends when:

- The LLM produces a final response with no further tool calls
- The `max_turns` limit is reached
- An error occurs (logged and surfaced to the gateway)

The gateway captures the `ResultMessage` which includes execution metadata
(duration, token usage, turn count) and records the full session transcript.

---

## Inline Script Pattern

Agent scripts can be self-contained using PEP 723 inline script metadata,
allowing UV to resolve dependencies without a separate project configuration:

```python
# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "claude-agent-sdk",
# ]
# ///
```

Execution:
```bash
uv run agent_script.py
```

UV automatically creates an isolated environment, installs dependencies, and
runs the script. This pattern keeps agents portable and self-describing.

---

## Relationship to the Gateway

The agent runtime is a **subprocess** of the gateway. The gateway:

1. Reads the agent definition (markdown file with frontmatter)
2. Translates it into `ClaudeAgentOptions`
3. Spawns an async Python process using `uv run`
4. Streams and logs all messages from the agent loop
5. Tracks taint based on tool results and input sources
6. Records the full transcript on completion

The runtime has no awareness of security policy, taint, or risk scoring.
It simply executes the loop with the constraints it was given. All security
logic lives in the gateway.
