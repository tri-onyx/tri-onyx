import json
import os
import re

from django.conf import settings
from django.http import HttpResponse
from django.shortcuts import redirect, render
from django.urls import reverse
from django.utils.safestring import mark_safe
from markdown_it import MarkdownIt

from trionyx_ui import gateway
from trionyx_ui.tool_briefs import (
    format_tool_brief as _format_tool_brief,
    get_brief_specs as _get_brief_specs,
)
from trionyx_ui.views.helpers import (
    escape as _escape,
    resolve_connected_agents as _resolve_connected_agents,
)

_md = MarkdownIt("commonmark", {"breaks": True}).enable("table")


def _render_md(text: str) -> str:
    html = _md.render(text)
    return html.replace("<a ", '<a target="_blank" rel="noopener" ')


VISIBLE_EVENT_TYPES = {
    "user_prompt",
    "text",
    "tool_use",
    "tool_result",
    "result",
    "error",
    "ready",
    "session_start",
    "session_stop",
    "send_message",
    "bcp_query",
    "risk_escalation",
    "approval_request",
    "interrupted",
    "image",
    "page",
}


def agent_chat(request, name):
    try:
        agent = gateway.get_agent(name)
    except gateway.GatewayError as e:
        agents = []
        try:
            agents = gateway.get_agents()
        except gateway.GatewayError:
            pass
        if e.status_code == 404:
            return render(request, "error.html", {
                "error_code": 404,
                "error_message": f"Agent '{name}' not found",
                "agents": agents,
            }, status=404)
        return render(request, "error.html", {
            "error_code": e.status_code,
            "error_message": e.message,
            "agents": agents,
        }, status=e.status_code)

    history_session_id = request.GET.get("session")
    if history_session_id:
        return _render_historical_session(request, agent, name, history_session_id)

    is_active = agent.get("status") not in (None, "inactive", "stopped")

    if not is_active:
        try:
            gateway.start_agent(name)
        except gateway.GatewayError:
            pass

    active_sessions = agent.get("active_sessions", [])
    selected_active = request.GET.get("active")

    if selected_active and any(s["session_id"] == selected_active for s in active_sessions):
        session_id = selected_active
    else:
        session_id = agent.get("session_id")

    messages = []
    last_timestamp = ""

    session_cost = 0.0

    if session_id:
        raw_events = gateway.get_session_log(name, session_id)
        messages = _pair_tool_calls(
            [classify_event(e) for e in raw_events if e.get("type") in VISIBLE_EVENT_TYPES]
        )
        if raw_events:
            last_timestamp = raw_events[-1].get("timestamp", "")
        session_cost = sum(e.get("cost_usd", 0) for e in raw_events if e.get("type") == "result")

    gateway_sse_url = f"{settings.GATEWAY_EXTERNAL_URL}/agents/{name}/events"
    if len(active_sessions) > 1 and session_id:
        gateway_sse_url += f"?session_id={session_id}"

    pending_approvals = gateway.get_approval_count()
    connected_agents = _resolve_connected_agents(agent)

    show_session_picker = len(active_sessions) > 1

    return render(request, "chat.html", {
        "agent": agent,
        "messages": messages,
        "is_active": True,
        "is_starting": False,
        "session_id": session_id,
        "gateway_sse_url": gateway_sse_url,
        "last_timestamp": last_timestamp,
        "pending_approvals": pending_approvals,
        "session_cost": f"{session_cost:.2f}" if session_cost < 0.005 else f"{session_cost:.4f}",
        "connected_agents": connected_agents,
        "viewing_history": False,
        "active_sessions": active_sessions if show_session_picker else [],
        "selected_session_id": session_id,
        "tool_briefs": _get_brief_specs(),
    })


def _render_historical_session(request, agent, name, history_session_id):
    raw_events = gateway.get_session_log(name, history_session_id)
    messages = _pair_tool_calls(
        [classify_event(e) for e in raw_events if e.get("type") in VISIBLE_EVENT_TYPES]
    )

    session_start_ts = ""
    for e in raw_events:
        if e.get("timestamp"):
            session_start_ts = e["timestamp"]
            break

    session_cost = sum(e.get("cost_usd", 0) for e in raw_events if e.get("type") == "result")
    pending_approvals = gateway.get_approval_count()
    connected_agents = _resolve_connected_agents(agent)

    return render(request, "chat.html", {
        "agent": agent,
        "messages": messages,
        "is_active": False,
        "session_id": history_session_id,
        "gateway_sse_url": "",
        "last_timestamp": "",
        "pending_approvals": pending_approvals,
        "viewing_history": True,
        "history_session_id": history_session_id,
        "history_session_start": session_start_ts,
        "session_cost": f"{session_cost:.2f}" if session_cost < 0.005 else f"{session_cost:.4f}",
        "connected_agents": connected_agents,
    })


def agent_sessions(request, name):
    sessions = gateway.list_agent_sessions(name)
    current_session_id = request.GET.get("current", "")
    return render(request, "partials/session_list.html", {
        "sessions": sessions,
        "agent_name": name,
        "current_session_id": current_session_id,
    })


def agent_status_check(request, name):
    check_url = reverse("agent-status-check", args=[name])
    still_starting = (
        f'<div id="starting-area"'
        f' hx-get="{check_url}"'
        f' hx-trigger="load delay:1s, every 2s"'
        f' hx-swap="outerHTML">'
        f'<div class="start-prompt starting">'
        f'<div class="spinner"></div><p>Starting agent...</p>'
        f'</div></div>'
    )
    try:
        agent = gateway.get_agent(name)
    except gateway.GatewayError:
        return HttpResponse(still_starting, content_type="text/html")

    is_active = agent.get("status") not in (None, "inactive", "stopped")
    if not is_active:
        return HttpResponse(still_starting, content_type="text/html")

    gateway_sse_url = f"{settings.GATEWAY_EXTERNAL_URL}/agents/{name}/events"
    return render(request, "partials/agent_started.html", {
        "agent": agent,
        "gateway_sse_url": gateway_sse_url,
    })


def agent_start(request, name):
    if request.method != "POST":
        return redirect("agent-chat", name=name)
    try:
        gateway.start_agent(name)
    except gateway.GatewayError:
        pass
    return redirect("agent-chat", name=name)


def agent_prompt(request, name):
    if request.method != "POST":
        return HttpResponse(status=405)

    content = request.POST.get("content", "").strip()
    if not content:
        return HttpResponse(status=400)

    session_id = request.POST.get("session_id", "").strip() or None

    try:
        gateway.send_prompt(name, content, session_id=session_id)
    except gateway.GatewayError:
        return HttpResponse(
            '<div class="msg msg-error">Failed to send prompt</div>',
            content_type="text/html",
        )

    from django.utils.html import escape
    return HttpResponse(
        f'<div class="msg msg-user">{escape(content)}</div>',
        content_type="text/html",
    )


def agent_stop(request, name):
    if request.method != "POST":
        return redirect("agent-chat", name=name)
    session_id = request.POST.get("session_id", "").strip() or None
    try:
        gateway.stop_agent(name, session_id=session_id)
    except gateway.GatewayError:
        pass
    if session_id:
        return redirect(f"/agents/{name}/?active={session_id}")
    return redirect("agent-chat", name=name)


_ALLOWED_IMAGE_EXTS = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg"}


def session_image(request, agent_name, session_id, image_id):
    ext = os.path.splitext(image_id)[1].lower()
    if ext not in _ALLOWED_IMAGE_EXTS:
        return HttpResponse(status=403)
    try:
        resp = gateway.get_session_image(agent_name, session_id, image_id)
        return HttpResponse(
            resp.content,
            content_type=resp.headers.get("content-type", "application/octet-stream"),
            headers={"Cache-Control": "private, max-age=3600"},
        )
    except Exception:
        return HttpResponse(status=404)


_COMMIT_SHA_RE = re.compile(r"\A[0-9a-f]{7,40}\Z")


def session_page(request, commit, page_path):
    if not _COMMIT_SHA_RE.match(commit):
        return HttpResponse(status=400)
    ext = os.path.splitext(page_path)[1].lower()
    if ext not in (".html", ".htm"):
        return HttpResponse(status=403)
    try:
        resp = gateway.get_session_page(commit, page_path)
        return HttpResponse(
            resp.content,
            content_type="text/html",
            headers={
                "Content-Security-Policy": "sandbox allow-scripts",
                "Cache-Control": "public, max-age=31536000, immutable",
            },
        )
    except Exception:
        return HttpResponse(status=404)


def classify_event(event: dict) -> dict:
    etype = event.get("type", "unknown")
    base = {
        "type": etype,
        "timestamp": event.get("timestamp", ""),
    }

    if etype == "user_prompt":
        base["content"] = event.get("content", "")

    elif etype == "text":
        raw = event.get("content", "")
        base["content"] = raw
        base["content_html"] = mark_safe(_render_md(raw))

    elif etype == "tool_use":
        base["tool_id"] = event.get("id", "")
        base["tool_name"] = event.get("name", "")
        base["brief"] = _format_tool_brief(event.get("name", ""), event.get("input", {}))
        base["detail"] = json.dumps(event.get("input", {}), indent=2)

    elif etype == "tool_result":
        base["tool_id"] = event.get("id", "")
        base["tool_name"] = event.get("name", "")
        content = event.get("content", "") or ""
        base["content_truncated"] = content[:3000]
        base["content_html"] = mark_safe(_render_md(content[:3000]))
        base["is_error"] = event.get("is_error", False)

    elif etype == "result":
        base["num_turns"] = event.get("num_turns", 0)
        base["duration_ms"] = event.get("duration_ms", 0)
        base["cost_usd"] = f"{event.get('cost_usd', 0):.4f}"

    elif etype == "error":
        base["message"] = event.get("message", str(event))

    elif etype == "image":
        base["image_id"] = event.get("image_id", "")
        base["filename"] = event.get("filename", "")
        base["media_type"] = event.get("media_type", "")

    elif etype == "page":
        base["path"] = event.get("path", "")
        base["commit"] = event.get("commit", "")
        base["title"] = event.get("title", "")
        base["filename"] = event.get("filename", "")

    elif etype == "send_message":
        base["to_agent"] = event.get("to", "")
        base["from_agent"] = event.get("from", "")

    elif etype == "bcp_query":
        base["to_agent"] = event.get("to", "")
        base["from_agent"] = event.get("from", "")
        base["category"] = event.get("category", "")

    elif etype == "risk_escalation":
        base["previous_risk"] = event.get("previous_risk", "")
        base["effective_risk"] = event.get("effective_risk", "")
        base["source"] = event.get("source", "")

    elif etype == "session_start":
        base["agent_name"] = event.get("agent_name", "")
        base["trigger_type"] = event.get("trigger_type", "")

    elif etype == "session_stop":
        base["reason"] = event.get("reason", "")

    elif etype == "interrupted":
        base["reason"] = event.get("reason", "")

    return base


def _pair_tool_calls(messages: list[dict]) -> list[dict]:
    results_by_id = {}
    for msg in messages:
        if msg["type"] == "tool_result" and msg.get("tool_id"):
            results_by_id[msg["tool_id"]] = msg

    paired = []
    consumed_ids = set()
    for msg in messages:
        if msg["type"] == "tool_use" and msg.get("tool_id") in results_by_id:
            result = results_by_id[msg["tool_id"]]
            consumed_ids.add(msg["tool_id"])
            paired.append({
                "type": "tool_pair",
                "timestamp": msg["timestamp"],
                "tool_name": msg["tool_name"],
                "brief": msg["brief"],
                "detail": msg["detail"],
                "result_content_html": result["content_html"],
                "result_is_error": result.get("is_error", False),
            })
        elif msg["type"] == "tool_result" and msg.get("tool_id") in consumed_ids:
            continue
        else:
            paired.append(msg)
    return paired




