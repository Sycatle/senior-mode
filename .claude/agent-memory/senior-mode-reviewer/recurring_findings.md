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

Added on PR #35 re-review (2026-11-17):
- **Fixes placed in the caller, not the shared rule.** The rule that Ready must wait for the merged spec was added to `frame` only. The `ready` checklist still accepts a spec that is only on a docs branch. **How to apply:** when a fix adds a precondition to one skill, check whether the discipline skill it calls should own that precondition.
- **A widened lookup without the field that tells what it found.** `milestones?state=all` combined with `--jq '.[].title'` hides closed milestones. **How to apply:** when a lookup goes from open to all states, check that the state reaches the decision.
- **Stdin or heredoc handoff to a Haiku agent.** Without an explicit quoted `<<'EOF'`, backticks in the body run as commands. The guard hook also parses heredoc lines that start with git or gh after a backtick. **How to apply:** every skill that passes free text through Bash must name the quoted heredoc form.
- **Single-to-multi argument changes** (`item set` pairs): check the global `usage()` and the agent docs that show the old form.

Added on PR #37 (2026-11-17, follow-up of #35 notes):
- **A listing that drops the id the next step needs.** The frame milestone listing printed state and title, but the reopen PATCH needs the number. **How to apply:** for every "list, then act on one" instruction, check that the list prints the key the action takes.
- **Write actions placed in a read-only step.** The "reopen a closed milestone" rule sat in frame's Facts step, before any milestone was chosen. **How to apply:** check that each write runs in the step where its target is known.
- **Skill rule changed, spec definition not.** `ready` gained "on the default branch", but spec 0001 §6 (Definition of Ready) was not updated, and `Spec-Unchanged` cited §11 instead. **How to apply:** for skill wording changes, grep the spec for the definition the skill implements, not only the section the PR cites.
- **Space-joined lists split again with an unquoted `for`.** Label names went through jq `join(" ")` and then `for b in $stale`, so names with spaces or globs break. Also, `join` on numbers needs jq 1.6 or later. **How to apply:** prefer one item per line with `while IFS= read -r`, and `tostring` before `join`.

Added on PR #38 (2026-11-17, follow-up of #37 notes):
- **"Is it on main" checks that test existence, not content.** `ready` checked the spec with `contents/<path> --jq .path`, which passes for an older version of an amended spec while the criteria and `accepted` status are read from the local docs branch. **How to apply:** when a check must use the default-branch version, the content it judges must come from there too (raw contents API), not only the path.
- **Tests that log `"$*"` cannot pin argument boundaries.** The gh stub in `test-issue.sh` joins arguments with spaces, so a quoting regression (`$b` unquoted) passes a test meant for "label kept whole". **How to apply:** for quoting/splitting fixes, ask for a stub that records one argument per line and an exact-line assert.

Added on PR #39 (2026-11-17, `senior-mode release`):
- **Temp files holding secrets cleaned by per-branch `rm -f`.** `release()` wrote the gh token to a mktemp file and removed it in three places, but no `trap`, so a Ctrl-C during npx left it in $TMPDIR. **How to apply:** for every mktemp holding a secret, ask for `trap 'rm -f ...' EXIT` right after creation.
- **"Pinned" npx tools.** `npx pkg@x.y.z` pins only the top package; transitive deps float without a lockfile. **How to apply:** challenge comments that promise reproducibility from an npx pin.
- **Protected-zone call:** release tooling that hands the gh token to an npm package was treated as security/infrastructure (`needs-human`, status pending).
- **Spec-Unchanged in prose only.** The body said why the spec was unchanged but without the `Spec-Unchanged:` line; still flag (cheap).

Added on PR #39 re-review (2026-11-17):
- **Both earlier findings fixed in one round** (EXIT trap plus INT/TERM traps that call exit, with a TERM test that failed on the old code). This is the pattern to accept for secret temp files: trap string expanded at install time (a `local` is gone by EXIT), and `( )` subshells do not inherit it. **How to apply:** a TERM-only test is enough; INT cannot be trapped in a background job of a non-interactive shell.
- **Human-merge notes are not findings, so they stay unaddressed.** The npx pin comment was left as is. **How to apply:** repeat them briefly under "For the human merge"; do not escalate them.

Added on PR #40 (2026-11-17, typescript preset):
- **Spec prose inserted inside a markdown table.** A paragraph added after one row of the §14 presets table broke the rest of it into plain text. **How to apply:** when a spec diff adds text next to a table, check that it is not between rows.
- **New release types with an old version seed.** Switching release-please to `node` kept the manifest at 0.0.0, which conflicts with an existing `package.json` version. **How to apply:** when a preset changes the release type, check where the current version comes from.
- **`npx <bin>` in non-interactive checks.** With stdin not a TTY, npm 7+ assumes yes and downloads a package named like the bin (`tsc` is a placeholder package). **How to apply:** prefer `npx --no --` or the package manager's exec for generated check commands.
- **Detection by one marker file** (`package.json` → typescript) also catches tooling-only package.json in other stacks. Flagged as a follow-up note, not blocking, since the spec says so.

Added on PR #40 re-review (2026-11-17):
- **"Dependency declared" is not "installed".** The npx fix gated the tsc fallback on `typescript` in package.json, which still downloads the `tsc` placeholder on a fresh clone without node_modules. **How to apply:** for fallbacks that run a local bin, ask whether the gate checks the manifest or the install; the robust fix is a runner flag that refuses downloads (`npx --no`).

Added on PR #43 (2026-11-17, repo checks its commits with the template hook):
- **Skip rules keyed on text, not structure.** The commit-msg hook skips `Merge *` subjects instead of merge commits, so dropping `git log --no-merges` lets a regular commit titled "Merge ..." pass. **How to apply:** when a PR drops a structural filter because "the tool skips it", check how the tool recognises the case.
- **Protected-zone call:** edits to `.github/workflows/ci.yml` or the `checks` list in `.claude/senior-mode.json` count as CI (`needs-human`, status pending), even while the workflow is disabled.
- Spec-Unchanged was missing again on a test-only change under `plugins/**`.

Added on PR #44 (2026-11-17, release-please initial-version):
- **Version seeds: initial-version vs manifest.** release-please releases `initial-version` exactly, with no bump; a non-0.0.0 manifest version is treated as the last release and bumped. Taking `initial-version` from package.json repeats an already-published version, and `npm init` gives 1.0.0. **How to apply:** for an existing version, ask for a seeded manifest instead.
- **"Already covered by test X" claims in PR bodies.** The `own` case cited for "existing config unchanged" had no such config. **How to apply:** open the cited test and check the fixture contains the case.

Added on PR #39 rebase re-review (2026-11-17):
- **Rebase re-reviews: prove the code is unchanged first.** `git range-diff <oldbase>..<oldhead> origin/main..<newhead>` with `=` on every code commit, plus `merge-base --is-ancestor origin/main <head>`, was enough to approve without re-reading the logic. Then only check what main added that could interact (here: other `trap`s in the CLI).

Added on #46 review (2026-11-17, git hook env unset in check and pre-push; asked before any push):
- **Env-leak tests that match a whole prefix.** The check `env | grep ^GIT_ && exit 1` fails on any GIT_* variable of the caller (GIT_EDITOR, GIT_SSH_COMMAND, GIT_PAGER), not only the ones the fix unsets. The head commit's own check record said `failed: script tests`. **How to apply:** env-leak asserts must name the exact variables (or the `git rev-parse --local-env-vars` list).
- **Review asked before push.** No PR and no remote commit, so no comment, label or status can be set. **How to apply:** check `gh api repos/O/R/commits/<sha>` first; report the findings and ask for a push. The local record `.git/senior-mode/checks/<sha>` (line 1 state, line 2 description) is the author's check evidence when no status exists.
- **Memory commits that replace instead of append.** e7ba0f5 overwrote the PR #39 raw-contents note in reviewer_environment.md (restored). **How to apply:** diff memory files in each PR for removed lines.
- **Protected-zone call:** `senior-mode check` and the pre-push template are the local CI (ADR 0006), so needs-human.

Added on PR #50 (2026-11-18, frame-guard hook for #36):
- **Guards that exempt the actor doing the work.** frame-guard skipped every subagent (`agent_id`), but frame delegates all writing to the `architect` subagent, so only the non-writing main conversation was guarded (blocking B1). **How to apply:** for every new guard, list which agent actually performs the guarded action in that workflow (skill steps + agents' `tools:`), and check the exemption list against it.
- **Deny reasons that hand the model the off switch.** The deny text told the model to run `senior-mode frame end`, which it can do itself via Bash. **How to apply:** escape hatches in deny reasons should be addressed to the user (`!` prefix, another command), not runnable by the model.
- **GNU-only tools in hooks** (`realpath -m`): failure yields an empty path and denies everything. Same "portability unstated" stance: non-blocking, propose a portable form.
- **Protected-zone call:** a new PreToolUse guard hook = security zone (`needs-human`), as with #31.

Added on PR #47 (2026-11-17, #46 pushed and re-reviewed):
- **Env-leak fix accepted pattern.** Unset the names from `git rev-parse --local-env-vars` inside the check subshell, after `root` and the record path are computed. Assert on named variables only (the caller may have GIT_EXEC_PATH, GIT_EDITOR, and so on). Known trade-off, not a finding: a repository used only through an explicit GIT_DIR (dotfiles) loses repo discovery in its checks.
- **The repository's own `.githooks/pre-push` is not the template.** It runs `senior-mode check` with `exec`. **How to apply:** for a fix in the template, check that `check()` gets it too, or this repository keeps the bug.

Added on PR #48 (2026-11-17, typescript preset renamed node):
- **Migrations that rename the key but keep the stored values.** The `typescript` to `node` migration rewrote `.preset`, but stored commands win over detection and checks are kept by name. So the old `npx tsc --noEmit` stayed on adopted projects, and the fix for the same issue did not reach them. **How to apply:** when a PR migrates stored config and fixes a generated value in the same PR, check that the migration also replaces values that are exactly the old generated default.

Added on PR #49 (2026-11-17, release manifest seed, follow-up of #40/#44):
- **Values copied from a user file into a strict consumer without a shape check.** The package.json `.version` went into `.release-please-manifest.json` as is. release-please `Version.parse` throws on non-semver, and `MinorVersionUpdate` keeps prerelease parts (`0.0.0-development` from semantic-release gives `0.1.0-development`). **How to apply:** when setup seeds a tool's state from project files, ask for a regex gate and a fallback to the neutral value.
- **Seeds gated on a file, not on the preset.** The package.json read also fed the `generic` (simple) preset. **How to apply:** check that stack-specific reads are keyed on `pname`.
- Third-party behaviour claims in PR bodies (release-please backfill from manifest) were true when checked at the pinned tag; keep checking at `RELEASE_PLEASE` from the bin, not the latest tag.

Added on PR #50 re-review (2026-11-18):
- **Dropping path resolution on one side only.** My N4 fix (remove `realpath -m`) left `root` from `git rev-parse --show-toplevel`, which is physical (it resolves symlinks), compared with a logical `file_path`. A symlinked project path or macOS `/var` (mktemp) then denies every docs/ write. **How to apply:** when a path check compares two paths, both must be normalised the same way. Ask for a test that uses a symlinked repo path.
- **All six findings fixed in one round, with tests**, plus the human-merge jq note. A PR that commits the reviewer memory files along with the feature is a human-merge note, not a finding.

Added on PR #52 (2026-11-18, release-please release PR for 0.1.0):
- **Release PR checklist that was enough to approve:** manifest, plugin.json `version`, CHANGELOG heading and config `initial-version` agree; no tag or release exists yet (first release uses `initial-version` without a bump); every feat/fix on main touching the package path is listed, and commits that only touch root files (`release-please-config.json`) are rightly left out; CHANGELOG date is the UTC date. The plugin.json reformat (arrays expanded) by the JSON updater is not a finding. Tag `senior-mode--v<x>` is deliberate (636c9c3).
- **Generated bodies cannot carry `Spec-Unchanged:`.** When the spec 12 drift check lands, it must exempt `autorelease: pending` PRs. Not a finding on the release PR itself.
- **Count before you post.** I first wrote 26 fixes instead of 24 and had to PATCH the comment. Piping `gh api --jq 'sub(...)'` into `gh api -X PATCH -F body=@-` works for such corrections.

Added on PR #53 (2026-11-18, ci.mode actions workflow + local-mode workflow disabling, #32):
- **"All workflows" lists include GitHub's dynamic ones.** `gh workflow list --all` (REST) returns `dynamic/...` paths (Dependabot Updates, Dependency Graph, Copilot review/agent, pages-build-deployment) as active; checked live on cli/cli. Default `--limit` is 50. **How to apply:** any bulk workflow action must filter `.path | startswith(".github/workflows/")` and pass a limit.
- **Shell loops that re-implement `check()`.** `while read ... done < <(jq ... @tsv)` with `bash -c "$run"`: the check eats the loop's stdin, @tsv doubles backslashes and escapes newlines, and a jq failure gives zero iterations, which reads as success. **How to apply:** ask for index iteration like `check()`, `</dev/null`, and a failure when the count is zero.
- **Status descriptions over 140 chars** are refused by the statuses API; `check()` cuts them, new posters must too.
- **Disruptive defaults missing from the setup consent table.** The default local mode disables every workflow, but the setup skill's "what will change" table did not say so, and a rerun undoes the advertised `gh workflow enable`. **How to apply:** for each new GitHub-side effect of setup, check that the skill's consent step lists it.
- Protected-zone call: workflow template + code that disables workflows = CI zone (`needs-human`, status failure while blocking findings remain).

Added on PR #53 re-review (2026-11-18, ci.mode actions workflow for #32):
- **A fix to a printed "way back" can drop the half that still works.** My B3 asked to say that a rerun disables workflows again; the fix replaced `gh workflow enable <name>` with "until ci.mode actions", but actions mode only re-enables its own workflow. **How to apply:** when a message tells the user how to undo something, check that the named step actually undoes it for every case, not only for the tool's own files.
- **Accepted test pattern for workflow templates:** extract the `run:` block of a step with awk from the template and run it against fixtures (exit code plus `$GITHUB_ENV` contents). It pins the real step, not a copy.
- **Protected-zone call:** workflow template plus code that disables workflows on GitHub = CI zone (`needs-human`, status pending), as with #43.

Added on PR #57 (2026-11-18, release job in the actions workflow + default-branch push filter, #55/#56):
- **Write jobs under a workflow-wide `cancel-in-progress: true`.** The concurrency group is per ref, so back-to-back merges on main cancel a running release-please and skip the `!cancelled()` status step. **How to apply:** when a PR adds a job that writes (release, deploy, tag), ask for `cancel-in-progress: ${{ github.event_name == 'pull_request' }}`.
- **Fixed-string greps that match more than one job.** The `github.ref_name == ...default_branch` grep was satisfied by the new release job's `if:`, so the checks job's condition (the AC under test) was unpinned. **How to apply:** for template greps, check the string occurs only in the place the AC is about.
- **New automation in one mode, old manual instruction left for all modes.** `agents/ops.md` still said `senior-mode release` after merges, which races the Actions release job in actions mode. **How to apply:** when a mode gains an automated step, grep agents and skills for the manual command it replaces.
- Protected-zone call: workflow template with a new `contents: write` job = CI zone (`needs-human`, status pending; no blocking findings).

Added on PR #65 (2026-11-18, CONTRIBUTING/SECURITY/CoC, two rounds):
- **Contributor docs written from the owner's seat.** The first draft assumed push access to upstream (`publish` posts to origin, so from a fork it writes to the fork). **How to apply:** for any contributor-facing doc, walk it as an outside contributor with a fork and no write access.
- **"Maintainer reruns the checks on your PR" runs untrusted code.** The check list (`.claude/senior-mode.json`) and `test-*.sh` come from the checked-out PR tree, with the maintainer's gh token. Flagged non-blocking (N2): ask for "reads the diff first". **How to apply:** any process doc or skill that runs a fork PR's checks locally must say to read the diff first.
- Docs-only community files = no protected zone (no `needs-human`); approved with status success.

Added on PR #57 re-review (2026-11-18, release job in the Actions workflow, #55/#56):
- **Docs tied to a warning that prints in one case only.** The setup skill relayed "the release PR needs a token to get CI" only when setup printed `releases:`, which happens only when Actions may not open PRs. The common case (allowed, no token) got no note, yet the release PR still gets no `senior-mode/ci`. **How to apply:** when a doc hangs advice on a printed line, list every state that needs the advice and check the line prints in each of them.
- **Accepted pattern for workflow-level concurrency with a releasing job:** `cancel-in-progress: ${{ github.event_name == 'pull_request' }}`. PR runs (`refs/pull/N/merge`) and push runs never share a group. A queued push run is still replaced by a newer one, which is harmless because the next release-please run covers it.
- Protected-zone call unchanged: workflow template = CI zone (`needs-human`, status pending).
