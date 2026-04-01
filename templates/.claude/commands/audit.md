# /audit — Check project alignment against requirements

You are the audit skill. Your job is to compare the current project state against a set of requirements, goals, or constraints and identify gaps or needed pivots.

## Input

`$ARGUMENTS` — optional: specific focus area or new requirements to audit against. If empty, audit against the project plan's stated goals.

## Process

1. **Read the full project state:**
   - `docs/plan.md` — goals, non-goals, approach
   - `docs/milestones/` — all milestone definitions and their status
   - `docs/adrs/` — architectural decisions made
   - `state.md` — current progress
   - `queue/` — all tasks across all statuses
   - `queue/archive/` — completed work

2. **If new requirements were provided** (via $ARGUMENTS):
   - Compare them against the current plan
   - Identify conflicts, gaps, or new scope

3. **Assess alignment:**
   - Are we on track to meet the plan's stated goals?
   - Are completed milestones actually delivering on their objectives?
   - Are there architectural decisions that need revisiting?
   - Are there blocked tasks that indicate a systemic problem?
   - Is the remaining work correctly scoped and prioritized?

4. **Produce an audit report:**
   ```
   ## Audit Report — {date}

   ### Alignment Summary
   {Overall assessment: on track / drifting / needs pivot}

   ### Goals Status
   | Goal | Status | Evidence |
   |------|--------|----------|

   ### Gaps Identified
   1. {gap description + recommended action}

   ### Pivot Recommendations
   1. {what to change and why}

   ### New Tasks Suggested
   1. {task description} — priority: {high/medium/low}
   ```

5. **If pivots are recommended:**
   - Create pivot task files in `queue/pending/` with `type: pivot`
   - These describe the changes needed (could be: new ADR, milestone modification, task reprioritization)
   - The operator reviews and approves these like any other task

6. **Update `state.md`** with the audit date and summary.

## Important

- Be honest and specific — vague "everything looks fine" audits are useless
- Quantify where possible (e.g., "3 of 5 goals addressed, 2 not yet started")
- Pivot recommendations should be actionable, not just observations
- Consider timeline constraints mentioned in the plan
