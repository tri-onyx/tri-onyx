# Security Hunter Ledger

One line per entry, newest last. Statuses: `FIXED` (this PR), `DOWNGRADED`
(real concern, not provable/fixable here — a human should look),
`NO-FINDING` (area swept, nothing cleared the bar).

- 2026-09-13 | FIXED | connector | Any Slack channel member's 👍/👎 reaction on a pending BCP/action approval — even from a non-owner — unconditionally consumed the ApprovalStore's ts→approval_id mapping, silently dropping the real owner's later approve/reject vote and permanently blocking the mandatory human-in-the-loop gate (docs/bcp.md) until the 7-day TTL expired | connector/connector/adapters/slack.py
- 2026-09-13 | NOTE | connector | Open PR #38 (2026-08-30) already covers a related but distinct gap: the *gateway* (lib/tri_onyx/connector_handler.ex) accepting an approval reaction's vote regardless of `trust.level`. That PR does not touch slack.py and does not fix the mapping-consumption bug fixed here — both are needed for the approval gate to hold end-to-end.
- 2026-09-13 | NO-FINDING | connector | Reviewed adapters/matrix.py end to end against the 2026-08-30 sweep (mention gating, thread/megolm handling, key verification, room creation/power-level demotion, `_dispatch_reaction`) — no new gap since that review; `_trust_all_devices` TOFU-trusts all room members' devices for E2E key sharing but still gates dispatch/approval via `_compute_trust`/`trusted_users`, matching the existing DOWNGRADED note. Also reviewed gateway_client.py, protocol.py, tool_briefs.py, formatting.py (commonmark `html: False`), config.py, transcriber.py (ffmpeg invoked via argv list, no shell, no attacker-controlled paths) and main.py's outbound/action routing — no trust-boundary break found beyond the approval-reaction fix above.
