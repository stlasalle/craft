#!/usr/bin/env bash
# notify.sh — Notification helpers for the autopilot orchestrator

# Send a macOS notification
notify() {
    local title="$1" message="$2"
    osascript -e "display notification \"$message\" with title \"$title\"" 2>/dev/null || true
}

# Ring the terminal bell
bell() {
    printf '\a'
}

# Notify about a blocked task
notify_blocked() {
    local task_id="$1" reason="$2"
    notify "Autopilot — Blocked" "$task_id: $reason"
    bell
}

# Notify about a completed task
notify_done() {
    local task_id="$1" pr_url="$2"
    notify "Autopilot — Done" "$task_id: PR merged"
    bell
}

# Notify about a task waiting for review
notify_waiting() {
    local task_id="$1"
    notify "Autopilot — PR Ready for Review" "$task_id: Draft PR needs your attention"
    bell
}

# Notify about milestone completion
notify_milestone() {
    local milestone="$1"
    notify "Autopilot — Milestone Complete" "$milestone: All tasks done, ready for consolidation"
    bell
}
