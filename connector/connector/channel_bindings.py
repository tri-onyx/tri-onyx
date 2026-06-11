"""Agent ↔ Slack channel bindings served by the gateway.

The gateway's agent definitions own channel bindings, served as
``channel_bindings`` in ``GET /agents/schema``. Each binding carries the
agent name plus either an explicit ``slack_channel`` ID or a
``github_repo`` from which a channel is auto-provisioned: the channel
name is ``{prefix}{repo-name}`` (prefix from the Slack adapter's
``channel_prefix`` config, default ``gh-``), and the bot creates the
channel and invites the owner if it does not exist yet — the creator is
automatically a member, so nobody has to invite the bot anywhere.

Resolved bindings are merged into the Slack adapter's ``rooms`` config as
:class:`~connector.config.RoomConfig` entries, so all generic room-based
routing (channel messages, heartbeats, approvals, articles, inter-agent
mirrors) works for bound Slack channels without connector-side
configuration.

Bindings are fetched once with retries (the gateway typically boots
slower than the connector); messages arriving in a bound channel before
the fetch completes are dropped by the adapter with a log line. Restart
the connector after changing bindings on the gateway. Renaming an
auto-provisioned channel in Slack breaks the name lookup — the connector
would create a fresh channel on next startup.
"""

from __future__ import annotations

import asyncio
import logging
import re
from typing import Any

import aiohttp

from connector.config import RoomConfig
from connector.tool_briefs import _http_base_from_ws_url

logger = logging.getLogger(__name__)

_FETCH_ATTEMPTS = 6
_FETCH_RETRY_DELAY_S = 5

# Slack channel names: ≤80 chars of lowercase letters, digits, hyphens,
# underscores.
_INVALID_NAME_CHARS = re.compile(r"[^a-z0-9_-]+")
_MAX_CHANNEL_NAME_LEN = 80


def channel_name_for_repo(repo: str, prefix: str, qualified: bool = False) -> str:
    """Derive a Slack channel name from an ``owner/repo`` string.

    Uses the repo name only (``gh-my-repo``); set *qualified* to include
    the owner (``gh-myorg-my-repo``) when two repos share a name.
    """
    owner, _, name = repo.partition("/")
    base = f"{owner}-{name}" if qualified and name else (name or owner)
    sanitized = _INVALID_NAME_CHARS.sub("-", base.lower()).strip("-")
    return (prefix + sanitized)[:_MAX_CHANNEL_NAME_LEN]


def _resolve_names(bindings: list[dict[str, Any]], prefix: str) -> dict[str, str]:
    """Map agent → desired channel name, owner-qualifying name collisions."""
    repo_bindings = [b for b in bindings if b.get("github_repo") and not b.get("slack_channel")]

    names: dict[str, str] = {}
    seen: dict[str, str] = {}  # name -> agent
    for binding in repo_bindings:
        agent = binding["agent"]
        repo = binding["github_repo"]
        name = channel_name_for_repo(repo, prefix)
        if name in seen:
            name = channel_name_for_repo(repo, prefix, qualified=True)
        seen[name] = agent
        names[agent] = name
    return names


async def load_channel_bindings(gateway_url: str, adapters: dict[str, Any]) -> None:
    """Fetch channel bindings from the gateway and merge into adapter config.

    Bound channels get ``mode="all"`` — the agent owns the channel, so every
    message in it is routed to the agent (no @-mention required).
    """
    slack = adapters.get("slack")
    if slack is None:
        return

    url = f"{_http_base_from_ws_url(gateway_url)}/agents/schema"
    bindings: list[dict[str, Any]] | None = None
    for attempt in range(1, _FETCH_ATTEMPTS + 1):
        try:
            timeout = aiohttp.ClientTimeout(total=5)
            async with aiohttp.ClientSession(timeout=timeout) as session:
                async with session.get(url) as resp:
                    resp.raise_for_status()
                    payload = await resp.json()
            bindings = payload.get("channel_bindings", [])
            break
        except Exception as exc:
            if attempt == _FETCH_ATTEMPTS:
                logger.warning(
                    "Could not load channel bindings from %s after %d attempts: %s",
                    url, attempt, exc,
                )
                return
            await asyncio.sleep(_FETCH_RETRY_DELAY_S)

    assert bindings is not None
    prefix = slack._config.extra.get("channel_prefix", "gh-")
    desired_names = _resolve_names(bindings, prefix)
    bound = 0

    for binding in bindings:
        agent = binding.get("agent", "")
        channel_id = binding.get("slack_channel") or ""

        if not channel_id and agent in desired_names:
            channel_id = await slack.ensure_channel(desired_names[agent]) or ""

        if not agent or not channel_id:
            continue
        if channel_id in slack._config.rooms:
            existing = slack._config.rooms[channel_id].agent
            if existing != agent:
                logger.warning(
                    "Channel %s already configured locally (agent=%s) — "
                    "gateway binding to %s skipped",
                    channel_id, existing, agent,
                )
            continue
        slack._config.rooms[channel_id] = RoomConfig(agent=agent, mode="all")
        bound += 1
        logger.info("Bound Slack channel %s to agent %s", channel_id, agent)

    logger.info("Loaded %d channel bindings from gateway (%d bound)", len(bindings), bound)
