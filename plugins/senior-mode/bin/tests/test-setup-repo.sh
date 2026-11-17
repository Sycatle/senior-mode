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
commit() { git -C "$1" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "$2" 2>"$work/err"; }

# A new repository, French project.
new="$work/app"
git init -q -b main "$new"
mkdir -p "$new/.claude"
echo '{"language": "fr"}' >"$new/.claude/senior-mode.json"
setup "$new" --command test="true" --command lint="true"
for f in CLAUDE.md .githooks/commit-msg .githooks/pre-push .github/pull_request_template.md \
  .github/ISSUE_TEMPLATE/feature.yml .github/ISSUE_TEMPLATE/bug.yml .claude/settings.json \
  release-please-config.json .release-please-manifest.json; do
  [ -f "$new/$f" ] || fail "$f not created"
done
[ "$(wc -l <"$new/CLAUDE.md")" -le 80 ] || fail "CLAUDE.md longer than 80 lines"
grep -q '^## Principes' "$new/CLAUDE.md" || fail "CLAUDE.md without its Principles section in French"
grep -q '^# app' "$new/CLAUDE.md" || fail "CLAUDE.md not titled with the repository name"
grep -qi 'Ce que ça apporte' "$new/.github/pull_request_template.md" || fail "PR template not in the project language"
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

# Second run: nothing changes.
before=$(snapshot "$new")
setup "$new" --command test="true" --command lint="true"
[ "$(snapshot "$new")" = "$before" ] || fail "second run changed files"

# The commit-msg hook.
commit "$new" "mise à jour" && fail "non-conventional commit accepted"
grep -q "Conventional Commit" "$work/err" || fail "refusal does not say why: $(cat "$work/err")"
commit "$new" "feat(ui): add the menu" || fail "conventional commit refused: $(cat "$work/err")"
commit "$new" "fixup! feat(ui): add the menu" || fail "fixup commit refused"
printf 'feat: ok\nbad subject\n' | "$new/.githooks/commit-msg" --subjects 2>/dev/null && fail "--subjects accepts a bad subject"

# The pre-push hook runs the configured checks, without senior-mode on the PATH.
(cd "$new" && PATH=/usr/bin:/bin .githooks/pre-push </dev/null) >"$work/out" 2>&1 ||
  fail "pre-push fails on passing checks: $(cat "$work/out")"
jq '.checks[0].run = "echo boom; false"' "$new/.claude/senior-mode.json" >"$work/c" && mv "$work/c" "$new/.claude/senior-mode.json"
(cd "$new" && .githooks/pre-push </dev/null) >"$work/out" 2>&1 && fail "pre-push passes a failing check"
grep -q boom "$work/out" || fail "pre-push hides the failing output"

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
[ "$(jq -c '[.permissions.allow[0], .model]' "$old/.claude/settings.json")" = '["Bash(make:*)","opus"]' ] ||
  fail "existing settings not kept: $(cat "$old/.claude/settings.json")"
[ "$(cat "$old/.github/PULL_REQUEST_TEMPLATE.md")" = 'Our template' ] || fail "existing PR template replaced"
[ -f "$old/.github/pull_request_template.md" ] && fail "second PR template created"
[ "$(git -C "$old" config core.hooksPath)" = .husky ] || fail "existing hooks path replaced"
grep -q husky "$work/out" || fail "custom hooks path not reported: $(cat "$work/out")"
[ "$(jq -c '[.checks[].name]' "$old/.claude/senior-mode.json")" = '["make","commit subjects"]' ] ||
  fail "existing checks not extended: $(jq -c .checks "$old/.claude/senior-mode.json")"
before=$(snapshot "$old")
setup "$old"
[ "$(snapshot "$old")" = "$before" ] || fail "second run on an existing repository changed files"

# Updated Principles replace the old block, nothing else.
sed -i 's/^## Principles/## Old principles/' "$old/CLAUDE.md"
setup "$old"
grep -q '^## Old principles' "$old/CLAUDE.md" && fail "outdated Principles block not refreshed"
[ "$(grep -c 'senior-mode:principles' "$old/CLAUDE.md")" = 2 ] || fail "Principles block duplicated"

[ "$failures" -eq 0 ] && echo "setup-repo: all cases pass"
exit "$failures"
