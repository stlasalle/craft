#!/usr/bin/env bash
# queue.sh — Queue manipulation helpers for the craft orchestrator

# Portable sed -i wrapper (macOS vs GNU)
_sed_i() {
    if sed --version 2>/dev/null | grep -q GNU; then
        sed -i -E "$@"
    else
        sed -i "" -E "$@"
    fi
}

# Get the value of a YAML frontmatter field from a task file
# Usage: task_field <file> <field>
task_field() {
    local file="$1" field="$2"
    sed -n '/^---$/,/^---$/p' "$file" | grep "^${field}:" | sed "s/^${field}:[[:space:]]*//"
}

# Get the task ID from a task file
task_id() {
    task_field "$1" "id"
}

# Get the task status from a task file
task_status() {
    task_field "$1" "status"
}

# Get the task milestone from a task file
task_milestone() {
    task_field "$1" "milestone"
}

# Get the task type from a task file
task_type() {
    task_field "$1" "type"
}

# Get depends_on as a space-separated list
task_depends_on() {
    local file="$1"
    sed -n '/^depends_on:/,/^[a-z]/p' "$file" | grep '^ *-' | sed 's/^ *- *//'
}

# Check if all dependencies of a task are satisfied (in done/ or archive/)
# Returns 0 if all deps are met, 1 if not
task_deps_met() {
    local file="$1"
    local queue_dir="$(dirname "$(dirname "$file")")"
    local deps
    deps=$(task_depends_on "$file")

    if [[ -z "$deps" ]]; then
        return 0
    fi

    for dep in $deps; do
        local found=0
        # Check done/
        for done_file in "$queue_dir/done"/*.md "$queue_dir/archive"/**/*.md; do
            [[ -f "$done_file" ]] || continue
            if [[ "$(task_id "$done_file")" == "$dep" ]]; then
                found=1
                break
            fi
        done
        if [[ $found -eq 0 ]]; then
            return 1
        fi
    done
    return 0
}

# Move a task file between queue directories and update its status
# Usage: move_task <file> <new-status-dir> <new-status>
move_task() {
    local file="$1" target_dir="$2" new_status="$3"
    local filename="$(basename "$file")"
    local target="$target_dir/$filename"

    # Update status in frontmatter
    _sed_i "s/^status:.*/status: $new_status/" "$file"

    # Move the file
    mv "$file" "$target"
    echo "$target"
}

# List all task files in a queue directory, sorted by ID
# Usage: list_tasks <directory>
list_tasks() {
    local dir="$1"
    find "$dir" -maxdepth 1 -name '*.md' -not -name '.gitkeep' 2>/dev/null | sort
}

# Count tasks in a directory
count_tasks() {
    local dir="$1"
    list_tasks "$dir" | wc -l | tr -d ' '
}

# Get the next approved task that has all dependencies met
# Usage: next_ready_task <queue-dir>
next_ready_task() {
    local queue_dir="$1"
    for task in $(list_tasks "$queue_dir/approved"); do
        if task_deps_met "$task"; then
            echo "$task"
            return 0
        fi
    done
    return 1
}

# Append a timestamped entry to a task's work log
# Usage: append_work_log <file> <message>
append_work_log() {
    local file="$1" message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "" >> "$file"
    echo "### $message — $timestamp" >> "$file"
}
