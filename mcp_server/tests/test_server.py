"""HTTP surface: discovery, DCR, the 401 challenge, the login page, and tools."""

from __future__ import annotations

import base64
import hashlib
from urllib.parse import parse_qs, urlsplit

import pytest
from mcp.server.mcpserver.exceptions import ToolError
from starlette.testclient import TestClient

from mcp_server.auth import TriOnyxAuthProvider
from mcp_server.config import ConfigError, parse_config
from mcp_server.gateway_bridge import GatewayError
from mcp_server.server import build_app, build_server, client_ip
from mcp_server.storage import OAuthStore

from conftest import CLAUDE_REDIRECT, OPERATOR_PASSWORD, raw_config

PUBLIC_URL = "https://mcp.example.com"
VERIFIER = "verifier-verifier-verifier-verifier"
CHALLENGE = base64.urlsafe_b64encode(hashlib.sha256(VERIFIER.encode()).digest()).decode().rstrip("=")


class StubBridge:
    """Minimal GatewayBridge stand-in for tool tests."""

    def __init__(self, reply: str = "hi from the agent", error: str | None = None):
        self.reply = reply
        self.error = error
        self.calls: list[tuple[str, str, str]] = []
        self.connected = True

    async def ask(self, agent_name, message, room_id, timeout=None):
        self.calls.append((agent_name, message, room_id))
        if self.error:
            raise GatewayError(self.error)
        return self.reply


@pytest.fixture
def bridge() -> StubBridge:
    return StubBridge()


@pytest.fixture
def wired(tmp_path, bridge):
    config = parse_config(raw_config(auth={"data_dir": str(tmp_path)}), path="t")
    provider = TriOnyxAuthProvider(config, OAuthStore(config.auth.store_path))
    mcp = build_server(config, provider, bridge)
    app = build_app(config, mcp)
    return config, provider, mcp, app


@pytest.fixture
def client(wired):
    _config, _provider, _mcp, app = wired
    # https so the Secure txn cookie set by /authorize participates in the flow.
    with TestClient(app, base_url="https://testserver") as test_client:
        yield test_client


def register_client(client: TestClient, redirect_uri: str = CLAUDE_REDIRECT) -> dict:
    """A DCR body shaped like the one claude.ai sends."""
    response = client.post(
        "/register",
        json={
            "client_name": "Claude",
            "redirect_uris": [redirect_uri],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
            "scope": "trionyx:chat",
        },
    )
    return response


# ---------------------------------------------------------------------------
# Discovery
# ---------------------------------------------------------------------------


def test_authorization_server_metadata(client):
    body = client.get("/.well-known/oauth-authorization-server").json()
    assert body["issuer"] == PUBLIC_URL
    assert body["authorization_endpoint"] == f"{PUBLIC_URL}/authorize"
    assert body["token_endpoint"] == f"{PUBLIC_URL}/token"
    assert body["registration_endpoint"] == f"{PUBLIC_URL}/register"
    assert body["code_challenge_methods_supported"] == ["S256"]
    assert set(body["grant_types_supported"]) == {"authorization_code", "refresh_token"}
    assert body["scopes_supported"] == ["trionyx:chat"]


def test_protected_resource_metadata_at_both_locations(client):
    for path in (
        "/.well-known/oauth-protected-resource",
        "/.well-known/oauth-protected-resource/mcp",
    ):
        response = client.get(path)
        assert response.status_code == 200, path
        body = response.json()
        assert body["resource"] == f"{PUBLIC_URL}/mcp"
        assert body["authorization_servers"] == [PUBLIC_URL]


def test_healthz(client, bridge):
    body = client.get("/healthz").json()
    assert body == {"status": "ok", "gateway_connected": True}


# ---------------------------------------------------------------------------
# The 401 challenge
# ---------------------------------------------------------------------------


def test_unauthenticated_mcp_call_gets_a_401_challenge(client):
    response = client.post(
        "/mcp",
        json={"jsonrpc": "2.0", "id": 1, "method": "tools/list"},
        headers={"Accept": "application/json, text/event-stream"},
    )
    assert response.status_code == 401
    challenge = response.headers["www-authenticate"]
    assert challenge.startswith("Bearer ")
    assert (
        f'resource_metadata="{PUBLIC_URL}/.well-known/oauth-protected-resource/mcp"'
        in challenge
    )


def test_bogus_bearer_token_gets_a_401_challenge(client):
    response = client.post(
        "/mcp",
        json={"jsonrpc": "2.0", "id": 1, "method": "tools/list"},
        headers={
            "Authorization": "Bearer not-a-real-token",
            "Accept": "application/json, text/event-stream",
        },
    )
    assert response.status_code == 401
    assert "resource_metadata=" in response.headers["www-authenticate"]


# ---------------------------------------------------------------------------
# Dynamic client registration
# ---------------------------------------------------------------------------


def test_dynamic_client_registration(client):
    response = register_client(client)
    assert response.status_code == 201
    body = response.json()
    assert body["client_id"]
    # Public client: no secret is minted.
    assert body.get("client_secret") is None
    assert body["redirect_uris"] == [CLAUDE_REDIRECT]


def test_confidential_registration_is_downgraded_to_a_public_client(client):
    """claude.ai registers as client_secret_post but never presents the secret
    at /token — every client is registered public (PKCE is the binding)."""
    response = client.post(
        "/register",
        json={
            "client_name": "Claude",
            "redirect_uris": [CLAUDE_REDIRECT],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "client_secret_post",
            "scope": "trionyx:chat",
        },
    )
    assert response.status_code == 201
    body = response.json()
    assert body["token_endpoint_auth_method"] == "none"
    assert body.get("client_secret") is None

    # The full flow works without a client secret at the token endpoint.
    location = authorize(client, body["client_id"]).headers["location"]
    txn = parse_qs(urlsplit(location).query)["txn"][0]
    redirect = client.post(
        "/login",
        data={"txn": txn, "password": OPERATOR_PASSWORD},
        follow_redirects=False,
    )
    code = parse_qs(urlsplit(redirect.headers["location"]).query)["code"][0]
    token_response = client.post(
        "/token",
        data={
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": CLAUDE_REDIRECT,
            "client_id": body["client_id"],
            "code_verifier": VERIFIER,
        },
    )
    assert token_response.status_code == 200, token_response.text
    assert token_response.json()["access_token"]


def test_registration_rejects_a_foreign_redirect_uri(client):
    response = register_client(client, redirect_uri="https://evil.test/callback")
    assert response.status_code == 400
    assert response.json()["error"] == "invalid_redirect_uri"


def test_registration_requires_json(client):
    response = client.post("/register", data={"redirect_uris": CLAUDE_REDIRECT})
    assert response.status_code == 400


# ---------------------------------------------------------------------------
# Authorization + login
# ---------------------------------------------------------------------------


def authorize(client: TestClient, client_id: str, **overrides) -> object:
    params = {
        "client_id": client_id,
        "redirect_uri": CLAUDE_REDIRECT,
        "response_type": "code",
        "code_challenge": CHALLENGE,
        "code_challenge_method": "S256",
        "state": "state-abc",
        "resource": f"{PUBLIC_URL}/mcp",
        "scope": "trionyx:chat",
    }
    params.update(overrides)
    return client.get("/authorize", params=params, follow_redirects=False)


def test_authorize_redirects_to_the_login_page(client):
    client_id = register_client(client).json()["client_id"]
    response = authorize(client, client_id)
    assert response.status_code == 302
    location = response.headers["location"]
    assert location.startswith(f"{PUBLIC_URL}/login?txn=")

    txn = parse_qs(urlsplit(location).query)["txn"][0]
    page = client.get("/login", params={"txn": txn})
    assert page.status_code == 200
    assert "Operator password" in page.text
    assert "Claude" in page.text
    assert page.headers["cache-control"] == "no-store"
    assert page.headers["x-frame-options"] == "DENY"


def test_authorize_without_pkce_is_rejected(client):
    client_id = register_client(client).json()["client_id"]
    response = client.get(
        "/authorize",
        params={
            "client_id": client_id,
            "redirect_uri": CLAUDE_REDIRECT,
            "response_type": "code",
            "state": "s",
        },
        follow_redirects=False,
    )
    # Redirected back to the client with an error — no code is ever issued.
    assert response.status_code == 302
    query = parse_qs(urlsplit(response.headers["location"]).query)
    assert query["error"] == ["invalid_request"]
    assert "code" not in query


def test_authorize_with_plain_pkce_is_rejected(client):
    client_id = register_client(client).json()["client_id"]
    response = authorize(client, client_id, code_challenge_method="plain")
    assert response.status_code == 302
    query = parse_qs(urlsplit(response.headers["location"]).query)
    assert "code" not in query


def test_authorize_with_a_foreign_resource_is_rejected(client):
    client_id = register_client(client).json()["client_id"]
    response = authorize(client, client_id, resource="https://evil.test/mcp")
    assert response.status_code == 302
    query = parse_qs(urlsplit(response.headers["location"]).query)
    assert query["error"] == ["invalid_target"]
    assert "code" not in query


def test_authorize_with_an_unregistered_redirect_uri_is_rejected(client):
    client_id = register_client(client).json()["client_id"]
    response = authorize(client, client_id, redirect_uri="https://evil.test/cb")
    assert response.status_code == 400
    assert "code" not in response.text


def test_wrong_password_does_not_issue_a_code(client, wired):
    _config, provider, _mcp, _app = wired
    client_id = register_client(client).json()["client_id"]
    location = authorize(client, client_id).headers["location"]
    txn = parse_qs(urlsplit(location).query)["txn"][0]

    response = client.post(
        "/login", data={"txn": txn, "password": "wrong"}, follow_redirects=False
    )
    assert response.status_code == 401
    assert "location" not in response.headers
    assert "Invalid credentials" in response.text
    assert provider._codes == {}


def test_login_page_for_an_unknown_transaction(client):
    response = client.get("/login", params={"txn": "nope"})
    assert response.status_code == 400
    assert "expired" in response.text.lower()


def test_authorize_sets_the_txn_binding_cookie(client):
    client_id = register_client(client).json()["client_id"]
    response = authorize(client, client_id)
    cookie = response.headers["set-cookie"]
    txn = parse_qs(urlsplit(response.headers["location"]).query)["txn"][0]
    assert cookie.startswith(f"mcp_txn={txn};")
    for attribute in ("HttpOnly", "Secure", "SameSite=Lax", "Path=/login"):
        assert attribute in cookie, cookie


def test_login_without_the_txn_cookie_is_refused(client, wired):
    """A pre-staged transaction cannot be completed from another browser.

    The attacker's browser initiates /authorize and holds the txn cookie; the
    phished operator opens the login link with the genuine domain but no
    cookie — even the correct password must not issue a code.
    """
    _config, provider, _mcp, _app = wired
    client_id = register_client(client).json()["client_id"]
    location = authorize(client, client_id).headers["location"]
    txn = parse_qs(urlsplit(location).query)["txn"][0]

    # The operator's browser: same app, no cookie jar entry.
    client.cookies.clear()

    page = client.get("/login", params={"txn": txn})
    assert page.status_code == 400
    assert "password" not in page.text.lower()

    response = client.post(
        "/login",
        data={"txn": txn, "password": OPERATOR_PASSWORD},
        follow_redirects=False,
    )
    assert response.status_code == 400
    assert "location" not in response.headers
    assert provider._codes == {}


def test_login_page_shows_the_verifiable_client_facts(client):
    client_id = register_client(client).json()["client_id"]
    location = authorize(client, client_id).headers["location"]
    txn = parse_qs(urlsplit(location).query)["txn"][0]
    page = client.get("/login", params={"txn": txn})
    assert client_id[:12] in page.text
    assert CLAUDE_REDIRECT in page.text


def test_oversized_login_body_is_refused(client):
    response = client.post("/login", data={"txn": "x", "password": "y" * 5000})
    assert response.status_code == 413


def test_repeated_wrong_passwords_lock_the_login_out(client, wired):
    _config, provider, _mcp, _app = wired
    client_id = register_client(client).json()["client_id"]
    location = authorize(client, client_id).headers["location"]
    txn = parse_qs(urlsplit(location).query)["txn"][0]

    for _ in range(provider._auth.max_login_failures):
        client.post("/login", data={"txn": txn, "password": "wrong"})
    response = client.post(
        "/login",
        data={"txn": txn, "password": OPERATOR_PASSWORD},
        follow_redirects=False,
    )
    assert response.status_code == 429
    assert provider._codes == {}


# ---------------------------------------------------------------------------
# End-to-end authorization code -> token -> refresh
# ---------------------------------------------------------------------------


def full_flow(client: TestClient) -> tuple[str, dict]:
    client_id = register_client(client).json()["client_id"]
    location = authorize(client, client_id).headers["location"]
    txn = parse_qs(urlsplit(location).query)["txn"][0]
    redirect = client.post(
        "/login",
        data={"txn": txn, "password": OPERATOR_PASSWORD},
        follow_redirects=False,
    )
    assert redirect.status_code == 302
    query = parse_qs(urlsplit(redirect.headers["location"]).query)
    assert query["state"] == ["state-abc"]
    code = query["code"][0]

    token_response = client.post(
        "/token",
        data={
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": CLAUDE_REDIRECT,
            "client_id": client_id,
            "code_verifier": VERIFIER,
            "resource": f"{PUBLIC_URL}/mcp",
        },
    )
    assert token_response.status_code == 200, token_response.text
    return client_id, token_response.json()


def test_full_authorization_flow_issues_a_usable_token(client):
    _client_id, tokens = full_flow(client)
    assert tokens["token_type"] == "Bearer"
    assert tokens["expires_in"] == 3600
    assert tokens["refresh_token"]

    response = client.post(
        "/mcp",
        json={
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": "2025-06-18",
                "capabilities": {},
                "clientInfo": {"name": "test", "version": "1"},
            },
        },
        headers={
            "Authorization": f"Bearer {tokens['access_token']}",
            "Accept": "application/json, text/event-stream",
        },
    )
    # The bearer token is accepted — anything in the 4xx range would mean the
    # token was rejected by the auth middleware.
    assert response.status_code < 400, response.text


def test_wrong_pkce_verifier_is_rejected(client):
    client_id = register_client(client).json()["client_id"]
    location = authorize(client, client_id).headers["location"]
    txn = parse_qs(urlsplit(location).query)["txn"][0]
    redirect = client.post(
        "/login",
        data={"txn": txn, "password": OPERATOR_PASSWORD},
        follow_redirects=False,
    )
    code = parse_qs(urlsplit(redirect.headers["location"]).query)["code"][0]

    response = client.post(
        "/token",
        data={
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": CLAUDE_REDIRECT,
            "client_id": client_id,
            "code_verifier": "the-wrong-verifier-the-wrong-verifier",
        },
    )
    assert response.status_code == 400
    assert response.json()["error"] == "invalid_grant"


def test_refresh_rotates_and_replay_returns_invalid_grant(client):
    client_id, tokens = full_flow(client)
    refreshed = client.post(
        "/token",
        data={
            "grant_type": "refresh_token",
            "refresh_token": tokens["refresh_token"],
            "client_id": client_id,
        },
    )
    assert refreshed.status_code == 200
    new_tokens = refreshed.json()
    assert new_tokens["refresh_token"] != tokens["refresh_token"]

    replay = client.post(
        "/token",
        data={
            "grant_type": "refresh_token",
            "refresh_token": tokens["refresh_token"],
            "client_id": client_id,
        },
    )
    assert replay.status_code == 400
    assert replay.json()["error"] == "invalid_grant"


def test_unknown_refresh_token_returns_invalid_grant(client):
    client_id, _tokens = full_flow(client)
    response = client.post(
        "/token",
        data={
            "grant_type": "refresh_token",
            "refresh_token": "made-up",
            "client_id": client_id,
        },
    )
    assert response.status_code == 400
    assert response.json()["error"] == "invalid_grant"


# ---------------------------------------------------------------------------
# Tools — one per allowlisted agent
# ---------------------------------------------------------------------------


async def test_tool_surface_is_one_tool_per_agent(wired):
    config, _provider, mcp, _app = wired
    tools = {tool.name: tool for tool in await mcp.list_tools()}
    assert sorted(tools) == ["main", "researcher"]
    for entry in config.agents:
        assert entry.description in tools[entry.name].description


async def test_agent_tool_forwards_to_the_bridge(wired, bridge):
    _config, _provider, mcp, _app = wired
    result = await mcp.call_tool(
        "main", {"message": "hello", "conversation_id": "c1"}
    )
    assert result.is_error is not True
    assert result.content[0].text == "hi from the agent"
    assert bridge.calls == [("main", "hello", "mcp-c1")]


async def test_agent_tool_defaults_the_conversation(wired, bridge):
    _config, _provider, mcp, _app = wired
    await mcp.call_tool("main", {"message": "hello"})
    assert bridge.calls == [("main", "hello", "mcp-default")]


async def test_agents_outside_the_allowlist_have_no_tool(wired, bridge):
    _config, _provider, mcp, _app = wired
    assert "evil" not in {tool.name for tool in await mcp.list_tools()}
    try:
        result = await mcp.call_tool("evil", {"message": "hello"})
    except Exception:  # noqa: BLE001 — unknown tools may raise or error-result
        pass
    else:
        assert result.is_error is True
    assert bridge.calls == []


async def test_agent_tool_rejects_gateway_system_commands(wired, bridge):
    _config, _provider, mcp, _app = wired
    for message in ("/restart other-agent", "  /restart other-agent", "/unknown"):
        with pytest.raises(ToolError, match="system commands"):
            await mcp.call_tool("main", {"message": message})
    assert bridge.calls == []


async def test_agent_tool_passes_skill_invocations_through(wired, bridge):
    _config, _provider, mcp, _app = wired
    result = await mcp.call_tool("main", {"message": "/newsagg:digest today"})
    assert result.is_error is not True
    assert bridge.calls == [("main", "/newsagg:digest today", "mcp-default")]


async def test_agent_tool_rejects_an_empty_message(wired, bridge):
    _config, _provider, mcp, _app = wired
    with pytest.raises(ToolError, match="empty"):
        await mcp.call_tool("main", {"message": "  "})
    assert bridge.calls == []


async def test_agent_tool_surfaces_gateway_errors_as_tool_errors(tmp_path):
    bridge = StubBridge(error="Agent 'main' did not respond within 300s.")
    config = parse_config(raw_config(auth={"data_dir": str(tmp_path)}), path="t")
    provider = TriOnyxAuthProvider(config, OAuthStore(config.auth.store_path))
    mcp = build_server(config, provider, bridge)
    # Direct call_tool raises; over the wire the kernel turns this into a
    # CallToolResult with is_error=True for the client.
    with pytest.raises(ToolError, match="did not respond"):
        await mcp.call_tool("main", {"message": "hi"})


async def test_agent_names_are_sanitized_into_tool_names(tmp_path, bridge):
    config = parse_config(
        raw_config(
            agents=[{"name": "news agg!", "description": "Gathers news"}],
            auth={"data_dir": str(tmp_path)},
        ),
        path="t",
    )
    provider = TriOnyxAuthProvider(config, OAuthStore(config.auth.store_path))
    mcp = build_server(config, provider, bridge)
    assert [tool.name for tool in await mcp.list_tools()] == ["news_agg"]
    await mcp.call_tool("news_agg", {"message": "hello"})
    # The gateway still sees the real agent name, not the sanitized tool name.
    assert bridge.calls == [("news agg!", "hello", "mcp-default")]


async def test_colliding_sanitized_tool_names_are_rejected(tmp_path, bridge):
    config = parse_config(
        raw_config(
            agents=[{"name": "news agg"}, {"name": "news_agg"}],
            auth={"data_dir": str(tmp_path)},
        ),
        path="t",
    )
    provider = TriOnyxAuthProvider(config, OAuthStore(config.auth.store_path))
    with pytest.raises(ConfigError, match="news_agg"):
        build_server(config, provider, bridge)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


class _FakeRequest:
    def __init__(self, headers, host="10.0.0.1"):
        self.headers = headers
        self.client = type("C", (), {"host": host})()


def test_client_ip_prefers_cloudflare_headers():
    assert client_ip(_FakeRequest({"cf-connecting-ip": "203.0.113.7"})) == "203.0.113.7"
    assert client_ip(_FakeRequest({"x-forwarded-for": "203.0.113.8, 10.0.0.2"})) == "203.0.113.8"
    assert client_ip(_FakeRequest({})) == "10.0.0.1"
