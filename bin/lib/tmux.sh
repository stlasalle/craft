#!/usr/bin/env bash
# tmux.sh — Tmux pane management for the craft orchestrator

# Session name for the orchestrator
TMUX_SESSION="craft"

# Ensure the tmux session exists, with orchestrator + architect windows
# Returns the session name
ensure_session() {
    local project_name="$1"
    local project_dir="$2"  # optional — used to cd the architect window
    local session="${TMUX_SESSION}-${project_name}"

    if ! tmux has-session -t "$session" 2>/dev/null; then
        tmux new-session -d -s "$session" -n "orchestrator"
        # Disable monitor-activity on the orchestrator window so dashboard refreshes
        # don't trigger tmux activity alerts
        tmux set-option -t "${session}:orchestrator" monitor-activity off 2>/dev/null || true
    fi

    # Ensure architect window exists — an agent session pre-loaded with project context
    if ! tmux list-windows -t "$session" -F '#{window_name}' 2>/dev/null | grep -q '^architect$'; then
        tmux new-window -t "${session}:" -n "architect"
        if [[ -n "${project_dir:-}" ]]; then
            local skill_file="${project_dir}/.claude/commands/init-architect.md"
            local architect_agent="${ARCHITECT_AGENT:-claude}"
            local cmd
            cmd=$(provider_architect_cmd "$architect_agent" "$skill_file" "$project_dir")
            # Use send-keys so the agent runs inside an interactive shell.
            # Passing the command to new-window runs it as the window's initial
            # process, which breaks TUI input (arrow keys, etc.) for agents
            # like codex that use interactive terminal frameworks.
            tmux send-keys -t "${session}:architect" "$cmd" Enter
        fi
        tmux select-window -t "${session}:orchestrator"
    fi

    echo "$session"
}

# Create a new window for a task and run the agent in it
# Returns the window ID
spawn_task_pane() {
    local session="$1" task_id="$2" prompt_file="$3" work_dir="$4"
    local agent="${5:-claude}"

    local cmd
    cmd=$(provider_task_cmd "$agent" "$prompt_file" "$work_dir")

    # Create window with a shell first, then send the command via send-keys.
    # This ensures the agent runs inside an interactive shell pty, so TUI
    # input (arrow keys, etc.) works if the operator jumps into the pane.
    local window_id
    window_id=$(tmux new-window -t "${session}:" -n "$task_id" -P -F '#{window_id}')
    tmux send-keys -t "${session}:${task_id}" "$cmd" Enter

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
    local status_file="/tmp/craft-${session}-status"
    echo "$status_text" > "$status_file"
}
