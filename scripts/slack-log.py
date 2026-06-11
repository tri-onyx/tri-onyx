# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "slack-sdk>=3.27",
# ]
# ///
"""Read the chat log of Slack channels the TriOnyx bot is a member of.

Development/ops tool: lets you inspect what agents and users actually
posted in bound channels without screenshots. Uses the bot token from
the environment or the repo .env file (the token is never printed).

Usage:
    uv run scripts/slack-log.py channels
    uv run scripts/slack-log.py read <#name|channel-id> [-n LIMIT]

Examples:
    uv run scripts/slack-log.py channels
    uv run scripts/slack-log.py read trionyx-golden-path-docs -n 20
"""

from __future__ import annotations

import argparse
import os
import sys
import time
from datetime import datetime
from pathlib import Path

from slack_sdk import WebClient
from slack_sdk.errors import SlackApiError

_RATE_LIMIT_RETRIES = 3

_CONNECTOR_CONTAINER = "trionyx-connector-1"


def _token_from_connector() -> str:
    """Read the bot token from the running connector's config.

    The connector's config is the authoritative token source (the .env
    copy has drifted before). Fetched in-process and never printed.
    """
    import subprocess

    try:
        result = subprocess.run(
            [
                "docker", "exec", _CONNECTOR_CONTAINER, "/app/.venv/bin/python", "-c",
                # The connector's own loader applies ${VAR} interpolation
                # with the container environment.
                "from connector.config import load_config; "
                "print(load_config('/app/config.yaml').adapters['slack'].extra.get('bot_token', ''))",
            ],
            capture_output=True, text=True, timeout=15,
        )
        if result.returncode == 0:
            return result.stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        pass
    return ""


def _load_token() -> str:
    # Connector config first: the SLACK_BOT_TOKEN in the host env / .env
    # has drifted from the token the live bot actually uses.
    token = _token_from_connector() or os.environ.get("SLACK_BOT_TOKEN", "")
    if not token:
        env_file = Path(__file__).resolve().parent.parent / ".env"
        if env_file.exists():
            for line in env_file.read_text().splitlines():
                line = line.strip()
                if line.startswith("SLACK_BOT_TOKEN="):
                    token = line.split("=", 1)[1].strip().strip("'\"")
                    break
    if not token:
        sys.exit("SLACK_BOT_TOKEN not set (env, connector container, or .env)")
    return token


def _call(method, **kwargs):
    """Invoke a Slack API method, retrying on 429 with Retry-After."""
    for attempt in range(_RATE_LIMIT_RETRIES + 1):
        try:
            return method(**kwargs)
        except SlackApiError as exc:
            if exc.response.status_code == 429 and attempt < _RATE_LIMIT_RETRIES:
                delay = int(exc.response.headers.get("Retry-After", 30))
                print(f"(rate limited, retrying in {delay}s)", file=sys.stderr)
                time.sleep(delay)
                continue
            raise
    raise AssertionError("unreachable")


def _bot_channels(client: WebClient) -> list[dict]:
    """All channels the bot is a member of (public and private)."""
    channels: list[dict] = []
    cursor = ""
    while True:
        resp = _call(
            client.users_conversations,
            types="public_channel,private_channel",
            exclude_archived=True,
            limit=200,
            cursor=cursor or None,
        )
        channels.extend(resp.get("channels", []))
        cursor = resp.get("response_metadata", {}).get("next_cursor", "")
        if not cursor:
            return channels


def cmd_channels(client: WebClient) -> None:
    for ch in sorted(_bot_channels(client), key=lambda c: c.get("name", "")):
        kind = "private" if ch.get("is_private") else "public"
        print(f"{ch['id']}  #{ch.get('name', '?'):<40} {kind}")


class NameCache:
    """Resolves Slack user IDs and bot IDs to display names, cached."""

    def __init__(self, client: WebClient) -> None:
        self._client = client
        self._names: dict[str, str] = {}

    def user(self, user_id: str) -> str:
        if user_id not in self._names:
            try:
                resp = _call(self._client.users_info, user=user_id)
                profile = resp["user"].get("profile", {})
                self._names[user_id] = (
                    profile.get("display_name")
                    or resp["user"].get("real_name")
                    or resp["user"].get("name")
                    or user_id
                )
            except SlackApiError:
                self._names[user_id] = user_id
        return self._names[user_id]


def cmd_read(client: WebClient, target: str, limit: int) -> None:
    channel_id = target
    if not target.upper().startswith(("C", "G")) or "#" in target or target != target.upper():
        # Treat as a channel name — resolve via the bot's membership list.
        name = target.lstrip("#")
        match = next((c for c in _bot_channels(client) if c.get("name") == name), None)
        if match is None:
            sys.exit(f"channel '{name}' not found among the bot's channels (try: channels)")
        channel_id = match["id"]

    resp = _call(client.conversations_history, channel=channel_id, limit=limit)
    names = NameCache(client)

    for msg in reversed(resp.get("messages", [])):
        ts = datetime.fromtimestamp(float(msg.get("ts", 0)))
        when = ts.strftime("%Y-%m-%d %H:%M")

        if msg.get("user"):
            author = names.user(msg["user"])
        elif msg.get("bot_profile"):
            author = msg["bot_profile"].get("name", "bot")
        else:
            author = msg.get("username", "?")

        text = msg.get("text", "").strip()
        reply_note = ""
        if msg.get("reply_count"):
            reply_note = f"  ({msg['reply_count']} thread replies)"

        indent = " " * (len(when) + 2)
        body = text.replace("\n", f"\n{indent}")
        print(f"[{when}] {author}: {body}{reply_note}")

        for reaction in msg.get("reactions", []):
            users = ", ".join(names.user(u) for u in reaction.get("users", []))
            print(f"{indent}:{reaction['name']}: by {users}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("channels", help="list channels the bot is in")

    read = sub.add_parser("read", help="print recent messages from a channel")
    read.add_argument("channel", help="channel name (with or without #) or ID")
    read.add_argument("-n", "--limit", type=int, default=30, help="messages to fetch (default 30)")

    args = parser.parse_args()
    client = WebClient(token=_load_token())

    if args.command == "channels":
        cmd_channels(client)
    elif args.command == "read":
        cmd_read(client, args.channel, args.limit)


if __name__ == "__main__":
    main()
