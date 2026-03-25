#!/usr/bin/env bash
# notify.sh — Notification helpers for the autopilot orchestrator
#
# Uses sound + tmux bell only (no macOS notification popups).
# Notifies if Ghostty is not focused, or if the orchestrator's tmux pane isn't active.

NOTIFY_VOLUME="${NOTIFY_VOLUME:-0.5}"
NOTIFY_SOUND="${NOTIFY_SOUND:-/System/Library/Sounds/Glass.aiff}"

# Ring the bell on this pane's TTY so tmux highlights the window
_tmux_bell() {
    if [[ -n "${TMUX_PANE:-}" ]]; then
        local pane_tty
        pane_tty=$(tmux display-message -t "$TMUX_PANE" -p '#{pane_tty}' 2>/dev/null)
        if [[ -n "$pane_tty" ]]; then
            printf '\a' > "$pane_tty"
        fi
    else
        printf '\a'
    fi
}

# Check if we should notify (Ghostty not focused, or our pane not active)
_should_notify() {
    local frontmost
    frontmost=$(osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true' 2>/dev/null | tr '[:upper:]' '[:lower:]')

    # Ghostty not focused — always notify
    if [[ "$frontmost" != "ghostty" ]]; then
        return 0
    fi

    # Ghostty is focused — notify if our tmux pane isn't the active one
    if [[ -n "${TMUX_PANE:-}" ]]; then
        local active
        active=$(tmux display-message -t "$TMUX_PANE" -p '#{window_active}#{pane_active}' 2>/dev/null)
        if [[ "$active" != "11" ]]; then
            return 0
        fi
    fi

    # We're the active pane in the focused window — no need to notify
    return 1
}

# Play sound + tmux bell if appropriate
alert() {
    # Disabled — too noisy. Orchestrator dashboard is sufficient.
    :
}

# Notify about a blocked task
notify_blocked() {
    local task_id="$1" reason="$2"
    alert
}

# Notify about a completed task
notify_done() {
    local task_id="$1" pr_url="$2"
    alert
}

# Notify about a task waiting for review
notify_waiting() {
    local task_id="$1"
    alert
}

# Notify about milestone completion
notify_milestone() {
    local milestone="$1"
    alert
}
