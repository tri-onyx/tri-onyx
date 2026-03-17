# API Reference

The gateway exposes an HTTP API at `http://localhost:4000` for managing agents, triggers, observability, and approvals.

## Agents

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/agents` | List agents with risk scores |
| `GET` | `/agents/:name` | Agent detail with taint status |
| `POST` | `/agents/:name/start` | Start an agent session |
| `POST` | `/agents/:name/stop` | Stop an agent session |
| `POST` | `/agents/:name/prompt` | Send prompt to running agent |
| `GET` | `/agents/:name/events` | SSE stream of agent events |

## Triggers

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/hooks/:endpoint_id` | Authenticated webhook ingress (internet-facing) |
| `POST` | `/messages` | External message with Bearer token auth |

## Webhook endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/webhook-endpoints` | List webhook endpoints |
| `POST` | `/webhook-endpoints` | Create webhook endpoint |
| `GET` | `/webhook-endpoints/:id` | Webhook endpoint detail |
| `PUT` | `/webhook-endpoints/:id` | Update webhook endpoint |
| `DELETE` | `/webhook-endpoints/:id` | Delete webhook endpoint |
| `POST` | `/webhook-endpoints/:id/rotate-secret` | Rotate signing secret |

## BCP approvals

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/bcp/approvals` | List pending BCP approval items |
| `POST` | `/bcp/approvals/:id/approve` | Approve a pending BCP item |
| `POST` | `/bcp/approvals/:id/reject` | Reject a pending BCP item |

## Action approvals

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/actions/approvals` | List pending action approval items |
| `POST` | `/actions/approvals/:id/approve` | Approve a pending action |
| `POST` | `/actions/approvals/:id/reject` | Reject a pending action |

## Observability

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/graph/analysis` | Graph analysis with risk propagation |
| `GET` | `/api/matrix` | Classification matrix (taint, sensitivity, capability) |
| `GET` | `/audit?since=YYYY-MM-DD` | Query audit log |
| `GET` | `/logs` | List agents with session logs |
| `GET` | `/logs/:agent_name` | List sessions for an agent |
| `GET` | `/logs/:agent_name/:session_id` | Session log (JSONL) |
| `GET` | `/health` | Health check |

## Connectors

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/connectors/ws` | WebSocket upgrade for external connectors |
| `GET` | `/connectors` | List active connectors |

## Heartbeats

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/heartbeats` | List heartbeat schedules |
| `PUT` | `/heartbeats/enabled` | Enable/disable heartbeat scheduler |
| `POST` | `/heartbeats/:agent_name` | Schedule heartbeat for agent |
| `DELETE` | `/heartbeats/:agent_name` | Cancel heartbeat for agent |

## Human review

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/review` | Mark artifacts as human-reviewed (resets taint) |
