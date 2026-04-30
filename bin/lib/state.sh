#!/usr/bin/env bash
# state.sh — Pluggable state backend dispatcher
#
# Sources a backend implementation based on the STATE_BACKEND variable.
# Backends:
#   local   — file-based task queue under queue/ (default)
#   linear  — Linear issues via GraphQL (implemented in a later plan)

STATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

STATE_BACKEND="${STATE_BACKEND:-local}"

case "$STATE_BACKEND" in
    local)
        # shellcheck source=/dev/null
        source "$STATE_DIR/state-local.sh"
        ;;
    *)
        echo "Error: unknown STATE_BACKEND '$STATE_BACKEND'. Supported: local" >&2
        return 1 2>/dev/null || exit 1
        ;;
esac
