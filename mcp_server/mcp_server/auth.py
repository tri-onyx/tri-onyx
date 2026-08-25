"""Operator-only OAuth 2.1 authorization server.

The MCP SDK serves the endpoints (`/.well-known/oauth-authorization-server`,
`/authorize`, `/token`, `/register`) and enforces PKCE-S256, the redirect-URI
round-trip and code expiry. This module supplies the *policy*:

* Dynamic Client Registration is open (the spec requires it) but grants nothing:
  a registered client still has to send the operator through an interactive
  login at ``/login`` before any authorization code exists.
* The login compares a single high-entropy secret in constant time, behind a
  per-IP lockout plus a global exponential backoff.
* Redirect URIs are checked against a configured allowlist at registration *and*
  at authorization time, so widening/narrowing the allowlist takes effect for
  already-registered clients.
* RFC 8707 ``resource`` is validated against this server's canonical URL and
  bound into the issued token's audience; the audience is re-checked on every
  bearer-token verification.
* Access and refresh tokens are random, stored hashed, and refresh tokens rotate
  on every use with the previous access token revoked in the same step.
"""

from __future__ import annotations

import hmac
import logging
import secrets
import time
from dataclasses import dataclass, field
from typing import Any

from mcp.server.auth.provider import (
    AccessToken,
    AuthorizationCode,
    AuthorizationParams,
    AuthorizeError,
    OAuthAuthorizationServerProvider,
    RefreshToken,
    RegistrationError,
    TokenError,
    construct_redirect_uri,
)
from mcp.shared.auth import OAuthClientInformationFull, OAuthToken

from mcp_server.config import McpConfig, canonical_resource
from mcp_server.storage import OAuthStore, hash_token

logger = logging.getLogger(__name__)

#: Entropy of the tokens we mint (bytes before base64url encoding).
_TOKEN_BYTES = 32
_CODE_BYTES = 32
_TXN_BYTES = 32

_SUBJECT = "operator"


class LoginError(Exception):
    """Base class for interactive-login failures."""


class LoginLocked(LoginError):
    """Too many failed attempts from this client."""

    def __init__(self, retry_after: float) -> None:
        super().__init__("Too many failed attempts. Try again later.")
        self.retry_after = retry_after


class LoginExpired(LoginError):
    """The authorization transaction is unknown or has expired."""


class LoginRejected(LoginError):
    """Wrong password."""


@dataclass(slots=True)
class _PendingAuthorization:
    """An /authorize request parked until the operator logs in."""

    client_id: str
    redirect_uri: str
    redirect_uri_provided_explicitly: bool
    code_challenge: str
    scopes: list[str]
    state: str | None
    resource: str | None
    created_at: float


@dataclass(slots=True)
class _CompletedLogin:
    """A recently finished login, kept briefly so duplicate form submissions
    (password-manager interstitials, double clicks) replay the same redirect
    instead of landing on a 'link expired' page."""

    redirect_url: str
    expires_at: float


#: How long a finished login transaction stays replayable.
_COMPLETED_LOGIN_TTL = 60.0

#: Ceiling on parked /authorize transactions. Any registered client can park
#: one, so the table is bounded; the oldest goes first (it is the closest to its
#: TTL anyway, and the operator is working on the newest).
_MAX_PENDING = 64


@dataclass(slots=True)
class _IpState:
    failures: int = 0
    locked_until: float = 0.0
    last_failure: float = 0.0


@dataclass(slots=True)
class LoginRateLimiter:
    """Per-IP lockout plus a global exponential backoff.

    A per-IP hard lockout stops a single attacker cheaply. The global counter
    exists so a distributed attempt cannot simply rotate source addresses — but
    it applies a *delay* rather than a lockout, so an attacker cannot lock the
    operator out of his own server by burning attempts.
    """

    max_failures: int = 5
    lockout_seconds: float = 900.0
    global_threshold: int = 20
    global_backoff_max: float = 30.0
    max_tracked_ips: int = 10_000
    clock: Any = time.monotonic

    _ips: dict[str, _IpState] = field(default_factory=dict)
    _global_failures: int = 0
    _global_reset_at: float = 0.0

    # -- queries ---------------------------------------------------------

    def failures(self, ip: str) -> int:
        """Consecutive failed attempts recorded for this IP."""
        state = self._ips.get(ip)
        return state.failures if state is not None else 0

    def locked_for(self, ip: str) -> float:
        """Seconds remaining on this IP's lockout (0 if not locked)."""
        state = self._ips.get(ip)
        if state is None:
            return 0.0
        remaining = state.locked_until - self.clock()
        if remaining <= 0:
            if state.locked_until:
                # Lock elapsed — start over.
                self._ips.pop(ip, None)
            return 0.0
        return remaining

    def global_delay(self) -> float:
        """Backoff delay to apply before evaluating any attempt."""
        now = self.clock()
        if self._global_reset_at and now >= self._global_reset_at:
            self._global_failures = 0
            self._global_reset_at = 0.0
        excess = self._global_failures - self.global_threshold
        if excess <= 0:
            return 0.0
        return min(float(2 ** min(excess, 16)), self.global_backoff_max)

    # -- mutations -------------------------------------------------------

    def record_failure(self, ip: str) -> None:
        now = self.clock()
        self._sweep(now)
        state = self._ips.setdefault(ip, _IpState())
        state.failures += 1
        state.last_failure = now
        if state.failures >= self.max_failures:
            state.locked_until = now + self.lockout_seconds
        self._global_failures += 1
        self._global_reset_at = now + self.lockout_seconds

    def _sweep(self, now: float) -> None:
        """Bound memory under source-address rotation.

        Entries below the lockout threshold whose last failure is older than the
        lockout window carry no signal any more; beyond that, the table is
        hard-capped by evicting the stalest entries.
        """
        stale = [
            ip
            for ip, state in self._ips.items()
            if state.locked_until <= now
            and now - state.last_failure > self.lockout_seconds
        ]
        for ip in stale:
            self._ips.pop(ip, None)
        while len(self._ips) >= self.max_tracked_ips:
            oldest = min(self._ips, key=lambda ip: self._ips[ip].last_failure)
            self._ips.pop(oldest, None)

    def record_success(self, ip: str) -> None:
        self._ips.pop(ip, None)
        self._global_failures = 0
        self._global_reset_at = 0.0


class TriOnyxAuthProvider(
    OAuthAuthorizationServerProvider[AuthorizationCode, RefreshToken, AccessToken]
):
    """Combined authorization server + resource server for a single operator."""

    def __init__(self, config: McpConfig, store: OAuthStore) -> None:
        self._config = config
        self._auth = config.auth
        self._store = store
        self._pending: dict[str, _PendingAuthorization] = {}
        self._completed: dict[str, _CompletedLogin] = {}
        self._codes: dict[str, AuthorizationCode] = {}
        self._allowed_redirects = {
            canonical_resource(u) for u in config.auth.redirect_uris
        }
        self.limiter = LoginRateLimiter(
            max_failures=config.auth.max_login_failures,
            lockout_seconds=float(config.auth.lockout_seconds),
            global_threshold=config.auth.global_failure_threshold,
            global_backoff_max=config.auth.global_backoff_max_seconds,
        )

    # ------------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------------

    def _redirect_allowed(self, uri: str) -> bool:
        return canonical_resource(uri) in self._allowed_redirects

    def _resource_ok(self, resource: str | None) -> bool:
        """RFC 8707: accept only this server's own canonical resource URL.

        Both the full endpoint (``https://host/mcp``) and the bare origin
        (``https://host``) are accepted — clients differ on which they send —
        but the token audience is always bound to the endpoint form.
        """
        if resource is None:
            return True
        candidate = canonical_resource(resource)
        return candidate in (
            self._config.canonical_resource_url,
            self._config.canonical_issuer_url,
        )

    def _prune_pending(self, now: float | None = None) -> None:
        now = time.time() if now is None else now
        ttl = self._auth.pending_authorization_ttl_seconds
        for txn in [t for t, p in self._pending.items() if p.created_at + ttl < now]:
            self._pending.pop(txn, None)
        for txn in [t for t, c in self._completed.items() if c.expires_at < now]:
            self._completed.pop(txn, None)
        for code, record in list(self._codes.items()):
            if record.expires_at < now:
                self._codes.pop(code, None)

    # ------------------------------------------------------------------
    # Client registration (RFC 7591)
    # ------------------------------------------------------------------

    async def get_client(self, client_id: str) -> OAuthClientInformationFull | None:
        record = self._store.get_client(client_id)
        if record is None:
            return None
        return OAuthClientInformationFull.model_validate(record)

    async def register_client(self, client_info: OAuthClientInformationFull) -> None:
        # Every client is registered as a *public* client, whatever it asked
        # for: this AS mandates PKCE-S256 and gates issuance on the operator
        # login, so a client secret adds nothing — and claude.ai registers as
        # client_secret_post yet never presents the minted secret at /token,
        # which would fail the exchange with invalid_client. The mutation is
        # reflected in the DCR response, so the client knows it is public.
        client_info.token_endpoint_auth_method = "none"
        client_info.client_secret = None
        client_info.client_secret_expires_at = None

        redirect_uris = [str(u) for u in (client_info.redirect_uris or [])]
        if not redirect_uris:
            raise RegistrationError(
                error="invalid_redirect_uri",
                error_description="At least one redirect_uri is required",
            )
        for uri in redirect_uris:
            if not self._redirect_allowed(uri):
                logger.warning(
                    "Rejected client registration for disallowed redirect_uri %r "
                    "(client_name=%r)",
                    uri,
                    client_info.client_name,
                )
                raise RegistrationError(
                    error="invalid_redirect_uri",
                    error_description=(
                        "redirect_uri is not permitted by this server's allowlist"
                    ),
                )
        stored = self._store.put_client(
            client_info.client_id,
            client_info.model_dump(mode="json", exclude_none=True),
            protected=self._pending_client_ids(),
        )
        if not stored:
            logger.warning(
                "Rejected client registration: store is at capacity and every "
                "stored client holds live tokens (client_name=%r)",
                client_info.client_name,
            )
            raise RegistrationError(
                error="invalid_client_metadata",
                error_description="registration limit reached — try again later",
            )
        logger.info(
            "Registered OAuth client %s (name=%r, redirect_uris=%s)",
            client_info.client_id,
            client_info.client_name,
            redirect_uris,
        )

    # ------------------------------------------------------------------
    # Authorization (interactive operator login)
    # ------------------------------------------------------------------

    async def authorize(
        self, client: OAuthClientInformationFull, params: AuthorizationParams
    ) -> str:
        redirect_uri = str(params.redirect_uri)
        if not self._redirect_allowed(redirect_uri):
            logger.warning(
                "Refusing /authorize for disallowed redirect_uri %r (client=%s)",
                redirect_uri,
                client.client_id,
            )
            raise AuthorizeError(
                error="access_denied",
                error_description="redirect_uri is not permitted by this server",
            )
        if not self._resource_ok(params.resource):
            logger.warning(
                "Refusing /authorize for unknown resource %r (client=%s)",
                params.resource,
                client.client_id,
            )
            raise AuthorizeError(
                error="invalid_target",
                error_description="resource does not identify this MCP server",
            )
        if not params.code_challenge:  # pragma: no cover - SDK enforces presence
            raise AuthorizeError(
                error="invalid_request",
                error_description="PKCE code_challenge is required",
            )

        self._prune_pending()
        while len(self._pending) >= _MAX_PENDING:
            oldest = min(self._pending, key=lambda t: self._pending[t].created_at)
            self._pending.pop(oldest, None)
            logger.warning(
                "Pending-authorization table full — evicted the oldest parked "
                "transaction"
            )
        txn = secrets.token_urlsafe(_TXN_BYTES)
        self._pending[txn] = _PendingAuthorization(
            client_id=client.client_id,
            redirect_uri=redirect_uri,
            redirect_uri_provided_explicitly=params.redirect_uri_provided_explicitly,
            code_challenge=params.code_challenge,
            scopes=list(params.scopes or []),
            state=params.state,
            resource=params.resource,
            created_at=time.time(),
        )
        logger.info(
            "Authorization request parked for operator login (client=%s, txn=%s…)",
            client.client_id,
            txn[:8],
        )
        return construct_redirect_uri(self._config.login_url, txn=txn)

    def pending_details(self, txn: str) -> dict[str, str] | None:
        """What the operator is being asked to authorize.

        Returns the self-asserted client name *plus* the verifiable facts
        (client_id, redirect_uri) so the consent page never has to trust the
        name alone.
        """
        pending = self._pending.get(txn)
        if pending is None:
            return None
        record = self._store.get_client(pending.client_id) or {}
        return {
            "client_name": str(record.get("client_name") or pending.client_id),
            "client_id": pending.client_id,
            "redirect_uri": pending.redirect_uri,
        }

    def _pending_client_ids(self) -> set[str]:
        """Clients with a parked authorization — not eviction fodder."""
        self._prune_pending()
        return {p.client_id for p in self._pending.values()}

    def has_pending(self, txn: str) -> bool:
        self._prune_pending()
        return txn in self._pending

    def complete_login(self, txn: str, password: str, client_ip: str) -> str:
        """Validate the operator password and mint an authorization code.

        Returns the redirect URL (carrying ``code`` and ``state``) on success.
        Raises :class:`LoginLocked`, :class:`LoginExpired` or
        :class:`LoginRejected` otherwise. Never reveals *why* a password was
        wrong, and never reveals whether ``txn`` existed when locked out.
        """
        locked = self.limiter.locked_for(client_ip)
        if locked > 0:
            logger.warning("Login attempt from locked-out client %s", client_ip)
            raise LoginLocked(locked)

        self._prune_pending()
        pending = self._pending.get(txn)
        if pending is None:
            # Duplicate submission of a just-completed login (password-manager
            # interstitials resubmit the form): replay the identical redirect —
            # same single-use code, nothing new is minted — but only for a
            # requester that still presents the correct password.
            completed = self._completed.get(txn)
            if completed is not None:
                if hmac.compare_digest(
                    self._auth.operator_password.encode("utf-8"),
                    password.encode("utf-8"),
                ):
                    logger.info(
                        "Replaying completed login redirect for duplicate submit "
                        "from %s (txn=%s…)",
                        client_ip,
                        txn[:8],
                    )
                    return completed.redirect_url
                # A password was evaluated here, so this attempt has to cost the
                # same as any other wrong guess — otherwise the replay window is
                # a rate-limit-free oracle for a known-good txn. The raised error
                # stays LoginExpired: which precondition failed is not disclosed.
                self.limiter.record_failure(client_ip)
                logger.warning(
                    "Wrong password on a completed-login replay from %s "
                    "(%d failure(s) recorded)",
                    client_ip,
                    self.limiter.failures(client_ip),
                )
            # A valid pending transaction is a precondition for evaluating the
            # password at all: without one there is nothing to authorize, and
            # requiring it means a password guess costs an /authorize round-trip.
            logger.warning(
                "Login attempt from %s with unknown/expired transaction", client_ip
            )
            raise LoginExpired("This login link has expired. Start over from claude.ai.")

        expected = self._auth.operator_password.encode("utf-8")
        provided = password.encode("utf-8")
        ok = hmac.compare_digest(expected, provided)

        if not ok:
            self.limiter.record_failure(client_ip)
            logger.warning(
                "Failed operator login from %s (%d failure(s) recorded)",
                client_ip,
                self.limiter.failures(client_ip),
            )
            raise LoginRejected("Invalid credentials")

        self.limiter.record_success(client_ip)
        self._pending.pop(txn, None)

        code = secrets.token_urlsafe(_CODE_BYTES)
        self._codes[code] = AuthorizationCode(
            code=code,
            scopes=pending.scopes,
            expires_at=time.time() + self._auth.auth_code_ttl_seconds,
            client_id=pending.client_id,
            code_challenge=pending.code_challenge,
            redirect_uri=pending.redirect_uri,  # type: ignore[arg-type]
            redirect_uri_provided_explicitly=pending.redirect_uri_provided_explicitly,
            resource=pending.resource,
            subject=_SUBJECT,
        )
        logger.info(
            "Operator authenticated from %s — issued authorization code for client %s",
            client_ip,
            pending.client_id,
        )
        redirect_url = construct_redirect_uri(
            pending.redirect_uri, code=code, state=pending.state
        )
        self._completed[txn] = _CompletedLogin(
            redirect_url=redirect_url,
            expires_at=time.time() + _COMPLETED_LOGIN_TTL,
        )
        return redirect_url

    # ------------------------------------------------------------------
    # Token issuance
    # ------------------------------------------------------------------

    async def load_authorization_code(
        self, client: OAuthClientInformationFull, authorization_code: str
    ) -> AuthorizationCode | None:
        record = self._codes.get(authorization_code)
        if record is None or record.client_id != client.client_id:
            return None
        return record

    async def exchange_authorization_code(
        self,
        client: OAuthClientInformationFull,
        authorization_code: AuthorizationCode,
    ) -> OAuthToken:
        # Single use: pop wins the race, a replay finds nothing.
        record = self._codes.pop(authorization_code.code, None)
        if record is None:
            raise TokenError(
                error="invalid_grant",
                error_description="authorization code has already been used",
            )
        if record.expires_at < time.time():
            raise TokenError(
                error="invalid_grant",
                error_description="authorization code has expired",
            )
        return self._issue_tokens(
            client_id=client.client_id,
            scopes=list(record.scopes),
            resource=record.resource,
        )

    async def load_refresh_token(
        self, client: OAuthClientInformationFull, refresh_token: str
    ) -> RefreshToken | None:
        record = self._store.get_refresh_token(refresh_token)
        if record is None or record.get("client_id") != client.client_id:
            return None
        expires_at = record.get("expires_at")
        return RefreshToken(
            token=refresh_token,
            client_id=str(record["client_id"]),
            scopes=list(record.get("scopes") or []),
            # The model requires int; the store may hold a float timestamp.
            expires_at=int(expires_at) if expires_at is not None else None,
            subject=record.get("subject"),
        )

    async def exchange_refresh_token(
        self,
        client: OAuthClientInformationFull,
        refresh_token: RefreshToken,
        scopes: list[str],
    ) -> OAuthToken:
        # Rotation: the presented refresh token is consumed atomically. A replay
        # (or a race) finds nothing and gets the standard invalid_grant.
        record = self._store.pop_refresh_token(refresh_token.token)
        if record is None or record.get("client_id") != client.client_id:
            raise TokenError(
                error="invalid_grant",
                error_description="refresh token is not valid",
            )
        expires_at = record.get("expires_at")
        if expires_at is not None and expires_at < time.time():
            raise TokenError(
                error="invalid_grant", error_description="refresh token has expired"
            )
        # Revoke the access token this refresh token last minted.
        access_hash = record.get("access_hash")
        if access_hash:
            self._store.delete_access_token_hash(str(access_hash))

        granted = list(scopes or record.get("scopes") or [])
        return self._issue_tokens(
            client_id=client.client_id,
            scopes=granted,
            resource=record.get("resource"),
            # The absolute lifetime is anchored at first issuance, so a refresh
            # loop cannot extend a session indefinitely.
            refresh_expires_at=record.get("absolute_expires_at"),
            absolute_expires_at=record.get("absolute_expires_at"),
        )

    def _issue_tokens(
        self,
        *,
        client_id: str,
        scopes: list[str],
        resource: str | None,
        refresh_expires_at: float | None = None,
        absolute_expires_at: float | None = None,
    ) -> OAuthToken:
        now = time.time()
        access_token = secrets.token_urlsafe(_TOKEN_BYTES)
        refresh_token = secrets.token_urlsafe(_TOKEN_BYTES)
        access_expires = int(now + self._auth.access_token_ttl_seconds)
        if absolute_expires_at is None:
            absolute_expires_at = now + self._auth.refresh_token_ttl_seconds
        refresh_expires = int(refresh_expires_at or absolute_expires_at)

        # Bind the audience to *our* canonical resource URL, never to whatever
        # the client asked for.
        audience = self._config.canonical_resource_url

        access_hash = self._store.put_access_token(
            access_token,
            {
                "client_id": client_id,
                "scopes": scopes,
                "expires_at": access_expires,
                "resource": audience,
                "subject": _SUBJECT,
            },
        )
        self._store.put_refresh_token(
            refresh_token,
            {
                "client_id": client_id,
                "scopes": scopes,
                "expires_at": refresh_expires,
                "absolute_expires_at": absolute_expires_at,
                "resource": audience,
                "subject": _SUBJECT,
                "access_hash": access_hash,
            },
        )
        logger.info(
            "Issued access token for client %s (scopes=%s, ttl=%ds)",
            client_id,
            " ".join(scopes),
            self._auth.access_token_ttl_seconds,
        )
        return OAuthToken(
            access_token=access_token,
            token_type="Bearer",
            expires_in=self._auth.access_token_ttl_seconds,
            scope=" ".join(scopes) if scopes else None,
            refresh_token=refresh_token,
        )

    # ------------------------------------------------------------------
    # Resource server
    # ------------------------------------------------------------------

    async def load_access_token(self, token: str) -> AccessToken | None:
        record = self._store.get_access_token(token)
        if record is None:
            return None
        expires_at = record.get("expires_at")
        if expires_at is not None and expires_at < time.time():
            self._store.delete_access_token_hash(hash_token(token))
            return None
        # Audience check (RFC 8707): a token minted for a different resource
        # must not be accepted here.
        if record.get("resource") not in (None, self._config.canonical_resource_url):
            logger.warning("Rejected access token with foreign audience")
            return None
        return AccessToken(
            token=token,
            client_id=str(record["client_id"]),
            scopes=list(record.get("scopes") or []),
            expires_at=int(expires_at) if expires_at is not None else None,
            resource=record.get("resource"),
            subject=record.get("subject"),
        )

    async def revoke_token(self, token: AccessToken | RefreshToken) -> None:
        if isinstance(token, RefreshToken):
            record = self._store.pop_refresh_token(token.token)
            if record and record.get("access_hash"):
                self._store.delete_access_token_hash(str(record["access_hash"]))
            return
        digest = hash_token(token.token)
        self._store.delete_access_token_hash(digest)
        # Drop any refresh token pointing at this access token.
        self._store.delete_refresh_tokens_for_access(digest)
