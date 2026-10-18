"""Approval reactions must come from trusted Matrix users only."""

from connector.adapters.matrix import MatrixAdapter
from connector.config import AdapterConfig

ROOM_ID = "!approvals:example.org"
EVENT_ID = "$approval-request"


def _adapter():
    adapter = MatrixAdapter(AdapterConfig(trusted_users=["@owner:hs"]))
    adapter._approval_events[EVENT_ID] = "appr-1"
    seen = []

    async def on_reaction(msg):
        seen.append(msg)

    adapter._on_reaction = on_reaction
    return adapter, seen


class TestApprovalReactionAuthority:
    async def test_untrusted_room_member_cannot_vote_on_an_approval(self):
        adapter, seen = _adapter()
        await adapter._dispatch_reaction(ROOM_ID, EVENT_ID, "👍", "@mallory:hs")
        assert seen == [], (
            "an untrusted room member's reaction was forwarded as an approval "
            "vote; the gateway approves unconditionally"
        )

    async def test_trusted_user_can_vote(self):
        adapter, seen = _adapter()
        await adapter._dispatch_reaction(ROOM_ID, EVENT_ID, "👍", "@owner:hs")
        assert [(m.approval_id, m.emoji) for m in seen] == [("appr-1", "👍")]
