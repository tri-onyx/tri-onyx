# Email Agent Setup Guide

This guide covers connecting TriOnyx to a personal email account via
IMAP/SMTP. The gateway polls IMAP for new messages, delivers them to the email
agent as files, and mediates all outbound email through SMTP. Credentials never
enter the agent sandbox.

---

## 1. Prerequisites

- A running TriOnyx gateway (Elixir)
- Docker and Docker Compose
- An email account with IMAP and SMTP access enabled
- The email agent definition loaded (`workspace/agent-definitions/email.md`)

## 2. Enable IMAP/SMTP on Your Email Provider

Most providers require explicit opt-in for IMAP access. Some require an
app-specific password rather than your regular login password.

### Gmail

1. Go to https://myaccount.google.com/security
2. Enable 2-Step Verification (required for app passwords)
3. Go to https://myaccount.google.com/apppasswords
4. Generate an app password for "Mail" on "Other (TriOnyx)"
5. Save the 16-character app password

IMAP: `imap.gmail.com:993` (SSL)
SMTP: `smtp.gmail.com:587` (STARTTLS)

### Outlook / Microsoft 365

1. Go to https://account.microsoft.com/security
2. Enable 2-Step Verification (required for app passwords)
3. Go to https://account.live.com/proofs/AppPassword
4. Generate an app password and save it

IMAP: `outlook.office365.com:993` (SSL/TLS)
SMTP: `smtp-mail.outlook.com:587` (STARTTLS)

Note: Microsoft uses OAuth2/Modern Auth by default. For IMAP/SMTP with
password authentication, you must use an app password — regular account
passwords will be rejected.

### Fastmail

1. Go to Settings > Privacy & Security > Integrations
2. Create a new app password with IMAP and SMTP access
3. Save the generated password

IMAP: `imap.fastmail.com:993` (SSL)
SMTP: `smtp.fastmail.com:587` (STARTTLS)

### Self-hosted (Dovecot/Postfix)

Use the same credentials as your regular email login. Ensure the IMAP server
allows LOGIN authentication over TLS and that SMTP supports STARTTLS on port
587.

## 3. Configure Environment Variables

Set the following environment variables. Add them to your `.env` file (which
must be in `.gitignore` — never commit credentials):

```bash
# .env (do NOT commit this file)

# IMAP — inbound email polling
TRI_ONYX_IMAP_HOST=imap.gmail.com
TRI_ONYX_IMAP_PORT=993
TRI_ONYX_IMAP_USERNAME=you@gmail.com
TRI_ONYX_IMAP_PASSWORD=abcd-efgh-ijkl-mnop
TRI_ONYX_IMAP_SSL=true
TRI_ONYX_IMAP_POLL_INTERVAL=300000    # 5 minutes in ms

# SMTP — outbound email sending
# Defaults to IMAP values if not set separately
TRI_ONYX_SMTP_HOST=smtp.gmail.com
TRI_ONYX_SMTP_PORT=587
TRI_ONYX_SMTP_USERNAME=you@gmail.com
TRI_ONYX_SMTP_PASSWORD=abcd-efgh-ijkl-mnop
TRI_ONYX_SMTP_SSL=true

# Agent name that receives email (default: "email")
TRI_ONYX_EMAIL_AGENT=email
```

### Minimal configuration

If your IMAP and SMTP use the same credentials (common for most providers),
you only need to set the IMAP variables plus the SMTP host/port:

```bash
TRI_ONYX_IMAP_HOST=imap.gmail.com
TRI_ONYX_IMAP_USERNAME=you@gmail.com
TRI_ONYX_IMAP_PASSWORD=abcd-efgh-ijkl-mnop
TRI_ONYX_SMTP_HOST=smtp.gmail.com
TRI_ONYX_SMTP_PORT=587
```

Everything else has sensible defaults. SMTP username and password default to
the IMAP values. SSL defaults to `true`. Poll interval defaults to 5 minutes.

### Variable reference

| Variable | Default | Description |
|----------|---------|-------------|
| `TRI_ONYX_IMAP_HOST` | *(required)* | IMAP server hostname. Presence enables the email feature. |
| `TRI_ONYX_IMAP_PORT` | `993` | IMAP server port |
| `TRI_ONYX_IMAP_USERNAME` | `""` | IMAP login username (usually your email address) |
| `TRI_ONYX_IMAP_PASSWORD` | `""` | IMAP login password or app password |
| `TRI_ONYX_IMAP_SSL` | `true` | Use SSL/TLS for IMAP connection |
| `TRI_ONYX_IMAP_POLL_INTERVAL` | `300000` | Polling interval in milliseconds (5 min) |
| `TRI_ONYX_EMAIL_AGENT` | `email` | Agent definition name to receive email |
| `TRI_ONYX_SMTP_HOST` | IMAP host | SMTP server hostname |
| `TRI_ONYX_SMTP_PORT` | `587` | SMTP server port |
| `TRI_ONYX_SMTP_USERNAME` | IMAP username | SMTP login username |
| `TRI_ONYX_SMTP_PASSWORD` | IMAP password | SMTP login password |
| `TRI_ONYX_SMTP_SSL` | `true` | Use STARTTLS for SMTP connection |

## 4. Run It

The email environment variables are already wired through in
`docker-compose.yml`. Docker Compose reads `.env` automatically and passes
the values to the gateway container. No changes to `docker-compose.yml` are
needed — just set the variables in `.env`.

```bash
# Start the gateway with email enabled
docker compose up --build

# Or in the background
docker compose up --build -d

# View gateway logs (look for "Email poller starting")
docker compose logs -f gateway
```

On startup with `TRI_ONYX_IMAP_HOST` set, you should see:

```
Email poller starting for agent=email host=imap.gmail.com interval=300000ms
```

If `TRI_ONYX_IMAP_HOST` is not set, the email poller is not started and no
email-related processes run. This is the default behavior.

## 5. How It Works

### Inbound flow

1. The IMAP poller connects to your email server on each poll interval
2. It searches for new messages since the last-seen UID
3. Each new email is parsed and written as a directory:

```
workspace/agents/email/inbox/
  12345/
    message.json          # Parsed headers, body, attachment manifest
    attachment-1-report.pdf
  12346/
    message.json
```

4. The risk manifest is updated with `taint_level: :high` (email is untrusted)
5. A `:connector_unverified` trigger dispatches to the email agent
6. The agent wakes and processes the new email

### Outbound flow

The agent writes a draft JSON file, then calls the `SendEmail` tool:

```json
{
  "to": "recipient@example.com",
  "subject": "Re: Your question",
  "body": "Here is the answer...",
  "cc": "team@example.com",
  "in_reply_to": "<original-message-id@example.com>"
}
```

The gateway reads the draft, validates it, and sends via SMTP. The agent
never sees SMTP credentials.

### Folder operations

- **MoveEmail** — moves an email between folders on both IMAP and the local
  filesystem, keeping them in sync
- **CreateFolder** — creates a new folder on both IMAP and the local
  filesystem

## 6. Receive-Only Mode

To create an email agent that can read and sort email but cannot send, remove
`SendEmail` from the tools list in the agent definition:

```yaml
---
name: email-readonly
description: Read-only email processor
model: claude-sonnet-4-20250514
tools: Read, Write, Edit, Bash, Grep, Glob, MoveEmail, CreateFolder, SendMessage
# ...
---
```

The agent can still use `MoveEmail` and `CreateFolder` to sort incoming email
into folders.

## 7. Security Model

### Taint tracking

Email inbound uses the `:connector_unverified` trigger, which gives the
session **high taint** from the start. This is correct — email content is
untrusted and may contain prompt injection attempts.

The email agent should be treated as a high-taint agent. If it needs to
communicate findings to low-taint agents, use BCP queries (bandwidth-
constrained trust protocol) rather than raw `SendMessage`.

### Credential isolation

IMAP and SMTP credentials are held exclusively by the gateway process. They
are set as environment variables on the gateway container and never passed
to agent containers. The agent interacts with email only through the MCP
tools, which emit requests over the protocol channel to the gateway.

### Tool sensitivity levels

| Tool | Auth Required | Sensitivity |
|------|---------------|-------------|
| `SendEmail` | yes | `:medium` |
| `MoveEmail` | yes | `:low` |
| `CreateFolder` | yes | `:low` |

### Path traversal prevention

All folder names are validated to be alphanumeric with hyphens and underscores
only. No `..`, `/`, or special characters are allowed. Draft file paths are
validated to be within the agent's workspace directory.

## 8. Customizing the Agent

The default `email.md` agent definition handles general email triage. You can
customize it by editing `workspace/agent-definitions/email.md`:

- **Change the model** — use a smaller model for cost efficiency on high-volume
  accounts, or a larger model for complex triage logic
- **Adjust the system prompt** — add rules for how to categorize specific
  senders, domains, or subject patterns
- **Change filesystem permissions** — restrict or expand what the agent can
  read and write
- **Add BCP channels** — configure structured communication with other agents
  for forwarding summaries without taint propagation

### Example: newsletter-only processor

```yaml
---
name: newsletter-processor
description: Sorts newsletters into folders
model: claude-haiku-4-20250514
tools: Read, Grep, Glob, MoveEmail, CreateFolder
network: none
fs_read:
  - "/agents/newsletter-processor/**"
fs_write: []
idle_timeout: 10m
---

You sort newsletters into topic folders. Read each email's message.json,
determine the topic, create a folder if needed, and move the email there.
Do not send any emails or messages to other agents.
```

## 9. Troubleshooting

### Poller not starting

**Symptom:** No "Email poller starting" in gateway logs.

- Verify `TRI_ONYX_IMAP_HOST` is set in the gateway's environment
- Check that Docker Compose is passing the variable through (list it under
  `environment:` in `docker-compose.yml`)
- The poller only starts when `TRI_ONYX_IMAP_HOST` is non-empty

### IMAP connection failures

**Symptom:** "IMAP poll failed" errors in gateway logs.

- Verify hostname, port, and SSL settings match your provider
- Check that the username and password are correct (test with a desktop email
  client first)
- For Gmail: ensure you are using an app password, not your regular password
- For self-hosted: ensure the IMAP server accepts LOGIN auth over TLS

### SMTP send failures

**Symptom:** SendEmail tool returns an error.

- Verify SMTP hostname and port (587 for STARTTLS, 465 for SSL)
- Check username and password (defaults to IMAP credentials if not set)
- For Gmail: sending limits apply (500/day for consumer, 2000/day for
  Workspace)
- Check that the "from" address matches the SMTP username — some providers
  reject mismatched senders

### Agent not waking on new email

**Symptom:** Emails appear in the filesystem but the agent doesn't process them.

- Check that the `email` agent definition is loaded (look for "Agent: email"
  in startup logs)
- Verify `TRI_ONYX_EMAIL_AGENT` matches the agent definition name
- Check TriggerRouter logs for dispatch errors

### Poll interval tuning

The default poll interval is 5 minutes (300000 ms). Adjust based on your
needs:

- **High-volume accounts:** 60000 (1 minute) — more responsive but more
  IMAP connections
- **Low-volume accounts:** 900000 (15 minutes) — reduces load on the email
  server
- **Development/testing:** 10000 (10 seconds) — fast feedback loop

```bash
TRI_ONYX_IMAP_POLL_INTERVAL=60000
```
