from django.urls import path
from trionyx_ui.views import approvals, chat, dashboard

urlpatterns = [
    path("", dashboard.index, name="dashboard"),
    path("agents/<str:name>/", chat.agent_chat, name="agent-chat"),
    path("agents/<str:name>/start", chat.agent_start, name="agent-start"),
    path("agents/<str:name>/prompt", chat.agent_prompt, name="agent-prompt"),
    path("agents/<str:name>/stop", chat.agent_stop, name="agent-stop"),
    path("approvals/badge", approvals.approvals_badge, name="approvals-badge"),
    path("approvals/dropdown", approvals.approvals_dropdown, name="approvals-dropdown"),
    path("approvals/<str:item_id>", approvals.approval_action, name="approval-action"),
]
