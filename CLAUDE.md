# Craft — Project Orchestration System

This repo contains the craft workflow system for orchestrating project work through Claude Code.

> **Branch context:** `mo/autonomous-delivery-harness` is a substantial enhancement to upstream Craft — see [draft PR](https://github.com/stlasalle/craft/pull/5). The architecture described below reflects the post-merge state. The full design rationale and plan-by-plan execution history live in `docs/superpowers/specs/` and `docs/superpowers/plans/`.

## Repo Structure

- `bin/` — Orchestrator and helper scripts (shell)
- `bin/lib/` — Shared shell library functions
- `templates/` — Project template (copied when initializing a new project)
  - `templates/.claude/commands/` — Claude Code skills (slash commands)
  - `templates/docs/` — Documentation templates
  - `templates/queue/` — Queue directory structure
- `projects/` — Active project instances (each is a copy of templates/ + customization)
- `shared/` — Cross-project resources (prompt patterns, lessons learned)
- `test/` — Bash test suites; `make test` runs them all
- `docs/superpowers/specs/` — design documents
- `docs/superpowers/plans/` — implementation plans (one per subsystem)

## Key Concepts

- **The project folder is the state machine.** Files on disk represent state. Claude reads state, does work, writes new state. The operator reviews state transitions.
- **Queue-based workflow.** Tasks flow through: `pending/` → `approved/` → `in-progress/` → `waiting/` → `done/` → archived by consolidation. Failures route to `blocked/`.
- **Tasks are markdown files with YAML frontmatter.** The frontmatter defines metadata (type, milestone, status, QA requirements, `pr:` URL once created). The body defines the work.
- **Skills are Claude Code slash commands** in `.claude/commands/`. They read project state, do work, and write results back.
- **Two-gate operator model.** The operator reviews at task approval (pending → approved) and PR merge. Everything in between is autonomous.

## Architecture: Worker / Watcher Split

The orchestrator manages four process types:

```
[ Architect ]      User-facing Claude Code session, plans work
[ Orchestrator ]   Persistent bash daemon, polls the queue, spawns workers/watchers
[ Worker ]         Short-lived agent: implements task → opens draft PR → exits
[ Watcher ]        Long-lived bash process per PR: polls gh, dispatches remediations
[ Remediation ]    Transient agent: handles one event (CI fail, review comment, etc.)
```

**Worker lifecycle:** orchestrator claims a ready task via `state_claim_task`, spawns a Claude Code session running `/work-task`. The worker creates the worktree, implements, runs QA, opens a draft PR, calls `state_mark_waiting`, and **exits**. It does not poll the PR.

**Watcher lifecycle:** orchestrator detects the task is in `waiting/` with a `pr:` field and spawns `bin/watcher.sh` in its own multiplexer pane. The watcher polls `gh pr view` on an interval, diffs state between iterations, and dispatches actions per event:

| Event | Action |
|---|---|
| `ci_failed` | Spawn `/fix-ci-failure` in a detached pane |
| `merged` | `state_mark_done`, exit |
| `closed` | `state_mark_blocked`, exit |
| `draft_to_ready` | Fire `on_ready` plugin hook |
| `new_comment_received` | Spawn `/address-review-comment` |
| `new_review_received` *(non-approval only)* | Spawn `/address-review-comment` |
| `new_review_approved` | Log only — operator merges manually |
| Other events | Log only (deferred) |

Pure-approval reviews are filtered upstream in `watcher_diff_events` so they don't trigger an LLM dispatch for nothing.

**Remediation lifecycle:** when the watcher dispatches an LLM event, it spawns the agent in a *detached* multiplexer pane (doesn't steal focus) and waits for any of:
- The pane exits cleanly
- The PR head SHA changes (agent pushed a fix)
- A 5-minute timeout

The watcher then force-kills the pane unconditionally (handles Claude Code's `/exit` not always terminating its process). Serial-per-PR: only one remediation in flight per PR at a time.

## State Backend

`bin/lib/state.sh` is a backend dispatcher. `STATE_BACKEND=local` (default) sources `state-local.sh` which wraps the file-based `queue.sh` helpers and adds high-level operations:

- `state_claim_task <queue_dir> <task_id>` — approved → in-progress
- `state_mark_waiting <queue_dir> <task_id> <pr_url>` — in-progress → waiting + record PR URL
- `state_mark_done <queue_dir> <task_id>`
- `state_mark_blocked <queue_dir> <task_id> <reason>`
- `state_append_note <queue_dir> <task_id> <text>` — append to work log
- `state_create_subtask <queue_dir> <parent_id> <title> <description>`
- `state_find_task_by_id <queue_dir> <task_id>` — search across queue subdirs
- `state_list_ready_tasks <queue_dir>`, `state_list_tasks <dir>`, `state_count_tasks <dir>`
- `state_task_*` accessor aliases (re-exports of `task_*` from queue.sh)

A future `state-linear.sh` backend could implement the same interface against Linear's GraphQL API without touching the orchestrator or skills.

The orchestrator and `bin/craft` source `state.sh` rather than `queue.sh` directly. Worker skills (which run in agent sessions) source state.sh too — the orchestrator exports `CRAFT_ROOT` and `QUEUE_DIR` into the worker's prompt prefix so it knows where to look.

## Watcher Events Library

`bin/lib/watcher-events.sh` is a pure (side-effect-free) library used by `bin/watcher.sh`. Three functions:

- `watcher_extract_state <json>` — parses `gh pr view --json` output into a flat key=value blob. Keys: `state`, `is_draft`, `mergeable`, `checks_conclusion`, `review_count`, `comment_count`, `approved_count`, `changes_requested_count`.
- `watcher_diff_events <prev_blob> <curr_blob>` — emits event names representing changes (one per line). Filters pure-approval reviews via `review_delta vs approved_delta` comparison.
- `watcher_dispatch_action <event_name>` — maps event → action blob with `kind=` (one of `log`, `hook`, `llm`, `terminal`) plus parameters (`skill=`, `transition=`, `hook_name=`, etc.).

Tested with JSON fixtures under `test/fixtures/pr-state/`.

## UI Surfaces

- **Orchestrator dashboard** — re-rendered each poll via `bin/render-dashboard.sh`. Shows queue counts, active workers + watchers (per-watcher freshness color-coded green/yellow/red, CI status badge, PR title), recent activity feed (tail of orchestrator log).
- **Watcher pane** — per-PR window split horizontally: top half is `bin/render-watcher-status.sh` re-rendering every 5s (PR header, CI matrix, reviews, last action); bottom half is the watcher's polling log.
- **Remediation pane** — transient. Spawned on event dispatch, named `rem-pr-N-skill-name`, exits/torn down when the agent completes or the SHA changes.

Pure bash + ANSI; no Node.js dependency. Multiplexer-agnostic via `bin/lib/mux-tmux.sh` and `bin/lib/mux-cmux.sh` behind a shared interface (`spawn_task_pane`, `spawn_task_pane_detached`, `spawn_watcher_pane`, `pane_is_running`, `kill_task_pane`).

## Skills

Skills live in `templates/.claude/commands/` (copied to `<project>/.claude/commands/` on `craft init`).

**Worker skills:**
- `/work-task` — main worker. Reads context, sets up worktree, implements, QAs, opens draft PR, calls `state_mark_waiting`, exits. **Does NOT poll the PR.**
- `/init-architect` — loads project context for the architect window.
- `/generate-milestone`, `/split-milestone`, `/consolidate`, `/qa-task`, `/audit` — planning + lifecycle skills (interactive, run from architect).

**Remediation skills (dispatched by the watcher):**
- `/fix-ci-failure` — investigates a failing CI check via `gh pr checks` / `gh run view` / Buildkite-posted check details, fixes, commits, pushes.
- `/address-review-comment` — handles new comments and non-approval reviews. Decides actionability per comment, makes one-fix-per-commit changes, replies via `gh api` only when needed for clarity.

**Deferred but designed** (see `docs/superpowers/plans/2026-04-29-event-coverage-and-intervention.md`'s "What's deferred"):
`/resolve-merge-conflict`, `/investigate-pr-close`, plus operator-override skills `/pause`, `/kill`, `/restart`, `/watch`.

## Agent Providers

The system is model-agnostic. Any CLI agent that accepts a prompt as its first argument can be used.

- **Project default** — set in `craft.conf` (`DEFAULT_AGENT=claude`, `ARCHITECT_AGENT=claude`)
- **Task override** — set `agent:` in task YAML frontmatter (e.g. `agent: codex`)
- **CLI override** — `craft <project> --agent codex` (one-off)
- **Persistent config** — `craft config <project> agent codex`

Provider launch logic lives in `bin/lib/providers.sh`. Workers and remediation agents currently run with `--dangerously-skip-permissions` so they don't prompt per tool call. The architect does NOT — it's the interactive surface and prompts normally.

## Conventions

- Shell scripts use bash, are POSIX-friendly where practical
- All paths in scripts are relative to the project root or use `$PROJECT_DIR`
- Task IDs are sequential within a project: `task-001`, `task-002`, etc.
- Milestone IDs use short prefixes: `m1-`, `m2-`, etc.
- macOS bash 3.2 compatibility: avoid `${var,,}` (use `tr` instead). `BASH_SOURCE[0]` is unreliable under zsh — prefer `$CRAFT_ROOT` for path resolution when possible.
- `set -uo pipefail` on all top-level scripts; not `-e` (we want to continue past tolerable failures).

## Tests

Run all suites: `make test`. Four bash test files under `test/`:

- `test-queue.sh` — low-level `queue.sh` accessors (34 assertions)
- `test-state.sh` — state backend interface (58 assertions)
- `test-watcher-events.sh` — watcher event detection + dispatch (40 assertions)
- `test-render-watcher-status.sh` — watcher status renderer with JSON fixtures (17 assertions)

Pattern: each suite uses a tempdir for fixtures (mktemp + trap cleanup), a `pass`/`fail`/`assert_eq`/`assert_contains`/`assert_not_contains` harness, and prints a `N tests: X passed, Y failed` summary.

## Plugins

Lifecycle hook system in `templates/plugins/`. Each plugin has `plugin.conf` + `hooks.sh`. `run-hook.sh` dispatches to enabled plugins (subshells for isolation).

Available hooks: `on_poll`, `on_started`, `on_waiting`, `on_ready`, `on_done`, `on_blocked`, `on_milestone`. Slack DM + Slack daily thread plugins ship in-tree. The legacy `linear-sync` plugin remains but is being superseded by the state-backend approach (a future `state-linear.sh` would be the proper integration point).

## Working on This Repo

When modifying skills (templates/.claude/commands/), think about:
1. What state does this skill read?
2. What state does this skill write?
3. What are the failure modes and how should they surface to the operator?

When extending watcher events:
1. Add the event detection logic to `watcher_diff_events` in `bin/lib/watcher-events.sh` (with tests).
2. Add the event-to-action mapping to `watcher_dispatch_action`.
3. If `kind=llm`, write a skill file under `templates/.claude/commands/`.
4. If the action mutates task state without firing a terminal event, ensure `bin/watcher.sh`'s safety-exit-on-task-left-waiting catches the loop teardown.

When extending state operations:
1. Add the new operation to `bin/lib/state-local.sh` (with tests in `test-state.sh`).
2. Document the signature in this file's State Backend section.
3. Future `state-linear.sh` should implement the same operation against Linear.

Known limitations / deferred follow-ups (see PR body for the full list): comment-ID-based idempotency tracking, skill template propagation to existing projects, additional remediation/intervention skills, and a `WORKER_AUTO_PERMISSIONS` config knob.
