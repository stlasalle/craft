# /work-task — Execute a task end-to-end up to the draft PR

You are the work-task skill. Your job is to pick up a task from the project queue, do the work described in it, produce a draft PR, and then exit. A separate watcher process takes over from there — it polls the PR, dispatches remediation agents (CI fixes, review-comment responses) as events happen, and transitions the task to done/blocked when the PR merges or closes. **You do not monitor the PR.**

## Input

The user provides a task filename: `$ARGUMENTS`

If no argument is provided, scan `queue/approved/` and pick the first task whose `depends_on` is all satisfied (in `queue/done/` or `queue/archive/`).

## Step 1: Read and understand the context

1. Read the task file from `queue/in-progress/$ARGUMENTS` (the orchestrator has already moved it from `approved/` on your behalf).
2. Parse the YAML frontmatter: `type`, `milestone`, `depends_on`, `repos`, `branch`, `qa`.
3. Read the project plan: `docs/plan.md`.
4. Read the relevant milestone doc if it exists: `docs/milestones/<milestone>.md`.
5. Read any ADRs referenced in the task or milestone.
6. Read `state.md` for current project context.

## Step 2: Set up the worktree

1. For each repo in the task's `repos:` list, locate the main clone. Check `$PROJECT_DIR/repos/<repo-name>` first; fall back to `~/code/<repo-name>` if that doesn't exist.
2. Create a worktree:
   - Path: `worktrees/<repo-name>-<task-id>/`
   - Command: `git -C <main-clone> worktree add <worktree-path> -b <branch> origin/main`
3. Do all code work inside the worktree — never in `repos/` or `~/code/`.

## Step 3: Do the work

1. Navigate to the worktree.
2. Read existing code before modifying — understand conventions.
3. Implement the changes described in the task's Summary and Acceptance Criteria.
4. Append progress notes to the task's Work Log via `state_append_note "$QUEUE_DIR" "<task-id>" "<note>"` (sourced from `bin/lib/state.sh` of the craft repo — see working-context block at the top of your prompt).

## Step 4: Run QA per the `qa:` spec

- `unit_tests: true` — run the repo's unit tests. Fix any regressions you introduced. Log output.
- `integration_tests: true` — run integration tests. Same approach.
- `local_validation: "command"` — run the specified command and confirm success.
- `qa_env: true` — **do not attempt.** Log: "QA environment validation required — flagged for {{OPERATOR_NAME}}."
- `prod_validation: true` — **do not attempt.** Log: "Production validation required — flagged for {{OPERATOR_NAME}}."

If any automated QA step fails and you cannot fix it after 2 attempts:
1. Call `state_mark_blocked "$QUEUE_DIR" "<task-id>" "<reason>"`.
2. Stop — do not create a PR.

## Step 5: Create the draft PR

1. Stage and commit with a conventional message (e.g. `feat: add widget`). Do NOT include the task ID in the commit message.
2. `git push -u origin <branch>`.
3. `gh pr create --draft` with:
   - Title: conventional style (e.g. `feat: add per-entity backfill flag`).
   - Body: Summary of changes + QA results + any notes or concerns.
   - `--reviewer {{GITHUB_REVIEWER}}` if `GITHUB_REVIEWER` is set in `craft.conf`; omit the flag otherwise.
4. Capture the PR URL.

## Step 6: Self-review

1. `gh pr diff <pr-number>` to see the full diff.
2. For each changed file, re-read to check context.
3. Review for correctness, code quality, testing, security, and performance.
4. If you find issues: fix them, commit, push.
5. Append a brief self-review summary to the Work Log via `state_append_note`.

**Do NOT post GitHub review comments on your own PR.** Automated PR review bots will review it once the operator marks it ready. Don't duplicate.

## Step 7: Hand off to the watcher

1. Source the state library: `source "$CRAFT_ROOT/bin/lib/state.sh"` (the orchestrator has set `CRAFT_ROOT` and `QUEUE_DIR` — see the working-context block at the top of your prompt).
2. Call `state_mark_waiting "$QUEUE_DIR" "<task-id>" "<pr-url>"`. This moves the task from `in-progress/` to `waiting/` and records the PR URL in the frontmatter.
3. Append a final Work Log entry: `state_append_note "$QUEUE_DIR" "<task-id>" "PR created and handed off to watcher: <pr-url>"`.
4. **Exit.** Run `/exit`. The orchestrator will detect the pane has closed and spawn a watcher for the PR on its next poll cycle.

## Failure handling

If you hit an unrecoverable error at any point:
1. Call `state_mark_blocked "$QUEUE_DIR" "<task-id>" "<clear explanation>"`.
2. `/exit`.

## Important rules

- NEVER merge a PR — only create draft PRs.
- NEVER modify files outside the task's worktree.
- ALWAYS work in the worktree (`worktrees/<repo>-<task-id>/`), never in `repos/` or `~/code/`.
- ALWAYS run the QA steps specified in the task before creating the PR.
- ALWAYS use the branch name from the task's `branch:` frontmatter.
- ALWAYS use conventional commit messages (`feat:`, `fix:`, `refactor:`, etc.) — never prefix with task IDs.
- **DO NOT poll the PR after creating it.** The watcher handles all post-PR lifecycle events — CI failures, review comments, merges, closures. You are done the moment you've called `state_mark_waiting` and exited.
