#!/usr/bin/env bash
# run-hook.sh — Dispatch a lifecycle hook to all enabled plugins
#
# Usage: plugins/run-hook.sh <hook-name> [args...]
#
# Hook names: on_waiting, on_ready, on_done, on_blocked, on_milestone
# Each plugin can provide a hooks.sh that defines these functions.

set -uo pipefail

HOOK_NAME="${1:?Usage: run-hook.sh <hook-name> [args...]}"
shift

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load project config for PLUGINS list
CONFIG_FILE="$PROJECT_DIR/autopilot.conf"
PLUGINS="${PLUGINS:-}"
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

if [[ -z "$PLUGINS" ]]; then
    exit 0
fi

# Split comma-separated plugin list and run each
IFS=',' read -ra PLUGIN_LIST <<< "$PLUGINS"
for plugin in "${PLUGIN_LIST[@]}"; do
    plugin="$(echo "$plugin" | xargs)"  # trim whitespace
    hooks_file="$SCRIPT_DIR/$plugin/hooks.sh"

    if [[ ! -f "$hooks_file" ]]; then
        echo "[plugins] Warning: plugin '$plugin' has no hooks.sh" >&2
        continue
    fi

    # Source the plugin's hooks in a subshell so plugins can't interfere with each other
    (
        # shellcheck source=/dev/null
        source "$hooks_file"
        if declare -f "$HOOK_NAME" > /dev/null 2>&1; then
            "$HOOK_NAME" "$@"
        fi
    )
done
