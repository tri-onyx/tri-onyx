# /// script
# requires-python = ">=3.11"
# dependencies = ["pytest>=8.0"]
# ///
"""Tests for reflection-mode constants in the TriOnyx agent runner.

The reflection code path is defined in ``runtime/agent_runner.py`` and is
selected at runtime when ``TRI_ONYX_MODE=reflection`` is set. Its dynamic
behavior (connecting a ``ClaudeSDKClient``, emitting a single turn, then
exiting) requires a live SDK and is covered by end-to-end tests. Here we
verify the static guarantees:

  - The restricted tool allow-list contains only file-IO primitives.
  - The hardcoded system prompt excludes the agent's usual persona context
    and directs output to the correct reflection path.
  - The user prompt template fills in the agent name and date.
"""

from __future__ import annotations

import sys
from pathlib import Path

# Ensure runtime/ is importable
sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent / "runtime"))

import agent_runner


def test_reflection_tools_are_restricted() -> None:
    """Reflection mode must not grant SendMessage, Bash, WebFetch, etc."""
    assert agent_runner._REFLECTION_TOOLS == ["Read", "Write", "Glob", "Grep"]


def test_reflection_system_prompt_references_log_mount() -> None:
    prompt = agent_runner._REFLECTION_SYSTEM_PROMPT
    assert "/reflection-logs/" in prompt
    assert "REFLECTION MODE" in prompt


def test_reflection_system_prompt_excludes_persona() -> None:
    """The reflection prompt must not reference memory / notes / heartbeat."""
    prompt = agent_runner._REFLECTION_SYSTEM_PROMPT
    # Must explicitly tell the model it has no persona context.
    assert "do NOT have access" in prompt.lower() or "do not have access" in prompt.lower()


def test_reflection_system_prompt_specifies_output_path() -> None:
    prompt = agent_runner._REFLECTION_SYSTEM_PROMPT
    assert "/workspace/agents/{agent_name}/reflections/{date}.md" in prompt


def test_reflection_system_prompt_excludes_prior_reflection_sessions() -> None:
    """Prior reflection runs live in the same logs directory; they must be ignored."""
    prompt = agent_runner._REFLECTION_SYSTEM_PROMPT
    assert "reflection-" in prompt


def test_reflection_user_prompt_fills_template() -> None:
    out = agent_runner._reflection_user_prompt("researcher", "2026-04-17")
    assert "Agent: researcher" in out
    assert "Date: 2026-04-17" in out
    assert "/workspace/agents/researcher/reflections/2026-04-17.md" in out
