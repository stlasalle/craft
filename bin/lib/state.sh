#!/usr/bin/env bash
# state.sh — Pluggable state backend dispatcher
#
# Sources a backend implementation based on the STATE_BACKEND variable.
# Backends:
#   local   — file-based task queue under queue/ (default)
#   linear  — Linear issues via GraphQL (implemented in a later plan)

# Resolve the directory holding state-*.sh.
# Prefer CRAFT_ROOT (set by the orchestrator and passed into worker
# prompts) so that sourcing this file from agents running under zsh —
# where BASH_SOURCE may be empty and dirname '' resolves to cwd —
# still finds the correct backend file. Fall back to BASH_SOURCE for
# direct bash callers.
if [[ -n "${CRAFT_ROOT:-}" ]] && [[ -f "${CRAFT_ROOT}/bin/lib/state-local.sh" ]]; then
    STATE_DIR="${CRAFT_ROOT}/bin/lib"
else
    STATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
fi

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
