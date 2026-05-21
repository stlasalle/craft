#!/usr/bin/env bash
set -uo pipefail

# test-state.sh — Tests for bin/lib/state.sh and state-local.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CRAFT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Default backend under test
export STATE_BACKEND="${STATE_BACKEND:-local}"

source "$CRAFT_ROOT/bin/lib/state.sh"

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
mkdir -p "$QUEUE_DIR"/{pending,approved,in-progress,waiting,done,blocked,archive}

# --- Tests ---

echo "state dispatcher"
assert_eq "STATE_BACKEND reported" "local" "$STATE_BACKEND"

echo ""
echo "state dispatcher error handling"

# Run state.sh in a subshell with an unknown backend — should fail.
err_output=$(STATE_BACKEND="nonsense" bash -c "source '$CRAFT_ROOT/bin/lib/state.sh'" 2>&1 || true)
TESTS_RUN=$((TESTS_RUN + 1))
if echo "$err_output" | grep -q "unknown STATE_BACKEND 'nonsense'"; then
    pass "dispatcher errors on unknown backend"
else
    fail "dispatcher errors on unknown backend" "got: $err_output"
fi

# Default backend should be local
default_output=$(unset STATE_BACKEND; bash -c "source '$CRAFT_ROOT/bin/lib/state.sh' && echo \$STATE_BACKEND")
assert_eq "default backend is local" "local" "$default_output"

echo ""
echo "state_task_field (alias of task_field)"

# Fixture task file
cat > "$QUEUE_DIR/pending/task-001.md" << 'EOF'
---
id: task-001
type: pr
milestone: m1-foundation
status: pending
depends_on: []
repos: [my-repo]
branch: feat/add-auth
---

# Add authentication
EOF

assert_eq "extracts id via state_task_field" "task-001" "$(state_task_field "$QUEUE_DIR/pending/task-001.md" "id")"
assert_eq "extracts branch via state_task_field" "feat/add-auth" "$(state_task_field "$QUEUE_DIR/pending/task-001.md" "branch")"
assert_eq "state_task_id" "task-001" "$(state_task_id "$QUEUE_DIR/pending/task-001.md")"
assert_eq "state_task_status" "pending" "$(state_task_status "$QUEUE_DIR/pending/task-001.md")"
assert_eq "state_task_milestone" "m1-foundation" "$(state_task_milestone "$QUEUE_DIR/pending/task-001.md")"
assert_eq "state_task_type" "pr" "$(state_task_type "$QUEUE_DIR/pending/task-001.md")"
assert_eq "state_task_depends_on empty" "" "$(state_task_depends_on "$QUEUE_DIR/pending/task-001.md")"

echo ""
echo "state listing and counting"

# Fixture: more tasks
cat > "$QUEUE_DIR/approved/task-002.md" << 'EOF'
---
id: task-002
type: pr
milestone: m1-foundation
status: approved
depends_on: []
repos: [my-repo]
branch: feat/add-users
---

# Add users
EOF

cat > "$QUEUE_DIR/approved/task-003.md" << 'EOF'
---
id: task-003
type: pr
milestone: m1-foundation
status: approved
depends_on: [task-001]
repos: [my-repo]
branch: feat/add-orgs
---

# Add orgs — blocked until task-001 lands
EOF

cat > "$QUEUE_DIR/in-progress/task-004.md" << 'EOF'
---
id: task-004
type: pr
milestone: m1-foundation
status: in-progress
depends_on: []
repos: [my-repo]
branch: feat/running
---

# In progress
EOF

assert_eq "state_count_tasks pending" "1" "$(state_count_tasks "$QUEUE_DIR/pending")"
assert_eq "state_count_tasks approved" "2" "$(state_count_tasks "$QUEUE_DIR/approved")"
assert_eq "state_count_tasks in-progress" "1" "$(state_count_tasks "$QUEUE_DIR/in-progress")"
assert_eq "state_count_tasks empty dir" "0" "$(state_count_tasks "$QUEUE_DIR/done")"

assert_eq "state_list_tasks returns 2 approved" "2" "$(state_list_tasks "$QUEUE_DIR/approved" | wc -l | tr -d ' ')"

# state_find_task_by_id should search across queue directories
found=$(state_find_task_by_id "$QUEUE_DIR" "task-002")
assert_eq "state_find_task_by_id finds approved" "$QUEUE_DIR/approved/task-002.md" "$found"

found=$(state_find_task_by_id "$QUEUE_DIR" "task-004")
assert_eq "state_find_task_by_id finds in-progress" "$QUEUE_DIR/in-progress/task-004.md" "$found"

# Not found returns empty + non-zero
assert_false "state_find_task_by_id returns false when missing" state_find_task_by_id "$QUEUE_DIR" "task-999"

# state_list_ready_tasks: approved with deps met, excluding those with unmet deps
ready_paths=$(state_list_ready_tasks "$QUEUE_DIR")
assert_eq "state_list_ready_tasks returns only task-002 path" "$QUEUE_DIR/approved/task-002.md" "$ready_paths"

echo ""
echo "state_claim_task"

# Fixture
cat > "$QUEUE_DIR/approved/task-010.md" << 'EOF'
---
id: task-010
type: pr
milestone: m1-foundation
status: approved
depends_on: []
repos: [my-repo]
branch: feat/claim
created: 2026-04-21
started:
waiting:
done:
blocked:
one_shot: true
---

# Claim test
EOF

new_file=$(state_claim_task "$QUEUE_DIR" "task-010")
assert_eq "claim moves to in-progress" "$QUEUE_DIR/in-progress/task-010.md" "$new_file"
assert_eq "claim updates status" "in-progress" "$(state_task_status "$new_file")"
assert_eq "claim sets started timestamp" "1" "$(state_task_field "$new_file" "started" | grep -c '^[0-9]\{4\}-')"

# Claiming a non-existent task should fail
assert_false "claim missing task returns false" state_claim_task "$QUEUE_DIR" "task-999"

echo ""
echo "state_mark_waiting"

cat > "$QUEUE_DIR/in-progress/task-011.md" << 'EOF'
---
id: task-011
type: pr
milestone: m1-foundation
status: in-progress
depends_on: []
repos: [my-repo]
branch: feat/waiting
created: 2026-04-21
started: 2026-04-21T10:00:00Z
waiting:
done:
blocked:
one_shot: true
---

# Waiting test
EOF

new_file=$(state_mark_waiting "$QUEUE_DIR" "task-011" "https://github.com/owner/repo/pull/42")
assert_eq "mark_waiting moves file" "$QUEUE_DIR/waiting/task-011.md" "$new_file"
assert_eq "mark_waiting updates status" "waiting" "$(state_task_status "$new_file")"
assert_eq "mark_waiting sets waiting timestamp" "1" "$(state_task_field "$new_file" "waiting" | grep -c '^[0-9]\{4\}-')"
assert_eq "mark_waiting stores pr url" "https://github.com/owner/repo/pull/42" "$(state_task_field "$new_file" "pr")"

# Missing task fails
assert_false "mark_waiting missing task returns false" state_mark_waiting "$QUEUE_DIR" "task-999" "http://x"

# Replace path: fixture already has a pr: line; new URL contains `&`
cat > "$QUEUE_DIR/in-progress/task-011b.md" << 'EOF'
---
id: task-011b
type: pr
milestone: m1-foundation
status: in-progress
depends_on: []
repos: [my-repo]
branch: feat/waiting-replace
pr: https://old.example.com/pr/0
created: 2026-04-21
started: 2026-04-21T10:00:00Z
waiting:
done:
blocked:
one_shot: true
---

# Replace-path test
EOF

new_file=$(state_mark_waiting "$QUEUE_DIR" "task-011b" "https://github.com/owner/repo/pull/99?tab=files&w=1")
assert_eq "mark_waiting replaces existing pr url with ampersand" "https://github.com/owner/repo/pull/99?tab=files&w=1" "$(state_task_field "$new_file" "pr")"

echo ""
echo "state_mark_done"

cat > "$QUEUE_DIR/waiting/task-012.md" << 'EOF'
---
id: task-012
type: pr
milestone: m1-foundation
status: waiting
depends_on: []
repos: [my-repo]
branch: feat/done
pr: https://github.com/owner/repo/pull/43
created: 2026-04-21
started: 2026-04-21T10:00:00Z
waiting: 2026-04-21T11:00:00Z
done:
blocked:
one_shot: true
---

# Done test
EOF

new_file=$(state_mark_done "$QUEUE_DIR" "task-012")
assert_eq "mark_done moves file" "$QUEUE_DIR/done/task-012.md" "$new_file"
assert_eq "mark_done updates status" "done" "$(state_task_status "$new_file")"
assert_eq "mark_done sets done timestamp" "1" "$(state_task_field "$new_file" "done" | grep -c '^[0-9]\{4\}-')"
assert_eq "mark_done preserves pr url" "https://github.com/owner/repo/pull/43" "$(state_task_field "$new_file" "pr")"

# Fallback: task in in-progress (no waiting/ phase)
cat > "$QUEUE_DIR/in-progress/task-012b.md" << 'EOF'
---
id: task-012b
type: pr
milestone: m1-foundation
status: in-progress
depends_on: []
repos: [my-repo]
branch: feat/done-fallback
created: 2026-04-21
started: 2026-04-21T10:00:00Z
waiting:
done:
blocked:
one_shot: true
---

# Done-fallback test
EOF

new_file=$(state_mark_done "$QUEUE_DIR" "task-012b")
assert_eq "mark_done falls back to in-progress" "$QUEUE_DIR/done/task-012b.md" "$new_file"

# Not found: returns non-zero
assert_false "mark_done missing task returns false" state_mark_done "$QUEUE_DIR" "task-999"

echo ""
echo "state_mark_blocked"

cat > "$QUEUE_DIR/in-progress/task-013.md" << 'EOF'
---
id: task-013
type: pr
milestone: m1-foundation
status: in-progress
depends_on: []
repos: [my-repo]
branch: feat/blocked
created: 2026-04-21
started: 2026-04-21T10:00:00Z
waiting:
done:
blocked:
one_shot: true
---

# Blocked test

## Work Log
EOF

new_file=$(state_mark_blocked "$QUEUE_DIR" "task-013" "CI failing with unexplained panic in test suite")
assert_eq "mark_blocked moves file" "$QUEUE_DIR/blocked/task-013.md" "$new_file"
assert_eq "mark_blocked updates status" "blocked" "$(state_task_status "$new_file")"
assert_eq "mark_blocked sets blocked timestamp" "1" "$(state_task_field "$new_file" "blocked" | grep -c '^[0-9]\{4\}-')"
assert_eq "mark_blocked sets one_shot false" "false" "$(state_task_field "$new_file" "one_shot")"
assert_eq "mark_blocked writes reason to work log" "1" "$(grep -c 'CI failing with unexplained panic' "$new_file")"

# Not found returns non-zero
assert_false "mark_blocked missing task returns false" state_mark_blocked "$QUEUE_DIR" "task-999" "nope"

echo ""
echo "state_append_note"

cat > "$QUEUE_DIR/in-progress/task-014.md" << 'EOF'
---
id: task-014
type: pr
milestone: m1-foundation
status: in-progress
depends_on: []
repos: [my-repo]
branch: feat/note
---

# Note test

## Work Log
EOF

state_append_note "$QUEUE_DIR" "task-014" "Pushed first commit"
assert_eq "append_note writes to work log" "1" "$(grep -c 'Pushed first commit' "$QUEUE_DIR/in-progress/task-014.md")"

# Missing task fails
assert_false "append_note missing task returns false" state_append_note "$QUEUE_DIR" "task-999" "nope"

echo ""
echo "state_create_subtask"

cat > "$QUEUE_DIR/in-progress/task-020.md" << 'EOF'
---
id: task-020
type: pr
milestone: m2-scaling
status: in-progress
depends_on: []
repos: [my-repo]
branch: feat/parent
---

# Parent task
EOF

# Capture baseline count BEFORE creating the subtask
pending_before=$(ls "$QUEUE_DIR/pending" | wc -l | tr -d ' ')
subtask_file=$(state_create_subtask "$QUEUE_DIR" "task-020" "Add caching layer" "The parent work needs a caching sub-layer.")
pending_after=$(ls "$QUEUE_DIR/pending" | wc -l | tr -d ' ')
assert_eq "subtask created in pending (+1)" "$((pending_before + 1))" "$pending_after"
assert_eq "subtask inherits milestone" "m2-scaling" "$(state_task_milestone "$subtask_file")"
assert_eq "subtask records parent in depends_on" "task-020" "$(state_task_depends_on "$subtask_file")"
assert_eq "subtask status is pending" "pending" "$(state_task_status "$subtask_file")"

# Next subtask from same parent gets a different sequential ID
subtask_file2=$(state_create_subtask "$QUEUE_DIR" "task-020" "Add metrics" "Monitoring")
tid1=$(state_task_id "$subtask_file")
tid2=$(state_task_id "$subtask_file2")
assert_true "second subtask has different id" test "$tid1" != "$tid2"

# Type inheritance: research parent produces research subtask
cat > "$QUEUE_DIR/in-progress/task-021.md" << 'EOF'
---
id: task-021
type: research
milestone: m2-scaling
status: in-progress
depends_on: []
repos: [my-repo]
branch: research/parent
---

# Research parent
EOF

research_subtask=$(state_create_subtask "$QUEUE_DIR" "task-021" "Investigate alternative" "Dig into the alternative approach")
assert_eq "subtask inherits parent type" "research" "$(state_task_type "$research_subtask")"

# Empty title rejected
assert_false "empty title rejected" state_create_subtask "$QUEUE_DIR" "task-020" "" "non-empty description"
assert_false "whitespace-only title rejected" state_create_subtask "$QUEUE_DIR" "task-020" "   " "non-empty description"

echo ""
echo "end-to-end: approved → in-progress → waiting → done"

cat > "$QUEUE_DIR/approved/task-100.md" << 'EOF'
---
id: task-100
type: pr
milestone: m3-roundtrip
status: approved
depends_on: []
repos: [my-repo]
branch: feat/roundtrip
created: 2026-04-21
started:
waiting:
done:
blocked:
one_shot: true
---

# Round-trip test

## Work Log
EOF

# 1. Claim
f=$(state_claim_task "$QUEUE_DIR" "task-100")
assert_eq "roundtrip: in-progress" "in-progress" "$(state_task_status "$f")"

# 2. Append some notes during work
state_append_note "$QUEUE_DIR" "task-100" "Implemented feature"
state_append_note "$QUEUE_DIR" "task-100" "Pushed draft PR"
assert_eq "roundtrip: two notes recorded" "2" "$(grep -c '^###' "$QUEUE_DIR/in-progress/task-100.md")"

# 3. Mark waiting with PR URL
f=$(state_mark_waiting "$QUEUE_DIR" "task-100" "https://example.com/pr/100")
assert_eq "roundtrip: waiting" "waiting" "$(state_task_status "$f")"
assert_eq "roundtrip: pr recorded" "https://example.com/pr/100" "$(state_task_field "$f" "pr")"

# 4. Mark done
f=$(state_mark_done "$QUEUE_DIR" "task-100")
assert_eq "roundtrip: done" "done" "$(state_task_status "$f")"
assert_eq "roundtrip: one_shot true on happy path" "true" "$(state_task_field "$f" "one_shot")"

# 5. Find by ID across all directories
found=$(state_find_task_by_id "$QUEUE_DIR" "task-100")
assert_eq "roundtrip: find_task_by_id after done" "$QUEUE_DIR/done/task-100.md" "$found"

# --- Summary ---

echo ""
echo "────────────────────────────"
echo "$TESTS_RUN tests: $TESTS_PASSED passed, $TESTS_FAILED failed"

if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
fi
