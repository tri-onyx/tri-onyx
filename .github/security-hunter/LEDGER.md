# Security hunter ledger

One line per entry, newest last. Statuses: FIXED (in the PR that added the line), DOWNGRADED (real concern, needs a human), NO-FINDING (area swept).

- 2026-11-22 | FIXED     | connector   | Escape tainted content in Slack approval messages (masked <url\|label> links, <!channel> pings) | connector/connector/adapters/slack.py
- 2026-11-22 | DOWNGRADED| connector   | Matrix *action* approvals (SendEmail/GitHub) render agent-supplied query_summary/response_content as markdown, so [label](url) masks the real URL from the reviewer; BCP approvals are safe (plain-text file). Needs a markdown-escape or code-block rendering decision | connector/connector/adapters/matrix.py
- 2026-11-22 | DOWNGRADED| connector   | Agent output, inter-agent mirrors and prompt mirrors reach Slack unescaped (markdown_to_mrkdwn is a pass-through), so a tainted agent can @channel-ping or mask links in bound channels | connector/connector/formatting.py
- 2026-11-22 | NO-FINDING| connector   | Also checked: approval reactions from non-owners (already open as #38/#48/#65/#68/#77), Matrix invites/edits/merge-buffer trust per sender, Slack consent/DM path, gateway audio_id path (gateway-generated, not agent-controlled) |
