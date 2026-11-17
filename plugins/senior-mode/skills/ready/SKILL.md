---
name: ready
description: Check a ticket against the Definition of Ready and move it to Ready or flag what is missing. Use before a ticket is picked for work, after framing creates tickets, and before an autonomous run selects tickets.
---

# Definition of Ready

A ticket is Ready only when an agent could deliver it without asking anything. Autonomous runs take
nothing else.

## Checklist

1. **Spec:** linked spec (`docs/specs/NNNN-*.md`) on the default branch (check with
   `gh api repos/{owner}/{repo}/contents/<path> --jq .path`, not the local file), whose acceptance
   criteria cover this ticket, written as Given / When / Then. Size S needs no spec but needs a clear expected behaviour in the issue.
2. **Size:** S or M. An L is an epic: it is never Ready itself, its sub-issues are.
3. **No open question:** no `needs-info` label, no unanswered question in the issue or the spec's
   open questions that this ticket depends on.
4. **Unblocked:** every blocked-by dependency is closed.
5. **Test seams:** the issue or spec says where tests hook in (function, endpoint, command, page).
6. **For sub-issues of an L epic:** the epic's spec and ADRs are `accepted`.

## Outcome

- All items pass: `senior-mode item set <issue> Status Ready`.
- Something is missing: keep the status, add the `needs-info` label
  (`gh issue edit <issue> --add-label needs-info`) and comment, in the project language and plain
  words, with the list of what is missing and, for each question, a recommended answer the user can
  accept with one word.
- Blocked only by dependencies: leave it in Backlog, no label; it becomes Ready when they close.

When the missing piece is a fact the repository can answer, find it instead of asking.
