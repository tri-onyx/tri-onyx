# Security Hunter Ledger

One line per entry, newest last.

- 2026-09-09 | FIXED | gateway-http | Router trusted a spoofable X-Forwarded-For header as the webhook source IP, letting any caller who could reach the gateway directly bypass a webhook endpoint's IP allowlist and per-IP rate limit | lib/tri_onyx/router.ex
