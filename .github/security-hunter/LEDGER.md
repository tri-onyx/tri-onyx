# Security Hunter Ledger

One line per entry, newest last.

- 2026-09-01 | FIXED | frontend | Prompt rate limiter keyed on client-spoofable X-Forwarded-For, letting any client bypass the per-client limit and flood /agents/:name/prompt (unbounded LLM cost, gateway load) | frontend/trionyx_ui/middleware.py
