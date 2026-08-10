"""MCP server assembly: tools, the operator login page, and the ASGI app."""

# No `from __future__ import annotations` here: the MCP SDK re-evaluates
# stringified tool annotations against module globals, which breaks the
# closure-interpolated Field descriptions in the per-agent tools. Annotations
# in this module must evaluate eagerly.

import asyncio
import hmac
import html
import logging
import re
from typing import Annotated, Any
from urllib.parse import parse_qs, urlsplit

from mcp.server.auth.settings import AuthSettings, ClientRegistrationOptions
from mcp.server.mcpserver import MCPServer
from mcp.server.transport_security import TransportSecuritySettings
from pydantic import Field
from starlette.applications import Starlette
from starlette.datastructures import MutableHeaders
from starlette.requests import Request
from starlette.responses import HTMLResponse, JSONResponse, RedirectResponse, Response

from mcp_server.auth import (
    LoginExpired,
    LoginLocked,
    LoginRejected,
    TriOnyxAuthProvider,
)
from mcp_server.config import AgentEntry, ConfigError, McpConfig
from mcp_server.gateway_bridge import (
    GatewayBridge,
    GatewayError,
    TurnStatus,
    make_room_id,
)

logger = logging.getLogger(__name__)

_TOOL_NAME_SAFE = re.compile(r"[^A-Za-z0-9_-]+")

#: Returned instead of the reply when a turn outlives the soft deadline. Written
#: for the calling model: it must keep polling the same conversation and must
#: not treat this text as the agent's answer.
_PENDING_NOTICE = """\
[TriOnyx: still working — this is NOT the reply] (check #{checks})

The '{agent}' agent is still on this turn: {progress}. The turn keeps running
on the server; nothing was lost.

Call `{tool}` again with {conv_hint} to collect the reply — each call waits up
to {soft:.0f}s, so repeat until the reply (or, if the agent gives up, an error)
arrives; the turn is abandoned after {hard:.0f}s total. While it runs, your
`message` is only a poll and is NOT delivered to the agent — hold new
instructions until the reply arrives, and don't switch `conversation_id` (that
starts a separate session). Once you have the reply, stop calling: the next
call starts a new turn."""


def _progress_phrase(status: TurnStatus) -> str:
    parts = [f"{status.elapsed:.0f}s elapsed", status.activity]
    if status.partial_chars:
        parts.append(
            f"{status.partial_chars} characters of output produced so far"
        )
    return ", ".join(parts)


def _conv_hint(conversation_id: str | None) -> str:
    if conversation_id:
        return f'conversation_id="{conversation_id}"'
    return "no conversation_id at all, exactly as now"


def _still_working_text(
    *,
    agent_name: str,
    tool_name: str,
    conversation_id: str | None,
    status: TurnStatus,
    soft: float,
    hard: float,
) -> str:
    return _PENDING_NOTICE.format(
        checks=status.checks,
        agent=agent_name,
        progress=_progress_phrase(status),
        tool=tool_name,
        conv_hint=_conv_hint(conversation_id),
        soft=soft,
        hard=hard,
    )


def agent_tool_name(agent_name: str) -> str:
    """Map an agent name onto the MCP tool-name charset.

    Tool names are the agent names — the tool list IS the agent directory —
    so anything outside ``[A-Za-z0-9_-]`` becomes an underscore.
    """
    cleaned = _TOOL_NAME_SAFE.sub("_", agent_name).strip("_")
    if not cleaned:
        raise ConfigError(
            f"agent name {agent_name!r} cannot be mapped to an MCP tool name"
        )
    return cleaned


#: Binds a parked /authorize transaction to the browser that initiated it, so a
#: phished operator opening someone else's login link is refused (fix for the
#: pre-staged-transaction attack — see docs/mcp-server.md).
TXN_COOKIE = "mcp_txn"

#: More than enough for a txn id + password form.
_MAX_LOGIN_BODY_BYTES = 4096

_SECURITY_HEADERS = {
    "Cache-Control": "no-store",
    "Pragma": "no-cache",
    "X-Frame-Options": "DENY",
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "no-referrer",
    "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'",
}


def client_ip(request: Request) -> str:
    """Best-effort client address.

    Behind the Cloudflare tunnel the real address arrives in ``CF-Connecting-IP``
    (set by Cloudflare's edge) or ``X-Forwarded-For`` (appended by cloudflared).
    Both are only as trustworthy as the tunnel — which is why the global backoff
    exists alongside the per-IP lockout.
    """
    header = request.headers.get("cf-connecting-ip")
    if header:
        return header.strip()
    forwarded = request.headers.get("x-forwarded-for")
    if forwarded:
        return forwarded.split(",")[0].strip()
    return request.client.host if request.client else "unknown"


def _login_page(
    *,
    txn: str,
    details: dict[str, str],
    form_action_origins: str = "",
    error: str | None = None,
    status_code: int = 200,
) -> HTMLResponse:
    # Chrome enforces CSP form-action on the *redirect target* of a form
    # submission, so the allowlisted callback origins must be listed or the
    # browser silently refuses to follow the 302 back to the client.
    headers = dict(_SECURITY_HEADERS)
    headers["Content-Security-Policy"] = (
        "default-src 'none'; style-src 'unsafe-inline'; "
        f"form-action 'self' {form_action_origins}".rstrip()
    )
    safe_txn = html.escape(txn, quote=True)
    safe_client = html.escape(details.get("client_name") or "an MCP client", quote=True)
    # The client name is self-asserted at registration; the id and redirect
    # target are what the server actually enforces, so show those too.
    safe_client_id = html.escape(details.get("client_id", "")[:12], quote=True)
    safe_redirect = html.escape(details.get("redirect_uri", ""), quote=True)
    error_block = (
        f'<p class="error" role="alert">{html.escape(error)}</p>' if error else ""
    )
    body = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>TriOnyx — operator sign-in</title>
<style>
  :root {{ color-scheme: dark; }}
  body {{ font-family: system-ui, sans-serif; background: #12141a; color: #e6e8ee;
         display: flex; min-height: 100vh; margin: 0; align-items: center;
         justify-content: center; }}
  form {{ background: #1b1e26; padding: 2rem; border-radius: 12px; width: min(22rem, 90vw);
          box-shadow: 0 12px 40px rgba(0,0,0,.45); }}
  h1 {{ font-size: 1.1rem; margin: 0 0 .35rem; }}
  p {{ font-size: .85rem; color: #9aa1b1; margin: 0 0 1.25rem; }}
  .error {{ color: #ff9d9d; }}
  .meta {{ font-size: .75rem; word-break: break-all; }}
  code {{ color: #c7cddb; }}
  label {{ display: block; font-size: .8rem; margin-bottom: .35rem; color: #9aa1b1; }}
  input {{ width: 100%; box-sizing: border-box; padding: .6rem .7rem; border-radius: 8px;
           border: 1px solid #2c313d; background: #0e1015; color: #e6e8ee; font-size: 1rem; }}
  button {{ margin-top: 1rem; width: 100%; padding: .65rem; border: 0; border-radius: 8px;
            background: #3d7dff; color: #fff; font-size: .95rem; cursor: pointer; }}
</style>
</head>
<body>
<form method="post" action="/login" autocomplete="off">
  <h1>Authorize {safe_client}</h1>
  <p>Only the TriOnyx operator can approve this connection.</p>
  <p class="meta">Client <code>{safe_client_id}…</code> will receive the authorization
  at <code>{safe_redirect}</code></p>
  {error_block}
  <input type="hidden" name="txn" value="{safe_txn}">
  <label for="password">Operator password</label>
  <input id="password" name="password" type="password" autocomplete="current-password"
         autofocus required>
  <button type="submit">Authorize</button>
</form>
</body>
</html>
"""
    return HTMLResponse(body, status_code=status_code, headers=headers)


def _message_page(title: str, detail: str, status_code: int) -> HTMLResponse:
    body = f"""<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>TriOnyx</title>
<style>
  :root {{ color-scheme: dark; }}
  body {{ font-family: system-ui, sans-serif; background: #12141a; color: #e6e8ee;
         display: flex; min-height: 100vh; margin: 0; align-items: center;
         justify-content: center; text-align: center; }}
  div {{ max-width: 26rem; padding: 2rem; }}
  p {{ color: #9aa1b1; font-size: .9rem; }}
</style></head>
<body><div><h1>{html.escape(title)}</h1><p>{html.escape(detail)}</p></div></body></html>
"""
    return HTMLResponse(body, status_code=status_code, headers=_SECURITY_HEADERS)


def build_server(config: McpConfig, provider: TriOnyxAuthProvider, bridge: GatewayBridge) -> MCPServer:
    """Wire tools, auth and the login flow onto an :class:`MCPServer`."""
    agent_list = "\n".join(
        f"- {entry.name}: {entry.description or 'no description'}"
        for entry in config.agents
    )
    instructions = config.instructions or (
        "This server is a front door to a set of TriOnyx agents. Each tool is "
        "one agent: call it with a message and it returns that agent's reply. "
        "Agents are stateful — pass a stable `conversation_id` to keep talking "
        "to the same agent session across turns. Tool calls are long-running: "
        "if a call returns a `[TriOnyx: still working]` notice, call the same "
        "tool again with the same `conversation_id` until the real reply "
        "arrives, and do not send new instructions in the meantime."
        "\n\nAvailable agents:\n" + agent_list
    )

    mcp = MCPServer(
        name=config.server_name,
        title=config.server_title,
        instructions=instructions,
        website_url=config.public_url,
        auth_server_provider=provider,
        auth=AuthSettings(
            issuer_url=config.issuer_url,  # type: ignore[arg-type]
            resource_server_url=config.resource_url,  # type: ignore[arg-type]
            client_registration_options=ClientRegistrationOptions(
                enabled=True,
                valid_scopes=[config.auth.scope],
                default_scopes=[config.auth.scope],
            ),
            required_scopes=[config.auth.scope],
        ),
    )

    # ------------------------------------------------------------------
    # Tools — one per allowlisted agent; the tool list is the agent directory
    # ------------------------------------------------------------------

    async def ask(
        agent_name: str,
        tool_name: str,
        message: str,
        conversation_id: str | None,
    ) -> str:
        stripped = message.strip()
        if not stripped:
            raise ValueError("message must not be empty")
        if stripped.startswith("/") and ":" not in stripped.split(None, 1)[0]:
            # The gateway parses leading-slash content as an operator system
            # command (e.g. `/restart <any agent>`) *before* routing, which
            # would bypass this server's agent allowlist. Skill invocations
            # (`/library:action`) pass through to the agent and stay allowed.
            # Rejected here, before the bridge, so a rejected message never
            # consumes a parked result.
            raise ValueError(
                "Messages must not start with '/': gateway system commands are "
                "not available through this connector."
            )

        room_id = make_room_id(config.session.room_prefix, conversation_id)
        logger.info(
            "tool agent=%s room=%s message=%.120s%s",
            agent_name,
            room_id,
            message,
            "…" if len(message) > 120 else "",
        )
        try:
            status = await bridge.ask(
                agent_name,
                message,
                room_id,
                wait_timeout=config.session.soft_timeout_seconds,
                hard_timeout=config.session.timeout_seconds,
            )
        except GatewayError as exc:
            raise ValueError(str(exc)) from None
        if status.pending:
            # A successful result, not an error: the calling model must read
            # the polling contract rather than see a failed tool call.
            return _still_working_text(
                agent_name=agent_name,
                tool_name=tool_name,
                conversation_id=conversation_id,
                status=status,
                soft=config.session.soft_timeout_seconds,
                hard=config.session.timeout_seconds,
            )
        if not status.reply:
            return (
                f"Agent '{agent_name}' finished without producing any text output."
            )
        return status.reply

    def register_agent_tool(entry: AgentEntry) -> None:
        purpose = (entry.description or f"The TriOnyx agent '{entry.name}'").rstrip(".")
        tool_name = agent_tool_name(entry.name)

        @mcp.tool(
            name=tool_name,
            title=f"Ask the {entry.name} agent",
            description=(
                f"{purpose}. Sends a message to the '{entry.name}' agent and "
                "returns its reply. The agent is stateful: reuse the same "
                "`conversation_id` to continue an existing conversation, or "
                "pick a new one to start fresh. Agent turns can take minutes — "
                "the first message to an agent boots its container. If the "
                "reply is not ready in time, this tool returns a "
                "`[TriOnyx: still working]` notice instead of the reply (a "
                "normal result, not an error) and the turn keeps running on "
                "the server: call this tool again with the same "
                "`conversation_id` to keep waiting, and repeat until you get "
                "the reply or an error. While a turn is running your `message` "
                "is only a poll and is NOT delivered to the agent, so never "
                "send new instructions until the previous turn's reply has "
                "arrived. Stop calling once you have the reply — a call on an "
                "idle conversation starts a new agent turn."
            ),
        )
        async def agent_tool(
            message: Annotated[
                str,
                Field(description=f"The message to send to the '{entry.name}' agent"),
            ],
            conversation_id: Annotated[
                str | None,
                Field(
                    description=(
                        "Stable id that keeps this conversation on one agent "
                        "session. Omit for the default conversation."
                    ),
                ),
            ] = None,
        ) -> str:
            return await ask(entry.name, tool_name, message, conversation_id)

    tool_names: set[str] = set()
    for entry in config.agents:
        tool_name = agent_tool_name(entry.name)
        if tool_name in tool_names:
            raise ConfigError(
                f"agent {entry.name!r} maps to tool name {tool_name!r}, which "
                "another allowlisted agent already uses — rename one of them"
            )
        tool_names.add(tool_name)
        register_agent_tool(entry)

    # ------------------------------------------------------------------
    # Operator login (custom, unauthenticated routes)
    # ------------------------------------------------------------------

    #: Bounds concurrent password evaluations so the global backoff delay is an
    #: actual throughput limit rather than per-request latency.
    login_guard = asyncio.Semaphore(4)

    # The login form's 302 lands on an allowlisted redirect URI; those origins
    # must be in CSP form-action or Chrome blocks the cross-origin redirect.
    redirect_origins = " ".join(
        sorted(
            {
                f"{urlsplit(u).scheme}://{urlsplit(u).netloc}"
                for u in config.auth.redirect_uris
            }
        )
    )

    def _expired_page() -> HTMLResponse:
        # One indistinguishable answer for unknown txn, expired txn and missing
        # cookie — no oracle for which precondition failed.
        return _message_page(
            "Link expired",
            "This authorization link is no longer valid. Start the connection "
            "again from claude.ai, in the same browser you use for claude.ai.",
            400,
        )

    def _txn_cookie_ok(request: Request, txn: str) -> bool:
        cookie = request.cookies.get(TXN_COOKIE, "")
        return bool(txn) and bool(cookie) and hmac.compare_digest(cookie, txn)

    @mcp.custom_route("/login", methods=["GET"])
    async def login_form(request: Request) -> Response:
        txn = request.query_params.get("txn", "")
        if not txn or not provider.has_pending(txn) or not _txn_cookie_ok(request, txn):
            return _expired_page()
        details = provider.pending_details(txn)
        assert details is not None  # has_pending was just checked
        return _login_page(
            txn=txn, details=details, form_action_origins=redirect_origins
        )

    @mcp.custom_route("/login", methods=["POST"])
    async def login_submit(request: Request) -> Response:
        length = request.headers.get("content-length")
        if length is None or not length.isdigit() or int(length) > _MAX_LOGIN_BODY_BYTES:
            return _message_page("Request too large", "Malformed login request.", 413)
        form = await request.form()
        txn = str(form.get("txn") or "")
        password = str(form.get("password") or "")
        ip = client_ip(request)
        logger.info(
            "POST /login from %s txn=%s… ua=%r referer=%r",
            ip,
            txn[:8],
            request.headers.get("user-agent", "")[:60],
            request.headers.get("referer", ""),
        )

        # The txn cookie was set by *this* browser's /authorize redirect; a
        # transaction pre-staged from someone else's browser dies here.
        if not _txn_cookie_ok(request, txn):
            logger.warning("POST /login from %s without a matching txn cookie", ip)
            return _expired_page()

        async with login_guard:
            delay = provider.limiter.global_delay()
            if delay:
                logger.warning("Global login backoff active — delaying %.1fs", delay)
                await asyncio.sleep(delay)

            try:
                redirect_url = provider.complete_login(txn, password, ip)
            except LoginLocked as exc:
                return _message_page(
                    "Too many attempts",
                    f"Locked out. Try again in about {int(exc.retry_after // 60) + 1} minute(s).",
                    429,
                )
            except LoginExpired:
                return _expired_page()
            except LoginRejected:
                details = provider.pending_details(txn)
                if details is None:
                    return _expired_page()
                return _login_page(
                    txn=txn,
                    details=details,
                    form_action_origins=redirect_origins,
                    error="Invalid credentials.",
                    status_code=401,
                )
        logger.info("Redirecting operator to the client callback (txn=%s…)", txn[:8])
        return RedirectResponse(
            redirect_url, status_code=302, headers={"Cache-Control": "no-store"}
        )

    # ------------------------------------------------------------------
    # Discovery alias + health
    # ------------------------------------------------------------------

    @mcp.custom_route("/.well-known/oauth-protected-resource", methods=["GET"])
    async def protected_resource_root(request: Request) -> Response:
        """RFC 9728 metadata at the path-less well-known location.

        The SDK serves the path-inserted form (`.../oauth-protected-resource/mcp`)
        that the WWW-Authenticate header points at; clients that probe the root
        get the same document here.
        """
        return JSONResponse(
            {
                "resource": config.resource_url,
                "authorization_servers": [config.issuer_url],
                "scopes_supported": [config.auth.scope],
                "bearer_methods_supported": ["header"],
            },
            headers={"Cache-Control": "no-store"},
        )

    @mcp.custom_route("/healthz", methods=["GET"])
    async def healthz(request: Request) -> Response:
        return JSONResponse(
            {"status": "ok", "gateway_connected": bridge.connected},
            headers={"Cache-Control": "no-store"},
        )

    return mcp


class TxnCookieMiddleware:
    """Sets the txn-binding cookie on the /authorize -> /login redirect.

    The SDK owns the /authorize route and only lets the provider return a
    redirect *URL*, so the Set-Cookie header is attached here instead: whenever
    /authorize responds with a Location containing a ``txn`` parameter, that
    txn is mirrored into a cookie scoped to /login. POST /login refuses any
    transaction the presenting browser does not hold the cookie for.
    """

    def __init__(self, app: Any, *, secure: bool, max_age: int) -> None:
        self.app = app
        self.secure = secure
        self.max_age = max_age

    async def __call__(self, scope: Any, receive: Any, send: Any) -> None:
        if scope["type"] != "http" or scope["path"].rstrip("/") != "/authorize":
            await self.app(scope, receive, send)
            return

        async def send_with_cookie(message: Any) -> None:
            if message["type"] == "http.response.start":
                headers = MutableHeaders(scope=message)
                location = headers.get("location") or ""
                txn = (parse_qs(urlsplit(location).query).get("txn") or [""])[0]
                if txn:
                    cookie = (
                        f"{TXN_COOKIE}={txn}; HttpOnly; SameSite=Lax; "
                        f"Path=/login; Max-Age={self.max_age}"
                    )
                    if self.secure:
                        cookie += "; Secure"
                    headers.append("set-cookie", cookie)
            await send(message)

        await self.app(scope, receive, send_with_cookie)


def build_app(config: McpConfig, mcp: MCPServer) -> Starlette:
    """Build the Starlette ASGI app for the streamable-HTTP transport."""
    public_host = config.public_url.split("://", 1)[-1].rstrip("/")
    transport_security = TransportSecuritySettings(
        enable_dns_rebinding_protection=config.dns_rebinding_protection,
        allowed_hosts=[
            public_host,
            f"{public_host}:*",
            f"{config.bind_host}:{config.bind_port}",
            "127.0.0.1:*",
            "localhost:*",
            "mcp:*",
            *config.extra_allowed_hosts,
        ],
        # claude.ai calls this endpoint server-side (no Origin header); only the
        # public origin and claude.ai are accepted when one is present.
        allowed_origins=[config.public_url, "https://claude.ai"],
    )
    app = mcp.streamable_http_app(
        streamable_http_path=config.mcp_path,
        transport_security=transport_security,
        # Anything other than a loopback host disables the SDK's automatic
        # localhost rebinding defaults — we supply our own above.
        host=config.bind_host,
    )
    app.add_middleware(
        TxnCookieMiddleware,
        secure=config.public_url.startswith("https://"),
        max_age=config.auth.pending_authorization_ttl_seconds,
    )
    return app


def build_all(config: McpConfig) -> tuple[GatewayBridge, MCPServer, Starlette, Any]:
    """Convenience wiring used by ``main`` and the tests."""
    from mcp_server.storage import OAuthStore

    store = OAuthStore(
        config.auth.store_path,
        max_clients=config.auth.max_registered_clients,
        client_ttl_seconds=config.auth.client_ttl_seconds,
    )
    provider = TriOnyxAuthProvider(config, store)
    bridge = GatewayBridge(
        gateway_url=config.gateway_url,
        gateway_token=config.gateway_token,
        connector_id=config.connector_id,
        sender=config.session.sender,
        trust_level=config.session.trust_level,
        default_timeout=config.session.timeout_seconds,
        soft_timeout=config.session.soft_timeout_seconds,
        parked_ttl=config.session.parked_result_ttl_seconds,
    )
    mcp = build_server(config, provider, bridge)
    app = build_app(config, mcp)
    return bridge, mcp, app, provider
