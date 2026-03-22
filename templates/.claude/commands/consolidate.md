# /consolidate — Summarize milestone completion

You are the consolidate skill. Your job is to assess milestone completion, archive done tasks, and update project documentation.

## Input

`$ARGUMENTS` — the milestone ID (e.g., `m1-ingestion-pipeline`).

## Process

1. **Read all done tasks** for this milestone from `queue/done/`
   - Filter by `milestone:` field in frontmatter matching `$ARGUMENTS`

2. **Read the milestone doc:** `docs/milestones/$ARGUMENTS.md`

3. **Assess completion:**
   - Are ALL tasks for this milestone in `done/`?
   - If not, which are still pending/approved/in-progress/blocked?
   - If incomplete, report the gap and stop — don't consolidate a partial milestone

4. **Generate the completion summary:**
   - What was accomplished (list of PRs merged, features delivered)
   - What acceptance criteria were met
   - Any deviations from the original milestone plan
   - Any follow-up items or tech debt identified during the work
   - Lessons learned (what went well, what was harder than expected)

5. **Update documents:**
   - Append the completion summary to the milestone doc's "Completion Summary" section
   - Check all status boxes in the milestone doc
   - Update `state.md` with the milestone completion
   - Update `docs/plan.md` if the milestone completion changes the overall plan status

6. **Archive tasks:**
   - Create `queue/archive/$ARGUMENTS/` directory
   - Move all done tasks for this milestone from `queue/done/` to `queue/archive/$ARGUMENTS/`
   - This clears the `done/` folder for the next active cycle

7. **Cross-pollinate:**
   - Append a lessons-learned entry to `../../shared/lessons-learned.md` (the repo-level file)
   - Include: project name, milestone, date, key insights

8. **Suggest next steps:**
   - Based on the plan, what's the logical next milestone?
   - Are there any blocked tasks from other milestones that are now unblocked?
   - Suggest running `/generate-milestone` if the next milestone isn't defined yet

## Important

- Do NOT consolidate if tasks are still in-progress or blocked — report the gap instead
- The archive is permanent history — make sure task files are complete before archiving
- The lessons-learned entry should be genuinely useful, not boilerplate
