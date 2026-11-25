# Security hunter ledger

One line per entry, newest last. Statuses: FIXED, DOWNGRADED, NO-FINDING.

- 2026-11-25 | FIXED     | gateway-http | Taint running sessions with the trigger's classification when routing webhook/unverified prompts into them | lib/tri_onyx/trigger_router.ex
- 2026-11-25 | DOWNGRADED| gateway-http | Documented cloudflared ingress `path: /hooks/*` is an unanchored regex, so any path containing "/hooks" (e.g. /agents/hooks/prompt, /pages/<c>/hooks) would be tunnelled to the unauthenticated management API; doc should use `^/hooks/[^/]+$` — needs a live tunnel to prove | docs/webhook-receiver-design.md
- 2026-11-25 | DOWNGRADED| gateway-http | ExternalMessage accepts any non-empty bearer because :api_key is never set by config/runtime.exs (fail-open "development" branch); same exposure as the unauthenticated /agents/:name/prompt, so only matters if /messages is ever tunnelled | lib/tri_onyx/triggers/external_message.ex
- 2026-11-25 | DOWNGRADED| gateway-http | Webhook allowed_ips CIDR match uses the source IP's bit length, so IPv6 sources with leading zero bits (::, ::ffff:a.b.c.d) match IPv4 CIDRs; only reachable with a spoofed/unusual source IP | lib/tri_onyx/webhook_receiver.ex
- 2026-11-25 | DOWNGRADED| risk-model   | Inter-agent prompt routed into a running session is labelled with the sender's taint (may be :low) while a fresh inter-agent session starts at the matrix's :medium — design question, left as-is | lib/tri_onyx/triggers/inter_agent.ex
- 2026-11-25 | DOWNGRADED| gateway-http | Connector WS register accepts token "" when TRI_ONYX_CONNECTOR_TOKEN is set but empty (Map.get default ""); config should treat empty as unset | lib/tri_onyx/connector_handler.ex
