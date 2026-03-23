#!/usr/bin/env bash
set -uo pipefail

# orchestrator.sh — Persistent daemon that processes the autopilot task queue
#
# Usage: orchestrator.sh <project-dir> [--max-parallel N]
#
# Watches the queue for approved tasks, spins up Claude sessions in tmux panes,
# monitors task lifecycle, and notifies on state changes.
#
# Run this in a tmux pane — it becomes the orchestrator dashboard.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/queue.sh"
source "$SCRIPT_DIR/lib/tmux.sh"
source "$SCRIPT_DIR/lib/notify.sh"

# --- Configuration ---
PROJECT_DIR=""
MAX_PARALLEL=3
POLL_INTERVAL=15  # seconds between queue checks
PR_POLL_INTERVAL=120  # seconds between PR merge checks

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
for dir in approved in-progress done blocked archive; do
    if [[ ! -d "$QUEUE_DIR/$dir" ]]; then
        echo "Error: $QUEUE_DIR/$dir does not exist. Is this an autopilot project?"
        exit 1
    fi
done

# --- State tracking ---
declare -A ACTIVE_TASKS=()  # task_id -> tmux window name
declare -A TASK_PR_URLS=()  # task_id -> PR URL (for merge monitoring)

# --- Display ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

clear_screen() {
    clear
}

render_dashboard() {
    clear_screen

    echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║  AUTOPILOT ORCHESTRATOR — ${CYAN}${PROJECT_NAME}${NC}${BOLD}$(printf '%*s' $((24 - ${#PROJECT_NAME})) '')║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""

    # Counts
    local n_pending n_approved n_in_progress n_done n_blocked
    n_pending=$(count_tasks "$QUEUE_DIR/pending")
    n_approved=$(count_tasks "$QUEUE_DIR/approved")
    n_in_progress=$(count_tasks "$QUEUE_DIR/in-progress")
    n_done=$(count_tasks "$QUEUE_DIR/done")
    n_blocked=$(count_tasks "$QUEUE_DIR/blocked")

    echo -e "  ${BLUE}○${NC} Pending: $n_pending    ${YELLOW}◐${NC} Approved: $n_approved    ${CYAN}●${NC} In Progress: $n_in_progress    ${GREEN}✓${NC} Done: $n_done    ${RED}✗${NC} Blocked: $n_blocked"
    echo ""

    # Active tasks
    if [[ ${#ACTIVE_TASKS[@]} -gt 0 ]]; then
        echo -e "${BOLD}  Active Tasks:${NC}"
        for task_id in "${!ACTIVE_TASKS[@]}"; do
            echo -e "    ${CYAN}●${NC} $task_id  [tmux window: ${ACTIVE_TASKS[$task_id]}]"
        done
        echo ""
    fi

    # Blocked tasks (important — surface these prominently)
    if [[ "$n_blocked" -gt 0 ]]; then
        echo -e "${BOLD}${RED}  ⚠ BLOCKED TASKS:${NC}"
        for task_file in $(list_tasks "$QUEUE_DIR/blocked"); do
            local tid
            tid=$(task_id "$task_file")
            echo -e "    ${RED}✗${NC} $tid — $(head -20 "$task_file" | grep '^## Summary' -A1 | tail -1 | sed 's/^[[:space:]]*//')"
        done
        echo ""
    fi

    # Approved tasks waiting
    if [[ "$n_approved" -gt 0 ]]; then
        echo -e "${BOLD}  Queue (approved, waiting):${NC}"
        for task_file in $(list_tasks "$QUEUE_DIR/approved"); do
            local tid dep_status
            tid=$(task_id "$task_file")
            if task_deps_met "$task_file"; then
                dep_status="${GREEN}ready${NC}"
            else
                dep_status="${YELLOW}waiting on deps${NC}"
            fi
            echo -e "    ${YELLOW}◐${NC} $tid  [$dep_status]"
        done
        echo ""
    fi

    # Recent done
    if [[ "$n_done" -gt 0 ]]; then
        echo -e "${BOLD}  Recently Completed:${NC}"
        for task_file in $(list_tasks "$QUEUE_DIR/done" | tail -5); do
            local tid
            tid=$(task_id "$task_file")
            echo -e "    ${GREEN}✓${NC} $tid"
        done
        echo ""
    fi

    # Footer
    local now
    now=$(date '+%H:%M:%S')
    echo -e "  ${BOLD}Last poll:${NC} $now  ${BOLD}Parallel limit:${NC} $MAX_PARALLEL  ${BOLD}Poll interval:${NC} ${POLL_INTERVAL}s"
    echo -e "  ${BOLD}Ctrl+C${NC} to stop orchestrator"
}

# --- Task Execution ---

run_task() {
    local task_file="$1"
    local tid
    tid=$(task_id "$task_file")
    local filename
    filename=$(basename "$task_file")

    echo "[$(date '+%H:%M:%S')] Starting task: $tid"

    # Move to in-progress
    local new_file
    new_file=$(move_task "$task_file" "$QUEUE_DIR/in-progress" "in-progress")

    # Build the prompt file
    # Read the skill template and substitute $ARGUMENTS
    # Prepend a note that the task has already been moved to in-progress by the orchestrator
    local skill_file="$PROJECT_DIR/.claude/commands/work-task.md"
    local prompt_file="/tmp/autopilot-prompt-${tid}.txt"
    {
        echo "NOTE: The orchestrator has already moved this task to queue/in-progress/${filename} and set its status to in-progress. Skip Step 2 (Move Task to In-Progress) — start from Step 1 (read context) then go straight to Step 3 (do the work)."
        echo ""
        sed "s/\\\$ARGUMENTS/$filename/g" "$skill_file"
    } > "$prompt_file"

    # Get the tmux session
    local session
    session=$(ensure_session "$PROJECT_NAME")

    # Spawn an interactive claude session in a tmux window (no -p flag, so TUI is visible)
    local window
    window=$(spawn_task_pane "$session" "$tid" "$prompt_file" "$PROJECT_DIR")

    # Track it
    ACTIVE_TASKS["$tid"]="$window"
}

# Check if active tasks have finished
check_active_tasks() {
    local session
    session="${TMUX_SESSION}-${PROJECT_NAME}"

    for tid in "${!ACTIVE_TASKS[@]}"; do
        if ! pane_is_running "$session" "$tid"; then
            echo "[$(date '+%H:%M:%S')] Task $tid session ended"
            unset ACTIVE_TASKS["$tid"]

            # Check where the task ended up
            if [[ -f "$QUEUE_DIR/done/$tid.md" ]]; then
                notify_done "$tid" ""
            elif [[ -f "$QUEUE_DIR/blocked/$tid.md" ]]; then
                notify_blocked "$tid" "Task moved to blocked"
            fi

            # Clean up the tmux window
            kill_task_pane "$session" "$tid"
        fi
    done
}

# Check for milestone completion
check_milestone_completion() {
    # Get all milestones that have tasks
    local milestones
    milestones=$(for f in "$QUEUE_DIR"/done/*.md "$QUEUE_DIR"/approved/*.md "$QUEUE_DIR"/in-progress/*.md "$QUEUE_DIR"/pending/*.md; do
        [[ -f "$f" ]] && task_milestone "$f"
    done | sort -u)

    for milestone in $milestones; do
        [[ -z "$milestone" ]] && continue

        # Check if all tasks for this milestone are done
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
            # Check there are actually done tasks for this milestone
            local has_done=false
            for f in "$QUEUE_DIR/done"/*.md; do
                [[ -f "$f" ]] || continue
                if [[ "$(task_milestone "$f")" == "$milestone" ]]; then
                    has_done=true
                    break
                fi
            done

            if $has_done; then
                notify_milestone "$milestone"
                echo "[$(date '+%H:%M:%S')] Milestone complete: $milestone — run /consolidate $milestone"
            fi
        fi
    done
}

# --- Main Loop ---

echo "Autopilot orchestrator starting for: $PROJECT_DIR"
echo "Max parallel tasks: $MAX_PARALLEL"
echo "Poll interval: ${POLL_INTERVAL}s"
echo ""

# Ensure tmux session
ensure_session "$PROJECT_NAME" > /dev/null

trap 'echo ""; echo "Orchestrator stopped."; exit 0' INT TERM

poll_count=0

while true; do
    # Check finished tasks
    check_active_tasks

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
