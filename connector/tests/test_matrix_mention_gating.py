"""Mention-gating must not be bypassable by replying to an arbitrary message.

docs/matrix-guide.md documents ``mode: mention`` as requiring an explicit
@mention before the agent is invoked in a group room, with one carve-out:
"Replies to the bot's own messages also trigger the agent (continuing a
thread)". A reply to some *other* member's message must still be gated —
otherwise any room member can invoke the agent at will just by hitting
"reply" on any message, defeating the point of mention mode.
"""

from types import SimpleNamespace

from nio import RoomGetEventResponse

from connector.adapters.matrix import MatrixAdapter
from connector.config import AdapterConfig, RoomConfig

ROOM_ID = "!room:example.org"
BOT_USER_ID = "@tri-onyx-bot:example.org"
ATTACKER = "@random-member:example.org"


def _room_get_event_response(sender: str) -> RoomGetEventResponse:
    resp = RoomGetEventResponse()
    resp.event = SimpleNamespace(sender=sender)
    return resp


def _reply_event(*, in_reply_to: str, body: str = "no mention here") -> SimpleNamespace:
    return SimpleNamespace(
        sender=ATTACKER,
        event_id="$attacker-reply",
        body=body,
        formatted_body="",
        source={
            "content": {
                "body": body,
                "m.relates_to": {"m.in_reply_to": {"event_id": in_reply_to}},
            }
        },
    )


def _adapter(room_get_event_result: RoomGetEventResponse) -> MatrixAdapter:
    adapter = MatrixAdapter(AdapterConfig())
    adapter._config.user_id = BOT_USER_ID
    adapter._initial_sync_done = True
    adapter._rooms[ROOM_ID] = RoomConfig(agent="main", mode="mention")

    async def room_get_event(room_id, event_id):
        return room_get_event_result

    adapter._client = SimpleNamespace(room_get_event=room_get_event)
    return adapter


def _group_room() -> SimpleNamespace:
    return SimpleNamespace(room_id=ROOM_ID, member_count=10)


class TestReplyMentionGating:
    async def test_reply_to_another_members_message_is_still_gated(self):
        """A reply to an ordinary member's message must not bypass mention mode."""
        adapter = _adapter(_room_get_event_response(ATTACKER))
        room = _group_room()
        event = _reply_event(in_reply_to="$someone-elses-message")

        await adapter._on_room_message(room, event)

        assert ROOM_ID not in adapter._merge_buffers, (
            "a reply to a non-bot message was dispatched to the agent despite "
            "mode: mention and no @mention — mention gating was bypassed"
        )

    async def test_reply_to_the_bots_own_message_still_dispatches(self):
        """The documented carve-out (continuing a thread with the bot) still works."""
        adapter = _adapter(_room_get_event_response(BOT_USER_ID))
        room = _group_room()
        event = _reply_event(in_reply_to="$bots-own-message")

        await adapter._on_room_message(room, event)

        assert ROOM_ID in adapter._merge_buffers
        assert len(adapter._merge_buffers[ROOM_ID]) == 1
