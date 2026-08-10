"""Shared fixtures: a realistic config and a provider backed by a temp store."""

from __future__ import annotations

from pathlib import Path
from typing import Any

import pytest
from mcp.shared.auth import OAuthClientInformationFull

from mcp_server.auth import TriOnyxAuthProvider
from mcp_server.config import McpConfig, parse_config
from mcp_server.storage import OAuthStore

OPERATOR_PASSWORD = "correct-horse-battery-staple-42"  # gitleaks:allow — test fixture
CLAUDE_REDIRECT = "https://claude.ai/api/mcp/auth_callback"


def raw_config(**overrides: Any) -> dict[str, Any]:
    base: dict[str, Any] = {
        "server": {
            "public_url": "https://mcp.example.com",
            "bind_host": "0.0.0.0",
            "bind_port": 8765,
            "allowed_hosts": ["testserver"],
        },
        "gateway": {
            "url": "ws://gateway:4000/connectors/ws",
            "token": "gateway-token",
            "connector_id": "mcp",
        },
        "auth": {
            "operator_password": OPERATOR_PASSWORD,
            "redirect_uris": [CLAUDE_REDIRECT],
            "data_dir": "/tmp",
        },
        "session": {"sender": "mcp-operator", "timeout_seconds": 5},
        "agents": [
            {"name": "main", "description": "The router"},
            {"name": "researcher", "description": "Deep research"},
        ],
    }
    for key, value in overrides.items():
        if isinstance(value, dict) and isinstance(base.get(key), dict):
            base[key] = {**base[key], **value}
        else:
            base[key] = value
    return base


@pytest.fixture
def config(tmp_path: Path) -> McpConfig:
    return parse_config(raw_config(auth={"data_dir": str(tmp_path)}), path="test.yaml")


@pytest.fixture
def store(tmp_path: Path) -> OAuthStore:
    return OAuthStore(tmp_path / "oauth-store.json")


@pytest.fixture
def provider(config: McpConfig, store: OAuthStore) -> TriOnyxAuthProvider:
    return TriOnyxAuthProvider(config, store)


def make_client(
    client_id: str = "client-1",
    redirect_uris: list[str] | None = None,
    **extra: Any,
) -> OAuthClientInformationFull:
    return OAuthClientInformationFull.model_validate(
        {
            "client_id": client_id,
            "redirect_uris": redirect_uris or [CLAUDE_REDIRECT],
            "token_endpoint_auth_method": "none",
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "client_name": "Claude",
            "scope": "trionyx:chat",
            **extra,
        }
    )
