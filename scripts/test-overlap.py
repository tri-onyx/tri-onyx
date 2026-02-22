# /// script
# requires-python = ">=3.11"
# dependencies = ["websockets>=12.0"]
# ///
"""Test overlapping messages to reproduce off-by-one ordering bug.

Sends message A, then immediately sends message B without waiting for A
to finish. Observes which responses come back and in what order.
"""
from __future__ import annotations

import asyncio
import json
import os
import subprocess
import sys

import websockets


def _detect_token() -> str | None:
    try:
        result = subprocess.run(
            ["docker", "exec", "tri-onyx-gateway-1", "printenv", "TRI_ONYX_CONNECTOR_TOKEN"],
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip()
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass
    return None


async def main() -> None:
    gateway = os.environ.get("TRI_ONYX_GATEWAY", "ws://localhost:4000")
    token = os.environ.get("TRI_ONYX_CONNECTOR_TOKEN") or _detect_token()
    if not token:
        print("Error: no connector token", file=sys.stderr)
        sys.exit(1)

    agent_name = "cheerleader"
    ws_url = gateway.rstrip("/") + "/connectors/ws"
    channel = {"platform": "test", "room_id": "test-overlap"}

    async with websockets.connect(ws_url) as ws:
        # Register
        await ws.send(json.dumps({
            "type": "register",
            "connector_id": "test-overlap",
            "platform": "test",
            "token": token,
        }))
        ack = json.loads(await ws.recv())
        assert ack.get("type") == "registered", f"Registration failed: {ack}"
        print("✓ Registered", file=sys.stderr)

        # Send message A
        msg_a = "Say ONLY the word ALPHA and nothing else. No punctuation."
        await ws.send(json.dumps({
            "type": "message",
            "agent_name": agent_name,
            "content": msg_a,
            "channel": channel,
            "trust": {"level": "verified", "sender": "test-overlap"},
        }))
        print(f"→ Sent message A: {msg_a!r}", file=sys.stderr)

        # Wait 2 seconds (agent should be running), then send message B
        await asyncio.sleep(2)

        msg_b = "Say ONLY the word BRAVO and nothing else. No punctuation."
        await ws.send(json.dumps({
            "type": "message",
            "agent_name": agent_name,
            "content": msg_b,
            "channel": channel,
            "trust": {"level": "verified", "sender": "test-overlap"},
        }))
        print(f"→ Sent message B: {msg_b!r}", file=sys.stderr)

        # Collect all frames for up to 60 seconds
        results_seen = 0
        texts = []
        try:
            async with asyncio.timeout(60):
                async for raw in ws:
                    frame = json.loads(raw)
                    ft = frame.get("type")

                    if ft == "agent_text":
                        content = frame.get("content", "")
                        texts.append(content)
                        print(f"  TEXT: {content!r}", file=sys.stderr)

                    elif ft == "agent_result":
                        results_seen += 1
                        print(f"  RESULT #{results_seen}", file=sys.stderr)
                        if results_seen >= 2:
                            break

                    elif ft == "agent_error":
                        print(f"  ERROR: {frame.get('message')}", file=sys.stderr)

                    elif ft == "error":
                        print(f"  DISPATCH ERROR: {frame.get('message')}", file=sys.stderr)

        except asyncio.TimeoutError:
            print("  TIMEOUT waiting for results", file=sys.stderr)

    print(file=sys.stderr)
    print("=" * 60, file=sys.stderr)
    print(f"Messages sent:  A='ALPHA', B='BRAVO'", file=sys.stderr)
    print(f"Text responses: {texts}", file=sys.stderr)
    print(f"Results seen:   {results_seen}", file=sys.stderr)
    print("=" * 60, file=sys.stderr)

    # Output as JSON for scripting
    print(json.dumps({
        "messages_sent": ["ALPHA", "BRAVO"],
        "text_responses": texts,
        "results_seen": results_seen,
    }))


if __name__ == "__main__":
    asyncio.run(main())
