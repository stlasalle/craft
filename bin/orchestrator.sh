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
source "$SCRIPT_DIR/lib/providers.sh"

# --- Configuration ---
PROJECT_DIR=""
MAX_PARALLEL=10
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
for dir in approved in-progress done blocked archive waiting; do
    mkdir -p "$QUEUE_DIR/$dir"
done
mkdir -p "$PROJECT_DIR/worktrees"

# Load agent provider config (sets DEFAULT_AGENT, ARCHITECT_AGENT)
load_provider_config "$PROJECT_DIR"

# --- State tracking ---
declare -A ACTIVE_TASKS=()  # task_id -> tmux window name
declare -A TASK_AGENTS=()   # task_id -> agent provider (claude, codex, etc.)
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
    # Use ANSI escape to clear without triggering tmux activity detection
    printf '\033[2J\033[H'
}

render_dashboard() {
    clear_screen

    echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║  AUTOPILOT ORCHESTRATOR — ${CYAN}${PROJECT_NAME}${NC}${BOLD}$(printf '%*s' $((24 - ${#PROJECT_NAME})) '')║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""

    # Counts
    local n_pending n_approved n_in_progress n_done n_blocked n_waiting
    n_pending=$(count_tasks "$QUEUE_DIR/pending")
    n_approved=$(count_tasks "$QUEUE_DIR/approved")
    n_in_progress=$(count_tasks "$QUEUE_DIR/in-progress")
    n_done=$(count_tasks "$QUEUE_DIR/done")
    n_blocked=$(count_tasks "$QUEUE_DIR/blocked")
    n_waiting=$(count_tasks "$QUEUE_DIR/waiting")

    echo -e "  ${BLUE}○${NC} Pending: $n_pending  ${YELLOW}◐${NC} Approved: $n_approved  ${CYAN}●${NC} In Progress: $n_in_progress  ${YELLOW}◉${NC} Waiting: $n_waiting  ${GREEN}✓${NC} Done: $n_done  ${RED}✗${NC} Blocked: $n_blocked"
    echo ""

    # Waiting tasks — needs operator attention (PR review)
    if [[ "$n_waiting" -gt 0 ]]; then
        echo -e "${BOLD}${YELLOW}  ◉ WAITING FOR REVIEW:${NC}"
        for task_file in $(list_tasks "$QUEUE_DIR/waiting"); do
            local tid pr_url
            tid=$(task_id "$task_file")
            pr_url=$(task_field "$task_file" "pr")
            if [[ -n "$pr_url" ]]; then
                echo -e "    ${YELLOW}◉${NC} $tid  ${CYAN}$pr_url${NC}"
            else
                echo -e "    ${YELLOW}◉${NC} $tid"
            fi
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

    # Active tasks
    if [[ ${#ACTIVE_TASKS[@]} -gt 0 ]]; then
        echo -e "${BOLD}  Active Tasks:${NC}"
        for task_id in "${!ACTIVE_TASKS[@]}"; do
            local agent_label="${TASK_AGENTS[$task_id]:-$DEFAULT_AGENT}"
            echo -e "    ${CYAN}●${NC} $task_id  [${agent_label}] [tmux: ${ACTIVE_TASKS[$task_id]}]"
        done
        echo ""
    fi

    # Approved tasks queued
    if [[ "$n_approved" -gt 0 ]]; then
        echo -e "${BOLD}  Queue (approved):${NC}"
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
    echo -e "  ${BOLD}Last poll:${NC} $now  ${BOLD}Parallel limit:${NC} $MAX_PARALLEL  ${BOLD}Poll interval:${NC} ${POLL_INTERVAL}s  ${BOLD}Agent:${NC} $DEFAULT_AGENT"
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

# Check if active tasks have finished
check_active_tasks() {
    local session
    session="${TMUX_SESSION}-${PROJECT_NAME}"

    for tid in "${!ACTIVE_TASKS[@]}"; do
        if ! pane_is_running "$session" "$tid"; then
            echo "[$(date '+%H:%M:%S')] Task $tid session ended"
            unset ACTIVE_TASKS["$tid"]
            unset TASK_AGENTS["$tid"]

            # Check where the task ended up
            if find_task_in "$QUEUE_DIR/done" "$tid" > /dev/null; then
                notify_done "$tid" ""
            elif find_task_in "$QUEUE_DIR/blocked" "$tid" > /dev/null; then
                notify_blocked "$tid" "Task moved to blocked"
            elif find_task_in "$QUEUE_DIR/waiting" "$tid" > /dev/null; then
                notify_waiting "$tid"
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

# Check for new tasks in waiting state and notify
# Uses a marker file per task to survive orchestrator restarts
check_waiting_tasks() {
    local marker_dir="/tmp/autopilot-waiting-${PROJECT_NAME}"
    mkdir -p "$marker_dir"
    for task_file in $(list_tasks "$QUEUE_DIR/waiting"); do
        local tid
        tid=$(task_id "$task_file")
        [[ -z "$tid" ]] && continue
        if [[ ! -f "$marker_dir/$tid" ]]; then
            touch "$marker_dir/$tid"
            notify_waiting "$tid"
            echo "[$(date '+%H:%M:%S')] Task $tid is waiting for review"
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

# --- Main Loop ---

# Ensure tmux session with orchestrator + planner windows
SESSION=$(ensure_session "$PROJECT_NAME" "$PROJECT_DIR")

# If we're not already inside this tmux session, re-exec ourselves inside the orchestrator pane
if [[ -z "${TMUX:-}" ]] || [[ "$(tmux display-message -p '#{session_name}' 2>/dev/null)" != "$SESSION" ]]; then
    tmux send-keys -t "${SESSION}:orchestrator" "exec '$0' '$PROJECT_DIR' --max-parallel $MAX_PARALLEL --poll-interval $POLL_INTERVAL" Enter
    exec tmux attach -t "$SESSION"
fi

echo "Autopilot orchestrator starting for: $PROJECT_DIR"
echo "Max parallel tasks: $MAX_PARALLEL"
echo "Poll interval: ${POLL_INTERVAL}s"
echo ""

trap 'echo ""; echo "Orchestrator stopped."; exit 0' INT TERM

poll_count=0

while true; do
    # Check finished tasks
    check_active_tasks

    # Check for new waiting tasks
    check_waiting_tasks

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
