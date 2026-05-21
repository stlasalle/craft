# Worker/Watcher Split Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split Craft's in-worker PR polling loop into a separate deterministic watcher process that dispatches LLM agents only when events fire. Ship `/fix-ci-failure` as the first remediation skill.

**Architecture:** Worker agents exit after creating a draft PR (instead of polling it). The orchestrator detects worker exit with a recorded PR URL and spawns a per-PR watcher pane running `bin/watcher.sh`. The watcher polls `gh pr view` on an interval, diffs state between polls, and takes one of three actions per event: (a) resolve deterministically (e.g., on `merged` → call `state_mark_done` and exit), (b) dispatch a narrow remediation skill in a fresh agent pane (e.g., on `ci_failed` → spawn `/fix-ci-failure`), or (c) log and keep polling. Event detection lives in `bin/lib/watcher-events.sh` as pure functions testable with JSON fixtures.

**Tech Stack:** Bash + `gh` CLI + `jq`. No new runtime dependencies. Uses the state backend interface from Plan 1. Ink UIs for the watcher come in a later plan.

---

## File Structure

**Files to create:**
- `bin/lib/watcher-events.sh` — pure event-detection functions: `watcher_extract_state`, `watcher_diff_events`, `watcher_dispatch_action`. No I/O other than reading inputs.
- `bin/watcher.sh` — the polling loop. Owns I/O: calls `gh`, reads/writes state file, spawns remediation panes, calls `state_mark_done` / `state_mark_blocked`. Sources `watcher-events.sh` + `state.sh` + `mux.sh`.
- `templates/.claude/commands/fix-ci-failure.md` — new skill file for CI-failure remediation agents.
- `test/test-watcher-events.sh` — unit tests for the event-detection functions.
- `test/fixtures/pr-state/*.json` — JSON fixture files used by the test file.

**Files to modify:**
- `bin/lib/mux-tmux.sh` — add `spawn_watcher_pane <session> <pr_number> <cmd>` that creates a window named `watch-pr-N`.
- `bin/lib/mux-cmux.sh` — same interface, cmux-specific.
- `bin/lib/mux.sh` — extend the documented interface to include `spawn_watcher_pane`.
- `bin/orchestrator.sh` — migrate `run_task` to use `state_claim_task`; track `ACTIVE_WATCHERS`; detect worker exit to `waiting/` with a `pr:` field and spawn a watcher.
- `templates/.claude/commands/work-task.md` — remove Step 9 (the PR polling loop) and Step 10 (the completion flow now owned by the watcher). Worker exits after Step 8's `state_mark_waiting` call.
- `Makefile` — `test` target runs `test-watcher-events.sh` alongside the others.

---

## Task 1: Test scaffolding for watcher events

**Files:**
- Create: `bin/lib/watcher-events.sh`
- Create: `test/test-watcher-events.sh`
- Create: `test/fixtures/pr-state/.gitkeep`
- Modify: `Makefile`

- [ ] **Step 1: Create empty `bin/lib/watcher-events.sh`**

```bash
#!/usr/bin/env bash
# watcher-events.sh — Pure event-detection functions for bin/watcher.sh.
#
# All functions here are side-effect-free: they take inputs (JSON strings,
# state files, or event names) and return outputs (state key=value blobs
# or event names). I/O lives in bin/watcher.sh, not here.

WATCHER_EVENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
```

- [ ] **Step 2: Create the test harness `test/test-watcher-events.sh`**

```bash
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
echo "────────────────────────────"
echo "$TESTS_RUN tests: $TESTS_PASSED passed, $TESTS_FAILED failed"

if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
fi
```

- [ ] **Step 3: Create the fixtures directory placeholder**

Run:
```bash
mkdir -p test/fixtures/pr-state
touch test/fixtures/pr-state/.gitkeep
chmod +x test/test-watcher-events.sh
```

- [ ] **Step 4: Wire the new test into the Makefile**

In `Makefile`, replace the `test` target:

```makefile
test:
	@echo "Running tests..."
	@bash $(CURDIR)/test/test-queue.sh
	@bash $(CURDIR)/test/test-state.sh
	@bash $(CURDIR)/test/test-watcher-events.sh
```

- [ ] **Step 5: Run `make test` — all three suites should pass**

Run: `make test`

Expected: `test-queue.sh` 34/34, `test-state.sh` 58/58, `test-watcher-events.sh` 1/1.

- [ ] **Step 6: Commit**

```bash
git add bin/lib/watcher-events.sh test/test-watcher-events.sh test/fixtures/pr-state/.gitkeep Makefile
git commit -m "feat(watcher): scaffold watcher-events library and test harness

Introduces bin/lib/watcher-events.sh (empty) and test/test-watcher-events.sh
with the standard test harness. Wires the new test file into make test."
```

---

## Task 2: `watcher_extract_state` — parse `gh pr view` JSON into a flat state blob

**Files:**
- Modify: `bin/lib/watcher-events.sh`
- Modify: `test/test-watcher-events.sh`
- Create: `test/fixtures/pr-state/open-draft-ci-pending.json`
- Create: `test/fixtures/pr-state/open-ci-failed.json`
- Create: `test/fixtures/pr-state/merged.json`

Input: JSON from `gh pr view --json state,isDraft,mergeable,statusCheckRollup,reviews,comments,mergedAt,title,number`.
Output: newline-separated `key=value` pairs capturing everything the diff function needs. We use a flat key=value format (not nested JSON) because bash diff-and-compare is cleanest on line-based text.

Expected keys emitted:
- `state` — `OPEN` / `MERGED` / `CLOSED`
- `is_draft` — `true` / `false`
- `mergeable` — `MERGEABLE` / `CONFLICTING` / `UNKNOWN`
- `checks_conclusion` — `SUCCESS` / `FAILURE` / `PENDING` (derived from `statusCheckRollup`: if any FAILURE, FAILURE; else if any PENDING or IN_PROGRESS, PENDING; else SUCCESS).
- `review_count` — integer
- `comment_count` — integer
- `approved_count` / `changes_requested_count` — integers summarising `reviews[].state`

- [ ] **Step 1: Create JSON fixtures**

`test/fixtures/pr-state/open-draft-ci-pending.json`:

```json
{
  "state": "OPEN",
  "isDraft": true,
  "mergeable": "MERGEABLE",
  "title": "feat: add widget",
  "number": 42,
  "mergedAt": null,
  "statusCheckRollup": [
    {"name": "lint", "conclusion": "SUCCESS", "status": "COMPLETED"},
    {"name": "unit-tests", "conclusion": null, "status": "IN_PROGRESS"}
  ],
  "reviews": [],
  "comments": []
}
```

`test/fixtures/pr-state/open-ci-failed.json`:

```json
{
  "state": "OPEN",
  "isDraft": false,
  "mergeable": "MERGEABLE",
  "title": "feat: add widget",
  "number": 42,
  "mergedAt": null,
  "statusCheckRollup": [
    {"name": "lint", "conclusion": "SUCCESS", "status": "COMPLETED"},
    {"name": "unit-tests", "conclusion": "FAILURE", "status": "COMPLETED"}
  ],
  "reviews": [
    {"state": "APPROVED", "author": {"login": "alice"}}
  ],
  "comments": [
    {"id": "c1"},
    {"id": "c2"}
  ]
}
```

`test/fixtures/pr-state/merged.json`:

```json
{
  "state": "MERGED",
  "isDraft": false,
  "mergeable": "UNKNOWN",
  "title": "feat: add widget",
  "number": 42,
  "mergedAt": "2026-04-21T12:00:00Z",
  "statusCheckRollup": [
    {"name": "lint", "conclusion": "SUCCESS", "status": "COMPLETED"},
    {"name": "unit-tests", "conclusion": "SUCCESS", "status": "COMPLETED"}
  ],
  "reviews": [
    {"state": "APPROVED", "author": {"login": "alice"}}
  ],
  "comments": []
}
```

- [ ] **Step 2: Add failing tests to `test/test-watcher-events.sh`**

Append before the `--- Summary ---` section:

```bash
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
```

- [ ] **Step 3: Run the tests — they should fail**

Run: `./test/test-watcher-events.sh`

Expected: `command not found: watcher_extract_state` on each assertion.

- [ ] **Step 4: Implement `watcher_extract_state`**

Append to `bin/lib/watcher-events.sh`:

```bash
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

    # Derive checks_conclusion from statusCheckRollup entries.
    # Priority: any FAILURE → FAILURE; else any null/IN_PROGRESS/PENDING → PENDING; else SUCCESS.
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
```

- [ ] **Step 5: Run the tests — they should pass**

Run: `./test/test-watcher-events.sh`

Expected: all assertions pass.

- [ ] **Step 6: Commit**

```bash
git add bin/lib/watcher-events.sh test/test-watcher-events.sh test/fixtures/pr-state/
git commit -m "feat(watcher): add watcher_extract_state for gh pr view JSON

Parses a gh pr view --json blob into a flat key=value state summary
used by the watcher polling loop. Covered by three JSON fixtures
representing open-draft-pending, open-ci-failed, and merged states."
```

---

## Task 3: `watcher_diff_events` — detect events from two state blobs

Takes two flat state blobs (previous, current — as multi-line strings) and emits event names representing changes, one per line. Events (in Plan 2 scope):

- `first_poll` — previous state is empty (first iteration after watcher start)
- `ci_failed` — `checks_conclusion` went `PENDING|SUCCESS` → `FAILURE`
- `ci_passed` — `checks_conclusion` went `PENDING|FAILURE` → `SUCCESS`
- `merged` — `state` became `MERGED`
- `closed` — `state` became `CLOSED` without merge (i.e., `state=CLOSED` and `mergedAt=null`)
- `draft_to_ready` — `is_draft` went `true` → `false`
- `mergeable_conflicting` — `mergeable` became `CONFLICTING`
- `new_review_received` — `review_count` increased
- `new_comment_received` — `comment_count` increased

**Files:**
- Modify: `bin/lib/watcher-events.sh`
- Modify: `test/test-watcher-events.sh`

- [ ] **Step 1: Add failing tests**

Append to `test/test-watcher-events.sh` before the `--- Summary ---`:

```bash
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
```

- [ ] **Step 2: Run tests — should fail**

Expected: `command not found: watcher_diff_events`.

- [ ] **Step 3: Implement `watcher_diff_events`**

Append to `bin/lib/watcher-events.sh`:

```bash
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

    # Review count grew.
    if [[ -n "$c_review" && -n "$p_review" ]] && (( c_review > p_review )); then
        echo "new_review_received"
    fi

    # Comment count grew.
    if [[ -n "$c_comment" && -n "$p_comment" ]] && (( c_comment > p_comment )); then
        echo "new_comment_received"
    fi
}
```

- [ ] **Step 4: Run tests — should pass**

Run: `./test/test-watcher-events.sh`

Expected: all new assertions pass.

- [ ] **Step 5: Commit**

```bash
git add bin/lib/watcher-events.sh test/test-watcher-events.sh
git commit -m "feat(watcher): add watcher_diff_events for state-transition detection

Takes two flat state blobs and emits event names for PR-state, CI,
draft-readiness, mergeability, review/comment-count transitions.
Empty previous state is handled with a first_poll event plus any
notable current-state conditions."
```

---

## Task 4: `watcher_dispatch_action` — map events to actions

Takes a single event name and returns the action to perform as a flat key=value blob. Actions:

- `kind=llm` + `skill=...` — dispatch a remediation agent by invoking the named skill
- `kind=terminal` + `transition=mark_done` or `transition=mark_blocked` — watcher itself calls `state_*` and exits
- `kind=hook` + `hook_name=...` — fire a plugin hook but keep polling
- `kind=log` — log-only, no action

Plan 2 dispatches for:

| Event | Action |
|---|---|
| `first_poll` | `kind=log` |
| `ci_failed` | `kind=llm skill=/fix-ci-failure` |
| `ci_passed` | `kind=log` |
| `merged` | `kind=terminal transition=mark_done` |
| `closed` | `kind=terminal transition=mark_blocked` |
| `draft_to_ready` | `kind=hook hook_name=on_ready` |
| `mergeable_conflicting` | `kind=log` (explicit deferral to Plan 5 `/resolve-merge-conflict`) |
| `new_review_received` | `kind=log` (explicit deferral to Plan 5 `/address-review-feedback`) |
| `new_comment_received` | `kind=log` (explicit deferral to Plan 5 `/address-review-comment`) |

**Files:**
- Modify: `bin/lib/watcher-events.sh`
- Modify: `test/test-watcher-events.sh`

- [ ] **Step 1: Add failing tests**

Append to `test/test-watcher-events.sh`:

```bash
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

# Unknown event also yields log (safe default)
action=$(watcher_dispatch_action "nonsense_event_xyz")
assert_contains "unknown event: kind=log" "kind=log" "$action"
```

- [ ] **Step 2: Run tests — should fail**

- [ ] **Step 3: Implement `watcher_dispatch_action`**

Append to `bin/lib/watcher-events.sh`:

```bash
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
        first_poll|ci_passed|mergeable_conflicting|new_review_received|new_comment_received)
            echo "kind=log"
            ;;
        *)
            echo "kind=log"
            echo "note=unknown event; default to log"
            ;;
    esac
}
```

- [ ] **Step 4: Run tests — should pass**

- [ ] **Step 5: Commit**

```bash
git add bin/lib/watcher-events.sh test/test-watcher-events.sh
git commit -m "feat(watcher): add watcher_dispatch_action event → action map

Centralises the mapping from event names to watcher actions:
- ci_failed → LLM dispatch of /fix-ci-failure
- merged / closed → terminal state transitions (handled by state.sh)
- draft_to_ready → plugin hook (on_ready)
- deferred events (review/comment/conflict) → log-only for now

Unknown events fall through to log for safety."
```

---

## Task 5: `spawn_watcher_pane` on the mux providers

Add a pane-spawning function to both multiplexer providers. The watcher needs its own cmux pane, named `watch-pr-N`, separate from task panes. We also need a generic `spawn_remediation_pane` for when the watcher dispatches an LLM agent, but that can be expressed as a task-like pane using the existing `spawn_task_pane` with a synthesised id — so we add only one new function here.

**Files:**
- Modify: `bin/lib/mux-tmux.sh`
- Modify: `bin/lib/mux-cmux.sh`
- Modify: `bin/lib/mux.sh`

- [ ] **Step 1: Add `spawn_watcher_pane` to `bin/lib/mux-tmux.sh`**

Append to `bin/lib/mux-tmux.sh`:

```bash
# spawn_watcher_pane <session> <pr_number> <cmd>
# Create a new tmux window named "watch-pr-<N>" running <cmd>.
# Returns the window ID.
spawn_watcher_pane() {
    local session="$1" pr_number="$2" cmd="$3"
    local window_name="watch-pr-${pr_number}"

    local window_id
    window_id=$(tmux new-window -t "${session}:" -n "$window_name" -P -F '#{window_id}' "$cmd")

    echo "$window_id"
}
```

- [ ] **Step 2: Add `spawn_watcher_pane` to `bin/lib/mux-cmux.sh`**

Read the current `mux-cmux.sh` to match its spawning style. Append an equivalent function:

```bash
# spawn_watcher_pane <session> <pr_number> <cmd>
# Create a new cmux pane named "watch-pr-<N>" running <cmd>.
spawn_watcher_pane() {
    local session="$1" pr_number="$2" cmd="$3"
    local window_name="watch-pr-${pr_number}"

    # cmux uses `cmux open` semantics already used by spawn_task_pane; mirror that.
    cmux open --session "$session" --name "$window_name" -- bash -c "$cmd"
    echo "$window_name"
}
```

If the existing `spawn_task_pane` in `mux-cmux.sh` uses a different invocation shape, match it exactly for `spawn_watcher_pane`. The key requirement is that the function creates a named pane in the cmux session running the given command.

- [ ] **Step 3: Document the new interface in `bin/lib/mux.sh`**

In the header comment of `bin/lib/mux.sh`, extend the interface list. Find:

```
#   kill_task_pane <session> <task-id>
#     → Clean up a task's pane/surface.
```

Replace that block with:

```
#   kill_task_pane <session> <task-id>
#     → Clean up a task's pane/surface.
#
#   spawn_watcher_pane <session> <pr_number> <cmd>
#     → Create a named pane/surface ("watch-pr-<N>") running the given command.
#       Returns the pane/surface identifier.
```

- [ ] **Step 4: Verify both providers declare the function**

Run:

```bash
bash -c 'MULTIPLEXER=tmux source bin/lib/mux.sh; declare -f spawn_watcher_pane > /dev/null && echo tmux:ok'
bash -c 'MULTIPLEXER=cmux source bin/lib/mux.sh; declare -f spawn_watcher_pane > /dev/null && echo cmux:ok'
```

Expected: `tmux:ok` and `cmux:ok`.

- [ ] **Step 5: Run the test suites (no regression)**

Run: `make test`

Expected: all test suites pass. (These mux files aren't covered by automated tests today; the function-availability check above is the acceptance test.)

- [ ] **Step 6: Commit**

```bash
git add bin/lib/mux-tmux.sh bin/lib/mux-cmux.sh bin/lib/mux.sh
git commit -m "feat(mux): add spawn_watcher_pane on tmux and cmux providers

Per-PR watchers need their own named pane (watch-pr-<N>) distinct
from task panes. Both multiplexer providers now implement
spawn_watcher_pane; the shared mux.sh interface contract is updated."
```

---

## Task 6: `bin/watcher.sh` — the polling loop

The watcher ties everything together. Args: `pr_url`, `task_id`, `queue_dir`, `project_dir`. It:

1. Extracts the PR number from the URL.
2. Reads prior state from `<project_dir>/.state/watchers/<pr_number>.state` (flat key=value lines). Empty on first run.
3. Calls `gh pr view <pr_url> --json state,isDraft,mergeable,statusCheckRollup,reviews,comments,mergedAt,title,number`.
4. Runs `watcher_extract_state` on the JSON.
5. Runs `watcher_diff_events` on prev vs current.
6. For each event, runs `watcher_dispatch_action` and acts on it:
   - `kind=log` — echo the event to stdout
   - `kind=hook` — run `plugins/run-hook.sh <hook_name>` if present (fail silently if not)
   - `kind=terminal` — call `state_<transition>` and break the loop
   - `kind=llm` — spawn a remediation pane using `spawn_watcher_pane`-equivalent (actually `spawn_task_pane` with a synthesised id), passing a prompt file that loads the named skill. Wait for the pane to exit before continuing the poll loop (serial per-PR per plan).
7. Saves current state to the state file.
8. Sleeps for the configured poll interval.
9. Loops.

The watcher exits cleanly on terminal transitions. It is designed to be spawned in its own cmux pane and survive the orchestrator's lifetime.

**Files:**
- Create: `bin/watcher.sh`

- [ ] **Step 1: Create `bin/watcher.sh` skeleton**

```bash
#!/usr/bin/env bash
set -uo pipefail

# watcher.sh — Long-lived per-PR polling loop.
#
# Usage: watcher.sh --pr <pr-url> --task <task-id> --queue-dir <dir> --project-dir <dir> [--poll-interval <seconds>]
#
# Polls `gh pr view` on an interval, diffs state between polls, and
# dispatches remediation agents, plugin hooks, or terminal state
# transitions as events fire.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/state.sh"
source "$SCRIPT_DIR/lib/watcher-events.sh"
source "$SCRIPT_DIR/lib/providers.sh"

PR_URL=""
TASK_ID=""
QUEUE_DIR=""
PROJECT_DIR=""
POLL_INTERVAL=30

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pr)            PR_URL="$2"; shift 2 ;;
        --task)          TASK_ID="$2"; shift 2 ;;
        --queue-dir)     QUEUE_DIR="$2"; shift 2 ;;
        --project-dir)   PROJECT_DIR="$2"; shift 2 ;;
        --poll-interval) POLL_INTERVAL="$2"; shift 2 ;;
        --help|-h)
            cat << 'HELP'
Usage: watcher.sh --pr <pr-url> --task <task-id> --queue-dir <dir> --project-dir <dir> [--poll-interval <seconds>]

Long-lived per-PR watcher. Polls the PR state via `gh`, detects
state transitions, and dispatches remediation agents or terminal
state changes.

Exits cleanly when the PR is merged (→ state_mark_done) or
closed (→ state_mark_blocked).
HELP
            exit 0
            ;;
        *) echo "watcher.sh: unknown arg '$1'" >&2; exit 1 ;;
    esac
done

for var in PR_URL TASK_ID QUEUE_DIR PROJECT_DIR; do
    if [[ -z "${!var}" ]]; then
        echo "watcher.sh: missing required arg for --${var,,} (use --help for usage)" >&2
        exit 1
    fi
done

# Derive the PR number from the URL (last path segment).
PR_NUMBER="${PR_URL##*/}"
if ! [[ "$PR_NUMBER" =~ ^[0-9]+$ ]]; then
    echo "watcher.sh: could not derive PR number from url '$PR_URL'" >&2
    exit 1
fi

STATE_FILE="$PROJECT_DIR/.state/watchers/${PR_NUMBER}.state"
mkdir -p "$(dirname "$STATE_FILE")"

log() {
    echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] watcher pr-${PR_NUMBER}: $*"
}

_run_hook() {
    local hook_runner="$PROJECT_DIR/plugins/run-hook.sh"
    if [[ -x "$hook_runner" ]]; then
        "$hook_runner" "$@" 2>/dev/null || true
    fi
}

# Read a key from an action blob (the output of watcher_dispatch_action).
_action_get() {
    local blob="$1" key="$2"
    echo "$blob" | grep "^${key}=" | head -1 | sed "s/^${key}=//"
}

# Spawn a remediation agent in a new pane.
# Uses the existing provider_task_cmd pattern to synthesise an agent
# invocation. The remediation runs synchronously — we wait for it to
# complete before returning to the polling loop (serial per-PR).
dispatch_remediation() {
    local skill="$1"
    local skill_name="${skill#/}"
    local prompt_file="/tmp/craft-remediation-${PR_NUMBER}-${skill_name}-$$.md"

    local skill_file="$PROJECT_DIR/.claude/commands/${skill_name}.md"
    if [[ ! -f "$skill_file" ]]; then
        log "skill file not found: $skill_file — skipping remediation"
        return 0
    fi

    local worktree_path
    worktree_path=$(_watcher_find_worktree "$TASK_ID") || worktree_path="$PROJECT_DIR"

    {
        echo "NOTE: You are a remediation agent dispatched by the watcher for PR ${PR_URL}."
        echo "Task: ${TASK_ID}. Worktree: ${worktree_path}."
        echo ""
        sed "s|\\\$ARGUMENTS|${PR_URL}|g" "$skill_file"
    } > "$prompt_file"

    load_provider_config "$PROJECT_DIR"
    local agent="${DEFAULT_AGENT:-claude}"
    local cmd
    cmd=$(provider_task_cmd "$agent" "$prompt_file" "$worktree_path")

    log "dispatching remediation: $skill (pr=$PR_NUMBER, task=$TASK_ID)"
    # Run synchronously so the polling loop stays serial per PR.
    bash -c "$cmd"
    rm -f "$prompt_file"
}

# Find the worktree path for a task. Reads branch from the task file
# and returns the matching worktrees/<repo>-<task-id> directory.
_watcher_find_worktree() {
    local tid="$1"
    local task_file
    task_file=$(state_find_task_by_id "$QUEUE_DIR" "$tid") || return 1
    local repos
    repos=$(task_field "$task_file" "repos")
    # repos is formatted like "[my-repo]" or "[repo-a, repo-b]" — take first.
    local first_repo
    first_repo=$(echo "$repos" | tr -d '[]' | tr ',' '\n' | head -1 | xargs)
    [[ -z "$first_repo" ]] && return 1
    local candidate="$PROJECT_DIR/worktrees/${first_repo}-${tid}"
    [[ -d "$candidate" ]] && { echo "$candidate"; return 0; }
    return 1
}

log "watcher starting (pr=$PR_URL, task=$TASK_ID, poll=${POLL_INTERVAL}s)"

prev_state=""
if [[ -f "$STATE_FILE" ]]; then
    prev_state=$(cat "$STATE_FILE")
fi

while true; do
    pr_json=$(gh pr view "$PR_URL" --json state,isDraft,mergeable,statusCheckRollup,reviews,comments,mergedAt,title,number 2>/dev/null) || {
        log "gh pr view failed; retrying after interval"
        sleep "$POLL_INTERVAL"
        continue
    }

    curr_state=$(watcher_extract_state "$pr_json")
    events=$(watcher_diff_events "$prev_state" "$curr_state")

    terminal=0
    if [[ -n "$events" ]]; then
        while IFS= read -r event; do
            [[ -z "$event" ]] && continue
            action=$(watcher_dispatch_action "$event")
            kind=$(_action_get "$action" "kind")
            case "$kind" in
                log)
                    log "event: $event"
                    ;;
                hook)
                    local_hook=$(_action_get "$action" "hook_name")
                    log "event: $event → hook $local_hook"
                    _run_hook "$local_hook" --task-id "$TASK_ID" --pr-url "$PR_URL" --pr-number "$PR_NUMBER"
                    ;;
                llm)
                    skill=$(_action_get "$action" "skill")
                    log "event: $event → dispatching $skill"
                    dispatch_remediation "$skill"
                    ;;
                terminal)
                    trans=$(_action_get "$action" "transition")
                    reason=$(_action_get "$action" "reason")
                    case "$trans" in
                        mark_done)
                            log "event: $event → state_mark_done"
                            state_mark_done "$QUEUE_DIR" "$TASK_ID" > /dev/null
                            ;;
                        mark_blocked)
                            log "event: $event → state_mark_blocked"
                            state_mark_blocked "$QUEUE_DIR" "$TASK_ID" "${reason:-PR closed without merging}" > /dev/null
                            ;;
                    esac
                    terminal=1
                    ;;
            esac
        done <<< "$events"
    fi

    # Persist current state for the next iteration.
    echo "$curr_state" > "$STATE_FILE"

    if (( terminal == 1 )); then
        log "terminal event reached; watcher exiting"
        exit 0
    fi

    prev_state="$curr_state"
    sleep "$POLL_INTERVAL"
done
```

- [ ] **Step 2: Make watcher.sh executable**

Run: `chmod +x bin/watcher.sh`

- [ ] **Step 3: Syntax-check the script**

Run: `bash -n bin/watcher.sh`

Expected: exits 0, no output.

- [ ] **Step 4: Help text works**

Run: `./bin/watcher.sh --help`

Expected: usage text printed to stdout; exit 0.

- [ ] **Step 5: Missing args error**

Run: `./bin/watcher.sh --pr https://github.com/x/y/pull/1`

Expected: exits 1 with message about missing required arg.

- [ ] **Step 6: Invalid PR URL error**

Run: `./bin/watcher.sh --pr not-a-url --task task-001 --queue-dir /tmp --project-dir /tmp`

Expected: exits 1 with message "could not derive PR number".

- [ ] **Step 7: Function-availability check**

Verify that sourcing the deps works and the script has all functions it needs:

```bash
bash -c '
    source bin/lib/state.sh
    source bin/lib/watcher-events.sh
    source bin/lib/providers.sh
    for fn in watcher_extract_state watcher_diff_events watcher_dispatch_action \
              state_mark_done state_mark_blocked state_find_task_by_id \
              provider_task_cmd load_provider_config; do
        if ! declare -f "$fn" > /dev/null; then
            echo "MISSING: $fn"
            exit 1
        fi
    done
    echo "functions OK"
'
```

Expected: `functions OK`.

- [ ] **Step 8: Commit**

```bash
git add bin/watcher.sh
git commit -m "feat(watcher): add bin/watcher.sh polling loop

Long-lived per-PR watcher that polls gh pr view, diffs state between
iterations, and dispatches actions via watcher_dispatch_action:
- CI failures → spawns a /fix-ci-failure remediation agent
- merged → state_mark_done; exits
- closed → state_mark_blocked; exits
- draft→ready → on_ready plugin hook
- review/comment/conflict events → log-only in Plan 2

Serial per-PR: remediation agents run synchronously within the watcher's
loop so only one fix attempt is in flight per PR at any time."
```

---

## Task 7: `/fix-ci-failure` skill

Narrow remediation skill. Given a PR URL, inspect failing checks, find and fix the root cause, commit, push, and exit. Focused enough to be completable by a short agent session.

**Files:**
- Create: `templates/.claude/commands/fix-ci-failure.md`

- [ ] **Step 1: Create the skill file**

```markdown
# /fix-ci-failure — Fix a failing CI check on an open PR

You are a short-lived remediation agent dispatched by a PR watcher because at least one CI check failed on the pull request.

## Input

`$ARGUMENTS` — the PR URL (e.g., `https://github.com/owner/repo/pull/42`).

## Your Job

1. **Identify the failing check(s).**
   - Run `gh pr checks <pr-url>` to list all checks and their statuses.
   - Focus on checks with `conclusion: FAILURE`. Ignore PENDING and SUCCESS.

2. **Read the failure details.**
   - For each failing check, run `gh api` or `gh run view` to fetch log output.
   - If the failure is from a Buildkite-posted check, the `targetUrl` in the check payload points to the Buildkite build; the check's annotation or summary usually has the relevant failure excerpt.
   - Read enough to determine the *root cause* — a failing test, a lint violation, a compilation error, a missing migration, etc.

3. **Navigate to the worktree.**
   - The prompt prefix you received names the worktree path. `cd` there before making any changes.
   - Do NOT modify files anywhere else on disk.

4. **Make the minimal fix.**
   - Fix only what's required to make the failing check pass.
   - Do NOT refactor unrelated code.
   - Do NOT add new features or tests beyond what the failure requires.
   - Follow the existing conventions in the repo.

5. **Verify locally if possible.**
   - If the failure is a unit test, run it locally to confirm your fix works.
   - If the failure is lint/typecheck, run the linter to confirm.
   - If you can't verify locally (e.g., an integration test that requires infrastructure), document what you tried.

6. **Commit and push.**
   - Use a conventional commit: `fix: <short description of what you fixed>`.
   - Do NOT reference the task ID in the commit message.
   - `git push` to the same branch.

7. **Exit.**
   - Do not comment on the PR.
   - Do not mark it as ready.
   - Do not merge.
   - The watcher will detect the new push, re-run its poll, and see the CI status transition on its own.

## Important Rules

- ONLY work in the worktree. Never modify files outside.
- NEVER mark the PR as ready or merge it. The operator controls those gates.
- NEVER disable or skip the failing check to "fix" it. Fix the underlying code.
- NEVER push force-push (`--force`) unless the branch has no history beyond your own changes.
- If you cannot determine the root cause, cannot fix it in this session, OR the fix requires changes outside the worktree: exit without pushing. The watcher will log that the remediation ran and the PR will remain in its failing state for operator attention.
- Keep the session tight — this is a focused fix, not a rework.
```

- [ ] **Step 2: Verify the skill file is readable**

Run:

```bash
head -3 templates/.claude/commands/fix-ci-failure.md
```

Expected: first three lines of the skill file.

- [ ] **Step 3: Commit**

```bash
git add templates/.claude/commands/fix-ci-failure.md
git commit -m "feat(skill): add /fix-ci-failure remediation skill

Narrow skill invoked by the watcher when a CI check fails on an
open PR. Reads failing check details via gh, navigates to the
worktree, makes a minimal fix, commits, pushes, and exits. The
watcher's next poll iteration sees the new state on its own."
```

---

## Task 8: Orchestrator — migrate `run_task` to `state_claim_task` + pass context to workers

Two related changes in `run_task`:
1. Migrate the approved → in-progress move from direct `move_task` to `state_claim_task`.
2. Extend the prompt prefix so the worker knows the absolute paths to `CRAFT_ROOT` and `QUEUE_DIR`. Workers need these to `source "$CRAFT_ROOT/bin/lib/state.sh"` and call `state_mark_waiting`/`state_append_note` (see Task 10).

**Files:**
- Modify: `bin/orchestrator.sh`

- [ ] **Step 1: Locate `run_task` in `bin/orchestrator.sh`**

Run: `grep -n 'run_task()' bin/orchestrator.sh`

Expected: line number of the function definition.

- [ ] **Step 2: Replace the `move_task` call with `state_claim_task`**

Find this block in `run_task` (around lines 205-210):

```bash
    # Move to in-progress and notify plugins
    local new_file
    new_file=$(move_task "$task_file" "$QUEUE_DIR/in-progress" "in-progress")
    notify_started "$tid"
```

Replace with:

```bash
    # Claim the task via the state interface (moves approved -> in-progress,
    # sets the started timestamp).
    local new_file
    new_file=$(state_claim_task "$QUEUE_DIR" "$tid") || {
        log "Failed to claim task $tid"
        return 1
    }
    notify_started "$tid"
```

- [ ] **Step 3: Extend the prompt prefix with CRAFT_ROOT and QUEUE_DIR**

In the same `run_task` function, find the prompt-file construction:

```bash
    local skill_file="$PROJECT_DIR/.claude/commands/work-task.md"
    local prompt_file="/tmp/craft-prompt-${tid}.txt"
    {
        echo "NOTE: The orchestrator has already moved this task to queue/in-progress/${filename} and set its status to in-progress. Skip Step 2 (Move Task to In-Progress) — start from Step 1 (read context) then go straight to Step 3 (do the work)."
        echo ""
        sed "s/\\\$ARGUMENTS/$filename/g" "$skill_file"
    } > "$prompt_file"
```

Replace with:

```bash
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
```

- [ ] **Step 4: Syntax check**

Run: `bash -n bin/orchestrator.sh`

Expected: exits 0.

- [ ] **Step 5: Run the test suites (no regression)**

Run: `make test`

Expected: 34 + 58 + all watcher tests green.

- [ ] **Step 6: Commit**

```bash
git add bin/orchestrator.sh
git commit -m "refactor(orchestrator): claim via state_claim_task + pass context to workers

- run_task now uses state_claim_task (matches timeout path in Plan 1).
- The prompt prefix exposes CRAFT_ROOT, PROJECT_DIR, and QUEUE_DIR to the
  worker so /work-task can source state.sh and call state_mark_waiting
  after creating the PR."
```

---

## Task 9: Orchestrator — track watchers and spawn on PR creation

The orchestrator needs to (a) track `ACTIVE_WATCHERS` alongside `ACTIVE_TASKS`, (b) detect when a worker exits having moved its task to `waiting/` with a `pr:` field, and (c) spawn a watcher pane for that PR. The watcher itself then owns the transition from waiting → done or waiting → blocked.

**Files:**
- Modify: `bin/orchestrator.sh`

- [ ] **Step 1: Add the `ACTIVE_WATCHERS` associative array**

Near the existing `declare -A ACTIVE_TASKS=()` block in `bin/orchestrator.sh`, add:

```bash
declare -A ACTIVE_WATCHERS=()  # pr_number -> tmux window name
```

- [ ] **Step 2: Add a helper to spawn a watcher for a given task file**

Below the existing helpers in `bin/orchestrator.sh` (after `find_task_in` but before `check_active_tasks`), add:

```bash
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
```

- [ ] **Step 3: Detect waiting tasks without watchers and spawn**

In the main loop of the orchestrator (inside `check_waiting_tasks` OR as a new sibling function), add a pass that spawns watchers for any task in `waiting/` that doesn't already have an active watcher.

Find the existing `check_waiting_tasks` function (around line 376). Below its closing brace, add a new function:

```bash
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
```

- [ ] **Step 4: Reap watchers when the task leaves `waiting/`**

Add this sibling function below `ensure_watchers_for_waiting`:

```bash
# Clean up watcher entries whose PR's task is no longer in waiting/.
reap_finished_watchers() {
    for pr_number in "${!ACTIVE_WATCHERS[@]}"; do
        # Is there still a waiting task referencing this pr_number?
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
```

- [ ] **Step 5: Wire both calls into the main polling loop**

Find the main `while true` loop at the bottom of the file. Currently it calls:

```bash
    # Run plugin poll hooks (e.g. linear-sync inbound)
    _run_hook on_poll 2>/dev/null || true

    # Check finished tasks
    check_active_tasks

    # Check for new waiting tasks
    check_waiting_tasks
```

Replace that block with:

```bash
    # Run plugin poll hooks (e.g. linear-sync inbound)
    _run_hook on_poll 2>/dev/null || true

    # Check finished tasks
    check_active_tasks

    # Check for new waiting tasks
    check_waiting_tasks

    # Spawn watchers for any waiting task without one; reap finished watchers.
    ensure_watchers_for_waiting
    reap_finished_watchers
```

- [ ] **Step 6: Update the dashboard to show active watchers**

Find the `render_dashboard` function. After the "Active Tasks:" section (after the closing `fi` of the `if [[ ${#ACTIVE_TASKS[@]} -gt 0 ]]` block), add:

```bash
    # Active watchers
    if [[ ${#ACTIVE_WATCHERS[@]} -gt 0 ]]; then
        echo -e "${BOLD}  Active Watchers:${NC}"
        for pr_number in "${!ACTIVE_WATCHERS[@]}"; do
            echo -e "    ${YELLOW}◉${NC} PR #$pr_number  [tmux: ${ACTIVE_WATCHERS[$pr_number]}]"
        done
        echo ""
    fi
```

- [ ] **Step 7: Syntax-check**

Run: `bash -n bin/orchestrator.sh`

Expected: exits 0.

- [ ] **Step 8: Function-availability check**

Run:

```bash
bash -c '
    set -u
    source bin/lib/state.sh
    source bin/lib/providers.sh
    load_provider_config "'"$PWD"'"
    source bin/lib/mux.sh
    for fn in spawn_watcher_pane ensure_session state_claim_task; do
        declare -f "$fn" > /dev/null || { echo MISSING:$fn; exit 1; }
    done
    echo OK
'
```

Expected: `OK`.

- [ ] **Step 9: Run the test suites**

Run: `make test`

Expected: all suites green.

- [ ] **Step 10: Commit**

```bash
git add bin/orchestrator.sh
git commit -m "feat(orchestrator): track watchers and spawn on PR creation

ACTIVE_WATCHERS associative array tracks per-PR watcher panes.
ensure_watchers_for_waiting spawns a watcher for any task in waiting/
with a recorded pr: field. reap_finished_watchers drops entries
whose tasks have moved on. Dashboard renders active watchers.

Worker tasks now transfer PR monitoring to a dedicated watcher
pane on exit; the worker skill itself stops polling (Task 10)."
```

---

## Task 10: Rewrite `/work-task` — worker exits after PR creation

The existing `/work-task` has a 192-line procedure including a polling loop in Step 9 and a completion flow in Step 10. Both of those are now the watcher's responsibility. The worker's job shrinks to: read context → worktree → implement → QA → draft PR → self-review → `state_mark_waiting` → exit.

**Files:**
- Modify: `templates/.claude/commands/work-task.md`

- [ ] **Step 1: Replace the skill content**

Rewrite `templates/.claude/commands/work-task.md` to this content. Do NOT keep any of the old Steps 9 or 10.

```markdown
# /work-task — Execute a task end-to-end up to the draft PR

You are the work-task skill. Your job is to pick up a task from the project queue, do the work described in it, produce a draft PR, and then exit. A separate watcher process takes over from there — it polls the PR, dispatches remediation agents (CI fixes, review-comment responses) as events happen, and transitions the task to done/blocked when the PR merges or closes. **You do not monitor the PR.**

## Input

The user provides a task filename: `$ARGUMENTS`

If no argument is provided, scan `queue/approved/` and pick the first task whose `depends_on` is all satisfied (in `queue/done/` or `queue/archive/`).

## Step 1: Read and understand the context

1. Read the task file from `queue/in-progress/$ARGUMENTS` (the orchestrator has already moved it from `approved/` on your behalf).
2. Parse the YAML frontmatter: `type`, `milestone`, `depends_on`, `repos`, `branch`, `qa`.
3. Read the project plan: `docs/plan.md`.
4. Read the relevant milestone doc if it exists: `docs/milestones/<milestone>.md`.
5. Read any ADRs referenced in the task or milestone.
6. Read `state.md` for current project context.

## Step 2: Set up the worktree

1. For each repo in the task's `repos:` list, locate the main clone. Check `$CRAFT_PROJECTS/<project>/repos/<repo-name>` first; fall back to `~/code/<repo-name>` if that doesn't exist.
2. Create a worktree:
   - Path: `worktrees/<repo-name>-<task-id>/`
   - Command: `git -C <main-clone> worktree add <worktree-path> -b <branch> origin/main`
3. Do all code work inside the worktree — never in `repos/` or `~/code/`.

## Step 3: Do the work

1. Navigate to the worktree.
2. Read existing code before modifying — understand conventions.
3. Implement the changes described in the task's Summary and Acceptance Criteria.
4. Append progress notes to the task's Work Log via `state_append_note "$QUEUE_DIR" "<task-id>" "<note>"` (sourced from `bin/lib/state.sh` of the craft repo).

## Step 4: Run QA per the `qa:` spec

- `unit_tests: true` — run the repo's unit tests. Fix any regressions you introduced. Log output.
- `integration_tests: true` — run integration tests. Same approach.
- `local_validation: "command"` — run the specified command and confirm success.
- `qa_env: true` — **do not attempt.** Log: "QA environment validation required — flagged for {{OPERATOR_NAME}}."
- `prod_validation: true` — **do not attempt.** Log: "Production validation required — flagged for {{OPERATOR_NAME}}."

If any automated QA step fails and you cannot fix it after 2 attempts:
1. Call `state_mark_blocked "$QUEUE_DIR" "<task-id>" "<reason>"`.
2. Stop — do not create a PR.

## Step 5: Create the draft PR

1. Stage and commit with a conventional message (e.g. `feat: add widget`). Do NOT include the task ID in the commit message.
2. `git push -u origin <branch>`.
3. `gh pr create --draft` with:
   - Title: conventional style (e.g. `feat: add per-entity backfill flag`).
   - Body: Summary of changes + QA results + any notes or concerns.
   - `--reviewer {{GITHUB_REVIEWER}}` if `GITHUB_REVIEWER` is set in `craft.conf`; omit the flag otherwise.
4. Capture the PR URL.

## Step 6: Self-review

1. `gh pr diff <pr-number>` to see the full diff.
2. For each changed file, re-read to check context.
3. Review for correctness, code quality, testing, security, and performance.
4. If you find issues: fix them, commit, push.
5. Append a brief self-review summary to the Work Log via `state_append_note`.

**Do NOT post GitHub review comments on your own PR.** Automated PR review bots will review it once the operator marks it ready. Don't duplicate.

## Step 7: Hand off to the watcher

1. Call `state_mark_waiting "$QUEUE_DIR" "<task-id>" "<pr-url>"`. This moves the task from `in-progress/` to `waiting/` and records the PR URL in the frontmatter.
2. Append a final Work Log entry: `state_append_note "$QUEUE_DIR" "<task-id>" "PR created and handed off to watcher: <pr-url>"`.
3. **Exit.** Run `/exit`. The orchestrator will detect the pane has closed and spawn a watcher for the PR on its next poll cycle.

## Failure handling

If you hit an unrecoverable error at any point:
1. Call `state_mark_blocked "$QUEUE_DIR" "<task-id>" "<clear explanation>"`.
2. `/exit`.

## Important rules

- NEVER merge a PR — only create draft PRs.
- NEVER modify files outside the task's worktree.
- ALWAYS work in the worktree (`worktrees/<repo>-<task-id>/`), never in `repos/` or `~/code/`.
- ALWAYS run the QA steps specified in the task before creating the PR.
- ALWAYS use the branch name from the task's `branch:` frontmatter.
- ALWAYS use conventional commit messages (`feat:`, `fix:`, `refactor:`, etc.) — never prefix with task IDs.
- **DO NOT poll the PR after creating it.** The watcher handles all post-PR lifecycle events — CI failures, review comments, merges, closures. You are done the moment you've called `state_mark_waiting` and exited.
```

- [ ] **Step 2: Verify file is readable and committed correctly**

Run:

```bash
wc -l templates/.claude/commands/work-task.md
```

Expected: file exists and is notably shorter than the previous version (old ~192 lines; new should be ~80-100 lines).

- [ ] **Step 3: Commit**

```bash
git add templates/.claude/commands/work-task.md
git commit -m "refactor(skill): /work-task exits after PR creation

Removes the in-worker polling loop (old Steps 9-10). The worker's
job now ends at state_mark_waiting — a separate watcher process
(spawned by the orchestrator) owns the PR-lifecycle monitoring
and all remediation dispatch."
```

---

## Self-Review Checklist (run after all tasks)

- [ ] `make test` passes — `test-queue.sh` 34/34, `test-state.sh` 58/58, `test-watcher-events.sh` all green.
- [ ] `bash -n` succeeds on all modified bash scripts.
- [ ] `./bin/watcher.sh --help` prints usage.
- [ ] `grep -n 'move_task' bin/orchestrator.sh` returns zero direct references — all state transitions go through `state_*`.
- [ ] `templates/.claude/commands/work-task.md` contains no polling loop or "while true" reference.
- [ ] A fresh `craft init` produces a project whose `.claude/commands/` contains `fix-ci-failure.md`.
- [ ] Both `spawn_watcher_pane` implementations exist and can be sourced via `mux.sh` with either `MULTIPLEXER=tmux` or `MULTIPLEXER=cmux`.
- [ ] No `TBD`, `TODO`, or placeholder strings in any new or modified file.

---

## What's Next

Plan 3 (Linear state backend) can now build against the same interface. Plan 4 (Ink UIs) can replace the plain-text watcher output with a reactive Ink pane. Plan 5 adds the remaining remediation skills (`/address-review-comment`, `/resolve-merge-conflict`, `/investigate-pr-close`, intervention skills) — plumbing is already in place because `watcher_dispatch_action` is a single switch statement to extend.
