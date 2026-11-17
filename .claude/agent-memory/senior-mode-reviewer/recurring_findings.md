---
name: recurring-findings
description: Review findings seen in senior-mode PRs (spec drift line, bash set -e holes incl. functions called in a || context, gh_retry misuse both ways, overwrite-not-merge setup, unpaginated lookups)
metadata:
  type: project
---

Recurring review findings in senior-mode (first noted on PR #29, 2026-11-17):

- **No `Spec-Unchanged:` and no spec update.** Spec 0001 `paths` is `plugins/**`, so every plugin PR touches it. PRs #20-#29 never had the line. The CI check from spec §12 is not implemented yet.
  **Why:** the rule exists only on paper until the check lands. **How to apply:** flag it as non-blocking on every PR, and propose the CI check at retro.
- **Bash `set -e` holes in `bin/senior-mode`.** A failure inside `a && b` or inside a `$(...)` used as an argument does not stop the script. `read < <(...)` with empty output exits silently, before any `die`. A function called as `x=$(f) || die` or `if f` runs with `-e` off, so every command inside it needs its own `|| return 1` (B3 on PR #29, fixed that way in 98e52f7).
  **How to apply:** check every new multi-step config write, every `read < <()`, and every function body whose caller uses `||` or `if`.
- **`gh_retry` misuse, both ways.** `gh` called directly with `2>/dev/null` treats transient errors as "not found" and leads to duplicates. `gh_retry` around non-idempotent calls (`project create`, POST with `--input -`) can retry an applied request, or send an empty stdin on the retry.
  **How to apply:** grep new code for `gh ` that is not wrapped in `gh_retry`, and for creates or `--input -` that are wrapped.
- **Setup steps that overwrite instead of merge.** For example, the branch protection PUT replaces the whole protection.
  **How to apply:** idempotency claims must hold on existing repositories, not only on a fresh one.
- **Lookups that do not paginate before a create.** `project list --limit 100` and `GET .../rulesets` (30 per page) can miss the existing object, so setup creates a duplicate or gets a 422.
  **How to apply:** for every find-then-create step, check that the lookup covers all pages.

Related: [[reviewer-environment]]

Added on PR #31 (2026-11-17, guard-bash `--admin` rule):

- **Guard hook parsing holes.** `guard-bash.sh` reads segments with `read -r` after `tr`, so a backslash-newline continuation splits one command in two. Rules that need two words to be adjacent (`pr merge`) miss flags placed between them (`gh pr -R x merge`). Quoted flags become `Q`.
  **How to apply:** for every new guard rule, test a multi-line form, flags between subcommand words, and the `gh api` equivalent of the denied CLI path.
- **Doc or comment references to the wrong ADR.** The admin bypass decision is in spec 0001 §11 (#11), not in ADR 0006.
  **How to apply:** grep the cited ADR for the claim before you accept the citation.
- **Hooks count as the security zone.** No `protected` key is set in `.claude/senior-mode.json`. I treated agent guard hooks as security and added `needs-human` on #31.
