# Matrix Setup Guide

This guide covers connecting TriOnyx to Matrix via the connector service.
The connector bridges Matrix rooms to TriOnyx agents — messages in mapped
rooms trigger agent sessions, and agent responses are posted back as threaded
replies.

---

## 1. Prerequisites

- A running TriOnyx gateway (Elixir)
- Docker and Docker Compose (with BuildKit enabled)
- A Matrix homeserver you can register accounts on, or an existing account on
  a public homeserver like matrix.org
- `curl` for API calls during setup

## 2. Create a Bot Account

The connector authenticates to Matrix as a regular user account. Create a
dedicated account for the bot rather than reusing a personal account.

### On matrix.org

Register at https://app.element.io or any Matrix client. Use a descriptive
username like `@tri-onyx-bot:matrix.org`.

### On a self-hosted homeserver (Synapse)

Use the admin API or registration endpoint:

```bash
# Register via Synapse admin API (requires shared secret from homeserver.yaml)
register_new_matrix_user -u tri-onyx-bot -p <password> -c /etc/synapse/homeserver.yaml
```

Or register through any Matrix client pointed at your homeserver.

## 3. Get an Access Token

The connector needs a long-lived access token. Obtain one via the login API:

```bash
curl -s -X POST https://matrix.example.com/_matrix/client/v3/login \
  -H 'Content-Type: application/json' \
  -d '{
    "type": "m.login.password",
    "identifier": {
      "type": "m.id.user",
      "user": "tri-onyx-bot"
    },
    "password": "YOUR_PASSWORD",
    "initial_device_display_name": "TriOnyx Connector"
  }' | python3 -m json.tool
```

The response contains `access_token` and `device_id`. Save both — the device
ID is needed for E2E encryption verification.

Alternatively, in Element: Settings > Help & About > Access Token (requires
developer mode enabled in settings).

**Store the token securely.** Set it as the `MATRIX_ACCESS_TOKEN` environment
variable. Never commit it to the repository.

## 4. Create Rooms and Invite the Bot

Create one Matrix room per agent (or per agent group) and invite the bot
account.

```bash
# Create a room
curl -s -X POST https://matrix.example.com/_matrix/client/v3/createRoom \
  -H "Authorization: Bearer $MATRIX_ACCESS_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{
    "name": "TriOnyx - Code Review",
    "topic": "Messages here trigger the code-review agent",
    "visibility": "private",
    "invite": ["@tri-onyx-bot:example.com"],
    "initial_state": [
      {
        "type": "m.room.encryption",
        "content": {"algorithm": "m.megolm.v1.aes-sha2"}
      }
    ]
  }'
```

Or create rooms through any Matrix client and invite the bot manually. Enable
encryption if desired (see section 5).

Note the room ID from the response (`!xxxx:example.com`) — you need it for
the connector configuration.

## 5. E2E Encryption Setup

End-to-end encryption is optional but recommended. When enabled, the connector
uses `matrix-nio` with the `libolm` crypto backend.

### Requirements

- The room must have encryption enabled (`m.room.encryption` state event)
- The `libolm-dev` library is included in the connector Docker image
- A persistent store path for crypto state (device keys, session keys)

### Persistent Crypto State

The connector stores E2E key material in a directory that must persist across
restarts. The `docker-compose.yml` mounts a named volume at `/data` for this
purpose. Configure the store path in `config.yaml`:

```yaml
matrix:
  store_path: /data/crypto-store
```

### Device Verification

After the bot joins an encrypted room, verify its device from another Matrix
client to establish cross-signing trust. In Element:

1. Open the room
2. Click the bot's avatar > Security > Verify
3. Complete the emoji verification flow

Unverified devices can still decrypt messages in most homeserver
configurations, but verification is needed for rooms that require verified
devices only.

## 6. Configure the Connector

Create `connector/config.yaml` with room-to-agent mappings:

```yaml
gateway:
  url: "http://gateway:4000"
  # Token must match TRI_ONYX_CONNECTOR_TOKEN on the gateway
  token: "${TRI_ONYX_CONNECTOR_TOKEN}"

matrix:
  homeserver: "https://matrix.example.com"
  # Access token is read from MATRIX_ACCESS_TOKEN env var
  store_path: "/data/crypto-store"

rooms:
  "!abc123:example.com":
    agent: code-reviewer
    mode: mention          # only respond to @mentions
    trusted_users:
      - "@alice:example.com"
      - "@bob:example.com"

  "!def456:example.com":
    agent: general-assistant
    mode: all              # respond to all messages
    trusted_users:
      - "@alice:example.com"
```

### Room configuration fields

| Field            | Description                                                |
|------------------|------------------------------------------------------------|
| `agent`          | Name of the agent definition to trigger                    |
| `mode`           | `all` (every message) or `mention` (only @bot mentions)   |
| `trusted_users`  | Matrix user IDs whose messages are treated as trusted input|

Messages from users not in `trusted_users` are still delivered to the agent
but marked as untrusted input, which raises the session's taint level.

## 7. Configure the Gateway

The gateway authenticates incoming connector requests using a shared token.
Generate a random token and set it on both sides:

```bash
# Generate a token
export TRI_ONYX_CONNECTOR_TOKEN=$(openssl rand -hex 32)
```

Set this in your environment or in a `.env` file (which must be listed in
`.gitignore`):

```bash
# .env (do NOT commit this file)
TRI_ONYX_CONNECTOR_TOKEN=<your-generated-token>
MATRIX_ACCESS_TOKEN=<your-matrix-access-token>
```

Docker Compose reads `.env` automatically and passes the variables to both
services.

## 8. Run It

```bash
# Build and start both services
docker compose up --build

# Or run in the background
docker compose up --build -d

# View logs
docker compose logs -f connector
```

The connector will:
1. Connect to the Matrix homeserver and perform an initial sync
2. Register with the gateway using the shared token
3. Begin listening for messages in configured rooms

## 9. Test the Setup

Send a test message in a mapped Matrix room:

```
Hello TriOnyx, can you read this?
```

Expected behavior:
1. The connector receives the message via Matrix sync
2. It sends a trigger request to the gateway with the message content
3. The gateway spawns the mapped agent
4. The agent processes the message and returns a response
5. The connector posts the response as a threaded reply in the Matrix room

Check the connector logs if no response appears:

```bash
docker compose logs connector | tail -50
```

## 10. Mention Mode

When a room is configured with `mode: mention`, the connector only forwards
messages that explicitly mention the bot's Matrix user ID
(`@tri-onyx-bot:example.com`).

This is useful for group rooms where the bot should not respond to every
message. In mention mode:

- Direct mentions like `@tri-onyx-bot review this PR` trigger the agent
- Regular conversation without mentions is ignored
- Replies to the bot's own messages also trigger the agent (continuing a thread)

In `mode: all`, every message in the room triggers the agent. This is suitable
for dedicated 1:1 rooms or purpose-specific rooms.

## 11. Trust and Taint Mapping

The connector maps Matrix identity signals to TriOnyx's taint model:

| Signal                        | Trust Level | Effect on Taint              |
|-------------------------------|-------------|------------------------------|
| Message from `trusted_users`  | Trusted     | Session starts untainted     |
| Message from unknown user     | Untrusted   | Session starts tainted       |
| Verified E2E device           | Higher      | Sender identity is confirmed |
| Unverified E2E device         | Lower       | Sender may be impersonated   |
| Unencrypted room              | Lowest      | Messages may be tampered     |

E2E verification status is informational — it does not override the
`trusted_users` list. A verified device from an untrusted user still produces
a tainted session. An unverified device from a trusted user produces an
untainted session but with a warning logged.

The gateway makes the final taint determination. The connector passes sender
identity and verification metadata; the gateway applies the policy.

## 12. Troubleshooting

### Sync failures

**Symptom:** Connector logs show `sync returned non-200` or connection errors.

- Verify the homeserver URL is correct and reachable from the container
- Check that the access token has not expired or been revoked
- If behind a reverse proxy, ensure the `/_matrix` path is forwarded correctly

### E2E encryption errors

**Symptom:** `OlmSessionError` or `Unable to decrypt` in logs.

- Ensure the crypto store path (`/data/crypto-store`) is on a persistent
  volume — losing the store means losing session keys
- Verify the bot device in Element or another client
- If the store is corrupted, delete the volume and re-verify:
  ```bash
  docker compose down -v
  docker compose up --build
  ```
  Then re-verify the bot device from another client.

### Connection drops / reconnection

The connector should automatically reconnect on transient network failures.
If it does not:

- Check `docker compose logs connector` for repeated errors
- Restart the connector: `docker compose restart connector`
- If the homeserver uses rate limiting, the connector may be throttled — check
  for HTTP 429 responses in logs

### Rate limits

Matrix homeservers enforce rate limits on sync and send operations. If the
bot is rate-limited:

- Reduce the sync polling frequency in the connector configuration
- For self-hosted homeservers, adjust rate limit settings in `homeserver.yaml`
- For matrix.org, respect the `Retry-After` header in 429 responses

### Gateway connection refused

**Symptom:** Connector cannot reach the gateway at `http://gateway:4000`.

- Ensure both services are in the same Docker Compose network (they are by
  default when defined in the same `docker-compose.yml`)
- Check that the gateway is fully started before the connector attempts
  registration — `depends_on` ensures start order but not readiness
- Verify `TRI_ONYX_CONNECTOR_TOKEN` matches on both services
