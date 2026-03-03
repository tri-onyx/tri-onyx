# Plugins

Plugins extend agents with reusable skills, commands, agents, hooks, and MCP
servers. They live in `workspace/plugins/` and are managed with the plugin CLI
(`scripts/tri-onyx-plugin.py`).

---

## How plugins reach agents

1. **Agent definition** declares plugins in frontmatter:
   ```yaml
   plugins:
     - newsagg
   ```

2. **Gateway** (`sandbox.ex`) adds FUSE read paths for each plugin:
   - `/plugins/` (parent directory, for readdir)
   - `/plugins/<name>/**` (all files in the plugin)

3. **Agent runner** passes plugin paths to the Claude Agent SDK:
   ```python
   plugins=[{"type": "local", "path": "/workspace/plugins/newsagg"}]
   ```

4. **SDK** passes `--plugin-dir /workspace/plugins/newsagg` to the bundled
   Claude Code CLI, which discovers the plugin manifest and registers
   components (skills, commands, hooks, etc.).

5. **Skill invocations** use the `/<plugin>:<skill>` syntax (e.g.,
   `/newsagg:fetchnews`). The CLI expands the skill's `SKILL.md` into the
   prompt and sends it to the model.

---

## Plugin directory structure

Each plugin follows the Claude Code plugin convention:

```
newsagg/
├── .claude-plugin/
│   └── plugin.json          # Plugin manifest (name is required)
├── skills/                  # Auto-discovered by convention
│   └── fetchnews/
│       └── SKILL.md         # Skill definition
├── commands/                # Slash commands (optional)
├── agents/                  # Subagent definitions (optional)
├── hooks/                   # Event handlers (optional)
│   └── hooks.json
├── .mcp.json                # MCP servers (optional)
└── ...                      # Plugin-specific files
```

### plugin.json

Minimal manifest — only `name` is required:

```json
{
  "name": "newsagg",
  "description": "News aggregation and formatting plugin",
  "version": "0.2.0"
}
```

Component directories (`skills/`, `commands/`, `agents/`, `hooks/`) are
auto-discovered at their default locations. You only need to declare them in
`plugin.json` if they live at non-standard paths.

---

## Path rules (important)

The Claude Code CLI enforces strict path rules for plugin manifests:

- **All custom paths must start with `./`** — relative to the plugin root.
  Paths starting with `../` are invalid and will cause the CLI to silently
  fail to load the plugin.
- **Default directories are auto-discovered** — `skills/`, `commands/`,
  `agents/`, `hooks/` don't need to be declared in `plugin.json`.
- **Custom paths supplement defaults** — declaring a custom `skills` path
  adds to the default `skills/` directory, it doesn't replace it.

**Example of what NOT to do:**

```json
{
  "name": "newsagg",
  "skills": "../skills/"
}
```

This fails silently because `../skills/` doesn't start with `./`. Since
`skills/` is auto-discovered anyway, the fix is to omit the field entirely.

---

## Gateway: system command handling

Messages starting with `/` are intercepted by the gateway's `SystemCommand`
module before reaching agents. Known commands (e.g., `/restart`) are executed
directly. Unknown commands return an error.

**Skill invocations** use colons (`/newsagg:fetchnews`) to distinguish
themselves from system commands. The parser detects the `:` and passes the
message through to the agent instead of intercepting it:

```elixir
# system_command.ex — parse/1
:error ->
  if String.contains?(name, ":") do
    :not_a_command        # Skill — pass through to agent
  else
    {:command, :unknown, ["/" <> name]}  # Unknown system command — error
  end
```

---

## Debugging plugin loading

If a skill invocation returns 0 turns, check these in order:

1. **Is the plugin loaded?** Look at the SDK `SystemMessage` init data in
   container logs. The `plugins` array should contain your plugin, and
   `slash_commands` should list `<plugin>:<skill>`.

2. **Is the manifest valid?** Ensure `.claude-plugin/plugin.json` has valid
   JSON and no paths starting with `../`.

3. **Is the FUSE policy correct?** The agent definition must list the plugin
   in `plugins:`. Check that `/plugins/<name>/**` appears in the FUSE read
   policy (`/etc/tri_onyx/fs-policy.json` inside the container).

4. **Is the gateway passing the message through?** Messages with `:` in the
   command name should reach the agent. Check gateway logs if the agent
   never receives the prompt.

5. **Check container logs directly:**
   ```bash
   docker logs <container-name> 2>&1 | grep -i "plugin\|skill\|denied"
   ```
   Unhandled SDK message types (including `SystemMessage`) are logged as
   warnings by the agent runner.

---

## Managing plugins

```bash
# Install a plugin from a git repo
uv run scripts/tri-onyx-plugin.py add <git-url> [--name NAME]

# List installed plugins
uv run scripts/tri-onyx-plugin.py list

# Upgrade a plugin
uv run scripts/tri-onyx-plugin.py upgrade <name>

# Remove a plugin
uv run scripts/tri-onyx-plugin.py remove <name>
```

Plugin metadata is recorded in `workspace/plugins.yaml`. When installed from
git, the `.git/` directory is stripped so files become mutable workspace
content.
