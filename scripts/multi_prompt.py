# /// script
# requires-python = ">=3.11"
# dependencies = ["httpx>=0.27"]
# ///
"""
Send multiple prompts to a TriOnyx agent session, waiting for each
to complete before sending the next.

Usage:
  uv run scripts/multi_prompt.py <agent> <prompt1> [prompt2] ...

Examples:
  uv run scripts/multi_prompt.py code-reviewer "Review auth.py" "Now check tests"
  uv run scripts/multi_prompt.py code-reviewer "Hello" "Follow up"

Options:
  --base-url  Gateway URL (default: http://localhost:4000)
"""

from __future__ import annotations

import argparse
import json
import sys
import threading
from typing import Any

import httpx


def parse_sse_stream(
    response: httpx.Response,
    on_event: Any,
    stop_event: threading.Event,
) -> None:
    """Parse an SSE stream, calling on_event(event_type, data) for each event."""
    event_type = ""
    data_lines: list[str] = []

    for line in response.iter_lines():
        if stop_event.is_set():
            break

        if line.startswith("event:"):
            event_type = line[len("event:") :].strip()
        elif line.startswith("data:"):
            data_lines.append(line[len("data:") :].strip())
        elif line == "":
            # Empty line = end of event
            if event_type and data_lines:
                data = "\n".join(data_lines)
                on_event(event_type, data)
            event_type = ""
            data_lines = []


def run(base_url: str, agent: str, prompts: list[str]) -> None:
    result_event = threading.Event()
    stop_event = threading.Event()
    last_error: list[str] = []

    def on_event(event_type: str, data: str) -> None:
        try:
            payload = json.loads(data)
        except json.JSONDecodeError:
            payload = data

        if event_type == "text":
            content = payload.get("content", data) if isinstance(payload, dict) else data
            print(content, end="", flush=True)
        elif event_type == "tool_use":
            name = payload.get("name", "?") if isinstance(payload, dict) else "?"
            print(f"\n[tool: {name}]", flush=True)
        elif event_type == "tool_result":
            is_err = payload.get("is_error", False) if isinstance(payload, dict) else False
            label = "tool_error" if is_err else "tool_result"
            content = payload.get("content", "")[:200] if isinstance(payload, dict) else ""
            print(f"[{label}: {content}]", flush=True)
        elif event_type == "error":
            msg = payload.get("message", data) if isinstance(payload, dict) else data
            last_error.clear()
            last_error.append(msg)
            print(f"\n[error: {msg}]", file=sys.stderr, flush=True)
        elif event_type == "result":
            turns = payload.get("num_turns", "?") if isinstance(payload, dict) else "?"
            ms = payload.get("duration_ms", "?") if isinstance(payload, dict) else "?"
            print(f"\n--- result: {turns} turns, {ms}ms ---\n", flush=True)
            result_event.set()
        elif event_type == "ready":
            pass  # handled in main flow
        elif event_type == "port_down":
            last_error.clear()
            last_error.append("agent port crashed")
            print("\n[port_down: agent process died]", file=sys.stderr, flush=True)
            result_event.set()

    client = httpx.Client(base_url=base_url, timeout=None)

    # Start the agent session
    print(f"Starting agent '{agent}'...")
    resp = client.post(f"/agents/{agent}/start")
    if resp.status_code != 200:
        print(f"Failed to start agent: {resp.status_code} {resp.text}", file=sys.stderr)
        sys.exit(1)

    # Connect to SSE in a background thread
    sse_client = httpx.Client(base_url=base_url, timeout=None)
    sse_response = sse_client.send(
        sse_client.build_request("GET", f"/agents/{agent}/events"),
        stream=True,
    )

    sse_thread = threading.Thread(
        target=parse_sse_stream,
        args=(sse_response, on_event, stop_event),
        daemon=True,
    )
    sse_thread.start()

    try:
        for i, prompt in enumerate(prompts, 1):
            result_event.clear()
            last_error.clear()

            print(f"=== Prompt {i}/{len(prompts)}: {prompt[:80]} ===\n")
            resp = client.post(
                f"/agents/{agent}/prompt",
                json={"content": prompt},
            )
            if resp.status_code != 200:
                print(
                    f"Failed to send prompt: {resp.status_code} {resp.text}",
                    file=sys.stderr,
                )
                break

            # Wait for the result event from SSE
            result_event.wait()

            if last_error:
                print(f"Agent errored, aborting remaining prompts.", file=sys.stderr)
                break
    finally:
        stop_event.set()
        # Stop the agent session
        client.post(f"/agents/{agent}/stop")
        sse_response.close()
        sse_client.close()
        client.close()


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Send multiple prompts to a TriOnyx agent session.",
    )
    parser.add_argument("agent", help="Agent name (e.g. code-reviewer)")
    parser.add_argument("prompts", nargs="+", help="Prompts to send in order")
    parser.add_argument(
        "--base-url",
        default="http://localhost:4000",
        help="Gateway URL (default: http://localhost:4000)",
    )
    args = parser.parse_args()
    run(args.base_url, args.agent, args.prompts)


if __name__ == "__main__":
    main()
