"""Config parsing, env interpolation and the validation guardrails."""

from __future__ import annotations

import pytest

from mcp_server.config import (
    CLAUDE_AI_REDIRECT_URI,
    ConfigError,
    canonical_resource,
    load_config,
    parse_config,
)

from conftest import raw_config


def test_parses_a_full_config():
    cfg = parse_config(raw_config(), path="test.yaml")
    assert cfg.public_url == "https://mcp.example.com"
    assert cfg.issuer_url == "https://mcp.example.com"
    assert cfg.resource_url == "https://mcp.example.com/mcp"
    assert cfg.login_url == "https://mcp.example.com/login"
    assert [a.name for a in cfg.agents] == ["main", "researcher"]
    assert cfg.agent("main").description == "The router"
    assert cfg.agent("nope") is None
    assert cfg.auth.redirect_uris == (CLAUDE_AI_REDIRECT_URI,)


def test_trailing_slash_is_stripped_from_public_url():
    cfg = parse_config(
        raw_config(server={"public_url": "https://mcp.example.com/"}), path="t"
    )
    assert cfg.issuer_url == "https://mcp.example.com"
    assert cfg.resource_url == "https://mcp.example.com/mcp"


@pytest.mark.parametrize(
    "url,expected",
    [
        ("HTTPS://MCP.Example.COM/mcp", "https://mcp.example.com/mcp"),
        ("https://mcp.example.com/mcp/", "https://mcp.example.com/mcp"),
        ("https://mcp.example.com:443/mcp", "https://mcp.example.com/mcp"),
        ("https://mcp.example.com/mcp?x=1#f", "https://mcp.example.com/mcp"),
        ("http://localhost:8765/mcp", "http://localhost:8765/mcp"),
    ],
)
def test_canonical_resource(url, expected):
    assert canonical_resource(url) == expected


def test_rejects_short_operator_password():
    with pytest.raises(ConfigError, match="at least 16"):
        parse_config(raw_config(auth={"operator_password": "short"}), path="t")


def test_rejects_unresolved_password_placeholder():
    with pytest.raises(ConfigError, match="MCP_OPERATOR_PASSWORD"):
        parse_config(
            raw_config(auth={"operator_password": "${MCP_OPERATOR_PASSWORD}"}), path="t"
        )


def test_rejects_unresolved_gateway_token():
    with pytest.raises(ConfigError, match="TRI_ONYX_CONNECTOR_TOKEN"):
        parse_config(
            raw_config(gateway={"token": "${TRI_ONYX_CONNECTOR_TOKEN}"}), path="t"
        )


def test_rejects_empty_agent_allowlist():
    with pytest.raises(ConfigError, match="at least one agent"):
        parse_config(raw_config(agents=[]), path="t")


def test_rejects_duplicate_agents():
    with pytest.raises(ConfigError, match="duplicate agent"):
        parse_config(raw_config(agents=["main", "main"]), path="t")


def test_rejects_plain_http_redirect_uri():
    with pytest.raises(ConfigError, match="must be https"):
        parse_config(raw_config(auth={"redirect_uris": ["http://evil.test/cb"]}), path="t")


def test_rejects_long_lived_auth_codes():
    with pytest.raises(ConfigError, match="auth_code_ttl_seconds"):
        parse_config(raw_config(auth={"auth_code_ttl_seconds": 3600}), path="t")


def test_agents_may_be_bare_strings():
    cfg = parse_config(raw_config(agents=["main"]), path="t")
    assert cfg.agents[0].name == "main"
    assert cfg.agents[0].description == ""


def test_load_config_interpolates_environment(tmp_path, monkeypatch):
    monkeypatch.setenv("MCP_PUBLIC_URL", "https://tunnel.example.com")
    monkeypatch.setenv("TRI_ONYX_CONNECTOR_TOKEN", "from-env-token")
    monkeypatch.setenv("MCP_OPERATOR_PASSWORD", "a-very-long-operator-password")
    path = tmp_path / "config.yaml"
    path.write_text(
        """
server:
  public_url: "${MCP_PUBLIC_URL}"
gateway:
  token: "${TRI_ONYX_CONNECTOR_TOKEN}"
auth:
  operator_password: "${MCP_OPERATOR_PASSWORD}"
agents:
  - name: main
"""
    )
    cfg = load_config(path)
    assert cfg.public_url == "https://tunnel.example.com"
    assert cfg.gateway_token == "from-env-token"
    assert cfg.auth.operator_password == "a-very-long-operator-password"


def test_load_config_missing_file(tmp_path):
    with pytest.raises(ConfigError, match="not found"):
        load_config(tmp_path / "nope.yaml")
