# /qa-task — Validate a completed task

You are the qa-task skill. Your job is to review a completed task's PR and verify it meets the acceptance criteria.

## Input

`$ARGUMENTS` — the task filename (e.g., `task-042.md`).

## Process

1. **Read the task file** from `queue/done/$ARGUMENTS`
2. **Extract the PR URL** from the Work Log section
3. **Read the acceptance criteria** from the task body
4. **Read the QA requirements** from the `qa:` frontmatter block

5. **Review the PR:**
   - Use `gh pr view` and `gh pr diff` to examine the changes
   - Check that the code changes align with the task's Summary and Acceptance Criteria
   - Look for obvious issues: missing error handling, untested edge cases, convention violations

6. **Run automated QA** (if not already done or if re-validation is needed):
   - Check out the PR branch in the relevant repo worktree
   - Run the QA steps specified in the task's `qa:` block
   - Log all results

7. **Produce a QA report** appended to the task's Work Log:
   ```
   ### QA Review — {timestamp}

   **Acceptance Criteria:**
   - [x] Criterion 1 — PASS: {evidence}
   - [ ] Criterion 2 — FAIL: {explanation}

   **Automated QA:**
   - Unit tests: PASS/FAIL
   - Integration tests: PASS/FAIL/SKIPPED
   - Local validation: PASS/FAIL/SKIPPED

   **Code Review Notes:**
   - {any concerns or suggestions}

   **Verdict: PASS / NEEDS CHANGES / FAIL**
   ```

8. **If NEEDS CHANGES or FAIL:**
   - Add a comment to the PR via `gh pr comment` explaining what needs to change
   - Move the task back to `queue/in-progress/` with status `in-progress`
   - The orchestrator will re-run `/work-task` to address the feedback

## Important

- Be thorough but practical — don't block on style nits
- Focus on correctness, security, and meeting the acceptance criteria
- If the task requires `qa_env` or `prod_validation`, note that these are pending Sam's review
