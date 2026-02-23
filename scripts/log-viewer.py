# /// script
# requires-python = ">=3.11"
# dependencies = ["httpx>=0.27"]
# ///
"""Browse agent session logs from the gateway.

Usage:
    uv run scripts/log-viewer.py                          # list agents
    uv run scripts/log-viewer.py <agent>                  # list sessions
    uv run scripts/log-viewer.py <agent> <session>        # show events
    uv run scripts/log-viewer.py <agent> latest           # latest session

Options:
    --gateway URL       Gateway base URL (default: http://localhost:4000)
    --type TYPE         Filter by event type (repeatable)
    --search QUERY      Filter events by text search
    --no-color          Disable colored output
    --json              Output raw JSON lines (session view only)
    --tail N            Show only the last N events

Environment:
    TRI_ONYX_GATEWAY    Gateway base URL (overridden by --gateway)
"""

import argparse
import json
import os
import sys
from datetime import datetime, timezone

import httpx

# --- ANSI colors ---

COLORS = {
    "reset": "\033[0m",
    "bold": "\033[1m",
    "dim": "\033[2m",
    "red": "\033[31m",
    "green": "\033[32m",
    "yellow": "\033[33m",
    "blue": "\033[34m",
    "magenta": "\033[35m",
    "cyan": "\033[36m",
    "gray": "\033[90m",
}

NO_COLORS = {k: "" for k in COLORS}

EVENT_COLORS = {
    "session_start": "green",
    "session_stop": "red",
    "ready": "green",
    "user_prompt": "green",
    "text": "blue",
    "tool_use": "yellow",
    "tool_result": "gray",
    "result": "green",
    "error": "red",
    "port_down": "red",
    "send_message": "blue",
    "heartbeat_result": "yellow",
}


def c(name: str, text: str, palette: dict) -> str:
    return f"{palette.get(name, '')}{text}{palette.get('reset', '')}"


# --- API ---


def api(gateway: str, path: str) -> httpx.Response:
    resp = httpx.get(f"{gateway.rstrip('/')}{path}", timeout=10)
    resp.raise_for_status()
    return resp


def list_agents(gateway: str) -> list[str]:
    data = api(gateway, "/logs").json()
    return data.get("agents", [])


def list_sessions(gateway: str, agent: str) -> list[dict]:
    data = api(gateway, f"/logs/{agent}").json()
    return data.get("sessions", [])


def get_events(gateway: str, agent: str, session_id: str) -> list[dict]:
    text = api(gateway, f"/logs/{agent}/{session_id}").text
    events = []
    for line in text.strip().split("\n"):
        line = line.strip()
        if not line:
            continue
        try:
            events.append(json.loads(line))
        except json.JSONDecodeError:
            pass
    return events


# --- Formatting ---


def format_bytes(b: int) -> str:
    if b < 1024:
        return f"{b} B"
    if b < 1024 * 1024:
        return f"{b / 1024:.1f} KB"
    return f"{b / (1024 * 1024):.1f} MB"


def format_ts(ts: str) -> str:
    try:
        dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
        return dt.astimezone().strftime("%H:%M:%S")
    except Exception:
        return ts or ""


def format_datetime(ts: str) -> str:
    try:
        dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
        return dt.astimezone().strftime("%Y-%m-%d %H:%M:%S")
    except Exception:
        return ts or ""


def truncate(s: str, n: int) -> str:
    return s[:n] + "..." if len(s) > n else s


def format_tool_use(e: dict) -> str:
    name = e.get("name", "")
    inp = e.get("input", {})
    detail = ""
    match name:
        case "Read":
            detail = inp.get("file_path", "")
            if inp.get("offset"):
                detail += f":{inp['offset']}"
        case "Write":
            detail = inp.get("file_path", "")
        case "Edit":
            detail = inp.get("file_path", "")
            if inp.get("old_string"):
                detail += f" (replacing {truncate(inp['old_string'], 40)})"
        case "Bash":
            detail = truncate(inp.get("command", inp.get("description", "")), 120)
        case "Glob":
            detail = inp.get("pattern", "")
            if inp.get("path"):
                detail += f" in {inp['path']}"
        case "Grep":
            detail = f"/{inp.get('pattern', '')}/"
            if inp.get("glob"):
                detail += f" {inp['glob']}"
            if inp.get("path"):
                detail += f" in {inp['path']}"
        case "WebFetch":
            detail = inp.get("url", "")
        case "WebSearch":
            detail = inp.get("query", "")
        case "Task":
            detail = inp.get("description", "")
            if not detail and inp.get("prompt"):
                detail = truncate(inp["prompt"], 80)
        case _:
            keys = list(inp.keys())
            if keys:
                detail = truncate(json.dumps(inp), 120)
    if detail:
        return f"{name} — {detail}"
    return name


def format_event_content(e: dict) -> str:
    etype = e.get("type", "unknown")
    match etype:
        case "session_start":
            return (
                f"agent={e.get('agent_name', '')} model={e.get('model', '')} "
                f"trigger={e.get('trigger_type', '')} risk={e.get('effective_risk', '')}"
            )
        case "session_stop":
            return (
                f"reason={e.get('reason', '')} taint={e.get('taint_level', '')} "
                f"sensitivity={e.get('sensitivity_level', e.get('secrecy_level', ''))}"
            )
        case "ready":
            return "Runtime ready"
        case "user_prompt":
            return truncate(e.get("content", ""), 500)
        case "text":
            return e.get("content", "")
        case "tool_use":
            return format_tool_use(e)
        case "tool_result":
            tag = "[ERROR] " if e.get("is_error") else ""
            return tag + truncate(e.get("content", ""), 500)
        case "result":
            return f"Done: {e.get('num_turns', '?')} turns, {e.get('duration_ms', '?')}ms, ${e.get('cost_usd', '?')}"
        case "error":
            return e.get("message", json.dumps(e))
        case "port_down":
            return e.get("reason", "")
        case "send_message":
            return f"{e.get('from', '')} -> {e.get('to', '')} ({e.get('message_type', '')})"
        case "heartbeat_result":
            return f"{e.get('classification', '')} agent={e.get('agent_name', '')}"
        case _:
            return json.dumps(e)


def matches_search(e: dict, query: str) -> bool:
    if not query:
        return True
    return query.lower() in json.dumps(e).lower()


# --- Commands ---


def cmd_list_agents(args):
    pal = NO_COLORS if args.no_color else COLORS
    agents = list_agents(args.gateway)
    if not agents:
        print(c("dim", "No agents found. Run an agent session first.", pal))
        return
    print(c("bold", f"Agents ({len(agents)}):", pal))
    for a in agents:
        print(f"  {a}")


def cmd_list_sessions(args):
    pal = NO_COLORS if args.no_color else COLORS
    sessions = list_sessions(args.gateway, args.agent)
    if not sessions:
        print(c("dim", f"No sessions found for {args.agent}.", pal))
        return
    print(c("bold", f"{args.agent} — {len(sessions)} sessions:", pal))
    for s in sessions:
        sid = s.get("session_id", "?")
        size = format_bytes(s.get("size_bytes", 0))
        modified = format_datetime(s.get("modified_at", ""))
        print(f"  {c('cyan', sid, pal)}  {c('dim', size, pal)}  {c('dim', modified, pal)}")


def cmd_show_session(args):
    pal = NO_COLORS if args.no_color else COLORS

    session_id = args.session
    if session_id == "latest":
        sessions = list_sessions(args.gateway, args.agent)
        if not sessions:
            print(c("dim", f"No sessions found for {args.agent}.", pal))
            return
        session_id = sessions[0].get("session_id")

    events = get_events(args.gateway, args.agent, session_id)

    # Apply filters
    type_filter = set(args.type) if args.type else None
    filtered = []
    for e in events:
        etype = e.get("type", "unknown")
        if type_filter and etype not in type_filter:
            continue
        if not matches_search(e, args.search):
            continue
        filtered.append(e)

    if args.tail:
        filtered = filtered[-args.tail :]

    if args.json:
        for e in filtered:
            print(json.dumps(e))
        return

    if not filtered:
        print(c("dim", "No matching events.", pal))
        return

    print(
        c("bold", f"{args.agent} / {session_id}", pal)
        + c("dim", f"  ({len(filtered)}/{len(events)} events)", pal)
    )
    print()

    for e in filtered:
        etype = e.get("type", "unknown")
        ts = format_ts(e.get("timestamp", ""))
        content = format_event_content(e)
        color = EVENT_COLORS.get(etype, "dim")

        ts_str = c("dim", ts, pal)
        type_str = c(color, etype.upper().ljust(18), pal)
        # Color error/tool content
        if etype in ("error", "port_down", "session_stop"):
            content_str = c("red", content, pal)
        elif etype in ("tool_use", "tool_result"):
            content_str = c("yellow", content, pal)
        else:
            content_str = content

        print(f"{ts_str}  {type_str}{content_str}")


def main():
    default_gateway = os.environ.get("TRI_ONYX_GATEWAY", "http://localhost:4000")

    parser = argparse.ArgumentParser(
        description="Browse agent session logs from the TriOnyx gateway."
    )
    parser.add_argument("agent", nargs="?", help="Agent name")
    parser.add_argument(
        "session", nargs="?", help="Session ID (or 'latest' for most recent)"
    )
    parser.add_argument(
        "--gateway",
        default=default_gateway,
        help=f"Gateway URL (default: {default_gateway})",
    )
    parser.add_argument(
        "--type",
        action="append",
        help="Filter by event type (repeatable, e.g. --type tool_use --type text)",
    )
    parser.add_argument("--search", default="", help="Filter events by text search")
    parser.add_argument("--no-color", action="store_true", help="Disable colors")
    parser.add_argument("--json", action="store_true", help="Output raw JSON lines")
    parser.add_argument(
        "--tail", type=int, default=0, help="Show only the last N events"
    )

    args = parser.parse_args()

    try:
        if args.agent and args.session:
            cmd_show_session(args)
        elif args.agent:
            cmd_list_sessions(args)
        else:
            cmd_list_agents(args)
    except httpx.HTTPStatusError as e:
        print(f"Error: HTTP {e.response.status_code} from {e.request.url}", file=sys.stderr)
        sys.exit(1)
    except httpx.ConnectError:
        print(f"Error: cannot connect to gateway at {args.gateway}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
