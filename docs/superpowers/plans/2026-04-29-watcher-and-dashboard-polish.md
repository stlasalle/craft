# Watcher + Dashboard UI Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the silent log-only watcher window with a split pane (live status snapshot + log tail), and elevate the orchestrator dashboard to surface watcher freshness, PR titles, and a recent-activity feed. Pure bash + ANSI; no Node.js dependency.

**Architecture:** Watchers cache their last raw `gh pr view` JSON next to the existing flat-state file. A new `render-watcher-status.sh` script reads both and prints a formatted snapshot. `spawn_watcher_pane` splits the tmux window so the status snapshot lives in one pane (refreshed via `while sleep N; do clear; render…; done`) while `watcher.sh`'s log scrolls in the other. The orchestrator's dashboard moves into `render-dashboard.sh` and reads watcher state files to surface per-PR freshness. A small `.state/notified-milestones/` marker pattern dedupes the milestone-completion log spam.

**Tech Stack:** Bash + ANSI escape sequences + `jq` (already required) + `gh` CLI (already required) + `tmux` (already required). No new runtime deps.

---

## File Structure

**Files to create:**
- `bin/render-watcher-status.sh` — pure render-once script. Args: `<state-file> <json-file>`. Outputs a formatted ANSI snapshot to stdout. No I/O beyond reading those two files. Used by the tmux status pane.
- `bin/render-dashboard.sh` — extracted from `orchestrator.sh::render_dashboard`. Args: `<project-dir>`. Outputs the dashboard once. The orchestrator's main loop calls it directly each tick; future Plans can replace the caller without touching the renderer.
- `test/test-render-watcher-status.sh` — fixture-based tests for the renderer.
- `test/fixtures/watcher-render/<scenario>.{state,json}` — paired fixture files for various PR states.

**Files to modify:**
- `bin/lib/mux-tmux.sh` — `spawn_watcher_pane` splits the window after creation so log + status sit side-by-side.
- `bin/lib/mux-cmux.sh` — same, cmux-style.
- `bin/watcher.sh` — write `<pr>.json` cache each poll, write `last_action=` to `<pr>.state`, drop `first_poll` log noise, dedupe identical consecutive log lines.
- `bin/orchestrator.sh` — replace inline `render_dashboard` with a call to `bin/render-dashboard.sh`. Add `.state/notified-milestones/` markers in `check_milestone_completion`.
- `Makefile` — `test` target runs `test-render-watcher-status.sh`.

**Files left alone:**
- `bin/lib/state.sh`, `bin/lib/state-local.sh`, `bin/lib/queue.sh` — unchanged.
- `bin/lib/watcher-events.sh` — unchanged.
- `templates/.claude/commands/*` — unchanged.

---

## Task 1: JSON cache from the watcher

The renderer needs the raw `gh pr view` JSON to show per-check rows, reviewer names, etc. The watcher already calls `gh` every poll; just persist the result.

**Files:**
- Modify: `bin/watcher.sh`

- [ ] **Step 1: Locate the gh pr view call**

Run: `grep -n 'gh pr view' bin/watcher.sh`

Expected: a line inside the main `while true` loop, around `pr_json=$(gh pr view "$PR_URL" --json …)`.

- [ ] **Step 2: Add the JSON cache write next to the existing state-file write**

Find the existing block in `bin/watcher.sh` (in the main loop, after `curr_state=$(watcher_extract_state "$pr_json")` and after the events handling, near where we do `echo "$curr_state" > "$STATE_FILE"`). Add a sibling write for the JSON.

Locate this block:

```bash
    # Persist current state for the next iteration.
    echo "$curr_state" > "$STATE_FILE"
```

Replace with:

```bash
    # Persist current state for the next iteration. Also cache the raw
    # gh pr view JSON for the status renderer.
    echo "$curr_state" > "$STATE_FILE"
    echo "$pr_json" > "${STATE_FILE%.state}.json"
```

The JSON path is derived from the state path so the two files always sit together as `.state/watchers/<pr>.state` and `.state/watchers/<pr>.json`.

- [ ] **Step 3: Smoke-test that cache write works**

```bash
bash -n bin/watcher.sh && echo "syntax OK"
```

Expected: `syntax OK`.

- [ ] **Step 4: Run the test suites**

Run: `make test`

Expected: existing 126 assertions still green.

- [ ] **Step 5: Commit**

```bash
git add bin/watcher.sh
git commit -m "feat(watcher): cache raw gh pr view JSON for the status renderer

Writes the unparsed JSON to .state/watchers/<pr>.json on each poll,
alongside the existing flat-state file. The renderer (next commit)
uses this for per-check rows, reviewer details, and PR metadata
that the flat state blob does not preserve."
```

---

## Task 2: Last-action and dedupe in the watcher log

Make the watcher's log clean enough that a human can read it without effort: drop the noisy `first_poll` line, dedupe consecutive identical entries (none happen today on the event path, but the gh-fail retry can spam), and record the most recent action in the state file so the renderer can show it.

**Files:**
- Modify: `bin/watcher.sh`

- [ ] **Step 1: Declare `last_action` outside the events loop and capture each iteration**

In `bin/watcher.sh`, find the events-handling block in the main loop. It currently looks like:

```bash
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
```

Replace the entire block with this version. The changes are:
- Declare `last_action=""` ONCE before the inner while loop so it survives across iterations.
- Each case branch sets `last_action` to a short description.
- The `log)` branch suppresses `event: first_poll` from the log (no signal value), but still records it as `last_action`.

```bash
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
```

After this loop, `last_action` holds the most recent event's description (or `""` if no events fired this poll). The persist block in the next step uses it.

- [ ] **Step 1b: Update the state-file write to include `last_action`**

Locate this block (immediately after the events-handling block, just before the `if (( terminal == 1 ))` check):

```bash
    # Persist current state for the next iteration.
    echo "$curr_state" > "$STATE_FILE"
```

Replace with:

```bash
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
```

Note: this also subsumes the JSON-cache write from Task 1's commit. Confirm the previous Task 1 line `echo "$pr_json" > "${STATE_FILE%.state}.json"` is no longer duplicated — it should appear ONCE, inside this new block.

- [ ] **Step 2: Dedupe consecutive identical gh-failure log lines**

In the main loop, locate this block:

```bash
    pr_json=$(gh pr view "$PR_URL" --json state,isDraft,mergeable,statusCheckRollup,reviews,comments,mergedAt,title,number 2>/dev/null) || {
        log "gh pr view failed; retrying after interval"
        sleep "$POLL_INTERVAL"
        continue
    }
```

Replace with:

```bash
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
```

This logs once at start of failure, once at recovery; no spam in between.

- [ ] **Step 3: Syntax check**

Run: `bash -n bin/watcher.sh && echo "syntax OK"`

Expected: `syntax OK`.

- [ ] **Step 4: Run the test suites**

Run: `make test`

Expected: 126 assertions still green (these changes don't affect the watcher-events tests).

- [ ] **Step 5: Commit**

```bash
git add bin/watcher.sh
git commit -m "feat(watcher): record last_action in state, dedupe noisy logs

- Suppress 'event: first_poll' from the log (no signal value).
- Record last_action and last_action_at in the state file so the
  status renderer can show 'most recent action'.
- Dedupe consecutive 'gh pr view failed' messages — log once per
  failure run with a single recovery line, instead of every 30s."
```

---

## Task 3: Test scaffolding for the watcher status renderer

Set up the test harness and fixtures before writing the renderer.

**Files:**
- Create: `test/test-render-watcher-status.sh`
- Create: `test/fixtures/watcher-render/.gitkeep`
- Modify: `Makefile`

- [ ] **Step 1: Create `test/test-render-watcher-status.sh`**

```bash
#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CRAFT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURES_DIR="$SCRIPT_DIR/fixtures/watcher-render"
RENDERER="$CRAFT_ROOT/bin/render-watcher-status.sh"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

pass() { TESTS_PASSED=$((TESTS_PASSED + 1)); echo "  ✓ $1"; }
fail() { TESTS_FAILED=$((TESTS_FAILED + 1)); echo "  ✗ $1 — $2"; }

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if echo "$haystack" | grep -q -- "$needle"; then
        pass "$label"
    else
        fail "$label" "expected to contain '$needle' in:
$haystack"
    fi
}

assert_not_contains() {
    local label="$1" needle="$2" haystack="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if echo "$haystack" | grep -q -- "$needle"; then
        fail "$label" "did NOT expect '$needle' in:
$haystack"
    else
        pass "$label"
    fi
}

echo "render-watcher-status scaffolding"
if [[ -x "$RENDERER" ]]; then
    pass "renderer exists and is executable"
    TESTS_RUN=$((TESTS_RUN + 1))
fi

echo ""
echo "────────────────────────────"
echo "$TESTS_RUN tests: $TESTS_PASSED passed, $TESTS_FAILED failed"

if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
fi
```

- [ ] **Step 2: Create the fixtures directory and make the test executable**

```bash
mkdir -p test/fixtures/watcher-render
touch test/fixtures/watcher-render/.gitkeep
chmod +x test/test-render-watcher-status.sh
```

- [ ] **Step 3: Wire into Makefile**

In `Makefile`, replace the `test` target:

```makefile
test:
	@echo "Running tests..."
	@bash $(CURDIR)/test/test-queue.sh
	@bash $(CURDIR)/test/test-state.sh
	@bash $(CURDIR)/test/test-watcher-events.sh
	@bash $(CURDIR)/test/test-render-watcher-status.sh
```

- [ ] **Step 4: Run `make test`**

Run: `make test`

Expected: existing 126 assertions still green; new suite reports `0 tests: 0 passed, 0 failed` (scaffold only — no renderer yet, so the existence assertion's TESTS_RUN ends at 0 because the if-block is gated; this is fine for a scaffold step).

If you instead get an error about the new test file failing because of bash strictness, just verify the file's set -uo pipefail is honored.

- [ ] **Step 5: Commit**

```bash
git add test/test-render-watcher-status.sh test/fixtures/watcher-render/.gitkeep Makefile
git commit -m "test(watcher): scaffold renderer test harness

Adds test/test-render-watcher-status.sh with the standard pass/fail
assertions, and the fixtures directory placeholder. Wires the new
suite into make test alongside the others."
```

---

## Task 4: Fixture files for the renderer

Three fixtures cover the cases the renderer must handle gracefully: open-draft-pending (early state), open-ready-ci-failed (active remediation territory), merged (terminal). Each is a paired `.state` (flat key=value) and `.json` (raw gh output) — exactly what the renderer reads from disk.

**Files:**
- Create: `test/fixtures/watcher-render/open-draft-pending.state`
- Create: `test/fixtures/watcher-render/open-draft-pending.json`
- Create: `test/fixtures/watcher-render/open-ready-ci-failed.state`
- Create: `test/fixtures/watcher-render/open-ready-ci-failed.json`
- Create: `test/fixtures/watcher-render/merged.state`
- Create: `test/fixtures/watcher-render/merged.json`

- [ ] **Step 1: Create open-draft-pending fixtures**

`test/fixtures/watcher-render/open-draft-pending.state`:

```
state=OPEN
is_draft=true
mergeable=MERGEABLE
checks_conclusion=PENDING
review_count=0
comment_count=0
approved_count=0
changes_requested_count=0
```

`test/fixtures/watcher-render/open-draft-pending.json`:

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

- [ ] **Step 2: Create open-ready-ci-failed fixtures**

`test/fixtures/watcher-render/open-ready-ci-failed.state`:

```
state=OPEN
is_draft=false
mergeable=MERGEABLE
checks_conclusion=FAILURE
review_count=2
comment_count=3
approved_count=1
changes_requested_count=1
last_action=event: ci_failed → dispatched /fix-ci-failure
last_action_at=2026-04-29T14:32:01Z
```

`test/fixtures/watcher-render/open-ready-ci-failed.json`:

```json
{
  "state": "OPEN",
  "isDraft": false,
  "mergeable": "MERGEABLE",
  "title": "fix: cache invalidation in user service",
  "number": 137,
  "mergedAt": null,
  "statusCheckRollup": [
    {"name": "lint", "conclusion": "SUCCESS", "status": "COMPLETED"},
    {"name": "unit-tests", "conclusion": "SUCCESS", "status": "COMPLETED"},
    {"name": "integration", "conclusion": "FAILURE", "status": "COMPLETED"}
  ],
  "reviews": [
    {"state": "APPROVED", "author": {"login": "alice"}},
    {"state": "CHANGES_REQUESTED", "author": {"login": "bob"}}
  ],
  "comments": [
    {"id": "c1"},
    {"id": "c2"},
    {"id": "c3"}
  ]
}
```

- [ ] **Step 3: Create merged fixtures**

`test/fixtures/watcher-render/merged.state`:

```
state=MERGED
is_draft=false
mergeable=UNKNOWN
checks_conclusion=SUCCESS
review_count=1
comment_count=0
approved_count=1
changes_requested_count=0
last_action=event: merged → state_mark_done
last_action_at=2026-04-29T15:41:32Z
```

`test/fixtures/watcher-render/merged.json`:

```json
{
  "state": "MERGED",
  "isDraft": false,
  "mergeable": "UNKNOWN",
  "title": "feat: add widget",
  "number": 42,
  "mergedAt": "2026-04-29T15:41:00Z",
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

- [ ] **Step 4: Verify fixtures parse**

Run:

```bash
for f in test/fixtures/watcher-render/*.json; do
    jq . "$f" > /dev/null && echo "  ok: $f" || echo "  BAD: $f"
done
```

Expected: three `ok:` lines.

- [ ] **Step 5: Commit**

```bash
git add test/fixtures/watcher-render/
git commit -m "test(watcher): add render fixtures for three PR states

Three paired fixtures (.state + .json) covering open-draft-pending,
open-ready-ci-failed, and merged. The renderer (next commit) is
tested against these to verify it handles each state without
errors and surfaces the right fields."
```

---

## Task 5: Implement `bin/render-watcher-status.sh`

The renderer reads the two files and prints a formatted snapshot. Run-once; the tmux pane wraps it in a `while sleep N; do clear; render…; done` loop.

**Files:**
- Create: `bin/render-watcher-status.sh`
- Modify: `test/test-render-watcher-status.sh`

- [ ] **Step 1: Add failing tests for the renderer**

Append to `test/test-render-watcher-status.sh` before the `--- Summary ---` section:

```bash
echo ""
echo "render-watcher-status: open-draft-pending"
out=$("$RENDERER" "$FIXTURES_DIR/open-draft-pending.state" "$FIXTURES_DIR/open-draft-pending.json")
assert_contains "shows PR title" "feat: add widget" "$out"
assert_contains "shows PR number" "PR #42" "$out"
assert_contains "shows DRAFT badge" "DRAFT" "$out"
assert_contains "shows lint check name" "lint" "$out"
assert_contains "shows unit-tests check name" "unit-tests" "$out"
assert_contains "shows mergeable status" "MERGEABLE" "$out"

echo ""
echo "render-watcher-status: open-ready-ci-failed"
out=$("$RENDERER" "$FIXTURES_DIR/open-ready-ci-failed.state" "$FIXTURES_DIR/open-ready-ci-failed.json")
assert_contains "shows fix PR title" "fix: cache invalidation" "$out"
assert_contains "shows READY badge" "READY" "$out"
assert_contains "shows integration check failure" "integration" "$out"
assert_contains "shows alice approved" "alice" "$out"
assert_contains "shows bob changes requested" "bob" "$out"
assert_contains "shows last action" "ci_failed" "$out"
assert_not_contains "no DRAFT badge on ready PR" "DRAFT" "$out"

echo ""
echo "render-watcher-status: merged"
out=$("$RENDERER" "$FIXTURES_DIR/merged.state" "$FIXTURES_DIR/merged.json")
assert_contains "shows MERGED badge" "MERGED" "$out"
assert_contains "shows last action mark_done" "state_mark_done" "$out"

echo ""
echo "render-watcher-status: missing files"
# Renderer exits non-zero with a clear message when state file is missing.
if "$RENDERER" /nonexistent.state /nonexistent.json > /tmp/render-err.out 2>&1; then
    fail "missing files exit non-zero" "renderer succeeded on missing files"
    TESTS_RUN=$((TESTS_RUN + 1))
else
    pass "missing files exit non-zero"
    TESTS_RUN=$((TESTS_RUN + 1))
fi
```

- [ ] **Step 2: Run tests — they should fail**

Run: `./test/test-render-watcher-status.sh`

Expected: file-not-found errors (renderer doesn't exist yet) for the existence check.

- [ ] **Step 3: Create `bin/render-watcher-status.sh`**

```bash
#!/usr/bin/env bash
set -uo pipefail

# render-watcher-status.sh — One-shot status renderer for a watched PR.
#
# Usage: render-watcher-status.sh <state-file> <json-file>
#
# Reads the watcher's flat-state file (key=value) and the cached
# `gh pr view` JSON. Prints a formatted snapshot to stdout. Caller
# is responsible for clearing the screen / refreshing.

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <state-file> <json-file>" >&2
    exit 1
fi

STATE_FILE="$1"
JSON_FILE="$2"

if [[ ! -f "$STATE_FILE" ]]; then
    echo "render-watcher-status: state file not found: $STATE_FILE" >&2
    exit 1
fi
if [[ ! -f "$JSON_FILE" ]]; then
    echo "render-watcher-status: json file not found: $JSON_FILE" >&2
    exit 1
fi

# ANSI colors
BOLD=$'\033[1m'
DIM=$'\033[2m'
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'
NC=$'\033[0m'

# Read flat state.
_state_get() {
    local key="$1"
    grep "^${key}=" "$STATE_FILE" | head -1 | sed "s/^${key}=//"
}

state=$(_state_get state)
is_draft=$(_state_get is_draft)
mergeable=$(_state_get mergeable)
checks_conclusion=$(_state_get checks_conclusion)
last_action=$(_state_get last_action)
last_action_at=$(_state_get last_action_at)

# Read JSON.
title=$(jq -r '.title // ""' "$JSON_FILE")
number=$(jq -r '.number // ""' "$JSON_FILE")

# Badge for the PR state.
badge=""
case "$state" in
    OPEN)
        if [[ "$is_draft" == "true" ]]; then
            badge="${YELLOW}DRAFT${NC}"
        else
            badge="${CYAN}READY${NC}"
        fi
        ;;
    MERGED) badge="${GREEN}MERGED${NC}" ;;
    CLOSED) badge="${RED}CLOSED${NC}" ;;
    *)      badge="${DIM}${state}${NC}" ;;
esac

# Header.
printf "%s\n" "${BOLD}═══════════════════════════════════════════════════════════════════${NC}"
printf "%s PR #%s — %s   %b\n" "${BOLD}" "$number" "$title" "$badge"
printf "%s mergeable: %s\n" "${DIM}" "$mergeable${NC}"
printf "%s\n" "${BOLD}═══════════════════════════════════════════════════════════════════${NC}"
echo ""

# CI Checks
echo "${BOLD}CI Checks${NC}"
jq -r '
    .statusCheckRollup // []
    | map({name, conclusion, status})
    | .[]
    | "\(.name)\t\(.conclusion // "")\t\(.status // "")"
' "$JSON_FILE" | while IFS=$'\t' read -r name concl status; do
    icon=""
    case "$concl" in
        SUCCESS) icon="${GREEN}✓${NC}" ;;
        FAILURE) icon="${RED}✗${NC}" ;;
        *)
            case "$status" in
                IN_PROGRESS|PENDING|QUEUED) icon="${YELLOW}●${NC}" ;;
                *) icon="${DIM}?${NC}" ;;
            esac
            ;;
    esac
    printf "  %b %s\n" "$icon" "$name"
done
echo ""

# Reviews
echo "${BOLD}Reviews${NC}"
review_lines=$(jq -r '
    .reviews // []
    | map("\(.author.login // "?")\t\(.state // "?")")
    | .[]
' "$JSON_FILE")
if [[ -z "$review_lines" ]]; then
    echo "  ${DIM}(none)${NC}"
else
    echo "$review_lines" | while IFS=$'\t' read -r who st; do
        case "$st" in
            APPROVED)          col="${GREEN}" ;;
            CHANGES_REQUESTED) col="${RED}" ;;
            *)                 col="${DIM}" ;;
        esac
        printf "  %s%-12s%b %s\n" "$col" "$who" "${NC}" "$st"
    done
fi
echo ""

# Last action
echo "${BOLD}Last Action${NC}"
if [[ -n "$last_action" ]]; then
    printf "  %s %s%s%s\n" "$last_action" "${DIM}" "$last_action_at" "${NC}"
else
    echo "  ${DIM}(none yet)${NC}"
fi
echo ""

# Footer
printf "%s%sUpdated: %s%s\n" "${DIM}" "" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "${NC}"
```

- [ ] **Step 4: Make executable**

Run: `chmod +x bin/render-watcher-status.sh`

- [ ] **Step 5: Run tests — they should pass**

Run: `./test/test-render-watcher-status.sh`

Expected: all assertions pass.

- [ ] **Step 6: Eyeball it**

Run:

```bash
./bin/render-watcher-status.sh \
    test/fixtures/watcher-render/open-ready-ci-failed.state \
    test/fixtures/watcher-render/open-ready-ci-failed.json
```

Expected: a colored, structured snapshot in your terminal showing PR #137, the failed integration check, alice/bob reviews, and the last action.

- [ ] **Step 7: Commit**

```bash
git add bin/render-watcher-status.sh test/test-render-watcher-status.sh
git commit -m "feat(watcher): add render-watcher-status.sh snapshot script

One-shot renderer that takes a watcher's flat state file and the
cached gh pr view JSON, prints a formatted ANSI snapshot: header
with PR number/title/state badge, CI check matrix, reviews block,
last action timestamp.

Tested against three fixtures (open-draft-pending, open-ready-
ci-failed, merged) plus a missing-files error path."
```

---

## Task 6: Tmux split-pane on watcher spawn

`spawn_watcher_pane` in `bin/lib/mux-tmux.sh` currently creates one window with the watcher script. We add a horizontal split where the top pane runs a refresh-loop calling `render-watcher-status.sh` and the bottom pane runs `watcher.sh` as before.

**Files:**
- Modify: `bin/lib/mux-tmux.sh`

- [ ] **Step 1: Update `spawn_watcher_pane`**

In `bin/lib/mux-tmux.sh`, find the existing `spawn_watcher_pane`:

```bash
spawn_watcher_pane() {
    local session="$1" pr_number="$2" cmd="$3"
    local window_name="watch-pr-${pr_number}"

    local window_id
    window_id=$(tmux new-window -t "${session}:" -n "$window_name" -P -F '#{window_id}' "$cmd")

    echo "$window_id"
}
```

Replace with:

```bash
spawn_watcher_pane() {
    local session="$1" pr_number="$2" cmd="$3"
    local window_name="watch-pr-${pr_number}"

    # Resolve script paths via the directory this file lives in (bin/lib),
    # so the renderer is found regardless of caller cwd.
    local lib_dir
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local renderer="${lib_dir%/lib}/render-watcher-status.sh"

    # Locate the project's .state/watchers/<pr>.{state,json} files.
    # The watcher.sh writes them; we derive the path from the cmd's
    # --project-dir argument.
    local project_dir
    project_dir=$(echo "$cmd" | sed -nE "s/.*--project-dir '([^']*)'.*/\\1/p")
    local state_file="${project_dir}/.state/watchers/${pr_number}.state"
    local json_file="${project_dir}/.state/watchers/${pr_number}.json"

    # Refresh script for the status pane: re-renders every 5s. Tolerates
    # the state files not existing yet (first poll hasn't completed).
    local refresh_cmd="while true; do
        clear
        if [[ -f '$state_file' && -f '$json_file' ]]; then
            '$renderer' '$state_file' '$json_file' || echo 'renderer error'
        else
            echo 'waiting for first poll…'
        fi
        sleep 5
    done"

    # Create the window running the watcher's log loop in the bottom pane.
    local window_id
    window_id=$(tmux new-window -t "${session}:" -n "$window_name" -P -F '#{window_id}' "$cmd")

    # Split the new window: top pane = status snapshot, bottom = log.
    # We split BEFORE the watcher emits much output so the visual
    # arrangement is established immediately.
    tmux split-window -v -b -t "$window_id" -p 50 "$refresh_cmd" 2>/dev/null || true

    # Re-focus the bottom (log) pane so cursor activity attracts attention.
    tmux select-pane -t "$window_id" -D 2>/dev/null || true

    echo "$window_id"
}
```

Note the use of `tmux split-window -v -b -t "$window_id" -p 50` — `-v` for vertical (horizontal divider), `-b` to put the new pane *before* (above) the existing one, `-p 50` for 50/50 split. Then `select-pane -D` moves focus down to the log pane.

- [ ] **Step 2: Smoke test**

Run:

```bash
bash -n bin/lib/mux-tmux.sh && echo "syntax OK"
```

Expected: `syntax OK`.

- [ ] **Step 3: Run the test suites**

Run: `make test`

Expected: all suites green. None of the existing tests cover the mux providers directly.

- [ ] **Step 4: Manual integration test (optional, requires a real project + tmux)**

If a delivery-harness-test or similar project is available with a watching task:

```bash
# Start the orchestrator (manual, since the exec path has a known issue)
CRAFT_INNER_SESSION=1 ~/src/craft/bin/orchestrator.sh \
    /path/to/project --max-parallel 1 --poll-interval 5
```

Wait for a watcher to spawn. Then `tmux attach`, switch to a `watch-pr-<N>` window, and verify:
- Top half: PR header + CI matrix + reviews + last action.
- Bottom half: watcher log lines as before.
- Top half re-renders every ~5s.

- [ ] **Step 5: Commit**

```bash
git add bin/lib/mux-tmux.sh
git commit -m "feat(mux-tmux): split watcher window into status + log panes

spawn_watcher_pane now creates a horizontally-split window: the top
pane re-renders the watcher's status snapshot every 5s via
render-watcher-status.sh; the bottom pane is the existing log
stream. Both share the same .state/watchers/<pr>.{state,json}
artifacts written by watcher.sh.

If the state files don't exist yet (first poll hasn't completed),
the top pane shows 'waiting for first poll…' until they appear."
```

---

## Task 7: Cmux split-pane parity

The cmux provider needs a matching split. The pattern mirrors tmux but uses cmux's `new-split` (already used by `spawn_task_pane` for cmux).

**Files:**
- Modify: `bin/lib/mux-cmux.sh`

- [ ] **Step 1: Read existing `spawn_watcher_pane` in mux-cmux.sh**

Run: `grep -n -A 20 'spawn_watcher_pane' bin/lib/mux-cmux.sh`

Note the existing function's pattern; we'll match its style.

- [ ] **Step 2: Update `spawn_watcher_pane` to do the split**

In `bin/lib/mux-cmux.sh`, find the existing `spawn_watcher_pane` function. Its current body uses cmux's surface API (`cmux select-workspace`, `cmux new-split down`, `cmux send`, etc.) to launch the watcher command.

Add a second `cmux new-split` call AFTER the watcher pane is created, this time spawning the refresh-loop renderer. The exact structure:

```bash
spawn_watcher_pane() {
    local session="$1" pr_number="$2" cmd="$3"
    local window_name="watch-pr-${pr_number}"

    # Locate the renderer and the state files (same logic as mux-tmux.sh).
    local lib_dir
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local renderer="${lib_dir%/lib}/render-watcher-status.sh"
    local project_dir
    project_dir=$(echo "$cmd" | sed -nE "s/.*--project-dir '([^']*)'.*/\\1/p")
    local state_file="${project_dir}/.state/watchers/${pr_number}.state"
    local json_file="${project_dir}/.state/watchers/${pr_number}.json"

    local refresh_cmd="while true; do
        clear
        if [[ -f '$state_file' && -f '$json_file' ]]; then
            '$renderer' '$state_file' '$json_file' || echo 'renderer error'
        else
            echo 'waiting for first poll…'
        fi
        sleep 5
    done"

    # Create the watcher pane.
    cmux select-workspace "$session" 2>/dev/null || true
    local surface_id
    surface_id=$(cmux new-split down 2>/dev/null || true)
    cmux set-status "watcher" "$window_name" 2>/dev/null || true
    cmux send "$cmd" 2>/dev/null || true
    cmux send-key enter 2>/dev/null || true

    # Save reference for pane_is_running.
    if [[ -n "${CMUX_SURFACES:-}" ]]; then
        CMUX_SURFACES["$window_name"]="${surface_id:-$window_name}"
    fi

    # Add the status pane above the watcher pane.
    cmux new-split up 2>/dev/null || true
    cmux set-status "watcher-status" "${window_name}-status" 2>/dev/null || true
    cmux send "$refresh_cmd" 2>/dev/null || true
    cmux send-key enter 2>/dev/null || true

    # Move focus back to the watcher (log) pane.
    cmux select-split down 2>/dev/null || true

    echo "${surface_id:-$window_name}"
}
```

If the existing cmux helper functions are named differently (e.g., `cmux split` instead of `cmux new-split`), match what the existing `spawn_task_pane` in the same file uses. **Do not invent new cmux subcommands.** If you can't determine the right syntax from the existing file, leave the cmux variant for a follow-up and only commit the tmux change from Task 6.

- [ ] **Step 3: Syntax check**

Run: `bash -n bin/lib/mux-cmux.sh && echo "syntax OK"`

Expected: `syntax OK`.

- [ ] **Step 4: Function-availability check**

```bash
bash -c '
    MULTIPLEXER=cmux source bin/lib/mux.sh
    declare -f spawn_watcher_pane > /dev/null && echo cmux:ok
'
```

Expected: `cmux:ok`.

- [ ] **Step 5: Commit**

```bash
git add bin/lib/mux-cmux.sh
git commit -m "feat(mux-cmux): split watcher window into status + log surfaces

Matches the tmux split done in the previous commit so cmux users
get the same status pane + log split. Above the watcher's log
surface, a second split runs render-watcher-status.sh in a 5s
refresh loop."
```

---

## Task 8: Extract dashboard renderer + freshness signals

Move `render_dashboard` from `bin/orchestrator.sh` into `bin/render-dashboard.sh`. The new script reads watcher state files to surface per-PR freshness (`polled Ns ago`), titles, and CI status. Activity feed reads the orchestrator log.

**Files:**
- Create: `bin/render-dashboard.sh`
- Modify: `bin/orchestrator.sh`

- [ ] **Step 1: Create `bin/render-dashboard.sh`**

```bash
#!/usr/bin/env bash
set -uo pipefail

# render-dashboard.sh — One-shot orchestrator dashboard renderer.
#
# Usage: render-dashboard.sh <project-dir>
#
# Reads queue/, .state/watchers/, and logs/ from the project directory
# and prints a single dashboard snapshot. Caller is responsible for
# clearing the screen / scheduling refreshes.

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <project-dir>" >&2
    exit 1
fi

PROJECT_DIR="$1"
QUEUE_DIR="$PROJECT_DIR/queue"
WATCHERS_DIR="$PROJECT_DIR/.state/watchers"
LOG_FILE="$PROJECT_DIR/logs/orchestrator-$(date '+%Y-%m-%d').log"
PROJECT_NAME="$(basename "$PROJECT_DIR")"

CRAFT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$CRAFT_ROOT/bin/lib/state.sh"

# ANSI
BOLD=$'\033[1m'
DIM=$'\033[2m'
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
CYAN=$'\033[0;36m'
NC=$'\033[0m'

n_pending=$(count_tasks "$QUEUE_DIR/pending")
n_approved=$(count_tasks "$QUEUE_DIR/approved")
n_in_progress=$(count_tasks "$QUEUE_DIR/in-progress")
n_waiting=$(count_tasks "$QUEUE_DIR/waiting")
n_done=$(count_tasks "$QUEUE_DIR/done")
n_blocked=$(count_tasks "$QUEUE_DIR/blocked")

# Header.
printf "%s╔═══════════════════════════════════════════════════════════════════╗%s\n" "$BOLD" "$NC"
printf "%s║  CRAFT — %-56s║%s\n" "$BOLD" "$PROJECT_NAME" "$NC"
printf "%s╚═══════════════════════════════════════════════════════════════════╝%s\n" "$BOLD" "$NC"
echo ""

# Queue.
printf "Queue   %s○%s pending %d   %s◐%s approved %d   %s●%s in-progress %d   %s◉%s waiting %d   %s✓%s done %d   %s✗%s blocked %d\n" \
    "$BLUE" "$NC" "$n_pending" \
    "$YELLOW" "$NC" "$n_approved" \
    "$CYAN" "$NC" "$n_in_progress" \
    "$YELLOW" "$NC" "$n_waiting" \
    "$GREEN" "$NC" "$n_done" \
    "$RED" "$NC" "$n_blocked"
echo ""

# Workers (in-progress tasks).
if (( n_in_progress > 0 )); then
    printf "%s  Workers%s\n" "$BOLD" "$NC"
    for f in $(list_tasks "$QUEUE_DIR/in-progress"); do
        local_tid=$(task_id "$f")
        title=$(grep '^# ' "$f" | head -1 | sed 's/^# //')
        printf "    %s●%s %-12s %s\n" "$CYAN" "$NC" "$local_tid" "${title:-(no title)}"
    done
    echo ""
fi

# Watchers (waiting tasks with pr field).
if (( n_waiting > 0 )); then
    printf "%s  Watchers%s\n" "$BOLD" "$NC"
    for f in $(list_tasks "$QUEUE_DIR/waiting"); do
        local_tid=$(task_id "$f")
        pr_url=$(task_field "$f" "pr")
        [[ -z "$pr_url" ]] && continue
        pr_number="${pr_url##*/}"
        title=$(grep '^# ' "$f" | head -1 | sed 's/^# //')
        # Freshness: mtime of the state file.
        state_file="$WATCHERS_DIR/${pr_number}.state"
        if [[ -f "$state_file" ]]; then
            now_epoch=$(date -u '+%s')
            file_epoch=$(stat -f '%m' "$state_file" 2>/dev/null || stat -c '%Y' "$state_file" 2>/dev/null)
            if [[ -n "$file_epoch" ]]; then
                age=$(( now_epoch - file_epoch ))
                if (( age < 60 )); then
                    fresh="${GREEN}polled ${age}s ago${NC}"
                elif (( age < 300 )); then
                    fresh="${YELLOW}polled ${age}s ago${NC}"
                else
                    fresh="${RED}STALE (${age}s)${NC}"
                fi
            else
                fresh="${DIM}unknown${NC}"
            fi
            # Read CI status if available.
            ci=$(grep '^checks_conclusion=' "$state_file" | sed 's/^checks_conclusion=//')
            case "$ci" in
                SUCCESS) ci_disp="${GREEN}CI✓${NC}" ;;
                FAILURE) ci_disp="${RED}CI✗${NC}" ;;
                PENDING) ci_disp="${YELLOW}CI●${NC}" ;;
                *)       ci_disp="${DIM}CI?${NC}" ;;
            esac
        else
            fresh="${DIM}no state yet${NC}"
            ci_disp=""
        fi
        printf "    %s◉%s pr-%-6s %-30s %b   %b\n" "$YELLOW" "$NC" "$pr_number" "${title:0:30}" "$ci_disp" "$fresh"
    done
    echo ""
fi

# Approved (queued for pickup).
if (( n_approved > 0 )); then
    printf "%s  Queue (approved)%s\n" "$BOLD" "$NC"
    for f in $(list_tasks "$QUEUE_DIR/approved"); do
        local_tid=$(task_id "$f")
        if task_deps_met "$f"; then
            dep_status="${GREEN}ready${NC}"
        else
            dep_status="${YELLOW}waiting on deps${NC}"
        fi
        printf "    %s◐%s %-12s [%b]\n" "$YELLOW" "$NC" "$local_tid" "$dep_status"
    done
    echo ""
fi

# Blocked.
if (( n_blocked > 0 )); then
    printf "%s%s  ⚠ Blocked%s\n" "$BOLD" "$RED" "$NC"
    for f in $(list_tasks "$QUEUE_DIR/blocked"); do
        local_tid=$(task_id "$f")
        title=$(grep '^# ' "$f" | head -1 | sed 's/^# //')
        printf "    %s✗%s %-12s %s\n" "$RED" "$NC" "$local_tid" "${title:-}"
    done
    echo ""
fi

# Recent activity (last 6 lines of the log).
if [[ -f "$LOG_FILE" ]]; then
    printf "%s  Recent%s\n" "$BOLD" "$NC"
    tail -6 "$LOG_FILE" | while IFS= read -r line; do
        printf "    %s%s%s\n" "$DIM" "$line" "$NC"
    done
    echo ""
fi

# Footer.
now=$(date '+%H:%M:%S')
printf "%sUpdated: %s%s\n" "$DIM" "$now" "$NC"
```

- [ ] **Step 2: Make executable**

Run: `chmod +x bin/render-dashboard.sh`

- [ ] **Step 3: Smoke test**

Test that the renderer runs without errors against the `delivery-harness-test` project (or any project you have):

```bash
./bin/render-dashboard.sh /Users/matt/src/craft/projects/delivery-harness-test
```

Expected: a formatted dashboard with queue counts, watchers section if any, recent log lines, etc. No errors.

- [ ] **Step 4: Update `bin/orchestrator.sh` to use the new renderer**

In `bin/orchestrator.sh`, find the existing `render_dashboard()` function. Replace its body with a call to the new script:

```bash
render_dashboard() {
    clear_screen
    "$SCRIPT_DIR/render-dashboard.sh" "$PROJECT_DIR"
    echo ""
    echo -e "  ${BOLD}Last poll:${NC} $(date '+%H:%M:%S')  ${BOLD}Parallel limit:${NC} $MAX_PARALLEL  ${BOLD}Poll interval:${NC} ${POLL_INTERVAL}s  ${BOLD}Agent:${NC} $DEFAULT_AGENT"
    echo -e "  ${BOLD}Ctrl+C${NC} to stop orchestrator"
}
```

The orchestrator's footer (poll interval, parallel limit, etc.) stays in the wrapper because those values come from runtime args, not from the project state.

- [ ] **Step 5: Run the test suites**

Run: `make test`

Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add bin/render-dashboard.sh bin/orchestrator.sh
git commit -m "feat(dashboard): extract renderer + add per-watcher freshness

bin/render-dashboard.sh is now a one-shot script the orchestrator
calls each tick. New affordances:
- Per-watcher freshness via state file mtime (green <60s, yellow
  <5m, red STALE).
- CI status badge per watcher (CI✓/CI✗/CI●) read from the watcher's
  own state file.
- PR title shown for each waiting task.
- Recent activity feed from the orchestrator log (last 6 lines).
- Approved queue with dep-readiness flags.

The orchestrator's render_dashboard() wraps the script call and
adds the runtime-only footer (poll interval, parallel limit)."
```

---

## Task 9: Milestone-completion notification dedupe

Pre-existing Craft bug surfaced during testing — `check_milestone_completion` logs `Milestone complete: <id>` every poll once a milestone's tasks are all done. Mirror the `.state/waiting/` marker pattern already used by `check_waiting_tasks`.

**Files:**
- Modify: `bin/orchestrator.sh`

- [ ] **Step 1: Locate `check_milestone_completion`**

Run: `grep -n 'check_milestone_completion' bin/orchestrator.sh`

Expected: function definition around line 332.

- [ ] **Step 2: Add a marker-file dedupe**

Find the function. Replace its body so the notification only fires once per milestone:

```bash
check_milestone_completion() {
    local marker_dir="$PROJECT_DIR/.state/notified-milestones"
    mkdir -p "$marker_dir"

    # Get all milestones that have tasks.
    local milestones
    milestones=$(for f in "$QUEUE_DIR"/done/*.md "$QUEUE_DIR"/approved/*.md "$QUEUE_DIR"/in-progress/*.md "$QUEUE_DIR"/pending/*.md; do
        [[ -f "$f" ]] && task_milestone "$f"
    done | sort -u)

    for milestone in $milestones; do
        [[ -z "$milestone" ]] && continue

        # Check if all tasks for this milestone are done.
        local all_done=true
        for dir in pending approved in-progress blocked; do
            for f in "$QUEUE_DIR/$dir"/*.md; do
                [[ -f "$f" ]] || continue
                if [[ "$(task_milestone "$f")" == "$milestone" ]]; then
                    all_done=false
                    break 2
                fi
            done
        done

        if $all_done; then
            local has_done=false
            for f in "$QUEUE_DIR/done"/*.md; do
                [[ -f "$f" ]] || continue
                if [[ "$(task_milestone "$f")" == "$milestone" ]]; then
                    has_done=true
                    break
                fi
            done

            if $has_done; then
                local marker="$marker_dir/$milestone"
                if [[ ! -f "$marker" ]]; then
                    touch "$marker"
                    notify_milestone "$milestone"
                    log "Milestone complete: $milestone — run /consolidate $milestone"
                fi
            fi
        else
            # Milestone is no longer fully done (a new task entered a
            # non-done state). Clear the marker so a future re-completion
            # re-notifies.
            local marker="$marker_dir/$milestone"
            [[ -f "$marker" ]] && rm -f "$marker"
        fi
    done
}
```

- [ ] **Step 3: Syntax check**

Run: `bash -n bin/orchestrator.sh && echo "syntax OK"`

Expected: `syntax OK`.

- [ ] **Step 4: Run the test suites**

Run: `make test`

Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add bin/orchestrator.sh
git commit -m "fix(orchestrator): dedupe milestone-complete notifications

Pre-existing bug: check_milestone_completion logged 'Milestone
complete: <id>' every poll once all of a milestone's tasks were
done, until the operator ran /consolidate. Now we use a
.state/notified-milestones/<id> marker file (mirroring the
.state/waiting/ pattern) so the notification fires once per
completion. The marker is cleared if a new task in that milestone
enters a non-done state, so re-completion re-notifies."
```

---

## Self-Review Checklist (run after all tasks)

- [ ] `make test` passes — `test-queue.sh` 34/34, `test-state.sh` 58/58, `test-watcher-events.sh` 34/34, `test-render-watcher-status.sh` all green.
- [ ] `bash -n` succeeds on every modified script (`bin/watcher.sh`, `bin/orchestrator.sh`, `bin/lib/mux-tmux.sh`, `bin/lib/mux-cmux.sh`).
- [ ] `./bin/render-watcher-status.sh test/fixtures/watcher-render/open-ready-ci-failed.{state,json}` prints a nicely-formatted snapshot in your terminal.
- [ ] `./bin/render-dashboard.sh /path/to/some/project` prints a formatted dashboard.
- [ ] Manual smoke test: kick off a watcher in a real project; confirm the new tmux window has two panes (status on top, log on bottom) and the status pane refreshes every ~5s.
- [ ] Manual smoke test: complete a milestone; verify "Milestone complete" log appears exactly once, not on every subsequent poll.
- [ ] No `TBD`, `TODO`, or placeholder strings in any new or modified file.

---

## What's Next

Plan 5 (remaining remediation skills + intervention skills) can now build on a much nicer-looking watcher pane. If the bash-only polish is enough, Ink (original Plan 4) becomes a "we'll see if we want this later" item rather than necessary work. If after using this for a while you decide you DO want sub-second updates or interactivity, the renderers we extracted (`render-watcher-status.sh`, `render-dashboard.sh`) are clean read-then-print scripts that an Ink frontend could call as backends — so even the eventual Ink work would build on this rather than discard it.
