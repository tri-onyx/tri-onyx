"""Tests for the persistent Slack approval store and the bot-message filter."""

import time

import pytest

from connector.adapters.slack import ApprovalStore, SlackAdapter
from connector.config import AdapterConfig, RoomConfig


class TestApprovalStore:
    def test_put_and_get_roundtrip(self, tmp_path):
        store = ApprovalStore(tmp_path / "approvals.yaml")
        store.put("1700000000.1", "appr-1")
        assert store.get("1700000000.1") == "appr-1"

    def test_unknown_ts_is_none(self, tmp_path):
        assert ApprovalStore(tmp_path / "approvals.yaml").get("nope") is None

    def test_survives_a_restart(self, tmp_path):
        path = tmp_path / "approvals.yaml"
        ApprovalStore(path).put("1700000000.1", "appr-1")
        assert ApprovalStore(path).get("1700000000.1") == "appr-1"

    def test_resolve_evicts_and_persists(self, tmp_path):
        path = tmp_path / "approvals.yaml"
        store = ApprovalStore(path)
        store.put("1700000000.1", "appr-1")
        store.resolve("1700000000.1")
        assert store.get("1700000000.1") is None
        assert len(store) == 0
        assert ApprovalStore(path).get("1700000000.1") is None

    def test_resolve_of_unknown_ts_is_a_noop(self, tmp_path):
        store = ApprovalStore(tmp_path / "approvals.yaml")
        store.resolve("nope")
        assert len(store) == 0

    def test_entries_expire_after_the_ttl(self, tmp_path):
        store = ApprovalStore(tmp_path / "approvals.yaml", ttl_s=0.0)
        store._data["old"] = {"approval_id": "appr-old", "created_at": time.time() - 10}
        assert store.get("old") is None
        assert len(store) == 0

    def test_expiry_runs_on_load(self, tmp_path):
        path = tmp_path / "approvals.yaml"
        fresh = ApprovalStore(path, ttl_s=3600)
        fresh.put("recent", "appr-new")
        fresh._data["stale"] = {"approval_id": "appr-old", "created_at": time.time() - 7200}
        fresh._flush()

        reloaded = ApprovalStore(path, ttl_s=3600)
        assert reloaded.get("recent") == "appr-new"
        assert reloaded.get("stale") is None

    def test_live_entries_are_not_expired(self, tmp_path):
        store = ApprovalStore(tmp_path / "approvals.yaml", ttl_s=3600)
        store.put("1700000000.1", "appr-1")
        assert store.get("1700000000.1") == "appr-1"


def _make_adapter(tmp_path, rooms=None):
    config = AdapterConfig(
        rooms=rooms or {},
        extra={
            "consent_path": str(tmp_path / "consent.yaml"),
            "approval_store_path": str(tmp_path / "approvals.yaml"),
            "owner_user_id": "UOWNER",
        },
    )
    adapter = SlackAdapter(config)
    adapter._bot_user_id = "UBOT"
    adapter._bot_id = "BSELF"
    return adapter


class TestOwnMessageFilter:
    def test_our_own_user_id_is_ours(self, tmp_path):
        assert _make_adapter(tmp_path)._is_own_message("UBOT", "")

    def test_our_own_bot_id_is_ours(self, tmp_path):
        """Webhook posts carry only bot_id."""
        assert _make_adapter(tmp_path)._is_own_message("", "BSELF")

    def test_another_app_is_not_ours(self, tmp_path):
        assert not _make_adapter(tmp_path)._is_own_message("", "BGITHUB")

    def test_a_human_is_not_ours(self, tmp_path):
        assert not _make_adapter(tmp_path)._is_own_message("UALICE", "")


class TestBoundChannelBotMessages:
    """Repo-bound channels must accept other apps (GitHub, CI)."""

    @pytest.fixture
    def adapter(self, tmp_path):
        adapter = _make_adapter(tmp_path, rooms={"C1": RoomConfig(agent="repo-agent", mode="all")})
        adapter._received = []

        async def capture(msg):
            adapter._received.append(msg)

        adapter._on_message = capture
        return adapter

    def _event(self, **overrides):
        event = {
            "type": "message",
            "channel": "C1",
            "channel_type": "channel",
            "text": "Deploy failed on main",
        }
        event.update(overrides)
        return event

    async def test_github_app_message_reaches_the_bound_agent(self, adapter):
        await adapter._handle_message(self._event(bot_id="BGITHUB", username="GitHub"))

        assert len(adapter._received) == 1
        msg = adapter._received[0]
        assert msg.agent_name == "repo-agent"
        assert "Deploy failed on main" in msg.content
        assert "GitHub" in msg.content
        assert "BGITHUB" in msg.content

    async def test_bot_profile_name_is_used_when_present(self, adapter):
        await adapter._handle_message(
            self._event(bot_id="BCI", bot_profile={"name": "CircleCI"})
        )
        assert "CircleCI" in adapter._received[0].content

    async def test_our_own_post_is_still_dropped(self, adapter):
        await adapter._handle_message(self._event(bot_id="BSELF"))
        await adapter._handle_message(self._event(user="UBOT"))
        assert adapter._received == []

    async def test_app_message_in_an_unbound_channel_is_dropped(self, adapter):
        await adapter._handle_message(self._event(channel="C-OTHER", bot_id="BGITHUB"))
        assert adapter._received == []

    async def test_app_dms_are_dropped(self, adapter):
        await adapter._handle_message(
            self._event(channel="D1", channel_type="im", bot_id="BGITHUB")
        )
        assert adapter._received == []

    async def test_app_message_trust_is_unverified(self, adapter):
        """A GitHub/CI app has no human behind it. The gateway maps
        trust.level == "verified" to the low-taint :verified_input trigger
        (taint_matrix.ex), the same class as an internal team member's
        message — an app-authored message (e.g. mirrored GitHub PR/issue
        text, attacker-controlled) must not get that reduced scrutiny."""
        await adapter._handle_message(self._event(bot_id="BGITHUB", username="GitHub"))
        assert adapter._received[0].trust == {"level": "unverified"}

    async def test_human_channel_member_trust_is_still_verified(self, adapter):
        await adapter._handle_message(self._event(user="UALICE"))
        assert adapter._received[0].trust == {"level": "verified"}
