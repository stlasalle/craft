# State Backend Abstraction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor Craft's state layer behind a pluggable backend interface so a Linear backend can be added later without forking. The local file-based backend continues to work identically to today.

**Architecture:** Introduce `bin/lib/state.sh` as a dispatcher that sources the right backend module based on the `STATE_BACKEND` config value. Provide `bin/lib/state-local.sh` as the file-based backend, which re-exports all existing `queue.sh` low-level accessors and adds new high-level operations (`state_claim_task`, `state_mark_waiting`, `state_mark_done`, etc.) composed from those accessors. Update `bin/orchestrator.sh` and `bin/craft` to source `state.sh` and use the high-level ops for state transitions.

**Tech Stack:** Bash. No new runtime dependencies. Uses existing `jq` (already required) and `sed` for YAML frontmatter manipulation.

---

## File Structure

**Files to create:**
- `bin/lib/state.sh` — dispatcher, sources the backend module based on `STATE_BACKEND`
- `bin/lib/state-local.sh` — local file-based backend (wraps `queue.sh` and adds high-level ops)
- `test/test-state.sh` — test suite for the state backend interface

**Files to modify:**
- `bin/orchestrator.sh` — source `state.sh` instead of `queue.sh`; use `state_*` ops for transitions
- `bin/craft` — in `cmd_status`, `cmd_metrics`, and `projects` subcommand: source `state.sh` instead of `queue.sh`
- `templates/craft.conf` — add `STATE_BACKEND=local` default
- `Makefile` — `test` target runs both `test-queue.sh` (unchanged) and new `test-state.sh`

**Files left alone:**
- `bin/lib/queue.sh` — **unchanged**. Remains the low-level file-accessor library used by `state-local.sh`. No rename, no changes; upstream users depending on it are unaffected.
- `templates/.claude/commands/*.md` — skill files continue to do raw file ops on `queue/`. They are rewritten in Plan 2 (worker/watcher split).
- `test/test-queue.sh` — **unchanged**, must still pass. Catches any accidental breakage of low-level ops.

---

## Task 1: Test harness bootstrap

**Files:**
- Create: `test/test-state.sh`
- Modify: `Makefile`

- [ ] **Step 1: Create the new test file with the harness pattern from `test-queue.sh`**

```bash
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

# --- Summary ---

echo ""
echo "────────────────────────────"
echo "$TESTS_RUN tests: $TESTS_PASSED passed, $TESTS_FAILED failed"

if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
fi
```

- [ ] **Step 2: Make the test file executable**

Run: `chmod +x test/test-state.sh`

- [ ] **Step 3: Run the test — it should fail because `state.sh` does not exist yet**

Run: `./test/test-state.sh`

Expected: `source: bin/lib/state.sh: No such file or directory` error.

- [ ] **Step 4: Create a stub `bin/lib/state.sh` so the test can run**

```bash
#!/usr/bin/env bash
# state.sh — Pluggable state backend dispatcher
#
# Sources a backend implementation based on the STATE_BACKEND variable.
# Backends:
#   local   — file-based task queue under queue/ (default)
#   linear  — Linear issues via GraphQL (implemented in a later plan)

STATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

STATE_BACKEND="${STATE_BACKEND:-local}"

case "$STATE_BACKEND" in
    local)
        # shellcheck source=/dev/null
        source "$STATE_DIR/state-local.sh"
        ;;
    *)
        echo "Error: unknown STATE_BACKEND '$STATE_BACKEND'. Supported: local" >&2
        return 1 2>/dev/null || exit 1
        ;;
esac
```

- [ ] **Step 5: Create a stub `bin/lib/state-local.sh` that just sources `queue.sh`**

```bash
#!/usr/bin/env bash
# state-local.sh — Local file-based state backend
#
# Wraps bin/lib/queue.sh (low-level file accessors) and exposes
# high-level state operations used by the orchestrator and skills.

STATE_LOCAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
source "$STATE_LOCAL_DIR/queue.sh"
```

- [ ] **Step 6: Run the test — it should pass now**

Run: `./test/test-state.sh`

Expected output includes:
```
state dispatcher
  ✓ STATE_BACKEND reported
1 tests: 1 passed, 0 failed
```

- [ ] **Step 7: Wire `test-state.sh` into the Makefile `test` target**

Replace the `test` target in `Makefile`:

```makefile
test:
	@echo "Running tests..."
	@bash $(CURDIR)/test/test-queue.sh
	@bash $(CURDIR)/test/test-state.sh
```

- [ ] **Step 8: Run both test suites via `make test`**

Run: `make test`

Expected: both suites report all tests passing.

- [ ] **Step 9: Commit**

```bash
git add bin/lib/state.sh bin/lib/state-local.sh test/test-state.sh Makefile
git commit -m "feat(state): introduce pluggable state backend dispatcher

Adds bin/lib/state.sh as the backend dispatcher and bin/lib/state-local.sh
as the default file-based backend (wraps queue.sh). Adds test/test-state.sh
and wires it into make test."
```

---

## Task 2: Re-export low-level task accessors under the state interface

The high-level ops that follow compose these. Keep the original `task_*` names from `queue.sh` intact (for backward compat with anything that already sources `queue.sh` directly) and add `state_*` aliases.

**Files:**
- Modify: `bin/lib/state-local.sh`
- Modify: `test/test-state.sh`

- [ ] **Step 1: Add a failing test for `state_task_field`**

Append to `test/test-state.sh` before the `Summary` section:

```bash
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
```

- [ ] **Step 2: Run the tests — they should fail**

Run: `./test/test-state.sh`

Expected: `command not found: state_task_field` (or similar) for each `state_task_*` assertion.

- [ ] **Step 3: Add the aliases to `state-local.sh`**

Append to `bin/lib/state-local.sh`:

```bash
# --- Low-level accessors (aliases of queue.sh functions) ---
# Keep the task_* originals available for compat; add state_* names for the
# consistent interface.

state_task_field()      { task_field "$@"; }
state_task_id()         { task_id "$@"; }
state_task_status()     { task_status "$@"; }
state_task_milestone()  { task_milestone "$@"; }
state_task_type()       { task_type "$@"; }
state_task_depends_on() { task_depends_on "$@"; }
state_task_deps_met()   { task_deps_met "$@"; }
```

- [ ] **Step 4: Run the tests — they should pass**

Run: `./test/test-state.sh`

Expected: all 7 new `state_task_*` assertions pass.

- [ ] **Step 5: Commit**

```bash
git add bin/lib/state-local.sh test/test-state.sh
git commit -m "feat(state): add state_task_* accessor aliases

Re-export queue.sh low-level accessors under state_* names so callers
have a single consistent namespace. The task_* originals remain
available for backward compatibility."
```

---

## Task 3: Listing and counting operations

These wrap queue directories behind state-level semantics so the Linear backend can later implement them against its own data source.

**Files:**
- Modify: `bin/lib/state-local.sh`
- Modify: `test/test-state.sh`

- [ ] **Step 1: Add failing tests for listing and counting**

Append to `test/test-state.sh`:

```bash
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
ready_ids=$(state_list_ready_tasks "$QUEUE_DIR" | xargs -I{} state_task_id {})
assert_eq "state_list_ready_tasks excludes unmet deps" "task-002" "$ready_ids"
```

- [ ] **Step 2: Run the tests — they should fail**

Run: `./test/test-state.sh`

Expected: `command not found: state_count_tasks` etc.

- [ ] **Step 3: Implement the listing and counting functions**

Append to `bin/lib/state-local.sh`:

```bash
# --- Listing and counting ---

# state_list_tasks <dir>
# List task file paths in a queue directory, sorted by ID.
state_list_tasks() {
    list_tasks "$@"
}

# state_count_tasks <dir>
# Count tasks in a queue directory.
state_count_tasks() {
    count_tasks "$@"
}

# state_find_task_by_id <queue_dir> <task_id>
# Find a task file by ID across all queue subdirectories.
# Echoes the file path on success, returns non-zero if not found.
state_find_task_by_id() {
    local queue_dir="$1" tid="$2"
    for sub in approved in-progress waiting done blocked pending; do
        local dir="$queue_dir/$sub"
        [[ -d "$dir" ]] || continue
        for f in "$dir"/*.md; do
            [[ -f "$f" ]] || continue
            if [[ "$(task_id "$f")" == "$tid" ]]; then
                echo "$f"
                return 0
            fi
        done
    done
    # Also check archive/*/
    if [[ -d "$queue_dir/archive" ]]; then
        for f in "$queue_dir/archive"/*/*.md; do
            [[ -f "$f" ]] || continue
            if [[ "$(task_id "$f")" == "$tid" ]]; then
                echo "$f"
                return 0
            fi
        done
    fi
    return 1
}

# state_list_ready_tasks <queue_dir>
# List approved tasks whose dependencies are all satisfied.
# Echoes file paths one per line.
state_list_ready_tasks() {
    local queue_dir="$1"
    for f in $(list_tasks "$queue_dir/approved"); do
        if task_deps_met "$f"; then
            echo "$f"
        fi
    done
}
```

- [ ] **Step 4: Run the tests — they should pass**

Run: `./test/test-state.sh`

Expected: all listing and counting assertions pass.

- [ ] **Step 5: Commit**

```bash
git add bin/lib/state-local.sh test/test-state.sh
git commit -m "feat(state): add listing, counting, and task-lookup ops

state_list_tasks, state_count_tasks, state_find_task_by_id, and
state_list_ready_tasks wrap queue.sh with state-interface semantics.
state_list_ready_tasks returns all approved tasks with deps met
(vs next_ready_task which returns the first)."
```

---

## Task 4: `state_claim_task` — approved → in-progress

Atomic-ish: updates frontmatter status, sets `started` timestamp, moves the file. Returns the new path so the caller can read updated fields.

**Files:**
- Modify: `bin/lib/state-local.sh`
- Modify: `test/test-state.sh`

- [ ] **Step 1: Add a failing test**

Append to `test/test-state.sh`:

```bash
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
assert_eq "claim leaves approved empty" "0" "$(state_count_tasks "$QUEUE_DIR/approved")"

# Claiming a non-existent task should fail
assert_false "claim missing task returns false" state_claim_task "$QUEUE_DIR" "task-999"
```

- [ ] **Step 2: Run the test — it should fail**

Run: `./test/test-state.sh`

Expected: `command not found: state_claim_task`.

- [ ] **Step 3: Implement `state_claim_task`**

Append to `bin/lib/state-local.sh`:

```bash
# --- State transitions ---

# state_claim_task <queue_dir> <task_id>
# Move an approved task to in-progress and set the started timestamp.
# Echoes the new file path on success, returns non-zero if the task
# is not found in approved/.
state_claim_task() {
    local queue_dir="$1" tid="$2"
    local src="$queue_dir/approved/${tid}.md"

    # Find by ID (not just filename, in case file naming drifts)
    if [[ ! -f "$src" ]]; then
        src=""
        for f in "$queue_dir/approved"/*.md; do
            [[ -f "$f" ]] || continue
            if [[ "$(task_id "$f")" == "$tid" ]]; then
                src="$f"
                break
            fi
        done
    fi

    if [[ -z "$src" ]] || [[ ! -f "$src" ]]; then
        return 1
    fi

    move_task "$src" "$queue_dir/in-progress" "in-progress"
}
```

- [ ] **Step 4: Run the tests — they should pass**

Run: `./test/test-state.sh`

Expected: all four claim assertions pass, and the "claim missing task returns false" assertion passes.

- [ ] **Step 5: Commit**

```bash
git add bin/lib/state-local.sh test/test-state.sh
git commit -m "feat(state): add state_claim_task for approved -> in-progress"
```

---

## Task 5: `state_mark_waiting` — in-progress → waiting, record PR URL

Moves the task to `waiting/`, sets `waiting` timestamp, and writes the `pr:` frontmatter field. If `pr:` does not exist in the frontmatter, it is added.

**Files:**
- Modify: `bin/lib/state-local.sh`
- Modify: `test/test-state.sh`

- [ ] **Step 1: Add a failing test**

Append to `test/test-state.sh`:

```bash
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
```

- [ ] **Step 2: Run the test — it should fail**

Run: `./test/test-state.sh`

Expected: `command not found: state_mark_waiting`.

- [ ] **Step 3: Implement `state_mark_waiting`**

Append to `bin/lib/state-local.sh`:

```bash
# state_mark_waiting <queue_dir> <task_id> <pr_url>
# Move an in-progress task to waiting, set the waiting timestamp,
# and write the pr: field to the task's frontmatter.
# Echoes the new file path on success.
state_mark_waiting() {
    local queue_dir="$1" tid="$2" pr_url="$3"
    local src="$queue_dir/in-progress/${tid}.md"

    if [[ ! -f "$src" ]]; then
        src=""
        for f in "$queue_dir/in-progress"/*.md; do
            [[ -f "$f" ]] || continue
            if [[ "$(task_id "$f")" == "$tid" ]]; then
                src="$f"
                break
            fi
        done
    fi

    if [[ -z "$src" ]] || [[ ! -f "$src" ]]; then
        return 1
    fi

    # Set or insert pr: field in frontmatter BEFORE moving.
    if grep -q '^pr:' "$src"; then
        _sed_i "s|^pr:.*|pr: ${pr_url}|" "$src"
    else
        # Insert after the `id:` line
        _sed_i "/^id:/a\\
pr: ${pr_url}" "$src"
    fi

    move_task "$src" "$queue_dir/waiting" "waiting"
}
```

- [ ] **Step 4: Run the tests — they should pass**

Run: `./test/test-state.sh`

Expected: all four waiting assertions pass, and the "missing task returns false" assertion passes.

- [ ] **Step 5: Commit**

```bash
git add bin/lib/state-local.sh test/test-state.sh
git commit -m "feat(state): add state_mark_waiting with pr URL recording"
```

---

## Task 6: `state_mark_done` — waiting → done

**Files:**
- Modify: `bin/lib/state-local.sh`
- Modify: `test/test-state.sh`

- [ ] **Step 1: Add a failing test**

Append to `test/test-state.sh`:

```bash
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
```

- [ ] **Step 2: Run the test — it should fail**

Expected: `command not found: state_mark_done`.

- [ ] **Step 3: Implement `state_mark_done`**

Append to `bin/lib/state-local.sh`:

```bash
# state_mark_done <queue_dir> <task_id>
# Move a task to done and set the done timestamp.
# Searches waiting/ and in-progress/ (in that order) for the task.
state_mark_done() {
    local queue_dir="$1" tid="$2"
    local src=""
    for sub in waiting in-progress; do
        for f in "$queue_dir/$sub"/*.md; do
            [[ -f "$f" ]] || continue
            if [[ "$(task_id "$f")" == "$tid" ]]; then
                src="$f"
                break 2
            fi
        done
    done

    if [[ -z "$src" ]]; then
        return 1
    fi

    move_task "$src" "$queue_dir/done" "done"
}
```

- [ ] **Step 4: Run the tests — they should pass**

- [ ] **Step 5: Commit**

```bash
git add bin/lib/state-local.sh test/test-state.sh
git commit -m "feat(state): add state_mark_done"
```

---

## Task 7: `state_mark_blocked` — any → blocked, with reason

Moves the task from whatever state it is in to `blocked/`, sets `blocked` timestamp, sets `one_shot: false`, and appends the reason to the work log.

**Files:**
- Modify: `bin/lib/state-local.sh`
- Modify: `test/test-state.sh`

- [ ] **Step 1: Add a failing test**

Append to `test/test-state.sh`:

```bash
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
```

- [ ] **Step 2: Run the test — it should fail**

Expected: `command not found: state_mark_blocked`.

- [ ] **Step 3: Implement `state_mark_blocked`**

Append to `bin/lib/state-local.sh`:

```bash
# state_mark_blocked <queue_dir> <task_id> <reason>
# Move a task from its current state to blocked, set the blocked timestamp,
# set one_shot=false, and append the reason to the task's work log.
state_mark_blocked() {
    local queue_dir="$1" tid="$2" reason="$3"
    local src=""
    for sub in in-progress approved waiting pending; do
        for f in "$queue_dir/$sub"/*.md; do
            [[ -f "$f" ]] || continue
            if [[ "$(task_id "$f")" == "$tid" ]]; then
                src="$f"
                break 2
            fi
        done
    done

    if [[ -z "$src" ]]; then
        return 1
    fi

    # Append reason to work log BEFORE moving (move_task updates timestamps).
    append_work_log "$src" "Blocked: $reason"

    move_task "$src" "$queue_dir/blocked" "blocked"
}
```

- [ ] **Step 4: Run the tests — they should pass**

- [ ] **Step 5: Commit**

```bash
git add bin/lib/state-local.sh test/test-state.sh
git commit -m "feat(state): add state_mark_blocked with reason logged"
```

---

## Task 8: `state_append_note` — append a timestamped note to a task's work log

Wraps `append_work_log` but finds the task by ID (not path).

**Files:**
- Modify: `bin/lib/state-local.sh`
- Modify: `test/test-state.sh`

- [ ] **Step 1: Add a failing test**

Append to `test/test-state.sh`:

```bash
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
```

- [ ] **Step 2: Run the test — it should fail**

- [ ] **Step 3: Implement `state_append_note`**

Append to `bin/lib/state-local.sh`:

```bash
# state_append_note <queue_dir> <task_id> <text>
# Find the task by ID across all queue directories and append a
# timestamped entry to its work log.
state_append_note() {
    local queue_dir="$1" tid="$2" text="$3"
    local src
    src=$(state_find_task_by_id "$queue_dir" "$tid") || return 1
    append_work_log "$src" "$text"
}
```

- [ ] **Step 4: Run the tests — they should pass**

- [ ] **Step 5: Commit**

```bash
git add bin/lib/state-local.sh test/test-state.sh
git commit -m "feat(state): add state_append_note"
```

---

## Task 9: `state_create_subtask` — create a child task under a parent

Generates the next sequential task ID, writes a new task file under `pending/` (not auto-approved — architect/operator decides). Inherits `milestone`, `repos`, and `branch` prefix from the parent.

**Files:**
- Modify: `bin/lib/state-local.sh`
- Modify: `test/test-state.sh`

- [ ] **Step 1: Add a failing test**

Append to `test/test-state.sh`:

```bash
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

subtask_file=$(state_create_subtask "$QUEUE_DIR" "task-020" "Add caching layer" "The parent work needs a caching sub-layer.")
assert_eq "subtask created in pending" "1" "$(ls "$QUEUE_DIR/pending" | wc -l | tr -d ' ')"
assert_eq "subtask inherits milestone" "m2-scaling" "$(state_task_milestone "$subtask_file")"
assert_eq "subtask records parent in depends_on" "task-020" "$(state_task_depends_on "$subtask_file")"
assert_eq "subtask status is pending" "pending" "$(state_task_status "$subtask_file")"

# Next subtask from same parent gets next sequential ID
subtask_file2=$(state_create_subtask "$QUEUE_DIR" "task-020" "Add metrics" "Monitoring")
tid1=$(state_task_id "$subtask_file")
tid2=$(state_task_id "$subtask_file2")
assert_true "second subtask has different id" test "$tid1" != "$tid2"
```

- [ ] **Step 2: Run the test — it should fail**

- [ ] **Step 3: Implement `state_create_subtask`**

Append to `bin/lib/state-local.sh`:

```bash
# _state_next_task_id <queue_dir>
# Compute the next sequential task ID across all queue directories.
_state_next_task_id() {
    local queue_dir="$1"
    local max=0
    for f in "$queue_dir"/*/*.md; do
        [[ -f "$f" ]] || continue
        local num
        num=$(basename "$f" .md | sed -n 's/^task-0*\([0-9][0-9]*\)$/\1/p')
        if [[ -n "$num" ]] && (( num > max )); then
            max=$num
        fi
    done
    # Also check archive
    if [[ -d "$queue_dir/archive" ]]; then
        for f in "$queue_dir/archive"/*/*.md; do
            [[ -f "$f" ]] || continue
            local num
            num=$(basename "$f" .md | sed -n 's/^task-0*\([0-9][0-9]*\)$/\1/p')
            if [[ -n "$num" ]] && (( num > max )); then
                max=$num
            fi
        done
    fi
    printf "task-%03d" $((max + 1))
}

# state_create_subtask <queue_dir> <parent_task_id> <title> <description>
# Create a new task file under pending/ linked to the parent via depends_on.
# Inherits milestone, repos, and branch prefix from the parent.
# Echoes the new file path on success.
state_create_subtask() {
    local queue_dir="$1" parent_id="$2" title="$3" description="$4"

    local parent_file
    parent_file=$(state_find_task_by_id "$queue_dir" "$parent_id") || return 1

    local milestone repos parent_branch
    milestone=$(task_milestone "$parent_file")
    repos=$(task_field "$parent_file" "repos")
    parent_branch=$(task_field "$parent_file" "branch")

    # Derive a branch prefix: keep everything up to the first `/` of the parent branch
    local branch_prefix=""
    if [[ "$parent_branch" == */* ]]; then
        branch_prefix="${parent_branch%%/*}/"
    fi

    local new_id
    new_id=$(_state_next_task_id "$queue_dir")

    # Slug the title for the branch
    local slug
    slug=$(echo "$title" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//' | cut -c1-50)
    local branch="${branch_prefix}${new_id}/${slug}"

    local date_str
    date_str=$(date -u '+%Y-%m-%d')

    local new_file="$queue_dir/pending/${new_id}.md"

    cat > "$new_file" << TASK_EOF
---
id: ${new_id}
type: pr
milestone: ${milestone}
status: pending
depends_on: [${parent_id}]
repos: ${repos}
branch: ${branch}
created: ${date_str}
started:
waiting:
done:
blocked:
one_shot: true
qa:
  unit_tests: true
  integration_tests: false
---

# ${title}

## Summary
${description}

## Acceptance Criteria
1.

## Technical Notes

## Work Log
TASK_EOF

    echo "$new_file"
}
```

- [ ] **Step 4: Run the tests — they should pass**

- [ ] **Step 5: Commit**

```bash
git add bin/lib/state-local.sh test/test-state.sh
git commit -m "feat(state): add state_create_subtask for child task creation"
```

---

## Task 10: Dispatcher validation — STATE_BACKEND=local is the default, unknown backends error

**Files:**
- Modify: `test/test-state.sh`

- [ ] **Step 1: Add tests that validate the dispatcher's behavior with unknown backends**

Append to `test/test-state.sh` (near the top, after the existing dispatcher test):

```bash
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
```

- [ ] **Step 2: Run the tests — they should pass**

The dispatcher was already implemented in Task 1 to handle these cases. This task simply validates that contract.

Run: `./test/test-state.sh`

Expected: both new assertions pass.

- [ ] **Step 3: Commit**

```bash
git add test/test-state.sh
git commit -m "test(state): validate dispatcher error handling and default"
```

---

## Task 11: Migrate `bin/orchestrator.sh` to source `state.sh`

The orchestrator currently sources `queue.sh` directly. Switch to `state.sh` and use `state_*` high-level ops for state transitions. Keep the low-level `task_*` accessors for field reads (they are still available via the re-exports).

**Files:**
- Modify: `bin/orchestrator.sh`

- [ ] **Step 1: Change the `source` line**

Edit `bin/orchestrator.sh` near the top. Replace:

```bash
source "$SCRIPT_DIR/lib/queue.sh"
```

with:

```bash
source "$SCRIPT_DIR/lib/state.sh"
```

- [ ] **Step 2: Replace the blocked-on-timeout transition with `state_mark_blocked`**

In `check_active_tasks`, find the timeout branch (around line 285-302). Replace:

```bash
if [[ -n "$task_file" ]]; then
    append_work_log "$task_file" "Timed out by orchestrator after ${elapsed}s (limit: ${timeout}s)"
    move_task "$task_file" "$QUEUE_DIR/blocked" "blocked" > /dev/null
fi
```

with:

```bash
if [[ -n "$task_file" ]]; then
    state_mark_blocked "$QUEUE_DIR" "$tid" "Timed out after ${elapsed}s (limit: ${timeout}s)" > /dev/null
fi
```

- [ ] **Step 3: Run the existing test suite to verify no regression**

Run: `make test`

Expected: `test-queue.sh` passes (unchanged), `test-state.sh` passes (all tasks so far).

- [ ] **Step 4: Verify orchestrator.sh loads state.sh cleanly and has the functions it uses**

Booting the full orchestrator here is awkward because it re-execs inside tmux. Instead, check the script's syntax and verify the functions it calls are all resolvable after sourcing `state.sh`:

```bash
# Syntax check
bash -n bin/orchestrator.sh && echo "syntax OK"

# Function availability check — all functions the orchestrator calls
# from queue.sh (transitively via state-local.sh) plus the new state_mark_blocked.
bash -c '
    set -u
    source "'"$PWD"'/bin/lib/state.sh"
    for fn in task_field task_id task_milestone task_type task_deps_met \
              list_tasks count_tasks move_task next_ready_task append_work_log \
              state_mark_blocked; do
        if ! declare -f "$fn" > /dev/null; then
            echo "MISSING: $fn"
            exit 1
        fi
    done
    echo "functions OK"
'
```

Expected: both `syntax OK` and `functions OK`.

- [ ] **Step 5: Commit**

```bash
git add bin/orchestrator.sh
git commit -m "refactor(orchestrator): source state.sh and use state_mark_blocked

Migrates the orchestrator from queue.sh directly to the state backend
interface. The timeout path now uses state_mark_blocked so that the
blocked reason lands in the task's work log via the state interface."
```

---

## Task 12: Migrate `bin/craft` to source `state.sh`

Three subcommands source `queue.sh` inline: `cmd_status`, `cmd_metrics`, and the `projects`/`ls` subcommand. Switch them to `state.sh`. No behavior change — state.sh re-exports the functions they use.

**Files:**
- Modify: `bin/craft`

- [ ] **Step 1: Replace `source` lines**

In `bin/craft`, find the three occurrences:

```bash
source "$CRAFT_ROOT/bin/lib/queue.sh"
```

Replace each with:

```bash
source "$CRAFT_ROOT/bin/lib/state.sh"
```

(There is one in `cmd_status`, one in `cmd_metrics`, and one in the `projects|ls` branch of the main dispatch `case`.)

- [ ] **Step 2: Verify `bin/craft status` still works**

Run:

```bash
TMPROJ=$(mktemp -d)/proj
mkdir -p "$TMPROJ/queue"/{pending,approved,in-progress,waiting,done,blocked,archive}
cp templates/craft.conf "$TMPROJ/"

CRAFT_PROJECTS="$(dirname "$TMPROJ")" ./bin/craft status "$(basename "$TMPROJ")"
```

Expected: status report prints queue counts (all 0).

- [ ] **Step 3: Verify `bin/craft metrics` still works**

Run:

```bash
CRAFT_PROJECTS="$(dirname "$TMPROJ")" ./bin/craft metrics "$(basename "$TMPROJ")"
```

Expected: metrics report prints the queue snapshot and "no completed tasks" message.

- [ ] **Step 4: Verify `bin/craft projects` still works**

Run:

```bash
CRAFT_PROJECTS="$(dirname "$TMPROJ")" ./bin/craft projects
```

Expected: lists the temp project with `0 tasks (0 done, 0 in-progress, 0 waiting, 0 blocked)`.

- [ ] **Step 5: Commit**

```bash
git add bin/craft
git commit -m "refactor(craft): source state.sh from status, metrics, projects

No behavior change — state.sh re-exports the queue.sh low-level
accessors used by these commands. Sets up the path for future
state-backend switching in the CLI."
```

---

## Task 13: Surface `STATE_BACKEND` in `templates/craft.conf` and `craft doctor`

**Files:**
- Modify: `templates/craft.conf`
- Modify: `bin/craft` (the `cmd_doctor` function)

- [ ] **Step 1: Add `STATE_BACKEND` to the project config template**

Edit `templates/craft.conf`. After the `DEFAULT_AGENT` block and before the `# --- Plugins ---` section, add:

```bash
# State backend: where task state lives.
#   local   — file-based queue/ directory (default, unchanged behavior)
#   linear  — Linear issues (implemented in a later phase)
STATE_BACKEND=local
```

- [ ] **Step 2: Add `STATE_BACKEND` to the doctor output**

In `bin/craft`, find `cmd_doctor`. In the `Environment:` section near the bottom (just before the `craft` PATH check), add a line that reports the current project's state backend if a project argument is supplied, otherwise reports the default:

Replace:

```bash
    echo ""
    echo "Environment:"
    printf "  %-12s %s\n" "CRAFT_ROOT" "$CRAFT_ROOT"
    printf "  %-12s %s\n" "shell" "$SHELL"
    printf "  %-12s %s\n" "platform" "$(uname -s) $(uname -m)"
```

with:

```bash
    echo ""
    echo "Environment:"
    printf "  %-12s %s\n" "CRAFT_ROOT" "$CRAFT_ROOT"
    printf "  %-12s %s\n" "shell" "$SHELL"
    printf "  %-12s %s\n" "platform" "$(uname -s) $(uname -m)"
    printf "  %-12s %s (default; set STATE_BACKEND in craft.conf per-project)\n" "state" "local"
```

- [ ] **Step 3: Update the `craft doctor` help text to mention `STATE_BACKEND`**

In `cmd_doctor`, find the help block at the top of the function. Replace the `Required:` / `Agents:` / `Optional:` block with one that mentions state backends:

```bash
craft doctor — Check dependencies and environment

Verifies that all required tools are installed and reports their versions.

Required:  bash, git, tmux or cmux, gh, jq
Agents:    claude, codex (at least one needed)
Optional:  linear-cli (for the legacy linear-sync plugin), cmux

State backends:
  local   file-based queue/ directory (default, no extra deps)
  linear  Linear-backed state (requires LINEAR_API_KEY, implemented in a later phase)

Also checks that craft is on your PATH and shows environment info.
```

- [ ] **Step 4: Smoke-test `craft doctor`**

Run: `./bin/craft doctor`

Expected: output includes the new `state  local (default; set STATE_BACKEND in craft.conf per-project)` line.

- [ ] **Step 5: Commit**

```bash
git add templates/craft.conf bin/craft
git commit -m "feat(config): expose STATE_BACKEND in craft.conf and doctor

Adds STATE_BACKEND=local to the project template and surfaces the
value in 'craft doctor' output so users can see at a glance which
backend is configured."
```

---

## Task 14: End-to-end smoke test — state.sh round-trip

A single test that exercises the happy path across state ops, ensuring the interface is internally consistent.

**Files:**
- Modify: `test/test-state.sh`

- [ ] **Step 1: Add an end-to-end round-trip test**

Append to `test/test-state.sh`, before the final summary:

```bash
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
```

- [ ] **Step 2: Run the test suite**

Run: `make test`

Expected: both test files pass. The round-trip test exercises claim → append × 2 → mark_waiting → mark_done → find, with all state assertions green.

- [ ] **Step 3: Commit**

```bash
git add test/test-state.sh
git commit -m "test(state): add end-to-end round-trip happy path"
```

---

## Self-Review Checklist (to run after all tasks are complete)

- [ ] `make test` passes — both `test-queue.sh` and `test-state.sh` green.
- [ ] `grep -rn "queue.sh" bin/` shows `queue.sh` only sourced from `state-local.sh` — neither `orchestrator.sh` nor `craft` references it directly anymore.
- [ ] `grep -rn "STATE_BACKEND" bin/ templates/` shows the variable is honored by the dispatcher, the config template, and the doctor output.
- [ ] Start the orchestrator against a scratch project; confirm dashboard renders and no errors appear in logs.
- [ ] `./bin/craft doctor` shows `state  local` in the environment section.
- [ ] `git log --oneline mo/autonomous-delivery-harness..HEAD` shows 14 focused commits, one per task.
- [ ] No new `TBD`, `TODO`, or placeholder strings in any new or modified file: `git diff main.. -- bin/ test/ templates/ Makefile | grep -E 'TBD|TODO|FIXME'` is empty.

---

## What's next

Plan 2 (worker/watcher split) can now be written against this interface. It will:
- Rewrite `/work-task` to call `state_claim_task` and `state_mark_waiting` instead of manipulating files directly
- Add orchestrator detection of worker exit with a PR URL set → spawns a watcher pane
- Introduce a bash-based watcher script with a poll loop
- Add the first remediation skill (`/fix-ci-failure`)
