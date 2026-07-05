"""Tests for Matrix merge-buffer flushing."""

from connector.adapters.matrix import MatrixAdapter
from connector.config import AdapterConfig, RoomConfig

ROOM_ID = "!room:example.org"


def _adapter_with_buffer(buf):
    adapter = MatrixAdapter(AdapterConfig())
    adapter._merge_buffers[ROOM_ID] = buf
    dispatched = []

    async def on_message(msg):
        dispatched.append(msg)

    adapter._on_message = on_message
    return adapter, dispatched


async def _flush(adapter):
    room_cfg = RoomConfig(agent="main")
    await adapter._flush_merge_buffer(ROOM_ID, room_cfg, None, 0)


class TestFlushMergeBuffer:
    async def test_single_sender_merges_into_one_message(self):
        adapter, dispatched = _adapter_with_buffer(
            [
                (0.0, "@alice:hs", "hello", []),
                (1.0, "@alice:hs", "world", [{"url": "mxc://img"}]),
            ]
        )
        await _flush(adapter)

        assert len(dispatched) == 1
        msg = dispatched[0]
        assert msg.agent_name == "main"
        assert msg.content == "hello\nworld"
        assert msg.images == [{"url": "mxc://img"}]
        assert msg.trust["sender"] == "@alice:hs"

    async def test_second_sender_is_not_dropped(self):
        adapter, dispatched = _adapter_with_buffer(
            [
                (0.0, "@alice:hs", "a1", []),
                (1.0, "@alice:hs", "a2", []),
                (2.0, "@bob:hs", "b1", [{"url": "mxc://bob"}]),
            ]
        )
        await _flush(adapter)

        assert [m.content for m in dispatched] == ["a1\na2", "b1"]
        assert [m.trust["sender"] for m in dispatched] == ["@alice:hs", "@bob:hs"]
        assert dispatched[1].images == [{"url": "mxc://bob"}]

    async def test_interleaved_senders_preserve_order_as_runs(self):
        adapter, dispatched = _adapter_with_buffer(
            [
                (0.0, "@alice:hs", "a1", []),
                (1.0, "@bob:hs", "b1", []),
                (2.0, "@bob:hs", "b2", []),
                (3.0, "@alice:hs", "a2", []),
            ]
        )
        await _flush(adapter)

        assert [m.content for m in dispatched] == ["a1", "b1\nb2", "a2"]
        assert [m.trust["sender"] for m in dispatched] == [
            "@alice:hs",
            "@bob:hs",
            "@alice:hs",
        ]

    async def test_empty_buffer_dispatches_nothing(self):
        adapter, dispatched = _adapter_with_buffer([])
        await _flush(adapter)
        assert dispatched == []
