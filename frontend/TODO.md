# TriOnyx Frontend — Post-V1 TODO

## Dashboard

- [ ] Agent cards should show session count when an agent has multiple concurrent sessions
- [ ] Starred/pinned agents — promote favorites to a card view when list view is added
- [ ] List view toggle (compact table) as an alternative to card grid
- [x] Auto-refresh dashboard data (HTMX polls summary strip and agent grid every 10s)
- [ ] Sort/filter agents by status, risk level, model, or name

## Chat

- [ ] Chat view redirect loop — when auto-starting an inactive agent, the redirect can loop if the agent takes time to start. Add a "starting..." interstitial state instead of redirecting
- [ ] Approval requests rendered inline in chat with approve/reject buttons
- [ ] Multiple sessions per agent — session picker when an agent has >1 active session
- [ ] Textarea auto-grow is basic — improve multiline prompt editing UX
- [ ] Message timestamps — show relative time ("2m ago") on hover or inline
- [ ] Collapsible tool call pairs — group tool_use + tool_result into a single collapsible block
- [ ] Agent context panel — expandable sidebar or drawer showing tools, fs_read/fs_write, network policy, taint/sensitivity/capability breakdown, send_to/receive_from
- [ ] Streaming text — currently each `text` event replaces as a full message. Handle partial/streaming text if the gateway adds support
- [ ] Copy button on agent responses and code blocks
- [ ] Session cost running total visible in header

## Additional Pages

- [ ] Graph view — agent topology with D3 force-directed layout, Biba/BLP violation highlighting
- [ ] Matrix view — tool taint/sensitivity/capability classification table, trigger table, risk matrix grid
- [ ] Workspace explorer — file tree with taint/sensitivity/git status, file detail with git provenance
- [ ] Log browser — browse historical session logs by agent, view individual sessions
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
- [ ] Favicon
- [ ] Loading skeletons for dashboard cards and chat history while gateway responds
- [ ] Error toast/notification system instead of inline error messages
- [ ] Dark/light theme toggle (currently dark only)
- [ ] Keyboard navigation — arrow keys to move between agent cards, Escape to go back
- [ ] Breadcrumb navigation (Dashboard → Agent Name)

## Infrastructure

- [ ] CSRF protection — add CsrfViewMiddleware and tokens for defense-in-depth
- [ ] Production static file serving via WhiteNoise or collectstatic + nginx
- [ ] Health check endpoint for the frontend container
- [ ] Gunicorn production config (currently using Django dev server via compose override)
- [ ] Frontend container logging configuration
- [ ] Rate limiting on prompt submission to prevent accidental spam
- [ ] Session-based preferences (e.g., collapsed tool calls, selected view mode) via cookies or localStorage

## Connector Replacement

- [ ] Evaluate replacing Matrix connector for direct user interaction — the web chat could become the primary interface, reducing dependency on external chat platforms
- [ ] WebSocket connection to gateway as a proper connector (register with token, receive all agent events, not just per-agent SSE)
- [ ] Notification system — browser notifications for agent completions, approval requests, risk escalations when the tab is not focused
