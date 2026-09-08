# Security Hunter Ledger

One line per entry, newest last.

- 2026-09-08 | FIXED | frontend | Client-side SSE markdown renderer (chat.js's `marked`) passed raw HTML through unescaped and never validated link/image destination schemes, letting a `<script>`/event-handler tag or a `javascript:` link in agent text or tool-result content execute in the dashboard's origin as soon as it streamed in live — unlike the initial page-load path (`views/helpers.render_markdown`, markdown-it with `html: False`), which was already safe against both | frontend/trionyx_ui/static/js/chat.js, frontend/trionyx_ui/static/js/markdown_safety.js
