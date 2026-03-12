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

    [ -f "$PLAYWRIGHT_CLI" ] || die "playwright-cli not found: $PLAYWRIGHT_CLI"

    if [ ! -d "$profile_dir" ]; then
        echo "creating new profile: $profile"
        mkdir -p "$profile_dir"
        chmod 755 "$profile_dir"
    fi

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
