"""Tests for Slack consent command matching."""

import pytest

from connector.adapters.slack import (
    _CONSENT_ACCEPT_PHRASES,
    _CONSENT_REVOKE_PHRASES,
    _DEFAULT_CONSENT_TEXT,
    SlackAdapter,
    _normalize_consent_reply,
)
from connector.config import AdapterConfig


class TestNormalizeConsentReply:
    @pytest.mark.parametrize(
        "raw",
        [
            "I agree",
            "i agree",
            "*I agree*",
            "  I Agree.  ",
            '"I agree"',
            "agree",
            "Agree!",
        ],
    )
    def test_accept_variants_match(self, raw):
        assert _normalize_consent_reply(raw) in _CONSENT_ACCEPT_PHRASES

    @pytest.mark.parametrize(
        "raw",
        [
            "revoke consent",
            "Revoke consent.",
            '"revoke consent"',
            "*Revoke Consent*",
            "disagree",
            "Disagree",
        ],
    )
    def test_revoke_variants_match(self, raw):
        assert _normalize_consent_reply(raw) in _CONSENT_REVOKE_PHRASES

    @pytest.mark.parametrize("raw", ["I do not agree", "agreeable", "hello"])
    def test_other_text_does_not_match(self, raw):
        normalized = _normalize_consent_reply(raw)
        assert normalized not in _CONSENT_ACCEPT_PHRASES
        assert normalized not in _CONSENT_REVOKE_PHRASES

    def test_phrases_cover_what_the_consent_text_promises(self):
        # The consent text instructs "I agree" and "revoke consent" — the
        # matched phrase sets must honor both.
        assert "I agree" in _DEFAULT_CONSENT_TEXT
        assert "revoke consent" in _DEFAULT_CONSENT_TEXT
        assert "i agree" in _CONSENT_ACCEPT_PHRASES
        assert "revoke consent" in _CONSENT_REVOKE_PHRASES


def _make_adapter(tmp_path):
    config = AdapterConfig(
        extra={
            "consent_path": str(tmp_path / "consent.yaml"),
            "owner_user_id": "UOWNER",
        }
    )
    adapter = SlackAdapter(config)
    adapter._bot_user_id = "UBOT"

    posts = []

    async def fake_post_dm(channel, text):
        posts.append(text)

    async def fake_display_name(user_id):
        return "Alice"

    adapter._post_dm = fake_post_dm
    adapter._get_display_name = fake_display_name
    return adapter, posts


def _dm_event(text, user="U1"):
    return {
        "user": user,
        "text": text,
        "channel": "D123",
        "channel_type": "im",
    }


class TestConsentCommands:
    async def test_i_agree_records_consent(self, tmp_path):
        adapter, posts = _make_adapter(tmp_path)
        await adapter._handle_message(_dm_event("*I agree*"))

        assert adapter._consent.has_valid_consent("U1")
        assert any("consent has been recorded" in p for p in posts)

    async def test_bare_agree_still_records_consent(self, tmp_path):
        adapter, _ = _make_adapter(tmp_path)
        await adapter._handle_message(_dm_event("agree"))
        assert adapter._consent.has_valid_consent("U1")

    async def test_revoke_consent_revokes(self, tmp_path):
        adapter, posts = _make_adapter(tmp_path)
        adapter._consent.record_consent("U1", "Alice")

        await adapter._handle_message(_dm_event("Revoke consent."))

        assert not adapter._consent.has_valid_consent("U1")
        assert any("revoked" in p for p in posts)

    async def test_disagree_still_revokes(self, tmp_path):
        adapter, _ = _make_adapter(tmp_path)
        adapter._consent.record_consent("U1", "Alice")
        await adapter._handle_message(_dm_event("disagree"))
        assert not adapter._consent.has_valid_consent("U1")

    async def test_non_command_without_consent_shows_consent_text(self, tmp_path):
        adapter, posts = _make_adapter(tmp_path)
        await adapter._handle_message(_dm_event("hello there"))

        assert not adapter._consent.has_valid_consent("U1")
        assert any("consent" in p.lower() for p in posts)
