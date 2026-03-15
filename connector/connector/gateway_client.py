"""WebSocket client for the TriOnyx gateway.

Handles registration, message routing, automatic reconnection with
exponential backoff, and periodic health pings.
"""

from __future__ import annotations

import asyncio
import logging
from typing import Any, Callable, Coroutine

import websockets
from websockets.asyncio.client import ClientConnection

from connector.config import ConnectorConfig
from connector.protocol import (
    AgentErrorMessage,
    AgentResultMessage,
    AgentTextMessage,
    AgentTypingMessage,
    ApprovalRequestMessage,
    HeartbeatNotification,
    HealthMessage,
    InboundMessage,
    OutboundMessage,
    ReactionMessage,
    RegisterMessage,
    RegisteredMessage,
    ActionRequest,
    decode,
    encode,
)

logger = logging.getLogger(__name__)

# Reconnect backoff parameters
_INITIAL_BACKOFF_S = 1.0
_MAX_BACKOFF_S = 60.0
_BACKOFF_FACTOR = 2.0

# Health ping interval
_HEALTH_INTERVAL_S = 30.0

OutboundHandler = Callable[[OutboundMessage], Coroutine[Any, Any, None]]
ActionHandler = Callable[[ActionRequest], Coroutine[Any, Any, None]]
HeartbeatHandler = Callable[[HeartbeatNotification], Coroutine[Any, Any, None]]
ApprovalRequestHandler = Callable[[ApprovalRequestMessage], Coroutine[Any, Any, None]]


class GatewayClient:
    """Maintains a persistent WebSocket connection to the TriOnyx gateway.

    The client registers on connect, routes outbound messages from the gateway
    to the appropriate adapter, and forwards inbound messages from adapters to
    the gateway.
    """

    def __init__(
        self,
        config: ConnectorConfig,
        *,
        on_outbound: OutboundHandler | None = None,
        on_action: ActionHandler | None = None,
        on_heartbeat: HeartbeatHandler | None = None,
        on_approval_request: ApprovalRequestHandler | None = None,
    ) -> None:
        self._config = config
        self._on_outbound = on_outbound
        self._on_action = on_action
        self._on_heartbeat = on_heartbeat
        self._on_approval_request = on_approval_request
        self._ws: ClientConnection | None = None
        self._registered = asyncio.Event()
        self._closing = False
        self._tasks: list[asyncio.Task[None]] = []

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    async def start(self) -> None:
        """Open the connection and begin the receive/health loops.

        Blocks until :meth:`stop` is called or the event loop ends.
        """
        self._closing = False
        await self._connect_loop()

    async def stop(self) -> None:
        """Gracefully close the connection and cancel background tasks."""
        self._closing = True
        for task in self._tasks:
            task.cancel()
        if self._ws is not None:
            await self._ws.close()
            self._ws = None
        logger.info("Gateway client stopped")

    async def send_message(self, msg: InboundMessage) -> None:
        """Forward an adapter-originated message to the gateway."""
        logger.info(
            "Sending message to gateway: agent=%s content=%.80s",
            msg.agent_name,
            msg.content,
        )
        await self._send(encode(msg))

    async def send_reaction(self, msg: ReactionMessage) -> None:
        """Forward an adapter-originated reaction to the gateway."""
        logger.info(
            "Sending reaction to gateway: emoji=%s sender=%s approval_id=%s agent=%s",
            msg.emoji,
            msg.sender,
            msg.approval_id or "",
            msg.agent_name,
        )
        await self._send(encode(msg))

    # ------------------------------------------------------------------
    # Connection lifecycle
    # ------------------------------------------------------------------

    async def _connect_loop(self) -> None:
        """Connect, register, and listen — reconnecting on failure."""
        backoff = _INITIAL_BACKOFF_S

        while not self._closing:
            try:
                async with websockets.connect(
                    self._config.gateway_url,
                    ping_timeout=60,
                ) as ws:
                    self._ws = ws
                    backoff = _INITIAL_BACKOFF_S
                    await self._register()
                    await self._run(ws)
            except (
                websockets.ConnectionClosed,
                websockets.InvalidURI,
                OSError,
            ) as exc:
                if self._closing:
                    return
                logger.warning(
                    "Gateway connection lost (%s), reconnecting in %.1fs",
                    exc,
                    backoff,
                )
                await asyncio.sleep(backoff)
                backoff = min(backoff * _BACKOFF_FACTOR, _MAX_BACKOFF_S)
            except Exception:
                if self._closing:
                    return
                logger.exception("Unexpected error in gateway connection loop")
                await asyncio.sleep(backoff)
                backoff = min(backoff * _BACKOFF_FACTOR, _MAX_BACKOFF_S)

    async def _register(self) -> None:
        """Send the register frame and wait for acknowledgement."""
        self._registered.clear()
        msg = RegisterMessage(
            connector_id=self._config.connector_id,
            platform="matrix",
            token=self._config.connector_token,
        )
        await self._send(encode(msg))
        logger.info("Sent register for connector_id=%s", self._config.connector_id)

    async def _run(self, ws: ClientConnection) -> None:
        """Main loop: receive frames and dispatch."""
        health_task = asyncio.create_task(self._health_loop())
        self._tasks.append(health_task)

        try:
            async for raw in ws:
                await self._handle_frame(raw)
        finally:
            health_task.cancel()
            self._tasks = [t for t in self._tasks if t is not health_task]

    # ------------------------------------------------------------------
    # Frame handling
    # ------------------------------------------------------------------

    async def _handle_frame(self, raw: str | bytes) -> None:
        """Decode and dispatch a single gateway frame."""
        msg = decode(raw)

        if isinstance(msg, RegisteredMessage):
            logger.info("Registered with gateway (id=%s)", msg.connector_id)
            self._registered.set()
            return

        if isinstance(msg, ActionRequest):
            if self._on_action:
                await self._on_action(msg)
            return

        if isinstance(msg, ApprovalRequestMessage):
            if self._on_approval_request:
                await self._on_approval_request(msg)
            return

        if isinstance(msg, HeartbeatNotification):
            if self._on_heartbeat:
                await self._on_heartbeat(msg)
            return

        if isinstance(msg, OutboundMessage):
            if self._on_outbound:
                await self._on_outbound(msg)
            return

        # Unknown frame — log and ignore
        if isinstance(msg, dict):
            logger.debug("Unhandled gateway frame type=%s", msg.get("type"))
        else:
            logger.debug("Unhandled gateway frame: %r", msg)

    # ------------------------------------------------------------------
    # Health ping
    # ------------------------------------------------------------------

    async def _health_loop(self) -> None:
        """Send periodic health pings to the gateway."""
        try:
            while True:
                await asyncio.sleep(_HEALTH_INTERVAL_S)
                if self._registered.is_set():
                    msg = HealthMessage(connector_id=self._config.connector_id)
                    await self._send(encode(msg))
        except asyncio.CancelledError:
            pass

    # ------------------------------------------------------------------
    # Transport
    # ------------------------------------------------------------------

    async def _send(self, data: str) -> None:
        """Send a raw JSON frame, ignoring errors if disconnected."""
        if self._ws is None:
            logger.warning("Cannot send — not connected to gateway")
            return
        try:
            await self._ws.send(data)
        except websockets.ConnectionClosed:
            logger.warning("Send failed — connection closed")
