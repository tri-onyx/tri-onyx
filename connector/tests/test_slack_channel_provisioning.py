"""Tests for Slack auto-provisioned channel binding (``ensure_channel``).

A bound channel's every message is routed to its agent with verified sender
trust (see ``_handle_bound_channel_message`` and ``channel_bindings.py``'s
module docstring). ``ensure_channel``'s create-first strategy falls back to
finding an existing channel by name when creation reports ``name_taken`` —
that fallback must not bind a channel this bot did not itself create, or an
attacker who squats the auto-provisioned name (e.g. after a rename frees it,
as the module docstring for ``channel_bindings.py`` describes) could have
their own channel — and their own messages — treated as verified.
"""

from __future__ import annotations

from typing import Any
from unittest.mock import AsyncMock

import pytest
from slack_sdk.errors import SlackApiError

from connector.adapters.slack import SlackAdapter
from connector.config import AdapterConfig


def _make_adapter(tmp_path, **extra: Any) -> SlackAdapter:
    config = AdapterConfig(
        rooms={},
        extra={
            "consent_path": str(tmp_path / "consent.yaml"),
            "approval_store_path": str(tmp_path / "approvals.yaml"),
            "channel_cache_path": str(tmp_path / "channels.yaml"),
            "owner_user_id": "UOWNER",
            **extra,
        },
    )
    adapter = SlackAdapter(config)
    adapter._bot_user_id = "UBOT"
    adapter._bot_id = "BSELF"
    adapter._web_client = AsyncMock()
    return adapter


class TestEnsureChannelOwnershipCheck:
    async def test_joins_and_binds_a_channel_this_bot_created(self, tmp_path):
        """The documented recovery path: the bot created the channel on a
        previous run, the local cache was lost, and conversations.create now
        reports name_taken for the bot's own channel — it must still bind."""
        adapter = _make_adapter(tmp_path)
        adapter._web_client.conversations_create.side_effect = SlackApiError(
            "name_taken", {"error": "name_taken"}
        )
        adapter._web_client.conversations_list.return_value = {
            "channels": [
                {"id": "C_LEGIT", "name": "trionyx-my-repo", "creator": "UBOT", "is_member": False}
            ],
        }

        channel_id = await adapter.ensure_channel("trionyx-my-repo")

        assert channel_id == "C_LEGIT"
        adapter._web_client.conversations_join.assert_awaited_once_with(channel="C_LEGIT")

    async def test_refuses_to_bind_a_channel_squatted_by_someone_else(self, tmp_path):
        """An attacker created a channel with the auto-provisioned name before
        the bot could claim it. ensure_channel must not join or bind it —
        doing so would route the agent's traffic through an attacker-owned
        channel and treat the attacker's own messages as verified sender
        trust."""
        adapter = _make_adapter(tmp_path)
        adapter._web_client.conversations_create.side_effect = SlackApiError(
            "name_taken", {"error": "name_taken"}
        )
        adapter._web_client.conversations_list.return_value = {
            "channels": [
                {
                    "id": "C_ATTACKER",
                    "name": "trionyx-my-repo",
                    "creator": "UATTACKER",
                    "is_member": False,
                }
            ],
        }

        channel_id = await adapter.ensure_channel("trionyx-my-repo")

        assert channel_id is None, (
            "ensure_channel bound a channel it did not create — an attacker "
            "who squats the auto-provisioned name can get their messages "
            "treated as verified"
        )
        adapter._web_client.conversations_join.assert_not_awaited()

    async def test_squatted_channel_is_not_cached(self, tmp_path):
        """A refused channel must not be remembered, so a later run (once the
        name is free again) retries provisioning instead of trusting it."""
        adapter = _make_adapter(tmp_path)
        adapter._web_client.conversations_create.side_effect = SlackApiError(
            "name_taken", {"error": "name_taken"}
        )
        adapter._web_client.conversations_list.return_value = {
            "channels": [
                {
                    "id": "C_ATTACKER",
                    "name": "trionyx-my-repo",
                    "creator": "UATTACKER",
                    "is_member": False,
                }
            ],
        }

        await adapter.ensure_channel("trionyx-my-repo")

        assert adapter._channel_cache.get("trionyx-my-repo") is None
