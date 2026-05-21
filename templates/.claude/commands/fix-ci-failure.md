# /fix-ci-failure — Fix a failing CI check on an open PR

You are a short-lived remediation agent dispatched by a PR watcher because at least one CI check failed on the pull request.

## Input

`$ARGUMENTS` — the PR URL (e.g., `https://github.com/owner/repo/pull/42`).

## Your Job

1. **Identify the failing check(s).**
   - Run `gh pr checks <pr-url>` to list all checks and their statuses.
   - Focus on checks with `conclusion: FAILURE`. Ignore PENDING and SUCCESS.

2. **Read the failure details.**
   - For each failing check, run `gh api` or `gh run view` to fetch log output.
   - If the failure is from a Buildkite-posted check, the `targetUrl` in the check payload points to the Buildkite build; the check's annotation or summary usually has the relevant failure excerpt.
   - Read enough to determine the *root cause* — a failing test, a lint violation, a compilation error, a missing migration, etc.

3. **Navigate to the worktree.**
   - The prompt prefix you received names the worktree path. `cd` there before making any changes.
   - Do NOT modify files anywhere else on disk.

4. **Make the minimal fix.**
   - Fix only what's required to make the failing check pass.
   - Do NOT refactor unrelated code.
   - Do NOT add new features or tests beyond what the failure requires.
   - Follow the existing conventions in the repo.

5. **Verify locally if possible.**
   - If the failure is a unit test, run it locally to confirm your fix works.
   - If the failure is lint/typecheck, run the linter to confirm.
   - If you can't verify locally (e.g., an integration test that requires infrastructure), document what you tried.

6. **Commit and push.**
   - Use a conventional commit: `fix: <short description of what you fixed>`.
   - Do NOT reference the task ID in the commit message.
   - `git push` to the same branch.

7. **Exit.**
   - Do not comment on the PR.
   - Do not mark it as ready.
   - Do not merge.
   - The watcher will detect the new push, re-run its poll, and see the CI status transition on its own.

## Important Rules

- ONLY work in the worktree. Never modify files outside.
- NEVER mark the PR as ready or merge it. The operator controls those gates.
- NEVER disable or skip the failing check to "fix" it. Fix the underlying code.
- NEVER push force-push (`--force`) unless the branch has no history beyond your own changes.
- If you cannot determine the root cause, cannot fix it in this session, OR the fix requires changes outside the worktree: exit without pushing. The watcher will log that the remediation ran and the PR will remain in its failing state for operator attention.
- Keep the session tight — this is a focused fix, not a rework.
