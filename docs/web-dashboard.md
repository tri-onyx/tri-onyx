# Web Dashboard

The dashboard is a Django application (in `frontend/`) that runs as the `frontend` service in Docker Compose and is served at `http://127.0.0.1:8080`. It holds no state of its own — every page is rendered from the gateway's HTTP API (the frontend queries the gateway for agents, schema, approvals, and graph analysis at request time), and the chat view subscribes to the gateway's server-sent event stream for live session output.

## Views

### Dashboard (`/`)

Agent overview and system status. A summary strip shows total/running/idle agent counts, gateway health, pending approval count, and whether heartbeat dispatch is enabled. Below it, a grid lists every registered agent with its current session status, sorted so active agents come first. The page polls for updates via HTMX partials.

### Graph (`/graph/`)

Agent topology visualization. Renders the agents and the gateway's graph analysis (transitive taint and sensitivity propagation, see [ADR-009](https://github.com/tri-onyx/tri-onyx/blob/main/adr/009-graph-analysis-transitive-risk.md)) so you can see how information flows between agents and where risk accumulates.

### Agent Builder (`/builder/`, `/builder/<name>/`)

Create and edit agent definitions. The form is rendered dynamically from the gateway's agent schema endpoint — fields, tool groups, known tools, and known agents all come from the gateway, so the builder never hardcodes them. Existing agents can be edited, deleted, and inspected (rendered system prompt context and overview).

### Agent Chat (`/agents/<name>/`)

Per-agent chat and session view. Start a session, send prompts, and watch the live event stream (tool calls, results, and output arrive over the gateway's SSE stream). Historical sessions can be browsed with `?session=<id>`, sessions can be stopped from the page, and tool calls are rendered as compact briefs. Images and pages produced during a session are served through the frontend.

### Approvals

Pending [BCP](bcp.md) approvals appear as a badge in the navigation bar on every page, with a dropdown to approve or deny items inline.

## Gateway API

The dashboard is a client of the gateway, not a replacement for it. The gateway's HTTP API remains directly accessible at `http://localhost:4000` — see the [API Reference](api-reference.md).
