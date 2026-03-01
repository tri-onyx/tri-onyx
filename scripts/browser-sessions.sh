#!/usr/bin/env bash
# Manage browser session profiles used by TriOnyx agents.
#
# Usage:
#   browser-sessions.sh list                  List profiles and lock status
#   browser-sessions.sh unlock <profile>      Remove Chromium lock files
#   browser-sessions.sh open <profile> [url]  Open headed browser for manual login

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SESSIONS_DIR="$PROJECT_DIR/workspace/browser-sessions"
PLAYWRIGHT_CLI="$PROJECT_DIR/playwright-cli/playwright-cli.js"

LOCK_FILES=(SingletonLock SingletonCookie SingletonSocket)

die() { echo "error: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# list — show profiles and their lock state
# ---------------------------------------------------------------------------
cmd_list() {
    if [ ! -d "$SESSIONS_DIR" ]; then
        echo "No sessions directory at $SESSIONS_DIR"
        return
    fi

    local found=0
    for dir in "$SESSIONS_DIR"/*/; do
        [ -d "$dir" ] || continue
        found=1
        local name
        name="$(basename "$dir")"
        local locks=""

        for lf in "${LOCK_FILES[@]}"; do
            local path="$dir$lf"
            if [ -L "$path" ]; then
                if [ -e "$path" ]; then
                    locks+=" $lf(active)"
                else
                    locks+=" $lf(stale)"
                fi
            fi
        done

        if [ -n "$locks" ]; then
            echo "$name  locks:$locks"
        else
            echo "$name  unlocked"
        fi
    done

    if [ "$found" -eq 0 ]; then
        echo "No profiles found in $SESSIONS_DIR"
    fi
}

# ---------------------------------------------------------------------------
# unlock — remove Singleton* lock files from a profile
# ---------------------------------------------------------------------------
cmd_unlock() {
    local profile="${1:?usage: browser-sessions.sh unlock <profile>}"
    local profile_dir="$SESSIONS_DIR/$profile"

    [ -d "$profile_dir" ] || die "profile not found: $profile_dir"

    # Fix ownership if needed so we can actually remove the lock files.
    if [ "$(stat -c %u "$profile_dir")" != "$(id -u)" ]; then
        echo "fixing profile ownership..."
        sudo chown -R "$(id -u):$(id -g)" "$profile_dir"
    fi

    local removed=0
    for lf in "${LOCK_FILES[@]}"; do
        local path="$profile_dir/$lf"
        if [ -L "$path" ] || [ -e "$path" ]; then
            rm -f "$path"
            echo "removed $lf"
            removed=$((removed + 1))
        fi
    done

    if [ "$removed" -eq 0 ]; then
        echo "no lock files found in $profile"
    fi
}

# ---------------------------------------------------------------------------
# open — launch a headed browser for manual interaction
# ---------------------------------------------------------------------------
cmd_open() {
    local profile="${1:?usage: browser-sessions.sh open <profile> [url]}"
    shift
    local url="${1:-}"
    local profile_dir="$SESSIONS_DIR/$profile"

    [ -d "$profile_dir" ] || die "profile not found: $profile_dir"
    [ -f "$PLAYWRIGHT_CLI" ] || die "playwright-cli not found: $PLAYWRIGHT_CLI"

    # Save original ownership so we can restore it after the browser exits.
    local orig_uid_gid
    orig_uid_gid="$(stat -c %u:%g "$profile_dir")"

    # Fix ownership — the container runs as a different UID so profile
    # dirs end up with 700 permissions owned by that UID.
    if [ "$(stat -c %u "$profile_dir")" != "$(id -u)" ]; then
        echo "fixing profile ownership..."
        sudo chown -R "$(id -u):$(id -g)" "$profile_dir"
    fi

    # Restore original ownership on exit (normal, error, or signal).
    restore_ownership() {
        echo "restoring profile ownership to $orig_uid_gid..."
        sudo chown -R "$orig_uid_gid" "$profile_dir"
    }
    trap restore_ownership EXIT

    # Clear stale locks so the browser can start cleanly.
    for lf in "${LOCK_FILES[@]}"; do
        local path="$profile_dir/$lf"
        if [ -L "$path" ] && [ ! -e "$path" ]; then
            rm -f "$path"
            echo "cleared stale $lf"
        fi
    done

    local args=(open --browser=chromium --headed --persistent "--profile=$profile_dir")
    [ -n "$url" ] && args+=("$url")

    echo "opening $profile..."
    node "$PLAYWRIGHT_CLI" "${args[@]}"
}

# ---------------------------------------------------------------------------
# dispatch
# ---------------------------------------------------------------------------
case "${1:-}" in
    list)    shift; cmd_list "$@" ;;
    unlock)  shift; cmd_unlock "$@" ;;
    open)    shift; cmd_open "$@" ;;
    *)
        echo "usage: browser-sessions.sh <list|unlock|open> [args...]" >&2
        exit 1
        ;;
esac
