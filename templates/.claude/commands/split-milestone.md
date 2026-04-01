# /split-milestone — Break a milestone into executable tasks

You are the split-milestone skill. Your job is to take a milestone definition and produce a set of task files in the queue.

## Input

`$ARGUMENTS` — the milestone ID (e.g., `m1-ingestion-pipeline`).

## Process

1. **Read the milestone doc:** `docs/milestones/$ARGUMENTS.md`
2. **Read supporting context:**
   - `docs/plan.md` — overall project context
   - `docs/adrs/` — any relevant architectural decisions
   - `.claude/CLAUDE.md` — project conventions and repo info
   - `state.md` — current project state
   - Existing tasks in `queue/` — avoid duplicating work already done or in progress

3. **Analyze the milestone** and break it into discrete, executable tasks:
   - Each task should be completable in a single PR
   - Tasks should be small enough for a single Claude session to handle (roughly 1-3 files changed)
   - Identify dependencies between tasks and set `depends_on` correctly
   - Determine which repo each task belongs to

4. **For each task, determine QA requirements:**
   - Does it need unit tests? (almost always yes)
   - Does it need integration tests? (if it touches APIs, databases, or service boundaries)
   - What local validation command would verify it works?
   - Does it need QA environment testing? (if it changes user-facing behavior)
   - Does it need production validation? (if it's critical infrastructure)

5. **Generate task files** in `queue/pending/`:
   - Use sequential IDs continuing from the highest existing task number
   - Follow the task template format exactly
   - Set `type: pr` for code tasks
   - Include clear acceptance criteria that Claude can verify
   - Include technical notes with relevant file paths and implementation hints

6. **Present the task list to {{OPERATOR_NAME}}** with a summary:
   - Total number of tasks
   - Dependency graph (which tasks block which)
   - Estimated parallelism (how many tasks can run concurrently)
   - Any tasks that need QA/prod validation ({{OPERATOR_NAME}}'s involvement required)

7. **Update `state.md`** to reflect the new tasks.

## Important

- Tasks should be ordered so that foundational work comes first
- Don't create tasks that are too vague — each task should have clear, testable acceptance criteria
- If the milestone is too large (>15 tasks), suggest splitting it into sub-milestones
- Flag any tasks where you're uncertain about the approach — these should be discussed before approval
