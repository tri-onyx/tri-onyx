from django.http import JsonResponse
from django.shortcuts import render

from trionyx_ui import gateway, schema_cache


def graph(request):
    return render(request, "graph.html")


def graph_data(request):
    try:
        agents = gateway.get_agents()
    except gateway.GatewayError:
        agents = []

    analysis = gateway.get_graph_analysis()

    # The gateway owns the risk model (level ordering, 2D matrix, capability
    # adjustment). Pass it through so graph.js derives tooltips from it instead
    # of hardcoding a parallel copy. Empty when the schema fetch has not
    # succeeded yet; the frontend degrades gracefully in that case.
    risk_model = schema_cache.get_schema().get("risk_model", {})

    return JsonResponse(
        {"agents": agents, "analysis": analysis, "risk_model": risk_model}
    )
