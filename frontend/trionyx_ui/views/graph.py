import json

from django.http import JsonResponse
from django.shortcuts import render

from trionyx_ui import gateway


def graph(request):
    return render(request, "graph.html")


def graph_data(request):
    try:
        agents = gateway.get_agents()
    except gateway.GatewayError:
        agents = []

    analysis = gateway.get_graph_analysis()

    return JsonResponse({"agents": agents, "analysis": analysis})
