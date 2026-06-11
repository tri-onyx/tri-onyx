"""Agent ↔ Slack channel bindings served by the gateway.

The gateway's agent definitions own channel bindings (the ``slack_channel``
frontmatter field), served as ``channel_bindings`` in ``GET /agents/schema``.
At connector startup the bindings are fetched and merged into the Slack
adapter's ``rooms`` config as :class:`~connector.config.RoomConfig` entries,
so all generic room-based routing (channel messages, heartbeats, approvals,
articles, inter-agent mirrors) works for bound Slack channels without any
connector-side configuration.

Bindings are fetched once with retries (the gateway typically boots slower
than the connector); messages arriving in a bound channel before the fetch
completes are dropped by the adapter with a log line. Restart the connector
after changing bindings on the gateway.
"""

from __future__ import annotations

import asyncio
import logging
from typing import Any

import aiohttp

from connector.config import RoomConfig
from connector.tool_briefs import _http_base_from_ws_url

logger = logging.getLogger(__name__)

_FETCH_ATTEMPTS = 6
_FETCH_RETRY_DELAY_S = 5


async def load_channel_bindings(gateway_url: str, adapters: dict[str, Any]) -> None:
    """Fetch channel bindings from the gateway and merge into adapter config.

    Bound channels get ``mode="all"`` — the agent owns the channel, so every
    message in it is routed to the agent (no @-mention required).
    """
    slack = adapters.get("slack")
    if slack is None:
        return

    url = f"{_http_base_from_ws_url(gateway_url)}/agents/schema"
    for attempt in range(1, _FETCH_ATTEMPTS + 1):
        try:
            timeout = aiohttp.ClientTimeout(total=5)
            async with aiohttp.ClientSession(timeout=timeout) as session:
                async with session.get(url) as resp:
                    resp.raise_for_status()
                    payload = await resp.json()
        except Exception as exc:
            if attempt == _FETCH_ATTEMPTS:
                logger.warning(
                    "Could not load channel bindings from %s after %d attempts: %s",
                    url, attempt, exc,
                )
                return
            await asyncio.sleep(_FETCH_RETRY_DELAY_S)
            continue

        bindings = payload.get("channel_bindings", [])
        for binding in bindings:
            agent = binding.get("agent", "")
            channel_id = binding.get("slack_channel", "")
            if not agent or not channel_id:
                continue
            if channel_id in slack._config.rooms:
                logger.warning(
                    "Channel %s already configured locally (agent=%s) — "
                    "gateway binding to %s skipped",
                    channel_id, slack._config.rooms[channel_id].agent, agent,
                )
                continue
            slack._config.rooms[channel_id] = RoomConfig(agent=agent, mode="all")
            logger.info("Bound Slack channel %s to agent %s", channel_id, agent)

        logger.info("Loaded %d channel bindings from gateway", len(bindings))
        return
