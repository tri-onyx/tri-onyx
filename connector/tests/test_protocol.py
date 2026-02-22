"""Tests for protocol message encoding and decoding."""

import json

from connector.protocol import (
    ApprovalRequestMessage,
    ReactionMessage,
    decode,
    encode,
)


class TestReactionMessageEncoding:
    def test_encode_reaction_with_approval_id(self):
        msg = ReactionMessage(
            emoji="👍",
            sender="@user:matrix.org",
            channel={"platform": "matrix", "room_id": "!room:matrix.org"},
            approval_id="abc-123",
            event_id="$evt1",
            trust={"level": "verified", "sender": "@user:matrix.org"},
        )
        raw = encode(msg)
        data = json.loads(raw)

        assert data["type"] == "reaction"
        assert data["emoji"] == "👍"
        assert data["sender"] == "@user:matrix.org"
        assert data["approval_id"] == "abc-123"
        assert data["channel"]["room_id"] == "!room:matrix.org"

    def test_encode_reaction_without_approval_id(self):
        msg = ReactionMessage(
            emoji="🎉",
            sender="@user:matrix.org",
            channel={"platform": "matrix", "room_id": "!room:matrix.org"},
            agent_name="coder",
            event_id="$evt2",
        )
        raw = encode(msg)
        data = json.loads(raw)

        assert data["type"] == "reaction"
        assert data["emoji"] == "🎉"
        assert data["agent_name"] == "coder"
        assert data["approval_id"] is None

    def test_encode_reaction_default_trust(self):
        msg = ReactionMessage(
            emoji="👎",
            sender="@anon:matrix.org",
            channel={"platform": "matrix", "room_id": "!room:matrix.org"},
        )
        raw = encode(msg)
        data = json.loads(raw)

        assert data["trust"] == {"level": "unverified"}


class TestApprovalRequestDecoding:
    def test_decode_approval_request(self):
        raw = json.dumps({
            "type": "approval_request",
            "approval_id": "abc-123",
            "from_agent": "controller",
            "to_agent": "reader",
            "category": 3,
            "query_summary": "Summarize the document",
            "response_content": "The document says...",
            "anomalies": [{"message": "word count exceeded"}],
        })
        msg = decode(raw)

        assert isinstance(msg, ApprovalRequestMessage)
        assert msg.approval_id == "abc-123"
        assert msg.from_agent == "controller"
        assert msg.to_agent == "reader"
        assert msg.category == 3
        assert msg.query_summary == "Summarize the document"
        assert msg.response_content == "The document says..."
        assert len(msg.anomalies) == 1
        assert msg.anomalies[0]["message"] == "word count exceeded"

    def test_decode_approval_request_defaults(self):
        raw = json.dumps({
            "type": "approval_request",
            "approval_id": "def-456",
        })
        msg = decode(raw)

        assert isinstance(msg, ApprovalRequestMessage)
        assert msg.approval_id == "def-456"
        assert msg.from_agent == ""
        assert msg.to_agent == ""
        assert msg.category == 0
        assert msg.anomalies == []


class TestRoundTrip:
    def test_reaction_encodes_to_valid_json(self):
        msg = ReactionMessage(
            emoji="👍",
            sender="@human:matrix.org",
            channel={"platform": "matrix", "room_id": "!r:m.org"},
            approval_id="test-id",
        )
        raw = encode(msg)
        # Should be valid JSON
        data = json.loads(raw)
        assert data["type"] == "reaction"
        assert data["approval_id"] == "test-id"
