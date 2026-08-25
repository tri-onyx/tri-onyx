"""OAuth provider policy: registration, login, codes, tokens, rotation."""

from __future__ import annotations

import base64
import hashlib
import json
import time
from urllib.parse import parse_qs, urlsplit

import pytest
from mcp.server.auth.provider import (
    AuthorizationParams,
    AuthorizeError,
    RegistrationError,
    TokenError,
)

import mcp_server.auth as auth_module
from mcp_server.auth import (
    LoginExpired,
    LoginLocked,
    LoginRateLimiter,
    LoginRejected,
    TriOnyxAuthProvider,
)
from mcp_server.config import parse_config
from mcp_server.storage import OAuthStore

from conftest import CLAUDE_REDIRECT, OPERATOR_PASSWORD, make_client, raw_config


def pkce_challenge(verifier: str = "verifier-verifier-verifier-verifier") -> str:
    digest = hashlib.sha256(verifier.encode()).digest()
    return base64.urlsafe_b64encode(digest).decode().rstrip("=")


def auth_params(**overrides):
    defaults = dict(
        state="state-123",
        scopes=["trionyx:chat"],
        code_challenge=pkce_challenge(),
        redirect_uri=CLAUDE_REDIRECT,
        redirect_uri_provided_explicitly=True,
        resource="https://mcp.example.com/mcp",
    )
    defaults.update(overrides)
    return AuthorizationParams(**defaults)


async def park_and_login(provider, client, ip="1.2.3.4", **param_overrides) -> str:
    url = await provider.authorize(client, auth_params(**param_overrides))
    txn = parse_qs(urlsplit(url).query)["txn"][0]
    redirect = provider.complete_login(txn, OPERATOR_PASSWORD, ip)
    return parse_qs(urlsplit(redirect).query)["code"][0]


# ---------------------------------------------------------------------------
# Registration
# ---------------------------------------------------------------------------


async def test_registers_a_claude_shaped_client(provider):
    client = make_client()
    await provider.register_client(client)
    loaded = await provider.get_client("client-1")
    assert loaded is not None
    assert str(loaded.redirect_uris[0]) == CLAUDE_REDIRECT


async def test_rejects_registration_with_foreign_redirect_uri(provider):
    client = make_client(redirect_uris=["https://evil.test/callback"])
    with pytest.raises(RegistrationError) as exc:
        await provider.register_client(client)
    assert exc.value.error == "invalid_redirect_uri"
    assert await provider.get_client("client-1") is None


async def test_rejects_registration_with_no_redirect_uri(provider):
    client = make_client()
    client.redirect_uris = None
    with pytest.raises(RegistrationError):
        await provider.register_client(client)


async def test_rejects_registration_when_one_of_several_uris_is_foreign(provider):
    client = make_client(redirect_uris=[CLAUDE_REDIRECT, "https://evil.test/cb"])
    with pytest.raises(RegistrationError):
        await provider.register_client(client)


# ---------------------------------------------------------------------------
# Authorization
# ---------------------------------------------------------------------------


async def test_authorize_redirects_to_the_login_page(provider):
    client = make_client()
    await provider.register_client(client)
    url = await provider.authorize(client, auth_params())
    assert url.startswith("https://mcp.example.com/login?")
    txn = parse_qs(urlsplit(url).query)["txn"][0]
    assert provider.has_pending(txn)
    details = provider.pending_details(txn)
    assert details["client_name"] == "Claude"
    assert details["client_id"] == "client-1"
    assert details["redirect_uri"] == CLAUDE_REDIRECT


async def test_authorize_rejects_redirect_uri_outside_the_allowlist(provider):
    client = make_client()
    await provider.register_client(client)
    with pytest.raises(AuthorizeError) as exc:
        await provider.authorize(
            client, auth_params(redirect_uri="https://evil.test/callback")
        )
    assert exc.value.error == "access_denied"


@pytest.mark.parametrize(
    "resource",
    [
        "https://mcp.example.com/mcp",
        "https://MCP.example.com/mcp/",
        "https://mcp.example.com",
        None,
    ],
)
async def test_authorize_accepts_our_own_resource_indicator(provider, resource):
    client = make_client()
    await provider.register_client(client)
    assert await provider.authorize(client, auth_params(resource=resource))


async def test_authorize_rejects_foreign_resource_indicator(provider):
    client = make_client()
    await provider.register_client(client)
    with pytest.raises(AuthorizeError) as exc:
        await provider.authorize(
            client, auth_params(resource="https://evil.test/mcp")
        )
    assert exc.value.error == "invalid_target"


# ---------------------------------------------------------------------------
# Operator login
# ---------------------------------------------------------------------------


async def test_wrong_password_issues_no_code(provider):
    client = make_client()
    await provider.register_client(client)
    url = await provider.authorize(client, auth_params())
    txn = parse_qs(urlsplit(url).query)["txn"][0]

    with pytest.raises(LoginRejected):
        provider.complete_login(txn, "not-the-password", "1.2.3.4")

    # The transaction is still pending (the operator may retry) but no code exists.
    assert provider.has_pending(txn)
    assert provider._codes == {}


async def test_correct_password_redirects_with_code_and_state(provider):
    client = make_client()
    await provider.register_client(client)
    url = await provider.authorize(client, auth_params())
    txn = parse_qs(urlsplit(url).query)["txn"][0]

    redirect = provider.complete_login(txn, OPERATOR_PASSWORD, "1.2.3.4")
    parts = urlsplit(redirect)
    query = parse_qs(parts.query)
    assert f"{parts.scheme}://{parts.netloc}{parts.path}" == CLAUDE_REDIRECT
    assert query["state"] == ["state-123"]
    assert len(query["code"][0]) >= 32
    # The transaction is consumed.
    assert not provider.has_pending(txn)


async def test_unknown_transaction_is_expired_even_with_right_password(provider):
    with pytest.raises(LoginExpired):
        provider.complete_login("no-such-txn", OPERATOR_PASSWORD, "1.2.3.4")


async def test_unknown_transaction_never_evaluates_the_password(provider):
    # Without a pending transaction a password guess is refused outright and
    # does not consume a limiter attempt.
    with pytest.raises(LoginExpired):
        provider.complete_login("no-such-txn", "a-wrong-guess", "6.6.6.6")
    assert provider.limiter.failures("6.6.6.6") == 0


async def test_login_locks_out_after_repeated_failures(provider):
    client = make_client()
    await provider.register_client(client)
    url = await provider.authorize(client, auth_params())
    txn = parse_qs(urlsplit(url).query)["txn"][0]

    for _ in range(provider._auth.max_login_failures):
        with pytest.raises(LoginRejected):
            provider.complete_login(txn, "wrong", "9.9.9.9")

    # Even the correct password is refused while locked out.
    with pytest.raises(LoginLocked):
        provider.complete_login(txn, OPERATOR_PASSWORD, "9.9.9.9")

    # A different address is unaffected.
    assert provider.complete_login(txn, OPERATOR_PASSWORD, "1.1.1.1")


async def test_duplicate_submit_replays_the_same_redirect(provider):
    """Password managers can resubmit the form after a successful login; the
    duplicate must land on the same redirect, not a 'link expired' page."""
    client = make_client()
    await provider.register_client(client)
    url = await provider.authorize(client, auth_params())
    txn = parse_qs(urlsplit(url).query)["txn"][0]

    first = provider.complete_login(txn, OPERATOR_PASSWORD, "1.2.3.4")
    second = provider.complete_login(txn, OPERATOR_PASSWORD, "1.2.3.4")
    assert second == first
    # The replay minted nothing new — still exactly one (single-use) code.
    assert len(provider._codes) == 1


async def test_duplicate_submit_with_a_wrong_password_is_refused(provider):
    client = make_client()
    await provider.register_client(client)
    url = await provider.authorize(client, auth_params())
    txn = parse_qs(urlsplit(url).query)["txn"][0]

    provider.complete_login(txn, OPERATOR_PASSWORD, "1.2.3.4")
    with pytest.raises(LoginExpired):
        provider.complete_login(txn, "not-the-password", "1.2.3.4")
    # A password *was* evaluated, so the guess costs a limiter attempt — the
    # replay window is not a rate-limit-free oracle for a known-good txn.
    assert provider.limiter.failures("1.2.3.4") == 1


async def test_completed_login_replay_window_expires(provider):
    client = make_client()
    await provider.register_client(client)
    url = await provider.authorize(client, auth_params())
    txn = parse_qs(urlsplit(url).query)["txn"][0]

    provider.complete_login(txn, OPERATOR_PASSWORD, "1.2.3.4")
    provider._completed[txn].expires_at = time.time() - 1
    with pytest.raises(LoginExpired):
        provider.complete_login(txn, OPERATOR_PASSWORD, "1.2.3.4")


async def test_expired_pending_authorization_cannot_be_completed(provider):
    client = make_client()
    await provider.register_client(client)
    url = await provider.authorize(client, auth_params())
    txn = parse_qs(urlsplit(url).query)["txn"][0]

    provider._pending[txn].created_at -= (
        provider._auth.pending_authorization_ttl_seconds + 1
    )
    with pytest.raises(LoginExpired):
        provider.complete_login(txn, OPERATOR_PASSWORD, "1.2.3.4")


# ---------------------------------------------------------------------------
# Rate limiter
# ---------------------------------------------------------------------------


class FakeClock:
    def __init__(self) -> None:
        self.now = 1000.0

    def __call__(self) -> float:
        return self.now


def test_rate_limiter_lockout_expires():
    clock = FakeClock()
    limiter = LoginRateLimiter(
        max_failures=3, lockout_seconds=900, global_threshold=100, clock=clock
    )
    for _ in range(3):
        limiter.record_failure("10.0.0.1")
    assert limiter.locked_for("10.0.0.1") == pytest.approx(900)

    clock.now += 901
    assert limiter.locked_for("10.0.0.1") == 0
    assert limiter.failures("10.0.0.1") == 0


def test_rate_limiter_success_clears_failures():
    limiter = LoginRateLimiter(max_failures=5, clock=FakeClock())
    limiter.record_failure("10.0.0.1")
    limiter.record_failure("10.0.0.1")
    assert limiter.failures("10.0.0.1") == 2
    limiter.record_success("10.0.0.1")
    assert limiter.failures("10.0.0.1") == 0


def test_rate_limiter_global_backoff_grows_and_caps():
    clock = FakeClock()
    limiter = LoginRateLimiter(
        max_failures=1000,
        global_threshold=3,
        global_backoff_max=30.0,
        clock=clock,
    )
    for _ in range(3):
        limiter.record_failure(f"10.0.0.{_}")
    assert limiter.global_delay() == 0.0

    limiter.record_failure("10.0.0.9")
    assert limiter.global_delay() == 2.0
    for _ in range(10):
        limiter.record_failure("10.0.0.9")
    assert limiter.global_delay() == 30.0


def test_rate_limiter_global_backoff_resets_over_time():
    clock = FakeClock()
    limiter = LoginRateLimiter(
        max_failures=1000, lockout_seconds=900, global_threshold=1, clock=clock
    )
    limiter.record_failure("a")
    limiter.record_failure("b")
    assert limiter.global_delay() > 0
    clock.now += 901
    assert limiter.global_delay() == 0.0


def test_rate_limiter_sweeps_stale_below_threshold_entries():
    clock = FakeClock()
    limiter = LoginRateLimiter(max_failures=5, lockout_seconds=900, clock=clock)
    limiter.record_failure("10.0.0.1")
    clock.now += 901
    # Any later failure sweeps entries whose last failure predates the window.
    limiter.record_failure("10.0.0.2")
    assert "10.0.0.1" not in limiter._ips
    assert "10.0.0.2" in limiter._ips


def test_rate_limiter_caps_tracked_ips():
    clock = FakeClock()
    limiter = LoginRateLimiter(
        max_failures=5, lockout_seconds=900, max_tracked_ips=10, clock=clock
    )
    for i in range(50):
        clock.now += 1  # all within the lockout window, so nothing is stale
        limiter.record_failure(f"2001:db8::{i}")
    assert len(limiter._ips) <= 10
    # The most recent attacker is still tracked; the oldest were evicted.
    assert "2001:db8::49" in limiter._ips
    assert "2001:db8::0" not in limiter._ips


# ---------------------------------------------------------------------------
# Token issuance
# ---------------------------------------------------------------------------


async def test_authorization_code_is_single_use(provider):
    client = make_client()
    await provider.register_client(client)
    code = await park_and_login(provider, client)

    record = await provider.load_authorization_code(client, code)
    assert record is not None
    tokens = await provider.exchange_authorization_code(client, record)
    assert tokens.access_token

    with pytest.raises(TokenError) as exc:
        await provider.exchange_authorization_code(client, record)
    assert exc.value.error == "invalid_grant"
    assert await provider.load_authorization_code(client, code) is None


async def test_authorization_code_expires(provider):
    client = make_client()
    await provider.register_client(client)
    code = await park_and_login(provider, client)
    record = await provider.load_authorization_code(client, code)
    record.expires_at = time.time() - 1

    with pytest.raises(TokenError) as exc:
        await provider.exchange_authorization_code(client, record)
    assert exc.value.error == "invalid_grant"


async def test_authorization_code_is_bound_to_its_client(provider):
    client = make_client()
    other = make_client(client_id="client-2")
    await provider.register_client(client)
    await provider.register_client(other)
    code = await park_and_login(provider, client)
    assert await provider.load_authorization_code(other, code) is None


async def test_code_carries_pkce_challenge_and_resource(provider):
    client = make_client()
    await provider.register_client(client)
    challenge = pkce_challenge("another-verifier-another-verifier")
    code = await park_and_login(provider, client, code_challenge=challenge)
    record = await provider.load_authorization_code(client, code)
    assert record.code_challenge == challenge
    assert record.resource == "https://mcp.example.com/mcp"
    assert str(record.redirect_uri) == CLAUDE_REDIRECT


async def test_tokens_are_stored_hashed_only(provider, store, tmp_path):
    client = make_client()
    await provider.register_client(client)
    code = await park_and_login(provider, client)
    record = await provider.load_authorization_code(client, code)
    tokens = await provider.exchange_authorization_code(client, record)

    raw = (tmp_path / "oauth-store.json").read_text()
    assert tokens.access_token not in raw
    assert tokens.refresh_token not in raw
    digest = hashlib.sha256(tokens.access_token.encode()).hexdigest()
    assert digest in json.loads(raw)["access_tokens"]


async def test_access_token_verifies_and_carries_audience(provider):
    client = make_client()
    await provider.register_client(client)
    code = await park_and_login(provider, client)
    record = await provider.load_authorization_code(client, code)
    tokens = await provider.exchange_authorization_code(client, record)

    access = await provider.load_access_token(tokens.access_token)
    assert access is not None
    assert access.client_id == "client-1"
    assert access.scopes == ["trionyx:chat"]
    assert access.resource == "https://mcp.example.com/mcp"
    assert access.subject == "operator"
    assert await provider.load_access_token("not-a-token") is None


async def test_expired_access_token_is_rejected_and_dropped(provider, store):
    client = make_client()
    await provider.register_client(client)
    code = await park_and_login(provider, client)
    record = await provider.load_authorization_code(client, code)
    tokens = await provider.exchange_authorization_code(client, record)

    stored = store.get_access_token(tokens.access_token)
    stored["expires_at"] = time.time() - 5
    store.put_access_token(tokens.access_token, stored)

    assert await provider.load_access_token(tokens.access_token) is None
    assert store.get_access_token(tokens.access_token) is None


async def test_token_minted_for_another_audience_is_rejected(provider, store):
    client = make_client()
    await provider.register_client(client)
    code = await park_and_login(provider, client)
    record = await provider.load_authorization_code(client, code)
    tokens = await provider.exchange_authorization_code(client, record)

    stored = store.get_access_token(tokens.access_token)
    stored["resource"] = "https://evil.test/mcp"
    store.put_access_token(tokens.access_token, stored)

    assert await provider.load_access_token(tokens.access_token) is None


# ---------------------------------------------------------------------------
# Refresh rotation
# ---------------------------------------------------------------------------


async def issue_pair(provider, client):
    code = await park_and_login(provider, client)
    record = await provider.load_authorization_code(client, code)
    return await provider.exchange_authorization_code(client, record)


async def test_refresh_rotates_both_tokens_and_revokes_the_old_pair(provider):
    client = make_client()
    await provider.register_client(client)
    first = await issue_pair(provider, client)

    loaded = await provider.load_refresh_token(client, first.refresh_token)
    assert loaded is not None
    second = await provider.exchange_refresh_token(client, loaded, ["trionyx:chat"])

    assert second.refresh_token != first.refresh_token
    assert second.access_token != first.access_token
    # Old access token no longer verifies, old refresh token is gone.
    assert await provider.load_access_token(first.access_token) is None
    assert await provider.load_refresh_token(client, first.refresh_token) is None
    assert await provider.load_access_token(second.access_token) is not None


async def test_replayed_refresh_token_returns_invalid_grant(provider):
    client = make_client()
    await provider.register_client(client)
    first = await issue_pair(provider, client)
    loaded = await provider.load_refresh_token(client, first.refresh_token)
    await provider.exchange_refresh_token(client, loaded, ["trionyx:chat"])

    with pytest.raises(TokenError) as exc:
        await provider.exchange_refresh_token(client, loaded, ["trionyx:chat"])
    assert exc.value.error == "invalid_grant"


async def test_expired_refresh_token_returns_invalid_grant(provider, store):
    client = make_client()
    await provider.register_client(client)
    first = await issue_pair(provider, client)
    stored = store.get_refresh_token(first.refresh_token)
    stored["expires_at"] = time.time() - 1
    store.put_refresh_token(first.refresh_token, stored)

    loaded = await provider.load_refresh_token(client, first.refresh_token)
    with pytest.raises(TokenError) as exc:
        await provider.exchange_refresh_token(client, loaded, ["trionyx:chat"])
    assert exc.value.error == "invalid_grant"


async def test_refresh_token_belongs_to_its_client(provider):
    client = make_client()
    other = make_client(client_id="client-2")
    await provider.register_client(client)
    await provider.register_client(other)
    first = await issue_pair(provider, client)
    assert await provider.load_refresh_token(other, first.refresh_token) is None


async def test_refresh_does_not_extend_the_absolute_lifetime(provider, store):
    client = make_client()
    await provider.register_client(client)
    first = await issue_pair(provider, client)
    absolute = store.get_refresh_token(first.refresh_token)["absolute_expires_at"]

    loaded = await provider.load_refresh_token(client, first.refresh_token)
    second = await provider.exchange_refresh_token(client, loaded, ["trionyx:chat"])
    assert store.get_refresh_token(second.refresh_token)["absolute_expires_at"] == absolute


async def test_revoking_an_access_token_kills_its_refresh_token(provider):
    client = make_client()
    await provider.register_client(client)
    tokens = await issue_pair(provider, client)
    access = await provider.load_access_token(tokens.access_token)

    await provider.revoke_token(access)
    assert await provider.load_access_token(tokens.access_token) is None
    assert await provider.load_refresh_token(client, tokens.refresh_token) is None


async def test_revoking_a_refresh_token_kills_its_access_token(provider):
    client = make_client()
    await provider.register_client(client)
    tokens = await issue_pair(provider, client)
    refresh = await provider.load_refresh_token(client, tokens.refresh_token)

    await provider.revoke_token(refresh)
    assert await provider.load_refresh_token(client, tokens.refresh_token) is None
    assert await provider.load_access_token(tokens.access_token) is None


# ---------------------------------------------------------------------------
# Store
# ---------------------------------------------------------------------------


async def test_tokens_survive_a_restart(config, tmp_path):
    store = OAuthStore(tmp_path / "oauth-store.json")
    provider = TriOnyxAuthProvider(config, store)
    client = make_client()
    await provider.register_client(client)
    tokens = await issue_pair(provider, client)

    reborn = TriOnyxAuthProvider(config, OAuthStore(tmp_path / "oauth-store.json"))
    assert await reborn.load_access_token(tokens.access_token) is not None
    assert await reborn.get_client("client-1") is not None


def test_store_prunes_expired_records(tmp_path):
    store = OAuthStore(tmp_path / "store.json")
    store.put_access_token("live", {"client_id": "c", "expires_at": time.time() + 60})
    store.put_access_token("dead", {"client_id": "c", "expires_at": time.time() - 60})
    assert store.prune() == 1
    assert store.get_access_token("live") is not None
    assert store.get_access_token("dead") is None


def test_store_without_a_path_is_memory_only():
    store = OAuthStore(None)
    store.put_access_token("t", {"client_id": "c", "expires_at": None})
    assert store.get_access_token("t") is not None


@pytest.mark.skipif(
    hasattr(__import__("os"), "geteuid") and __import__("os").geteuid() == 0,
    reason="root ignores directory permissions",
)
def test_store_survives_an_unwritable_path(tmp_path):
    unwritable = tmp_path / "ro"
    unwritable.mkdir()
    unwritable.chmod(0o500)
    store = OAuthStore(unwritable / "store.json")
    store.put_access_token("t", {"client_id": "c", "expires_at": None})
    # Memory-only fallback: still readable in-process.
    assert store.get_access_token("t") is not None
    unwritable.chmod(0o700)


def test_store_ignores_a_corrupt_file(tmp_path):
    path = tmp_path / "store.json"
    path.write_text("{not json")
    store = OAuthStore(path)
    assert store.client_count() == 0


def test_store_evicts_the_oldest_tokenless_client_at_capacity(tmp_path):
    store = OAuthStore(tmp_path / "store.json", max_clients=2)
    assert store.put_client("old", {"client_id": "old", "client_id_issued_at": 100})
    assert store.put_client("new", {"client_id": "new", "client_id_issued_at": 200})
    assert store.put_client("newest", {"client_id": "newest", "client_id_issued_at": 300})
    assert store.client_count() == 2
    assert store.get_client("old") is None
    assert store.get_client("newest") is not None


def test_store_never_evicts_a_client_with_live_tokens(tmp_path):
    store = OAuthStore(tmp_path / "store.json", max_clients=1)
    assert store.put_client("active", {"client_id": "active", "client_id_issued_at": 100})
    store.put_refresh_token("rt", {"client_id": "active", "expires_at": None})
    assert not store.put_client("intruder", {"client_id": "intruder"})
    assert store.get_client("active") is not None
    assert store.get_client("intruder") is None


async def test_registration_fails_cleanly_when_the_store_is_full(tmp_path, config):
    store = OAuthStore(tmp_path / "store.json", max_clients=1)
    provider = TriOnyxAuthProvider(config, store)
    await provider.register_client(make_client(client_id="active"))
    await issue_pair(provider, make_client(client_id="active"))
    with pytest.raises(RegistrationError) as exc:
        await provider.register_client(make_client(client_id="one-too-many"))
    assert exc.value.error == "invalid_client_metadata"


def test_store_prunes_stale_tokenless_clients(tmp_path):
    store = OAuthStore(tmp_path / "store.json", client_ttl_seconds=3600)
    now = time.time()
    store.put_client("stale", {"client_id": "stale", "client_id_issued_at": now - 7200})
    store.put_client("fresh", {"client_id": "fresh", "client_id_issued_at": now - 60})
    store.put_client("stale-but-live", {"client_id": "stale-but-live", "client_id_issued_at": now - 7200})
    store.put_refresh_token("rt", {"client_id": "stale-but-live", "expires_at": None})
    assert store.prune(now) == 1
    assert store.get_client("stale") is None
    assert store.get_client("fresh") is not None
    assert store.get_client("stale-but-live") is not None


def test_config_scope_is_used_for_registration(config):
    assert config.auth.scope == "trionyx:chat"
    assert parse_config(raw_config(auth={"scope": "custom"}), path="t").auth.scope == "custom"


def test_store_prefers_evicting_a_client_with_no_pending_authorization(tmp_path):
    store = OAuthStore(tmp_path / "store.json", max_clients=2)
    store.put_client("mid-login", {"client_id": "mid-login", "client_id_issued_at": 100})
    store.put_client("idle", {"client_id": "idle", "client_id_issued_at": 200})
    # The oldest tokenless client is the one the operator is mid-login on, so
    # the flood evicts the idle registration instead.
    assert store.put_client(
        "flood", {"client_id": "flood"}, protected={"mid-login"}
    )
    assert store.get_client("mid-login") is not None
    assert store.get_client("idle") is None


def test_store_still_evicts_when_every_candidate_is_protected(tmp_path):
    store = OAuthStore(tmp_path / "store.json", max_clients=1)
    store.put_client("only", {"client_id": "only", "client_id_issued_at": 100})
    assert store.put_client("next", {"client_id": "next"}, protected={"only"})
    assert store.get_client("next") is not None


async def test_registration_does_not_evict_a_client_mid_authorization(tmp_path, config):
    store = OAuthStore(tmp_path / "store.json", max_clients=2)
    provider = TriOnyxAuthProvider(config, store)

    operator_client = make_client(client_id="operator")
    await provider.register_client(operator_client)
    await provider.register_client(make_client(client_id="idle"))
    await provider.authorize(operator_client, auth_params())  # parks a txn

    await provider.register_client(make_client(client_id="flood"))
    assert store.get_client("operator") is not None
    assert store.get_client("idle") is None


async def test_pending_authorizations_are_capped(provider):
    client = make_client()
    await provider.register_client(client)
    for _ in range(auth_module._MAX_PENDING + 5):
        await provider.authorize(client, auth_params())
    assert len(provider._pending) <= auth_module._MAX_PENDING


async def test_the_newest_pending_authorization_survives_a_flood(provider):
    client = make_client()
    await provider.register_client(client)
    for _ in range(auth_module._MAX_PENDING - 1):
        await provider.authorize(client, auth_params())
    mine = parse_qs(urlsplit(await provider.authorize(client, auth_params())).query)["txn"][0]
    for _ in range(10):
        await provider.authorize(client, auth_params())
    assert provider.has_pending(mine)
