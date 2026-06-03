import json
import logging

from django.http import HttpResponse
from django.shortcuts import render

from trionyx_ui import gateway

logger = logging.getLogger(__name__)


def builder_new(request):
    try:
        schema = gateway.get_agent_schema()
    except gateway.GatewayError:
        schema = {"fields": [], "groups": [], "tool_groups": [], "known_tools": [], "known_agents": []}

    pending_approvals = gateway.get_approval_count()

    return render(request, "builder.html", {
        "schema_json": json.dumps(schema),
        "initial_json": json.dumps({
            "mode": "create",
            "agent_name": None,
            "frontmatter": {},
            "system_prompt": "",
        }),
        "mode": "create",
        "agent_name": None,
        "pending_approvals": pending_approvals,
    })


def builder_edit(request, name):
    try:
        schema = gateway.get_agent_schema()
    except gateway.GatewayError:
        schema = {"fields": [], "groups": [], "tool_groups": [], "known_tools": [], "known_agents": []}

    try:
        definition = gateway.get_agent_definition(name)
    except gateway.GatewayError as e:
        return render(request, "error.html", {
            "error_title": "Agent Not Found",
            "error_message": e.message,
            "pending_approvals": gateway.get_approval_count(),
        }, status=e.status_code)

    pending_approvals = gateway.get_approval_count()

    return render(request, "builder.html", {
        "schema_json": json.dumps(schema),
        "initial_json": json.dumps({
            "mode": "edit",
            "agent_name": name,
            "frontmatter": definition.get("frontmatter", {}),
            "system_prompt": definition.get("system_prompt", ""),
        }),
        "mode": "edit",
        "agent_name": name,
        "pending_approvals": pending_approvals,
    })


def builder_save(request):
    if request.method != "POST":
        return HttpResponse(status=405)

    try:
        payload = json.loads(request.body)
    except (json.JSONDecodeError, ValueError):
        return render(request, "partials/builder_errors.html", {
            "errors": [{"field": "_global", "message": "Invalid request data"}],
        })

    mode = payload.pop("_mode", "create")
    name = payload.get("name", "")

    try:
        if mode == "edit":
            gateway.update_agent(name, payload)
        else:
            gateway.create_agent(payload)

        resp = HttpResponse(status=204)
        resp["HX-Redirect"] = f"/builder/{name}/"
        return resp

    except gateway.GatewayValidationError as e:
        return render(request, "partials/builder_errors.html", {
            "errors": e.errors,
        })
    except gateway.GatewayError as e:
        return render(request, "partials/builder_errors.html", {
            "errors": [{"field": "_global", "message": e.message}],
        })


def builder_delete(request, name):
    if request.method != "POST":
        return HttpResponse(status=405)

    try:
        gateway.delete_agent(name)
        resp = HttpResponse(status=204)
        resp["HX-Redirect"] = "/"
        return resp
    except gateway.GatewayError as e:
        return render(request, "partials/builder_errors.html", {
            "errors": [{"field": "_global", "message": e.message}],
        })


def builder_context(request, name):
    try:
        context = gateway.get_agent_context(name)
        return render(request, "partials/builder_context.html", {
            "context": context,
        })
    except gateway.GatewayError:
        return HttpResponse('<div class="builder-empty">Context unavailable</div>')


def builder_overview(request, name):
    try:
        agent = gateway.get_agent(name)
        connected_agents = _resolve_connected_agents(agent)
        return render(request, "partials/builder_overview.html", {
            "agent": agent,
            "connected_agents": connected_agents,
        })
    except gateway.GatewayError:
        return HttpResponse('<div class="builder-empty">Agent overview unavailable</div>')


def _resolve_connected_agents(agent: dict) -> list[dict]:
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
