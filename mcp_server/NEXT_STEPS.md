# Public MCP Server — Status & Remaining Steps

> Status as of 2026-08-10 (end of day): **LIVE and verified end-to-end.**
> The claude.ai connector is authorized and working (token exchange + agent
> round-trips confirmed), and a Cloudflare Access policy (One-time PIN,
> operator email only) gates `/login` and `/authorize` — nothing else, since
> claude.ai calls `/mcp`, `/token`, `/register` and `.well-known` server-side.
> All blocking security fixes from the 2026-08-09 review are implemented and
> tested. Architecture and setup docs: `docs/mcp-server.md`.
>
> Operational notes: restarting the `mcp` service kills in-flight tool calls —
> apply config changes when idle. Agent turns take 1–3 minutes; Claude voice
> may time out client-side even though the turn completes.

## Completed (2026-08-10)

1. ✅ **[HIGH] Login transaction bound to the initiating browser** — `mcp_txn`
   cookie set on the `/authorize` redirect (`TxnCookieMiddleware`); `/login`
   (GET and POST) refuses a txn without the matching cookie. Consent page shows
   the client id prefix + exact redirect URI, not just the self-asserted name.
2. ✅ **[HIGH] Gateway system commands blocked** — agent tools reject messages
   whose first token starts with `/` unless it is `/library:action` skill
   syntax, so `/restart <off-allowlist agent>` cannot be smuggled through.
3. ✅ **[MEDIUM] DCR store bounded** — `max_registered_clients` (default 32;
   oldest tokenless registration evicted, preferring one with no parked
   authorization; a client with live tokens is never evicted) +
   `client_ttl_seconds` prune (default 30 d), plus a per-IP rate limit on
   `/register` (`max_registrations_per_ip`, default 20). See 2026-08-25 below.
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

10. ✅ Registrations force-downgraded to public clients — claude.ai registers
    as `client_secret_post` but never presents the secret at `/token`.
11. ✅ Login page CSP `form-action` includes the callback origins — Chrome
    enforces form-action on the submission's redirect target and otherwise
    silently blocks the 302 back to claude.ai.
12. ✅ Completed logins replayable for 60 s (cookie-bound + password-verified)
    so password-manager interstitial resubmits don't strand the flow.
13. ✅ Operator setup done: tunnel routed to `http://mcp:8765`, `.env` secrets
    set, `secrets/mcp-config.yaml` filled, Cloudflare Access (One-time PIN,
    operator email) on `/login` + `/authorize` only, connector added in
    claude.ai, `news`-agent round-trip verified end-to-end.

## Completed (2026-08-25 review round)

14. ✅ **[HIGH] Abandoned turns can no longer cross-talk** — the gateway has no
    cancel/interrupt frame, so a turn abandoned by the hard deadline or a
    disconnect kept running there and its late `agent_result` settled the *next*
    turn on the same key. Abandonments are now counted per key and one terminal
    frame is swallowed per count (counters expire after 15 min).
15. ✅ **[HIGH] Turns isolated per credential** — the authenticated client id is
    hashed into the `room_id`, so two tokens sharing a `conversation_id` cannot
    attach to each other's turns. (Folded into the room id rather than added as a
    third key component: gateway frames only echo `agent_name` + `room_id`.)
16. ✅ **[MEDIUM] Parked replies are labelled** — a parked reply/error now names
    the message it answers and states that the message the collecting call
    carried was not delivered and should be resent.
17. ✅ **[MEDIUM] `/register` flood mitigated** — per-IP rate limit
    (`RegisterRateLimitMiddleware`, its own limiter instance so it cannot slow
    the operator's login), eviction prefers clients with no parked
    authorization, cap raised 10 → 32.
18. ✅ **[MEDIUM] `_pending` authorizations capped** (64, oldest first) and
    expired entries pruned on insert.
19. ✅ **[MEDIUM] `trust.level` is `unverified`** — messages are LLM-composed
    text with no sender identity; `verified` overstated it. Check that the live
    `secrets/mcp-config.yaml` does not pin `session.trust_level: verified`.
20. ✅ **[MEDIUM] Completed-login replay is rate-limited** — a wrong password on
    the 60 s replay window now records a limiter failure (it was a free oracle
    for a known-good txn).
21. ✅ **[LOW] `client_ip` no longer trusts `X-Forwarded-For`** — CF only, and
    only when `server.trusted_proxy_headers` (default true); otherwise the
    socket peer.
22. ✅ **[LOW] Non-ASCII `txn` no longer 500s** — `hmac.compare_digest` is given
    bytes.
23. ✅ **[LOW] Lock table pruned** — `_locks` entries with no turn, no
    abandonment and no holder are swept.

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
