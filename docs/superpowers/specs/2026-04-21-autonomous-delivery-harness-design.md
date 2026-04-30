# Autonomous Delivery Harness — Design

**Date:** 2026-04-21
**Status:** Draft, pending implementation plan
**Base:** Fork/enhancement of [Craft](../../../) with net-new watcher/UX capabilities

## Context & Motivation

Craft today orchestrates coding tasks by scaffolding markdown task files, spawning agents in tmux/cmux panes, and letting those agents polls their own PRs until merge. It works, but it has three limitations for our use case:

1. **Workers do too much.** A single `/work-task` session implements the feature, creates the PR, self-reviews, *and* stays alive polling for CI failures and review comments. Keeping an agent session alive for hours of polling is expensive and fragile.
2. **The state layer is file-based.** For users whose team already runs on Linear, maintaining a parallel markdown-based state (`queue/`, `docs/plan.md`, `docs/milestones/`) creates drift and duplicates work.
3. **The UX is plain.** The orchestrator dashboard is functional ANSI text. For a product that runs 24/7 and coordinates multiple agents across many PRs, the surface should feel first-party.

This design addresses those three things while preserving what Craft does well: its deterministic, file-inspectable orchestration model; the agent-provider abstraction; the plugin hook system; the cmux/tmux integration; the worktree-per-task isolation.

The design is heavily informed by [Gas Town](https://github.com/steveyegge/gastown) — specifically its separation of work-doing agents from health-monitoring processes (Witnesses), and its "escalate when stuck, don't guess" discipline. It deliberately does *not* adopt Gas Town's structure wholesale (Go rewrite, Mayor/Polecat vocabulary, Beads as a dependency) because that surface area exceeds what's needed.

## Goals

1. **Separate the worker from the watcher.** Workers do the code work and exit. Watchers are long-lived, deterministic processes that poll PRs and dispatch remediation agents only when something actionable happens.
2. **Support Linear as a native state backend, alongside the existing local file backend.** Refactor Craft's state layer behind a pluggable interface so upstream users keep the local option and we get Linear without forking.
3. **Invest in first-party UX.** Ink-based UIs for the orchestrator dashboard and per-watcher panes. Glanceable, reactive, professional-feeling.
4. **Preserve upstream-contributability.** All non-Linear-specific improvements should be mergeable back into the main Craft repo.

## Non-Goals

- Multi-tracker abstraction (Jira, GitHub Issues, ADO). Linear only. YAGNI.
- Persistent cross-session architect memory. The architect starts fresh each launch. If gaps emerge, we add this later.
- Rewriting Craft in Go. Bash + Node (for Ink) only.
- Replacing the architect's conversational interface. Claude Code with Linear MCP is the UX; we add no wrapper around it.
- A generic watchdog/supervision tier à la Gas Town's Deacon. The orchestrator loop + per-PR watchers cover our scale.

## High-Level Architecture

```
┌────────────────────────────────────────────────────────────────────────┐
│  cmux workspace                                                        │
│                                                                        │
│  ┌─────────────────┐  ┌──────────────────┐                             │
│  │   Architect     │  │   Orchestrator   │                             │
│  │  (Claude Code   │  │  (bash daemon,   │                             │
│  │   + Linear MCP) │  │   Ink dashboard) │                             │
│  └─────────────────┘  └──────────────────┘                             │
│                                                                        │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐                  │
│  │  Worker      │  │  Worker      │  │  Watcher     │                  │
│  │  (task-042)  │  │  (task-043)  │  │  (PR #1234)  │                  │
│  │  short-lived │  │  short-lived │  │  long-lived  │                  │
│  │  agent       │  │  agent       │  │  Ink process │                  │
│  └──────────────┘  └──────────────┘  └──────────────┘                  │
│                                        │                               │
│                                        │ dispatches when events fire   │
│                                        ↓                               │
│                                   ┌──────────────┐                     │
│                                   │  Fix agent   │                     │
│                                   │ /fix-ci-...  │                     │
│                                   │ short-lived  │                     │
│                                   └──────────────┘                     │
└────────────────────────────────────────────────────────────────────────┘
                │                       │                          │
                │                       │                          │
           Linear MCP              gh CLI + direct             Buildkite MCP
          (architect)              Linear GraphQL              (fix agents)
                                   (orchestrator/
                                    watchers)
```

Four process types share the workspace:

- **Architect** — interactive Claude Code session. User-facing. Plans work, creates Linear issues via MCP, dispatches tasks, answers questions. One per workspace.
- **Orchestrator** — bash daemon with an Ink UI. Polls the state backend, spawns workers/watchers, dispatches plugin hooks, renders the dashboard. One per workspace.
- **Worker** — short-lived agent session. Picks up a ready task, sets up worktree, implements, QAs, creates draft PR, exits. One per active task.
- **Watcher** — long-lived Node/Ink process. Attached to a PR after worker exit. Polls PR state via `gh`, renders per-PR UI, dispatches remediation agents on events, exits on PR merge/close. One per active PR.
- **Remediation agents** (transient) — short-lived agent sessions dispatched by a watcher. Run narrow skills like `/fix-ci-failure`. Exit immediately after completing their specific job.

## State Backend Abstraction

This is the core refactor. Craft's `bin/lib/queue.sh` already functions as an implicit interface — orchestrator, skills, and plugins all call functions like `next_ready_task`, `move_task`, `task_deps_met`. We make that interface explicit and provide two implementations.

### Interface (`bin/lib/state.sh`)

Dispatches to a backend module based on `STATE_BACKEND` config (`local` or `linear`).

Core operations every backend must implement:

| Function | Semantics |
|---|---|
| `list_ready_tasks` | Tasks in the "approved/go" state, with dependencies met |
| `list_active_tasks` | Tasks currently being worked (in-progress) |
| `list_waiting_tasks` | Tasks with PRs, awaiting outcome |
| `get_task <id>` | Return task metadata (title, description, parent, deps, branch, repos, qa, pr_url) |
| `claim_task <id>` | Atomically move task to in-progress, record timestamp, return task data |
| `mark_waiting <id> <pr_url>` | Record PR creation, move to waiting state |
| `mark_done <id>` | PR merged, task complete |
| `mark_blocked <id> <reason>` | Task blocked, human attention required |
| `create_subtask <parent_id> <title> <description> [meta]` | Create a child task linked to the parent |
| `append_note <id> <text>` | Audit trail entry (markdown section in local, Linear comment in linear) |

### Local backend (`bin/lib/state-local.sh`)

Essentially today's `queue.sh` with light renames to match the interface. Markdown files in `queue/{pending,approved,in-progress,waiting,done,blocked}/`. Keeps Craft's current behavior for upstream users.

### Linear backend (`bin/lib/state-linear.sh`)

~80 lines of bash + curl calling Linear's GraphQL API. Operations map as:

| Interface | Linear |
|---|---|
| `list_ready_tasks` | `issues` query filtered by team, state/label meaning "ready" |
| `claim_task` | `issueUpdate` transitioning to the "in-progress" state |
| `mark_waiting` | `issueUpdate` state transition + comment with PR URL |
| `mark_done` | `issueUpdate` to "done" state |
| `mark_blocked` | `issueUpdate` to "blocked" state + `commentCreate` with reason |
| `create_subtask` | `issueCreate` with `parentId` |
| `append_note` | `commentCreate` |

A minimal local JSON cache (`.state/cache.json`) records ticket IDs and status since last poll, so the orchestrator doesn't re-fetch the full team issue list every 15s. Each poll does an incremental query using `updatedAt > lastPollTime`.

### Configuration

```
# craft.conf additions
STATE_BACKEND=linear     # or "local" (default)

# Linear-specific (only when STATE_BACKEND=linear)
LINEAR_API_KEY=          # or $LINEAR_API_KEY env
LINEAR_TEAM_ID=
LINEAR_PROJECT_ID=       # scope issue fetches to a specific project
LINEAR_READY_STATE=      # state name meaning "ready to run"
LINEAR_IN_PROGRESS_STATE=
LINEAR_WAITING_STATE=
LINEAR_DONE_STATE=
LINEAR_BLOCKED_STATE=
```

### What retires

The existing `templates/plugins/linear-sync/` plugin goes away. Its entire purpose was to project Linear into the local markdown backend. Once Linear is a native backend, the projection is redundant.

## Component Details

### Architect

Unchanged in principle, lighter in content. Runs as a Claude Code session in its own cmux pane, launched via a thin `/init-architect` skill that says "read current Linear state, summarize, wait for instructions."

**Tools available in the architect session:**
- Linear MCP — full issue/comment/document/project access
- `gh` CLI (via Bash)
- Standard Claude Code tools (Read, Edit, Write, Grep, Glob, Task)

**Tools the architect does NOT need bespoke skills for:**
- Creating tickets (Linear MCP's `save_issue` handles this natively; we just prompt the architect to use it during planning)
- Listing/filtering tickets (Linear MCP)
- Adding comments, relations, labels (Linear MCP)

**Bespoke architect skills (minimal set):**
- `/init-architect` — loads context on startup
- `/plan` — guided planning flow (the new replacement for `/generate-milestone` and `/split-milestone`, streamlined because Linear handles the data model). Creates tickets via MCP during conversation.
- `/pause <task-id>` — orchestrator intervention
- `/kill <task-id>` — orchestrator intervention with task-blocked state
- `/restart <task-id>` — respawn from current state
- `/watch <pr-url>` — manually attach a watcher to a PR (rare)

### Orchestrator

Today's `bin/orchestrator.sh`, modified:

- **Reads via `state.sh`** instead of direct `queue/` access.
- **Picks up ready tasks**, spawns worker panes (same as today).
- **Detects worker exit with a PR created** → spawns a watcher pane for that PR.
- **Renders an Ink dashboard** (new, replaces the ANSI `render_dashboard`).
- **Runs plugin hooks** on the existing events (`on_started`, `on_waiting`, `on_done`, `on_blocked`, `on_milestone`, `on_poll`) plus new ones (`on_ci_failed`, `on_review_received`, `on_remediation_dispatched`).

### Worker Lifecycle

Dramatically simpler than today's `/work-task`. New `/work-task` skill:

1. Claim the task via `claim_task` (orchestrator pre-moves, so skip if already in-progress).
2. Read task data + Linear parent/siblings context (via MCP).
3. Create worktree.
4. Implement the changes.
5. Run the QA steps from the task metadata.
6. Commit with conventional message; push; `gh pr create --draft`.
7. Self-review (read the diff, fix obvious issues, re-push if needed).
8. Call `mark_waiting(task_id, pr_url)` — task moves to waiting state.
9. **Exit.**

No polling loop. No PR monitoring. No review handling. That's the watcher's job.

### Watcher Process Model

New. One Node/Ink process per active PR, spawned by the orchestrator when it detects a worker has created a PR.

**Responsibilities:**
- Poll `gh pr view --json state,isDraft,reviews,comments,mergedAt,statusCheckRollup,title,mergeable` on a configurable interval (default 30s).
- Detect events by diffing against last-seen state.
- Render Ink UI showing: header (PR title + state), CI/CD check matrix (including Buildkite via GitHub Checks), reviews pane, recent-actions log, pending-remediations queue, next-poll countdown.
- On event detection, enqueue a remediation. Process queue FIFO, serially per PR.
- Dispatch remediation agents by spawning a fresh cmux pane with a narrow skill invocation.
- Exit when PR merges or closes (after dispatching `/investigate-pr-close` for the close case).

**State persistence:** watchers write their internal state to `.state/watchers/<pr-number>.json` on every poll so they can resume if restarted or crashed.

### Watcher Event Taxonomy

| Event | Detection | Response |
|---|---|---|
| No change | Default | Poll again |
| CI passed | `gh pr checks` | Log, continue |
| **CI failed** | `gh pr checks` failure state | **Dispatch `/fix-ci-failure`** |
| **New line/review comment** | Diff against last seen | **Dispatch `/address-review-comment`** |
| **Review: CHANGES_REQUESTED** | `reviews` query | **Dispatch `/address-review-feedback`** |
| **Review: APPROVED** | `reviews` query | Log, fire `on_review_received` hook, continue |
| **Draft → Ready flip** | `isDraft` changed | Fire `on_ready` hook (Slack DM), continue |
| **Mergeable = CONFLICTING** | `mergeable` field | **Dispatch `/resolve-merge-conflict`** |
| **PR merged** | `state = MERGED` | `mark_done`, exit watcher |
| **PR closed (not merged)** | `state = CLOSED` | Dispatch `/investigate-pr-close`, then `mark_blocked`, exit |
| **Remediation agent crashed** | Fix pane exited without expected state change | `mark_blocked` with reason, fire `on_blocked` hook |

Remediations are processed **serially per PR, parallel across PRs**. If CI fails and a review comment lands in the same poll cycle, both are queued; the second starts only after the first finishes. The watcher UI shows the queue so the user can see what's pending.

### Remediation Skills

New, narrow, short skill files (~50 lines each) under `templates/.claude/commands/`:

- `/fix-ci-failure <pr-url> <failed-check-name>` — reads the failed check, investigates via Buildkite MCP (for log detail), makes the fix, commits, pushes.
- `/address-review-comment <pr-url> <comment-id>` — reads the specific comment, addresses it, commits, pushes.
- `/address-review-feedback <pr-url> <review-id>` — broader review with CHANGES_REQUESTED, addresses all comments in that review.
- `/resolve-merge-conflict <pr-url>` — rebases on main, resolves conflicts, pushes.
- `/investigate-pr-close <pr-url>` — determines why PR was closed, posts a summary to the Linear issue.
- `/create-subtask <parent-id> <title> <description>` — worker-triggered sub-issue creation.

All run in the original task's worktree (`worktrees/<repo>-<task-id>/`). All have Linear + Buildkite MCPs configured.

### Linear GraphQL Shim (`bin/lib/linear.sh`)

Only the daemon side needs this; agent sessions use Linear MCP. The shim is ~80 lines of bash + curl + jq. Operations:

- `linear_list_ready_issues`
- `linear_get_issue <id>`
- `linear_update_status <id> <state-name>`
- `linear_post_comment <id> <body>`
- `linear_create_subissue <parent-id> <title> <description>` (used only in rare cases where the orchestrator itself needs to create an issue — worker-side sub-issues go via MCP)

Retries: exponential backoff on HTTP 429/5xx, 3 attempts. No retries on 4xx auth errors (surface immediately).

### Ink UIs

Two Ink apps, each ~200–400 lines of TypeScript:

**`ui/dashboard/`** — the orchestrator dashboard:
- Header: project name, backend (local/linear), active agent count
- Left: queue counts (pending/approved/in-progress/waiting/done/blocked) with reactive updates
- Middle: active workers + watchers, grouped by task
- Right: recent events stream (last N lifecycle events)
- Footer: keyboard shortcuts (`q` quit, `r` refresh, `p` pause all)

**`ui/watcher/`** — the per-PR watcher UI:
- Header: PR number, title, state badge (draft/ready/merged/closed), mergeable status
- CI/CD matrix: table of check runs, per-check duration, status icons
- Reviews: list of reviewers, their state, comment counts, unread markers
- Recent actions: chronological log of detections and dispatches
- Pending remediations: FIFO queue of dispatches waiting to run
- Footer: next poll countdown, last update timestamp

Both use `ink`, `ink-table`, `ink-spinner`. Node.js runtime dependency added to `craft doctor`.

### Buildkite Integration

**Watcher side:** no native Buildkite code. Relies on Buildkite's GitHub Checks integration — failing Buildkite jobs show up in `gh pr checks`.

**Fix agent side:** when `/fix-ci-failure` is dispatched for a Buildkite check, the agent uses Buildkite MCP (configured in its environment) to fetch job logs, annotations, and build metadata. No bespoke helper script.

If an org doesn't use the Buildkite → GitHub Checks integration, this falls back — we'd need a small Buildkite polling plugin, but that's out of scope for v1.

### Slack

Existing plugins (`slack-dm-notify`, `slack-daily-thread`) carry forward unchanged. They hook on `on_waiting`, `on_blocked`, `on_done`, etc. New hooks (`on_ci_failed`, `on_review_received`, `on_remediation_dispatched`) are available but the existing plugins don't subscribe to them by default.

## End-to-End Task Lifecycle

The full flow from planning to merge:

```
1. Architect (user + Claude Code + Linear MCP)
     → creates Linear issue (state: ready) via MCP

2. Orchestrator (next poll tick)
     → state.sh list_ready_tasks → returns the new issue
     → calls state.sh claim_task (transitions Linear to in-progress)
     → spawns worker pane

3. Worker (short-lived agent)
     → reads task via MCP
     → worktree, implement, QA, draft PR
     → state.sh mark_waiting(id, pr_url) (Linear status + PR comment)
     → exits

4. Orchestrator (detects worker exit, PR URL in task state)
     → spawns watcher pane for PR

5. Watcher (long-lived Ink process)
     → polls PR state
     → renders UI
     → on CI fail: dispatch /fix-ci-failure pane (fix agent uses Buildkite MCP)
     → on review comment: dispatch /address-review-comment pane
     → on merge: state.sh mark_done, exit

6. Orchestrator (detects watcher exit with done state)
     → fires on_done hooks (Slack, etc.)
```

Sub-issue creation (path c):

```
Worker mid-run realizes decomposition is needed
  → calls state.sh create_subtask(parent_id, title, description)
    → Linear: create issue with parentId, label "ready-for-claude"
  → continues its own work (or blocks if the sub-task is a prerequisite)

Orchestrator (next poll tick)
  → picks up the new sub-task
  → spawns a worker for it
```

## Intervention Model

Primary interventions go through Linear (edit the issue, change state, add comments — the loop sees it on the next poll).

Runtime-only interventions (things Linear can't express) via architect skills:

- `/pause <task-id>` — stop the worker/watcher pane, leave Linear state unchanged
- `/kill <task-id>` — terminate and transition Linear to blocked with reason
- `/restart <task-id>` — respawn from current Linear state
- `/watch <pr-url>` — manually attach a watcher (rare, for debugging)

Closing a cmux pane manually is the nuclear option: orchestrator detects pane exit, cleans up tracking, doesn't touch Linear state. User's responsibility if they do this.

## What Gets Retired (in our fork)

- `queue/` as the primary state (still available via `STATE_BACKEND=local`)
- `docs/plan.md`, `docs/milestones/`, `docs/adrs/`, `state.md` — Linear Documents cover this
- The existing `linear-sync` plugin — replaced by the native `linear` backend
- The ANSI-text dashboard — replaced by Ink
- The in-worker PR polling loop (Step 9 of current `work-task`) — replaced by the watcher
- `/generate-milestone` and `/split-milestone` as elaborate skills — replaced by a lighter `/plan` skill that nudges the architect into using Linear MCP

## What Ships Upstream (contributable to main Craft)

- The state backend abstraction (refactor of `queue.sh` → `state.sh` + backends)
- The watcher process model (applicable to any state backend)
- The worker/watcher split (splits current `/work-task`)
- The Ink dashboard and watcher UIs
- The narrow remediation skills (`/fix-ci-failure`, etc.)
- New lifecycle hooks (`on_ci_failed`, `on_review_received`, `on_remediation_dispatched`)

What stays in our fork (or ships as an opt-in plugin):
- The Linear state backend (`state-linear.sh`)
- The Linear GraphQL shim
- Buildkite-MCP-aware remediation skill configuration
- Any Linktree-specific assumptions in the architect's `/plan` skill

## Open Questions / Deliberate Non-Decisions

1. **Which Ink libraries exactly.** Confirmed directions: `ink` for rendering, `ink-table`, `ink-spinner`. Specific structure decisions defer to implementation.
2. **Remediation agent timeouts.** Default: inherit from `AGENT_TIMEOUT`. Per-skill overrides possible in skill frontmatter. To be finalized in the plan.
3. **Whether `/plan` creates Linear issues directly or proposes them for user approval first.** Leaning: proposes a batch, user says "yes" in chat, architect calls `save_issue` for each. Confirms user intent without friction.
4. **Watcher UI key bindings.** To be designed during implementation. Minimum: `q` close (kills watcher), `r` force refresh, `?` help.
5. **Observability.** Structured logs to `logs/` by process type. No OpenTelemetry initially (Gas Town has it; we don't need it at our scale). Revisit if operational visibility becomes a problem.

## Effort Estimate

Rough sizing, in ordinal difficulty (not days):

| Piece | Size | Notes |
|---|---|---|
| State backend refactor (local → abstract + local + linear) | M | Straightforward — queue.sh is already the boundary |
| Linear GraphQL shim | S | ~80 lines bash/curl/jq |
| Worker/watcher split (refactor of work-task skill) | S | Mostly a content rewrite |
| Remediation skills (5–6 new short skills) | S | Each ~50 lines |
| Ink orchestrator dashboard | M | ~400 lines TS, new component work |
| Ink watcher UI | M | ~400 lines TS, event-driven state management |
| Orchestrator changes (spawn watchers, new hooks) | S | Small additions to existing daemon |
| Architect `/plan` skill | S | Light skill file |
| Intervention skills (`/pause`, `/kill`, etc.) | S | Thin wrappers over state.sh + pane management |
| Doctor updates (Node.js, ink check) | XS | Dependency additions |

Rough total: **several M-sized pieces, plenty of S-sized pieces**. Most of the work is the Ink UI layer and the state backend refactor; everything else is content work.

## Acceptance Criteria

This design is considered implemented when:

1. A fresh workspace can be initialized with `STATE_BACKEND=linear` pointed at a Linear team/project.
2. Creating a Linear issue in the ready state causes the orchestrator to pick it up, spawn a worker, and transition the issue through Linear states correctly.
3. When the worker creates a PR, a watcher pane opens in cmux showing the Ink UI.
4. When CI fails on a watched PR, the watcher detects it within one poll cycle and dispatches a fix agent in a new pane; the fix agent pushes a fix; the watcher resumes normal polling.
5. When a review comment lands, the watcher detects it and dispatches a remediation agent similarly.
6. If both CI fails and a review comment arrive in one poll cycle, the remediations queue and execute serially (visible in the watcher UI).
7. When the PR merges, the watcher closes its pane, the Linear issue transitions to done, and the Slack hooks fire.
8. Worker can call `create_subtask` mid-run and the new Linear issue is picked up on the next orchestrator poll.
9. `STATE_BACKEND=local` still works for upstream users — all the new watcher/UX work functions identically against the markdown file backend.
10. `craft doctor` reports correctly on Node.js + Ink dependencies when the Ink UIs are enabled.
