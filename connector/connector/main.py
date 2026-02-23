"""Entry point for the TriOnyx connector.

Loads configuration, starts chat platform adapters and the gateway WebSocket
client, wires them together, and handles graceful shutdown.
"""

from __future__ import annotations

import asyncio
import logging
import signal
import sys
from typing import Any

from connector.adapters.matrix import MatrixAdapter
from connector.config import AdapterConfig, ConnectorConfig, load_config
from connector.gateway_client import GatewayClient
from connector.protocol import (
    ActionRequest,
    AgentStepMessage,
    AgentTextMessage,
    AgentTypingMessage,
    AgentResultMessage,
    AgentErrorMessage,
    ApprovalRequestMessage,
    HeartbeatNotification,
    InboundMessage,
    OutboundMessage,
    ReactionMessage,
)

logger = logging.getLogger("connector")

# Map of adapter names to their implementation classes
_ADAPTER_REGISTRY: dict[str, type] = {
    "matrix": MatrixAdapter,
}


def _build_adapters(
    config: ConnectorConfig,
) -> dict[str, Any]:
    """Instantiate enabled adapters from config."""
    # Create transcriber if voice is enabled
    transcriber = None
    if config.voice.enabled:
        from connector.transcriber import Transcriber

        transcriber = Transcriber(
            model_size=config.voice.whisper_model,
            language=config.voice.language,
        )
        logger.info(
            "Voice transcription enabled (model=%s, language=%s)",
            config.voice.whisper_model,
            config.voice.language,
        )

    adapters: dict[str, Any] = {}
    for name, adapter_cfg in config.adapters.items():
        if not adapter_cfg.enabled:
            logger.info("Adapter %s is disabled, skipping", name)
            continue
        cls = _ADAPTER_REGISTRY.get(name)
        if cls is None:
            logger.warning("Unknown adapter type: %s", name)
            continue
        adapters[name] = cls(adapter_cfg, transcriber=transcriber)
        logger.info("Created adapter: %s", name)
    return adapters


async def _route_outbound(
    adapters: dict[str, Any],
    msg: OutboundMessage,
) -> None:
    """Route a gateway outbound message to the appropriate adapter."""
    platform = msg.channel.get("platform", "")
    adapter = adapters.get(platform)
    if adapter is None:
        logger.warning("No adapter for platform %s", platform)
        return

    if isinstance(msg, AgentTextMessage):
        await adapter.send_text(msg.channel, msg.content, agent_name=msg.agent_name)
    elif isinstance(msg, AgentResultMessage):
        # Result is a completion signal (duration_ms, cost, etc.) — not a
        # user-visible message.  Sending it as text produced blank messages
        # and risked feeding back into the bot's own mention gating.
        logger.debug(
            "Agent result for %s (not sending to chat)",
            msg.agent_name or msg.session_id,
        )
    elif isinstance(msg, AgentTypingMessage):
        await adapter.send_typing(msg.channel, msg.is_typing)
    elif isinstance(msg, AgentStepMessage):
        await adapter.send_step(msg.channel, msg)
    elif isinstance(msg, AgentErrorMessage):
        await adapter.send_text(msg.channel, f"Error: {msg.error}", agent_name=msg.agent_name)
    else:
        logger.debug("Unhandled outbound message type: %s", msg.type)


async def _route_action(
    adapters: dict[str, Any],
    req: ActionRequest,
) -> None:
    """Route a gateway action request to the appropriate adapter."""
    platform = req.channel.get("platform", "")
    adapter = adapters.get(platform)
    if adapter is None:
        logger.warning("No adapter for platform %s (action=%s)", platform, req.action)
        return

    action = req.action
    params = req.params

    if action == "react":
        await adapter.send_reaction(req.channel, params.get("emoji", ""))
    elif action == "edit":
        await adapter.edit_message(req.channel, params.get("message_id", ""), params.get("content", ""))
    elif action == "delete":
        await adapter.delete_message(req.channel, params.get("message_id", ""))
    elif action == "send_file":
        await adapter.send_file(
            req.channel,
            params.get("data", b""),
            params.get("filename", "file"),
            params.get("mime_type", "application/octet-stream"),
        )
    else:
        logger.warning("Unknown action: %s", action)


async def _route_approval_request(
    adapters: dict[str, Any],
    msg: ApprovalRequestMessage,
) -> None:
    """Route approval request to adapters.

    Checks ``approval_rooms`` first, then falls back to the room where
    the controller agent (``from_agent``) is configured.
    """
    routed = False
    for adapter_name, adapter in adapters.items():
        # Explicit approval room
        room_id = (
            adapter._config.approval_rooms.get(msg.from_agent)
            or adapter._config.approval_rooms.get(msg.to_agent)
            or adapter._config.approval_rooms.get("_default")
        )

        # Fallback: find the room where from_agent is the configured agent
        if not room_id:
            for rid, room_cfg in adapter._config.rooms.items():
                if room_cfg.agent == msg.from_agent:
                    room_id = rid
                    break

        if room_id:
            channel = {"platform": adapter_name, "room_id": room_id}
            logger.info(
                "Routing approval request %s to %s room %s",
                msg.approval_id,
                adapter_name,
                room_id,
            )
            await adapter.send_approval_request(
                approval_id=msg.approval_id,
                from_agent=msg.from_agent,
                to_agent=msg.to_agent,
                category=msg.category,
                query_summary=msg.query_summary,
                response_content=msg.response_content,
                anomalies=msg.anomalies,
                channel=channel,
            )
            routed = True

    if not routed:
        logger.warning(
            "No adapter could route approval request %s (from=%s to=%s) "
            "— configure approval_rooms or ensure the agent has a room",
            msg.approval_id,
            msg.from_agent,
            msg.to_agent,
        )


async def _route_heartbeat(
    adapters: dict[str, Any],
    msg: HeartbeatNotification,
) -> None:
    """Route a heartbeat notification to the room configured for the agent."""
    for adapter_name, adapter in adapters.items():
        room_id = adapter._config.heartbeat_rooms.get(msg.agent_name)
        if room_id:
            channel = {"platform": adapter_name, "room_id": room_id}
            logger.info(
                "Routing heartbeat from %s to %s room %s",
                msg.agent_name,
                adapter_name,
                room_id,
            )
            await adapter.send_text(channel, msg.content, agent_name=msg.agent_name)


async def run(config: ConnectorConfig) -> None:
    """Start all components and run until shutdown."""
    adapters = _build_adapters(config)
    if not adapters:
        logger.error("No adapters enabled — exiting")
        return

    # Create gateway client with routing callbacks
    gateway = GatewayClient(
        config,
        on_outbound=lambda msg: _route_outbound(adapters, msg),
        on_action=lambda req: _route_action(adapters, req),
        on_heartbeat=lambda msg: _route_heartbeat(adapters, msg),
        on_approval_request=lambda msg: _route_approval_request(adapters, msg),
    )

    # Wire adapter inbound -> gateway
    async def on_adapter_message(msg: InboundMessage) -> None:
        await gateway.send_message(msg)

    async def on_adapter_reaction(msg: ReactionMessage) -> None:
        await gateway.send_reaction(msg)

    # Set up graceful shutdown
    shutdown_event = asyncio.Event()

    def _signal_handler() -> None:
        logger.info("Shutdown signal received")
        shutdown_event.set()

    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, _signal_handler)

    # Start all components concurrently
    async with asyncio.TaskGroup() as tg:
        # Start adapters
        for name, adapter in adapters.items():
            tg.create_task(adapter.start(on_adapter_message, on_reaction=on_adapter_reaction))

        # Start gateway client
        gateway_task = tg.create_task(gateway.start())

        # Wait for shutdown signal then tear down
        async def _shutdown_watcher() -> None:
            await shutdown_event.wait()
            logger.info("Initiating graceful shutdown")
            await gateway.stop()
            for name, adapter in adapters.items():
                logger.info("Stopping adapter: %s", name)
                await adapter.stop()
            # Cancel the gateway task to unblock the TaskGroup
            gateway_task.cancel()

        tg.create_task(_shutdown_watcher())


def main() -> None:
    """CLI entry point."""
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        stream=sys.stderr,
    )

    config_path = sys.argv[1] if len(sys.argv) > 1 else None
    config = load_config(config_path)

    logger.info(
        "Starting connector %s (gateway=%s, adapters=%s)",
        config.connector_id,
        config.gateway_url,
        list(config.adapters.keys()),
    )

    try:
        asyncio.run(run(config))
    except KeyboardInterrupt:
        pass
    finally:
        logger.info("Connector shut down")


if __name__ == "__main__":
    main()
