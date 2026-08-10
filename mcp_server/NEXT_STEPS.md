# Public MCP Server — Status & Remaining Steps

> Status as of 2026-08-10. All blocking security fixes from the 2026-08-09
> review are **implemented and verified**: 120 mcp_server tests + 47 connector
> tests pass in Docker, and a local smoke test of the full OAuth flow
> (discovery → DCR → authorize → cookie-bound login → code → redirect) passed.
> What remains before first exposure is operator-only setup, below.
> Architecture and setup docs: `docs/mcp-server.md`.

## Completed (2026-08-10)

1. ✅ **[HIGH] Login transaction bound to the initiating browser** — `mcp_txn`
   cookie set on the `/authorize` redirect (`TxnCookieMiddleware`); `/login`
   (GET and POST) refuses a txn without the matching cookie. Consent page shows
   the client id prefix + exact redirect URI, not just the self-asserted name.
2. ✅ **[HIGH] Gateway system commands blocked** — agent tools reject messages
   whose first token starts with `/` unless it is `/library:action` skill
   syntax, so `/restart <off-allowlist agent>` cannot be smuggled through.
3. ✅ **[MEDIUM] DCR store bounded** — `max_registered_clients` (default 10;
   oldest tokenless registration evicted, a client with live tokens is never
   evicted) + `client_ttl_seconds` prune (default 30 d).
4. ✅ **[MEDIUM] Login rate limit is real** — the password is only evaluated
   against a live pending txn, and the backoff section runs under a
   `Semaphore(4)` so the delay bounds throughput.
5. ✅ **[MEDIUM] Rate-limiter IP table swept** — stale sub-threshold entries
   dropped on each failure; hard cap (10 000) with oldest-first eviction.
6. ✅ **[MEDIUM] Dependencies pinned** — `mcp==2.0.0`, committed `uv.lock`,
   image builds with `uv sync --locked`.
7. ✅ **[MEDIUM] cloudflared network-isolated** — `mcp_edge` (cloudflared+mcp
   only) and internal-only `mcp_internal` (mcp+gateway); `TUNNEL_METRICS` on
   127.0.0.1. `gateway:4000` and `frontend:8080` are unreachable from the
   tunnel container.
8. ✅ [LOW] `POST /login` body capped (4 KiB) before form parsing.
9. ✅ Tool surface reworked: one MCP tool per allowlisted agent (the tool list
   is the agent directory); sanitized tool names, collisions are a startup
   configuration error.

Still owed from verification: one real agent round-trip through the gateway
(needs the stack up with real secrets — part of first-exposure testing below).

## Manual operator steps (only you can do these)

1. Create a Cloudflare Tunnel (Zero Trust → Networks → Tunnels), route a public
   hostname to `http://mcp:8765`, copy the connector token.
2. Add to `.env`: `TUNNEL_TOKEN=…`,
   `MCP_OPERATOR_PASSWORD=<high-entropy — openssl rand -base64 32>`,
   `MCP_PUBLIC_URL=https://<your-hostname>`.
3. `cp secrets/mcp-config.yaml.example secrets/mcp-config.yaml`,
   `mkdir -p secrets/mcp-data`, edit the `agents:` allowlist (only agents safe
   to expose — prompt injection reaching claude.ai inherits operator trust).
4. Strongly recommended defense-in-depth: a Cloudflare Access policy in front
   of the hostname, so the login page isn't reachable by the open internet.
5. `docker compose --profile mcp up -d --build mcp cloudflared`, run the smoke
   checks in `docs/mcp-server.md` ("Start" section), then add the custom
   connector in claude.ai pointing at `https://<hostname>/mcp`.

## Lower priority (can follow first exposure)

- [LOW] Create the store temp file with `O_EXCL, 0o600` (currently
  umask-then-chmod window); `mkdir(mode=0o700)` for the parent
  (`storage.py` `_save`).
- [INFO] Drop `tests/` from the production image (`mcp.Dockerfile`).
- [INFO] Password rotation doesn't revoke outstanding 30-day refresh tokens
  (break-glass: delete `secrets/mcp-data/oauth-store.json` and restart);
  consider a password-generation counter keyed into tokens.
- [INFO] `canonical_resource` uses `str.lower()`; prefer IDNA normalisation if
  non-ASCII hostnames ever enter the redirect allowlist.
- A distinct connector token for this internet-facing process (instead of the
  shared `TRI_ONYX_CONNECTOR_TOKEN`) would reduce blast radius — gateway-side
  change; revisit together with an opt-in flag for system commands on the
  inbound frame (`connector_handler.ex`).
