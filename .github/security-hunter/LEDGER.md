# Security Hunter Ledger

One line per entry, newest last.

- 2026-08-30 | FIXED | connector | Any room/channel member's 👍/👎 reaction approved or rejected pending BCP/action approvals — ConnectorHandler never checked the sender's trust level | lib/tri_onyx/connector_handler.ex
- 2026-08-30 | DOWNGRADED | connector | Matrix `_trust_all_devices` TOFU-trusts every device of every user in a configured room (not just `trusted_users`) purely for E2E key sharing; doesn't grant message dispatch or approval rights on its own (those still gate on `_compute_trust`/`trusted_users`), so not independently exploitable, but worth a human look if E2E confidentiality guarantees are ever relied on for authz | connector/connector/adapters/matrix.py
- 2026-08-30 | NO-FINDING | connector | Reviewed adapters/matrix.py (mention gating, thread extraction, key verification, room creation/power levels, merge buffering) and adapters/slack.py's approval/consent store end to end; channel_bindings.py grant model; protocol.py framing. No other trust-boundary break found beyond the approval-reaction gap fixed above.
