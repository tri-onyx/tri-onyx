import json

from django.http import HttpResponse

from trionyx_ui import gateway


def approvals_badge(request):
    """Returns just the badge count for HTMX polling."""
    count = gateway.get_approval_count()
    if count:
        html = (
            f'<span class="notif-badge">{count}</span>'
            f'<span class="notif-dot"></span>'
        )
    else:
        html = ""
    return HttpResponse(html)


def approvals_dropdown(request):
    """Returns the full dropdown content."""
    items = gateway.get_approvals()
    if not items:
        return HttpResponse(
            '<div class="notif-empty">No pending approvals</div>'
        )

    parts = []
    for item in items:
        parts.append(_render_item(item))
    return HttpResponse("\n".join(parts))


def approval_action(request, item_id):
    if request.method != "POST":
        return HttpResponse(status=405)

    action = request.POST.get("action", "")
    kind = request.POST.get("kind", "bcp")

    try:
        if action == "approve":
            gateway.approve_item(item_id, kind)
        elif action == "reject":
            reason = request.POST.get("reason", "")
            gateway.reject_item(item_id, kind, reason)
        else:
            return HttpResponse(status=400)
    except Exception:
        return HttpResponse(
            '<div class="notif-item notif-item-error">Action failed</div>',
            content_type="text/html",
        )

    resp = HttpResponse("")
    resp["HX-Trigger"] = "notif-refresh, badge-refresh"
    return resp


def _render_item(item: dict) -> str:
    kind = item.get("kind", "bcp")
    item_id = item.get("id", "")
    submitted = item.get("submitted_at", "")

    if kind == "bcp":
        from_agent = _esc(item.get("from_agent", ""))
        to_agent = _esc(item.get("to_agent", ""))
        query = _esc(item.get("query", ""))
        justification = _esc(item.get("justification", ""))
        action_desc = f"{from_agent} to {to_agent}"

        desc = (
            f'<div class="notif-item-header">'
            f'<span class="notif-kind notif-kind-bcp">BCP</span>'
            f'<span class="notif-agents">{from_agent} &rarr; {to_agent}</span>'
            f'</div>'
        )
        if query:
            desc += f'<div class="notif-detail">{query}</div>'
        if justification:
            desc += f'<div class="notif-detail notif-justification">{justification}</div>'
    else:
        agent = _esc(item.get("agent_name", ""))
        tool = _esc(item.get("tool_name", ""))
        tool_input = item.get("tool_input", {})
        brief = _tool_brief(tool, tool_input)
        action_desc = f"{tool} for {agent}"

        desc = (
            f'<div class="notif-item-header">'
            f'<span class="notif-kind notif-kind-action">Action</span>'
            f'<span class="notif-agents">{agent}</span>'
            f'</div>'
            f'<div class="notif-detail">{_esc(tool)}'
        )
        if brief:
            desc += f' <span class="notif-tool-brief">{_esc(brief)}</span>'
        desc += '</div>'

    return (
        f'<div class="notif-item" id="notif-{_esc(item_id)}">'
        f'{desc}'
        f'<div class="notif-actions">'
        f'<button class="btn-notif btn-notif-approve"'
        f' hx-post="/approvals/{_esc(item_id)}"'
        f' hx-vals=\'{json.dumps({"action": "approve", "kind": kind})}\''
        f' hx-target="#notif-{_esc(item_id)}"'
        f' hx-swap="outerHTML"'
        f' aria-label="Approve {action_desc}"'
        f'>Approve</button>'
        f'<button class="btn-notif btn-notif-reject"'
        f' hx-post="/approvals/{_esc(item_id)}"'
        f' hx-vals=\'{json.dumps({"action": "reject", "kind": kind})}\''
        f' hx-target="#notif-{_esc(item_id)}"'
        f' hx-swap="outerHTML"'
        f' aria-label="Reject {action_desc}"'
        f'>Reject</button>'
        f'</div>'
        f'</div>'
    )


def _tool_brief(tool_name: str, tool_input: dict) -> str:
    if tool_name in ("Read", "Write"):
        return _short_path(tool_input.get("file_path", ""))
    if tool_name == "Bash":
        cmd = tool_input.get("command", "")
        return cmd[:60] + ("..." if len(cmd) > 60 else "")
    if tool_name == "Edit":
        return _short_path(tool_input.get("file_path", ""))
    return ""


def _short_path(path: str) -> str:
    if not path:
        return ""
    parts = path.replace("/workspace/", "").split("/")
    if len(parts) > 3:
        return f".../{'/'.join(parts[-2:])}"
    return "/".join(parts)


def _esc(text: str) -> str:
    return (
        text.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
        .replace("'", "&#x27;")
    )
