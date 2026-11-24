---
name: go
description: Move the project forward - attaches to the daemon when it runs, otherwise delivers the top Ready ticket with the user in the loop, test-first with a pull request and a review; "auto" starts the daemon. Use on "go", "next", "suivant", "on enchaîne", "prochain ticket", "lance", or at the start of a working day.
disable-model-invocation: true
argument-hint: "[#issue | auto]"
---

# Go

Argument: $ARGUMENTS (a ticket number, `auto`, or empty). Answer in the project language
(`senior-mode config get language`). Details and commands: `${CLAUDE_SKILL_DIR}/reference.md`.

0. **Adopted?** No `.claude/senior-mode.json`: invoke skill `setup` first, then go on.
1. **State.** `senior-mode status --json` once. If `.serve.running`: the daemon delivers. Say so,
   summarise what needs the user, show where to watch (`senior-mode status --watch`, `journalctl
   --user -u senior-mode-serve`) and stop. Argument `auto`: confirm `autonomy.parallel` and
   `autonomy.merge`, then `senior-mode serve --install`; stop. Otherwise five lines at most.
2. **Waiting for a human.** For each pull request that needs the user (`needs-human`, reviewed and
   green, failing): what it is, offer review (`reviewer` agent) or merge. Before new work. Never merge
   without an explicit yes here; a `needs-human` pull request is merged by the user.
3. **Pick.** `senior-mode pick --max 1`, or the asked ticket if Ready. Nothing: suggest `frame`, stop.
   Show the ticket and its criteria in two lines and ask to take it.
4. **Start.** `senior-mode start <issue>`; work only in its worktree. Refused on `wip`: offer to finish
   the ticket it names.
5. **Red.** `test-author` agent (skill `tdd`); keep the failing output. Wait for a background agent.
6. **Green.** `implementer` agent, atomic commits (skill `commit`); once it returned, `senior-mode
   check` (skill `verify`). Show the diff summary; the user can redirect at any point.
7. **Pull request.** Run the review checklist on your diff. Push, template, `Closes #<n>`, the red run,
   the Self-review table (a row `#<n>.<k>` with evidence per criterion; `senior-mode ready --pr <pr>`
   checks it), the spec change or `Spec-Unchanged:`. `senior-mode item set <n> Status "In review"`, `senior-mode publish`.
8. **Review.** `reviewer` agent, fresh context; two fix rounds at most. `senior-mode/security`
   pending (protected zone, L ticket): the `security` agent too.
9. **Merge.** Verdict and link, then ask. Only on a clear yes, with ci, review and security green and
   no `needs-human`: `ops` agent, `gh pr merge <pr> --rebase --delete-branch`, `senior-mode item set
   <n> Status Done`. Then skill `docs` without waiting. Offer the next ticket.

A security risk met outside the ticket is filed (`senior-mode issue create --severity ...`,
reference "Delivering"), never fixed in this pull request.

Never skip a step to go faster; stop and say why when one fails twice.
