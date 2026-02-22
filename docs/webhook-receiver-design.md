# Webhook Receiver Design

> **Status:** Draft
> **Date:** 2026-02-15
> **Scope:** Internet-facing webhook ingress for TriOnyx agents via Cloudflare Tunnel

## Problem

TriOnyx agents need to receive events from external services (GitHub, Slack,
monitoring tools, CI systems, etc.) via webhooks. The current `POST /webhooks/:agent_name`
endpoint has no authentication — anyone who knows the agent name can trigger it.
We need a secure webhook receiver that:

- Is safe to expose directly to the internet (behind Cloudflare Tunnel)
- Uniquely identifies each webhook entry point
- Binds each entry point to one or more agents
- Authenticates senders without requiring complex integrations
- Maintains TriOnyx's taint-by-default posture for untrusted input

## Architecture Overview

```
External Service (GitHub, Slack, etc.)
    │
    │  POST https://<tunnel>.cfargotunnel.com/hooks/<endpoint_id>
    │  X-Webhook-Signature: sha256=<hmac_hex>
    │  X-Webhook-Timestamp: <unix_epoch>
    │
    ▼
┌──────────────────┐
│  Cloudflare      │  TLS termination, DDoS protection, IP filtering
│  Tunnel          │  (transport layer — NOT an auth layer)
└──────────────────┘
    │
    ▼
┌──────────────────────────────────────────────────────────────┐
│  WebhookReceiver Plug Pipeline                               │
│                                                              │
│  1. Rate limiter (per endpoint_id, per source IP)            │
│  2. Path lookup: endpoint_id → WebhookEndpoint config        │
│  3. HMAC signature verification (X-Webhook-Signature)        │
│  4. Timestamp validation (replay window)                     │
│  5. Payload size + JSON validation                           │
│  6. Dispatch to bound agent(s) via TriggerRouter             │
└──────────────────────────────────────────────────────────────┘
    │
    ▼
┌──────────────────┐
│  TriggerRouter   │  Existing dispatch — spawns/routes to AgentSession
└──────────────────┘
    │
    ▼
┌──────────────────┐
│  AgentSession    │  Tainted immediately (webhook = untrusted)
└──────────────────┘
```

## Security Model: Defense in Depth

The webhook receiver uses **four layers** of defense. No single layer is the
sole gatekeeper — compromise of one layer does not grant access.

### Layer 1: Cloudflare Tunnel (Transport)

- TLS termination — payloads encrypted in transit
- DDoS mitigation and bot filtering
- The gateway never binds to a public IP; Cloudflare Tunnel dials out
- Optional: Cloudflare WAF rules to block non-POST, wrong content-type, etc.
- **Not an authentication layer** — provides transport security only

### Layer 2: Unguessable Endpoint ID (Path Token)

Each webhook endpoint gets a random, unguessable identifier:

```
POST /hooks/whk_7f3a9b2c4e1d8f6a5b0c3e7d9f1a2b4c
```

- 128-bit random hex (32 chars) prefixed with `whk_` for identification
- Acts as a **first-line filter**: scanners, bots, and accidental requests
  are rejected before any crypto is performed
- NOT sufficient as sole authentication (URLs appear in logs, monitoring,
  error messages, Cloudflare analytics, Referer headers, etc.)
- Cheap to validate: O(1) ETS/map lookup

### Layer 3: HMAC Signature Verification (Authentication)

The real authentication layer. Each endpoint has a signing secret; the sender
must include a signature header computed over the request body:

```
X-Webhook-Signature: sha256=<hex(HMAC-SHA256(signing_secret, body))>
```

**Why HMAC over path-only auth:**

| Concern               | Path token only         | HMAC signature           |
|-----------------------|-------------------------|--------------------------|
| Secret in logs?       | Yes (URL logged everywhere) | No (secret never sent) |
| Payload integrity?    | No                      | Yes (body is signed)     |
| Replay protection?    | No                      | Yes (with timestamp)     |
| Rotation?             | Downtime required       | Dual-secret window       |
| Sender impersonation? | Easy (copy URL)         | Requires secret          |

**Verification algorithm:**

```
1. Extract X-Webhook-Signature header → "sha256=<received_hex>"
2. Extract X-Webhook-Timestamp header → timestamp_str
3. Reject if timestamp is outside ±5 minute window (replay protection)
4. Compute: expected = hex(HMAC-SHA256(signing_secret, timestamp_str <> "." <> raw_body))
5. Constant-time compare received_hex vs expected
6. Reject if mismatch
```

The timestamp is included in the signed material to prevent replay attacks —
a captured request cannot be replayed after the window expires.

**Compatibility note:** Many webhook providers (GitHub, Stripe, Slack) send
their own signature headers. The receiver should support **provider-specific
verification modes** alongside the default TriOnyx scheme:

| Provider | Header                    | Algorithm           |
|----------|---------------------------|---------------------|
| Default  | `X-Webhook-Signature`     | HMAC-SHA256 + timestamp |
| GitHub   | `X-Hub-Signature-256`     | HMAC-SHA256 of body |
| Stripe   | `Stripe-Signature`        | HMAC-SHA256 + timestamp |
| Slack    | `X-Slack-Signature`       | HMAC-SHA256 + timestamp |
| None     | *(skip verification)*     | Path token only     |

The `None` mode exists for providers that don't support signing. In this mode,
the path token becomes the sole authentication — the endpoint should be flagged
as reduced-security in the audit log and the operator should be warned at
registration time.

### Layer 4: Rate Limiting

Per-endpoint, per-source-IP rate limiting to bound abuse even with valid credentials:

- Default: 60 requests/minute per endpoint per source IP
- Configurable per endpoint
- Uses a token bucket algorithm (GenServer or ETS-based)
- Returns `429 Too Many Requests` with `Retry-After` header

## Data Model

### WebhookEndpoint

A webhook endpoint is a persistent configuration object stored in the gateway.

```elixir
defmodule TriOnyx.WebhookEndpoint do
  @type t :: %__MODULE__{
    id: String.t(),                    # "whk_<32 hex chars>"
    label: String.t(),                 # Human-readable name, e.g. "github-push"
    agents: [String.t()],             # Bound agent names (fan-out)
    signing_secret: String.t(),       # HMAC signing secret (generated)
    signing_mode: signing_mode(),     # :default | :github | :stripe | :slack | :none
    enabled: boolean(),               # Soft disable without deleting
    rate_limit: pos_integer(),        # Requests per minute per source IP
    allowed_ips: [String.t()] | nil,  # Optional IP allowlist (nil = any)
    created_at: DateTime.t(),
    rotated_at: DateTime.t() | nil,   # Last secret rotation
    previous_secret: String.t() | nil # Old secret during rotation window
  }

  @type signing_mode :: :default | :github | :stripe | :slack | :none
end
```

### Storage

Webhook endpoints are stored in a JSON file at `~/.tri-onyx/webhooks.json`,
loaded into an ETS table at startup by a `WebhookRegistry` GenServer. This
mirrors the pattern used by `AuditLog` for file-based persistence.

```json
[
  {
    "id": "whk_7f3a9b2c4e1d8f6a5b0c3e7d9f1a2b4c",
    "label": "github-push",
    "agents": ["code-reviewer"],
    "signing_secret": "<encrypted or raw — see Key Management>",
    "signing_mode": "github",
    "enabled": true,
    "rate_limit": 60,
    "allowed_ips": null,
    "created_at": "2026-02-15T12:00:00Z"
  }
]
```

### Key Management

Signing secrets should be generated with `:crypto.strong_rand_bytes(32)` and
stored as hex. For the initial implementation, secrets are stored in plaintext
in the webhooks.json file (the file should be permission-restricted to `0600`).
A future iteration can encrypt at rest using a master key derived from an
environment variable.

## API Endpoints

### Webhook Ingress (Internet-Facing)

```
POST /hooks/:endpoint_id
```

This is the only endpoint exposed through the Cloudflare Tunnel. All other
management endpoints remain on the local-only port 4000.

**Request:**
```http
POST /hooks/whk_7f3a9b2c4e1d8f6a5b0c3e7d9f1a2b4c HTTP/1.1
Content-Type: application/json
X-Webhook-Signature: sha256=a1b2c3d4...
X-Webhook-Timestamp: 1739577600

{"event": "push", "ref": "refs/heads/main", ...}
```

**Responses:**

| Status | Meaning                                         |
|--------|-------------------------------------------------|
| 202    | Accepted — dispatched to agent(s)               |
| 400    | Invalid JSON or missing required headers        |
| 401    | Invalid or missing signature                    |
| 404    | Unknown endpoint ID (no timing leak — constant) |
| 408    | Timestamp outside replay window                 |
| 413    | Payload too large (>1 MB)                       |
| 429    | Rate limit exceeded                             |

**Important:** The 404 response for unknown endpoint IDs must use constant-time
behavior — always perform the same amount of work regardless of whether the ID
exists, to prevent endpoint enumeration via timing side-channels. In practice:
look up the endpoint, if not found, still compute a dummy HMAC before returning.

### Management Endpoints (Local Only)

These endpoints are served on the existing port 4000 (not exposed through the
tunnel). They allow the operator to manage webhook endpoints.

```
GET    /webhook-endpoints                    # List all endpoints
POST   /webhook-endpoints                    # Create new endpoint
GET    /webhook-endpoints/:id                # Get endpoint details
PUT    /webhook-endpoints/:id                # Update endpoint
DELETE /webhook-endpoints/:id                # Delete endpoint
POST   /webhook-endpoints/:id/rotate-secret  # Rotate signing secret
GET    /webhook-endpoints/:id/deliveries     # Recent delivery log
```

#### Create Endpoint

```http
POST /webhook-endpoints
Content-Type: application/json

{
  "label": "github-push",
  "agents": ["code-reviewer"],
  "signing_mode": "github",
  "rate_limit": 60,
  "allowed_ips": ["140.82.112.0/20"]
}
```

**Response (201):**
```json
{
  "id": "whk_7f3a9b2c4e1d8f6a5b0c3e7d9f1a2b4c",
  "label": "github-push",
  "agents": ["code-reviewer"],
  "signing_secret": "e3b0c44298fc1c149afbf4c8996fb924...",
  "signing_mode": "github",
  "enabled": true,
  "rate_limit": 60,
  "webhook_url": "https://<tunnel>/hooks/whk_7f3a9b2c4e1d8f6a5b0c3e7d9f1a2b4c",
  "created_at": "2026-02-15T12:00:00Z"
}
```

The `signing_secret` is returned ONLY on creation and rotation. It is never
returned in GET responses (write-once, display-once pattern).

#### Rotate Secret

```http
POST /webhook-endpoints/whk_7f3a9b2c4e1d8f6a5b0c3e7d9f1a2b4c/rotate-secret
```

**Response (200):**
```json
{
  "new_secret": "d7a8fbb307d7809469ca9abcb0082e4f...",
  "previous_secret_valid_until": "2026-02-15T13:00:00Z",
  "message": "Both old and new secrets will be accepted for 1 hour"
}
```

During the rotation window, both the old and new secrets are accepted. This
allows the sender to be updated without downtime.

## Elixir Module Structure

```
lib/tri_onyx/
├── webhook_endpoint.ex          # Struct + validation
├── webhook_registry.ex          # GenServer — ETS-backed endpoint store
├── webhook_receiver.ex          # Plug pipeline for /hooks/:id
├── webhook_signature.ex         # HMAC verification (multi-provider)
├── webhook_rate_limiter.ex      # Token bucket rate limiter
└── triggers/
    └── webhook.ex               # (existing — updated to accept endpoint metadata)
```

### WebhookRegistry (GenServer)

- Owns an ETS table (`:webhook_endpoints`, `:set`, `read_concurrency: true`)
- Loads from `~/.tri-onyx/webhooks.json` on init
- Persists on every mutation (create/update/delete/rotate)
- Added to the supervision tree after `AuditLog`, before `TriggerRouter`
- Public API: `lookup/1`, `create/1`, `update/2`, `delete/1`, `rotate_secret/1`, `list/0`
- `lookup/1` is a direct ETS read (no GenServer call) for hot-path performance

### WebhookReceiver (Plug)

The ingress pipeline, mounted in the Router at `/hooks/:endpoint_id`:

```elixir
post "/hooks/:endpoint_id" do
  # 1. Lookup endpoint (ETS — no GenServer bottleneck)
  # 2. Check enabled
  # 3. Check rate limit
  # 4. Check IP allowlist (if configured)
  # 5. Verify signature (provider-specific)
  # 6. Validate payload (size, JSON)
  # 7. Fan-out dispatch to all bound agents via TriggerRouter
  # 8. Audit log the delivery
  # 9. Return 202
end
```

### WebhookSignature

Pure module with verification functions per provider:

```elixir
defmodule TriOnyx.WebhookSignature do
  @spec verify(signing_mode, secret, raw_body, headers) :: :ok | {:error, reason}

  # :default — X-Webhook-Signature + X-Webhook-Timestamp
  # :github  — X-Hub-Signature-256 (HMAC-SHA256 of body)
  # :stripe  — Stripe-Signature (HMAC-SHA256 + timestamp)
  # :slack   — X-Slack-Signature (HMAC-SHA256 + timestamp)
  # :none    — always passes (path token is sole auth)
end
```

All comparisons use `:crypto.hash_equals/2` (constant-time).

## Integration with Existing Systems

### TriggerRouter

No changes needed to `TriggerRouter.dispatch/2`. The webhook receiver constructs
the same trigger event shape that the current `Webhook.handle/3` produces:

```elixir
%{
  type: :webhook,
  agent_name: agent_name,
  payload: body,
  metadata: %{
    endpoint_id: endpoint.id,
    endpoint_label: endpoint.label,
    signing_mode: endpoint.signing_mode,
    source_ip: source_ip,
    received_at: DateTime.utc_now() |> DateTime.to_iso8601(),
    content_type: "application/json"
  }
}
```

For fan-out (one endpoint bound to multiple agents), the receiver dispatches
one event per agent. Each agent gets its own session, its own taint status.

### InformationClassifier

No changes needed. Webhook triggers already classify as high taint. The
metadata now carries richer context (endpoint_id, source_ip) for audit
purposes, but the taint classification is unchanged.

### AuditLog

Webhook deliveries are logged as existing `trigger` audit events. The
additional metadata (endpoint_id, source_ip, signature_valid) is included
in the event payload for forensic analysis.

### Supervision Tree

Updated startup order in `application.ex`:

```
1. AuditLog
2. EventBus.Registry
3. WebhookRegistry          ← NEW (must start before Router)
4. WebhookRateLimiter       ← NEW
5. AgentSupervisor
6. TriggerRouter
7. Scheduler
8. ConnectorRegistry
9. Bandit HTTP Server
```

## Cloudflare Tunnel Configuration

The Cloudflare Tunnel should be configured to forward ONLY the webhook
ingress path to the gateway. All management endpoints stay local-only.

```yaml
# cloudflared config.yml
tunnel: tri-onyx-webhooks
credentials-file: /etc/cloudflared/credentials.json

ingress:
  # Only expose the webhook ingress path
  - hostname: hooks.example.com
    path: /hooks/*
    service: http://localhost:4000
    originRequest:
      noTLSVerify: true
  # Block everything else
  - service: http_status:404
```

This ensures that even if the tunnel hostname is known, only `/hooks/*` is
reachable. The management API, SSE streams, WebSocket connectors, and all
other endpoints remain accessible only from localhost.

## Migration from Current Webhook Endpoint

The existing `POST /webhooks/:agent_name` endpoint should be **deprecated
but kept** during migration:

1. Add a deprecation warning log on each call
2. Document the new `/hooks/:endpoint_id` path as the replacement
3. Remove `POST /webhooks/:agent_name` in a future release

The old endpoint uses agent name as the identifier with no auth — it should
never be exposed through the tunnel.

## What This Design Does NOT Cover (Future Work)

- **Webhook delivery retries (outbound):** This is an inbound-only receiver.
  If TriOnyx needs to send webhooks, that's a separate design.
- **Payload schema validation per endpoint:** The receiver validates JSON
  structure but does not enforce provider-specific schemas. Agent prompts
  can extract what they need.
- **Encryption at rest for secrets:** The initial implementation stores
  secrets in plaintext in a permission-restricted file. A future iteration
  can use envelope encryption.
- **Webhook delivery log with response/retry tracking:** The audit log
  captures delivery events, but there's no dedicated UI for browsing them.
  The `GET /webhook-endpoints/:id/deliveries` endpoint is a wrapper around
  the audit log filtered by endpoint ID.

## Implementation Order

1. `WebhookEndpoint` struct + validation
2. `WebhookRegistry` GenServer + ETS + JSON persistence
3. `WebhookSignature` verification module (default + GitHub modes first)
4. `WebhookRateLimiter` (ETS-based token bucket)
5. `WebhookReceiver` plug + Router integration
6. Management API endpoints in Router
7. Supervision tree wiring
8. Tests (unit for signature verification, integration for full pipeline)
9. Cloudflare Tunnel configuration documentation
