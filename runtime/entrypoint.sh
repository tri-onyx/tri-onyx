#!/usr/bin/env bash
# TriOnyx agent container entrypoint
#
# Prepares the sandbox environment and starts the agent runner:
#   1. Write FUSE policy from environment variable
#   2. Mount tri-onyx-fs FUSE driver
#   3. (Optional) Apply iptables network policy
#   4. Lock down /mnt/host bind mount (chmod 700)
#   5. Drop root privileges via gosu and exec the agent runner
#
# Required environment variables:
#   TRI_ONYX_FS_POLICY  — JSON object with fs_read/fs_write arrays
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

# -----------------------------------------------------------------------
# 1. FUSE filesystem policy
# -----------------------------------------------------------------------

POLICY_FILE="/etc/tri_onyx/fs-policy.json"

if [ -z "${TRI_ONYX_FS_POLICY:-}" ]; then
    die "TRI_ONYX_FS_POLICY environment variable is not set"
fi

# Write the policy JSON to a file for the FUSE driver.
echo "$TRI_ONYX_FS_POLICY" > "$POLICY_FILE"

# Validate it is parseable JSON.
if ! python3 -c "import json, sys; json.load(open(sys.argv[1]))" "$POLICY_FILE" 2>/dev/null; then
    die "TRI_ONYX_FS_POLICY is not valid JSON"
fi

log "FUSE policy written to $POLICY_FILE"

# -----------------------------------------------------------------------
# 2. Mount FUSE filesystem
# -----------------------------------------------------------------------

# Start the FUSE driver in the background. It mirrors /mnt/host to
# /workspace with access control from the policy file.
tri-onyx-fs \
    --config "$POLICY_FILE" \
    --source /mnt/host \
    --mountpoint /workspace \
    --allow-other 2>&1 1>/dev/null &

FUSE_PID=$!
log "tri-onyx-fs started (pid=$FUSE_PID)"

# Wait for the FUSE mount to become ready by checking if /workspace is a
# mountpoint. Poll every 100ms with a 10-second timeout.
MOUNT_TIMEOUT_ITERATIONS=100  # 100 * 0.1s = 10s
WAITED=0
while ! mountpoint -q /workspace 2>/dev/null; do
    if ! kill -0 "$FUSE_PID" 2>/dev/null; then
        die "tri-onyx-fs exited before mount was ready"
    fi
    if [ "$WAITED" -ge "$MOUNT_TIMEOUT_ITERATIONS" ]; then
        die "Timed out waiting for FUSE mount on /workspace (10s)"
    fi
    sleep 0.1
    WAITED=$((WAITED + 1))
done

log "FUSE mount ready at /workspace"

# -----------------------------------------------------------------------
# 3. Network policy
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

    # Drop everything else.
    iptables -A OUTPUT -j DROP
    log "Network policy applied: all other outbound traffic dropped"
fi

# -----------------------------------------------------------------------
# 4. Hide /mnt/host and drop privileges
# -----------------------------------------------------------------------

# The FUSE driver (already running as a background process) retains its
# original mount namespace and continues to access /mnt/host normally.
#
# For the agent process, we create a NEW mount namespace (unshare --mount)
# and overmount /mnt/host with an empty tmpfs. This makes the real bind
# mount invisible to the agent, preventing bypass via direct path access,
# /proc/self/cwd tricks, or any other route to the backing filesystem.
#
# After hiding /mnt/host, gosu drops root privileges so the agent runs
# as the unprivileged tri_onyx user with no capabilities.

log "Dropping privileges to tri_onyx user"
exec unshare --mount -- sh -c '
    mount -t tmpfs none /mnt/host &&
    exec gosu tri_onyx uv run --script /opt/tri_onyx/agent_runner.py
'
