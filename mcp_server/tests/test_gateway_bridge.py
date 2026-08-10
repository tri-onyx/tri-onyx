"""Gateway bridge: frame handling, correlation, timeouts and disconnects."""

from __future__ import annotations

import asyncio

import pytest
from connector.protocol import (
    AgentErrorMessage,
    AgentResultMessage,
    AgentStepMessage,
    AgentTextMessage,
)

from mcp_server.gateway_bridge import GatewayBridge, GatewayError, make_room_id

CHANNEL = {"platform": "mcp", "room_id": "mcp-conv-1"}


class FakeGatewayClient:
    """Stands in for connector.gateway_client.GatewayClient."""

    def __init__(self, config, *, platform="matrix", on_outbound=None, on_disconnect=None, **_):
        self.config = config
        self.platform = platform
        self.on_outbound = on_outbound
        self.on_disconnect = on_disconnect
        self.sent = []
        self.registered = True
        self.stopped = False

    # -- GatewayClient surface used by the bridge ------------------------

    @property
    def is_registered(self) -> bool:
        return self.registered

    async def wait_registered(self, timeout=None) -> bool:
        return self.registered

    async def start(self) -> None:
        await asyncio.sleep(3600)

    async def stop(self) -> None:
        self.stopped = True

    async def send_message(self, msg) -> None:
        self.sent.append(msg)

    # -- test helpers ----------------------------------------------------

    async def emit(self, msg) -> None:
        await self.on_outbound(msg)

    async def drop(self) -> None:
        self.registered = False
        await self.on_disconnect()


def make_bridge(**kwargs) -> GatewayBridge:
    return GatewayBridge(
        gateway_url="ws://gateway:4000/connectors/ws",
        gateway_token="token",
        connector_id="mcp",
        default_timeout=kwargs.pop("default_timeout", 5.0),
        client_factory=FakeGatewayClient,
        **kwargs,
    )


# ---------------------------------------------------------------------------
# room ids
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "conversation_id,expected",
    [
        (None, "mcp-default"),
        ("", "mcp-default"),
        ("   ", "mcp-default"),
        ("chat-42", "mcp-chat-42"),
        ("a/b c:d", "mcp-a-b-c-d"),
        ("!room:matrix.org", "mcp-room-matrix-org"),
        ("../../etc/passwd", "mcp-etc-passwd"),
        ("x" * 200, "mcp-" + "x" * 64),
    ],
)
def test_room_ids_are_namespaced_and_sanitized(conversation_id, expected):
    assert make_room_id("mcp", conversation_id) == expected


def test_room_id_prefix_is_configurable():
    assert make_room_id("custom", "abc") == "custom-abc"


# ---------------------------------------------------------------------------
# Request / response
# ---------------------------------------------------------------------------


async def test_registers_as_the_mcp_platform():
    bridge = make_bridge()
    assert bridge._client.platform == "mcp"
    assert bridge._client.config.connector_id == "mcp"


async def test_ask_collects_text_until_agent_result():
    bridge = make_bridge()
    client = bridge._client

    task = asyncio.create_task(bridge.ask("main", "hello", "mcp-conv-1"))
    await asyncio.sleep(0.01)

    sent = client.sent[0]
    assert sent.agent_name == "main"
    assert sent.content == "hello"
    assert sent.channel == CHANNEL
    assert sent.trust == {"level": "verified", "sender": "mcp-operator"}

    await client.emit(AgentTextMessage(type="agent_text", agent_name="main", channel=CHANNEL, content="part one"))
    await client.emit(AgentStepMessage(type="agent_step", agent_name="main", channel=CHANNEL, step_type="tool_use", name="Read"))
    await client.emit(AgentTextMessage(type="agent_text", agent_name="main", channel=CHANNEL, content="part two"))
    await client.emit(AgentResultMessage(type="agent_result", agent_name="main", channel=CHANNEL))

    assert await task == "part one\n\npart two"


async def test_ask_surfaces_agent_errors():
    bridge = make_bridge()
    client = bridge._client
    task = asyncio.create_task(bridge.ask("main", "hi", "mcp-conv-1"))
    await asyncio.sleep(0.01)
    await client.emit(
        AgentErrorMessage(type="agent_error", agent_name="main", channel=CHANNEL, error="boom")
    )
    with pytest.raises(GatewayError, match="boom"):
        await task


async def test_result_without_text_yields_empty_reply():
    bridge = make_bridge()
    client = bridge._client
    task = asyncio.create_task(bridge.ask("main", "hi", "mcp-conv-1"))
    await asyncio.sleep(0.01)
    await client.emit(AgentResultMessage(type="agent_result", agent_name="main", channel=CHANNEL))
    assert await task == ""


async def test_frames_for_another_agent_or_room_are_ignored():
    bridge = make_bridge(default_timeout=0.2)
    client = bridge._client
    task = asyncio.create_task(bridge.ask("main", "hi", "mcp-conv-1"))
    await asyncio.sleep(0.01)

    other_channel = {"platform": "mcp", "room_id": "mcp-conv-2"}
    await client.emit(AgentTextMessage(type="agent_text", agent_name="main", channel=other_channel, content="not mine"))
    await client.emit(AgentTextMessage(type="agent_text", agent_name="other", channel=CHANNEL, content="not mine"))
    await client.emit(AgentResultMessage(type="agent_result", agent_name="main", channel=other_channel))

    with pytest.raises(GatewayError, match="did not respond"):
        await task


async def test_timeout_produces_a_clean_error():
    bridge = make_bridge(default_timeout=0.05)
    task = asyncio.create_task(bridge.ask("main", "hi", "mcp-conv-1"))
    with pytest.raises(GatewayError, match="did not respond within"):
        await task
    assert bridge._turns == {}


async def test_disconnect_fails_in_flight_requests():
    bridge = make_bridge()
    client = bridge._client
    task = asyncio.create_task(bridge.ask("main", "hi", "mcp-conv-1"))
    await asyncio.sleep(0.01)
    await client.drop()
    with pytest.raises(GatewayError, match="(?i)connection.*lost"):
        await task


async def test_ask_fails_fast_when_never_connected():
    bridge = make_bridge()
    bridge._client.registered = False
    with pytest.raises(GatewayError, match="Not connected"):
        await bridge.ask("main", "hi", "mcp-conv-1")


async def test_concurrent_asks_on_one_conversation_are_serialised():
    bridge = make_bridge()
    client = bridge._client

    first = asyncio.create_task(bridge.ask("main", "one", "mcp-conv-1"))
    await asyncio.sleep(0.01)
    second = asyncio.create_task(bridge.ask("main", "two", "mcp-conv-1"))
    await asyncio.sleep(0.01)

    # The second request waits for the first turn to finish.
    assert [m.content for m in client.sent] == ["one"]

    await client.emit(AgentTextMessage(type="agent_text", agent_name="main", channel=CHANNEL, content="a"))
    await client.emit(AgentResultMessage(type="agent_result", agent_name="main", channel=CHANNEL))
    assert await first == "a"

    await asyncio.sleep(0.01)
    assert [m.content for m in client.sent] == ["one", "two"]
    await client.emit(AgentTextMessage(type="agent_text", agent_name="main", channel=CHANNEL, content="b"))
    await client.emit(AgentResultMessage(type="agent_result", agent_name="main", channel=CHANNEL))
    assert await second == "b"


async def test_different_conversations_run_in_parallel():
    bridge = make_bridge()
    client = bridge._client
    channel_two = {"platform": "mcp", "room_id": "mcp-conv-2"}

    first = asyncio.create_task(bridge.ask("main", "one", "mcp-conv-1"))
    second = asyncio.create_task(bridge.ask("main", "two", "mcp-conv-2"))
    await asyncio.sleep(0.01)
    assert {m.channel["room_id"] for m in client.sent} == {"mcp-conv-1", "mcp-conv-2"}

    await client.emit(AgentResultMessage(type="agent_result", agent_name="main", channel=channel_two))
    await client.emit(AgentResultMessage(type="agent_result", agent_name="main", channel=CHANNEL))
    assert await first == ""
    assert await second == ""


async def test_stop_is_idempotent():
    bridge = make_bridge()
    await bridge.stop()
    assert bridge._client.stopped
