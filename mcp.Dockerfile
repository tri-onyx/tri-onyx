# Public MCP entry point for claude.ai custom connectors.
#
# Deliberately minimal: no docker socket, no workspace mounts, no gateway
# source. It talks to the gateway over the connector WebSocket only, and to the
# internet only through the cloudflared sidecar.
FROM python:3.12-slim

COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

# Must match the uid/gid owning ./secrets/mcp-data on the host so the OAuth
# store survives restarts (same convention as the agent image).
ARG HOST_UID=1000
ARG HOST_GID=1000

RUN groupadd -g "${HOST_GID}" mcp 2>/dev/null || true \
    && useradd -u "${HOST_UID}" -g "${HOST_GID}" -m -s /usr/sbin/nologin mcp 2>/dev/null || true

WORKDIR /app

ENV UV_PROJECT_ENVIRONMENT=/app/.venv \
    UV_LINK_MODE=copy \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

# --locked: the committed lockfile is the only dependency source of truth —
# the build fails rather than silently re-resolving the OAuth stack.
COPY mcp_server/pyproject.toml mcp_server/uv.lock ./
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --locked --no-install-project

# The connector package supplies the gateway wire protocol and client; the MCP
# server never re-implements them.
COPY connector/connector/ ./connector/
COPY mcp_server/mcp_server/ ./mcp_server/
COPY mcp_server/tests/ ./tests/

RUN mkdir -p /data && chown -R "${HOST_UID}:${HOST_GID}" /app /data

ENV TRI_ONYX_MCP_CONFIG=/app/config.yaml \
    PATH="/app/.venv/bin:${PATH}"

USER ${HOST_UID}:${HOST_GID}

EXPOSE 8765

CMD ["uv", "run", "--no-sync", "python", "-m", "mcp_server.main"]
