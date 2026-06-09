"""Helpers shared by the view modules."""

from trionyx_ui import gateway


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
