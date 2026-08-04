# Getting Started

This guide walks you through setting up a working TriOnyx instance from a fresh clone. By the end you'll have the gateway, an agent, and a chat connector running locally.

---

## Prerequisites

- **Docker** with Compose v2 (`docker compose`)
- **UV** ([astral.sh/uv](https://docs.astral.sh/uv/)) — Python package manager used throughout the project
- **Git**
- A **Claude API key** or OAuth token (from [console.anthropic.com](https://console.anthropic.com))
- A **Matrix account** for the bot (see [Matrix Setup](matrix-guide.md) for details), or a **Slack workspace** with a bot app

---

## 1. Clone and bootstrap

```bash
git clone https://github.com/tri-onyx/tri-onyx.git
cd tri-onyx
```

### Install git hooks

The pre-commit hook runs [gitleaks](https://github.com/gitleaks/gitleaks) to scan for secrets and warns about stale templates:

```bash
brew install gitleaks           # secret scanner
bash scripts/install-hooks.sh   # install pre-commit hook
```

See [Secret Management](secrets.md) for details on how secrets are protected.

### Copy templates

The repository ships template files with placeholder values. Copy them and fill in your secrets:

```bash
# Environment variables
cp .env.example .env

# Connector configuration (Matrix/Slack room mappings)
mkdir -p secrets
cp secrets/connector-config.yaml.example secrets/connector-config.yaml
```

You do **not** need to copy `workspace.template/` by hand. On first start the
gateway seeds the workspace automatically (`Workspace.ensure_initialized`),
creating the shared `core` (AGENTS.md + personality) and `definitions` (agent
definitions) git repos from the template.

!!! tip "Secrets are safe"
    The `.env` and `secrets/` directory are gitignored — your secrets will never be committed.

---

## 2. Configure secrets

### `.env`

Open `.env` and fill in the required values:

```bash
# Required — Claude API access for agents
CLAUDE_CODE_OAUTH_TOKEN=your-oauth-token-here

# Required — shared secret between gateway and connector
# Generate one: openssl rand -hex 32
TRI_ONYX_CONNECTOR_TOKEN=your-generated-token

# Required if using Matrix
MATRIX_ACCESS_TOKEN=your-matrix-access-token
```

See [Matrix Setup](matrix-guide.md) for how to obtain a Matrix access token, or [Email Setup](email-setup.md) for email connector credentials.

For Slack, set:

```bash
SLACK_BOT_TOKEN=xoxb-your-bot-token
SLACK_APP_TOKEN=xapp-your-app-token
SLACK_OWNER_USER_ID=U-your-user-id
```

### `secrets/connector-config.yaml`

This file maps chat rooms to agents. Open it and configure your adapter:

```yaml
gateway:
  url: "ws://gateway:4000/connectors/ws"
  connector_id: "matrix-home"
  token: "<your-secret-here>"    # must match TRI_ONYX_CONNECTOR_TOKEN

adapters:
  matrix:
    enabled: true
    homeserver: "https://matrix.org"
    user_id: "@your-bot:matrix.org"
    access_token: "<your-matrix-access-token>"
    device_id: "TRI-ONYX-01"
    store_path: "/data/matrix"
    trusted_users:
      - "@your-user:matrix.org"
    rooms:
      "!your-room-id:matrix.org":
        agent: "main"
        mode: "mention"
        merge_window_ms: 3000
        show_steps: true
```

Each room maps to an agent by name. The agent name must match a definition file in the `definitions` repo (without the `.md` extension).

---

## 3. Set up the workspace

The workspace is a set of **git repositories** managed by the gateway. On first start it seeds two shared repos from `workspace.template/`: `core` (AGENTS.md + personality) and `definitions` (agent definition files). On the host they live under `workspace/bare/` (bare repos, the source of truth) with gateway-managed working trees under `workspace/trees/`. Customize them for your setup:

### Personality (optional)

The personality files in the `core` repo shape how your agents communicate. Edit these files to set the tone:

- **`SOUL.md`** — Core behavioral principles and communication style
- **`IDENTITY.md`** — Agent name, role description, and how it introduces itself
- **`USER.md`** — User profile and preferences (auto-generated from session logs)

These files are read by agents that have `core` in their `repos_read` list. You can leave them as-is to start with the defaults.

### Agent definitions

The template includes all built-in agent definitions, seeded into the `definitions` repo. Each is a markdown file with YAML frontmatter:

```markdown
---
name: main
model: claude-sonnet-4-6
tools: Read, Write, Edit, Bash, Grep, Glob
network: none
repos_read:
  - core
  - knowledge
repos_write:
  - knowledge
---

You are the main agent. Handle general tasks...
```

Each agent's own repo is always mounted read-write at `/workspace` (its working directory) — no frontmatter needed for that. `repos_read`/`repos_write` mount additional repos at `/repos/<name>`: shared repo names (`core`, `definitions`, `knowledge`), another agent's repo (`agents/<name>`), or the wildcard `agents/*`.

You can start with just the `main.md` agent and add more as needed. Remove any agent definitions you don't plan to use.

### Agent repos

When an agent runs for the first time, the gateway creates a git repo for it. Inside the container it is mounted at `/workspace` and holds the agent's persistent state:

- `/workspace/HEARTBEAT.md` — Agent status, updated periodically
- `/workspace/NOTES.md` — Agent notes
- `/workspace/memory/<date>.md` — Persistent memory files
- `/workspace/reflections/` — Reflection output

These are created automatically — you don't need to set them up manually. Working trees contain no `.git`; the gateway commits each session's changes (with taint/sensitivity provenance trailers) and pushes them to the bare repo at session end.

---

## 4. Build images

```bash
# Gateway (Elixir/OTP)
docker build -f gateway.Dockerfile -t tri-onyx-gateway:latest .

# Agent runtime (Python + Claude SDK)
docker build --build-arg HOST_UID=$(id -u) --build-arg HOST_GID=$(id -g) \
  -f agent.Dockerfile -t tri-onyx-agent:latest .

# Connector (Python, chat bridge)
docker build -f connector.Dockerfile -t trionyx-connector:latest .
```

The agent image passes your host UID/GID so bind-mounted files have correct ownership.

---

## 5. Start the system

```bash
docker compose up
```

This starts the gateway, connector, web frontend, and Docker socket proxy services. The gateway spawns agent containers on demand when messages arrive.

To run in the background:

```bash
docker compose up -d

# View logs
docker compose logs -f
docker compose logs -f gateway
docker compose logs -f connector
```

---

## 6. Verify it works

### Health check

```bash
curl http://localhost:4000/health
```

### List agents

```bash
curl http://localhost:4000/agents | python3 -m json.tool
```

You should see your agent definitions listed with their risk scores and status.

### Send a test message

If using Matrix, send a message in your mapped room (mention the bot if using `mode: mention`).

Or test directly via the API:

```bash
curl -X POST http://localhost:4000/agents/main/prompt \
  -H 'Content-Type: application/json' \
  -d '{"content": "Hello, can you see this?"}'
```

Watch the gateway logs for the agent session lifecycle:

```
docker compose logs -f gateway
```

### End-to-end test harness

For scripted testing:

```bash
uv run scripts/test-agent.py main "What tools do you have access to?"
```

---

## 7. Web dashboard

The `frontend` compose service serves a web UI at [http://127.0.0.1:8080](http://127.0.0.1:8080):

- **`/`** — Agent overview: session statuses, gateway health, pending approvals
- **`/graph/`** — Agent topology with taint/sensitivity risk analysis
- **`/builder/`** — Create and edit agent definitions
- **`/agents/<name>/`** — Per-agent chat: start sessions, send prompts, watch live output, browse session history

See [Web Dashboard](web-dashboard.md) for details. The gateway's HTTP API remains at `http://localhost:4000`.

---

## Keeping templates up to date

When you add new environment variables to `.env`, change connector config, or modify agent definitions, regenerate the templates so other contributors get the updates:

```bash
uv run scripts/generate-templates.py
```

The pre-commit hook will warn you if templates are stale. To check manually:

```bash
uv run scripts/generate-templates.py --check
```

---

## Troubleshooting

??? question "Agent container fails to start"
    - Verify `HOST_UID`/`HOST_GID` match your user: `id -u && id -g`
    - Check the gateway logs for mount errors — the gateway prepares each agent's working trees under `workspace/trees/` before starting the container

??? question "connector_token mismatch"
    `TRI_ONYX_CONNECTOR_TOKEN` must be identical in `.env` (read by both services via Docker Compose) and in `secrets/connector-config.yaml` under `gateway.token`.

??? question "Matrix sync fails"
    - Verify the homeserver URL is reachable from inside the container
    - Check that the access token hasn't expired (re-login to get a new one)
    - See [Matrix Setup](matrix-guide.md) for detailed troubleshooting

??? question "No response from agent"
    1. Check gateway logs: `docker compose logs gateway | tail -50`
    2. Check if the agent started: `curl http://localhost:4000/agents`
    3. Verify the room-to-agent mapping in `secrets/connector-config.yaml`
    4. Make sure `CLAUDE_CODE_OAUTH_TOKEN` is set and valid

---

## Next steps

- [Running as a Service](service-setup.md) — Run TriOnyx on boot with automatic restarts
- [Matrix Setup](matrix-guide.md) — Detailed chat connector configuration
- [Agent Runtime](agent-runtime.md) — How agent sessions work
- [Plugins](plugins.md) — Install and manage agent plugins
- [BCP Protocol](bcp.md) — How agents communicate across trust boundaries
- [Browser Sessions](browser-sessions.md) — Give agents persistent browser access
