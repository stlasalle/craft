#!/usr/bin/env bash
# mux-cmux.sh — cmux multiplexer provider for the craft orchestrator
#
# Uses cmux workspaces and surfaces instead of tmux sessions and windows.
# Requires cmux to be running (it's a macOS GUI app, not a daemon).

# Workspace name prefix
CMUX_PREFIX="craft"

# Compat alias used by orchestrator.sh — both providers expose
# the same session-name prefix variable so check_active_tasks and
# reap_finished_watchers work identically regardless of multiplexer.
TMUX_SESSION="${CMUX_PREFIX}"

# Track surface IDs for task panes
declare -A CMUX_SURFACES=()  # task_id -> surface_id

# Ensure the cmux workspace exists, with orchestrator + architect surfaces
# Returns the workspace identifier
ensure_session() {
    local project_name="$1"
    local project_dir="$2"
    local workspace_name="${CMUX_PREFIX}-${project_name}"

    # Check if workspace already exists
    local existing
    existing=$(cmux list-workspaces 2>/dev/null | grep "$workspace_name" || true)

    if [[ -z "$existing" ]]; then
        cmux new-workspace "$workspace_name" 2>/dev/null
    fi

    # Select the workspace
    cmux select-workspace "$workspace_name" 2>/dev/null || true

    # The orchestrator runs in the initial surface.
    # Create the architect surface if it doesn't exist yet.
    local surfaces
    surfaces=$(cmux list-surfaces 2>/dev/null || true)
    local surface_count
    surface_count=$(echo "$surfaces" | grep -c . 2>/dev/null || echo "0")

    if [[ "$surface_count" -lt 2 ]] && [[ -n "${project_dir:-}" ]]; then
        local skill_file="${project_dir}/.claude/commands/init-architect.md"
        local architect_agent="${ARCHITECT_AGENT:-claude}"
        local cmd
        cmd=$(provider_architect_cmd "$architect_agent" "$skill_file" "$project_dir")

        cmux new-split right 2>/dev/null || true
        cmux send "$cmd" 2>/dev/null || true
        cmux send-key enter 2>/dev/null || true
    fi

    echo "$workspace_name"
}

# Create a new surface for a task and run the agent in it
# Returns the surface ID
spawn_task_pane() {
    local session="$1" task_id="$2" prompt_file="$3" work_dir="$4"
    local agent="${5:-claude}"

    local cmd
    cmd=$(provider_task_cmd "$agent" "$prompt_file" "$work_dir")

    # Select the workspace and create a new split
    cmux select-workspace "$session" 2>/dev/null || true
    local surface_id
    surface_id=$(cmux new-split down 2>/dev/null || true)

    # Set surface title/status for identification
    cmux set-status "task" "$task_id" 2>/dev/null || true

    # Send the command
    cmux send "$cmd" 2>/dev/null || true
    cmux send-key enter 2>/dev/null || true

    # Track the surface
    CMUX_SURFACES["$task_id"]="${surface_id:-$task_id}"

    echo "${surface_id:-$task_id}"
}

# Like spawn_task_pane but creates the surface without focusing it.
# cmux's new-split takes focus by default; we focus back to the previous
# surface after creating the new one. Used for remediation agents
# dispatched by watchers.
# Returns the surface ID.
spawn_task_pane_detached() {
    local session="$1" task_id="$2" prompt_file="$3" work_dir="$4"
    local agent="${5:-claude}"

    local cmd
    cmd=$(provider_task_cmd "$agent" "$prompt_file" "$work_dir")

    # Capture the currently-focused surface so we can return to it.
    local prev_surface
    prev_surface=$(cmux focused-surface 2>/dev/null || true)

    cmux select-workspace "$session" 2>/dev/null || true
    local surface_id
    surface_id=$(cmux new-split down 2>/dev/null || true)
    cmux set-status "task" "$task_id" 2>/dev/null || true
    cmux send "$cmd" 2>/dev/null || true
    cmux send-key enter 2>/dev/null || true

    CMUX_SURFACES["$task_id"]="${surface_id:-$task_id}"

    # Restore focus to the previously-focused surface.
    if [[ -n "$prev_surface" ]]; then
        cmux focus-surface "$prev_surface" 2>/dev/null || true
    fi

    echo "${surface_id:-$task_id}"
}

# Check if a task's surface is still running
# Returns 0 if running, 1 if finished
pane_is_running() {
    local session="$1" task_id="$2"

    # Check if the surface still exists
    local surface_id="${CMUX_SURFACES[$task_id]:-}"
    if [[ -z "$surface_id" ]]; then
        return 1
    fi

    # Check if the surface is still listed
    if cmux list-surfaces 2>/dev/null | grep -q "$surface_id"; then
        return 0
    fi

    return 1
}

# Kill a task's surface
kill_task_pane() {
    local session="$1" task_id="$2"

    local surface_id="${CMUX_SURFACES[$task_id]:-}"
    if [[ -n "$surface_id" ]]; then
        cmux focus-surface "$surface_id" 2>/dev/null || true
        # cmux doesn't have a direct "close surface" CLI yet,
        # so we send exit to the shell
        cmux send-surface "$surface_id" "exit" 2>/dev/null || true
        cmux send-key enter 2>/dev/null || true
        unset CMUX_SURFACES["$task_id"]
    fi
}

# Create a new surface for a watcher and run the command in it
# Returns the surface ID
spawn_watcher_pane() {
    local session="$1" pr_number="$2" cmd="$3"
    local window_name="watch-pr-${pr_number}"

    # Locate the renderer and the state files (same logic as mux-tmux.sh).
    local lib_dir
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local renderer="${lib_dir%/lib}/render-watcher-status.sh"
    local project_dir
    project_dir=$(echo "$cmd" | sed -nE "s/.*--project-dir '([^']*)'.*/\\1/p")
    local state_file="${project_dir}/.state/watchers/${pr_number}.state"
    local json_file="${project_dir}/.state/watchers/${pr_number}.json"

    local refresh_cmd="while true; do
        clear
        if [[ -f '$state_file' && -f '$json_file' ]]; then
            '$renderer' '$state_file' '$json_file' || echo 'renderer error'
        else
            echo 'waiting for first poll…'
        fi
        sleep 5
    done"

    # Create the watcher pane (matches the existing pattern in this file).
    cmux select-workspace "$session" 2>/dev/null || true
    local surface_id
    surface_id=$(cmux new-split down 2>/dev/null || true)
    cmux set-status "watcher" "$window_name" 2>/dev/null || true
    cmux send "$cmd" 2>/dev/null || true
    cmux send-key enter 2>/dev/null || true

    # Save reference for pane_is_running.
    if [[ -n "${CMUX_SURFACES:-}" ]]; then
        CMUX_SURFACES["$window_name"]="${surface_id:-$window_name}"
    fi

    # Add the status pane above the watcher pane.
    cmux new-split up 2>/dev/null || true
    cmux set-status "watcher-status" "${window_name}-status" 2>/dev/null || true
    cmux send "$refresh_cmd" 2>/dev/null || true
    cmux send-key enter 2>/dev/null || true

    # Move focus back to the watcher (log) pane.
    cmux select-split down 2>/dev/null || true

    echo "${surface_id:-$window_name}"
}

# Update the orchestrator display (no-op for cmux — the dashboard renders in-terminal)
update_orchestrator_display() {
    local session="$1" status_text="$2"
    # cmux notifications can supplement the dashboard
    if [[ -n "$status_text" ]]; then
        cmux set-status "craft" "$status_text" 2>/dev/null || true
    fi
}
