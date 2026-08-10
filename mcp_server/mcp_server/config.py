"""Configuration for the MCP server.

YAML with ``${VAR}`` environment interpolation, exactly like the connector's
config — the interpolation helper is imported from ``connector.config`` rather
than reimplemented so the two cannot drift.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit, urlunsplit

import yaml

# Single source of truth for ${VAR} interpolation (see connector/connector/config.py).
from connector.config import _interpolate as interpolate_env

DEFAULT_CONFIG_PATH_ENV = "TRI_ONYX_MCP_CONFIG"

#: The only redirect URI claude.ai ever uses for custom connectors.
CLAUDE_AI_REDIRECT_URI = "https://claude.ai/api/mcp/auth_callback"


class ConfigError(ValueError):
    """Raised when the configuration is missing or internally inconsistent."""


def canonical_resource(url: str) -> str:
    """Canonicalize a URL for RFC 8707 resource-indicator comparison.

    Lowercases scheme and host, drops the default port, drops query/fragment,
    and strips a trailing slash from the path.
    """
    parts = urlsplit(url.strip())
    scheme = parts.scheme.lower()
    host = (parts.hostname or "").lower()
    port = parts.port
    if port is not None and not (
        (scheme == "http" and port == 80) or (scheme == "https" and port == 443)
    ):
        netloc = f"{host}:{port}"
    else:
        netloc = host
    path = parts.path.rstrip("/")
    return urlunsplit((scheme, netloc, path, "", ""))


@dataclass(slots=True, frozen=True)
class AgentEntry:
    """One agent the connector is allowed to talk to."""

    name: str
    description: str = ""


@dataclass(slots=True, frozen=True)
class AuthConfig:
    """OAuth 2.1 authorization-server policy."""

    operator_password: str = ""
    redirect_uris: tuple[str, ...] = (CLAUDE_AI_REDIRECT_URI,)
    scope: str = "trionyx:chat"
    auth_code_ttl_seconds: int = 300
    access_token_ttl_seconds: int = 3600
    refresh_token_ttl_seconds: int = 30 * 24 * 3600
    pending_authorization_ttl_seconds: int = 600
    max_login_failures: int = 5
    lockout_seconds: int = 900
    global_failure_threshold: int = 20
    global_backoff_max_seconds: float = 30.0
    max_registered_clients: int = 10
    client_ttl_seconds: int = 30 * 24 * 3600
    data_dir: str = "/data"

    @property
    def store_path(self) -> Path:
        return Path(self.data_dir) / "oauth-store.json"


@dataclass(slots=True, frozen=True)
class SessionConfig:
    """How agent conversations are mapped onto gateway sessions."""

    sender: str = "mcp-operator"
    trust_level: str = "verified"
    room_prefix: str = "mcp"
    #: Hard ceiling for one background agent turn.
    timeout_seconds: float = 300.0
    #: How long one tool call waits before returning a "still working" notice.
    #: Must stay under the MCP client's own tool-call timeout (undocumented for
    #: claude.ai; 50 s leaves headroom under a presumed ~60 s).
    soft_timeout_seconds: float = 50.0
    #: How long a finished, uncollected reply is held for the next poll.
    parked_result_ttl_seconds: float = 600.0


@dataclass(slots=True, frozen=True)
class McpConfig:
    """Top-level MCP server configuration."""

    public_url: str
    bind_host: str = "0.0.0.0"
    bind_port: int = 8765
    mcp_path: str = "/mcp"
    server_name: str = "trionyx"
    server_title: str = "TriOnyx"
    instructions: str = ""
    dns_rebinding_protection: bool = True
    extra_allowed_hosts: tuple[str, ...] = ()
    gateway_url: str = "ws://gateway:4000/connectors/ws"
    gateway_token: str = ""
    connector_id: str = "mcp"
    agents: tuple[AgentEntry, ...] = ()
    auth: AuthConfig = field(default_factory=AuthConfig)
    session: SessionConfig = field(default_factory=SessionConfig)
    config_path: str = ""

    # -- derived ---------------------------------------------------------

    @property
    def issuer_url(self) -> str:
        """OAuth issuer: the public origin, no trailing slash."""
        return self.public_url.rstrip("/")

    @property
    def resource_url(self) -> str:
        """RFC 9728 resource identifier: the public MCP endpoint."""
        return self.issuer_url + self.mcp_path

    @property
    def canonical_resource_url(self) -> str:
        return canonical_resource(self.resource_url)

    @property
    def canonical_issuer_url(self) -> str:
        return canonical_resource(self.issuer_url)

    @property
    def login_url(self) -> str:
        return self.issuer_url + "/login"

    def agent(self, name: str) -> AgentEntry | None:
        for entry in self.agents:
            if entry.name == name:
                return entry
        return None


def _require(raw: Any, key: str, path: str) -> Any:
    value = raw.get(key)
    if value in (None, ""):
        raise ConfigError(f"{path}: missing required key '{key}'")
    return value


def _unresolved(value: str) -> bool:
    """True if a ``${VAR}`` placeholder survived interpolation (env var unset)."""
    return "${" in value


def parse_config(raw: dict[str, Any], *, path: str = "<memory>") -> McpConfig:
    """Build an :class:`McpConfig` from an already-interpolated mapping."""
    if not isinstance(raw, dict):
        raise ConfigError(f"{path}: top level must be a mapping")

    server_raw = raw.get("server") or {}
    gateway_raw = raw.get("gateway") or {}
    auth_raw = raw.get("auth") or {}
    session_raw = raw.get("session") or {}

    public_url = str(_require(server_raw, "public_url", path)).rstrip("/")
    if _unresolved(public_url):
        raise ConfigError(
            f"{path}: server.public_url still contains an unresolved ${{VAR}} "
            "placeholder — is MCP_PUBLIC_URL set?"
        )
    if not public_url.startswith(("http://", "https://")):
        raise ConfigError(f"{path}: server.public_url must be an absolute http(s) URL")

    mcp_path = str(server_raw.get("mcp_path", "/mcp"))
    if not mcp_path.startswith("/"):
        raise ConfigError(f"{path}: server.mcp_path must start with '/'")

    gateway_token = str(gateway_raw.get("token", ""))
    if not gateway_token or _unresolved(gateway_token):
        raise ConfigError(
            f"{path}: gateway.token is empty or unresolved — is "
            "TRI_ONYX_CONNECTOR_TOKEN set?"
        )

    operator_password = str(auth_raw.get("operator_password", ""))
    if not operator_password or _unresolved(operator_password):
        raise ConfigError(
            f"{path}: auth.operator_password is empty or unresolved — is "
            "MCP_OPERATOR_PASSWORD set?"
        )
    if len(operator_password) < 16:
        raise ConfigError(
            f"{path}: auth.operator_password must be at least 16 characters; "
            "generate one with `openssl rand -base64 32`"
        )

    redirect_uris = tuple(
        str(u).strip() for u in auth_raw.get("redirect_uris", [CLAUDE_AI_REDIRECT_URI])
    )
    if not redirect_uris:
        raise ConfigError(f"{path}: auth.redirect_uris must not be empty")
    for uri in redirect_uris:
        if not uri.startswith("https://") and not uri.startswith("http://localhost"):
            raise ConfigError(
                f"{path}: auth.redirect_uris entry {uri!r} must be https "
                "(http is only allowed for http://localhost during testing)"
            )

    agents: list[AgentEntry] = []
    for entry in raw.get("agents") or []:
        if isinstance(entry, str):
            agents.append(AgentEntry(name=entry))
        elif isinstance(entry, dict):
            name = str(_require(entry, "name", f"{path}: agents[]"))
            agents.append(
                AgentEntry(name=name, description=str(entry.get("description", "")))
            )
        else:
            raise ConfigError(f"{path}: agents[] entries must be strings or mappings")
    if not agents:
        raise ConfigError(f"{path}: at least one agent must be allowlisted")

    seen: set[str] = set()
    for entry in agents:
        if entry.name in seen:
            raise ConfigError(f"{path}: duplicate agent {entry.name!r}")
        seen.add(entry.name)

    auth = AuthConfig(
        operator_password=operator_password,
        redirect_uris=redirect_uris,
        scope=str(auth_raw.get("scope", "trionyx:chat")),
        auth_code_ttl_seconds=int(auth_raw.get("auth_code_ttl_seconds", 300)),
        access_token_ttl_seconds=int(auth_raw.get("access_token_ttl_seconds", 3600)),
        refresh_token_ttl_seconds=int(
            auth_raw.get("refresh_token_ttl_seconds", 30 * 24 * 3600)
        ),
        pending_authorization_ttl_seconds=int(
            auth_raw.get("pending_authorization_ttl_seconds", 600)
        ),
        max_login_failures=int(auth_raw.get("max_login_failures", 5)),
        lockout_seconds=int(auth_raw.get("lockout_seconds", 900)),
        global_failure_threshold=int(auth_raw.get("global_failure_threshold", 20)),
        global_backoff_max_seconds=float(
            auth_raw.get("global_backoff_max_seconds", 30.0)
        ),
        max_registered_clients=int(auth_raw.get("max_registered_clients", 10)),
        client_ttl_seconds=int(auth_raw.get("client_ttl_seconds", 30 * 24 * 3600)),
        data_dir=str(auth_raw.get("data_dir", "/data")),
    )
    if auth.auth_code_ttl_seconds > 600:
        raise ConfigError(f"{path}: auth.auth_code_ttl_seconds must be <= 600")

    session = SessionConfig(
        sender=str(session_raw.get("sender", "mcp-operator")),
        trust_level=str(session_raw.get("trust_level", "verified")),
        room_prefix=str(session_raw.get("room_prefix", "mcp")),
        timeout_seconds=float(session_raw.get("timeout_seconds", 300.0)),
        soft_timeout_seconds=float(session_raw.get("soft_timeout_seconds", 50.0)),
        parked_result_ttl_seconds=float(
            session_raw.get("parked_result_ttl_seconds", 600.0)
        ),
    )
    if session.soft_timeout_seconds <= 0:
        raise ConfigError(f"{path}: session.soft_timeout_seconds must be > 0")
    if session.soft_timeout_seconds > session.timeout_seconds:
        raise ConfigError(
            f"{path}: session.soft_timeout_seconds "
            f"({session.soft_timeout_seconds:.0f}s) must not exceed "
            f"session.timeout_seconds ({session.timeout_seconds:.0f}s) — a tool "
            "call has to return before the background turn is abandoned"
        )
    if session.parked_result_ttl_seconds < session.soft_timeout_seconds:
        raise ConfigError(
            f"{path}: session.parked_result_ttl_seconds must be >= "
            "session.soft_timeout_seconds, or a finished reply can expire "
            "before the polling caller comes back for it"
        )

    return McpConfig(
        public_url=public_url,
        bind_host=str(server_raw.get("bind_host", "0.0.0.0")),
        bind_port=int(server_raw.get("bind_port", 8765)),
        mcp_path=mcp_path,
        server_name=str(server_raw.get("name", "trionyx")),
        server_title=str(server_raw.get("title", "TriOnyx")),
        instructions=str(server_raw.get("instructions", "")),
        dns_rebinding_protection=bool(
            server_raw.get("dns_rebinding_protection", True)
        ),
        extra_allowed_hosts=tuple(
            str(h) for h in (server_raw.get("allowed_hosts") or [])
        ),
        gateway_url=str(gateway_raw.get("url", "ws://gateway:4000/connectors/ws")),
        gateway_token=gateway_token,
        connector_id=str(gateway_raw.get("connector_id", "mcp")),
        agents=tuple(agents),
        auth=auth,
        session=session,
        config_path=path,
    )


def load_config(path: str | Path | None = None) -> McpConfig:
    """Load the MCP server configuration from a YAML file."""
    if path is None:
        path = os.environ.get(DEFAULT_CONFIG_PATH_ENV, "config.yaml")
    file_path = Path(path)
    if not file_path.is_file():
        raise ConfigError(f"config file not found: {file_path}")
    raw = yaml.safe_load(file_path.read_text())
    raw = interpolate_env(raw)
    return parse_config(raw or {}, path=str(file_path))
