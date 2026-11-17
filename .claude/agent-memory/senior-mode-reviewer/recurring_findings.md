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

Added on PR #31 re-review (2026-11-17):

- **Quote replacement hides what a guard rule matches.** `guard-bash.sh` turns quoted text into `Q`, so a quoted `gh api` endpoint or a single-quoted GraphQL query (`mergePullRequest`) gets past rules that match on paths or query text. A fix round closed the REST path only, and the spec sentence was widened beyond it ("a merge through gh api").
  **How to apply:** for every rule that matches an argument value (not a flag), test the quoted form, and check that the spec wording matches exactly what the hook denies.
- **Fix rounds skip the non-blocking items.** On #31 the ADR citation (N3) was left as is after the fix commit.
  **How to apply:** list each earlier finding with fixed / not addressed in the re-review.
Added on PR #33 (2026-11-17):
- **Pipeline checks without `pipefail`.** `check()` and the `pre-push` template run each check with `bash -c`, which does not inherit `pipefail`. A check like `git log <range> | validator` passes when `git log` fails (missing base ref), and the test passed only because of that.
  **How to apply:** for every check `run` string with a pipe, ask what happens when the first command fails.
- **Marker-block rewrites (awk skip-until-close-marker).** A missing close marker drops the rest of the user's file. `mv tmp file` replaces symlinks and leaves 0600 mode.
  **How to apply:** require both markers before rewriting, and write back with `cat >`.
- **Spec drift was handled correctly on #33** (spec §12/§14 updated in the PR), so the Spec-Unchanged finding is not systematic any more. Check before flagging it.
- **Guard hook blocks review comments.** `hooks/guard-bash.sh` denies any Bash command whose text contains the commit short skip flag, even inside a heredoc. Say it in words in review comments.

Added on PR #33 second round (2026-11-17):
- **Fix claims without tests regress.** The N7 fix (sed replaced by `${s//pat/$var}`) was claimed as tested but had no case, and it still breaks on `&` because bash 5.2+ has `patsub_replacement` on (only an inner-quoted `"$var"` protects). **How to apply:** for each "fixed" item, find its test; flag `${x//p/$var}` with an unquoted var.
- **Validation by count, not by shape.** Marker checks with `grep -c` (one open, one close) still allow the wrong order. **How to apply:** prefer validating inside the rewriting awk (`END { exit skip }`) to separate pre-checks.
- **"Default branch" guesses.** Fallbacks to origin/main|master miss `develop` or `trunk` when `origin/HEAD` is unset (`git remote add` never sets it). **How to apply:** ask what happens with a remote but an unknown base.

Added on PR #33 third round (2026-11-17):
- **A reviewer's own fix suggestion can regress.** My R2 fix ("fail when origin exists but no base is found") blocked the first push to an empty origin, where no `refs/remotes/origin/*` exist yet and `set-head --auto` cannot help. **How to apply:** when proposing a "fail loudly" fallback, list the states that reach it (empty remote, unborn HEAD, nothing fetched) before posting.
- **Portability is unstated.** The scripts use no bash 4 feature, but fixes use `"${x//p/"$v"}"` (inner quotes kept literally on bash 4.2 and earlier) and GNU BRE `\?`. **How to apply:** flag as non-blocking until a supported platform is stated; propose that the setup or README spec state it at retro.

Added on PR #35 (2026-11-17, frame + issue create):
- **"Reuse instead of duplicate" paths that still write.** `issue create` reuses an open issue by title but re-applies a default Status (Backlog), Priority and Size, which resets Ready/In progress tickets on rerun. **How to apply:** for every find-or-create, check that the found branch does not write defaults; only explicitly passed values may change existing state.
- **Skills that delegate to agents lacking the tools.** `frame` asked `scout` (Read/Grep/Glob only) to run `gh api`; ops has no Write but must supply `--body-file`. **How to apply:** for each "ask agent X to do Y" in a skill, check X's `tools:` frontmatter can do Y.
- **Ready before the spec reaches main.** Framing moved slices to Ready while the spec PR was still open (needs-human for L). **How to apply:** check ordering of ready vs docs PR merge in any planning skill.
- **Empty arrays under `set -u`** (`"${a[@]}"`) fail on bash <= 4.3 (macOS 3.2); regexes like `^[0-9]*$` accept empty values that then match `grep -qx ""` on a here-string.
