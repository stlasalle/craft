# /work-task — Execute a task from the queue

You are the work-task skill. Your job is to pick up a task from the project queue, do the work described in it, and produce a draft PR.

## Input

The user provides a task filename: `$ARGUMENTS`

If no argument is provided, scan `queue/approved/` and pick the first task that has no unmet `depends_on` entries (i.e., all dependencies are in `queue/done/` or `queue/archive/`).

## Step 1: Read and Understand Context

1. Read the task file from `queue/approved/$ARGUMENTS` (or `queue/in-progress/$ARGUMENTS` if resuming)
2. Parse the YAML frontmatter to understand: type, milestone, dependencies, repos, QA requirements
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

## Step 3: Do the Work

1. Navigate to the relevant repo in `repos/{repo-name}/`
2. Create a new branch from the repo's default branch: `{task-id}/{short-description}`
3. Read existing code to understand the codebase before making changes
4. Implement the changes described in the task's Summary and Acceptance Criteria
5. Write clean, well-structured code following the repo's existing conventions
6. Append progress notes to the Work Log section as you go

## Step 4: Run QA (per the task's `qa:` spec)

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

## Step 5: Create Draft PR

1. Stage and commit all changes with a clear message: `[{task-id}] {summary}`
2. Push the branch to the remote
3. Create a **draft** pull request using `gh pr create --draft`:
   - Title: `[{task-id}] {short summary from task}`
   - Body should include:
     - Link back to the task (file path in the project)
     - Summary of changes
     - QA results (what passed, what's flagged for manual review)
     - Any notes or concerns
   - Assign Sam as reviewer
4. Append the PR URL to the task's Work Log

## Step 6: Update State

1. Update the task frontmatter: set `status: done`
2. Move the file: `queue/in-progress/{task}.md` → `queue/done/{task}.md`
3. Append a completion entry to the Work Log:
   ```
   ### Work Completed — {timestamp}
   PR: {pr-url}
   QA: {summary of qa results}
   ```
4. Update `state.md` with the latest activity

## Failure Handling

If you hit an unrecoverable error at any point:
1. Move the task to `queue/blocked/{task}.md`
2. Set `status: blocked` in frontmatter
3. Write a clear explanation in the Work Log: what you tried, what failed, what Sam needs to do
4. Update `state.md` to reflect the blocked task

## Important Rules

- NEVER merge a PR — only create draft PRs
- NEVER modify files outside the task's declared `repos:`
- ALWAYS read existing code before modifying it
- ALWAYS run the QA checks specified in the task before creating the PR
- ALWAYS update the Work Log as you go — this is Sam's audit trail
- If the task's `depends_on` lists tasks that are NOT in `done/` or `archive/`, STOP and move the task to `blocked/` with an explanation
