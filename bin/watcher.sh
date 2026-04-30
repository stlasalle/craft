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

if [[ -z "$PR_URL" ]]; then
    echo "watcher.sh: missing required --pr (use --help for usage)" >&2
    exit 1
fi
if [[ -z "$TASK_ID" ]]; then
    echo "watcher.sh: missing required --task (use --help for usage)" >&2
    exit 1
fi
if [[ -z "$QUEUE_DIR" ]]; then
    echo "watcher.sh: missing required --queue-dir (use --help for usage)" >&2
    exit 1
fi
if [[ -z "$PROJECT_DIR" ]]; then
    echo "watcher.sh: missing required --project-dir (use --help for usage)" >&2
    exit 1
fi

# Derive the PR number from the URL (last path segment).
PR_NUMBER="${PR_URL##*/}"
if ! [[ "$PR_NUMBER" =~ ^[0-9]+$ ]]; then
    echo "watcher.sh: could not derive PR number from url '$PR_URL'" >&2
    exit 1
fi

STATE_FILE="$PROJECT_DIR/.state/watchers/${PR_NUMBER}.state"
mkdir -p "$(dirname "$STATE_FILE")"

# Project name (used to construct the multiplexer session name when
# spawning remediation panes).
PROJECT_NAME="$(basename "$PROJECT_DIR")"

# Load project-level config (sets DEFAULT_AGENT, MULTIPLEXER, etc.) and
# source the multiplexer provider so spawn_task_pane_detached / kill_task_pane
# / pane_is_running are available for remediation dispatch below.
load_provider_config "$PROJECT_DIR"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/mux.sh"

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

# Find the worktree path for a task. Reads repos from the task file
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

# Spawn a remediation agent in a new (unfocused) multiplexer pane and
# wait for it to complete. Three independent completion signals: pane
# exited, the PR's head SHA changed (agent pushed a fix), or a hard
# timeout. Force-kill the pane at the end regardless to handle Claude
# Code's "/exit" not actually terminating its process.
#
# Serial per PR: this function blocks until the remediation finishes,
# so the watcher's main poll loop can't dispatch a second remediation
# on the same PR while one is in flight.
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

    local agent="${DEFAULT_AGENT:-claude}"
    local session="${TMUX_SESSION}-${PROJECT_NAME}"
    local remediation_id="rem-${PR_NUMBER}-${skill_name//\//-}"

    # Capture initial head SHA so a successful push counts as completion.
    local initial_sha
    initial_sha=$(gh pr view "$PR_URL" --json commits -q '.commits[-1].oid' 2>/dev/null || true)

    log "dispatching $skill in pane $remediation_id"
    spawn_task_pane_detached "$session" "$remediation_id" "$prompt_file" "$worktree_path" "$agent" > /dev/null 2>&1 || {
        log "spawn_task_pane_detached failed; falling back to inline execution"
        local cmd
        cmd=$(provider_task_cmd "$agent" "$prompt_file" "$worktree_path")
        bash -c "$cmd"
        rm -f "$prompt_file"
        return 0
    }

    # Wait for ANY of: pane exit, new commit pushed, timeout. 5 min cap.
    local timeout_s=300
    local start_t
    start_t=$(date +%s)
    while true; do
        if ! pane_is_running "$session" "$remediation_id"; then
            log "remediation pane exited cleanly"
            break
        fi
        local current_sha
        current_sha=$(gh pr view "$PR_URL" --json commits -q '.commits[-1].oid' 2>/dev/null || true)
        if [[ -n "$current_sha" && -n "$initial_sha" && "$current_sha" != "$initial_sha" ]]; then
            log "remediation pushed new commit ($current_sha); tearing down pane"
            break
        fi
        local now_t
        now_t=$(date +%s)
        if (( now_t - start_t > timeout_s )); then
            log "remediation $skill exceeded ${timeout_s}s — force-killing pane"
            break
        fi
        sleep 5
    done

    # Force-kill regardless. Idempotent if the pane already exited.
    kill_task_pane "$session" "$remediation_id" 2>/dev/null || true
    rm -f "$prompt_file"
}

log "watcher starting (pr=$PR_URL, task=$TASK_ID, poll=${POLL_INTERVAL}s)"

prev_state=""
if [[ -f "$STATE_FILE" ]]; then
    prev_state=$(cat "$STATE_FILE")
fi

while true; do
    pr_json=$(gh pr view "$PR_URL" --json state,isDraft,mergeable,statusCheckRollup,reviews,comments,mergedAt,title,number 2>/dev/null) || {
        # Dedupe: only log the first failure of a run and the recovery.
        if [[ "${gh_failing:-0}" != "1" ]]; then
            log "gh pr view failed; will retry every ${POLL_INTERVAL}s until recovered"
            gh_failing=1
        fi
        sleep "$POLL_INTERVAL"
        continue
    }
    if [[ "${gh_failing:-0}" == "1" ]]; then
        log "gh pr view recovered"
        gh_failing=0
    fi

    curr_state=$(watcher_extract_state "$pr_json")
    events=$(watcher_diff_events "$prev_state" "$curr_state")

    terminal=0
    last_action=""
    if [[ -n "$events" ]]; then
        while IFS= read -r event; do
            [[ -z "$event" ]] && continue
            action=$(watcher_dispatch_action "$event")
            kind=$(_action_get "$action" "kind")
            case "$kind" in
                log)
                    if [[ "$event" != "first_poll" ]]; then
                        log "event: $event"
                    fi
                    last_action="event: $event"
                    ;;
                hook)
                    local_hook=$(_action_get "$action" "hook_name")
                    log "event: $event → hook $local_hook"
                    _run_hook "$local_hook" --task-id "$TASK_ID" --pr-url "$PR_URL" --pr-number "$PR_NUMBER"
                    last_action="event: $event → hook $local_hook"
                    ;;
                llm)
                    skill=$(_action_get "$action" "skill")
                    log "event: $event → dispatching $skill"
                    dispatch_remediation "$skill"
                    last_action="event: $event → dispatched $skill"
                    ;;
                terminal)
                    trans=$(_action_get "$action" "transition")
                    reason=$(_action_get "$action" "reason")
                    case "$trans" in
                        mark_done)
                            log "event: $event → state_mark_done"
                            state_mark_done "$QUEUE_DIR" "$TASK_ID" > /dev/null
                            last_action="event: $event → state_mark_done"
                            ;;
                        mark_blocked)
                            log "event: $event → state_mark_blocked"
                            state_mark_blocked "$QUEUE_DIR" "$TASK_ID" "${reason:-PR closed without merging}" > /dev/null
                            last_action="event: $event → state_mark_blocked"
                            ;;
                    esac
                    terminal=1
                    ;;
            esac
        done <<< "$events"
    fi

    # Persist current state for the next iteration. Append last_action
    # (if any event fired this poll) so the renderer can show the most
    # recent activity. Cache raw gh JSON for the renderer's per-check
    # rows and reviewer details.
    {
        echo "$curr_state"
        if [[ -n "$last_action" ]]; then
            echo "last_action=$last_action"
            echo "last_action_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        fi
    } > "$STATE_FILE"
    echo "$pr_json" > "${STATE_FILE%.state}.json"

    if (( terminal == 1 )); then
        log "terminal event reached; watcher exiting"
        exit 0
    fi

    prev_state="$curr_state"
    sleep "$POLL_INTERVAL"
done
