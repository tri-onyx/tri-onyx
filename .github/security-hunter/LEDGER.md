# Security Hunter Ledger

One line per entry, newest last.

- 2026-09-05 | FIXED | mcp-auth | uvicorn's ProxyHeadersMiddleware, wired with `forwarded_allow_ips="*"`, let any caller rewrite `request.client` via a spoofed `X-Forwarded-For` header on every request, bypassing the per-IP login lockout and the `/register` rate limiter that `mcp_server.server.client_ip` deliberately built to resist exactly that header | mcp_server/mcp_server/main.py
