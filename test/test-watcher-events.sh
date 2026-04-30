#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CRAFT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURES_DIR="$SCRIPT_DIR/fixtures/pr-state"

source "$CRAFT_ROOT/bin/lib/watcher-events.sh"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

pass() { TESTS_PASSED=$((TESTS_PASSED + 1)); echo "  ✓ $1"; }
fail() { TESTS_FAILED=$((TESTS_FAILED + 1)); echo "  ✗ $1 — $2"; }

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$expected" == "$actual" ]]; then
        pass "$label"
    else
        fail "$label" "expected '$expected', got '$actual'"
    fi
}

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if echo "$haystack" | grep -q -- "$needle"; then
        pass "$label"
    else
        fail "$label" "expected to contain '$needle' in: $haystack"
    fi
}

echo "watcher-events scaffolding"
assert_eq "watcher-events.sh sourced" "1" "1"

echo ""
echo "watcher_extract_state"

state_draft=$(watcher_extract_state "$(cat "$FIXTURES_DIR/open-draft-ci-pending.json")")
assert_contains "open-draft: state=OPEN" "state=OPEN" "$state_draft"
assert_contains "open-draft: is_draft=true" "is_draft=true" "$state_draft"
assert_contains "open-draft: mergeable=MERGEABLE" "mergeable=MERGEABLE" "$state_draft"
assert_contains "open-draft: checks PENDING" "checks_conclusion=PENDING" "$state_draft"
assert_contains "open-draft: review_count=0" "review_count=0" "$state_draft"
assert_contains "open-draft: comment_count=0" "comment_count=0" "$state_draft"

state_failed=$(watcher_extract_state "$(cat "$FIXTURES_DIR/open-ci-failed.json")")
assert_contains "ci-failed: state=OPEN" "state=OPEN" "$state_failed"
assert_contains "ci-failed: is_draft=false" "is_draft=false" "$state_failed"
assert_contains "ci-failed: checks FAILURE" "checks_conclusion=FAILURE" "$state_failed"
assert_contains "ci-failed: review_count=1" "review_count=1" "$state_failed"
assert_contains "ci-failed: approved_count=1" "approved_count=1" "$state_failed"
assert_contains "ci-failed: comment_count=2" "comment_count=2" "$state_failed"

state_merged=$(watcher_extract_state "$(cat "$FIXTURES_DIR/merged.json")")
assert_contains "merged: state=MERGED" "state=MERGED" "$state_merged"
assert_contains "merged: checks SUCCESS" "checks_conclusion=SUCCESS" "$state_merged"

echo ""
echo "watcher_diff_events"

# Helper: capture extract for fixtures already loaded
state_draft=$(watcher_extract_state "$(cat "$FIXTURES_DIR/open-draft-ci-pending.json")")
state_failed=$(watcher_extract_state "$(cat "$FIXTURES_DIR/open-ci-failed.json")")
state_merged=$(watcher_extract_state "$(cat "$FIXTURES_DIR/merged.json")")

# First poll (empty previous)
events=$(watcher_diff_events "" "$state_draft")
assert_contains "first_poll emitted" "first_poll" "$events"

# Transition: pending CI → failed CI
events=$(watcher_diff_events "$state_draft" "$state_failed")
assert_contains "ci_failed event emitted" "ci_failed" "$events"

# Transition: pending → failed also implies draft→ready (fixture difference)
assert_contains "draft_to_ready event emitted" "draft_to_ready" "$events"

# Transition: pending → failed also adds a review
assert_contains "new_review_received event emitted" "new_review_received" "$events"

# Transition: pending → failed also adds comments
assert_contains "new_comment_received event emitted" "new_comment_received" "$events"

# Transition: failed → merged
events=$(watcher_diff_events "$state_failed" "$state_merged")
assert_contains "merged event emitted" "merged" "$events"
# merged implies CI went from FAILURE to SUCCESS on the merged fixture
assert_contains "ci_passed event emitted" "ci_passed" "$events"

# No changes
events=$(watcher_diff_events "$state_draft" "$state_draft")
assert_eq "no events when state unchanged" "" "$events"

echo ""
echo "watcher_dispatch_action"

action=$(watcher_dispatch_action "ci_failed")
assert_contains "ci_failed: kind=llm" "kind=llm" "$action"
assert_contains "ci_failed: skill=/fix-ci-failure" "skill=/fix-ci-failure" "$action"

action=$(watcher_dispatch_action "merged")
assert_contains "merged: kind=terminal" "kind=terminal" "$action"
assert_contains "merged: transition=mark_done" "transition=mark_done" "$action"

action=$(watcher_dispatch_action "closed")
assert_contains "closed: kind=terminal" "kind=terminal" "$action"
assert_contains "closed: transition=mark_blocked" "transition=mark_blocked" "$action"

action=$(watcher_dispatch_action "draft_to_ready")
assert_contains "draft_to_ready: kind=hook" "kind=hook" "$action"
assert_contains "draft_to_ready: hook_name=on_ready" "hook_name=on_ready" "$action"

# Deferred events yield kind=log
action=$(watcher_dispatch_action "new_review_received")
assert_contains "new_review_received: kind=log" "kind=log" "$action"

action=$(watcher_dispatch_action "mergeable_conflicting")
assert_contains "mergeable_conflicting: kind=log" "kind=log" "$action"

# Unknown event also yields log
action=$(watcher_dispatch_action "nonsense_event_xyz")
assert_contains "unknown event: kind=log" "kind=log" "$action"

echo ""
echo "────────────────────────────"
echo "$TESTS_RUN tests: $TESTS_PASSED passed, $TESTS_FAILED failed"

if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
fi
