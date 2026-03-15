# Agent container image for TriOnyx
#
# Runs Python agents using the Claude Agent SDK inside a sandboxed
# environment with FUSE-based filesystem access control.
#
# Runtime requirements:
#   docker run --device /dev/fuse --cap-drop ALL --cap-add SYS_ADMIN ...
#   (add --cap-add NET_ADMIN for network policy enforcement)

# --- Build stages ---

# Node.js runtime for playwright-cli
FROM node:22-slim AS node-base

# Install playwright-cli npm dependencies in an isolated stage so npm
# is not present in the final image.
FROM node-base AS playwright-cli-deps
COPY playwright-cli/package.json playwright-cli/package-lock.json /opt/playwright-cli/
WORKDIR /opt/playwright-cli
RUN npm ci --production

# --- Final image ---

FROM python:3.12-slim

# Install FUSE3 for the tri-onyx-fs driver, iptables for optional
# network policy enforcement, tini as a minimal init process, and gosu
# for dropping root privileges after sandbox setup.
RUN apt-get update && apt-get install -y --no-install-recommends \
      fuse3 \
      libfuse3-dev \
      iptables \
      tini \
      gosu \
      # Playwright/Chromium system dependencies
      libnss3 libnspr4 libatk1.0-0 libatk-bridge2.0-0 \
      libatspi2.0-0 libdbus-1-3 libdrm2 libxcomposite1 \
      libxdamage1 libxfixes3 libxrandr2 libgbm1 libxcb1 \
      libxkbcommon0 libx11-6 libx11-xcb1 libxext6 libasound2 \
      libexpat1 libcups2 libpango-1.0-0 libcairo2 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Install the Docker CLI (static binary) for agents with docker_socket access.
# Only the CLI is needed — the daemon runs on the host.
ADD https://download.docker.com/linux/static/stable/x86_64/docker-27.5.1.tgz /tmp/docker.tgz
RUN tar -xzf /tmp/docker.tgz --strip-components=1 -C /usr/local/bin docker/docker \
    && rm /tmp/docker.tgz

# Allow non-root FUSE mounts (the entrypoint runs as root for FUSE/iptables,
# but this ensures fuse3 works correctly inside the container).
RUN echo "user_allow_other" >> /etc/fuse.conf

# Create a dedicated non-root user for running the agent process.
# The entrypoint drops privileges to this user after FUSE mount and
# iptables setup (which require root).
# Default UID/GID 1000 matches the typical host user so bind-mounted
# directories (e.g. browser session profiles) are accessible without
# sudo chown.
ARG HOST_UID=1000
ARG HOST_GID=1000
RUN groupadd -g $HOST_GID tri_onyx \
    && useradd -u $HOST_UID -g tri_onyx -d /home/tri_onyx -s /bin/bash tri_onyx \
    && mkdir -p /home/tri_onyx && chown tri_onyx:tri_onyx /home/tri_onyx

# Install UV for running the agent script with inline dependencies.
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

# Copy the FUSE driver binary.
COPY fuse/tri-onyx-fs /usr/local/bin/tri-onyx-fs
RUN chmod +x /usr/local/bin/tri-onyx-fs

# Copy the Python agent runtime and browser stealth script.
COPY runtime/agent_runner.py runtime/protocol.py runtime/browser-stealth.js /opt/tri_onyx/

# Pre-install the inline script dependencies into UV's cache so that
# `uv run --script` at runtime is a cache hit with no network required.
# The script exits immediately (stdin is empty → EOF → shutdown), but the
# dependencies are resolved and cached. Use a shared cache directory that
# the non-root agent user can access after privilege dropping.
ENV UV_CACHE_DIR=/opt/uv-cache
RUN uv run --script /opt/tri_onyx/agent_runner.py < /dev/null 2>&1 || true

ENV PLAYWRIGHT_BROWSERS_PATH=/opt/playwright-browsers

# Install Node.js (runtime only, no npm) and playwright-cli.
# The CLI delegates to Playwright's built-in client; node_modules were
# pre-installed in the playwright-cli-deps build stage.
COPY --from=node-base /usr/local/bin/node /usr/local/bin/node
COPY playwright-cli/playwright-cli.js /opt/playwright-cli/playwright-cli.js
COPY --from=playwright-cli-deps /opt/playwright-cli/node_modules /opt/playwright-cli/node_modules
RUN chmod +x /opt/playwright-cli/playwright-cli.js \
    && ln -s /opt/playwright-cli/playwright-cli.js /usr/local/bin/playwright-cli

# Install Chromium using the Node.js playwright package so the browser
# revision matches what playwright-cli expects at runtime.
RUN node /opt/playwright-cli/node_modules/playwright/cli.js install chromium \
    && chown -R tri_onyx:tri_onyx /opt/playwright-browsers

# Create the browser sessions directory for pre-authenticated profiles.
RUN mkdir -p /home/tri_onyx/.browser-sessions \
    && chown tri_onyx:tri_onyx /home/tri_onyx/.browser-sessions

RUN chown -R tri_onyx:tri_onyx /opt/uv-cache

# Copy the container entrypoint.
COPY runtime/entrypoint.sh /opt/tri_onyx/entrypoint.sh
RUN chmod +x /opt/tri_onyx/entrypoint.sh

# Create the FUSE mountpoint and bind mount target.
RUN mkdir -p /workspace /mnt/host /etc/tri_onyx

WORKDIR /workspace

# Use tini as PID 1 to handle signal forwarding and zombie reaping.
ENTRYPOINT ["tini", "--", "/opt/tri_onyx/entrypoint.sh"]
