"""Tests for gateway frame handling."""

import json

from connector.config import ConnectorConfig
from connector.gateway_client import GatewayClient


def _make_client(**kwargs):
    return GatewayClient(ConnectorConfig(), **kwargs)


class TestHandleFrame:
    async def test_malformed_json_is_dropped_without_raising(self):
        client = _make_client()
        # Must not raise — a bad frame should be logged and skipped so the
        # websocket connection survives.
        await client._handle_frame("this is not json {")

    async def test_frame_with_bad_field_type_is_dropped(self):
        client = _make_client()
        # approval_request runs int(category); a non-numeric string raises
        # ValueError inside decode and must be swallowed.
        frame = json.dumps({"type": "approval_request", "category": "not-a-number"})
        await client._handle_frame(frame)

    async def test_valid_frame_still_dispatched_after_bad_frame(self):
        received = []

        async def on_heartbeat(msg):
            received.append(msg)

        client = _make_client(on_heartbeat=on_heartbeat)
        await client._handle_frame("garbage")
        await client._handle_frame(
            json.dumps(
                {"type": "heartbeat_notification", "agent_name": "main", "content": "hi"}
            )
        )

        assert len(received) == 1
        assert received[0].agent_name == "main"

    async def test_registered_frame_sets_event(self):
        client = _make_client()
        await client._handle_frame(
            json.dumps({"type": "registered", "connector_id": "c1"})
        )
        assert client._registered.is_set()
