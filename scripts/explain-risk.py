# /// script
# requires-python = ">=3.11"
# dependencies = ["httpx>=0.27"]
# ///
"""Explain why agents have their risk levels.

Queries the gateway API and prints a succinct breakdown of each agent's
taint, sensitivity, capability, and effective risk — showing which tools
and incoming edges drive each level.

Usage:
    uv run scripts/explain-risk.py [agent-name ...] [options]

Examples:
    uv run scripts/explain-risk.py                    # all agents
    uv run scripts/explain-risk.py researcher main    # specific agents
    uv run scripts/explain-risk.py --gateway http://localhost:4000
"""

import argparse
import sys

import httpx

LEVEL_RANK = {"low": 0, "medium": 1, "high": 2}
RISK_RANK = {"low": 0, "moderate": 1, "high": 2, "critical": 3}
LEVEL_SYMBOLS = {"low": "·", "medium": "▲", "high": "▲▲"}
RISK_SYMBOLS = {"low": "●", "moderate": "◆", "high": "▲", "critical": "⬟"}


def colorize(level: str, text: str | None = None) -> str:
    """ANSI-colorize a level string."""
    text = text or level
    colors = {
        "low": "\033[32m",       # green
        "medium": "\033[33m",    # yellow
        "high": "\033[31m",      # red
        "moderate": "\033[33m",  # yellow
        "critical": "\033[91m",  # bright red
    }
    reset = "\033[0m"
    return f"{colors.get(level, '')}{text}{reset}"


def format_drivers(drivers: list[dict]) -> str:
    """Format tool driver list as 'Tool(level), ...'."""
    if not drivers:
        return "none"
    return ", ".join(f"{d['tool']}({colorize(d['level'])})" for d in drivers)


def format_unified_sources(sources: list[dict]) -> str:
    """Format unified source list as 'source(level), ...'."""
    if not sources:
        return "none"
    parts = []
    for d in sources:
        label = f"{d['source']}({colorize(d['level'])})"
        if d.get("edge_type"):
            label += f" [{d['edge_type']}]"
        parts.append(label)
    return ", ".join(parts)



def explain_agent(name: str, agent: dict, analysis: dict) -> str:
    """Build a succinct explanation string for one agent."""
    lines = []

    aa = analysis.get(name, {})
    cap = aa.get("capability_level", "low")
    eff_risk = aa.get("effective_risk", "low")
    prop_t = aa.get("propagated_taint") or aa.get("worst_case_taint", "low")
    prop_s = aa.get("propagated_sensitivity") or aa.get("worst_case_sensitivity", "low")
    wc_t = aa.get("worst_case_taint", prop_t)
    wc_s = aa.get("worst_case_sensitivity", prop_s)

    risk_sym = RISK_SYMBOLS.get(eff_risk, "?")
    header = f"{risk_sym} {name}  —  effective risk: {colorize(eff_risk)}"
    lines.append(header)

    # Description
    desc = agent.get("description")
    if desc:
        lines.append(f"  {desc}")

    # Three axes — unified sources

    # Detect live session override: when the agent's live taint exceeds worst-case,
    # it was escalated by the trigger type at runtime.
    live_t = agent.get("taint_level", wc_t)
    live_s = agent.get("sensitivity_level", wc_s)
    live_t_elevated = LEVEL_RANK.get(live_t, 0) > LEVEL_RANK.get(wc_t, 0)
    live_s_elevated = LEVEL_RANK.get(live_s, 0) > LEVEL_RANK.get(wc_s, 0)

    taint_base_note = f"static: {wc_t}"
    if live_t_elevated:
        sources = agent.get("information_sources", [])
        trigger_reason = f"; live session: {live_t} via {sources[0]}" if sources else f"; live session: {live_t}"
        taint_base_note += trigger_reason

    lines.append(f"  Taint:       {colorize(prop_t):<20s} ({taint_base_note})")
    taint_srcs = aa.get("taint_sources", [])
    if taint_srcs:
        tool_srcs = [s for s in taint_srcs if s.get("kind") == "tool"]
        input_srcs = [s for s in taint_srcs if s.get("kind") == "input"]
        if tool_srcs:
            lines.append(f"    tools:     {format_unified_sources(tool_srcs)}")
        if input_srcs:
            lines.append(f"    inputs:    {format_unified_sources(input_srcs)}")

    sens_base_note = f"static: {wc_s}"
    if live_s_elevated:
        sens_base_note += f"; live session: {live_s}"

    lines.append(f"  Sensitivity: {colorize(prop_s):<20s} ({sens_base_note})")
    sens_srcs = aa.get("sensitivity_sources", [])
    if sens_srcs:
        tool_srcs = [s for s in sens_srcs if s.get("kind") == "tool"]
        input_srcs = [s for s in sens_srcs if s.get("kind") == "input"]
        if tool_srcs:
            lines.append(f"    tools:     {format_unified_sources(tool_srcs)}")
        if input_srcs:
            lines.append(f"    inputs:    {format_unified_sources(input_srcs)}")

    lines.append(f"  Capability:  {colorize(cap)}")
    cap_drivers = aa.get("capability_drivers", [])
    if cap_drivers:
        lines.append(f"    drivers:   {format_drivers(cap_drivers)}")

    # Network
    network = agent.get("network", "none")
    if network and network != "none":
        net_str = ", ".join(network) if isinstance(network, list) else str(network)
        lines.append(f"  Network:     {net_str}")

    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description="Explain agent risk levels")
    parser.add_argument("agents", nargs="*", help="Agent names (default: all)")
    parser.add_argument(
        "--gateway", default="http://localhost:4000",
        help="Gateway URL (default: http://localhost:4000)",
    )
    parser.add_argument("--no-color", action="store_true", help="Disable color output")
    args = parser.parse_args()

    if args.no_color:
        # Strip ANSI by replacing colorize
        global colorize
        colorize = lambda level, text=None: text or level  # noqa: E731

    client = httpx.Client(base_url=args.gateway, timeout=10)

    try:
        agents_resp = client.get("/agents").raise_for_status().json()
        analysis_resp = client.get("/graph/analysis").raise_for_status().json()
    except httpx.HTTPError as e:
        print(f"Error reaching gateway: {e}", file=sys.stderr)
        sys.exit(1)

    agent_list = agents_resp.get("agents", [])
    agent_map = {a["name"]: a for a in agent_list}
    analysis = analysis_resp.get("agents", {})

    # Filter to requested agents
    names = args.agents or sorted(agent_map.keys())
    missing = [n for n in names if n not in agent_map]
    if missing:
        print(f"Unknown agents: {', '.join(missing)}", file=sys.stderr)
        sys.exit(1)

    # Print edge summary
    edges = analysis_resp.get("edges", [])
    biba_count = sum(1 for e in edges if e.get("biba_violation"))
    blp_count = sum(1 for e in edges if e.get("blp_violation"))

    print(f"\033[1m{len(agent_map)} agents, {len(edges)} edges", end="")
    if biba_count or blp_count:
        parts = []
        if biba_count:
            parts.append(f"{biba_count} Biba violations")
        if blp_count:
            parts.append(f"{blp_count} BLP violations")
        print(f"  ⚠ {', '.join(parts)}", end="")
    print(f"\033[0m\n")

    for i, name in enumerate(names):
        if i > 0:
            print()
        print(explain_agent(name, agent_map[name], analysis))


if __name__ == "__main__":
    main()
