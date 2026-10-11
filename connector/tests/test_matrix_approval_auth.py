"""Approval reactions in Matrix must come from trusted_users."""

from connector.adapters.matrix import MatrixAdapter
from connector.config import AdapterConfig

ROOM_ID = "!room:example.org"
EVENT_ID = "$approval"


def _adapter():
    adapter = MatrixAdapter(AdapterConfig(trusted_users=["@owner:example.org"]))
    adapter._approval_events[EVENT_ID] = "appr-1"
    received = []

    async def on_reaction(msg):
        received.append(msg)

    adapter._on_reaction = on_reaction
    return adapter, received


class TestApprovalReactionAuthorization:
    async def test_untrusted_user_cannot_approve(self):
        adapter, received = _adapter()
        await adapter._dispatch_reaction(ROOM_ID, EVENT_ID, "👍", "@mallory:example.org")
        assert received == [], "an untrusted room member's vote must not reach the gateway"

    async def test_trusted_user_can_approve(self):
        adapter, received = _adapter()
        await adapter._dispatch_reaction(ROOM_ID, EVENT_ID, "👍", "@owner:example.org")
        assert [m.approval_id for m in received] == ["appr-1"]
