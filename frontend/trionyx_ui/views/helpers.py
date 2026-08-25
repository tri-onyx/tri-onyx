"""Helpers shared by the view modules."""

from markdown_it import MarkdownIt

from trionyx_ui import gateway

# Agent- and gateway-authored markdown is untrusted input: ``html: False``
# makes markdown-it escape raw HTML instead of passing it through, which is
# what lets callers ``mark_safe()`` the result. (The "commonmark" preset
# enables raw HTML by default — the override is load-bearing.)
_md = MarkdownIt("commonmark", {"breaks": True, "html": False}).enable("table")


def render_markdown(text: str) -> str:
    """Render untrusted markdown to HTML safe to ``mark_safe()``.

    Links open in a new tab: the rendered text lives inside the dashboard,
    and following a link should not navigate away from it.
    """
    html = _md.render(text or "")
    return html.replace("<a ", '<a target="_blank" rel="noopener" ')


def short_path(path: str) -> str:
    """Compact a workspace path for display."""
    if not path:
        return ""
    parts = path.replace("/workspace/", "").split("/")
    if len(parts) > 3:
        return f".../{'/'.join(parts[-2:])}"
    return "/".join(parts)


def escape(text: str) -> str:
    """HTML-escape text for safe interpolation into markup (including
    single- and double-quoted attribute values)."""
    return (
        text.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
        .replace("'", "&#x27;")
    )


def format_session_cost(cost: float) -> str:
    """Format a USD session cost for display: tiny costs get extra
    precision so they don't render as \"0.00\"."""
    return f"{cost:.4f}" if cost < 0.005 else f"{cost:.2f}"


def resolve_connected_agents(agent: dict) -> list[dict]:
    """Build the send/receive connectivity list for an agent, with live
    status from the gateway (defaulting to inactive when unreachable)."""
    send_to = set(agent.get("send_to") or [])
    receive_from = set(agent.get("receive_from") or [])
    all_names = send_to | receive_from
    if not all_names:
        return []

    status_map = {}
    try:
        for a in gateway.get_agents():
            if a["name"] in all_names:
                status_map[a["name"]] = a.get("status", "inactive")
    except gateway.GatewayError:
        pass

    result = []
    for name in sorted(all_names):
        directions = []
        if name in send_to:
            directions.append("send")
        if name in receive_from:
            directions.append("receive")
        result.append({
            "name": name,
            "status": status_map.get(name, "inactive"),
            "directions": directions,
        })
    return result
