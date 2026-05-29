from django.http import JsonResponse
from django.shortcuts import render

from trionyx_ui import gateway


def _dashboard_context():
    try:
        agents = gateway.get_agents()
    except gateway.GatewayError:
        agents = []

    health = gateway.get_health()
    pending_approvals = gateway.get_approval_count()
    heartbeat_status = gateway.get_heartbeat_status()

    running_count = sum(
        1 for a in agents if a.get("status") in ("running", "ready", "starting", "saving_memory")
    )
    idle_count = sum(1 for a in agents if a.get("status") == "inactive")

    status_order = {"running": 0, "ready": 1, "starting": 2, "saving_memory": 3}
    agents.sort(key=lambda a: (
        status_order.get(a.get("status", ""), 99),
        -(a.get("session_count") or 0),
        a.get("name", ""),
    ))

    return {
        "agents": agents,
        "total_count": len(agents),
        "running_count": running_count,
        "idle_count": idle_count,
        "pending_approvals": pending_approvals,
        "heartbeats_enabled": heartbeat_status.get("enabled", False),
        "health": health,
    }


def index(request):
    return render(request, "dashboard.html", _dashboard_context())


def dashboard_summary(request):
    return render(request, "partials/summary_strip.html", _dashboard_context())


def dashboard_agents(request):
    return render(request, "partials/agent_grid.html", _dashboard_context())


def healthz(request):
    gw = gateway.get_health()
    gateway_ok = gw.get("status") != "unreachable"
    return JsonResponse({
        "status": "ok" if gateway_ok else "degraded",
        "gateway": "ok" if gateway_ok else "unreachable",
    }, status=200)
