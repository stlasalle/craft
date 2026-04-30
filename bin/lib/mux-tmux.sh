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
        if [[ -n "${project_dir:-}" ]]; then
            local skill_file="${project_dir}/.claude/commands/init-architect.md"
            local architect_agent="${ARCHITECT_AGENT:-claude}"
            local cmd
            cmd=$(provider_architect_cmd "$architect_agent" "$skill_file" "$project_dir")
            tmux new-window -t "${session}:" -n "architect" "$cmd"
        else
            tmux new-window -t "${session}:" -n "architect"
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

# Create a new window for a watcher and run the command in it
# Returns the window ID
spawn_watcher_pane() {
    local session="$1" pr_number="$2" cmd="$3"
    local window_name="watch-pr-${pr_number}"

    # Resolve script paths via the directory this file lives in (bin/lib),
    # so the renderer is found regardless of caller cwd.
    local lib_dir
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local renderer="${lib_dir%/lib}/render-watcher-status.sh"

    # Locate the project's .state/watchers/<pr>.{state,json} files.
    # The watcher.sh writes them; we derive the path from the cmd's
    # --project-dir argument.
    local project_dir
    project_dir=$(echo "$cmd" | sed -nE "s/.*--project-dir '([^']*)'.*/\\1/p")
    local state_file="${project_dir}/.state/watchers/${pr_number}.state"
    local json_file="${project_dir}/.state/watchers/${pr_number}.json"

    # Refresh script for the status pane: re-renders every 5s. Tolerates
    # the state files not existing yet (first poll hasn't completed).
    local refresh_cmd="while true; do
        clear
        if [[ -f '$state_file' && -f '$json_file' ]]; then
            '$renderer' '$state_file' '$json_file' || echo 'renderer error'
        else
            echo 'waiting for first poll…'
        fi
        sleep 5
    done"

    # Create the window running the watcher's log loop in the bottom pane.
    local window_id
    window_id=$(tmux new-window -t "${session}:" -n "$window_name" -P -F '#{window_id}' "$cmd")

    # Split the new window: top pane = status snapshot, bottom = log.
    # We split BEFORE the watcher emits much output so the visual
    # arrangement is established immediately.
    tmux split-window -v -b -t "$window_id" -p 50 "$refresh_cmd" 2>/dev/null || true

    # Re-focus the bottom (log) pane so cursor activity attracts attention.
    tmux select-pane -t "$window_id" -D 2>/dev/null || true

    echo "$window_id"
}

# Update the orchestrator pane with status info
update_orchestrator_display() {
    local session="$1" status_text="$2"

    # Write status to a temp file that the orchestrator pane reads
    local status_file="/tmp/craft-${session}-status"
    echo "$status_text" > "$status_file"
}
