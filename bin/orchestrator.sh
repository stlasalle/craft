#!/usr/bin/env bash
set -uo pipefail

# orchestrator.sh — Persistent daemon that processes the craft task queue
#
# Usage: orchestrator.sh <project-dir> [--max-parallel N]
#
# Watches the queue for approved tasks, spins up Claude sessions in tmux panes,
# monitors task lifecycle, and notifies on state changes.
#
# Run this in a tmux pane — it becomes the orchestrator dashboard.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CRAFT_ROOT="${CRAFT_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
source "$SCRIPT_DIR/lib/state.sh"
source "$SCRIPT_DIR/lib/notify.sh"
source "$SCRIPT_DIR/lib/providers.sh"
# Multiplexer loaded after config (needs MULTIPLEXER variable)

# --- Logging ---
LOG_FILE=""  # set after PROJECT_DIR is known

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg"
    [[ -n "$LOG_FILE" ]] && echo "$msg" >> "$LOG_FILE"
}

# --- Configuration ---
PROJECT_DIR=""
MAX_PARALLEL=10
POLL_INTERVAL=15  # seconds between queue checks

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --max-parallel)
            MAX_PARALLEL="$2"
            shift 2
            ;;
        --poll-interval)
            POLL_INTERVAL="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 <project-dir> [--max-parallel N] [--poll-interval SECONDS]"
            exit 0
            ;;
        *)
            PROJECT_DIR="$1"
            shift
            ;;
    esac
done

if [[ -z "$PROJECT_DIR" ]]; then
    echo "Error: project directory required"
    echo "Usage: $0 <project-dir> [--max-parallel N]"
    exit 1
fi

PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
QUEUE_DIR="$PROJECT_DIR/queue"
PROJECT_NAME="$(basename "$PROJECT_DIR")"

# Validate project structure
for dir in approved in-progress done blocked archive waiting; do
    mkdir -p "$QUEUE_DIR/$dir"
done
mkdir -p "$PROJECT_DIR/worktrees"
mkdir -p "$PROJECT_DIR/.state/waiting"
mkdir -p "$PROJECT_DIR/logs"

# Initialize log file
LOG_FILE="$PROJECT_DIR/logs/orchestrator-$(date '+%Y-%m-%d').log"

# Load agent provider config (sets DEFAULT_AGENT, ARCHITECT_AGENT, MULTIPLEXER)
load_provider_config "$PROJECT_DIR"

# Load multiplexer provider (must come after config so MULTIPLEXER is set)
source "$SCRIPT_DIR/lib/mux.sh"

# --- State tracking ---
declare -A ACTIVE_TASKS=()     # task_id -> tmux window name
declare -A TASK_AGENTS=()      # task_id -> agent provider (claude, codex, etc.)
declare -A TASK_START=()       # task_id -> epoch timestamp when task started
declare -A ACTIVE_WATCHERS=()  # pr_number -> tmux window name

# --- Display ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

clear_screen() {
    # Use ANSI escape to clear without triggering tmux activity detection
    printf '\033[2J\033[H'
}

render_dashboard() {
    clear_screen
    "$SCRIPT_DIR/render-dashboard.sh" "$PROJECT_DIR"
    echo ""
    echo -e "  ${BOLD}Last poll:${NC} $(date '+%H:%M:%S')  ${BOLD}Parallel limit:${NC} $MAX_PARALLEL  ${BOLD}Poll interval:${NC} ${POLL_INTERVAL}s  ${BOLD}Agent:${NC} $DEFAULT_AGENT"
    echo -e "  ${BOLD}Ctrl+C${NC} to stop orchestrator"
}

# --- Task Execution ---

run_task() {
    local task_file="$1"
    local tid
    tid=$(task_id "$task_file")
    local filename
    filename=$(basename "$task_file")

    log "Starting task: $tid"

    # Claim the task via the state interface (moves approved -> in-progress,
    # sets the started timestamp).
    local new_file
    new_file=$(state_claim_task "$QUEUE_DIR" "$tid") || {
        log "Failed to claim task $tid"
        return 1
    }
    notify_started "$tid"

    # Build the prompt file
    # Read the skill template and substitute $ARGUMENTS
    # Prepend a note that the task has already been moved to in-progress by the orchestrator
    local skill_file="$PROJECT_DIR/.claude/commands/work-task.md"
    local prompt_file="/tmp/craft-prompt-${tid}.txt"
    {
        echo "NOTE: The orchestrator has already claimed this task (moved queue/approved/${filename} to queue/in-progress/${filename} and set status=in-progress with a started timestamp). You do NOT need to move the task file yourself."
        echo ""
        echo "Working context:"
        echo "  CRAFT_ROOT=${CRAFT_ROOT}"
        echo "  PROJECT_DIR=${PROJECT_DIR}"
        echo "  QUEUE_DIR=${QUEUE_DIR}"
        echo ""
        echo "To call state operations (e.g., state_mark_waiting, state_append_note), first source the state library:"
        echo "  source \"\${CRAFT_ROOT}/bin/lib/state.sh\""
        echo "Then invoke operations with QUEUE_DIR as the first argument, e.g.:"
        echo "  state_mark_waiting \"\${QUEUE_DIR}\" \"${tid}\" \"<pr-url>\""
        echo ""
        sed "s/\\\$ARGUMENTS/$filename/g" "$skill_file"
    } > "$prompt_file"

    # Determine which agent provider to use (task-level override or project default)
    local agent
    agent=$(task_agent "$new_file")

    # Get the tmux session
    local session
    session=$(ensure_session "$PROJECT_NAME" "$PROJECT_DIR")

    # Spawn an agent session in a tmux window
    local window
    window=$(spawn_task_pane "$session" "$tid" "$prompt_file" "$PROJECT_DIR" "$agent")

    # Track it
    ACTIVE_TASKS["$tid"]="$window"
    TASK_AGENTS["$tid"]="$agent"
    TASK_START["$tid"]="$(date +%s)"
}

# Find a task file by task ID across queue directories
find_task_in() {
    local dir="$1" tid="$2"
    for f in "$dir"/*.md; do
        [[ -f "$f" ]] || continue
        if [[ "$(task_id "$f")" == "$tid" ]]; then
            echo "$f"
            return 0
        fi
    done
    return 1
}

# Spawn a watcher for a task that has moved to waiting/.
# Reads the pr: field from the task's frontmatter. Returns 0 on success,
# 1 if no pr field or the PR number can't be derived.
spawn_watcher_for_task() {
    local task_file="$1"
    local tid
    tid=$(task_id "$task_file")

    local pr_url
    pr_url=$(task_field "$task_file" "pr")
    if [[ -z "$pr_url" ]]; then
        log "Task $tid is in waiting/ but has no pr: field — not spawning watcher"
        return 1
    fi

    local pr_number="${pr_url##*/}"
    if ! [[ "$pr_number" =~ ^[0-9]+$ ]]; then
        log "Task $tid has unparseable pr url '$pr_url' — not spawning watcher"
        return 1
    fi

    # Already watching this PR?
    if [[ -n "${ACTIVE_WATCHERS[$pr_number]:-}" ]]; then
        return 0
    fi

    local session
    session=$(ensure_session "$PROJECT_NAME" "$PROJECT_DIR")

    local cmd="'$SCRIPT_DIR/watcher.sh' --pr '$pr_url' --task '$tid' --queue-dir '$QUEUE_DIR' --project-dir '$PROJECT_DIR'"

    local window
    window=$(spawn_watcher_pane "$session" "$pr_number" "$cmd")

    ACTIVE_WATCHERS["$pr_number"]="$window"
    log "Spawned watcher for PR $pr_number (task $tid)"
}

# Get the timeout for a task (per-task override or global default, in seconds)
# Returns empty string if no timeout is configured
task_timeout() {
    local tid="$1"
    local task_file=""

    # Find the task file in in-progress
    task_file=$(find_task_in "$QUEUE_DIR/in-progress" "$tid" 2>/dev/null || true)
    if [[ -n "$task_file" ]]; then
        local per_task
        per_task=$(task_field "$task_file" "timeout")
        if [[ -n "$per_task" ]]; then
            echo "$per_task"
            return
        fi
    fi

    echo "${AGENT_TIMEOUT:-}"
}

# Check if active tasks have finished or timed out
check_active_tasks() {
    local session
    session="${TMUX_SESSION}-${PROJECT_NAME}"
    local now
    now=$(date +%s)

    for tid in "${!ACTIVE_TASKS[@]}"; do
        # Check for timeout
        local timeout
        timeout=$(task_timeout "$tid")
        if [[ -n "$timeout" ]] && [[ -n "${TASK_START[$tid]:-}" ]]; then
            local elapsed=$(( now - TASK_START[$tid] ))
            if (( elapsed > timeout )); then
                log "Task $tid timed out after ${elapsed}s (limit: ${timeout}s)"

                local task_file
                task_file=$(find_task_in "$QUEUE_DIR/in-progress" "$tid" 2>/dev/null || true)
                if [[ -n "$task_file" ]]; then
                    state_mark_blocked "$QUEUE_DIR" "$tid" "Timed out after ${elapsed}s (limit: ${timeout}s)" > /dev/null
                fi

                kill_task_pane "$session" "$tid"
                notify_blocked "$tid" "Agent timed out after ${elapsed}s"

                unset ACTIVE_TASKS["$tid"]
                unset TASK_AGENTS["$tid"]
                unset TASK_START["$tid"]
                continue
            fi
        fi

        if ! pane_is_running "$session" "$tid"; then
            log "Task $tid session ended"
            unset ACTIVE_TASKS["$tid"]
            unset TASK_AGENTS["$tid"]
            unset TASK_START["$tid"]

            # Check where the task ended up
            if find_task_in "$QUEUE_DIR/done" "$tid" > /dev/null; then
                log "Task $tid → done"
                notify_done "$tid" ""
            elif find_task_in "$QUEUE_DIR/blocked" "$tid" > /dev/null; then
                log "Task $tid → blocked"
                notify_blocked "$tid" "Task moved to blocked"
            elif find_task_in "$QUEUE_DIR/waiting" "$tid" > /dev/null; then
                log "Task $tid → waiting"
                notify_waiting "$tid"
            else
                log "Task $tid session ended but task not found in done/blocked/waiting"
            fi

            # Clean up the tmux window
            kill_task_pane "$session" "$tid"
        fi
    done
}

# Check for milestone completion
# Check for milestone completion
check_milestone_completion() {
    local marker_dir="$PROJECT_DIR/.state/notified-milestones"
    mkdir -p "$marker_dir"

    # Get all milestones that have tasks.
    local milestones
    milestones=$(for f in "$QUEUE_DIR"/done/*.md "$QUEUE_DIR"/approved/*.md "$QUEUE_DIR"/in-progress/*.md "$QUEUE_DIR"/pending/*.md; do
        [[ -f "$f" ]] && task_milestone "$f"
    done | sort -u)

    for milestone in $milestones; do
        [[ -z "$milestone" ]] && continue

        # Check if all tasks for this milestone are done.
        local all_done=true
        for dir in pending approved in-progress blocked; do
            for f in "$QUEUE_DIR/$dir"/*.md; do
                [[ -f "$f" ]] || continue
                if [[ "$(task_milestone "$f")" == "$milestone" ]]; then
                    all_done=false
                    break 2
                fi
            done
        done

        if $all_done; then
            local has_done=false
            for f in "$QUEUE_DIR/done"/*.md; do
                [[ -f "$f" ]] || continue
                if [[ "$(task_milestone "$f")" == "$milestone" ]]; then
                    has_done=true
                    break
                fi
            done

            if $has_done; then
                local marker="$marker_dir/$milestone"
                if [[ ! -f "$marker" ]]; then
                    touch "$marker"
                    notify_milestone "$milestone"
                    log "Milestone complete: $milestone — run /consolidate $milestone"
                fi
            fi
        else
            # Milestone is no longer fully done (a new task entered a
            # non-done state). Clear the marker so a future re-completion
            # re-notifies.
            local marker="$marker_dir/$milestone"
            [[ -f "$marker" ]] && rm -f "$marker"
        fi
    done
}

# Check for new tasks in waiting state and notify
# Uses a marker file per task inside the project directory
check_waiting_tasks() {
    local marker_dir="$PROJECT_DIR/.state/waiting"
    mkdir -p "$marker_dir"
    for task_file in $(list_tasks "$QUEUE_DIR/waiting"); do
        local tid
        tid=$(task_id "$task_file")
        [[ -z "$tid" ]] && continue
        if [[ ! -f "$marker_dir/$tid" ]]; then
            touch "$marker_dir/$tid"
            notify_waiting "$tid"
            log "Task $tid is waiting for review"
        fi
    done
    # Clean up markers for tasks no longer in waiting
    for marker in "$marker_dir"/*; do
        [[ -f "$marker" ]] || continue
        local marker_tid
        marker_tid=$(basename "$marker")
        if ! find_task_in "$QUEUE_DIR/waiting" "$marker_tid" > /dev/null 2>&1; then
            rm -f "$marker"
        fi
    done
}

# Ensure each task in waiting/ with a pr URL has an active watcher.
ensure_watchers_for_waiting() {
    for task_file in $(list_tasks "$QUEUE_DIR/waiting"); do
        local pr_url pr_number
        pr_url=$(task_field "$task_file" "pr")
        [[ -z "$pr_url" ]] && continue
        pr_number="${pr_url##*/}"
        [[ -z "${ACTIVE_WATCHERS[$pr_number]:-}" ]] || continue
        spawn_watcher_for_task "$task_file" || true
    done
}

# Clean up watcher entries whose pane has died OR whose PR's task is no
# longer in waiting/. Either case means ACTIVE_WATCHERS has a stale entry
# that would otherwise prevent ensure_watchers_for_waiting from respawning.
reap_finished_watchers() {
    local session
    session="${TMUX_SESSION}-${PROJECT_NAME}"

    for pr_number in "${!ACTIVE_WATCHERS[@]}"; do
        # Check 1: is the watcher pane still alive?
        if ! pane_is_running "$session" "watch-pr-${pr_number}"; then
            log "Watcher pane for PR $pr_number has exited — unregistering"
            unset ACTIVE_WATCHERS["$pr_number"]
            continue
        fi

        # Check 2: is the task still in waiting/? If not, the watcher did
        # its job and will exit shortly on its own (or already has).
        local found=0
        for task_file in $(list_tasks "$QUEUE_DIR/waiting"); do
            local pr_url
            pr_url=$(task_field "$task_file" "pr")
            if [[ "${pr_url##*/}" == "$pr_number" ]]; then
                found=1
                break
            fi
        done
        if (( found == 0 )); then
            log "Watcher for PR $pr_number: task no longer in waiting/ — unregistering"
            unset ACTIVE_WATCHERS["$pr_number"]
        fi
    done
}

# --- Main Loop ---

# Handle nested tmux — if already inside tmux, unset TMUX to allow nesting
# and use a different prefix (C-b) for the inner session so keys don't collide
# with the outer session's prefix.
CRAFT_NESTED_TMUX=""
if [[ "$MULTIPLEXER" == "tmux" ]] && [[ -n "${TMUX:-}" ]] && [[ -z "${CRAFT_INNER_SESSION:-}" ]]; then
    CRAFT_NESTED_TMUX="$TMUX"
    unset TMUX
fi

# Ensure multiplexer session with orchestrator + planner windows
SESSION=$(ensure_session "$PROJECT_NAME" "$PROJECT_DIR")

# If nested, set the inner session to use C-b so it doesn't collide with the outer prefix
if [[ -n "$CRAFT_NESTED_TMUX" ]]; then
    tmux set-option -t "$SESSION" prefix C-b 2>/dev/null || true
fi

# If using tmux and we're not already inside the session, re-exec inside the orchestrator pane
if [[ "$MULTIPLEXER" == "tmux" ]]; then
    if [[ -z "${TMUX:-}" ]] || [[ "$(tmux display-message -p '#{session_name}' 2>/dev/null)" != "$SESSION" ]]; then
        tmux send-keys -t "${SESSION}:orchestrator" "CRAFT_INNER_SESSION=1 exec '$0' '$PROJECT_DIR' --max-parallel $MAX_PARALLEL --poll-interval $POLL_INTERVAL" Enter
        exec tmux attach -t "$SESSION"
    fi
fi
# cmux: no re-exec needed — the orchestrator runs directly in the current terminal

log "Craft orchestrator starting for: $PROJECT_DIR"
log "Max parallel tasks: $MAX_PARALLEL, Poll interval: ${POLL_INTERVAL}s"
echo ""

trap 'log "Orchestrator stopped."; exit 0' INT TERM

poll_count=0

while true; do
    # Run plugin poll hooks (e.g. linear-sync inbound)
    _run_hook on_poll 2>/dev/null || true

    # Check finished tasks
    check_active_tasks

    # Check for new waiting tasks
    check_waiting_tasks

    # Spawn watchers for any waiting task without one; reap finished watchers.
    ensure_watchers_for_waiting
    reap_finished_watchers

    # Check milestone completion every 4th poll
    if (( poll_count % 4 == 0 )); then
        check_milestone_completion
    fi

    # Pick up new tasks if we have capacity
    active_count=${#ACTIVE_TASKS[@]}
    while (( active_count < MAX_PARALLEL )); do
        next_task=$(next_ready_task "$QUEUE_DIR") || break

        run_task "$next_task"
        active_count=$((active_count + 1))
    done

    # Render the dashboard
    render_dashboard

    # Sleep
    sleep "$POLL_INTERVAL"
    poll_count=$((poll_count + 1))
done
