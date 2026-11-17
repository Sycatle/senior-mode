#!/usr/bin/env bash
# Tests for `senior-mode check` and `senior-mode publish`. Offline: gh is a stub that logs its arguments.
set -u
cli=$(cd "$(dirname "$0")/.." && pwd)/senior-mode
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

mkdir -p "$work/stub"
cat >"$work/stub/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$GH_LOG"
STUB
chmod +x "$work/stub/gh"
export PATH="$work/stub:$PATH" GH_LOG="$work/gh.log"

repo="$work/repo"
git init -q "$repo"
git -C "$repo" remote add origin https://github.com/acme/app.git
mkdir -p "$repo/.claude"
config() {
  printf '%s\n' "$1" >"$repo/.claude/senior-mode.json"
  git -C "$repo" add -A
  git -C "$repo" -c user.name=t -c user.email=t@t commit -q -m "chore: config" --allow-empty
}
run() { (cd "$repo" && "$cli" "$@") >"$work/out" 2>&1; }
sha() { git -C "$repo" rev-parse HEAD; }

config '{"checks":[]}'
run check && fail "check passes with no checks configured"
grep -q setup "$work/out" || fail "no-checks message does not mention setup"

config '{"checks":[{"name":"lint","run":"true"},{"name":"tests","run":"echo all good"}]}'
run check || fail "check fails although every check passes: $(cat "$work/out")"
grep -q "2/2 checks passed" "$work/out" || fail "summary missing: $(cat "$work/out")"
: >"$GH_LOG"
run publish || fail "publish fails after a passing check: $(cat "$work/out")"
grep -q -- "api repos/acme/app/statuses/$(sha) -f state=success -f context=senior-mode/ci -f description=2/2 checks passed" "$GH_LOG" ||
  fail "success status not published as expected: $(cat "$GH_LOG")"

config '{"checks":[{"name":"lint","run":"true"},{"name":"tests","run":"echo boom; exit 3"}]}'
run check && fail "check passes although a check fails"
grep -q "FAIL  tests" "$work/out" || fail "failing check not named: $(cat "$work/out")"
grep -q boom "$work/out" || fail "failing check output not shown: $(cat "$work/out")"
: >"$GH_LOG"
run publish || fail "publish fails after a failing check: $(cat "$work/out")"
grep -q -- "-f state=failure -f context=senior-mode/ci -f description=failed: tests" "$GH_LOG" ||
  fail "failure status not published as expected: $(cat "$GH_LOG")"

# Git exports GIT_DIR to hooks, absolute in a linked worktree: a check must not inherit it, or a
# test that runs git on a fixture writes into this repository.
config '{"checks":[{"name":"env","run":"env | grep -E \"^GIT_(DIR|WORK_TREE|INDEX_FILE)=\" && exit 1; true"}]}'
(cd "$repo" && GIT_DIR="$repo/.git" GIT_WORK_TREE="$repo" GIT_INDEX_FILE="$repo/.git/index" "$cli" check) \
  >"$work/out" 2>&1 || fail "a check sees git's hook environment: $(cat "$work/out")"

config '{"checks":[{"name":"lint","run":"true"}]}'
: >"$GH_LOG"
run publish && fail "publish works without a check result for this commit"
[ -s "$GH_LOG" ] && fail "gh called without a check result"

echo dirty >"$repo/untracked.txt"
run check || fail "check fails on a dirty tree although every check passes"
run publish && fail "a check on a dirty tree was recorded for HEAD"
rm "$repo/untracked.txt"

[ "$failures" -eq 0 ] && echo "check: all cases pass"
exit "$failures"
