FROM python:3.12-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    libolm-dev \
    ffmpeg \
    && rm -rf /var/lib/apt/lists/*

COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

WORKDIR /app

COPY connector/pyproject.toml ./
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --no-install-project

COPY connector/connector/ ./connector/

ENV TRI_ONYX_CONNECTOR_CONFIG=/app/config.yaml

CMD ["uv", "run", "python", "-m", "connector.main"]
