"""Request/response bridge over the gateway's connector WebSocket.

The gateway speaks a streaming protocol: a ``message`` frame starts (or resumes)
an agent session, and the answer arrives as zero or more ``agent_text`` frames
terminated by ``agent_result`` (or ``agent_error``). MCP tools are
request/response, so this module collapses one gateway turn into one string.

Correlation is by ``(agent_name, room_id)`` — the gateway echoes the opaque
channel object back on every frame, and keys its own sessions by
``agent_name:hash(channel)``, so a stable room_id gives a persistent agent
session for a conversation.

A turn can outlive the tool call that started it: the first message to an agent
boots a container and can take minutes, while the MCP client's own tool-call
timeout is much shorter. ``ask`` therefore waits only up to a *soft* deadline
and then reports the turn as still pending; the turn keeps running in the
background, later calls on the same key attach to it (their message is a poll,
not a new prompt), and a reply that lands with nobody waiting is parked until
the next call collects it or a TTL expires it.

The persistent connection, registration and reconnect/backoff all come from
:class:`connector.gateway_client.GatewayClient`; nothing about the wire protocol
is re-implemented here.
"""

from __future__ import annotations

import asyncio
import logging
import re
import time
from dataclasses import dataclass, field
from typing import Any

from connector.config import ConnectorConfig
from connector.gateway_client import GatewayClient
from connector.protocol import (
    AgentErrorMessage,
    AgentResultMessage,
    AgentStepMessage,
    AgentTextMessage,
    AgentTypingMessage,
    InboundMessage,
    OutboundMessage,
)

logger = logging.getLogger(__name__)

PLATFORM = "mcp"

_ROOM_ID_SAFE = re.compile(r"[^A-Za-z0-9_-]+")
_MAX_ROOM_ID_LEN = 64

#: Grace for a reconnect blip before failing a call. Reconnect backoff starts
#: at 1 s, so 10 s covers real blips without eating most of the soft budget.
_RECONNECT_GRACE_S = 10.0

_SWEEP_INTERVAL_S = 60.0

_ACTIVITY = {
    "sent": "the message is queued at the gateway",
    "starting": (
        "the agent session is starting up — the first message to an agent "
        "syncs its git repos and boots a container"
    ),
    "ready": "the agent session is up and the agent is thinking",
    "writing": "the agent has started writing its reply",
}

#: phase -> rank; note_phase only moves forward so a late typing frame cannot
#: clobber a more specific phase (e.g. a tool already running).
_PHASE_RANK = {"sent": 0, "starting": 1, "ready": 2, "tool": 3, "writing": 3}


class GatewayError(RuntimeError):
    """The gateway could not complete the request."""


def make_room_id(prefix: str, conversation_id: str | None) -> str:
    """Namespace and sanitize a caller-supplied conversation id.

    The result is used as the channel ``room_id``, which the gateway hashes into
    a session key — so it must be stable, bounded, and impossible to confuse
    with another connector's rooms.
    """
    raw = (conversation_id or "default").strip() or "default"
    cleaned = _ROOM_ID_SAFE.sub("-", raw).strip("-") or "default"
    cleaned = cleaned[:_MAX_ROOM_ID_LEN]
    return f"{prefix}-{cleaned}"


@dataclass(slots=True, frozen=True)
class TurnStatus:
    """What one tool call learned about a turn.

    ``elapsed`` is the age of the *turn*, not of this call's wait — it answers
    "how long has the agent been at this", which is what the caller needs.
    """

    pending: bool
    reply: str = ""
    elapsed: float = 0.0
    activity: str = ""
    checks: int = 0
    partial_chars: int = 0


@dataclass(slots=True)
class _Turn:
    """One agent turn, possibly outliving the call that started it."""

    future: asyncio.Future[str]
    agent_name: str
    room_id: str
    started_at: float
    hard_timeout: float
    texts: list[str] = field(default_factory=list)
    phase: str = "sent"
    tool_name: str = ""
    finished_at: float | None = None
    waiters: int = 0
    checks: int = 0
    watchdog: asyncio.Task[None] | None = None

    def add_text(self, content: str) -> None:
        if content:
            self.texts.append(content)

    def finish(self) -> None:
        if not self.future.done():
            self.future.set_result("\n\n".join(self.texts).strip())
            self._settle()

    def fail(self, error: str) -> None:
        if not self.future.done():
            self.future.set_exception(GatewayError(error))
            self._settle()

    def _settle(self) -> None:
        if self.finished_at is None:
            self.finished_at = time.monotonic()

    @property
    def elapsed(self) -> float:
        return (self.finished_at or time.monotonic()) - self.started_at

    @property
    def partial_chars(self) -> int:
        return sum(len(t) for t in self.texts)

    @property
    def activity(self) -> str:
        if self.phase == "tool":
            return f"the agent is running the {self.tool_name or 'unknown'} tool"
        return _ACTIVITY.get(self.phase, _ACTIVITY["sent"])

    def note_phase(self, phase: str, *, tool: str = "") -> None:
        if _PHASE_RANK.get(phase, 0) < _PHASE_RANK.get(self.phase, 0):
            return
        self.phase = phase
        if tool:
            self.tool_name = tool

    def status(self, *, pending: bool, reply: str = "") -> TurnStatus:
        return TurnStatus(
            pending=pending,
            reply=reply,
            elapsed=self.elapsed,
            activity=self.activity,
            checks=self.checks,
            partial_chars=self.partial_chars,
        )


class GatewayBridge:
    """Owns the gateway connection and turns MCP tool calls into agent turns."""

    def __init__(
        self,
        *,
        gateway_url: str,
        gateway_token: str,
        connector_id: str = "mcp",
        sender: str = "mcp-operator",
        trust_level: str = "verified",
        default_timeout: float = 300.0,
        soft_timeout: float = 50.0,
        parked_ttl: float = 600.0,
        client_factory: Any = None,
    ) -> None:
        self._config = ConnectorConfig(
            gateway_url=gateway_url,
            connector_id=connector_id,
            connector_token=gateway_token,
        )
        self._sender = sender
        self._trust_level = trust_level
        self._default_timeout = default_timeout
        self._soft_timeout = soft_timeout
        self._parked_ttl = parked_ttl
        self._turns: dict[tuple[str, str], _Turn] = {}
        self._locks: dict[tuple[str, str], asyncio.Lock] = {}
        self._task: asyncio.Task[None] | None = None
        self._sweeper: asyncio.Task[None] | None = None
        factory = client_factory or GatewayClient
        self._client = factory(
            self._config,
            platform=PLATFORM,
            on_outbound=self._on_outbound,
            on_disconnect=self._on_disconnect,
        )

    # ------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------

    async def start(self) -> None:
        """Start the background connection loop (returns immediately)."""
        if self._task is None:
            self._task = asyncio.create_task(self._client.start(), name="gateway-bridge")
        if self._sweeper is None:
            self._sweeper = asyncio.create_task(
                self._sweep_loop(), name="gateway-bridge-sweeper"
            )

    async def stop(self) -> None:
        if self._sweeper is not None:
            self._sweeper.cancel()
            self._sweeper = None
        for key, turn in list(self._turns.items()):
            turn.fail("The MCP server is shutting down.")
            self._drop(key, turn)
        await self._client.stop()
        if self._task is not None:
            self._task.cancel()
            try:
                await self._task
            except (asyncio.CancelledError, Exception):  # noqa: BLE001
                pass
            self._task = None

    @property
    def connected(self) -> bool:
        return bool(self._client.is_registered)

    # ------------------------------------------------------------------
    # Ask
    # ------------------------------------------------------------------

    async def ask(
        self,
        agent_name: str,
        message: str,
        room_id: str,
        *,
        wait_timeout: float | None = None,
        hard_timeout: float | None = None,
    ) -> TurnStatus:
        """Send *message* to *agent_name*, or poll the turn already running.

        Waits up to *wait_timeout* (the soft deadline). If the turn has not
        finished by then, returns a pending :class:`TurnStatus` and leaves the
        turn running. A call that finds a turn already in flight for the same
        key does **not** forward its message — the gateway FIFO-queues prompts
        per session, so forwarding a poll would enqueue a second prompt and
        produce a second ``agent_result`` for the same key. A call that finds a
        parked (finished, uncollected) turn returns its reply immediately and
        likewise drops its own message.
        """
        wait_timeout = self._soft_timeout if wait_timeout is None else wait_timeout
        hard_timeout = self._default_timeout if hard_timeout is None else hard_timeout
        key = (agent_name, room_id)
        lock = self._locks.setdefault(key, asyncio.Lock())

        async with lock:
            self._expire_parked(time.monotonic())
            turn = self._turns.get(key)
            if turn is not None and turn.future.done():
                # Parked pickup: this call's message is dropped by contract.
                self._drop(key, turn)
                return self._settled(turn)
            if turn is None:
                if not self._client.is_registered:
                    # Give a reconnect a short grace period rather than failing
                    # the first call after a blip.
                    grace = min(_RECONNECT_GRACE_S, wait_timeout)
                    if not await self._client.wait_registered(timeout=grace):
                        raise GatewayError(
                            "Not connected to the TriOnyx gateway — try again shortly."
                        )
                # Register before sending: if the socket dies mid-send, the
                # receive loop's _on_disconnect fails registered turns, so the
                # caller is woken instead of waiting on a frame that never comes.
                turn = self._start_turn(key, agent_name, room_id, hard_timeout)
                try:
                    await self._client.send_message(
                        InboundMessage(
                            agent_name=agent_name,
                            content=message,
                            channel={"platform": PLATFORM, "room_id": room_id},
                            trust={"level": self._trust_level, "sender": self._sender},
                        )
                    )
                except BaseException:
                    self._drop(key, turn)
                    raise
                logger.info(
                    "-> agent=%s room=%s message=%.120s%s",
                    agent_name,
                    room_id,
                    message,
                    "…" if len(message) > 120 else "",
                )
            else:
                logger.info(
                    "   agent=%s room=%s poll #%d (%.0fs elapsed, %s)",
                    agent_name,
                    room_id,
                    turn.checks + 1,
                    turn.elapsed,
                    turn.activity,
                )
            turn.checks += 1
            turn.waiters += 1

        try:
            # asyncio.wait never cancels its awaitables — neither on timeout nor
            # when THIS caller is cancelled. That is what keeps the turn alive
            # in the background; asyncio.wait_for(turn.future, ...) would cancel
            # the future and silently revert the whole early-return feature.
            await asyncio.wait({turn.future}, timeout=wait_timeout)
        finally:
            turn.waiters -= 1

        if not turn.future.done():
            logger.info(
                "~> agent=%s room=%s still working after %.0fs (%s)",
                agent_name,
                room_id,
                turn.elapsed,
                turn.activity,
            )
            return turn.status(pending=True)

        self._drop(key, turn)
        return self._settled(turn)

    # ------------------------------------------------------------------
    # Turn bookkeeping
    # ------------------------------------------------------------------

    def _start_turn(
        self,
        key: tuple[str, str],
        agent_name: str,
        room_id: str,
        hard_timeout: float,
    ) -> _Turn:
        loop = asyncio.get_running_loop()
        turn = _Turn(
            future=loop.create_future(),
            agent_name=agent_name,
            room_id=room_id,
            started_at=time.monotonic(),
            hard_timeout=hard_timeout,
        )
        self._turns[key] = turn
        turn.watchdog = asyncio.create_task(
            self._hard_deadline(turn), name=f"turn-deadline-{agent_name}-{room_id}"
        )
        return turn

    def _drop(self, key: tuple[str, str], turn: _Turn) -> None:
        # Identity-checked: a late waiter may hold a reference to an old turn
        # after a new one was started for the same key.
        if self._turns.get(key) is turn:
            del self._turns[key]
        if turn.watchdog is not None and not turn.watchdog.done():
            turn.watchdog.cancel()
        if turn.future.done() and not turn.future.cancelled():
            # Mark a parked exception retrieved so asyncio's GC does not log
            # "Future exception was never retrieved".
            turn.future.exception()

    def _settled(self, turn: _Turn) -> TurnStatus:
        if turn.future.cancelled():
            raise GatewayError("The MCP server is shutting down.")
        exc = turn.future.exception()
        if exc is not None:
            # A fresh instance per caller: the same parked error may be
            # delivered to several waiters.
            raise GatewayError(str(exc)) from None
        return turn.status(pending=False, reply=turn.future.result())

    def _expire_parked(self, now: float) -> int:
        dropped = 0
        for key, turn in list(self._turns.items()):
            if (
                turn.finished_at is not None
                and turn.waiters == 0
                and now - turn.finished_at > self._parked_ttl
            ):
                self._drop(key, turn)
                dropped += 1
        return dropped

    async def _sweep_loop(self) -> None:
        while True:
            await asyncio.sleep(_SWEEP_INTERVAL_S)
            dropped = self._expire_parked(time.monotonic())
            if dropped:
                logger.info(
                    "Swept %d uncollected parked result(s); %d turn(s), %d lock(s) live",
                    dropped,
                    len(self._turns),
                    len(self._locks),
                )

    async def _hard_deadline(self, turn: _Turn) -> None:
        await asyncio.sleep(turn.hard_timeout)
        if turn.future.done():
            return
        logger.warning(
            "Turn agent=%s room=%s hit the %.0fs hard timeout",
            turn.agent_name,
            turn.room_id,
            turn.hard_timeout,
        )
        turn.fail(
            f"Agent '{turn.agent_name}' did not respond within {turn.hard_timeout:.0f}s."
        )

    # ------------------------------------------------------------------
    # Gateway frames
    # ------------------------------------------------------------------

    async def _on_outbound(self, msg: OutboundMessage) -> None:
        room_id = (msg.channel or {}).get("room_id", "")
        key = (msg.agent_name, room_id)
        turn = self._turns.get(key)

        if isinstance(msg, AgentStepMessage):
            if msg.step_type == "tool_use":
                logger.info("   agent=%s room=%s tool=%s", msg.agent_name, room_id, msg.name)
                if turn is not None and not turn.future.done():
                    turn.note_phase("tool", tool=msg.name or "")
            return

        if turn is None or turn.future.done():
            # No turn, or trailing frames for a turn that already settled —
            # dropping them keeps a parked reply immutable.
            return

        if isinstance(msg, AgentTypingMessage):
            # typing=true fires at dispatch (session may still be booting);
            # typing=false fires on the runtime's `ready` event.
            turn.note_phase("starting" if msg.is_typing else "ready")
        elif isinstance(msg, AgentTextMessage):
            turn.note_phase("writing")
            turn.add_text(msg.content)
        elif isinstance(msg, AgentResultMessage):
            # agent_result carries no content — the answer was streamed as
            # agent_text frames.
            if msg.content:
                turn.add_text(msg.content)
            logger.info("<- agent=%s room=%s complete", msg.agent_name, room_id)
            turn.finish()
        elif isinstance(msg, AgentErrorMessage):
            error = msg.error or msg.message or "the agent reported an error"
            logger.warning(
                "<- agent=%s room=%s error=%.200s", msg.agent_name, room_id, error
            )
            turn.fail(error)

    async def _on_disconnect(self) -> None:
        """Fail every unsettled turn rather than letting callers hang.

        Parked (already finished) results survive a disconnect; the failure is
        itself parked, so an unattended turn's error reaches the next poll.
        """
        pending = [t for t in self._turns.values() if not t.future.done()]
        if not pending:
            return
        logger.warning(
            "Gateway connection lost — failing %d in-flight turn(s)", len(pending)
        )
        for turn in pending:
            turn.fail("Connection to the TriOnyx gateway was lost.")
