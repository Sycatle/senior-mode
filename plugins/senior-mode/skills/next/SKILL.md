---
name: next
description: The daily session with the user in the loop - state of the board, pull requests waiting for a human, then the top Ready ticket delivered test-first with a pull request and a review. Use on "next", "suivant", "on enchaîne", "prochain ticket", "go", or at the start of a working day.
disable-model-invocation: true
argument-hint: "[#issue]"
---

# Next

Argument: $ARGUMENTS (a ticket number; empty means the top of `pick`). Answer in the project language
(`senior-mode config get language`). Details and commands: `${CLAUDE_SKILL_DIR}/reference.md`.

1. **State.** Run `senior-mode status`; give at most five lines, what needs the user first.
2. **Waiting for a human.** For each open pull request that needs the user (`needs-human`, reviewed
   and green, or failing), say what it is and offer to review it (`reviewer` agent) or to merge it.
   Handle these before new work. Never merge without an explicit yes in this conversation; a
   `needs-human` pull request is merged by the user, not by you.
3. **Pick.** `senior-mode pick --max 1`, or the ticket asked for if it is Ready. Nothing to pick: say
   so, suggest `frame`, stop. Show the ticket and its criteria in two lines and ask to take it.
4. **Start.** `senior-mode start <issue>` makes the worktree and the branch and sets In progress.
   Work only in that worktree. If it refuses on the `wip` limit, offer to finish the ticket it names.
5. **Red.** `test-author` agent, from the ticket and its spec (skill `tdd`). Keep the failing output.
6. **Green.** `implementer` agent, atomic commits (skill `commit`), then `senior-mode check` (skill
   `verify`). Show the user the diff summary; they can redirect at any point.
7. **Pull request.** Push, open it from the template with `Closes #<n>`, the red run, what was
   verified and the spec change or `Spec-Unchanged:`. `senior-mode item set <n> Status "In review"`,
   `senior-mode publish`.
8. **Review.** `reviewer` agent in a fresh context; at most two fix rounds by the `implementer`. If
   `senior-mode/security` is pending (protected zone or L ticket), the `security` agent too.
9. **Merge.** Report the verdict and the link, then ask whether to merge. Only on a clear yes, and
   when `senior-mode/ci`, `senior-mode/review` and `senior-mode/security` are all green and the pull
   request is not `needs-human`: `ops` agent,
   `gh pr merge <pr> --rebase --delete-branch`, then `senior-mode item set <n> Status Done`. Then
   invoke skill `docs`; do not wait for its pull
   request. Offer the next ticket.

Never skip a step to go faster; stop and say why when one fails twice.
