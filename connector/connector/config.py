"""Configuration loader with YAML parsing and environment variable interpolation."""

from __future__ import annotations

import os
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import yaml

_ENV_VAR_RE = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}")

DEFAULT_CONFIG_PATH_ENV = "TRI_ONYX_CONNECTOR_CONFIG"


@dataclass(slots=True)
class RoomConfig:
    """Per-room configuration within an adapter."""

    agent: str
    mode: str = "mention"
    merge_window_ms: int = 3000
    show_steps: bool = False
    show_result: bool = True
    step_mode: str = "brief"  # raw | pretty | brief


@dataclass(slots=True)
class AdapterConfig:
    """Configuration for a single chat platform adapter."""

    enabled: bool = False
    homeserver: str = ""
    user_id: str = ""
    access_token: str = ""
    device_id: str = ""
    store_path: str = ""
    trusted_users: list[str] = field(default_factory=list)
    rooms: dict[str, RoomConfig] = field(default_factory=dict)
    heartbeat_rooms: dict[str, str] = field(default_factory=dict)
    approval_rooms: dict[str, str] = field(default_factory=dict)
    extra: dict[str, Any] = field(default_factory=dict)


@dataclass(slots=True)
class ConnectorConfig:
    """Top-level connector configuration."""

    gateway_url: str = "ws://gateway:4000/connectors/ws"
    connector_id: str = ""
    connector_token: str = ""
    adapters: dict[str, AdapterConfig] = field(default_factory=dict)


def _interpolate(value: Any) -> Any:
    """Recursively replace ``${VAR}`` placeholders with environment variable values."""
    if isinstance(value, str):
        return _ENV_VAR_RE.sub(lambda m: os.environ.get(m.group(1), m.group(0)), value)
    if isinstance(value, dict):
        return {k: _interpolate(v) for k, v in value.items()}
    if isinstance(value, list):
        return [_interpolate(v) for v in value]
    return value


def _parse_adapter(name: str, raw: dict[str, Any]) -> AdapterConfig:
    """Parse a raw adapter dict into an AdapterConfig."""
    rooms: dict[str, RoomConfig] = {}
    for room_id, room_raw in raw.get("rooms", {}).items():
        if isinstance(room_raw, dict):
            rooms[room_id] = RoomConfig(
                agent=room_raw.get("agent", name),
                mode=room_raw.get("mode", "mention"),
                merge_window_ms=int(room_raw.get("merge_window_ms", 3000)),
                show_steps=bool(room_raw.get("show_steps", False)),
                show_result=bool(room_raw.get("show_result", True)),
                step_mode=str(room_raw.get("step_mode", "brief")),
            )

    heartbeat_rooms: dict[str, str] = {}
    for agent_name, room_id in raw.get("heartbeat_rooms", {}).items():
        heartbeat_rooms[agent_name] = str(room_id)

    approval_rooms: dict[str, str] = {}
    for agent_name, room_id in raw.get("approval_rooms", {}).items():
        approval_rooms[agent_name] = str(room_id)

    known_keys = {
        "enabled", "homeserver", "user_id", "access_token",
        "device_id", "store_path", "trusted_users", "rooms",
        "heartbeat_rooms", "approval_rooms",
    }
    extra = {k: v for k, v in raw.items() if k not in known_keys}

    return AdapterConfig(
        enabled=bool(raw.get("enabled", False)),
        homeserver=str(raw.get("homeserver", "")),
        user_id=str(raw.get("user_id", "")),
        access_token=str(raw.get("access_token", "")),
        device_id=str(raw.get("device_id", "")),
        store_path=str(raw.get("store_path", "")),
        trusted_users=list(raw.get("trusted_users", [])),
        rooms=rooms,
        heartbeat_rooms=heartbeat_rooms,
        approval_rooms=approval_rooms,
        extra=extra,
    )


def load_config(path: str | Path | None = None) -> ConnectorConfig:
    """Load and return the connector configuration from a YAML file.

    If *path* is ``None``, falls back to the ``TRI_ONYX_CONNECTOR_CONFIG``
    environment variable, then ``config.yaml`` in the current directory.
    """
    if path is None:
        path = os.environ.get(DEFAULT_CONFIG_PATH_ENV, "config.yaml")

    raw = yaml.safe_load(Path(path).read_text())
    raw = _interpolate(raw)

    gateway = raw.get("gateway", {})
    adapters: dict[str, AdapterConfig] = {}
    for name, adapter_raw in raw.get("adapters", {}).items():
        if isinstance(adapter_raw, dict):
            adapters[name] = _parse_adapter(name, adapter_raw)

    return ConnectorConfig(
        gateway_url=str(gateway.get("url", "ws://gateway:4000/connectors/ws")),
        connector_id=str(gateway.get("connector_id", "")),
        connector_token=str(gateway.get("token", "")),
        adapters=adapters,
    )
