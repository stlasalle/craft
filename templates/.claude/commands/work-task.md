# /work-task — Execute a task from the queue

You are the work-task skill. Your job is to pick up a task from the project queue, do the work described in it, produce a draft PR, and then monitor the PR until it is merged.

## Input

The user provides a task filename: `$ARGUMENTS`

If no argument is provided, scan `queue/approved/` and pick the first task that has no unmet `depends_on` entries (i.e., all dependencies are in `queue/done/` or `queue/archive/`).

## Step 1: Read and Understand Context

1. Read the task file from `queue/approved/$ARGUMENTS` (or `queue/in-progress/$ARGUMENTS` if resuming)
2. Parse the YAML frontmatter to understand: type, milestone, dependencies, repos, QA requirements, branch name
3. Read the project plan: `docs/plan.md`
4. Read the relevant milestone doc: `docs/milestones/{milestone}.md`
5. Read any ADRs referenced in the task or milestone
6. Read `state.md` for current project context

## Step 2: Move Task to In-Progress

1. Update the task file's `status:` field from `approved` to `in-progress`
2. Move the file: `queue/approved/{task}.md` → `queue/in-progress/{task}.md`
3. Append a work log entry with timestamp:
   ```
   ### Work Started — {timestamp}
   ```

## Step 3: Set Up Worktree

Each task works in its own git worktree to avoid conflicts with other tasks running in parallel.

1. Read the `repos:` and `branch:` fields from the task frontmatter
2. For each repo in `repos:`, create a worktree:
   - Worktree path: `worktrees/{repo-name}-{task-id}/` (e.g. `worktrees/linktree-backend-task-001/`)
   - Find the main clone of the repo. Check if `repos/{repo-name}` exists (legacy layout). If not, check `~/code/{repo-name}`. Use that as the git dir to create the worktree from.
   - Run: `git -C {main-clone} worktree add {worktree-path} -b {branch} origin/main` (or check out the branch if it already exists)
3. Do all code work inside the worktree, NOT in `repos/` or `~/code/`

## Step 4: Do the Work

1. Navigate to the worktree: `worktrees/{repo-name}-{task-id}/`
2. Read existing code to understand the codebase before making changes
3. Implement the changes described in the task's Summary and Acceptance Criteria
4. Write clean, well-structured code following the repo's existing conventions
5. Append progress notes to the Work Log section as you go

## Step 5: Run QA (per the task's `qa:` spec)

Read the `qa:` block from the task frontmatter and execute each enabled check:

- **`unit_tests: true`** — Run the repo's unit test suite. If tests fail, fix the code. If you can't fix it, note the failure in the work log.
- **`integration_tests: true`** — Run integration tests. Same approach as unit tests.
- **`local_validation: "command"`** — Run the specified command and verify it succeeds. Log the output.
- **`qa_env: true`** — Do NOT attempt this. Add a note to the work log: "QA environment validation required — flagged for Sam."
- **`prod_validation: true`** — Do NOT attempt this. Add a note to the work log: "Production validation required — flagged for Sam."

If any automated QA step fails and you cannot fix it after 2 attempts:
1. Move the task to `queue/blocked/`
2. Update status to `blocked`
3. Append a detailed explanation to the Work Log
4. Stop — do not create a PR

## Step 6: Create Draft PR

1. Stage and commit all changes using conventional commit style: `feat: {summary}`, `fix: {summary}`, etc. Do NOT use task IDs in commit messages.
2. Push the branch to the remote
3. Create a **draft** pull request using `gh pr create --draft`:
   - Title: conventional style, e.g. `feat: add per-entity backfill flag to URL backfill pipeline`
   - Body should include:
     - Summary of changes
     - QA results (what passed, what's flagged for manual review)
     - Any notes or concerns
   - Assign `stlasalle` as reviewer (`--reviewer stlasalle`)
4. Append the PR URL to the task's Work Log
5. Update the task frontmatter to add `pr: {pr-url}`

## Step 7: Self-Review

Before moving to waiting, review your own PR. This catches issues before Sam sees it.

1. Get the full diff: `gh pr diff {number}`
2. For each changed file, re-read the full file to check context
3. Review for:
   - **Correctness**: bugs, off-by-one errors, unhandled edge cases, null/undefined risks
   - **Code quality**: follows existing codebase conventions, no unnecessary `any` casts, no unused imports
   - **Testing**: new code has test coverage, test descriptions are clear
   - **Security**: no injection risks, no exposed secrets
   - **Performance**: no N+1 queries, no unnecessary allocations
4. If you find issues: fix them, commit, and push. Do NOT post review comments on your own PR.
5. Append a brief self-review summary to the Work Log (what you checked, what you fixed if anything)

**Important:** Do NOT post GitHub review comments. The Claude Code GitHub Action will run its own review when Sam marks the PR as ready — avoid duplicate comment spam.

## Step 8: Move Task to Waiting

After self-review, move the task to the waiting state so the orchestrator can notify Sam.

1. Update the task frontmatter: set `status: waiting`
2. Move the file: `queue/in-progress/{task}.md` → `queue/waiting/{task}.md`
3. Append a work log entry:
   ```
   ### PR Created, Waiting for Review — {timestamp}
   PR: {pr-url}
   ```

## Step 9: Monitor PR Until Merge

After moving to waiting, enter a polling loop.

Track whether the PR is still a draft. Initially it will be `isDraft: true`.

**Polling loop (every ~15 seconds):**

1. Check PR status using `gh pr view {number} --json state,isDraft,reviews,comments,mergedAt,statusCheckRollup,title`
2. If the PR has been **merged** (`state: MERGED`):
   - Exit the polling loop
   - Proceed to Step 10 (Complete Task)
3. If the PR was **previously a draft** but is now **no longer a draft** (`isDraft` changed from `true` to `false`):
   - Sam has marked it as ready for review — post it to the team's PR thread
   - Find today's PR thread: `~/.claude/slack-bot/pr-thread-cache.sh get` — if that exits non-zero, skip posting (don't block on this)
   - Post using the PR title as the message: `~/.claude/slack-bot/post.sh --channel C08HQLZK3A7 --thread "$THREAD_TS" --text "{pr-title} - <{pr-url}|#{pr-number}>"`
   - Append a work log entry: "PR marked as ready — posted to #team-trust-platform"
   - Update your tracked draft state so you don't post again
4. If **CI checks have failed** (any item in `statusCheckRollup` has `conclusion: FAILURE`):
   - Read the failed check details: `gh pr checks {number}`
   - Use the `bk` CLI to inspect Buildkite build steps and logs (e.g. `bk build view`, `bk step logs`)
   - Investigate the failure — look at build logs, test output, linting errors, etc.
   - Fix the issue in the code
   - Commit and push with a descriptive conventional commit message
   - Append a work log entry noting the CI failure and your fix
5. If there are **new review comments or PR comments** since last check:
   - Read and understand the feedback
   - Make the requested changes in the code
   - Commit and push with a descriptive conventional commit message
   - Append a work log entry noting the review feedback and your response
6. If the PR has been **closed** (not merged):
   - Append a work log entry noting the PR was closed
   - Move the task to `queue/blocked/` with an explanation
   - Stop polling
7. Otherwise, sleep ~15 seconds and check again

**Important:** Sam will mark the PR as "ready" after his initial review. Automated PR bots will then review the PR too, adding more comments/reviews. CI checks (Buildkite) run on every push. Stay alive to handle all rounds of feedback — both human reviews and CI failures.

## Step 10: Complete Task

Only reach this step when the PR has been merged.

1. Update the task frontmatter: set `status: done`
2. Move the file: `queue/waiting/{task}.md` → `queue/done/{task}.md`
3. Append a completion entry to the Work Log:
   ```
   ### Work Completed — {timestamp}
   PR: {pr-url}
   QA: {summary of qa results}
   ```
4. Update `state.md` with the latest activity
5. Do NOT clean up the worktree — leave it in place. Sam will clean up worktrees manually.

## Failure Handling

If you hit an unrecoverable error at any point:
1. Move the task to `queue/blocked/{task}.md`
2. Set `status: blocked` in frontmatter
3. Write a clear explanation in the Work Log: what you tried, what failed, what Sam needs to do
4. Update `state.md` to reflect the blocked task

## Important Rules

- NEVER merge a PR — only create draft PRs
- NEVER modify files outside the task's worktree
- ALWAYS work in the worktree (`worktrees/{repo}-{task-id}/`), never in `repos/` or `~/code/`
- ALWAYS read existing code before modifying it
- ALWAYS run the QA checks specified in the task before creating the PR
- ALWAYS update the Work Log as you go — this is Sam's audit trail
- ALWAYS use the branch name from the task's `branch:` frontmatter
- ALWAYS use conventional commit messages (`feat:`, `fix:`, `refactor:`, etc.) — never prefix with task IDs
- If the task's `depends_on` lists tasks that are NOT in `done/` or `archive/`, STOP and move the task to `blocked/` with an explanation
