#!/usr/bin/env bash
# tmux.sh — Tmux pane management for the autopilot orchestrator

# Session name for the orchestrator
TMUX_SESSION="autopilot"

# Ensure the tmux session exists, with orchestrator + planner windows
# Returns the session name
ensure_session() {
    local project_name="$1"
    local project_dir="$2"  # optional — used to cd the planner window
    local session="${TMUX_SESSION}-${project_name}"

    if ! tmux has-session -t "$session" 2>/dev/null; then
        tmux new-session -d -s "$session" -n "orchestrator"
        # Disable monitor-activity on the orchestrator window so dashboard refreshes
        # don't trigger tmux activity alerts
        tmux set-option -t "${session}:orchestrator" monitor-activity off 2>/dev/null || true
    fi

    # Ensure architect window exists — a Claude session pre-loaded with project context
    if ! tmux list-windows -t "$session" -F '#{window_name}' 2>/dev/null | grep -q '^architect$'; then
        if [[ -n "${project_dir:-}" ]]; then
            local skill_file="${project_dir}/.claude/commands/init-architect.md"
            tmux new-window -t "${session}:" -n "architect" "cd '${project_dir}' && claude \"\$(cat '${skill_file}')\" ; exec \$SHELL"
        else
            tmux new-window -t "${session}:" -n "architect"
        fi
        tmux select-window -t "${session}:orchestrator"
    fi

    echo "$session"
}

# Create a new pane for a task and run a command in it
# Returns the pane ID
spawn_task_pane() {
    local session="$1" task_id="$2" prompt_file="$3" work_dir="$4"

    # tmux new-window runs via sh -c; use interactive claude (no -p) so TUI is visible
    # Following the pattern from slack-bot/listener.js
    local cmd="cd '${work_dir}' && claude \"\$(cat '${prompt_file}')\" ; rm -f '${prompt_file}'; exec \$SHELL"

    local window_id
    window_id=$(tmux new-window -t "${session}:" -n "$task_id" -P -F '#{window_id}' "$cmd")

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
