---
name: recurring-findings
description: Review findings seen in senior-mode PRs (spec drift line, bash set -e holes, gh outside gh_retry, overwrite-not-merge setup); candidates for retro rules
metadata:
  type: project
---

Recurring review findings in senior-mode (first noted on PR #29, 2026-11-17):

- **No `Spec-Unchanged:` and no spec update.** Spec 0001 `paths` is `plugins/**`, so every plugin PR touches it. PRs #20-#29 never had the line. The CI check from spec §12 is not implemented yet.
  **Why:** the rule exists only on paper until the check lands. **How to apply:** flag it as non-blocking on every PR, and propose the CI check at retro.
- **Bash `set -e` holes in `bin/senior-mode`.** A failure inside `a && b` or inside a `$(...)` used as an argument does not stop the script. `read < <(...)` with empty output exits silently, before any `die`.
  **How to apply:** check every new multi-step config write and every `read < <()`.
- **`gh` called directly instead of `gh_retry`, with `2>/dev/null`.** This treats transient errors as "not found" and leads to duplicates.
  **How to apply:** grep new code for `gh ` that is not wrapped in `gh_retry`.
- **Setup steps that overwrite instead of merge.** For example, the branch protection PUT replaces the whole protection.
  **How to apply:** idempotency claims must hold on existing repositories, not only on a fresh one.

Related: [[reviewer-environment]]
