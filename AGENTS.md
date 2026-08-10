# TriOnyx Agent Instructions

> **Note:** `CLAUDE.md` is a symlink to this file (`AGENTS.md`). Edit `AGENTS.md` directly.

## Workspace Directory

The `workspace/` directory is tracked by a separate git repository outside the scope of this project. Do not commit or push changes to files under `workspace/` in this repo.

## Destructive Actions

- **NEVER delete `.git` directories** — especially inside submodules or nested repos. Losing `.git` means losing all commit history, and if there is no upstream remote, that history is **unrecoverable**.
- **NEVER run `rm -rf` on directories you don't fully understand** — always ask the user before deleting anything that could contain irreplaceable data.
- **NEVER use `sudo`** — if a command requires elevated privileges, ask the user to run it themselves.
- When converting a submodule to regular files, only remove the index entry (`git rm --cached`) and stage the contents. Do not touch the `.git` directory inside it.

## Development Workflow

When building new features, follow these steps in order:

1. **Clarify requirements** — Use `AskUserQuestion` to confirm scope, approach, and any ambiguous details before writing code. Don't start implementing until the plan is agreed on.

2. **Build the feature** — Make code changes. Rebuild any affected images before moving on (see Container Rebuilds below).

3. **Run existing tests** — Always run the relevant test suite after making changes:
   - Elixir (gateway): `docker run --rm -v $(pwd):/app -w /app tri-onyx-gateway:latest mix test`
   - Python (connector): `docker run --rm -v $(pwd)/connector:/app -w /app trionyx-connector:latest uv run pytest`
   - Python (mcp server): `docker run --rm -v $(pwd)/mcp_server/mcp_server:/app/mcp_server:ro -v $(pwd)/mcp_server/tests:/app/tests:ro -v $(pwd)/connector/connector:/app/connector:ro -w /app trionyx-mcp:latest uv run --no-sync pytest -q`

4. **Rebuild images and restart containers** — Before running end-to-end tests, rebuild any affected images and restart containers so the latest code is running (see Container Rebuilds below).

5. **Run end-to-end tests** — If the feature touches the agent runtime, connector, or gateway communication, run a live end-to-end test using the test-agent harness:
   ```
   uv run scripts/test-agent.py <agent-name> "<test prompt>"
   ```
   Check that tool calls, results, and Matrix output all look correct.

## Testing

- **Always run tests inside Docker containers** — never run mix or python tests directly on the host
- Elixir tests: `docker run --rm -v $(pwd):/app -w /app tri-onyx-gateway:latest mix test`

## Per-Agent Repos (`TriOnyx.RepoStore`)

Every filesystem boundary is a git repository — there is no FUSE layer and no path-glob policy. **The mount set is the ACL.**

- Each agent owns a repo (bare at `workspace/bare/agents/<name>.git`) mounted read-write at `/workspace` in its container (its cwd). Shared repos (`core`, `definitions`, `knowledge`, ...) mount under `/repos/<name>` — rw for `repos_write` grants (the agent gets its own clone, synced through the bare repo at session boundaries), ro for `repos_read` grants (a shared `_ro` checkout of last-committed state).
- **Gateway-only git**: no working tree contains `.git`; all git runs with explicit `--git-dir`/`--work-tree` from the gateway, so history is untamperable from inside a container.
- **Session protocol**: trees are fast-forwarded before the container starts (`RepoStore.prepare_session/1`) and committed + pushed at session end (`Workspace.commit_session/4`) with `Taint-Level`/`Sensitivity-Level` trailers. Push conflicts on shared repos are parked on `conflict/<agent>/<session>` branches — main stays clean, nothing is lost.
- **Tree ownership**: the gateway checks trees out as root, but agent containers run as `tri_onyx` (= `TRI_ONYX_HOST_UID`, default 1000, must match the agent image's `HOST_UID` build arg). `sync_tree/2` chowns every rw agent tree to that uid after each sync, so agents can write their mounts; `_ro`/`_gw` trees stay gateway-owned.
- The risk manifest keys files by canonical path: `agents/<name>/<path>` or `shared/<name>/<path>`.

## Container Rebuilds

- **Always rebuild containers after making changes** that affect baked-in artifacts
- The `runtime/` directory (including `agent_runner.py`, `protocol.py`, `entrypoint.sh`) is bind-mounted read-only at `/opt/tri_onyx`, so **Python/runtime changes take effect on next container start without rebuilding**. Only rebuild the agent image if `agent.Dockerfile` changes:
  `docker build --no-cache --build-arg HOST_UID=$(id -u) --build-arg HOST_GID=$(id -g) -t tri-onyx-agent:latest -f agent.Dockerfile .`
- The gateway image (`tri-onyx-gateway`) mounts Elixir source at runtime, so it only needs rebuilding if `gateway.Dockerfile` itself changes:
  `docker build -t tri-onyx-gateway:latest -f gateway.Dockerfile .`
- After rebuilding, restart any running containers to pick up the new image
- For runtime-only changes (Python files under `runtime/`), just restart the agent container — no rebuild needed

## Gateway Management Commands

The gateway runs as a named Erlang node (`gateway`), enabling remote evaluation of Elixir expressions from inside the container. This is useful for triggering internal operations that don't have HTTP endpoints (e.g., reflection runs, scheduler inspection).

```bash
# General pattern — replace HOSTNAME, Module, :function, and [args].
# ERL_AFLAGS= clears the container-level flags so the admin node gets its own name.
docker exec -e ERL_AFLAGS= trionyx-gateway-1 \
  elixir --sname admin --cookie trionyx -e \
  ':rpc.call(:"gateway@HOSTNAME", Module, :function, [args]) |> IO.inspect()'

# Get the current hostname (changes on every container recreate)
docker exec trionyx-gateway-1 hostname
```

Modules whose public functions take the server name as their first argument (`TriggerRouter`, `AgentSupervisor`, `Scheduler`, `ApprovalQueue`, `WebhookRegistry`) require the module name as the first RPC argument. Modules whose public API is plain functions (`SessionLogger` — a GenServer internally, but its query functions don't take a server name — and `AgentLoader`) do not.

### Agent management

```bash
# List registered agent names
:rpc.call(N, TriOnyx.TriggerRouter, :list_agents, [TriOnyx.TriggerRouter])
|> Enum.map(& &1.name)

# Get a specific agent definition
:rpc.call(N, TriOnyx.TriggerRouter, :get_agent, [TriOnyx.TriggerRouter, "main"])

# Reload definitions from disk (returns {:ok, count})
:rpc.call(N, TriOnyx.TriggerRouter, :load_agents, [TriOnyx.TriggerRouter])
```

### Sessions

```bash
# List active sessions with name and status
:rpc.call(N, TriOnyx.AgentSupervisor, :list_sessions, [TriOnyx.AgentSupervisor])
|> Enum.map(fn s -> {s.definition.name, s.status} end)

# Count active sessions
:rpc.call(N, TriOnyx.AgentSupervisor, :count_sessions, [TriOnyx.AgentSupervisor])
```

### Triggers and scheduling

```bash
# Trigger a reflection run for an agent
:rpc.call(N, TriOnyx.TriggerRouter, :dispatch_reflection, [TriOnyx.TriggerRouter, "main"])

# List heartbeat schedules
:rpc.call(N, TriOnyx.Triggers.Scheduler, :list_heartbeats, [TriOnyx.Triggers.Scheduler])

# List reflection jobs
:rpc.call(N, TriOnyx.Triggers.Scheduler, :list_reflections, [TriOnyx.Triggers.Scheduler])

# Check/toggle global heartbeat dispatch
:rpc.call(N, TriOnyx.Triggers.Scheduler, :enabled?, [TriOnyx.Triggers.Scheduler])
:rpc.call(N, TriOnyx.Triggers.Scheduler, :set_enabled, [TriOnyx.Triggers.Scheduler, false])
```

### Logs

```bash
# List agents that have log directories
:rpc.call(N, TriOnyx.SessionLogger, :list_agents, [])

# List session log files for an agent
:rpc.call(N, TriOnyx.SessionLogger, :list_sessions, ["main"])
```

### Approvals

```bash
# List pending approval items
:rpc.call(N, TriOnyx.BCP.ApprovalQueue, :list_pending, [TriOnyx.BCP.ApprovalQueue])
```

To run any of the above, wrap it in the full `docker exec` invocation shown in the general pattern. For example:

```bash
docker exec -e ERL_AFLAGS= trionyx-gateway-1 \
  elixir --sname admin --cookie trionyx -e \
  'n = :"gateway@'$(docker exec trionyx-gateway-1 hostname)'";
   :rpc.call(n, TriOnyx.TriggerRouter, :list_agents, [TriOnyx.TriggerRouter])
   |> Enum.map(& &1.name) |> IO.inspect()'
```

## Source of Truth

- **Never duplicate logic or data** across languages/files if it can be avoided. Duplication leads to silent drift across sessions.
- **Elixir is the source of truth** for risk model data (taint, sensitivity, capability matrices), tool metadata, agent definition schema, and agent configuration logic. When other languages (Python scripts, docs generators, the frontend, etc.) need this data, they must fetch it from the gateway at runtime (e.g., via API endpoints) or at build time (e.g., Mix task outputting JSON) — never maintain a parallel copy.
- **The frontend must never hardcode** lists of valid fields, tool names, model options, or enum values that the gateway already knows. Expose a schema/metadata endpoint from the gateway and have the frontend render dynamically from that response.

## Documentation

The docs site uses MkDocs Material and is served via Docker for local development:

```bash
# Start docs server (live-reload on file changes, serves at http://localhost:8000)
docker compose -f docker-compose.docs.yml up -d

# Stop
docker compose -f docker-compose.docs.yml down
```

- Source files are in `docs/`, config in `mkdocs.yml`, custom styles in `docs/stylesheets/extra.css`
- The volume mount means edits to any file under `docs/` or `mkdocs.yml` trigger an automatic reload — no container restart needed
- Use `uv run scripts/browser.py navigate http://localhost:8000/<path> --screenshot ./tmp/screenshot.png` to visually verify changes
- Agent docs in `docs/agents/` are auto-generated from definitions by CI — don't edit them by hand unless also updating the generator

## Browser Tool

- Use `uv run scripts/browser.py <command>` for browser automation and screenshots
- Subcommands: `navigate`, `click`, `fill`, `read`, `screenshot`, `list`, `wait`, `close`
- Uses accessibility-based locators (ARIA roles + names) to interact with the UI
- Examples:
  ```bash
  uv run scripts/browser.py navigate http://localhost:8080 --screenshot ./tmp/dash.png
  uv run scripts/browser.py click button "Start Session"
  uv run scripts/browser.py fill textbox "Message" "Hello"
  uv run scripts/browser.py list --role button
  ```
- Options: `-W 1920 -H 1080` for viewport size, `--wait networkidle` for load strategy
- Dependencies are managed inline via PEP 723 — no manual install needed

## Slack Log Tool

- Use `uv run scripts/slack-log.py <command>` to inspect what was actually posted
  in the Slack channels the TriOnyx bot is in (e.g. verifying agent output and
  inter-agent mirrors without screenshots)
- Subcommands:
  ```bash
  uv run scripts/slack-log.py channels                       # list bot channels
  uv run scripts/slack-log.py read trionyx-golden-path-docs  # recent history
  uv run scripts/slack-log.py read C0123ABCDEF -n 50         # by ID, more messages
  ```
- The bot token is taken from the running connector container's config (the
  authoritative source — the host `.env` copy has drifted before) and is never
  printed
- Note: Slack returns `>` as `&gt;` in raw history text; blockquotes render fine
  in the client

## Plugin System

Plugins are reusable agent extensions (e.g., newsagg, diary, bookmarks) that live in `workspace/plugins/`. Each plugin is a directory of files that agents can read/write via FUSE paths like `/plugins/<name>/**`.

Plugins are managed with the CLI tool:

```bash
uv run scripts/tri-onyx-plugin.py add <git-url> [--name NAME] [--ref TAG/BRANCH]
uv run scripts/tri-onyx-plugin.py upgrade <name>
uv run scripts/tri-onyx-plugin.py remove <name>
uv run scripts/tri-onyx-plugin.py list
```

When a plugin is installed from a git repo, its `.git/` directory is stripped so the files become mutable workspace content tracked by the workspace's own git repo. Plugin metadata is recorded in `workspace/plugins.yaml`.

## Temporary Files

- Always use local tmp directories within the project (e.g., `./tmp/`) instead of system-wide `/tmp/`
- Create temporary test directories under the project root for isolation and cleanup
- Example: `mkdir -p ./tmp/test-data` instead of `/tmp/test-data`
