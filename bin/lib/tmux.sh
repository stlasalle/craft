#!/usr/bin/env bash
# tmux.sh — Tmux pane management for the autopilot orchestrator

# Session name for the orchestrator
TMUX_SESSION="autopilot"

# Ensure the tmux session exists
ensure_session() {
    local project_name="$1"
    local session="${TMUX_SESSION}-${project_name}"

    if ! tmux has-session -t "$session" 2>/dev/null; then
        tmux new-session -d -s "$session" -n "orchestrator"
        echo "Created tmux session: $session"
    fi
    echo "$session"
}

# Create a new pane for a task and run a command in it
# Returns the pane ID
spawn_task_pane() {
    local session="$1" task_id="$2" command="$3"

    # Create a new window for this task
    local window_id
    window_id=$(tmux new-window -t "$session" -n "$task_id" -P -F '#{window_id}' "$command; echo '--- Task $task_id finished (exit code: $?) ---'; read")

    echo "$window_id"
}

# Check if a task pane is still running
# Returns 0 if running, 1 if finished
pane_is_running() {
    local session="$1" task_id="$2"

    if tmux list-windows -t "$session" -F '#{window_name}' 2>/dev/null | grep -q "^${task_id}$"; then
        # Check if the process in the pane is still running
        local pane_pid
        pane_pid=$(tmux list-panes -t "${session}:${task_id}" -F '#{pane_pid}' 2>/dev/null | head -1)
        if [[ -n "$pane_pid" ]] && kill -0 "$pane_pid" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

# Kill a task pane
kill_task_pane() {
    local session="$1" task_id="$2"
    tmux kill-window -t "${session}:${task_id}" 2>/dev/null || true
}

# Update the orchestrator pane with status info
update_orchestrator_display() {
    local session="$1" status_text="$2"

    # Write status to a temp file that the orchestrator pane reads
    local status_file="/tmp/autopilot-${session}-status"
    echo "$status_text" > "$status_file"
}
