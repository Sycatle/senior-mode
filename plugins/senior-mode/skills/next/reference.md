# next: reference

## Commands

| Step | Command |
|---|---|
| State | `senior-mode status` (moves the "last time" mark; `--json` to list what needs a human) |
| Waiting | `gh pr list --state open --json number,title,url,labels,headRefName`; statuses of one: `gh pr checks <n>` |
| Pick | `senior-mode pick --max 1` (Ready, open, not L, not blocked, no `needs-info`; Priority, milestone, number) |
| Start | `senior-mode start <issue>`: prints `branch <name>` and `worktree <path>`, sets Status In progress |
| Ticket | `gh issue view <n> --json title,body,labels`; the spec is linked in the body |
| Pull request | `gh pr create --body-file <file>` from `.github/pull_request_template.md`; the title is the first commit's subject |
| Merge | `gh pr merge <n> --rebase --delete-branch`, never `--admin` |

## Waiting for a human

- Reviewed and green, no `needs-human`: offer "merge #n?". On a clear yes, merge as in step 9.
- No review yet: offer the `reviewer` agent first; it posts the verdict and `senior-mode/review`.
- `needs-human` (protected zone, size L, ADR): summarise the verdict and the files that triggered
  it, and let the user merge it themselves.
- Failing status: show the failing context; offer to fix it on that branch.
- A pull request whose branch is not in a worktree here is reviewed from `gh pr diff`; do not check
  it out in the main checkout.

## Delivering

- Start from a clean state: `senior-mode start` is safe to rerun and reuses the worktree.
- A ticket the user redirects mid-way keeps its branch; commit what exists, say what is left.
- When the work outgrows the ticket's size, or touches a protected zone it did not plan for
  (`senior-mode config get protected`): stop and ask; the pull request gets `needs-human`.
- Discovered work becomes a new issue (`senior-mode issue create`), not part of this pull request.
- After a merge, `docs` runs once; a `docs/after-pr-*` pull request is never documented in turn.
- Close the day with a short count: merged, waiting for the user, next ticket.
