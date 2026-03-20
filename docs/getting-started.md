# Getting Started

This guide walks you through setting up a working TriOnyx instance from a fresh clone. By the end you'll have the gateway, an agent, and a chat connector running locally.

---

## Prerequisites

- **Docker** with Compose v2 (`docker compose`)
- **Go 1.22+** (for compiling the FUSE driver)
- **UV** ([astral.sh/uv](https://docs.astral.sh/uv/)) — Python package manager used throughout the project
- **Git**
- A **Claude API key** or OAuth token (from [console.anthropic.com](https://console.anthropic.com))
- A **Matrix account** for the bot (see [Matrix Setup](matrix-guide.md) for details), or a **Slack workspace** with a bot app

!!! warning "Linux recommended"
    The FUSE driver requires `/dev/fuse`, which is available natively on Linux. macOS works for gateway and connector development but cannot run agent containers with FUSE sandboxing without a Linux VM.

---

## 1. Clone and bootstrap

```bash
git clone https://github.com/anthropics/TriOnyx.git
cd TriOnyx
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

# Workspace (agent definitions, personality, directory structure)
cp -r workspace.template/ workspace/
```

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

Each room maps to an agent by name. The agent name must match a file in `workspace/agent-definitions/` (without the `.md` extension).

---

## 3. Set up the workspace

The workspace template gives you the full set of agent definitions and an empty directory structure. Customize it for your setup:

### Personality (optional)

The `workspace/personality/` directory shapes how your agents communicate. Edit these files to set the tone:

- **`SOUL.md`** — Core behavioral principles and communication style
- **`IDENTITY.md`** — Agent name, role description, and how it introduces itself
- **`USER.md`** — User profile and preferences (your name, working style)
- **`MEMORY.md`** — Persistent personality memory, populated over time by agents

These files are read by agents that have `personality` in their `fs_read` paths. You can leave them as-is to start with the defaults.

### Agent definitions

The template includes all built-in agent definitions in `workspace/agent-definitions/`. Each is a markdown file with YAML frontmatter:

```markdown
---
name: main
model: claude-sonnet-4-6
tools: Read, Write, Edit, Bash, Grep, Glob
network: none
fs_read:
  - "/code/**"
fs_write:
  - "/code/**"
---

You are the main agent. Handle general tasks...
```

You can start with just the `main.md` agent and add more as needed. Remove any agent definitions you don't plan to use.

### Agent runtime directories

When an agent runs for the first time, the gateway creates a runtime directory under `workspace/agents/<name>/` with:

- `HEARTBEAT.md` — Agent status, updated periodically
- `memory/` — Persistent memory files
- `TODO.md` — Agent task list

These are created automatically — you don't need to set them up manually.

---

## 4. Build images

### FUSE driver

The agent image requires a pre-compiled FUSE binary. Build it inside a Go container:

```bash
docker run --rm -v $(pwd)/fuse:/src -w /src golang:1.22 \
  go build -o tri-onyx-fs ./cmd/tri-onyx-fs
```

This produces `fuse/tri-onyx-fs`, which gets copied into the agent image.

### Docker images

```bash
# Gateway (Elixir/OTP)
docker build -f gateway.Dockerfile -t tri-onyx-gateway:latest .

# Agent runtime (Python + FUSE sandbox)
docker build --build-arg HOST_UID=$(id -u) --build-arg HOST_GID=$(id -g) \
  -f agent.Dockerfile -t tri-onyx-agent:latest .

# Connector (Python, chat bridge)
docker build -f connector.Dockerfile -t connector:latest .
```

The agent image passes your host UID/GID so bind-mounted files have correct ownership.

---

## 5. Start the system

```bash
docker compose up
```

This starts the gateway and connector. The gateway spawns agent containers on demand when messages arrive.

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
  -d '{"text": "Hello, can you see this?"}'
```

Watch the gateway logs for the agent session lifecycle:

```
docker compose logs -f gateway
```

### End-to-end test harness

For scripted testing:

```bash
uv run scripts/test-agent.py --agent main --prompt "What tools do you have access to?"
```

---

## 7. Web dashboard

The gateway serves a web UI at [http://localhost:4000](http://localhost:4000):

- **`/`** — Agent overview and control panel
- **`/graph`** — Real-time agent topology with taint/sensitivity visualization
- **`/matrix`** — Classification matrix (taint, sensitivity, capability levels)
- **`/logs`** — Session log browser

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
    - Check that `fuse/tri-onyx-fs` exists and was compiled for Linux (not macOS)
    - Ensure Docker has access to `/dev/fuse`: `ls -la /dev/fuse`
    - Verify `HOST_UID`/`HOST_GID` match your user: `id -u && id -g`

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

- [Matrix Setup](matrix-guide.md) — Detailed chat connector configuration
- [Agent Runtime](agent-runtime.md) — How agent sessions work
- [Plugins](plugins.md) — Install and manage agent plugins
- [BCP Protocol](bcp.md) — How agents communicate across trust boundaries
- [Browser Sessions](browser-sessions.md) — Give agents persistent browser access
