#!/usr/bin/env bash
# Tests for `senior-mode setup repo` and the git hooks it installs. Offline: no GitHub call.
set -u
cli=$(cd "$(dirname "$0")/.." && pwd)/senior-mode
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }
setup() { # dir [args...]
  local dir=$1
  shift
  (cd "$dir" && "$cli" setup repo "$@") >"$work/out" 2>"$work/err" || fail "setup exited non-zero: $(cat "$work/err")"
}
snapshot() { (cd "$1" && find . -path ./.git -prune -o -type f -print0 | sort -z | xargs -0 sha1sum; git config core.hooksPath); }
commit() { git -C "$1" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "$2" "${@:3}" 2>"$work/err"; }

# A new repository, French project.
new="$work/app"
git init -q -b main "$new"
mkdir -p "$new/.claude"
echo '{"language": "fr"}' >"$new/.claude/senior-mode.json"
setup "$new" --command test="true" --command lint="true"
[ "$(grep -c '^secrets: ' "$work/out")" -eq 1 ] || fail "no one-line secrets advice: $(cat "$work/out")"
grep '^secrets: ' "$work/out" | grep -q "dev-only" || fail "advice does not say agent machines hold dev-only secrets"
for f in CLAUDE.md .githooks/commit-msg .githooks/pre-push .github/pull_request_template.md \
  .github/ISSUE_TEMPLATE/feature.yml .github/ISSUE_TEMPLATE/bug.yml .claude/settings.json \
  release-please-config.json .release-please-manifest.json; do
  [ -f "$new/$f" ] || fail "$f not created"
done
[ -e "$new/.github/workflows/senior-mode.yml" ] && fail "workflow written in local CI mode"
[ "$(wc -l <"$new/CLAUDE.md")" -le 80 ] || fail "CLAUDE.md longer than 80 lines"
grep -q '^## Principes' "$new/CLAUDE.md" || fail "CLAUDE.md without its Principles section in French"
grep -q '^# app' "$new/CLAUDE.md" || fail "CLAUDE.md not titled with the repository name"
grep -q "environnements de développement.*envGuard" "$new/CLAUDE.md" || fail "French Principles without the development-environments line"
grep -q '^## Vue d.ensemble' "$new/docs/architecture.md" 2>/dev/null || fail "docs/architecture.md not created in the project language: $(cat "$work/out")"
grep -q 'docs/architecture.md: created' "$work/out" || fail "architecture overview not reported: $(cat "$work/out")"
grep -qi 'Ce que ça apporte' "$new/.github/pull_request_template.md" || fail "PR template not in the project language"
grep -q '^## .*New shared code' "$new/.github/pull_request_template.md" || fail "PR template without its New shared code section (#487)"
grep -q '^## New shared code' "$(dirname "$cli")/../templates/en/pull_request_template.md" || fail "English PR template without its New shared code section (#487)"
[ -x "$new/.githooks/commit-msg" ] && [ -x "$new/.githooks/pre-push" ] || fail "git hooks not executable"
[ "$(git -C "$new" config core.hooksPath)" = .githooks ] || fail "core.hooksPath not set"
jq -e '.permissions.allow | index("Bash(senior-mode:*)")' "$new/.claude/settings.json" >/dev/null ||
  fail "settings without senior-mode allowed"
jq -e '.permissions.deny | index("Bash(git push --force:*)")' "$new/.claude/settings.json" >/dev/null ||
  fail "settings without force-push denied"
[ "$(jq -c '[.checks[].name]' "$new/.claude/senior-mode.json")" = '["lint","test","commit subjects"]' ] ||
  fail "checks not derived from the commands: $(jq -c .checks "$new/.claude/senior-mode.json")"
[ "$(jq -r '.preset + "/" + .language + "/" + .commands.test' "$new/.claude/senior-mode.json")" = generic/fr/true ] ||
  fail "config keys lost or commands not stored: $(cat "$new/.claude/senior-mode.json")"
jq -e '.packages["."].component == "app"' "$new/release-please-config.json" >/dev/null ||
  fail "release-please component is not the repository name"
jq -e '.packages["."]["initial-version"] == "0.1.0"' "$new/release-please-config.json" >/dev/null ||
  fail "a new project's first release is not 0.1.0"

jq -e '.protected | index("**/migrations/**") and index(".github/workflows/**") and index("**/secrets/**") and index(".claude/secret-allowlist") and index(".claude/ratchet-baseline.json") and index(".claude/architecture-baseline.json")' \
  "$new/.claude/senior-mode.json" >/dev/null || fail "generic preset without protected zones: $(jq -c .protected "$new/.claude/senior-mode.json")"

# `setup repo` writes `protected`, after `setup github` ran on a first setup: with globs and no
# managed CODEOWNERS block it says to rerun `setup github`, and it says it again on a rerun.
grep -q "CODEOWNERS: the protected zones are not owned yet; rerun senior-mode setup github" "$work/out" ||
  fail "no word that setup github must be rerun: $(cat "$work/out")"

# The agents' project memory is git-ignored: written in the checkout, it must not leave it dirty.
git -C "$new" check-ignore -q .claude/agent-memory/reviewer/MEMORY.md || fail "agent memory not ignored"
grep -q '^.gitignore: .claude/agent-memory/ ignored' "$work/out" || fail "ignore not reported: $(cat "$work/out")"

# The decision log merges as a union (#639): parallel framings that each log a decision do not conflict. An existing
# .gitattributes is extended, and a rerun adds nothing.
[ "$(git -C "$new" check-attr merge -- docs/decisions.md | sed 's/.*: //')" = union ] || fail "setup did not set merge=union on docs/decisions.md: $(cat "$new/.gitattributes" 2>&1)"
grep -q '^.gitattributes: docs/decisions.md merges as a union' "$work/out" || fail "union not reported: $(cat "$work/out")"
printf '*.png binary' >"$new/.gitattributes"
setup "$new"
[ "$(cat "$new/.gitattributes")" = "$(printf '*.png binary\ndocs/decisions.md merge=union')" ] || fail ".gitattributes not extended: $(cat "$new/.gitattributes")"
setup "$new"
[ "$(grep -c 'docs/decisions.md' "$new/.gitattributes")" -eq 1 ] || fail "rerun duplicated the attribute: $(cat "$new/.gitattributes")"

# docs/vision.md is the owner's (#342): setup repo proposes to protect it while no glob of `protected` covers it,
# and says nothing once one does (the generic preset's globs do not).
grep -q "docs/vision.md: add it to protected" "$work/out" || fail "no proposal to protect docs/vision.md: $(cat "$work/out")"
jq '.protected += ["docs/vision.md"]' "$new/.claude/senior-mode.json" >"$work/c" && mv "$work/c" "$new/.claude/senior-mode.json"
setup "$new" --command test="true" --command lint="true"
grep -q "docs/vision.md" "$work/out" && fail "protection proposed again once docs/vision.md is protected: $(cat "$work/out")"
jq '.protected -= ["docs/vision.md"]' "$new/.claude/senior-mode.json" >"$work/c" && mv "$work/c" "$new/.claude/senior-mode.json"
setup "$new" --command test="true" --command lint="true"
grep -q "docs/vision.md: add it to protected" "$work/out" || fail "proposal lost when the glob is removed: $(cat "$work/out")"
jq '.protected = ["docs/**"]' "$new/.claude/senior-mode.json" >"$work/c" && mv "$work/c" "$new/.claude/senior-mode.json"
setup "$new" --command test="true" --command lint="true"
grep -q "docs/vision.md" "$work/out" && fail "protection proposed although docs/** covers it: $(cat "$work/out")"
jq '.protected = []' "$new/.claude/senior-mode.json" >"$work/c" && mv "$work/c" "$new/.claude/senior-mode.json"
setup "$new" --command test="true" --command lint="true"
grep -q "docs/vision.md: add it to protected" "$work/out" || fail "an empty protected list is not proposed docs/vision.md: $(cat "$work/out")"
jq 'del(.protected)' "$new/.claude/senior-mode.json" >"$work/c" && mv "$work/c" "$new/.claude/senior-mode.json"
setup "$new" --command test="true" --command lint="true"

# Second run: nothing changes.
before=$(snapshot "$new")
setup "$new" --command test="true" --command lint="true"
[ "$(snapshot "$new")" = "$before" ] || fail "second run changed files"
grep -q "rerun senior-mode setup github" "$work/out" || fail "rerun forgets to say setup github must be rerun"
mkdir -p "$new/.github"
printf '# senior-mode:begin\n# senior-mode:end\n' >"$new/.github/CODEOWNERS"
setup "$new" --command test="true" --command lint="true"
grep -q "CODEOWNERS" "$work/out" && fail "CODEOWNERS advice although the managed block exists: $(cat "$work/out")"
rm -rf "$new/.github/CODEOWNERS"
before=$(snapshot "$new")

# The commit-msg hook.
commit "$new" "mise à jour" && fail "non-conventional commit accepted"
grep -q "Conventional Commit" "$work/err" || fail "refusal does not say why: $(cat "$work/err")"
commit "$new" "feat(ui): add the menu" || fail "conventional commit refused: $(cat "$work/err")"
commit "$new" "fixup! feat(ui): add the menu" || fail "fixup commit refused"
printf 'feat: ok\nbad subject\n' | "$new/.githooks/commit-msg" --subjects 2>/dev/null && fail "--subjects accepts a bad subject"
printf 'fixup! feat: x\n' | "$new/.githooks/commit-msg" --subjects 2>/dev/null &&
  fail "--subjects accepts a fixup commit, which a rebase merge would land as is"
for s in "fix(hooks): deny force-push" "feat(api)!: drop v1 config" "docs(adr): record decisions 0001-0005" \
  "$(printf 'chore: one\nci: two')"; do
  printf '%s\n' "$s" | "$new/.githooks/commit-msg" --subjects 2>/dev/null || fail "--subjects refuses: $s"
done
for s in "feat:missing space" "feature: unknown type" "feat(): empty scope" "$(printf 'feat: fine\nwip')"; do
  printf '%s\n' "$s" | "$new/.githooks/commit-msg" --subjects 2>/dev/null && fail "--subjects accepts: $s"
done

# The commit subjects check reads the branch against the default branch, whatever its name.
check_subjects() { (cd "$new" && bash -c "$(jq -r '.checks[] | select(.name == "commit subjects") | .run' .claude/senior-mode.json)") 2>&1; }
check_subjects >/dev/null && fail "commit subjects passes a branch with a fixup commit, without remote"
git init -q --bare "$work/origin.git"
git -C "$new" remote add origin "$work/origin.git"
git -C "$new" branch -q -m main master
git -C "$new" push -q --no-verify origin master >/dev/null 2>&1
commit "$new" "pas conventionnel" --no-verify
check_subjects >"$work/out" && fail "commit subjects passes a bad subject on a master-based repository: $(cat "$work/out")"
grep -q "pas conventionnel" "$work/out" || fail "commit subjects checked the wrong range: $(cat "$work/out")"
git -C "$new" reset -q --hard origin/master
check_subjects >"$work/out" || fail "commit subjects fails on a clean branch: $(cat "$work/out")"

# A re-run with a changed command updates its check; an unknown command name is refused.
setup "$new" --command test="echo changed"
[ "$(jq -r '.checks[] | select(.name == "test") | .run' "$new/.claude/senior-mode.json")" = "echo changed" ] ||
  fail "changed command not applied to its check"
(cd "$new" && "$cli" setup repo --command tests="x") >/dev/null 2>&1 && fail "unknown command name accepted"

# A bare re-run keeps a derived check edited by hand.
jq '(.checks[] | select(.name == "test") | .run) = "echo changed --coverage" | (.checks[] | select(.name == "test")).timeout = 5' \
  "$new/.claude/senior-mode.json" >"$work/c" && mv "$work/c" "$new/.claude/senior-mode.json"
setup "$new"
[ "$(jq -c '.checks[] | select(.name == "test") | [.run, .timeout]' "$new/.claude/senior-mode.json")" = '["echo changed --coverage",5]' ] ||
  fail "bare re-run reverted a check edited by hand"

# A .gitignore of the project's own is extended, not replaced, and a rule that already covers the path is kept.
printf 'node_modules' >"$new/.gitignore"
setup "$new"
[ "$(cat "$new/.gitignore")" = "$(printf 'node_modules\n.claude/agent-memory/')" ] || fail "existing .gitignore not extended: $(cat "$new/.gitignore")"
printf '.claude/\n' >"$new/.gitignore"
setup "$new"
[ "$(cat "$new/.gitignore")" = ".claude/" ] || fail ".gitignore rewritten although .claude/ already covers the memory"

# A hook that lost its exec bit is repaired.
chmod -x "$new/.githooks/pre-push"
setup "$new"
[ -x "$new/.githooks/pre-push" ] || fail "hook without exec bit not repaired"

# The pre-push hook runs the configured checks, without senior-mode on the PATH.
nopath=$(tr : '\n' <<<"$PATH" | grep -v senior-mode | paste -sd: -)
(cd "$new" && PATH=$nopath .githooks/pre-push </dev/null) >"$work/out" 2>&1 ||
  fail "pre-push fails on passing checks: $(cat "$work/out")"
jq '.checks[0].run = "env | grep -E \"^GIT_(DIR|WORK_TREE)=\" && exit 1; true"' "$new/.claude/senior-mode.json" >"$work/c" && mv "$work/c" "$new/.claude/senior-mode.json"
(cd "$new" && GIT_DIR="$new/.git" GIT_WORK_TREE="$new" .githooks/pre-push </dev/null) >"$work/out" 2>&1 ||
  fail "pre-push leaks git's hook environment to the checks: $(cat "$work/out")"
jq '.checks[0].run = "echo boom; false"' "$new/.claude/senior-mode.json" >"$work/c" && mv "$work/c" "$new/.claude/senior-mode.json"
(cd "$new" && .githooks/pre-push </dev/null) >"$work/out" 2>&1 && fail "pre-push passes a failing check"
grep -q boom "$work/out" || fail "pre-push hides the failing output"
grep -Eq '^FAIL  [^ ]+.* \([0-9]+\.[0-9]s\)$' "$work/out" || fail "pre-push does not show the time of a check: $(cat "$work/out")"

# With senior-mode on the PATH the hook runs `check --changed` (#827); without it, the list above.
mkdir -p "$work/sm-stub"
printf '#!/usr/bin/env bash\necho "senior-mode $*" >"%s"\n' "$work/sm-called" >"$work/sm-stub/senior-mode"
chmod +x "$work/sm-stub/senior-mode"
(cd "$new" && PATH="$work/sm-stub:$nopath" .githooks/pre-push </dev/null) >"$work/out" 2>&1 || fail "pre-push with senior-mode on the PATH fails: $(cat "$work/out")"
[ "$(cat "$work/sm-called" 2>/dev/null)" = "senior-mode check --changed" ] || fail "pre-push does not run check --changed: $(cat "$work/sm-called" 2>/dev/null)"

# The hook tells the checks which paths the push changes (SENIOR_MODE_CHANGED_FILES) from the lines git gives
# it; when it cannot work them out, no list, so a check runs in full.
sc="$work/scoped"
git init -q -b main "$sc"
mkdir -p "$sc/.claude" "$sc/.githooks"
cp "$new/.githooks/pre-push" "$sc/.githooks/pre-push"
jq -n --arg out "$work/seen" '{checks: [{name: "seen", run: ("if [ -n \"${SENIOR_MODE_CHANGED_FILES:-}\" ]; then cat \"$SENIOR_MODE_CHANGED_FILES\"; else echo FULL; fi >" + $out)}]}' \
  >"$sc/.claude/senior-mode.json"
git -C "$sc" add -A
git -C "$sc" -c user.name=t -c user.email=t@t commit -q -m "chore: start"
first=$(git -C "$sc" rev-parse HEAD)
mkdir "$sc/a" && echo x >"$sc/a/one.txt" && echo x >"$sc/two.txt"
git -C "$sc" add -A
git -C "$sc" -c user.name=t -c user.email=t@t commit -q -m "feat: two"
last=$(git -C "$sc" rev-parse HEAD)
push() { (cd "$sc" && printf '%s\n' "$1" | .githooks/pre-push) >"$work/out" 2>&1 || fail "pre-push fails: $(cat "$work/out")"; }
push "refs/heads/main $last refs/heads/main $first"
[ "$(sort "$work/seen" | paste -sd' ')" = "a/one.txt two.txt" ] || fail "pre-push: changed paths of an update: $(cat "$work/seen")"
push "refs/heads/main $last refs/heads/main 1111111111111111111111111111111111111111"
[ "$(cat "$work/seen")" = FULL ] || fail "pre-push: an unknown remote commit did not mean a full run: $(cat "$work/seen")"
push "refs/heads/new $last refs/heads/new 0000000000000000000000000000000000000000"
[ "$(cat "$work/seen")" = FULL ] || fail "pre-push: a new branch with no base did not mean a full run: $(cat "$work/seen")"
(cd "$sc" && .githooks/pre-push </dev/null) >"$work/out" 2>&1
[ "$(cat "$work/seen")" = FULL ] || fail "pre-push: no pushed ref did not mean a full run: $(cat "$work/seen")"

# A check with `tier: 3` is skipped by the hook, which says so; a tier that is not 2 or 3 stops it (spec 474 §2).
jq -n --arg out "$work/tiered" '{checks: [{name: "two", run: ("echo two >>" + $out)}, {name: "slow", tier: 3, run: ("echo slow >>" + $out)}]}' \
  >"$sc/.claude/senior-mode.json"
rm -f "$work/tiered"
(cd "$sc" && .githooks/pre-push </dev/null) >"$work/out" 2>&1 || fail "pre-push fails with a tier 3 check: $(cat "$work/out")"
[ "$(cat "$work/tiered")" = two ] || fail "pre-push runs a tier 3 check: $(cat "$work/tiered")"
grep -qx 'heavy: slow runs after the push' "$work/out" || fail "pre-push does not say that the tier 3 check is deferred: $(cat "$work/out")"
jq '.checks[1].tier = 4' "$sc/.claude/senior-mode.json" >"$work/c" && mv "$work/c" "$sc/.claude/senior-mode.json"
(cd "$sc" && .githooks/pre-push </dev/null) >"$work/out" 2>&1 && fail "pre-push accepts tier 4"
grep -q 'checks\[1\].tier must be 2 or 3, not 4' "$work/out" || fail "pre-push error does not name the key: $(cat "$work/out")"

# The query-count helper of the project's ORM (spec 472): offered at the preset's path, recorded as
# performance.queries.helper, never over an existing file; no supported ORM, nothing and `queries: not measured`.
orm_repo() { # name, then the manifest file and its content
  local d="$work/orm-$1"
  git init -q -b main "$d"
  mkdir -p "$d/.claude"
  echo '{}' >"$d/.claude/senior-mode.json"
  printf '%s\n' "$3" >"$d/$2"
  printf '%s' "$d"
}
helper_key() { jq -r '.performance.queries.helper // "none"' "$1/.claude/senior-mode.json"; }
pr=$(orm_repo prisma package.json '{"name":"p","devDependencies":{"prisma":"6.0.0"}}')
setup "$pr"
grep -q '^queries: prisma helper test/support/query-count.ts: created$' "$work/out" || fail "prisma helper not offered: $(grep '^queries' "$work/out")"
cmp -s "$pr/test/support/query-count.ts" "$(dirname "$cli")/../presets/node/queries/prisma.ts" || fail "prisma helper is not the preset's"
[ "$(helper_key "$pr")" = test/support/query-count.ts ] || fail "prisma helper path not recorded: $(helper_key "$pr")"
echo '// mine' >"$pr/test/support/query-count.ts"
setup "$pr"
grep -q '^queries: helper kept at test/support/query-count.ts$' "$work/out" || fail "a recorded helper is not kept: $(grep '^queries' "$work/out")"
[ "$(cat "$pr/test/support/query-count.ts")" = '// mine' ] || fail "an existing helper was overwritten"
pr=$(orm_repo prisma2 package.json '{"name":"p","dependencies":{"@prisma/client":"6.0.0"}}')
mkdir -p "$pr/test/support" && echo '// mine' >"$pr/test/support/query-count.ts"
setup "$pr"
[ "$(cat "$pr/test/support/query-count.ts")" = '// mine' ] || fail "a helper at the default path, not recorded yet, was overwritten"
grep -q '^queries: prisma helper test/support/query-count.ts: kept$' "$work/out" || fail "existing file at the helper path not reported: $(grep '^queries' "$work/out")"
[ "$(helper_key "$pr")" = test/support/query-count.ts ] || fail "path of an existing helper not recorded"
pr=$(orm_repo prisma3 package.json '{"name":"p","dependencies":{"@prisma/client":"6.0.0"}}')
jq '.performance.queries.helper = "spec/db-helper.ts"' "$pr/.claude/senior-mode.json" >"$work/c" && mv "$work/c" "$pr/.claude/senior-mode.json"
setup "$pr"
[ ! -e "$pr/test/support/query-count.ts" ] || fail "a helper written although the config names another"
[ "$(helper_key "$pr")" = spec/db-helper.ts ] || fail "a configured helper path was changed"
pr=$(orm_repo sqla pyproject.toml $'[project]\nname = "x"\ndependencies = ["SQLAlchemy[asyncio]>=2"]')
setup "$pr"
cmp -s "$pr/tests/query_count.py" "$(dirname "$cli")/../presets/python/queries/sqlalchemy.py" || fail "sqlalchemy helper not offered: $(grep '^queries' "$work/out")"
[ "$(helper_key "$pr")" = tests/query_count.py ] || fail "sqlalchemy helper path not recorded"
pr=$(orm_repo django requirements.txt $'Django==5.0\npytest')
setup "$pr"
cmp -s "$pr/tests/query_count.py" "$(dirname "$cli")/../presets/python/queries/django.py" || fail "django helper not offered: $(grep '^queries' "$work/out")"
pr=$(orm_repo sqlx Cargo.toml $'[package]\nname = "x"\n\n[dependencies]\nsqlx = { version = "0.8", features = ["sqlite"] }')
setup "$pr"
cmp -s "$pr/tests/support/query_count.rs" "$(dirname "$cli")/../presets/rust/queries/sqlx.rs" || fail "sqlx helper not offered: $(grep '^queries' "$work/out")"
[ "$(helper_key "$pr")" = tests/support/query_count.rs ] || fail "sqlx helper path not recorded"
pr=$(orm_repo plainpy pyproject.toml $'[project]\nname = "x"\ndependencies = ["requests", "django-environ"]')
setup "$pr"
grep -q '^queries: not measured' "$work/out" || fail "no ORM did not report not measured: $(cat "$work/out")"
[ "$(helper_key "$pr")" = none ] && [ ! -e "$pr/tests/query_count.py" ] || fail "something was offered with no supported ORM"
pr=$(orm_repo plainnode package.json '{"name":"p","dependencies":{"drizzle-orm":"1"}}')
setup "$pr"
grep -q '^queries: not measured' "$work/out" || fail "an unsupported ORM did not report not measured: $(cat "$work/out")"
[ ! -e "$pr/test" ] || fail "something was offered for an unsupported ORM"

# An existing repository: its own CLAUDE.md, settings, PR template, hooks path and checks are extended.
old="$work/legacy"
git init -q -b main "$old"
mkdir -p "$old/.claude" "$old/.github"
printf '# Legacy\n\n## Commands\n- make test\n' >"$old/CLAUDE.md"
echo '{"permissions": {"allow": ["Bash(make:*)"]}, "model": "opus"}' >"$old/.claude/settings.json"
echo 'Our template' >"$old/.github/PULL_REQUEST_TEMPLATE.md"
echo '{"checks": [{"name": "make", "run": "make test"}]}' >"$old/.claude/senior-mode.json"
git -C "$old" config core.hooksPath .husky
setup "$old"
head -4 "$old/CLAUDE.md" | grep -q '^- make test' || fail "existing CLAUDE.md content not kept"
grep -q '^## Principles' "$old/CLAUDE.md" || fail "Principles not appended to the existing CLAUDE.md"
grep -q '^## Code map' "$old/CLAUDE.md" && fail "skeleton added to an existing CLAUDE.md"
grep -q 'development environments only.*envGuard' "$old/CLAUDE.md" || fail "Principles without the development-environments line"
[ "$(jq -c '[.permissions.allow[0], .model]' "$old/.claude/settings.json")" = '["Bash(make:*)","opus"]' ] ||
  fail "existing settings not kept: $(cat "$old/.claude/settings.json")"
[ "$(cat "$old/.github/PULL_REQUEST_TEMPLATE.md")" = 'Our template' ] || fail "existing PR template replaced"
[ -f "$old/.github/pull_request_template.md" ] && fail "second PR template created"
[ "$(git -C "$old" config core.hooksPath)" = .husky ] || fail "existing hooks path replaced"
grep -q '^## Overview' "$old/docs/architecture.md" 2>/dev/null || fail "docs/architecture.md not created in English"
grep -q husky "$work/out" || fail "custom hooks path not reported: $(cat "$work/out")"
[ "$(jq -c '[.checks[].name]' "$old/.claude/senior-mode.json")" = '["make","commit subjects"]' ] ||
  fail "existing checks not extended: $(jq -c .checks "$old/.claude/senior-mode.json")"
before=$(snapshot "$old")
setup "$old"
[ "$(snapshot "$old")" = "$before" ] || fail "second run on an existing repository changed files"

# An existing architecture document is never touched.
echo 'Our architecture' >"$old/docs/architecture.md"
setup "$old"
[ "$(cat "$old/docs/architecture.md")" = 'Our architecture' ] || fail "existing docs/architecture.md replaced"
grep -q 'docs/architecture.md: kept' "$work/out" || fail "kept architecture overview not reported: $(cat "$work/out")"

# Updated Principles replace the old block, nothing else.
sed -i 's/^## Principles/## Old principles/' "$old/CLAUDE.md"
setup "$old"
grep -q '^## Old principles' "$old/CLAUDE.md" && fail "outdated Principles block not refreshed"
[ "$(grep -c 'senior-mode:principles' "$old/CLAUDE.md")" = 2 ] || fail "Principles block duplicated"

# Broken markers: the file is left alone, the user's text after the block survives.
echo '## Our notes' >>"$old/CLAUDE.md"
sed -i '/\/senior-mode:principles/d; s/^## Principles/## Old principles/' "$old/CLAUDE.md"
setup "$old"
grep -q '^## Our notes' "$old/CLAUDE.md" || fail "user text after a broken Principles block deleted"
grep -qi 'markers' "$work/out" || fail "broken Principles markers not reported: $(cat "$work/out")"

# Markers in the wrong order: left untouched too.
printf '# Swapped\n<!-- /senior-mode:principles -->\n<!-- senior-mode:principles -->\n## Mine\n' >"$old/CLAUDE.md"
setup "$old"
grep -q '^## Mine' "$old/CLAUDE.md" || fail "user text after swapped Principles markers deleted"

# A long CLAUDE.md is reported.
seq 90 >>"$old/CLAUDE.md"
setup "$old"
grep -q 'over 80' "$work/out" || fail "CLAUDE.md over 80 lines not reported: $(cat "$work/out")"

# The repository name is plain text in the CLAUDE.md title.
rd="$work/R&D"
git init -q -b main "$rd"
setup "$rd"
grep -qx '# R&D' "$rd/CLAUDE.md" || fail "repository name with & mangled: $(head -1 "$rd/CLAUDE.md")"

# A repository with an AGENTS.md (scaffolded by a framework): the new CLAUDE.md points to it, no skeleton.
ag="$work/agents"
git init -q -b main "$ag"
printf '# Agents\nRun npm test.\n' >"$ag/AGENTS.md"
setup "$ag"
grep -qx '@AGENTS.md' "$ag/CLAUDE.md" || fail "CLAUDE.md does not import AGENTS.md: $(cat "$ag/CLAUDE.md")"
grep -q '^## Code map' "$ag/CLAUDE.md" && fail "skeleton duplicated next to AGENTS.md"
grep -q '^## Principles' "$ag/CLAUDE.md" || fail "Principles missing from the CLAUDE.md pointing to AGENTS.md"
grep -qx '# agents' "$ag/CLAUDE.md" || fail "CLAUDE.md not titled with the repository name"
grep -q 'to fill' "$work/out" && fail "setup asks to fill a skeleton that is not there: $(cat "$work/out")"
grep -q 'AGENTS.md' "$work/out" || fail "AGENTS.md not reported: $(cat "$work/out")"
[ "$(cat "$ag/AGENTS.md")" = "$(printf '# Agents\nRun npm test.')" ] || fail "AGENTS.md changed"

# commit subjects: nothing to check without commits; a remote without a known default branch fails
# and says how to fix it, instead of reading the whole history.
(cd "$rd" && .githooks/commit-msg --branch) 2>"$work/err" || fail "--branch fails without commits: $(cat "$work/err")"
commit "$rd" "feat: first"
git init -q --bare "$work/trunk.git"
git -C "$rd" remote add origin "$work/trunk.git"
(cd "$rd" && .githooks/commit-msg --branch) 2>"$work/err" || fail "--branch blocks the first push to an empty origin: $(cat "$work/err")"
commit "$rd" "old style subject" --no-verify
git -C "$rd" push -q --no-verify origin HEAD:trunk >/dev/null 2>&1
(cd "$rd" && .githooks/commit-msg --branch) 2>"$work/err" && fail "--branch passes with an unknown default branch"
grep -q 'set-head' "$work/err" || fail "unknown default branch not explained: $(cat "$work/err")"

# CLAUDE.md as a symlink stays a symlink; an existing release manifest keeps its version.
own="$work/own"
git init -q -b main "$own"
printf '# Own\n<!-- senior-mode:principles -->\nold\n<!-- /senior-mode:principles -->\n' >"$own/AGENTS.md"
ln -s AGENTS.md "$own/CLAUDE.md"
echo '{".": "2.3.0"}' >"$own/.release-please-manifest.json"
mkdir -p "$own/.githooks"
printf '#!/bin/sh\nnpx commitlint --edit\n' >"$own/.githooks/commit-msg"
echo '{"packages": {".": {"release-type": "go"}}}' >"$own/release-please-config.json"
setup "$own"
[ "$(jq -c . "$own/release-please-config.json")" = '{"packages":{".":{"release-type":"go"}}}' ] ||
  fail "existing release-please config changed"
[ -L "$own/CLAUDE.md" ] || fail "CLAUDE.md symlink replaced by a file"
grep -q '^## Principles' "$own/AGENTS.md" || fail "Principles not refreshed through the CLAUDE.md symlink"
[ "$(jq -r '."."' "$own/.release-please-manifest.json")" = 2.3.0 ] || fail "existing release manifest reset"
jq -e '.checks | any(.name == "commit subjects")' "$own/.claude/senior-mode.json" >/dev/null &&
  fail "commit subjects check added although the project's commit-msg hook is its own"

# ci.mode actions: a workflow runs the config's checks on GitHub; an existing one is kept.
act="$work/act"
git init -q -b main "$act"
mkdir -p "$act/.claude" "$act/.github/workflows"
echo '{"ci": {"mode": "actions"}}' >"$act/.claude/senior-mode.json"
echo 'name: Theirs' >"$act/.github/workflows/ci.yml"
setup "$act"
wf=$act/.github/workflows/senior-mode.yml
[ -f "$wf" ] || fail "no workflow in actions mode: $(cat "$work/out")"
grep -q "workflow senior-mode.yml: created" "$work/out" || fail "workflow not reported: $(cat "$work/out")"
for want in "senior-mode/ci" ".claude/senior-mode.json" "dependency-review-action" "actions/cache" "statuses: write"; do
  grep -qF "$want" "$wf" 2>/dev/null || fail "workflow lacks $want"
done
[ "$(cat "$act/.github/workflows/ci.yml")" = "name: Theirs" ] || fail "an existing workflow was changed"
grep -qE 'branches: *\[' "$wf" && fail "workflow pushes limited to a hardcoded branch list"
[ "$(awk '/^  checks:/ { on = 1 } on && /^    if:/ { print; exit }' "$wf")" = \
  "    if: github.event_name == 'pull_request' || github.ref_name == github.event.repository.default_branch" ] ||
  fail "workflow checks pushes to branches other than the default one"
grep -qF "cancel-in-progress: \${{ github.event_name == 'pull_request' }}" "$wf" ||
  fail "a push to the default branch can cancel a release in progress"
for want in "googleapis/release-please-action@v4" "config-file: release-please-config.json" \
  "manifest-file: .release-please-manifest.json" "contents: write" "pull-requests: write" \
  'secrets.RELEASE_PLEASE_TOKEN || github.token'; do
  grep -qF "$want" "$wf" 2>/dev/null || fail "release job lacks $want"
done
grep -A1 -F "uses: googleapis/release-please-action" "$wf" |
  grep -qF "if: hashFiles('release-please-config.json') != ''" || fail "release-please runs without a config"
# The workflow's Checks step runs exactly the configured commands, all of them, and fails closed.
awk '/- name: Checks$/ { on = 1; next } on && /- name:/ { exit } on && /run: \|/ { body = 1; next }
  body { sub(/^          /, ""); print }' "$wf" >"$work/checks.sh"
runs() { # expected-exit config-json
  local d=$work/ci rc=0
  rm -rf "$d" && mkdir -p "$d/.claude" && echo "$2" >"$d/.claude/senior-mode.json" && printf 'a.b\n' >"$d/f"
  (cd "$d" && GITHUB_ENV=$d/env bash "$work/checks.sh") >/dev/null 2>&1 || rc=$?
  if [ "$1" = 0 ]; then [ "$rc" = 0 ]; else [ "$rc" != 0 ]; fi
}
runs 0 '{"checks": [{"name": "eats", "run": "cat >/dev/null"}, {"name": "next", "run": "touch ran"}]}' &&
  [ -f "$work/ci/ran" ] || fail "a check reading stdin swallows the next ones"
runs 0 '{"checks": [{"name": "re", "run": "grep -q '"'"'a\\.b'"'"' f"}]}' || fail "a backslash in a check is changed"
runs 1 '{"checks": []}' || fail "no checks reported as success"
runs 1 '{}' || fail "a config without checks reported as success"
runs 1 '{"checks": [{"name": "ok", "run": "true"}, {"name": "bad", "run": "false"}]}' || fail "a failing check passes"
grep -q '^FAILED=bad$' "$work/ci/env" 2>/dev/null || fail "failed checks not passed to the status step"
echo 'name: Mine' >"$wf"
setup "$act"
[ "$(cat "$wf")" = "name: Mine" ] || fail "an existing senior-mode workflow was replaced"
grep -q "workflow senior-mode.yml: kept" "$work/out" || fail "kept workflow not reported: $(cat "$work/out")"

# The language server of the stack is proposed, never installed, and not again once answered (#341).
for pair in "node:package.json:typescript-language-server:typescript-lsp" "python:pyproject.toml:pyright:pyright-lsp" \
  "go:go.mod:gopls:gopls-lsp" "rust:Cargo.toml:rust-analyzer:rust-analyzer-lsp"; do
  IFS=: read -r pname manifest server plugin <<<"$pair"
  d="$work/lsp-$pname"
  git init -q -b main "$d"
  if [ "$manifest" = package.json ]; then echo '{"name": "x"}' >"$d/$manifest"; else : >"$d/$manifest"; fi
  setup "$d"
  grep -q "^lsp: the language server for $pname is $server " "$work/out" || fail "$pname: no proposal: $(cat "$work/out")"
  grep -q "claude plugin install $plugin@claude-plugins-official" "$work/out" || fail "$pname: no enabling command"
  [ ! -e "$d/.lsp.json" ] || fail "$pname: setup wrote .lsp.json"
  [ "$(jq 'has("lsp")' "$d/.claude/senior-mode.json")" = false ] || fail "$pname: proposing recorded an answer"
  (cd "$d" && "$cli" setup answers --lsp no) >/dev/null 2>"$work/err" || fail "$pname: answers --lsp no: $(cat "$work/err")"
  [ "$(jq '.lsp' "$d/.claude/senior-mode.json")" = false ] || fail "$pname: lsp not recorded"
  setup "$d"
  ! grep -q '^lsp:' "$work/out" || fail "$pname: proposed again after an answer"
  (cd "$d" && "$cli" config validate) >/dev/null 2>&1 || fail "$pname: lsp key rejected by the schema"
done
d="$work/lsp-yes"
git init -q -b main "$d"
: >"$d/go.mod"
setup "$d"
(cd "$d" && "$cli" setup answers --lsp yes) >/dev/null 2>&1
[ "$(jq '.lsp' "$d/.claude/senior-mode.json")" = true ] || fail "lsp yes not recorded"
setup "$d"
! grep -q '^lsp:' "$work/out" || fail "proposed again after yes"
(cd "$d" && "$cli" setup answers --lsp maybe) >/dev/null 2>&1 && fail "accepted an unknown lsp answer"
d="$work/lsp-generic"
git init -q -b main "$d"
setup "$d"
! grep -q '^lsp:' "$work/out" || fail "generic preset got a language server proposal"

# `setup repo --hooks` writes the hooks and nothing else (#608).
hk="$work/hooks"
git init -q -b main "$hk"
setup "$hk" --hooks
[ -x "$hk/.githooks/commit-msg" ] && [ -x "$hk/.githooks/pre-push" ] || fail "--hooks: hooks not installed: $(cat "$work/out")"
[ "$(git -C "$hk" config core.hooksPath)" = .githooks ] || fail "--hooks: core.hooksPath not set"
[ "$(cd "$hk" && find . -path ./.git -prune -o -type f -print | sort | tr '\n' ' ')" = "./.githooks/commit-msg ./.githooks/pre-push " ] ||
  fail "--hooks wrote more than the hooks: $(cd "$hk" && find . -path ./.git -prune -o -type f -print)"
rm "$hk/.githooks/pre-push"
setup "$hk" --hooks
[ -x "$hk/.githooks/pre-push" ] || fail "--hooks: a missing hook is not refreshed"
(cd "$hk" && "$cli" setup repo --hooks --dry-run) >/dev/null 2>&1 && fail "--hooks accepted with another option"

[ "$failures" -eq 0 ] && echo "setup-repo: all cases pass"
exit "$failures"
