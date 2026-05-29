from django.urls import path
from trionyx_ui.views import approvals, chat, dashboard, graph

urlpatterns = [
    path("healthz", dashboard.healthz, name="healthz"),
    path("", dashboard.index, name="dashboard"),
    path("dashboard/summary", dashboard.dashboard_summary, name="dashboard-summary"),
    path("dashboard/agents", dashboard.dashboard_agents, name="dashboard-agents"),
    path("graph/", graph.graph, name="graph"),
    path("graph/data", graph.graph_data, name="graph-data"),
    path("agents/<str:name>/", chat.agent_chat, name="agent-chat"),
    path("agents/<str:name>/sessions", chat.agent_sessions, name="agent-sessions"),
    path("agents/<str:name>/start", chat.agent_start, name="agent-start"),
    path("agents/<str:name>/status-check", chat.agent_status_check, name="agent-status-check"),
    path("agents/<str:name>/prompt", chat.agent_prompt, name="agent-prompt"),
    path("agents/<str:name>/stop", chat.agent_stop, name="agent-stop"),
    path("workspace/images/<str:agent_name>/<str:session_id>/<str:image_id>", chat.session_image, name="session-image"),
    path("approvals/badge", approvals.approvals_badge, name="approvals-badge"),
    path("approvals/dropdown", approvals.approvals_dropdown, name="approvals-dropdown"),
    path("approvals/<str:item_id>", approvals.approval_action, name="approval-action"),
]
