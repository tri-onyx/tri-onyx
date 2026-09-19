# Security Hunter Ledger

One line per entry, newest last.

- 2026-09-19 | FIXED | mcp-auth | Unverified connector senders (any Matrix room member via DM, any non-owner Slack sender in a bound channel) could execute the operator-only `/restart <agent>` system command, bypassing the taint/trust model entirely | lib/tri_onyx/connector_handler.ex
