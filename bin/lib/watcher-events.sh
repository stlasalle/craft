#!/usr/bin/env bash
# watcher-events.sh — Pure event-detection functions for bin/watcher.sh.
#
# All functions here are side-effect-free: they take inputs (JSON strings,
# state files, or event names) and return outputs (state key=value blobs
# or event names). I/O lives in bin/watcher.sh, not here.

WATCHER_EVENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# watcher_extract_state <json>
# Read a JSON blob from `gh pr view` and emit a flat key=value state
# summary, one pair per line. Keys: state, is_draft, mergeable,
# checks_conclusion, review_count, comment_count, approved_count,
# changes_requested_count.
watcher_extract_state() {
    local json="$1"

    local state is_draft mergeable review_count comment_count
    state=$(echo "$json" | jq -r '.state // "UNKNOWN"')
    is_draft=$(echo "$json" | jq -r '.isDraft // false')
    mergeable=$(echo "$json" | jq -r '.mergeable // "UNKNOWN"')
    review_count=$(echo "$json" | jq -r '.reviews // [] | length')
    comment_count=$(echo "$json" | jq -r '.comments // [] | length')

    # Derive checks_conclusion from statusCheckRollup.
    # Priority: any FAILURE → FAILURE; else any null/IN_PROGRESS/PENDING/QUEUED → PENDING; else SUCCESS.
    local checks_conclusion
    checks_conclusion=$(echo "$json" | jq -r '
        .statusCheckRollup // []
        | if any(.conclusion == "FAILURE") then "FAILURE"
          elif any(.conclusion == null or .status == "IN_PROGRESS" or .status == "PENDING" or .status == "QUEUED") then "PENDING"
          else "SUCCESS"
          end
    ')

    local approved_count changes_requested_count
    approved_count=$(echo "$json" | jq -r '[.reviews // [] | .[] | select(.state == "APPROVED")] | length')
    changes_requested_count=$(echo "$json" | jq -r '[.reviews // [] | .[] | select(.state == "CHANGES_REQUESTED")] | length')

    cat << EOF
state=$state
is_draft=$is_draft
mergeable=$mergeable
checks_conclusion=$checks_conclusion
review_count=$review_count
comment_count=$comment_count
approved_count=$approved_count
changes_requested_count=$changes_requested_count
EOF
}

# _watcher_state_get <state_blob> <key>
# Extract the value for a key from a flat key=value state blob.
# Echoes the empty string if key is not found.
_watcher_state_get() {
    local blob="$1" key="$2"
    echo "$blob" | grep "^${key}=" | head -1 | sed "s/^${key}=//"
}

# watcher_diff_events <prev_state_blob> <current_state_blob>
# Emit event names (one per line) representing differences between the
# two states. If prev is empty, emits "first_poll" plus any notable
# current-state conditions.
watcher_diff_events() {
    local prev="$1" curr="$2"

    # Handle first-poll case: previous is empty.
    if [[ -z "$prev" ]]; then
        echo "first_poll"
        # Still emit per-condition events based on current state alone.
        local c_state c_checks c_mergeable
        c_state=$(_watcher_state_get "$curr" "state")
        c_checks=$(_watcher_state_get "$curr" "checks_conclusion")
        c_mergeable=$(_watcher_state_get "$curr" "mergeable")
        [[ "$c_state" == "MERGED" ]] && echo "merged"
        [[ "$c_state" == "CLOSED" ]] && echo "closed"
        [[ "$c_checks" == "FAILURE" ]] && echo "ci_failed"
        [[ "$c_mergeable" == "CONFLICTING" ]] && echo "mergeable_conflicting"
        return 0
    fi

    local p_state p_is_draft p_mergeable p_checks p_review p_comment
    p_state=$(_watcher_state_get "$prev" "state")
    p_is_draft=$(_watcher_state_get "$prev" "is_draft")
    p_mergeable=$(_watcher_state_get "$prev" "mergeable")
    p_checks=$(_watcher_state_get "$prev" "checks_conclusion")
    p_review=$(_watcher_state_get "$prev" "review_count")
    p_comment=$(_watcher_state_get "$prev" "comment_count")

    local c_state c_is_draft c_mergeable c_checks c_review c_comment
    c_state=$(_watcher_state_get "$curr" "state")
    c_is_draft=$(_watcher_state_get "$curr" "is_draft")
    c_mergeable=$(_watcher_state_get "$curr" "mergeable")
    c_checks=$(_watcher_state_get "$curr" "checks_conclusion")
    c_review=$(_watcher_state_get "$curr" "review_count")
    c_comment=$(_watcher_state_get "$curr" "comment_count")

    # PR state transitions.
    if [[ "$p_state" != "$c_state" ]]; then
        case "$c_state" in
            MERGED) echo "merged" ;;
            CLOSED) echo "closed" ;;
        esac
    fi

    # Draft → Ready.
    if [[ "$p_is_draft" == "true" && "$c_is_draft" == "false" ]]; then
        echo "draft_to_ready"
    fi

    # CI transitions.
    if [[ "$p_checks" != "$c_checks" ]]; then
        case "$c_checks" in
            FAILURE) echo "ci_failed" ;;
            SUCCESS) [[ "$p_checks" != "" ]] && echo "ci_passed" ;;
        esac
    fi

    # Merge conflict arose.
    if [[ "$p_mergeable" != "CONFLICTING" && "$c_mergeable" == "CONFLICTING" ]]; then
        echo "mergeable_conflicting"
    fi

    # Review count grew. Suppress the event when the only new reviews are
    # pure approvals — those don't need an LLM dispatch. We compare the
    # review-count delta to the approved-count delta: if the review delta
    # exceeds the approved delta, at least one non-approval review landed
    # (CHANGES_REQUESTED or COMMENTED), and we emit the event.
    if [[ -n "$c_review" && -n "$p_review" ]] && (( c_review > p_review )); then
        local p_approved c_approved
        p_approved=$(_watcher_state_get "$prev" "approved_count")
        c_approved=$(_watcher_state_get "$curr" "approved_count")
        # Default missing counts to 0 for safe arithmetic.
        : "${p_approved:=0}"
        : "${c_approved:=0}"
        local review_delta=$(( c_review - p_review ))
        local approved_delta=$(( c_approved - p_approved ))
        if (( review_delta > approved_delta )); then
            echo "new_review_received"
        fi
    fi

    # Comment count grew.
    if [[ -n "$c_comment" && -n "$p_comment" ]] && (( c_comment > p_comment )); then
        echo "new_comment_received"
    fi
}

# watcher_dispatch_action <event_name>
# Return the action to perform for a given event, as a flat key=value
# blob. Unknown events return kind=log (safe default).
watcher_dispatch_action() {
    local event="$1"
    case "$event" in
        ci_failed)
            echo "kind=llm"
            echo "skill=/fix-ci-failure"
            ;;
        new_comment_received|new_review_received)
            # Treat reviews and ad-hoc comments uniformly. Pure-approval
            # reviews are filtered upstream in watcher_diff_events so the
            # skill only runs when there's actionable feedback.
            echo "kind=llm"
            echo "skill=/address-review-comment"
            ;;
        merged)
            echo "kind=terminal"
            echo "transition=mark_done"
            ;;
        closed)
            echo "kind=terminal"
            echo "transition=mark_blocked"
            echo "reason=PR was closed without merging"
            ;;
        draft_to_ready)
            echo "kind=hook"
            echo "hook_name=on_ready"
            ;;
        first_poll|ci_passed|mergeable_conflicting)
            echo "kind=log"
            ;;
        *)
            echo "kind=log"
            echo "note=unknown event; default to log"
            ;;
    esac
}
