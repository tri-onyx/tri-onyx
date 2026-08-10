"""Request/response bridge over the gateway's connector WebSocket.

The gateway speaks a streaming protocol: a ``message`` frame starts (or resumes)
an agent session, and the answer arrives as zero or more ``agent_text`` frames
terminated by ``agent_result`` (or ``agent_error``). MCP tools are
request/response, so this module collapses one gateway turn into one string.

Correlation is by ``(agent_name, room_id)`` — the gateway echoes the opaque
channel object back on every frame, and keys its own sessions by
``agent_name:hash(channel)``, so a stable room_id gives a persistent agent
session for a conversation.

The persistent connection, registration and reconnect/backoff all come from
:class:`connector.gateway_client.GatewayClient`; nothing about the wire protocol
is re-implemented here.
"""

from __future__ import annotations

import asyncio
import logging
import re
from dataclasses import dataclass, field
from typing import Any

from connector.config import ConnectorConfig
from connector.gateway_client import GatewayClient
from connector.protocol import (
    AgentErrorMessage,
    AgentResultMessage,
    AgentStepMessage,
    AgentTextMessage,
    InboundMessage,
    OutboundMessage,
)

logger = logging.getLogger(__name__)

PLATFORM = "mcp"

_ROOM_ID_SAFE = re.compile(r"[^A-Za-z0-9_-]+")
_MAX_ROOM_ID_LEN = 64


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


@dataclass(slots=True)
class _Turn:
    """One in-flight question to an agent."""

    future: asyncio.Future[str]
    texts: list[str] = field(default_factory=list)

    def add_text(self, content: str) -> None:
        if content:
            self.texts.append(content)

    def finish(self) -> None:
        if not self.future.done():
            self.future.set_result("\n\n".join(self.texts).strip())

    def fail(self, error: str) -> None:
        if not self.future.done():
            self.future.set_exception(GatewayError(error))


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
        self._turns: dict[tuple[str, str], _Turn] = {}
        self._locks: dict[tuple[str, str], asyncio.Lock] = {}
        self._task: asyncio.Task[None] | None = None
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

    async def stop(self) -> None:
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
        timeout: float | None = None,
    ) -> str:
        """Send *message* to *agent_name* and wait for the agent's reply."""
        timeout = self._default_timeout if timeout is None else timeout
        key = (agent_name, room_id)
        lock = self._locks.setdefault(key, asyncio.Lock())

        async with lock:
            if not self._client.is_registered:
                # Give a reconnect a short grace period rather than failing the
                # first call after a blip.
                if not await self._client.wait_registered(timeout=min(30.0, timeout)):
                    raise GatewayError(
                        "Not connected to the TriOnyx gateway — try again shortly."
                    )

            loop = asyncio.get_running_loop()
            turn = _Turn(future=loop.create_future())
            self._turns[key] = turn
            logger.info(
                "-> agent=%s room=%s message=%.120s%s",
                agent_name,
                room_id,
                message,
                "…" if len(message) > 120 else "",
            )
            try:
                await self._client.send_message(
                    InboundMessage(
                        agent_name=agent_name,
                        content=message,
                        channel={"platform": PLATFORM, "room_id": room_id},
                        trust={"level": self._trust_level, "sender": self._sender},
                    )
                )
                return await asyncio.wait_for(turn.future, timeout)
            except asyncio.TimeoutError:
                raise GatewayError(
                    f"Agent '{agent_name}' did not respond within {timeout:.0f}s."
                ) from None
            finally:
                self._turns.pop(key, None)

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
            return

        if turn is None:
            # Frames for a turn we are no longer waiting on (timed out, or a
            # session the gateway resumed on its own) are dropped.
            return

        if isinstance(msg, AgentTextMessage):
            turn.add_text(msg.content)
        elif isinstance(msg, AgentResultMessage):
            # agent_result carries no content — the answer was streamed as
            # agent_text frames.
            if msg.content:
                turn.add_text(msg.content)
            logger.info("<- agent=%s room=%s complete", msg.agent_name, room_id)
            turn.finish()
        elif isinstance(msg, AgentErrorMessage):
            logger.warning(
                "<- agent=%s room=%s error=%.200s", msg.agent_name, room_id, msg.error
            )
            turn.fail(msg.error or "the agent reported an error")

    async def _on_disconnect(self) -> None:
        """Fail every in-flight turn rather than letting callers hang."""
        if not self._turns:
            return
        logger.warning(
            "Gateway connection lost — failing %d in-flight request(s)", len(self._turns)
        )
        for turn in list(self._turns.values()):
            turn.fail("Connection to the TriOnyx gateway was lost.")
