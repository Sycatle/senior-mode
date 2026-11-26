#!/usr/bin/env bash
# Tests for `senior-mode untested` (#422, spec 409 section 6): the files a branch changes that have no tests need a
# characterization commit first; a refactor leaves the pinned assertions as they are. Offline: a local repository.
set -u
cli=$(cd "$(dirname "$0")/.." && pwd)/senior-mode
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }
g() { git -C "$repo" -c user.name=t -c user.email=t@t "$@" >/dev/null 2>&1 || echo "setup failed: git $*"; }
put() { # path content
  mkdir -p "$repo/$(dirname "$1")"
  printf '%s\n' "$2" >"$repo/$1"
}
commit() { g add -A; g commit -m "$1"; }
run() { (cd "$repo" && "$cli" untested "$@") >"$work/out" 2>"$work/err"; }
said() { grep -qE -- "$1" "$work/out"; }

repo="$work/repo"
git init -q -b main "$repo"
put README.md "# x"
put src/pricing.sh 'price() { echo 10; }'
put src/billing.sh 'bill() { echo 20; }'
put src/covered.sh 'covered() { echo 1; }'
put src/low.sh 'low() { echo 1; }'
put src/types.ts 'export type A = string'
put src/api.generated.ts 'export const x = 1'
put src/legacy/old.sh 'old() { echo 1; }'
put tests/test-covered.sh 'source ../src/covered.sh; covered'
put docs/a.md "doc"
put .claude/ratchet-baseline.json '{"coverage": {"files": {"src/billing.sh": 80, "src/low.sh": 20}}}'
commit "chore: start"

# A file with no coverage data and no test that mentions it is untested; the rest is not, or says why.
run src/pricing.sh src/covered.sh src/types.ts src/api.generated.ts docs/a.md src/legacy/old.sh tests/test-covered.sh || fail "A: untested failed: $(cat "$work/err")"
said '^untested src/pricing.sh: no coverage data and no test mentions it' || fail "A: pricing.sh not untested: $(cat "$work/out")"
said '^untested src/covered.sh' && fail "A: a file a test mentions is untested: $(cat "$work/out")"
said '^exempt src/types.ts: types or constants' || fail "A: types.ts not exempt: $(cat "$work/out")"
said '^exempt src/api.generated.ts: generated' || fail "A: a generated file is not exempt: $(cat "$work/out")"
said '^exempt docs/a.md: docs' || fail "A: docs are not exempt: $(cat "$work/out")"
said '^exempt tests/test-covered.sh: a test file' || fail "A: a test is not exempt: $(cat "$work/out")"

# B: the coverage of the ratchet baseline wins over the mentions, against characterize.below (50 by default).
run src/billing.sh src/low.sh || fail "B: untested failed"
said '^untested src/low.sh: 20% covered, under characterize.below \(50%\)' || fail "B: 20% is not untested: $(cat "$work/out")"
said 'src/billing.sh' && fail "B: 80% is untested: $(cat "$work/out")"
mkdir -p "$repo/.claude"
printf '%s\n' '{"characterize": {"below": 10, "exempt": ["src/legacy/**", "src/pricing.sh"]}}' >"$repo/.claude/senior-mode.json"
run src/low.sh src/legacy/old.sh src/pricing.sh || fail "B: untested failed with a config"
said '^untested src/low.sh' && fail "B: characterize.below = 10 not applied: $(cat "$work/out")"
said '^exempt src/legacy/old.sh: characterize.exempt \(src/legacy/\*\*\)' || fail "B: characterize.exempt not applied: $(cat "$work/out")"
said '^exempt src/pricing.sh: characterize.exempt' || fail "B: an exempt file is not exempt: $(cat "$work/out")"
rm "$repo/.claude/senior-mode.json"

# C: --check on a branch that changes an untested file without a characterization commit fails; a commit that pins it passes.
g switch -c refactor/pricing
put src/pricing.sh 'price() { echo 11; }'
commit "refactor(pricing): simplify"
run --check && fail "C: a branch that changes untested code with no characterization commit passes"
said '^missing src/pricing.sh: .*test\(<scope>\): characterize' || fail "C: the missing commit is not said: $(cat "$work/out")"
g reset -q --hard main
put tests/test-pricing.sh 'source ../src/pricing.sh; [ "$(price)" = 10 ] || exit 1'
commit "test(pricing): characterize price"
put src/pricing.sh 'price() { echo 10; }  # tidied'
commit "refactor(pricing): tidy"
run --check || fail "C: a characterized refactor fails: $(cat "$work/err") $(cat "$work/out")"
said '^characterized src/pricing.sh: [0-9a-f]{40} test\(pricing\): characterize price' || fail "C: the pinning commit is not named: $(cat "$work/out")"

# D: a characterization commit made after the change does not count (it must pin the code as it was).
g reset -q --hard main
put src/pricing.sh 'price() { echo 11; }'
commit "feat(pricing): new price"
put tests/test-pricing.sh 'source ../src/pricing.sh; [ "$(price)" = 11 ] || exit 1'
commit "test(pricing): characterize price"
run --check && fail "D: a characterization commit after the change passes"
said '^missing src/pricing.sh' || fail "D: the late commit is not refused: $(cat "$work/out")"

# E: a refactor that edits a pinned assertion fails; a behaviour change (no refactor commit) is left to the reviewer.
g reset -q --hard main
put tests/test-pricing.sh 'source ../src/pricing.sh; [ "$(price)" = 10 ] || exit 1'
commit "test(pricing): characterize price"
put src/pricing.sh 'price() { echo 12; }'
put tests/test-pricing.sh 'source ../src/pricing.sh; [ "$(price)" = 12 ] || exit 1'
commit "refactor(pricing): reshape"
run --check && fail "E: a refactor that edits a pinned assertion passes"
said '^pinned tests/test-pricing.sh: [0-9a-f]+ edits a pinned assertion in a refactor' || fail "E: the pinned edit is not said: $(cat "$work/out")"
g reset -q --hard HEAD~1
put src/pricing.sh 'price() { echo 12; }'
put tests/test-pricing.sh 'source ../src/pricing.sh; [ "$(price)" = 12 ] || exit 1'
commit "feat(pricing): price is 12"
run --check || fail "E: a behaviour change that edits an assertion is refused: $(cat "$work/out")"

# F: --changed lists without failing; a new file has nothing to pin; an exempt change needs nothing.
g reset -q --hard main
g switch -c feat/new
put src/fresh.sh 'fresh() { echo 1; }'
put docs/a.md "doc 2"
put src/types.ts 'export type A = number'
commit "feat: fresh"
run --check || fail "F: new, docs and types files need no characterization: $(cat "$work/out")"
run --changed || fail "F: --changed failed"
said 'src/fresh.sh' && fail "F: a new file is listed: $(cat "$work/out")"

# G: no argument is a usage error.
run && fail "G: untested with no argument succeeded"

[ "$failures" -eq 0 ] && echo "test-characterize: all passed"
exit "$failures"
