# /// script
# requires-python = ">=3.11"
# dependencies = ["websockets>=12.0"]
# ///
"""Test harness for TriOnyx.

Emulates the Matrix connector to drive an agent end-to-end through the
gateway's connector WebSocket protocol. Prints each gateway frame as a
JSON line to stdout as it arrives, then exits when the agent finishes.

Usage:
    uv run scripts/test-agent.py <agent-name> <prompt> [options]
    uv run scripts/test-agent.py <agent-name> --turns '<json>' [options]

Environment:
    TRI_ONYX_CONNECTOR_TOKEN  Shared connector token (auto-detected
                                from the running gateway container if
                                not set)
    TRI_ONYX_GATEWAY          Gateway WebSocket base URL
                                (default: ws://localhost:4000)

Options:
    --trust verified|unverified  Trust level forwarded to the gateway
                                 (default: verified)
    --timeout SECONDS            Max wait time per turn in seconds
                                 (default: 120)
    --auto-approve               Automatically approve any BCTP
                                 approval_request with 👍

Turn-based usage:
    --turns takes a JSON array of user actions. Each element is one of:

        {"type": "message", "content": "..."}
            Send a message to the agent and wait for agent_result.

        {"type": "react", "emoji": "👍"}
            Send a reaction. If an approval_request is pending, sends
            it as an approval reaction (with approval_id). Otherwise
            sends a general reaction to the agent and waits for the
            next agent_result.

    Reactions to approval_request are sent immediately when the frame
    arrives (mid-session), not after agent_result, because the agent
    is blocked waiting for the BCTP tool result.

Output:
    One JSON object per line (JSONL). Frame types:
        agent_typing   Agent started/stopped thinking
        agent_step     Tool use or tool result
        agent_text     Text chunk from the agent
        agent_log      Runtime log message (WARNING+ only)
        agent_result   Session complete (terminal — exit 0)
        agent_error    Session failed  (terminal — exit 1)
        timeout        Timed out waiting for completion (exit 1)

Examples:
    # Simple single-turn
    uv run scripts/test-agent.py main "What files are in /workspace?"

    # Auto-approve BCTP requests
    uv run scripts/test-agent.py researcher "Summarise the logs" --auto-approve

    # Multi-turn with explicit approval
    uv run scripts/test-agent.py main --turns '[
      {"type": "message", "content": "Run the deployment"},
      {"type": "react",   "emoji":   "👍"},
      {"type": "message", "content": "Now check the status"}
    ]'

    # General reaction (triggers reaction-based agent behaviour)
    uv run scripts/test-agent.py main --turns '[
      {"type": "message", "content": "Prepare the report"},
      {"type": "react",   "emoji":   "🔄"}
    ]'

    # Pipe output through jq for readable formatting
    uv run scripts/test-agent.py python-coder "Write hello.py" | jq .
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import subprocess
import sys
from typing import Any

import websockets

_TERMINAL_TYPES = {"agent_result", "agent_error"}


async def run(
    agent_name: str,
    turns: list[dict[str, Any]],
    *,
    gateway_url: str,
    token: str,
    trust: str = "verified",
    timeout: float = 120.0,
    auto_approve: bool = False,
) -> int:
    """Connect as a test connector, execute turns, collect frames.

    Returns exit code: 0 on successful agent_result, 1 on error or timeout.
    """
    ws_url = gateway_url.rstrip("/") + "/connectors/ws"
    channel = {"platform": "test", "room_id": "test-harness"}

    async with websockets.connect(ws_url) as ws:
        # Authenticate
        await ws.send(
            json.dumps(
                {
                    "type": "register",
                    "connector_id": "test-harness",
                    "platform": "test",
                    "token": token,
                }
            )
        )

        ack = json.loads(await ws.recv())
        if ack.get("type") != "registered":
            _emit({"type": "error", "error": f"registration failed: {ack}"})
            return 1

        # Prime: send the first message turn
        remaining = list(turns)
        first_msg = _pop_next_message(remaining)
        if first_msg is None:
            _emit({"type": "error", "error": "turns must contain at least one message"})
            return 1

        await _send_message(ws, agent_name, first_msg["content"], channel, trust)

        # Single event loop for the entire session.
        #
        # approval_request arrives mid-session (agent is blocked on the BCTP
        # tool result), so we handle it inline rather than after agent_result.
        pending_approval: dict | None = None

        try:
            async with asyncio.timeout(timeout):
                async for raw in ws:
                    frame = json.loads(raw)
                    _emit(frame)

                    frame_type = frame.get("type")

                    # ── BCTP approval request ──────────────────────────────
                    if frame_type == "approval_request":
                        pending_approval = frame
                        react_turn = _pop_next_react(remaining)

                        if react_turn is not None:
                            await _send_approval_reaction(
                                ws, react_turn["emoji"], frame, channel, trust
                            )
                            pending_approval = None
                        elif auto_approve:
                            await _send_approval_reaction(
                                ws, "👍", frame, channel, trust
                            )
                            pending_approval = None
                        # else: no reaction available yet — keep pending_approval
                        # and continue collecting; a later react turn or
                        # auto_approve will handle it when seen.

                    # ── Agent finished its current turn ───────────────────
                    elif frame_type == "agent_result":
                        # Flush any leading react turns.  If a pending approval
                        # exists, consume it; otherwise send as a general
                        # reaction and wait for the next agent_result.
                        while remaining and remaining[0]["type"] == "react":
                            react_turn = remaining.pop(0)
                            if pending_approval:
                                await _send_approval_reaction(
                                    ws, react_turn["emoji"], pending_approval, channel, trust
                                )
                                pending_approval = None
                            else:
                                await _send_general_reaction(
                                    ws, react_turn["emoji"], agent_name, channel, trust
                                )
                            # Continue collecting to see what the agent does
                            # next — do NOT break here.
                            break  # Process one reaction at a time

                        # If there are more message turns, send the next one.
                        next_msg = _pop_next_message(remaining)
                        if next_msg is not None:
                            await _send_message(
                                ws, agent_name, next_msg["content"], channel, trust
                            )
                        elif not remaining:
                            # All turns consumed — done.
                            return 0
                        # else: only react turns left; they'll be handled above
                        # when the next agent_result arrives.

                    # ── Agent error ───────────────────────────────────────
                    elif frame_type == "agent_error":
                        return 1

        except asyncio.TimeoutError:
            _emit({"type": "timeout", "timeout_s": timeout})
            return 1

    return 0


# ---------------------------------------------------------------------------
# Send helpers
# ---------------------------------------------------------------------------


async def _send_message(
    ws: Any,
    agent_name: str,
    content: str,
    channel: dict,
    trust: str,
) -> None:
    await ws.send(
        json.dumps(
            {
                "type": "message",
                "agent_name": agent_name,
                "content": content,
                "channel": channel,
                "trust": {"level": trust, "sender": "test-harness"},
            }
        )
    )


async def _send_approval_reaction(
    ws: Any,
    emoji: str,
    approval_frame: dict,
    channel: dict,
    trust: str,
) -> None:
    """Send a reaction that resolves a pending BCTP approval_request."""
    await ws.send(
        json.dumps(
            {
                "type": "reaction",
                "emoji": emoji,
                "sender": "test-harness",
                "channel": channel,
                "approval_id": approval_frame.get("approval_id", ""),
                "agent_name": approval_frame.get("to_agent", ""),
                "event_id": "",
                "trust": {"level": trust, "sender": "test-harness"},
            }
        )
    )


async def _send_general_reaction(
    ws: Any,
    emoji: str,
    agent_name: str,
    channel: dict,
    trust: str,
) -> None:
    """Send a general reaction to an agent's message (no approval_id)."""
    await ws.send(
        json.dumps(
            {
                "type": "reaction",
                "emoji": emoji,
                "sender": "test-harness",
                "channel": channel,
                "agent_name": agent_name,
                "event_id": "",
                "trust": {"level": trust, "sender": "test-harness"},
            }
        )
    )


# ---------------------------------------------------------------------------
# Turn queue helpers
# ---------------------------------------------------------------------------


def _pop_next_message(turns: list[dict]) -> dict | None:
    for i, turn in enumerate(turns):
        if turn["type"] == "message":
            return turns.pop(i)
    return None


def _pop_next_react(turns: list[dict]) -> dict | None:
    for i, turn in enumerate(turns):
        if turn["type"] == "react":
            return turns.pop(i)
    return None


# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------


def _emit(frame: dict) -> None:
    print(json.dumps(frame), flush=True)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def _detect_token() -> str | None:
    """Read the connector token from the running gateway container."""
    try:
        result = subprocess.run(
            ["docker", "exec", "tri-onyx-gateway-1", "printenv", "TRI_ONYX_CONNECTOR_TOKEN"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip()
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass
    return None


def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("agent", help="Agent name to invoke")
    parser.add_argument(
        "prompt",
        nargs="?",
        help="Prompt to send (shorthand for a single message turn)",
    )
    parser.add_argument(
        "--turns",
        metavar="JSON",
        help="JSON array of turn objects (message/react); overrides prompt",
    )
    parser.add_argument(
        "--trust",
        choices=["verified", "unverified"],
        default="verified",
        help="Trust level (default: verified)",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=120.0,
        metavar="SECONDS",
        help="Max wait time per turn in seconds (default: 120)",
    )
    parser.add_argument(
        "--auto-approve",
        action="store_true",
        help="Automatically approve BCTP approval_request frames with 👍",
    )
    args = parser.parse_args()

    if args.turns:
        try:
            turns = json.loads(args.turns)
        except json.JSONDecodeError as e:
            print(f"Error: --turns is not valid JSON: {e}", file=sys.stderr)
            sys.exit(1)
    elif args.prompt:
        turns = [{"type": "message", "content": args.prompt}]
    else:
        parser.error("provide either a prompt argument or --turns JSON")

    gateway = os.environ.get("TRI_ONYX_GATEWAY", "ws://localhost:4000")
    token = os.environ.get("TRI_ONYX_CONNECTOR_TOKEN") or _detect_token()
    if not token:
        print(
            "Error: could not detect connector token. Set TRI_ONYX_CONNECTOR_TOKEN "
            "or ensure the tri-onyx-gateway-1 container is running.",
            file=sys.stderr,
        )
        sys.exit(1)

    exit_code = asyncio.run(
        run(
            args.agent,
            turns,
            gateway_url=gateway,
            token=token,
            trust=args.trust,
            timeout=args.timeout,
            auto_approve=args.auto_approve,
        )
    )
    sys.exit(exit_code)


if __name__ == "__main__":
    main()
