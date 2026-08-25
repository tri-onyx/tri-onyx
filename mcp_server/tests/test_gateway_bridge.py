"""Gateway bridge: frame handling, correlation, early-return turns and TTLs."""

from __future__ import annotations

import asyncio
import time

import pytest
from connector.protocol import (
    AgentErrorMessage,
    AgentResultMessage,
    AgentStepMessage,
    AgentTextMessage,
    AgentTypingMessage,
)

import mcp_server.gateway_bridge as gateway_bridge_module
from mcp_server.gateway_bridge import GatewayBridge, GatewayError, make_room_id

CHANNEL = {"platform": "mcp", "room_id": "mcp-conv-1"}
KEY = ("main", "mcp-conv-1")


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
        soft_timeout=kwargs.pop("soft_timeout", 5.0),
        parked_ttl=kwargs.pop("parked_ttl", 60.0),
        client_factory=FakeGatewayClient,
        **kwargs,
    )


async def finish(client, content="ok", channel=CHANNEL, agent="main"):
    if content:
        await client.emit(
            AgentTextMessage(type="agent_text", agent_name=agent, channel=channel, content=content)
        )
    await client.emit(
        AgentResultMessage(type="agent_result", agent_name=agent, channel=channel)
    )


def typing(is_typing=True, channel=CHANNEL, agent="main"):
    return AgentTypingMessage(
        type="agent_typing", agent_name=agent, channel=channel, is_typing=is_typing
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


def test_room_id_is_scoped_to_the_authenticated_client():
    # Same conversation id, two credentials -> two keys, so neither can attach
    # to the other's turn or collect its reply.
    one = make_room_id("mcp", "shared", "client-one")
    two = make_room_id("mcp", "shared", "client-two")
    assert one != two
    assert one.endswith("-shared") and two.endswith("-shared")
    # Stable for a given client (a token refresh keeps the conversation).
    assert make_room_id("mcp", "shared", "client-one") == one
    # No credential material is echoed into the room id.
    assert "client-one" not in one


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
    # No sender identity behind an LLM-composed message: untrusted content.
    assert sent.trust == {"level": "unverified", "sender": "mcp-operator"}

    await client.emit(AgentTextMessage(type="agent_text", agent_name="main", channel=CHANNEL, content="part one"))
    await client.emit(AgentStepMessage(type="agent_step", agent_name="main", channel=CHANNEL, step_type="tool_use", name="Read"))
    await client.emit(AgentTextMessage(type="agent_text", agent_name="main", channel=CHANNEL, content="part two"))
    await client.emit(AgentResultMessage(type="agent_result", agent_name="main", channel=CHANNEL))

    status = await task
    assert status.pending is False
    assert status.reply == "part one\n\npart two"


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


async def test_agent_error_sent_under_the_gateways_message_key_is_surfaced():
    # The gateway's agent_error frame carries the detail as "message", not
    # "error" — the bridge must read both.
    bridge = make_bridge()
    client = bridge._client
    task = asyncio.create_task(bridge.ask("main", "hi", "mcp-conv-1"))
    await asyncio.sleep(0.01)
    await client.emit(
        AgentErrorMessage(
            type="agent_error", agent_name="main", channel=CHANNEL, message="boom detail"
        )
    )
    with pytest.raises(GatewayError, match="boom detail"):
        await task


async def test_result_without_text_yields_empty_reply():
    bridge = make_bridge()
    client = bridge._client
    task = asyncio.create_task(bridge.ask("main", "hi", "mcp-conv-1"))
    await asyncio.sleep(0.01)
    await client.emit(AgentResultMessage(type="agent_result", agent_name="main", channel=CHANNEL))
    assert (await task).reply == ""


async def test_frames_for_another_agent_or_room_are_ignored():
    bridge = make_bridge(soft_timeout=0.05)
    client = bridge._client
    task = asyncio.create_task(bridge.ask("main", "hi", "mcp-conv-1"))
    await asyncio.sleep(0.01)

    other_channel = {"platform": "mcp", "room_id": "mcp-conv-2"}
    await client.emit(AgentTextMessage(type="agent_text", agent_name="main", channel=other_channel, content="not mine"))
    await client.emit(AgentTextMessage(type="agent_text", agent_name="other", channel=CHANNEL, content="not mine"))
    await client.emit(AgentResultMessage(type="agent_result", agent_name="main", channel=other_channel))

    status = await task
    assert status.pending is True
    assert status.partial_chars == 0
    assert KEY in bridge._turns  # the turn was neither settled nor mutated


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
    assert (await first).reply == ""
    assert (await second).reply == ""


async def test_stop_is_idempotent():
    bridge = make_bridge()
    await bridge.stop()
    assert bridge._client.stopped


# ---------------------------------------------------------------------------
# Early return: soft deadline, attach, parked results
# ---------------------------------------------------------------------------


async def test_soft_deadline_returns_pending_without_killing_the_turn():
    bridge = make_bridge(soft_timeout=0.05)
    status = await bridge.ask("main", "hi", "mcp-conv-1")
    assert status.pending is True
    turn = bridge._turns[KEY]
    assert not turn.future.done()
    assert not turn.future.cancelled()


async def test_poll_attaches_to_the_running_turn_and_gets_the_reply():
    bridge = make_bridge(soft_timeout=0.05)
    client = bridge._client
    assert (await bridge.ask("main", "hello", "mcp-conv-1")).pending is True

    poll = asyncio.create_task(bridge.ask("main", "status?", "mcp-conv-1"))
    await asyncio.sleep(0.01)
    assert len(client.sent) == 1  # the poll was not forwarded to the agent
    await finish(client, "the reply")
    assert (await poll).reply == "the reply"
    assert bridge._turns == {}


async def test_two_waiters_on_one_turn_both_receive_the_reply():
    bridge = make_bridge()
    client = bridge._client
    first = asyncio.create_task(bridge.ask("main", "one", "mcp-conv-1"))
    await asyncio.sleep(0.01)
    second = asyncio.create_task(bridge.ask("main", "poll", "mcp-conv-1"))
    await asyncio.sleep(0.01)

    assert len(client.sent) == 1
    await finish(client, "a")
    assert (await first).reply == "a"
    assert (await second).reply == "a"
    assert bridge._turns == {}


async def test_key_is_idle_after_delivery_so_the_next_message_is_sent():
    bridge = make_bridge()
    client = bridge._client
    task = asyncio.create_task(bridge.ask("main", "one", "mcp-conv-1"))
    await asyncio.sleep(0.01)
    await finish(client, "a")
    assert (await task).reply == "a"

    next_task = asyncio.create_task(bridge.ask("main", "next", "mcp-conv-1"))
    await asyncio.sleep(0.01)
    assert [m.content for m in client.sent] == ["one", "next"]
    await finish(client, "b")
    assert (await next_task).reply == "b"


async def test_parked_result_is_delivered_to_the_next_call():
    bridge = make_bridge(soft_timeout=0.02)
    client = bridge._client
    assert (await bridge.ask("main", "hello", "mcp-conv-1")).pending is True

    await finish(client, "late reply")  # lands with nobody waiting
    assert bridge._turns[KEY].future.done()

    status = await bridge.ask("main", "status?", "mcp-conv-1")
    assert status.pending is False
    assert status.reply == "late reply"
    assert len(client.sent) == 1
    assert bridge._turns == {}


async def test_parked_result_is_delivered_even_to_a_new_substantive_message():
    # The contract's sharp edge: a genuinely new question arriving on a parked
    # key receives the previous reply and its own message is dropped — so the
    # status says so, naming the message the reply actually answers.
    bridge = make_bridge(soft_timeout=0.02)
    client = bridge._client
    await bridge.ask("main", "hello", "mcp-conv-1")
    await finish(client, "old reply")

    status = await bridge.ask("main", "a totally new question", "mcp-conv-1")
    assert status.reply == "old reply"
    assert status.stale is True
    assert status.prompt == "hello"
    assert len(client.sent) == 1


async def test_a_fresh_turns_reply_is_not_marked_stale():
    bridge = make_bridge()
    client = bridge._client
    task = asyncio.create_task(bridge.ask("main", "hello", "mcp-conv-1"))
    await asyncio.sleep(0.01)
    await finish(client, "answer")
    status = await task
    assert status.stale is False
    assert status.prompt == ""


async def test_parked_error_delivered_to_a_later_call_says_which_message_it_is():
    bridge = make_bridge(soft_timeout=0.02)
    client = bridge._client
    await bridge.ask("main", "the first question", "mcp-conv-1")
    await client.emit(
        AgentErrorMessage(type="agent_error", agent_name="main", channel=CHANNEL, error="crashed")
    )
    with pytest.raises(GatewayError, match="the first question"):
        await bridge.ask("main", "an unrelated new question", "mcp-conv-1")


async def test_parked_error_is_delivered_to_the_next_call():
    bridge = make_bridge(soft_timeout=0.02)
    client = bridge._client
    await bridge.ask("main", "hello", "mcp-conv-1")
    await client.emit(
        AgentErrorMessage(type="agent_error", agent_name="main", channel=CHANNEL, error="crashed")
    )

    with pytest.raises(GatewayError, match="crashed"):
        await bridge.ask("main", "status?", "mcp-conv-1")
    assert bridge._turns == {}

    # The key is idle again: the following message starts a fresh turn.
    assert (await bridge.ask("main", "retry", "mcp-conv-1")).pending is True
    assert [m.content for m in client.sent] == ["hello", "retry"]


# ---------------------------------------------------------------------------
# Hard timeout
# ---------------------------------------------------------------------------


async def test_hard_timeout_wakes_an_attached_caller():
    bridge = make_bridge(default_timeout=0.05, soft_timeout=5.0)
    with pytest.raises(GatewayError, match="did not respond within"):
        await bridge.ask("main", "hi", "mcp-conv-1")
    assert bridge._turns == {}


async def test_hard_timeout_fails_an_unattended_turn():
    bridge = make_bridge(default_timeout=0.05, soft_timeout=0.02)
    assert (await bridge.ask("main", "hi", "mcp-conv-1")).pending is True

    await asyncio.sleep(0.1)
    assert bridge._turns[KEY].future.done()  # parked as an error

    with pytest.raises(GatewayError, match="did not respond within"):
        await bridge.ask("main", "status?", "mcp-conv-1")
    assert len(bridge._client.sent) == 1
    assert bridge._turns == {}


async def test_watchdog_is_cancelled_once_the_turn_is_delivered():
    bridge = make_bridge()
    client = bridge._client
    task = asyncio.create_task(bridge.ask("main", "hi", "mcp-conv-1"))
    await asyncio.sleep(0.01)
    turn = bridge._turns[KEY]
    await finish(client, "a")
    await task
    await asyncio.sleep(0)
    assert turn.watchdog.done()


async def test_cancelled_caller_leaves_the_turn_running():
    # asyncio.wait (unlike wait_for) must not propagate the caller's
    # cancellation into the turn future — the turn survives the caller.
    bridge = make_bridge()
    client = bridge._client
    task = asyncio.create_task(bridge.ask("main", "hi", "mcp-conv-1"))
    await asyncio.sleep(0.01)
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task

    assert KEY in bridge._turns
    assert not bridge._turns[KEY].future.cancelled()

    await finish(client, "survived")
    assert (await bridge.ask("main", "status?", "mcp-conv-1")).reply == "survived"


# ---------------------------------------------------------------------------
# Parked-result TTL
# ---------------------------------------------------------------------------


async def test_parked_result_expires_after_its_ttl():
    bridge = make_bridge(soft_timeout=0.02, parked_ttl=0.05)
    client = bridge._client
    await bridge.ask("main", "hello", "mcp-conv-1")
    await finish(client, "stale")

    await asyncio.sleep(0.1)
    status = await bridge.ask("main", "a new question", "mcp-conv-1")
    assert status.pending is True  # a NEW turn was started, not the stale reply
    assert [m.content for m in client.sent] == ["hello", "a new question"]


async def test_parked_ttl_is_measured_from_completion_not_from_start():
    bridge = make_bridge(soft_timeout=0.02, parked_ttl=0.1)
    client = bridge._client
    await bridge.ask("main", "hello", "mcp-conv-1")
    await asyncio.sleep(0.15)  # turn is older than the TTL, but still running
    await finish(client, "fresh")

    status = await bridge.ask("main", "status?", "mcp-conv-1")
    assert status.reply == "fresh"


async def test_sweeper_drops_abandoned_parked_results(monkeypatch):
    monkeypatch.setattr(gateway_bridge_module, "_SWEEP_INTERVAL_S", 0.02)
    bridge = make_bridge(soft_timeout=0.02, parked_ttl=0.01)
    client = bridge._client
    await bridge.start()
    try:
        await bridge.ask("main", "hello", "mcp-conv-1")
        await finish(client, "abandoned")
        await asyncio.sleep(0.1)
        assert bridge._turns == {}
    finally:
        await bridge.stop()


# ---------------------------------------------------------------------------
# Disconnects
# ---------------------------------------------------------------------------


async def test_disconnect_does_not_discard_an_already_parked_result():
    bridge = make_bridge(soft_timeout=0.02)
    client = bridge._client
    await bridge.ask("main", "hello", "mcp-conv-1")
    await finish(client, "safe")

    await client.drop()
    client.registered = True
    assert (await bridge.ask("main", "status?", "mcp-conv-1")).reply == "safe"


async def test_disconnect_parks_the_error_for_an_unattended_turn():
    bridge = make_bridge(soft_timeout=0.02)
    client = bridge._client
    await bridge.ask("main", "hello", "mcp-conv-1")

    await client.drop()
    client.registered = True
    with pytest.raises(GatewayError, match="(?i)connection.*lost"):
        await bridge.ask("main", "status?", "mcp-conv-1")


# ---------------------------------------------------------------------------
# Activity phases
# ---------------------------------------------------------------------------


async def test_activity_reports_the_session_starting_phase():
    bridge = make_bridge(soft_timeout=0.05)
    client = bridge._client
    task = asyncio.create_task(bridge.ask("main", "hi", "mcp-conv-1"))
    await asyncio.sleep(0.01)
    await client.emit(typing(True))
    assert "starting" in (await task).activity


async def test_activity_reports_the_agent_is_ready():
    bridge = make_bridge(soft_timeout=0.05)
    client = bridge._client
    task = asyncio.create_task(bridge.ask("main", "hi", "mcp-conv-1"))
    await asyncio.sleep(0.01)
    await client.emit(typing(True))
    await client.emit(typing(False))
    assert "thinking" in (await task).activity


async def test_activity_reports_the_running_tool():
    bridge = make_bridge(soft_timeout=0.05)
    client = bridge._client
    task = asyncio.create_task(bridge.ask("main", "hi", "mcp-conv-1"))
    await asyncio.sleep(0.01)
    await client.emit(typing(True))
    await client.emit(
        AgentStepMessage(type="agent_step", agent_name="main", channel=CHANNEL, step_type="tool_use", name="Bash")
    )
    assert "Bash" in (await task).activity


async def test_later_typing_frames_do_not_clobber_a_more_specific_phase():
    bridge = make_bridge(soft_timeout=0.05)
    client = bridge._client
    task = asyncio.create_task(bridge.ask("main", "hi", "mcp-conv-1"))
    await asyncio.sleep(0.01)
    await client.emit(
        AgentStepMessage(type="agent_step", agent_name="main", channel=CHANNEL, step_type="tool_use", name="Bash")
    )
    await client.emit(typing(True))
    assert "Bash" in (await task).activity


async def test_pending_status_reports_elapsed_and_partial_output():
    bridge = make_bridge(soft_timeout=0.05)
    client = bridge._client
    task = asyncio.create_task(bridge.ask("main", "hi", "mcp-conv-1"))
    await asyncio.sleep(0.01)
    await client.emit(
        AgentTextMessage(type="agent_text", agent_name="main", channel=CHANNEL, content="part one")
    )
    status = await task
    assert status.pending is True
    assert status.partial_chars == len("part one")
    assert status.elapsed > 0
    assert status.checks == 1


async def test_checks_counts_repeated_polls():
    bridge = make_bridge(soft_timeout=0.02)
    for expected in (1, 2, 3):
        status = await bridge.ask("main", "hi", "mcp-conv-1")
        assert status.pending is True
        assert status.checks == expected
    assert len(bridge._client.sent) == 1


async def test_frames_after_completion_do_not_mutate_a_parked_result():
    bridge = make_bridge(soft_timeout=0.02)
    client = bridge._client
    await bridge.ask("main", "hello", "mcp-conv-1")
    await finish(client, "a")
    await client.emit(
        AgentTextMessage(type="agent_text", agent_name="main", channel=CHANNEL, content="b")
    )
    assert (await bridge.ask("main", "status?", "mcp-conv-1")).reply == "a"


# ---------------------------------------------------------------------------
# Shutdown
# ---------------------------------------------------------------------------


async def test_stop_wakes_waiters_and_leaves_no_watchdog_tasks():
    bridge = make_bridge()
    task = asyncio.create_task(bridge.ask("main", "hi", "mcp-conv-1"))
    await asyncio.sleep(0.01)
    await bridge.stop()
    with pytest.raises(GatewayError, match="shutting down"):
        await task
    await asyncio.sleep(0)
    leftovers = [t for t in asyncio.all_tasks() if (t.get_name() or "").startswith("turn-deadline")]
    assert leftovers == []


# ---------------------------------------------------------------------------
# Abandoned turns
# ---------------------------------------------------------------------------


async def test_late_frames_from_an_abandoned_turn_do_not_settle_the_next_turn():
    # The gateway has no cancel frame, so a turn we gave up on keeps running
    # there and still emits its result. It must not settle the turn that took
    # over the key in the meantime.
    bridge = make_bridge(default_timeout=0.05, soft_timeout=0.02)
    client = bridge._client
    assert (await bridge.ask("main", "first", "mcp-conv-1")).pending is True
    await asyncio.sleep(0.1)  # the hard deadline abandons the turn
    with pytest.raises(GatewayError, match="did not respond within"):
        await bridge.ask("main", "poll", "mcp-conv-1")
    assert bridge._turns == {}

    second = asyncio.create_task(
        bridge.ask("main", "second", "mcp-conv-1", wait_timeout=0.05, hard_timeout=5.0)
    )
    await asyncio.sleep(0.01)
    await finish(client, "the FIRST message's answer")

    status = await second
    assert status.pending is True  # swallowed, not delivered as the new answer
    assert status.partial_chars == 0
    assert KEY in bridge._turns

    # Resynchronised: the new turn's own frames settle it.
    await finish(client, "the second message's answer")
    collected = await bridge.ask("main", "poll", "mcp-conv-1")
    assert collected.reply == "the second message's answer"


async def test_only_one_terminal_frame_is_swallowed_per_abandoned_turn():
    bridge = make_bridge(default_timeout=0.05, soft_timeout=0.02)
    client = bridge._client
    await bridge.ask("main", "first", "mcp-conv-1")
    await asyncio.sleep(0.1)
    with pytest.raises(GatewayError):
        await bridge.ask("main", "poll", "mcp-conv-1")

    assert len(bridge._abandoned[KEY]) == 1
    await finish(client, "late")
    assert KEY not in bridge._abandoned


async def test_a_disconnect_abandons_in_flight_turns():
    bridge = make_bridge(soft_timeout=0.02)
    client = bridge._client
    await bridge.ask("main", "hello", "mcp-conv-1")
    await client.drop()
    assert len(bridge._abandoned[KEY]) == 1

    # The reply the gateway kept working on is not handed to the next turn.
    client.registered = True
    with pytest.raises(GatewayError, match="(?i)connection.*lost"):
        await bridge.ask("main", "poll", "mcp-conv-1")
    await finish(client, "from the lost turn")
    assert (await bridge.ask("main", "next", "mcp-conv-1")).pending is True


async def test_abandonment_bookkeeping_expires(monkeypatch):
    # Belt and braces: a frame that can never arrive (its result was emitted
    # while no connector was attached) must not swallow frames forever.
    monkeypatch.setattr(gateway_bridge_module, "_ABANDONED_TTL_S", 0.01)
    bridge = make_bridge(default_timeout=0.05, soft_timeout=0.02)
    await bridge.ask("main", "hello", "mcp-conv-1")
    await asyncio.sleep(0.1)
    assert bridge._abandoned[KEY]
    bridge._expire_abandoned(time.monotonic())
    assert bridge._abandoned == {}


# ---------------------------------------------------------------------------
# Lock table
# ---------------------------------------------------------------------------


async def test_idle_locks_are_pruned(monkeypatch):
    monkeypatch.setattr(gateway_bridge_module, "_SWEEP_INTERVAL_S", 0.02)
    bridge = make_bridge()
    client = bridge._client
    await bridge.start()
    try:
        task = asyncio.create_task(bridge.ask("main", "hi", "mcp-conv-1"))
        await asyncio.sleep(0.01)
        await finish(client, "done")
        await task
        assert bridge._locks  # the key's lock is still there
        await asyncio.sleep(0.1)
        assert bridge._locks == {}  # nothing in flight, nothing parked
    finally:
        await bridge.stop()


async def test_a_lock_in_use_is_never_pruned():
    bridge = make_bridge(soft_timeout=0.02)
    client = bridge._client
    await bridge.ask("main", "hi", "mcp-conv-1")  # leaves a running turn
    assert bridge._prune_locks() == 0
    assert KEY in bridge._locks

    await finish(client, "done")  # parked, still not collected
    assert bridge._prune_locks() == 0
