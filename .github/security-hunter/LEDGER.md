# Security Hunter Ledger

One line per finding, newest last. Statuses: `FIXED` (this PR), `DOWNGRADED`
(real concern, not provable/fixable here — a human should look),
`NO-FINDING` (area swept, nothing cleared the bar).

- 2026-09-27 | FIXED | connector | Slack `ensure_channel`'s create-lost-the-race fallback joined and bound *any* existing channel matching the auto-provisioned name, without checking who created it — an attacker who squats the name (e.g. after a rename frees it) gets a bound channel, and every message they post in it is treated as verified sender trust by `_handle_bound_channel_message` | connector/connector/adapters/slack.py
- 2026-09-27 | NOTE | connector | Independently re-derived the approval-reaction trust gap already covered by open PRs #38 (gateway-side `trust.level` check) and #48 (Slack-side owner-only reaction authorization + mapping-consumption fix) — not re-filed; see those PRs.
- 2026-09-27 | NO-FINDING | connector | Reviewed channel_bindings.py's `_resolve_names`/`_unique_name` collision handling, ConsentStore/ApprovalStore/ChannelCache persistence, matrix.py's `_trust_all_devices` TOFU device trust (still gates dispatch/approval via `trusted_users`, matching the prior DOWNGRADED note from PR #38), room creation/power-level demotion, and protocol.py framing — no other new trust-boundary break found beyond the channel-squatting fix above.
