# Security hunter ledger

- 2026-11-16 | FIXED     | risk-model  | Label inter-agent messages with the sending session's taint, not a sibling session's | lib/tri_onyx/triggers/inter_agent.ex
- 2026-11-16 | DOWNGRADED| risk-model  | InterAgent message_type is forwarded unsanitised (no length/charset cap) into the receiver envelope; taint still inherited so low impact | lib/tri_onyx/triggers/inter_agent.ex
