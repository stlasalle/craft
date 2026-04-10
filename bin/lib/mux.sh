#!/usr/bin/env bash
# mux.sh — Multiplexer abstraction layer
#
# Sources either tmux.sh or cmux.sh based on the MULTIPLEXER config.
# All multiplexer providers must implement these functions:
#
#   ensure_session <project-name> <project-dir>
#     → Create/find a session with orchestrator + architect windows.
#       Returns the session/workspace identifier.
#
#   spawn_task_pane <session> <task-id> <prompt-file> <work-dir> [agent]
#     → Create a new pane/surface and run the agent command in it.
#       Returns a pane/surface identifier.
#
#   pane_is_running <session> <task-id>
#     → Returns 0 if the task's pane is still alive, 1 if finished.
#
#   kill_task_pane <session> <task-id>
#     → Clean up a task's pane/surface.

MUX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default to tmux if not set
MULTIPLEXER="${MULTIPLEXER:-tmux}"

case "$MULTIPLEXER" in
    tmux)
        source "$MUX_DIR/mux-tmux.sh"
        ;;
    cmux)
        source "$MUX_DIR/mux-cmux.sh"
        ;;
    *)
        echo "Error: unknown multiplexer '$MULTIPLEXER'. Supported: tmux, cmux" >&2
        exit 1
        ;;
esac
