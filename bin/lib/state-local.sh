#!/usr/bin/env bash
# state-local.sh — Local file-based state backend
#
# Wraps bin/lib/queue.sh (low-level file accessors) and exposes
# high-level state operations used by the orchestrator and skills.

# Resolve the directory holding queue.sh. Prefer the value already set
# by state.sh (STATE_DIR) to be robust under zsh callers where BASH_SOURCE
# is empty. Fall back to BASH_SOURCE for direct callers.
if [[ -n "${STATE_DIR:-}" ]] && [[ -f "${STATE_DIR}/queue.sh" ]]; then
    STATE_LOCAL_DIR="${STATE_DIR}"
elif [[ -n "${CRAFT_ROOT:-}" ]] && [[ -f "${CRAFT_ROOT}/bin/lib/queue.sh" ]]; then
    STATE_LOCAL_DIR="${CRAFT_ROOT}/bin/lib"
else
    STATE_LOCAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
fi

# shellcheck source=/dev/null
source "$STATE_LOCAL_DIR/queue.sh"

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

# --- State transitions ---

# _state_find_in_dir <queue_dir> <subdir> <tid>
# Echo the file path for a task with id=<tid> in <queue_dir>/<subdir>.
# Tries the canonical <tid>.md filename first; falls back to scanning
# directory entries and matching by frontmatter id.
# Returns 1 if not found.
_state_find_in_dir() {
    local queue_dir="$1" subdir="$2" tid="$3"
    local canonical="$queue_dir/$subdir/${tid}.md"
    if [[ -f "$canonical" ]]; then
        echo "$canonical"
        return 0
    fi
    for f in "$queue_dir/$subdir"/*.md; do
        [[ -f "$f" ]] || continue
        if [[ "$(task_id "$f")" == "$tid" ]]; then
            echo "$f"
            return 0
        fi
    done
    return 1
}

# state_claim_task <queue_dir> <task_id>
# Move an approved task to in-progress and set the started timestamp.
# Echoes the new file path on success, returns non-zero if the task
# is not found in approved/. (Claim is scoped to approved/ by design —
# other transitions may search multiple queue directories.)
state_claim_task() {
    local queue_dir="$1" tid="$2"
    local src
    src=$(_state_find_in_dir "$queue_dir" "approved" "$tid") || return 1
    move_task "$src" "$queue_dir/in-progress" "in-progress"
}

# state_mark_waiting <queue_dir> <task_id> <pr_url>
# Move an in-progress task to waiting, set the waiting timestamp (via
# move_task), and write the pr: field to the task's frontmatter.
# If pr: is already present its value is replaced; otherwise the line
# is inserted immediately after the id: line.
# Echoes the new file path on success.
state_mark_waiting() {
    local queue_dir="$1" tid="$2" pr_url="$3"
    local src
    src=$(_state_find_in_dir "$queue_dir" "in-progress" "$tid") || return 1

    # Set or insert pr: in frontmatter BEFORE moving.
    if grep -q '^pr:' "$src"; then
        # Escape sed replacement metacharacters: \  &  and the | delimiter.
        local esc=${pr_url//\\/\\\\}
        esc=${esc//&/\\&}
        esc=${esc//|/\\|}
        _sed_i "s|^pr:.*|pr: ${esc}|" "$src"
    else
        # Insert after the id: line.
        _sed_i "/^id:/a\\
pr: ${pr_url}" "$src"
    fi

    move_task "$src" "$queue_dir/waiting" "waiting"
}

# state_mark_done <queue_dir> <task_id>
# Move a task to done and set the done timestamp. Searches waiting/
# first (normal flow) then in-progress/ (if an agent marks a task
# done without an explicit waiting phase).
state_mark_done() {
    local queue_dir="$1" tid="$2"
    local src
    src=$(_state_find_in_dir "$queue_dir" "waiting" "$tid") \
        || src=$(_state_find_in_dir "$queue_dir" "in-progress" "$tid") \
        || return 1
    move_task "$src" "$queue_dir/done" "done"
}

# state_mark_blocked <queue_dir> <task_id> <reason>
# Move a task from its current state to blocked, append the reason to
# the work log, and delegate to move_task (which handles the blocked
# timestamp and one_shot=false flip).
# Searches in-progress, approved, waiting, pending (but NOT done or
# blocked — already-terminal states should not be re-blocked).
state_mark_blocked() {
    local queue_dir="$1" tid="$2" reason="$3"
    local src=""
    for sub in in-progress approved waiting pending; do
        src=$(_state_find_in_dir "$queue_dir" "$sub" "$tid") && break
    done
    [[ -n "$src" ]] || return 1

    # Append reason to work log BEFORE moving. If the append fails we
    # abort rather than move the task into blocked/ without a trail.
    append_work_log "$src" "Blocked: $reason" || return 1

    move_task "$src" "$queue_dir/blocked" "blocked"
}

# state_append_note <queue_dir> <task_id> <text>
# Find the task by ID across all queue directories and append a
# timestamped entry to its work log.
state_append_note() {
    local queue_dir="$1" tid="$2" text="$3"
    local src
    src=$(state_find_task_by_id "$queue_dir" "$tid") || return 1
    append_work_log "$src" "$text"
}

# _state_next_task_id <queue_dir>
# Compute the next sequential task ID across all queue directories
# (including archive). Format: task-NNN.
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

    local milestone repos parent_branch parent_type
    milestone=$(state_task_milestone "$parent_file")
    repos=$(state_task_field "$parent_file" "repos")
    parent_branch=$(state_task_field "$parent_file" "branch")
    parent_type=$(state_task_type "$parent_file")
    [[ -z "$parent_type" ]] && parent_type="pr"

    # Reject empty / whitespace-only titles — would produce degenerate branches.
    local title_stripped="${title//[[:space:]]/}"
    if [[ -z "$title_stripped" ]]; then
        echo "state_create_subtask: title is empty or whitespace-only" >&2
        return 1
    fi

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
type: ${parent_type}
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
