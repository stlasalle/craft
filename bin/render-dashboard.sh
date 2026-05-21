#!/usr/bin/env bash
set -uo pipefail

# render-dashboard.sh — One-shot orchestrator dashboard renderer.
#
# Usage: render-dashboard.sh <project-dir>
#
# Reads queue/, .state/watchers/, and logs/ from the project directory
# and prints a single dashboard snapshot. Caller is responsible for
# clearing the screen / scheduling refreshes.

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <project-dir>" >&2
    exit 1
fi

PROJECT_DIR="$1"
QUEUE_DIR="$PROJECT_DIR/queue"
WATCHERS_DIR="$PROJECT_DIR/.state/watchers"
LOG_FILE="$PROJECT_DIR/logs/orchestrator-$(date '+%Y-%m-%d').log"
PROJECT_NAME="$(basename "$PROJECT_DIR")"

CRAFT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$CRAFT_ROOT/bin/lib/state.sh"

# ANSI
BOLD=$'\033[1m'
DIM=$'\033[2m'
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
CYAN=$'\033[0;36m'
NC=$'\033[0m'

n_pending=$(count_tasks "$QUEUE_DIR/pending")
n_approved=$(count_tasks "$QUEUE_DIR/approved")
n_in_progress=$(count_tasks "$QUEUE_DIR/in-progress")
n_waiting=$(count_tasks "$QUEUE_DIR/waiting")
n_done=$(count_tasks "$QUEUE_DIR/done")
n_blocked=$(count_tasks "$QUEUE_DIR/blocked")

# Header.
printf "%s╔═══════════════════════════════════════════════════════════════════╗%s\n" "$BOLD" "$NC"
printf "%s║  CRAFT — %-56s║%s\n" "$BOLD" "$PROJECT_NAME" "$NC"
printf "%s╚═══════════════════════════════════════════════════════════════════╝%s\n" "$BOLD" "$NC"
echo ""

# Queue.
printf "Queue   %s○%s pending %d   %s◐%s approved %d   %s●%s in-progress %d   %s◉%s waiting %d   %s✓%s done %d   %s✗%s blocked %d\n" \
    "$BLUE" "$NC" "$n_pending" \
    "$YELLOW" "$NC" "$n_approved" \
    "$CYAN" "$NC" "$n_in_progress" \
    "$YELLOW" "$NC" "$n_waiting" \
    "$GREEN" "$NC" "$n_done" \
    "$RED" "$NC" "$n_blocked"
echo ""

# Workers (in-progress tasks).
if (( n_in_progress > 0 )); then
    printf "%s  Workers%s\n" "$BOLD" "$NC"
    for f in $(list_tasks "$QUEUE_DIR/in-progress"); do
        local_tid=$(task_id "$f")
        title=$(grep '^# ' "$f" | head -1 | sed 's/^# //')
        printf "    %s●%s %-12s %s\n" "$CYAN" "$NC" "$local_tid" "${title:-(no title)}"
    done
    echo ""
fi

# Watchers (waiting tasks with pr field).
if (( n_waiting > 0 )); then
    printf "%s  Watchers%s\n" "$BOLD" "$NC"
    for f in $(list_tasks "$QUEUE_DIR/waiting"); do
        local_tid=$(task_id "$f")
        pr_url=$(task_field "$f" "pr")
        [[ -z "$pr_url" ]] && continue
        pr_number="${pr_url##*/}"
        title=$(grep '^# ' "$f" | head -1 | sed 's/^# //')
        # Freshness: mtime of the state file.
        state_file="$WATCHERS_DIR/${pr_number}.state"
        if [[ -f "$state_file" ]]; then
            now_epoch=$(date -u '+%s')
            # Try GNU stat first (which errors cleanly on macOS), then BSD stat.
            if file_epoch=$(stat -c '%Y' "$state_file" 2>/dev/null); then
                :
            else
                file_epoch=$(stat -f '%m' "$state_file" 2>/dev/null)
            fi
            # Guard against accidental non-numeric values.
            if ! [[ "$file_epoch" =~ ^[0-9]+$ ]]; then
                file_epoch=""
            fi
            if [[ -n "$file_epoch" ]]; then
                age=$(( now_epoch - file_epoch ))
                if (( age < 60 )); then
                    fresh="${GREEN}polled ${age}s ago${NC}"
                elif (( age < 300 )); then
                    fresh="${YELLOW}polled ${age}s ago${NC}"
                else
                    fresh="${RED}STALE (${age}s)${NC}"
                fi
            else
                fresh="${DIM}unknown${NC}"
            fi
            # Read CI status if available.
            ci=$(grep '^checks_conclusion=' "$state_file" | sed 's/^checks_conclusion=//')
            case "$ci" in
                SUCCESS) ci_disp="${GREEN}CI✓${NC}" ;;
                FAILURE) ci_disp="${RED}CI✗${NC}" ;;
                PENDING) ci_disp="${YELLOW}CI●${NC}" ;;
                *)       ci_disp="${DIM}CI?${NC}" ;;
            esac
        else
            fresh="${DIM}no state yet${NC}"
            ci_disp=""
        fi
        title_disp="${title:-(no title)}"
        printf "    %s◉%s pr-%-6s %-30s %b   %b\n" "$YELLOW" "$NC" "$pr_number" "${title_disp:0:30}" "$ci_disp" "$fresh"
    done
    echo ""
fi

# Approved (queued for pickup).
if (( n_approved > 0 )); then
    printf "%s  Queue (approved)%s\n" "$BOLD" "$NC"
    for f in $(list_tasks "$QUEUE_DIR/approved"); do
        local_tid=$(task_id "$f")
        if task_deps_met "$f"; then
            dep_status="${GREEN}ready${NC}"
        else
            dep_status="${YELLOW}waiting on deps${NC}"
        fi
        printf "    %s◐%s %-12s [%b]\n" "$YELLOW" "$NC" "$local_tid" "$dep_status"
    done
    echo ""
fi

# Blocked.
if (( n_blocked > 0 )); then
    printf "%s%s  ⚠ Blocked%s\n" "$BOLD" "$RED" "$NC"
    for f in $(list_tasks "$QUEUE_DIR/blocked"); do
        local_tid=$(task_id "$f")
        title=$(grep '^# ' "$f" | head -1 | sed 's/^# //')
        printf "    %s✗%s %-12s %s\n" "$RED" "$NC" "$local_tid" "${title:-}"
    done
    echo ""
fi

# Recent activity (last 6 lines of the log).
if [[ -f "$LOG_FILE" ]]; then
    printf "%s  Recent%s\n" "$BOLD" "$NC"
    tail -6 "$LOG_FILE" | while IFS= read -r line; do
        printf "    %s%s%s\n" "$DIM" "$line" "$NC"
    done
    echo ""
fi

# Footer.
now=$(date '+%H:%M:%S')
printf "%sUpdated: %s%s\n" "$DIM" "$now" "$NC"
