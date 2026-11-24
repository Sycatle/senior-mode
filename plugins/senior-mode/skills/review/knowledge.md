# Findings and knowledge notes: reference

Read at the end of every review, before posting the comment.

## The finding marker

A finding is a list item of the verdict that names a `file:line`. Each one ends with
`<!-- finding: <slug> -->`, and nothing follows the marker. The slug is stable: the same rule on the
same area gets the same slug on every pull request, so it can be searched for.

- Shape: `<rule>-<area>`, kebab-case, at most 60 characters.
- `<rule>`: the check that was broken, in the words of this skill or of the project's rule, not of the
  pull request: `unchecked-input`, `swallowed-error`, `missing-test`, `n-plus-one`, `layer-violation`.
- `<area>`: the module the file lives in (`billing`, `auth`, `cli-board`), not the file or the line.
- Before inventing a slug, look for an existing one: `gh pr list --state merged --limit 30 --json number`
  then `gh pr view <n> --json comments --jq '.comments[].body'`, searching for `finding:`.

## A finding seen twice

For each finding, search the last 30 merged pull requests for a comment carrying the same marker.
It counts when that pull request changed a file under the same directory as the finding
(`gh pr view <n> --json files`). Then, once the review is posted:

1. A note already covers it when `docs/knowledge/<slug>.md` exists, or a note of `kind: pitfall`
   has `paths` matching the finding's file and says the same thing. Cite the note in the review
   (`covered by docs/knowledge/<slug>.md`) and open nothing.
2. Otherwise open one separate pull request for it, never on the branch under review, and leave that
   branch and its pull request untouched:
   - `git worktree add <dir> -b docs/knowledge-<slug> origin/<default branch>`; write
     `docs/knowledge/<slug>.md` with a heredoc (you have no editor).
   - Front matter: `paths` the narrowest globs covering the findings' files of both pull requests,
     `verified` today, `origin: "#<earlier>, #<this>"` (a quoted list of both pull requests),
     `kind: pitfall`.
   - Body: a title naming the trap, then what goes wrong, why, and what to do. Under 40 lines.
   - `senior-mode check` in that worktree must pass; commit `docs(knowledge): <slug>`; push;
     `gh pr create --base <default branch>` with a title `docs(knowledge): <slug>`, a body that links
     both pull requests, and no `Closes`. Link it in the review.

A finding seen once opens nothing. At most 2 such pull requests per review.
