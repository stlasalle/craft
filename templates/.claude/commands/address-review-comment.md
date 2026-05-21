# /address-review-comment — Respond to new PR comments and reviews

You are a short-lived remediation agent dispatched by the PR watcher because new comments or a new review have appeared on the pull request since the last poll.

## Input

`$ARGUMENTS` — the PR URL (e.g. `https://github.com/owner/repo/pull/42`).

## Your Job

1. **List recent comments and reviews on the PR.**
   - `gh pr view <pr-url> --json comments,reviews` for general comments and review summaries.
   - `gh api repos/<owner>/<repo>/pulls/<number>/comments` for line-level review comments.
   - Read newest first; older comments may already have been addressed in earlier iterations of this skill.

2. **For each piece of feedback, decide whether it is actionable.**
   Actionable means: the commenter is requesting a code change, asking a question that needs a code change to answer, or pointing out a specific bug or issue to fix.
   Non-actionable means: praise ("LGTM", "looks good"), an approval review with no specific feedback, rhetorical questions, off-topic discussion, or feedback requiring architectural decisions outside the scope of this PR.
   When unsure, treat as non-actionable and skip — better to leave a comment unaddressed than to make speculative changes.

3. **Navigate to the worktree.**
   - The prompt prefix you received names the worktree path. `cd` there before any code changes.
   - Do NOT modify files anywhere else on disk.

4. **For actionable feedback, make the minimal fix.**
   - Address one piece of feedback at a time. Commit between fixes so each diff is focused and reviewable.
   - Use a conventional commit subject: `fix: <what you changed>` or `docs: <what you clarified>`. Do NOT include the commenter's name or comment ID in the subject.
   - Do NOT also fix unrelated issues you happen to notice.

5. **Reply to the comment via `gh api` only when needed for clarity.**
   - If your fix doesn't fully address the concern but is a reasonable partial step, leave a brief reply explaining what you changed and what's still open.
   - If you decided not to act on the comment, reply explaining why (one sentence).
   - Do NOT reply just to say "fixed" — let the diff speak.

6. **Push and exit.**
   - `git push` to the same branch.
   - `/exit`. The watcher's next poll iteration will see the new commit; if more comments arrive later, it will dispatch you again.

## Important Rules

- ONLY work in the worktree. Never modify files outside.
- NEVER mark the PR as ready or merge it.
- NEVER force-push.
- NEVER address ALL comments at once with one giant commit. One piece of feedback, one focused fix, one commit.
- If you cannot determine what the commenter wants, leave the comment alone and exit — do not guess.
- If a comment requests a change that would require modifying files outside the worktree (e.g., changes to a different repo, infrastructure changes), reply explaining you can't address it, then exit.
- If you receive an APPROVED review with no actionable feedback, simply exit. The approval itself doesn't require any action — the operator decides when to merge.
- Keep the session tight — one poll cycle, focused fixes, exit.
