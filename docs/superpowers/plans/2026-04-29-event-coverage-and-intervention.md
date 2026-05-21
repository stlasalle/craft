# Comment Dispatch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Verify the watcher's event-dispatch substrate works for a second skill (beyond `/fix-ci-failure` from Plan 2) by wiring `/address-review-comment` to fire on actionable comments and reviews — with pure-approval reviews filtered upstream so they don't trigger an LLM dispatch for nothing.

**Architecture:** The Plan 2 substrate (`watcher_dispatch_action` event-to-skill map) already handles `ci_failed`. This plan adds one more event-to-skill mapping (`new_comment_received` and `new_review_received` both → `/address-review-comment`), filters pure approvals upstream in `watcher_diff_events`, and writes the new skill. No other event types or operator-override skills are in scope; those are explicitly deferred until this verifies the plumbing.

**Tech Stack:** Bash + jq + gh CLI + watcher-events.sh (Plan 2). No new runtime dependencies.

---

## Scope decisions

**In scope:**
- One new skill: `/address-review-comment`.
- Wire `new_comment_received` and `new_review_received` to dispatch it.
- Tests for the new dispatch entries.

**Deferred (not in this plan):**
- `/address-review-feedback` (split CHANGES_REQUESTED handling) — Linktree rarely uses CHANGES_REQUESTED, so the generic `/address-review-comment` will handle reviews too.
- `/resolve-merge-conflict` for `mergeable_conflicting`.
- `/investigate-pr-close` for the close path.
- Operator-override skills (`/pause`, `/kill`, `/restart`, `/watch`).
- `WORKER_AUTO_PERMISSIONS` config knob (workers already run autonomously by default; that's fine).
- Force-kill of lingering worker panes (a polish item unrelated to dispatch).

The deferred items can be picked up incrementally once the dispatch substrate is confirmed working through this plan.

---

## File Structure

**Files to create:**
- `templates/.claude/commands/address-review-comment.md` — new skill content.

**Files to modify:**
- `bin/lib/watcher-events.sh` — change `new_comment_received` and `new_review_received` from `kind=log` to `kind=llm skill=/address-review-comment` in `watcher_dispatch_action`.
- `test/test-watcher-events.sh` — extend the dispatch test block with the two new mappings.

**Files left alone:**
- `bin/watcher.sh` — no changes; the dispatch loop already handles `kind=llm` correctly (it does so for `ci_failed` today).
- `bin/orchestrator.sh`, all of `bin/lib/state*.sh`, `bin/lib/queue.sh`, mux providers, render scripts.

---

## Task 1: Suppress pure-approval reviews in `watcher_diff_events`

Approval-only reviews shouldn't trigger the LLM-dispatched remediation skill — there's nothing to address. Filter them out at the watcher level (before dispatch) by checking whether the review-count delta exceeds the approved-count delta. Only the "extra" reviews are non-approvals and worth firing the event for.

**Files:**
- Modify: `bin/lib/watcher-events.sh`
- Modify: `test/test-watcher-events.sh`

- [ ] **Step 1: Add failing tests for the approval-suppression logic**

In `test/test-watcher-events.sh`, find the existing `watcher_diff_events` block. After the existing assertions but before the next section's `echo ""`, append:

```bash
# Synthesize state blobs to control approved/review counts directly.
state_no_reviews="state=OPEN
is_draft=false
mergeable=MERGEABLE
checks_conclusion=PENDING
review_count=0
comment_count=0
approved_count=0
changes_requested_count=0"

state_one_approval="state=OPEN
is_draft=false
mergeable=MERGEABLE
checks_conclusion=PENDING
review_count=1
comment_count=0
approved_count=1
changes_requested_count=0"

state_one_changes_requested="state=OPEN
is_draft=false
mergeable=MERGEABLE
checks_conclusion=PENDING
review_count=1
comment_count=0
approved_count=0
changes_requested_count=1"

state_one_approval_one_changes="state=OPEN
is_draft=false
mergeable=MERGEABLE
checks_conclusion=PENDING
review_count=2
comment_count=0
approved_count=1
changes_requested_count=1"

# Pure approval — should NOT emit new_review_received
events=$(watcher_diff_events "$state_no_reviews" "$state_one_approval")
assert_not_contains "pure approval suppressed" "new_review_received" "$events"

# Changes-requested review — SHOULD emit new_review_received
events=$(watcher_diff_events "$state_no_reviews" "$state_one_changes_requested")
assert_contains "changes_requested still emits" "new_review_received" "$events"

# Mixed batch (one approval + one changes-requested) — SHOULD emit
events=$(watcher_diff_events "$state_no_reviews" "$state_one_approval_one_changes")
assert_contains "mixed batch still emits" "new_review_received" "$events"
```

- [ ] **Step 2: Run the tests — they should fail**

Run: `./test/test-watcher-events.sh`

Expected: the "pure approval suppressed" assertion fails because the current code emits `new_review_received` whenever review_count grows, regardless of whether the new review was an approval.

- [ ] **Step 3: Update `watcher_diff_events` to apply the filter**

In `bin/lib/watcher-events.sh::watcher_diff_events`, find this block:

```bash
    # Review count grew.
    if [[ -n "$c_review" && -n "$p_review" ]] && (( c_review > p_review )); then
        echo "new_review_received"
    fi
```

Replace with:

```bash
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
```

- [ ] **Step 4: Run the tests — they should pass**

Run: `./test/test-watcher-events.sh`

Expected: all three new approval-suppression assertions pass. Existing `watcher_diff_events` assertions also still pass (the open-ci-failed fixture has 1 review with state APPROVED, increasing both counts by 1 — review_delta=1, approved_delta=1 — filter suppresses; this is fine because the approval landed alongside the CI failure which itself fires the skill).

If any pre-existing test case breaks because of the new filter, double-check the fixture: state transitions where the only review is an approval should now correctly suppress. The plan's existing assertion `assert_contains "new_review_received event emitted" "new_review_received" "$events"` (against state_draft → state_failed transition) used to pass because review_count grew; with this filter, review_count went 0→1 via APPROVED so new_review_received is suppressed. **Update that assertion to `assert_not_contains` to match the new (correct) behavior.**

To find and update it, look in the existing watcher_diff_events block and locate:

```bash
# Transition: pending → failed also adds a review
assert_contains "new_review_received event emitted" "new_review_received" "$events"
```

Replace with:

```bash
# Transition: pending → failed adds an APPROVED review, which is now
# suppressed (pure approvals don't need an LLM-dispatched skill).
assert_not_contains "approval-only review suppressed" "new_review_received" "$events"
```

- [ ] **Step 5: Run all tests for full confirmation**

Run: `make test`

Expected: all assertions green, including the modified one above.

- [ ] **Step 6: Commit**

```bash
git add bin/lib/watcher-events.sh test/test-watcher-events.sh
git commit -m "feat(watcher-events): suppress pure-approval reviews from dispatch

watcher_diff_events now compares the review-count delta against the
approved-count delta. If they're equal, the only new reviews are
pure approvals — there's nothing actionable to dispatch a skill for,
so the new_review_received event is suppressed. CHANGES_REQUESTED,
COMMENTED, and mixed batches continue to fire the event.

Trade-off: APPROVED reviews with non-empty bodies are also suppressed.
At Linktree that's acceptable since reviewers typically leave separate
comments rather than adding bodies to approvals. If it becomes a
problem, the filter can be softened later."
```

---

## Task 2: Wire the dispatch entries

`watcher_dispatch_action` currently returns `kind=log` for `new_comment_received` and `new_review_received`. Update both to dispatch `/address-review-comment`. The Task 1 filter ensures `new_review_received` only fires for actionable reviews.

**Files:**
- Modify: `bin/lib/watcher-events.sh`
- Modify: `test/test-watcher-events.sh`

- [ ] **Step 1: Add failing tests for the new dispatch entries**

In `test/test-watcher-events.sh`, find the existing `watcher_dispatch_action` block. After the existing assertions but before the next section's `echo ""`, append:

```bash
# new_comment_received → dispatch /address-review-comment
action=$(watcher_dispatch_action "new_comment_received")
assert_contains "comment: kind=llm" "kind=llm" "$action"
assert_contains "comment: skill=/address-review-comment" "skill=/address-review-comment" "$action"

# new_review_received → also dispatches /address-review-comment.
# (Pure-approval reviews are filtered upstream in watcher_diff_events,
# so by the time this event fires there's actionable content.)
action=$(watcher_dispatch_action "new_review_received")
assert_contains "review: kind=llm" "kind=llm" "$action"
assert_contains "review: skill=/address-review-comment" "skill=/address-review-comment" "$action"
```

- [ ] **Step 2: Run the tests — they should fail**

Run: `./test/test-watcher-events.sh`

Expected: the four new assertions fail because both events still return `kind=log`.

- [ ] **Step 3: Update `watcher_dispatch_action` in `bin/lib/watcher-events.sh`**

Find the existing function:

```bash
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

Replace with:

```bash
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
```

Changes from the original:
- New `new_comment_received|new_review_received)` branch routes both to `/address-review-comment`.
- Those event names are removed from the `kind=log` group at the bottom.
- All other branches unchanged. `mergeable_conflicting` still logs only (deferred).

- [ ] **Step 4: Run the tests — they should pass**

Run: `./test/test-watcher-events.sh`

Expected: all assertions pass, including the four new dispatch assertions.

- [ ] **Step 5: Run all test suites**

Run: `make test`

Expected: all assertions green.

- [ ] **Step 6: Commit**

```bash
git add bin/lib/watcher-events.sh test/test-watcher-events.sh
git commit -m "feat(watcher-events): dispatch comments and reviews to /address-review-comment

Both new_comment_received and new_review_received now map to the
new /address-review-comment skill (next commit). Pure-approval
reviews are already filtered upstream in watcher_diff_events
(previous commit), so by the time these events fire there's
actionable feedback to address.

Splitting CHANGES_REQUESTED into a dedicated skill remains
deferred — the unified comment skill handles all actionable
review feedback uniformly."
```

---

## Task 3: Create `/address-review-comment` skill

The skill prompt for the new remediation agent. Reads new comments / review feedback on the PR, decides which are actionable, makes one fix per actionable comment with focused commits, then exits.

**Files:**
- Create: `templates/.claude/commands/address-review-comment.md`

- [ ] **Step 1: Create the skill file with this exact content:**

```markdown
# /address-review-comment — Respond to new PR comments and reviews

You are a short-lived remediation agent dispatched by the PR watcher because new comments or a new review have appeared on the pull request since the last poll.

## Input

`$ARGUMENTS` — the PR URL (e.g. `https://github.com/owner/repo/pull/42`).

## Your Job

1. **List recent comments and reviews on the PR.**
   - `gh pr view <pr-url> --json comments,reviews` for general comments and review summaries.
   - `gh api repos/<owner>/<repo>/pulls/<number>/comments` for line-level review comments.
   - Read newest first; older comments may already have been addressed in earlier iterations of this skill.

2. **For each piece of feedback, decide whether it is actionable.**
   Actionable means: the commenter is requesting a code change, asking a question that needs a code change to answer, or pointing out a specific bug or issue to fix.
   Non-actionable means: praise ("LGTM", "looks good"), an approval review with no specific feedback, rhetorical questions, off-topic discussion, or feedback requiring architectural decisions outside the scope of this PR.
   When unsure, treat as non-actionable and skip — better to leave a comment unaddressed than to make speculative changes.

3. **Navigate to the worktree.**
   - The prompt prefix you received names the worktree path. `cd` there before any code changes.
   - Do NOT modify files anywhere else on disk.

4. **For actionable feedback, make the minimal fix.**
   - Address one piece of feedback at a time. Commit between fixes so each diff is focused and reviewable.
   - Use a conventional commit subject: `fix: <what you changed>` or `docs: <what you clarified>`. Do NOT include the commenter's name or comment ID in the subject.
   - Do NOT also fix unrelated issues you happen to notice.

5. **Reply to the comment via `gh api` only when needed for clarity.**
   - If your fix doesn't fully address the concern but is a reasonable partial step, leave a brief reply explaining what you changed and what's still open.
   - If you decided not to act on the comment, reply explaining why (one sentence).
   - Do NOT reply just to say "fixed" — let the diff speak.

6. **Push and exit.**
   - `git push` to the same branch.
   - `/exit`. The watcher's next poll iteration will see the new commit; if more comments arrive later, it will dispatch you again.

## Important Rules

- ONLY work in the worktree. Never modify files outside.
- NEVER mark the PR as ready or merge it.
- NEVER force-push.
- NEVER address ALL comments at once with one giant commit. One piece of feedback, one focused fix, one commit.
- If you cannot determine what the commenter wants, leave the comment alone and exit — do not guess.
- If a comment requests a change that would require modifying files outside the worktree (e.g., changes to a different repo, infrastructure changes), reply explaining you can't address it, then exit.
- If you receive an APPROVED review with no actionable feedback, simply exit. The approval itself doesn't require any action — the operator decides when to merge.
- Keep the session tight — one poll cycle, focused fixes, exit.
```

- [ ] **Step 2: Verify the file is readable**

Run: `head -5 templates/.claude/commands/address-review-comment.md`

Expected: the first heading and intro lines.

- [ ] **Step 3: Run all test suites (no regression — this is a new file, doesn't affect existing tests)**

Run: `make test`

Expected: all assertions still green.

- [ ] **Step 4: Commit**

```bash
git add templates/.claude/commands/address-review-comment.md
git commit -m "feat(skill): add /address-review-comment

Narrow remediation skill dispatched by the watcher when new
comments or reviews appear on a watched PR. Reads the feedback,
filters out non-actionable items (approvals, praise), makes
minimal one-comment-per-commit fixes, pushes, and exits. The
watcher detects the new commit on its next poll.

Treats CHANGES_REQUESTED reviews uniformly with comments for now;
splitting into a dedicated skill is deferred until experience
shows it's needed."
```

---

## Self-Review Checklist (run after all three tasks)

- [ ] `make test` passes — `test-watcher-events.sh` includes the new approval-suppression and dispatch assertions, all green.
- [ ] `bash -n bin/lib/watcher-events.sh && echo OK` reports OK.
- [ ] `templates/.claude/commands/address-review-comment.md` exists and is readable.
- [ ] `grep 'kind=log' bin/lib/watcher-events.sh` shows ONLY `first_poll`, `ci_passed`, `mergeable_conflicting`, and the unknown-event default — comment/review events no longer appear in that branch.
- [ ] Manual probe: synthesize a state blob with review_count=1 / approved_count=1 (pure approval), pass through `watcher_diff_events`, confirm output does NOT contain `new_review_received`.
- [ ] No `TBD`, `TODO`, or placeholder strings in any new or modified file.

---

## What's deferred for future plans

Once this plan ships and the comment-dispatch flow is confirmed working live, the natural follow-ups (in rough priority order):

1. `/resolve-merge-conflict` — wire `mergeable_conflicting`, write the rebase-and-resolve skill. Common case at scale.
2. `/investigate-pr-close` — replace the current direct mark_blocked on PR close with a diagnostic skill. Adds the watcher's safety-exit-on-task-left-waiting check at the same time (since the skill mutates state itself rather than firing a terminal event).
3. `/address-review-feedback` — only if `/address-review-comment` proves inadequate for CHANGES_REQUESTED reviews. Worth waiting to see whether the unified handling is good enough.
4. Operator-override skills (`/pause`, `/kill`, `/restart`, `/watch`) — useful once you're running enough concurrent tasks that manual intervention is needed.
5. Worker-pane force-kill on transition — small polish to handle Claude Code's `/exit` not terminating its process.
6. `WORKER_AUTO_PERMISSIONS` config knob — only if a user actually wants to disable the autonomy default.
