# Security Hunter Ledger

One line per entry, newest last.

- 2026-08-26 | FIXED | gateway-http | Path traversal in agent_name/session_id on GET /images/:agent_name/:session_id/:image_id lets an unauthenticated caller read arbitrary files on the host, bypassing the logs/ sandbox (the sibling /audio route already guards this same construction) | lib/tri_onyx/router.ex
