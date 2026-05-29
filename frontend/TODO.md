# TriOnyx Frontend — Post-V1 TODO

## Dashboard

- [ ] Agent cards should show session count when an agent has multiple concurrent sessions
- [ ] Starred/pinned agents — promote favorites to a card view when list view is added
- [ ] List view toggle (compact table) as an alternative to card grid
- [x] Auto-refresh dashboard data (HTMX polls summary strip and agent grid every 10s)
- [ ] Sort/filter agents by status, risk level, model, or name

## Chat

- [x] Chat view redirect loop — replaced server-side redirect with "Starting agent..." interstitial that polls via HTMX until active
- [ ] Approval requests rendered inline in chat with approve/reject buttons
- [ ] Multiple sessions per agent — session picker when an agent has >1 active session
- [x] Textarea auto-grow — smooth resize, height resets after submit, Shift+Enter for newline
- [x] Message timestamps — relative time ("2m ago") shown on hover, full timestamp in tooltip
- [x] Collapsible tool call pairs — tool_use + tool_result merged into single collapsible block
- [x] Agent context panel — expandable sidebar showing tools, fs_read/fs_write, network policy, taint/sensitivity/capability breakdown, send_to/receive_from with clickable agent links
- [ ] Streaming text — currently each `text` event replaces as a full message. Handle partial/streaming text if the gateway adds support
- [x] Copy button on agent responses and code blocks
- [x] Session cost running total visible in header

## Additional Pages

- [ ] Graph view — agent topology with D3 force-directed layout, Biba/BLP violation highlighting
- [ ] Matrix view — tool taint/sensitivity/capability classification table, trigger table, risk matrix grid
- [ ] Workspace explorer — file tree with taint/sensitivity/git status, file detail with git provenance
- [ ] Audit log — query and display audit entries by date range
- [ ] Webhook management — CRUD webhook endpoints, rotate secrets
- [ ] Heartbeat management — list schedules, enable/disable global dispatch, trigger manually, schedule/cancel individual heartbeats
- [ ] Connector status — list active connectors with platform and adapter info

## Approvals

- [x] Approval bell icon with dropdown listing all pending BCP + action approvals
- [x] Approve/reject actions from the notification dropdown
- [x] Approval badge polls for updates every 15s via HTMX
- [ ] Dedicated approvals page with full history and filtering
- [ ] Notification sound or browser notification for new approval requests

## Design & UX

- [ ] Mobile/responsive layout — currently optimized for desktop only
- [x] Favicon
- [ ] Loading skeletons for dashboard cards and chat history while gateway responds
- [ ] Error toast/notification system instead of inline error messages
- [ ] Dark/light theme toggle (currently dark only)
- [ ] Keyboard navigation — arrow keys to move between agent cards, Escape to go back
- [x] Breadcrumb navigation (Dashboard → Agent Name)

## Infrastructure

- [x] CSRF protection — CsrfViewMiddleware + hx-headers on body + {% csrf_token %} in standard forms
- [x] Production static file serving via WhiteNoise + collectstatic in Dockerfile
- [x] Health check endpoint for the frontend container (`/healthz` — returns 200 with gateway status)
- [x] Gunicorn production config (Dockerfile CMD uses gunicorn; docker-compose overrides with runserver for dev)
- [x] Frontend container logging configuration (LOGGING dict in settings, RequestLoggingMiddleware, gateway module logging)
- [x] Rate limiting on prompt submission to prevent accidental spam (PromptRateLimitMiddleware server-side + client-side send button debounce)
- [x] Session-based preferences (e.g., collapsed tool calls, selected view mode) via localStorage (prefs object in chat.js, toggle in context panel)

## Connector Replacement

- [ ] Evaluate replacing Matrix connector for direct user interaction — the web chat could become the primary interface, reducing dependency on external chat platforms
- [ ] WebSocket connection to gateway as a proper connector (register with token, receive all agent events, not just per-agent SSE)
- [ ] Notification system — browser notifications for agent completions, approval requests, risk escalations when the tab is not focused
