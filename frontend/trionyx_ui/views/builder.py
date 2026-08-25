import json
import logging

from django.http import HttpResponse
from django.shortcuts import render
from django.utils.safestring import mark_safe

from trionyx_ui import gateway
from trionyx_ui.views.helpers import (
    render_markdown as _render_md,
    resolve_connected_agents as _resolve_connected_agents,
)

logger = logging.getLogger(__name__)


def builder_new(request):
    try:
        schema = gateway.get_agent_schema()
    except gateway.GatewayError:
        schema = {"fields": [], "groups": [], "tool_groups": [], "known_tools": [], "known_agents": []}

    pending_approvals = gateway.get_approval_count()

    return render(request, "builder.html", {
        "schema": schema,
        "initial": {
            "mode": "create",
            "agent_name": None,
            "frontmatter": {},
            "system_prompt": "",
        },
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
        "schema": schema,
        "initial": {
            "mode": "edit",
            "agent_name": name,
            "frontmatter": definition.get("frontmatter", {}),
            "system_prompt": definition.get("system_prompt", ""),
        },
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
            "context_html": mark_safe(_render_md(context)),
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
