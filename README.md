# TriOnyx

[![Elixir](https://img.shields.io/badge/Elixir-OTP-4B275F?logo=elixir&logoColor=white)](https://elixir-lang.org)
[![Python](https://img.shields.io/badge/Python-Agent_Runtime-3776AB?logo=python&logoColor=white)](https://python.org)
[![Go](https://img.shields.io/badge/Go-FUSE_Driver-00ADD8?logo=go&logoColor=white)](https://go.dev)
[![Docker](https://img.shields.io/badge/Docker-Containerized-2496ED?logo=docker&logoColor=white)](https://docker.com)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

**Track what agents see, not just what they do.**

A security-first agent runtime that tracks **information flow** between isolated LLM agents. Taint tracking, sensitivity labels, and bandwidth-constrained communication — built on Elixir/OTP for a single operator running their own agents.

<p>
  <a href="https://tri-onyx.com"><strong>Documentation</strong></a>&nbsp;&nbsp;|&nbsp;&nbsp;<a href="https://tri-onyx.com/getting-started/"><strong>Getting Started</strong></a>&nbsp;&nbsp;|&nbsp;&nbsp;<a href="https://tri-onyx.com/api-reference/"><strong>API Reference</strong></a>
</p>

---

## The lethal trifecta

The term comes from [Simon Willison's "The Lethal Trifecta"](https://simonwillison.net/2025/Jun/16/the-lethal-trifecta/) — the observation that AI agents become critically dangerous when they combine access to private data, exposure to untrusted content, and the ability to communicate externally. TriOnyx was built to address this directly.

Other agent runtimes sandbox **capability** — restrict filesystem, disable shell, limit network. This misses the point. The real danger isn't any single property. It's the combination of three:

> **Untrusted content** — Web pages, emails, API responses — any of which can carry prompt injections.
>
> **x Sensitive information** — Credentials, private files, internal APIs — things an attacker wants to reach.
>
> **x Capabilities** — Shell access, file writes, inter-agent messaging — tools to act on a hijacked context.
>
> **= High-risk agent** — TriOnyx tracks **information**, not just capability — blocking tainted data from reaching sensitive resources.

---

## Features

- **Isolated containers** — each agent runs in its own Docker container with a per-agent FUSE filesystem, network rules, and no shared state
- **Taint tracking** — Biba integrity model tracks what each agent has been exposed to
- **Sensitivity labels** — Bell-LaPadula confidentiality tracks access to secrets and private data
- **Information flow enforcement** — the gateway intercepts all inter-agent messages and blocks policy violations
- **Bandwidth-Constrained Protocol** — tainted agents communicate with clean agents through structured, human-approvable formats
- **FUSE filesystem** — custom Go driver enforces per-file read/write policies with O(1) path-trie lookups
- **Browser sessions** — headless Chromium with persistent login sessions from the host
- **Plugin system** — reusable agent extensions installable from git repos
- **Auditable everything** — structured logs for file access, tool calls, message routing, and policy violations

![Agent topology showing taint and sensitivity propagation](docs/agent-graph.png)

---

## Architecture

```
            External Triggers (webhooks, chat, cron, email)
                            |
                            v
+----------------------------------------------+
|             Elixir/OTP Gateway               |
|  Non-agentic. No LLM. Deterministic policy.  |
+-------------+----------------+---------------+
              |                |
              v                v
+---------------+  +---------------+     +-------------+
| Agent A       |  | Agent B       |     | Connector   |
| Python+Claude |  | Python+Claude |     | Matrix      |
| FUSE (Go)     |  | FUSE (Go)     |     +-------------+
+---------------+  +---------------+
```

See the [full architecture docs](https://tri-onyx.com/agent-runtime/) for details.

---

## Quick start

### Prerequisites

- Docker

### Build

```bash
# Gateway image (Elixir/OTP)
docker build -f gateway.Dockerfile -t tri-onyx-gateway:latest .

# Agent runtime image (Python + FUSE sandbox)
docker build -f agent.Dockerfile -t tri-onyx-agent:latest .

# Connector image (Python, for Matrix chat bridge)
docker build -f connector.Dockerfile -t connector:latest .
```

The agent image requires a pre-built FUSE driver binary at `fuse/tri-onyx-fs`. See [FUSE Driver](https://tri-onyx.com/fuse-driver-spec/) for build instructions.

### Run

```bash
docker compose up
```

### Test

```bash
# Elixir gateway tests
docker run --rm -v $(pwd):/app -w /app tri-onyx-gateway:latest mix test

# Go FUSE driver tests
docker run --rm --device /dev/fuse --cap-add SYS_ADMIN \
  --security-opt apparmor=unconfined \
  -v $(pwd)/fuse:/src -w /src golang:1.22 \
  bash -c "apt-get update -qq && apt-get install -y -qq fuse3 2>/dev/null && go test ./..."

# Python connector tests
docker run --rm -v $(pwd)/connector:/app -w /app connector:latest uv run pytest
```

---

## Agent definitions

Agents are defined as markdown files with YAML frontmatter in `workspace/agent-definitions/`:

```markdown
---
name: code-reviewer
description: Reviews code for quality, security, and style
model: claude-sonnet-4-20250514
tools: Read, Grep, Glob
network: none
fs_read:
  - /workspace/repo/src/**/*
  - /workspace/repo/tests/**/*
skills: code-review-standards, security-checklist
browser: false
---

You are a code reviewer. Analyze the code at /workspace/repo/src and
provide feedback on quality, security issues, and style.
```

The frontmatter declares permissions (tools, filesystem access, network policy, browser access). The body is the system prompt. The gateway translates these into Docker container configuration, FUSE policy, and iptables rules.

---

## Documentation

Full documentation is available at **[tri-onyx.com](https://tri-onyx.com)**:

- [Getting Started](https://tri-onyx.com/getting-started/) — complete walkthrough from clone to running agents
- [Security Model](adr/SECURITY_MODEL.md) — three-axis risk model, enforcement layers, violation detection
- [Bandwidth-Constrained Protocol](https://tri-onyx.com/bcp/) — how tainted agents communicate safely
- [Browser Sessions](https://tri-onyx.com/browser-sessions/) — persistent browser sessions for agents
- [Plugins](https://tri-onyx.com/plugins/) — plugin system and management
- [API Reference](https://tri-onyx.com/api-reference/) — full HTTP API documentation
- [Web Dashboard](https://tri-onyx.com/web-dashboard/) — monitoring and management UI
- [Comparison with OpenClaw](https://tri-onyx.com/comparison/) — detailed side-by-side
- [Architecture Decisions](https://tri-onyx.com/decisions/) — ADRs 001-010
- [Project Structure](https://tri-onyx.com/project-structure/) — full source tree reference
