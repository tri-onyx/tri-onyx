#!/usr/bin/env bash
# TriOnyx agent container entrypoint
#
# The container's filesystem access is fully defined by its bind mounts
# (the gateway mounts exactly the repo working trees this agent is granted,
# rw or ro — see TriOnyx.Sandbox). There is no in-container filesystem
# policy: the mount set is the ACL.
#
# Startup sequence:
#   1. Install plugin Python dependencies (network still unrestricted)
#   2. Apply iptables network policy
#   3. (Optional) Configure browser capability
#   4. Drop root privileges via gosu and exec the agent runner
#
# Required environment variables:
#   TRI_ONYX_NETWORK_POLICY — "none", "outbound", or comma-separated
#                                host[:port] allowlist

set -euo pipefail

log() {
    echo "[entrypoint] $*" >&2
}

die() {
    log "FATAL: $*"
    exit 1
}

if [ -n "${TRI_ONYX_MODE:-}" ]; then
    log "TRI_ONYX_MODE=${TRI_ONYX_MODE}"
fi

# -----------------------------------------------------------------------
# 1. Install plugin Python dependencies
# -----------------------------------------------------------------------
# Plugins with a pyproject.toml need their dependencies available in the
# container. TRI_ONYX_PLUGIN_PATHS is a comma-separated list of
# name=container-path pairs pointing into the mounted repo trees. Install
# BEFORE network lockdown so PyPI is still reachable.
#
# The plugin directory is an agent-writable mount, so nothing from it is
# ever handed to the installer as a build target — that would execute the
# plugin's own build backend, here, as root. Instead:
#   * only the declared [project].dependencies are installed (parsed with
#     tomllib — no plugin code runs),
#   * --only-binary :all: keeps a malicious *dependency* from running an
#     sdist build hook either,
#   * the install runs as tri_onyx into a user-owned directory that is put
#     on PYTHONPATH/PATH for the agent process below.
# Consequence: a plugin that is also an installable package does not get
# its console scripts. Plugin code is run from its mount (`uv run
# /workspace/plugins/<p>/...`) or imported via PYTHONPATH.

PLUGIN_SITE="/home/tri_onyx/.plugin-site"

plugin_dependencies() {
    # Print one PEP 508 requirement per line from [project].dependencies.
    python3 - "$1" <<'PYEOF'
import sys, tomllib

with open(sys.argv[1], "rb") as fh:
    project = tomllib.load(fh).get("project") or {}
for dep in project.get("dependencies") or []:
    if isinstance(dep, str) and dep.strip():
        print(dep.strip())
PYEOF
}

if [ -n "${TRI_ONYX_PLUGIN_PATHS:-}" ]; then
    mkdir -p "$PLUGIN_SITE"
    chown tri_onyx:tri_onyx "$PLUGIN_SITE"

    IFS=',' read -ra PLUGIN_ENTRIES <<< "$TRI_ONYX_PLUGIN_PATHS"
    for entry in "${PLUGIN_ENTRIES[@]}"; do
        plugin="${entry%%=*}"
        plugin_path="${entry#*=}"
        [ -f "${plugin_path}/pyproject.toml" ] || continue

        if ! dep_lines=$(plugin_dependencies "${plugin_path}/pyproject.toml" 2>&1); then
            log "WARNING: cannot read dependencies of plugin '${plugin}', skipping"
            log "  ${dep_lines}"
            continue
        fi

        deps=()
        while IFS= read -r dep; do
            [ -n "$dep" ] && deps+=("$dep")
        done <<< "$dep_lines"

        if [ ${#deps[@]} -eq 0 ]; then
            log "Plugin '${plugin}' declares no dependencies, nothing to install"
            continue
        fi

        log "Installing ${#deps[@]} declared dep(s) for plugin '${plugin}' into ${PLUGIN_SITE}"
        gosu tri_onyx uv pip install \
            --python /usr/local/bin/python3 \
            --target "$PLUGIN_SITE" \
            --only-binary :all: \
            "${deps[@]}" 2>&1 | while read -r line; do log "  $line"; done
    done
fi

# -----------------------------------------------------------------------
# 1.5. Ensure Playwright browsers match the Python playwright package
# -----------------------------------------------------------------------
# The Docker image pre-installs Chromium for the Node.js playwright-cli,
# but plugins may use the Python playwright package which tracks a
# different browser revision. Install any missing browsers now, while
# network is still unrestricted. If browsers already match, this is a
# fast no-op.

if [ "${TRI_ONYX_BROWSER:-}" = "true" ]; then
    log "Ensuring Python Playwright browsers are installed"
    uv run --with playwright playwright install chromium 2>&1 | while read -r line; do log "  $line"; done || true
    chown -R tri_onyx:tri_onyx /opt/playwright-browsers 2>/dev/null || true
    chown -R tri_onyx:tri_onyx /opt/uv-cache 2>/dev/null || true
fi

# -----------------------------------------------------------------------
# 2. Network policy
# -----------------------------------------------------------------------

if [ -z "${TRI_ONYX_NETWORK_POLICY:-}" ]; then
    die "TRI_ONYX_NETWORK_POLICY environment variable is not set"
fi
NETWORK_POLICY="$TRI_ONYX_NETWORK_POLICY"

# The Claude API endpoint is always allowed — the agent runtime needs it
# for LLM inference regardless of the tool network policy.
CLAUDE_API_HOST="api.anthropic.com"

# Only allow DNS to the nameservers already configured in the container.
# This prevents DNS exfiltration to attacker-controlled servers while
# supporting both Docker's embedded resolver (127.0.0.11 on user-defined
# networks) and host-inherited resolvers (default bridge).
CONFIGURED_DNS=$(grep -oP '(?<=^nameserver )\S+' /etc/resolv.conf || true)
if [ -z "$CONFIGURED_DNS" ]; then
    die "No nameservers found in /etc/resolv.conf"
fi

apply_base_iptables() {
    iptables -A OUTPUT -o lo -j ACCEPT
    iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    for ns in $CONFIGURED_DNS; do
        iptables -A OUTPUT -p udp -d "$ns" --dport 53 -j ACCEPT
        iptables -A OUTPUT -p tcp -d "$ns" --dport 53 -j ACCEPT
    done
}

allow_host() {
    local entry="$1"
    entry=$(echo "$entry" | xargs)  # trim whitespace
    [ -z "$entry" ] && return

    # Parse optional port: "host:port" or just "host".
    if [[ "$entry" == *:* ]]; then
        local host="${entry%:*}"
        local port="${entry##*:}"
    else
        local host="$entry"
        local port=""
    fi

    # Skip wildcard patterns — iptables cannot handle them directly.
    if [[ "$host" == *"*"* ]]; then
        log "WARNING: Wildcard host pattern '$host' cannot be enforced via iptables, skipping"
        return
    fi

    if [ -n "$port" ]; then
        iptables -A OUTPUT -p tcp -d "$host" --dport "$port" -j ACCEPT
        log "  allow: $host:$port"
    else
        iptables -A OUTPUT -p tcp -d "$host" -j ACCEPT
        log "  allow: $host (all ports)"
    fi
}

if [ "$NETWORK_POLICY" = "outbound" ]; then
    log "Network policy: outbound (unrestricted)"
elif [ "$NETWORK_POLICY" = "none" ]; then
    # Block all outbound traffic except the Claude API.
    log "Network policy: none — allowing only Claude API"
    apply_base_iptables
    allow_host "$CLAUDE_API_HOST"
    # If DOCKER_HOST is set, allow the Docker socket proxy through iptables.
    if [ -n "${DOCKER_HOST:-}" ]; then
        # Extract host:port from tcp://host:port
        DOCKER_PROXY_ADDR="${DOCKER_HOST#tcp://}"
        allow_host "$DOCKER_PROXY_ADDR"
    fi
    iptables -A OUTPUT -j DROP
    log "Network policy applied: only $CLAUDE_API_HOST reachable"
else
    # Host allowlist — apply iptables rules to restrict outbound traffic.
    log "Network policy: allowlist — applying iptables rules"
    apply_base_iptables

    # Always allow the Claude API.
    allow_host "$CLAUDE_API_HOST"

    # Allow each host in the comma-separated list.
    IFS=',' read -ra HOSTS <<< "$NETWORK_POLICY"
    for entry in "${HOSTS[@]}"; do
        allow_host "$entry"
    done

    # If DOCKER_HOST is set, allow the Docker socket proxy through iptables.
    if [ -n "${DOCKER_HOST:-}" ]; then
        DOCKER_PROXY_ADDR="${DOCKER_HOST#tcp://}"
        allow_host "$DOCKER_PROXY_ADDR"
    fi

    # Drop everything else.
    iptables -A OUTPUT -j DROP
    log "Network policy applied: all other outbound traffic dropped"
fi

# -----------------------------------------------------------------------
# 3. Browser capability (playwright-cli)
# -----------------------------------------------------------------------

if [ "${TRI_ONYX_BROWSER:-}" = "true" ]; then
    AGENT_NAME="${TRI_ONYX_AGENT_NAME:?TRI_ONYX_AGENT_NAME is required for browser capability}"

    # Ensure browser sessions directory exists and is fully owned by
    # tri_onyx. The directory is bind-mounted from the host where files
    # are typically owned by UID 1000. Chromium profile directories
    # (e.g. Default/) are created with drwx------ permissions, so a UID
    # mismatch locks tri_onyx out entirely — causing the browser to fall
    # back to an in-memory profile and losing the authenticated session.
    # Recursive chown while still running as root fixes this.
    mkdir -p /home/tri_onyx/.browser-sessions
    chown -R tri_onyx:tri_onyx /home/tri_onyx/.browser-sessions 2>/dev/null || true
    chmod -R u+rwX,g+rX,o+rX /home/tri_onyx/.browser-sessions 2>/dev/null || true

    # Create snapshot output directory inside the agent's own repo tree
    # (mounted rw at /workspace) so the agent can read snapshots via the
    # Read tool.
    BROWSER_OUTPUT_DIR="/workspace/.playwright-cli"
    mkdir -p "$BROWSER_OUTPUT_DIR"
    chown tri_onyx:tri_onyx "$BROWSER_OUTPUT_DIR" 2>/dev/null || true

    # Copy the browser stealth init script to a path the tri_onyx user can
    # read.  This JS is injected before any page script executes to hide
    # common headless/automation fingerprint signals.
    cp /opt/tri_onyx/browser-stealth.js /home/tri_onyx/.browser-stealth.js
    chown tri_onyx:tri_onyx /home/tri_onyx/.browser-stealth.js

    # Generate playwright-cli config in the tri_onyx home directory. The
    # wrapper script passes --config.
    CONFIG_PATH="/home/tri_onyx/.playwright-cli.config.json"
    cat > "$CONFIG_PATH" <<PCEOF
{
  "browser": {
    "browserName": "chromium",
    "isolated": false,
    "userDataDir": "/home/tri_onyx/.browser-sessions",
    "initScript": ["/home/tri_onyx/.browser-stealth.js"],
    "launchOptions": {
      "channel": "chromium",
      "args": [
        "--no-sandbox",
        "--disable-setuid-sandbox",
        "--disable-dev-shm-usage",
        "--disable-blink-features=AutomationControlled",
        "--window-size=1920,1080",
        "--disable-background-networking",
        "--disable-breakpad",
        "--disable-client-side-phishing-detection",
        "--disable-sync",
        "--disable-default-apps",
        "--metrics-recording-only",
        "--no-first-run",
        "--no-default-browser-check",
        "--mute-audio"
      ]
    },
    "contextOptions": {
      "viewport": {"width": 1920, "height": 1080},
      "locale": "en-US"
    }
  },
  "outputDir": "${BROWSER_OUTPUT_DIR}"
}
PCEOF
    chown tri_onyx:tri_onyx "$CONFIG_PATH" 2>/dev/null || true

    # Create a convenience wrapper so agents call `browser <cmd>` instead
    # of `playwright-cli --config=... <cmd>`.
    cat > /usr/local/bin/browser <<'BEOF'
#!/bin/sh
exec playwright-cli --config=/home/tri_onyx/.playwright-cli.config.json "$@"
BEOF
    chmod +x /usr/local/bin/browser

    log "Browser capability configured (output=$BROWSER_OUTPUT_DIR)"
fi

# -----------------------------------------------------------------------
# 4. Drop privileges
# -----------------------------------------------------------------------

# GitHub clones under /github and /github-ro are created by the gateway
# (possibly as a different UID); git refuses to operate on repos with
# mismatched ownership unless marked safe. Mark exactly those clones —
# `safe.directory '*'` would also cover every future mount and any repo
# the agent can create itself.
if command -v git >/dev/null 2>&1; then
    for clone in /github/*/* /github-ro/*/*; do
        [ -d "$clone" ] || continue
        gosu tri_onyx git config --global --add safe.directory "$clone" || true
    done
fi

# Dependencies of pyproject-based plugins were installed into a
# tri_onyx-owned directory (see section 1); make them importable and their
# console scripts runnable for the agent and every tool subprocess.
# Caveat: PYTHONPATH takes precedence over site-packages, so a plugin that
# declares a dependency the runner also uses (pydantic, httpx, mcp, …) will
# shadow the version `uv run --script` resolved for agent_runner.py.
if [ -d "$PLUGIN_SITE" ]; then
    export PYTHONPATH="${PLUGIN_SITE}${PYTHONPATH:+:${PYTHONPATH}}"
    export PATH="${PLUGIN_SITE}/bin:${PATH}"
fi

log "Dropping privileges to tri_onyx user"
exec gosu tri_onyx uv run --script /opt/tri_onyx/agent_runner.py
