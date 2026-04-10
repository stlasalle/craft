#!/usr/bin/env bash
set -uo pipefail

# test-queue.sh — Tests for bin/lib/queue.sh
#
# Usage: ./test/test-queue.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CRAFT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$CRAFT_ROOT/bin/lib/queue.sh"

# --- Test harness ---

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

assert_true() {
    local label="$1"; shift
    TESTS_RUN=$((TESTS_RUN + 1))
    if "$@" 2>/dev/null; then
        pass "$label"
    else
        fail "$label" "expected success, got failure"
    fi
}

assert_false() {
    local label="$1"; shift
    TESTS_RUN=$((TESTS_RUN + 1))
    if "$@" 2>/dev/null; then
        fail "$label" "expected failure, got success"
    else
        pass "$label"
    fi
}

# --- Setup ---

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

QUEUE_DIR="$TMPDIR/queue"
mkdir -p "$QUEUE_DIR"/{pending,approved,in-progress,done,blocked,archive}

# Create test task files
cat > "$QUEUE_DIR/pending/task-001.md" << 'EOF'
---
id: task-001
type: pr
milestone: m1-foundation
status: pending
depends_on: []
repos: [my-repo]
branch: feat/add-auth
qa:
  unit_tests: true
  integration_tests: false
---

# Add authentication

## Summary
Add basic auth.

## Acceptance Criteria
1. Auth works.
EOF

cat > "$QUEUE_DIR/pending/task-002.md" << 'EOF'
---
id: task-002
type: pr
milestone: m1-foundation
status: pending
depends_on: [task-001]
repos: [my-repo]
branch: feat/add-users
---

# Add user management

## Summary
Add user CRUD.
EOF

cat > "$QUEUE_DIR/approved/task-003.md" << 'EOF'
---
id: task-003
type: research
milestone: m1-foundation
status: approved
depends_on: []
repos: [my-repo]
branch: research/perf
---

# Performance investigation
EOF

cat > "$QUEUE_DIR/approved/task-004.md" << 'EOF'
---
id: task-004
type: pr
milestone: m1-foundation
status: approved
depends_on: [task-003]
repos: [my-repo]
branch: feat/optimize
---

# Optimize queries
EOF

# --- Tests ---

echo "task_field"
assert_eq "extracts id" "task-001" "$(task_field "$QUEUE_DIR/pending/task-001.md" "id")"
assert_eq "extracts type" "pr" "$(task_field "$QUEUE_DIR/pending/task-001.md" "type")"
assert_eq "extracts milestone" "m1-foundation" "$(task_field "$QUEUE_DIR/pending/task-001.md" "milestone")"
assert_eq "extracts status" "pending" "$(task_field "$QUEUE_DIR/pending/task-001.md" "status")"
assert_eq "extracts branch" "feat/add-auth" "$(task_field "$QUEUE_DIR/pending/task-001.md" "branch")"
assert_eq "returns empty for missing field" "" "$(task_field "$QUEUE_DIR/pending/task-001.md" "nonexistent")"

echo ""
echo "task_id / task_status / task_milestone / task_type"
assert_eq "task_id" "task-001" "$(task_id "$QUEUE_DIR/pending/task-001.md")"
assert_eq "task_status" "pending" "$(task_status "$QUEUE_DIR/pending/task-001.md")"
assert_eq "task_milestone" "m1-foundation" "$(task_milestone "$QUEUE_DIR/pending/task-001.md")"
assert_eq "task_type" "pr" "$(task_type "$QUEUE_DIR/pending/task-001.md")"

echo ""
echo "task_depends_on"
assert_eq "empty deps" "" "$(task_depends_on "$QUEUE_DIR/pending/task-001.md")"
assert_eq "has deps" "task-001" "$(task_depends_on "$QUEUE_DIR/pending/task-002.md")"

echo ""
echo "task_deps_met"
# task-001 has no deps — should always be met
assert_true "no deps are met" task_deps_met "$QUEUE_DIR/pending/task-001.md"
# task-002 depends on task-001 which is in pending — not met
assert_false "unmet dep in pending" task_deps_met "$QUEUE_DIR/pending/task-002.md"

# Move task-001 to done and recheck
cp "$QUEUE_DIR/pending/task-001.md" "$QUEUE_DIR/done/task-001.md"
assert_true "dep met when in done" task_deps_met "$QUEUE_DIR/pending/task-002.md"
rm "$QUEUE_DIR/done/task-001.md"

echo ""
echo "count_tasks"
assert_eq "pending count" "2" "$(count_tasks "$QUEUE_DIR/pending")"
assert_eq "approved count" "2" "$(count_tasks "$QUEUE_DIR/approved")"
assert_eq "done count" "0" "$(count_tasks "$QUEUE_DIR/done")"
assert_eq "empty dir count" "0" "$(count_tasks "$QUEUE_DIR/blocked")"

echo ""
echo "list_tasks"
local_list=$(list_tasks "$QUEUE_DIR/pending" | wc -l | tr -d ' ')
assert_eq "lists pending tasks" "2" "$local_list"

echo ""
echo "next_ready_task"
# task-003 has no deps and is approved — should be next
next=$(next_ready_task "$QUEUE_DIR")
assert_eq "picks task with no deps" "task-003" "$(task_id "$next")"

# Move task-003 to done, now task-004 (depends on task-003) should be ready
cp "$QUEUE_DIR/approved/task-003.md" "$QUEUE_DIR/done/task-003.md"
rm "$QUEUE_DIR/approved/task-003.md"
next=$(next_ready_task "$QUEUE_DIR")
assert_eq "picks task after dep met" "task-004" "$(task_id "$next")"

echo ""
echo "move_task"
new_file=$(move_task "$QUEUE_DIR/approved/task-004.md" "$QUEUE_DIR/in-progress" "in-progress")
assert_eq "moves file" "$QUEUE_DIR/in-progress/task-004.md" "$new_file"
assert_eq "updates status" "in-progress" "$(task_status "$new_file")"
assert_eq "approved now empty" "0" "$(count_tasks "$QUEUE_DIR/approved")"

echo ""
echo "append_work_log"
append_work_log "$QUEUE_DIR/in-progress/task-004.md" "Test log entry"
assert_eq "appends to file" "1" "$(grep -c 'Test log entry' "$QUEUE_DIR/in-progress/task-004.md")"

# --- Summary ---

echo ""
echo "────────────────────────────"
echo "$TESTS_RUN tests: $TESTS_PASSED passed, $TESTS_FAILED failed"

if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
fi
