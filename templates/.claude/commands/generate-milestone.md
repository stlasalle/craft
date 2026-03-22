# /generate-milestone — Interactively create the next milestone

You are the generate-milestone skill. Your job is to help Sam identify and define the next milestone for the project.

## Input

`$ARGUMENTS` — optional: a rough description of what the next milestone should focus on.

## Process

1. **Read current state:**
   - `docs/plan.md` — the master plan and overall goals
   - `state.md` — current project progress
   - `docs/milestones/` — all existing milestones and their status
   - `queue/done/` and `queue/archive/` — what's been accomplished
   - `queue/blocked/` — any ongoing blockers

2. **Assess where we are:**
   - Which milestones are complete?
   - Which goals from the plan are not yet addressed?
   - Are there blocked items that suggest a milestone is needed?
   - What's the natural next step based on dependencies?

3. **Propose the next milestone:**
   - Present Sam with a proposed milestone: objective, scope, success criteria
   - Explain your reasoning: why this milestone, why now
   - Ask Sam for feedback — this is an interactive conversation

4. **Iterate with Sam** until he's happy with the milestone definition.

5. **Write the milestone doc:**
   - Determine the next milestone ID (e.g., if `m2-*` exists, create `m3-*`)
   - Create `docs/milestones/{milestone-id}.md` using the milestone template structure
   - Update `docs/plan.md` milestones section if needed
   - Update `state.md` to reflect the new milestone

## Important

- This is an INTERACTIVE skill — do not write the milestone doc without Sam's approval
- Present options and trade-offs, don't just pick one path
- Consider the project timeline and any constraints mentioned in the plan
- Think about dependencies between milestones
