# /// script
# requires-python = ">=3.11"
# dependencies = ["pytest>=8.0"]
# ///
"""Tests for the TriOnyx runtime protocol module."""

from __future__ import annotations

import io
import json
import sys
from pathlib import Path

# Ensure runtime/ is importable
sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent / "runtime"))

from protocol import (
    StartMessage,
    PromptMessage,
    ShutdownMessage,
    parse_inbound,
    emit_ready,
    emit_text,
    emit_tool_use,
    emit_tool_result,
    emit_result,
    emit_error,
    _emit,
)

import pytest


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def capture_emit(fn, *args, **kwargs) -> dict:
    """Call an emitter function and return the parsed JSON output."""
    old = sys.stdout
    sys.stdout = buf = io.StringIO()
    try:
        fn(*args, **kwargs)
    finally:
        sys.stdout = old
    return json.loads(buf.getvalue().strip())


# ---------------------------------------------------------------------------
# Inbound message parsing
# ---------------------------------------------------------------------------


class TestStartMessage:
    def test_parse_full(self):
        msg = parse_inbound({
            "type": "start",
            "agent": {
                "name": "reviewer",
                "tools": ["Read", "Grep", "Glob"],
                "model": "claude-sonnet-4-20250514",
                "system_prompt": "You review code.",
                "max_turns": 20,
                "cwd": "/project",
            },
        })
        assert isinstance(msg, StartMessage)
        assert msg.name == "reviewer"
        assert msg.tools == ["Read", "Grep", "Glob"]
        assert msg.model == "claude-sonnet-4-20250514"
        assert msg.system_prompt == "You review code."
        assert msg.max_turns == 20
        assert msg.cwd == "/project"

    def test_parse_defaults(self):
        msg = StartMessage.from_dict({"agent": {}})
        assert msg.name == "unnamed"
        assert msg.tools == []
        assert msg.model == "claude-sonnet-4-20250514"
        assert msg.system_prompt == ""
        assert msg.max_turns == 200
        assert msg.cwd == "/workspace"

    def test_parse_missing_agent_key(self):
        msg = StartMessage.from_dict({})
        assert msg.name == "unnamed"


class TestPromptMessage:
    def test_parse_with_metadata(self):
        msg = parse_inbound({
            "type": "prompt",
            "content": "Analyze main.py",
            "metadata": {"trigger": "cron", "session_id": "abc"},
        })
        assert isinstance(msg, PromptMessage)
        assert msg.content == "Analyze main.py"
        assert msg.metadata == {"trigger": "cron", "session_id": "abc"}

    def test_parse_without_metadata(self):
        msg = PromptMessage.from_dict({"content": "hello"})
        assert msg.content == "hello"
        assert msg.metadata == {}

    def test_parse_empty(self):
        msg = PromptMessage.from_dict({})
        assert msg.content == ""
        assert msg.images == []

    def test_parse_with_images_in_metadata(self):
        img = {"data": "aGVsbG8=", "media_type": "image/png"}
        msg = PromptMessage.from_dict({
            "content": "What is this?",
            "metadata": {"source": "connector", "images": [img]},
        })
        assert msg.content == "What is this?"
        assert len(msg.images) == 1
        assert msg.images[0]["media_type"] == "image/png"

    def test_parse_with_images_at_top_level(self):
        img = {"data": "aGVsbG8=", "media_type": "image/jpeg"}
        msg = PromptMessage.from_dict({
            "content": "",
            "images": [img],
        })
        assert msg.content == ""
        assert len(msg.images) == 1
        assert msg.images[0]["media_type"] == "image/jpeg"

    def test_parse_image_only_no_text(self):
        img = {"data": "aGVsbG8=", "media_type": "image/png"}
        msg = PromptMessage.from_dict({"images": [img]})
        assert msg.content == ""
        assert len(msg.images) == 1


class TestShutdownMessage:
    def test_parse_with_reason(self):
        msg = parse_inbound({"type": "shutdown", "reason": "operator stop"})
        assert isinstance(msg, ShutdownMessage)
        assert msg.reason == "operator stop"

    def test_parse_without_reason(self):
        msg = ShutdownMessage.from_dict({})
        assert msg.reason == ""


class TestParseInbound:
    def test_unknown_type_raises(self):
        with pytest.raises(ValueError, match="Unknown message type"):
            parse_inbound({"type": "bogus"})

    def test_missing_type_raises(self):
        with pytest.raises(ValueError, match="Unknown message type"):
            parse_inbound({})

    def test_none_type_raises(self):
        with pytest.raises(ValueError, match="Unknown message type"):
            parse_inbound({"type": None})


# ---------------------------------------------------------------------------
# Outbound message emitters
# ---------------------------------------------------------------------------


class TestEmitReady:
    def test_output(self):
        msg = capture_emit(emit_ready)
        assert msg == {"type": "ready"}


class TestEmitText:
    def test_output(self):
        msg = capture_emit(emit_text, "Hello world")
        assert msg == {"type": "text", "content": "Hello world"}

    def test_empty_content(self):
        msg = capture_emit(emit_text, "")
        assert msg["content"] == ""


class TestEmitToolUse:
    def test_output(self):
        msg = capture_emit(
            emit_tool_use, "toolu_01", "Read", {"file_path": "/test.py"}
        )
        assert msg == {
            "type": "tool_use",
            "id": "toolu_01",
            "name": "Read",
            "input": {"file_path": "/test.py"},
        }


class TestEmitToolResult:
    def test_output(self):
        msg = capture_emit(emit_tool_result, "toolu_01", "file contents", False)
        assert msg == {
            "type": "tool_result",
            "tool_use_id": "toolu_01",
            "content": "file contents",
            "is_error": False,
        }

    def test_error_result(self):
        msg = capture_emit(emit_tool_result, "toolu_01", "not found", True)
        assert msg["is_error"] is True


class TestEmitResult:
    def test_output(self):
        msg = capture_emit(emit_result, 5000, 3, 0.042, False)
        assert msg == {
            "type": "result",
            "duration_ms": 5000,
            "num_turns": 3,
            "cost_usd": 0.042,
            "is_error": False,
        }

    def test_error_result(self):
        msg = capture_emit(emit_result, 100, 0, 0.0, True)
        assert msg["is_error"] is True


class TestEmitError:
    def test_output(self):
        msg = capture_emit(emit_error, "something broke")
        assert msg == {"type": "error", "message": "something broke"}


# ---------------------------------------------------------------------------
# JSON Lines format
# ---------------------------------------------------------------------------


class TestJsonLinesFormat:
    def test_newline_terminated(self):
        old = sys.stdout
        sys.stdout = buf = io.StringIO()
        try:
            emit_ready()
            emit_text("hi")
        finally:
            sys.stdout = old
        output = buf.getvalue()
        # Each message should end with exactly one newline
        lines = output.split("\n")
        assert lines[-1] == ""  # trailing newline produces empty last element
        assert len(lines) == 3  # two messages + trailing empty

    def test_compact_json(self):
        old = sys.stdout
        sys.stdout = buf = io.StringIO()
        try:
            emit_text("test")
        finally:
            sys.stdout = old
        line = buf.getvalue().strip()
        # Compact format: no spaces after separators
        assert " " not in line.replace("test", "X")
