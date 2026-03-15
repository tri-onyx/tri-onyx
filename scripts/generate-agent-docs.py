# /// script
# requires-python = ">=3.11"
# dependencies = ["pyyaml"]
# ///
"""Generate MkDocs pages for each agent definition.

Reads workspace/agent-definitions/*.md, parses YAML frontmatter,
and writes docs/agents/<name>.md with a config table + system prompt.
Also generates docs/agents/index.md and updates the Agents nav section
in mkdocs.yml.

Usage:
    uv run scripts/generate-agent-docs.py
    uv run scripts/generate-agent-docs.py --check   # exits non-zero if stale
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
DEFINITIONS_DIR = ROOT / "workspace" / "agent-definitions"
OUTPUT_DIR = ROOT / "docs" / "agents"
MKDOCS_YML = ROOT / "mkdocs.yml"


def parse_definition(path: Path) -> tuple[dict, str]:
    """Parse a markdown file with YAML frontmatter into (meta, body)."""
    text = path.read_text()
    if not text.startswith("---"):
        raise ValueError(f"{path.name}: missing YAML frontmatter")
    _, frontmatter, body = text.split("---", 2)
    meta = yaml.safe_load(frontmatter)
    return meta, body.strip()


def format_network(network) -> str:
    if isinstance(network, list):
        return ", ".join(f"`{h}`" for h in network)
    return f"`{network}`"


def format_list(items: list[str]) -> str:
    if not items:
        return "*none*"
    return ", ".join(f"`{i}`" for i in items)


def format_bcp_channels(channels: list[dict]) -> str:
    if not channels:
        return ""
    lines = [
        "",
        "### BCP Channels",
        "",
        "| Peer | Role | Max Category | Budget (bits) |",
        "|------|------|:------------:|:-------------:|",
    ]
    for ch in channels:
        lines.append(
            f"| `{ch['peer']}` | {ch['role']} | {ch['max_category']} | {ch['budget_bits']} |"
        )
    return "\n".join(lines)


def format_cron_schedules(schedules: list[dict]) -> str:
    if not schedules:
        return ""
    lines = [
        "",
        "### Cron Schedules",
        "",
        "| Schedule | Label | Message |",
        "|----------|-------|---------|",
    ]
    for s in schedules:
        label = s.get("label") or ""
        msg = s["message"]
        if len(msg) > 80:
            msg = msg[:77] + "..."
        lines.append(f"| `{s['schedule']}` | {label} | {msg} |")
    return "\n".join(lines)


def generate_agent_page(meta: dict, body: str) -> str:
    """Generate a docs page for a single agent."""
    name = meta["name"]
    description = meta.get("description", "")
    model = meta.get("model", "claude-sonnet-4-20250514")
    tools = meta.get("tools", "")
    if isinstance(tools, str):
        tools = [t.strip() for t in tools.split(",")]
    network = meta.get("network", "none")
    idle_timeout = meta.get("idle_timeout", "")
    browser = meta.get("browser", False)
    docker_socket = meta.get("docker_socket", False)
    trionyx_repo = meta.get("trionyx_repo", False)
    base_taint = meta.get("base_taint", "low")
    heartbeat_every = meta.get("heartbeat_every", "")
    fs_read = meta.get("fs_read") or []
    fs_write = meta.get("fs_write") or []
    send_to = meta.get("send_to") or []
    receive_from = meta.get("receive_from") or []
    plugins = meta.get("plugins") or []
    skills = meta.get("skills") or []
    input_sources = meta.get("input_sources") or []
    bcp_channels = meta.get("bcp_channels") or []
    cron_schedules = meta.get("cron_schedules") or []

    sections = []

    # Title and description
    sections.append(f"# {name}\n")
    if description:
        sections.append(f"*{description}*\n")

    # Configuration table
    rows = [
        ("Model", f"`{model}`"),
        ("Tools", format_list(tools)),
        ("Network", format_network(network)),
        ("Base Taint", f"`{base_taint}`"),
        ("Idle Timeout", f"`{idle_timeout}`" if idle_timeout else "*default*"),
    ]
    if browser:
        rows.append(("Browser", "yes"))
    if docker_socket:
        rows.append(("Docker Socket", "yes"))
    if trionyx_repo:
        rows.append(("TriOnyx Repo Access", "yes"))
    if heartbeat_every:
        rows.append(("Heartbeat", f"`{heartbeat_every}`"))
    if input_sources:
        rows.append(("Input Sources", format_list(input_sources)))

    sections.append("## Configuration\n")
    sections.append("| Setting | Value |")
    sections.append("|---------|-------|")
    for label, value in rows:
        sections.append(f"| {label} | {value} |")
    sections.append("")

    # Filesystem access
    if fs_read or fs_write:
        sections.append("## Filesystem Access\n")
        if fs_read:
            sections.append("**Read:** " + ", ".join(f"`{p}`" for p in fs_read) + "\n")
        if fs_write:
            sections.append("**Write:** " + ", ".join(f"`{p}`" for p in fs_write) + "\n")

    # Communication
    if send_to or receive_from or bcp_channels:
        sections.append("## Communication\n")
        if send_to:
            sections.append(
                "**Sends to:** "
                + ", ".join(f"[{a}]({a}.md)" for a in send_to)
                + "\n"
            )
        if receive_from:
            sections.append(
                "**Receives from:** "
                + ", ".join(f"[{a}]({a}.md)" for a in receive_from)
                + "\n"
            )
        bcp = format_bcp_channels(bcp_channels)
        if bcp:
            sections.append(bcp)
            sections.append("")

    # Plugins
    if plugins:
        sections.append("## Plugins\n")
        sections.append(format_list(plugins) + "\n")

    # Cron
    cron = format_cron_schedules(cron_schedules)
    if cron:
        sections.append(cron)
        sections.append("")

    # System prompt
    sections.append("## System Prompt\n")
    sections.append(body)
    sections.append("")

    return "\n".join(sections)


def generate_index(agents: list[dict]) -> str:
    """Generate the agents index page."""
    lines = [
        "# Agents\n",
        "TriOnyx ships with the following agent definitions. Each agent runs in its own "
        "Docker container with isolated filesystem, network, and tool access.\n",
        "| Agent | Description | Model | Network |",
        "|-------|-------------|-------|---------|",
    ]
    for a in sorted(agents, key=lambda x: x["name"]):
        name = a["name"]
        desc = a.get("description", "")
        model = a.get("model", "claude-sonnet-4-20250514")
        short_model = model.replace("claude-", "").split("-2025")[0]
        network = a.get("network", "none")
        if isinstance(network, list):
            network = f"{len(network)} hosts"
        lines.append(f"| [{name}]({name}.md) | {desc} | {short_model} | {network} |")

    lines.append("")
    lines.append("## Architecture\n")
    lines.append(
        "All agents communicate through the Elixir/OTP gateway. "
        "Inter-agent messaging is governed by `send_to`/`receive_from` declarations, "
        "and cross-trust-boundary communication uses the "
        "[Bandwidth-Constrained Protocol](../bcp.md). "
        "See [Agent Runtime](../agent-runtime.md) for details on how sessions work.\n"
    )
    return "\n".join(lines)


def build_agents_nav(agent_names: list[str]) -> str:
    """Build the Agents nav YAML block for mkdocs.yml."""
    lines = ["  - Agents:", "      - Overview: agents/index.md"]
    for name in sorted(agent_names):
        lines.append(f"      - {name}: agents/{name}.md")
    return "\n".join(lines)


def update_mkdocs_nav(agent_names: list[str]) -> str | None:
    """Update the Agents section in mkdocs.yml. Returns new content, or None if unchanged."""
    text = MKDOCS_YML.read_text()
    new_nav = build_agents_nav(agent_names)

    # Match the entire "  - Agents:" block up to the next top-level nav entry or EOF
    pattern = r"(  - Agents:.*?)(\n  - |\Z)"
    match = re.search(pattern, text, re.DOTALL)

    if match:
        before = text[: match.start()]
        after_sep = match.group(2)
        after = text[match.end() :]
        updated = before + new_nav + after_sep + after
    else:
        # No Agents section yet — insert before Development (or at end of nav)
        dev_pattern = r"(\n  - Development:)"
        dev_match = re.search(dev_pattern, text)
        if dev_match:
            updated = text[: dev_match.start()] + "\n" + new_nav + text[dev_match.start() :]
        else:
            updated = text.rstrip() + "\n" + new_nav + "\n"

    if updated == text:
        return None
    return updated


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--check",
        action="store_true",
        help="Check if generated docs are up to date (exits non-zero if stale)",
    )
    args = parser.parse_args()

    if not DEFINITIONS_DIR.is_dir():
        print(f"Error: {DEFINITIONS_DIR} not found", file=sys.stderr)
        sys.exit(1)

    definition_files = sorted(DEFINITIONS_DIR.glob("*.md"))
    if not definition_files:
        print(f"Error: no .md files in {DEFINITIONS_DIR}", file=sys.stderr)
        sys.exit(1)

    agents = []
    pages = {}

    for path in definition_files:
        try:
            meta, body = parse_definition(path)
        except Exception as e:
            print(f"Warning: skipping {path.name}: {e}", file=sys.stderr)
            continue
        agents.append(meta)
        pages[meta["name"]] = generate_agent_page(meta, body)

    agent_names = [a["name"] for a in agents]
    index_content = generate_index(agents)
    mkdocs_update = update_mkdocs_nav(agent_names)

    if args.check:
        stale = False

        index_path = OUTPUT_DIR / "index.md"
        if not index_path.exists() or index_path.read_text() != index_content:
            print(f"Stale: {index_path.relative_to(ROOT)}")
            stale = True

        for name, content in pages.items():
            page_path = OUTPUT_DIR / f"{name}.md"
            if not page_path.exists() or page_path.read_text() != content:
                print(f"Stale: {page_path.relative_to(ROOT)}")
                stale = True

        if mkdocs_update is not None:
            print(f"Stale: mkdocs.yml (Agents nav section)")
            stale = True

        if stale:
            print("\nRun: uv run scripts/generate-agent-docs.py")
            sys.exit(1)
        else:
            print("Agent docs are up to date.")
    else:
        OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

        (OUTPUT_DIR / "index.md").write_text(index_content)
        print(f"Wrote docs/agents/index.md")

        for name, content in pages.items():
            (OUTPUT_DIR / f"{name}.md").write_text(content)
            print(f"Wrote docs/agents/{name}.md")

        if mkdocs_update is not None:
            MKDOCS_YML.write_text(mkdocs_update)
            print("Updated mkdocs.yml")
        else:
            print("mkdocs.yml already up to date")

        print(f"\nGenerated {len(pages)} agent pages.")


if __name__ == "__main__":
    main()
