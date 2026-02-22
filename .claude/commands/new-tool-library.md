# Create a new tool library

You are implementing a new tool library for TriOnyx. A tool library gives agents access to external capabilities (data sources, services, computations) through ordinary Python imports.

Read the architecture document first:

```
workspace/tool-library-architecture.md
```

Then implement all pieces for the new tool described below.

---

## Implementation checklist

### 1. Python tool library package

Create the package at `tool-libraries/<tool_name>/`:

```
tool-libraries/<tool_name>/
├── pyproject.toml
└── <tool_name>.py          (or <tool_name>/__init__.py for multi-module)
```

The `pyproject.toml` must declare `tri-onyx-tool-sdk` as a dependency. The library itself is thin — each public function delegates to `tri_onyx_tool_sdk.request()` with a tool name string and a params dict. The library contains **no transport logic**.

```python
# example: tool-libraries/customer_db/customer_db.py
from tri_onyx_tool_sdk import request

def query(sql: str) -> list[dict]:
    """Query the customer database."""
    return request("customer_db.query", {"sql": sql})
```

The tool name string follows the convention `<library_name>.<function_name>`.

### 2. Gateway handler (Elixir)

Create a handler module at `lib/tri_onyx/tool_libraries/<tool_name>.ex`.

This module receives `tool_library_request` events where `tool` starts with `"<tool_name>."` and returns a result. Pattern:

```elixir
defmodule TriOnyx.ToolLibraries.<ToolName> do
  @moduledoc "Gateway handler for the <tool_name> tool library."

  def handle(%{"tool" => "<tool_name>.<function>", "params" => params}) do
    # Fulfill the request — query a database, call an API, etc.
    # Return {:ok, result} or {:error, reason}
  end
end
```

Register the handler in `lib/tri_onyx/tool_libraries.ex` (the dispatcher that `AgentSession` delegates to).

### 3. ToolRegistry entry

Add an entry to `lib/tri_onyx/tool_registry.ex`:

- Add `"<ToolName>"` to `@known_tools`
- Add auth metadata to `@tool_meta` (`requires_auth: true` if the gateway needs credentials)
- Add a display entry to `@display_entries` for the Matrix classification UI

### 4. Taint and sensitivity classification

Add classification entries for the new tool in:

- `lib/tri_onyx/taint_matrix.ex` — what taint level do results from this tool carry?
- `lib/tri_onyx/sensitivity_matrix.ex` — what sensitivity level?

Consider: does this tool return external/untrusted data (high taint)? Does it expose confidential information (high sensitivity)?

### 5. Agent definition

Add the library to any agent that should use it. In the agent's YAML frontmatter:

```yaml
tool_libraries:
  - <tool_name>
```

This tells the gateway to install the library at container startup and make it importable.

### 6. Protocol types (if not already present)

If the shared `tool_library_request` / `tool_library_response` protocol types don't exist yet in `runtime/protocol.py`, add them. These are generic and shared across all tool libraries — they only need to be added once.

---

## What the tool should do

$ARGUMENTS

---

## Guidelines

- Keep the Python library as thin as possible. It is a typed wrapper around `tri_onyx_tool_sdk.request`, nothing more.
- All real work happens in the gateway handler. The library never makes network calls, database connections, or file I/O on its own.
- Follow existing patterns in the codebase — look at how `SendEmail` / `MoveEmail` / `CreateFolder` are implemented as gateway-mediated tools for reference.
- Run existing tests after making changes (see CLAUDE.md for test commands).
- If the shared infrastructure (SDK shim, socket server in agent_runner.py, protocol types) doesn't exist yet, implement that first before the tool-specific code.
