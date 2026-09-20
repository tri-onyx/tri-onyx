# Security Hunter Ledger

One line per entry, newest last. Statuses: `FIXED` (this PR), `DOWNGRADED`
(real concern, not provable/fixable here — a human should look),
`NO-FINDING` (area swept, nothing cleared the bar).

- 2026-09-20 | FIXED | connector | Matrix `_should_dispatch`'s mention-gating carve-out for replies fired for a reply to *any* event, not just the bot's own messages — any member of a `mode: mention` group room could invoke the agent at will by replying to an arbitrary message, bypassing the documented (`docs/matrix-guide.md`) requirement of an explicit @mention | connector/connector/adapters/matrix.py
- 2026-09-20 | NOTE | connector | Open PRs #38, #44, #47, #48 (2026-08-30 .. 2026-09-13) already cover Slack/Matrix approval-reaction trust, Slack bound-channel bot trust, and gateway-mediated email/calendar tool grants — not re-filed. Reviewed alongside this finding: slack.py's ConsentStore/ApprovalStore/ChannelCache, channel_bindings.py's name resolution, gateway_client.py, protocol.py, tool_briefs.py, main.py's routing — no other new trust-boundary break found beyond the mention-gating bypass fixed here.
