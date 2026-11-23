#!/usr/bin/env bash
# Tests for `senior-mode red-tests record <issue>` (#191): the files the test-author session committed on the
# ticket branch are listed in <git common dir>/senior-mode/runs/<issue>/red-tests, one path per line, for the
# guard (hooks/self-protect.sh) to keep read-only for the ticket session. Offline: a local repository.
set -u
cli=$(cd "$(dirname "$0")/.." && pwd)/senior-mode
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }
g() { git -C "$repo" -c user.name=t -c user.email=t@t "$@" >/dev/null 2>&1 || echo "setup failed: git $*"; }
commit_files() { # message path...
  local m=$1 f
  shift
  for f in "$@"; do
    mkdir -p "$repo/$(dirname "$f")"
    echo x >>"$repo/$f"
  done
  g add -A
  g commit -m "$m"
}
record() { (cd "${dir:-$repo}" && "$cli" red-tests record "$@" 2>"$work/err"); }
list=$work/repo/.git/senior-mode/runs/7/red-tests

repo="$work/repo"
git init -q -b main "$repo"
g commit --allow-empty -m "chore: start"
g switch -c feat/7-thing

# Nothing committed on the branch yet: nothing to record, and no list is left behind.
record 7 >/dev/null && fail "recorded with no commit on the branch"
[ ! -e "$list" ] || fail "an empty list was written"

# The test-author's commits: new and changed test files, one path per line.
commit_files "test: red tests for #7" tests/a.sh web/tests/b.test.js
commit_files "test: another" "tests/with space.sh"
out=$(record 7) || fail "record failed: $(cat "$work/err")"
[ "$(sort "$list")" = "$(printf '%s\n' "tests/a.sh" "tests/with space.sh" "web/tests/b.test.js")" ] ||
  fail "the list is not the committed files: $(cat "$list" 2>/dev/null)"
grep -q '3 file' <<<"$out" || fail "record does not say how many files: $out"

# Written once: the implementer's later commits are not the test-author's.
commit_files "feat: code" src/app.js
record 7 >/dev/null && fail "a second record overwrote the list"
grep -q src/app.js "$list" && fail "an implementer file is in the list"

# From a linked worktree the list is the common one, paths from the root of that worktree.
git -C "$repo" worktree add -q "$work/wt" -b feat/8-other main
(cd "$work/wt" && mkdir -p t && echo x >t/c.sh && git add -A && git -c user.name=t -c user.email=t@t commit -qm "test: c")
dir=$work/wt record 8 >/dev/null || fail "record from a linked worktree failed: $(cat "$work/err")"
[ "$(cat "$repo/.git/senior-mode/runs/8/red-tests")" = "t/c.sh" ] || fail "linked worktree list: $(cat "$repo/.git/senior-mode/runs/8/red-tests")"

# Bad usage.
record >/dev/null && fail "record without an issue"
record abc >/dev/null && fail "record with a non-numeric issue"
(cd "$work" && "$cli" red-tests record 7 2>/dev/null) && fail "works outside a git repository"
(cd "$repo" && "$cli" red-tests list 7 2>/dev/null) && fail "unknown subcommand"

[ "$failures" -eq 0 ] && echo "red-tests: all cases pass"
exit "$failures"
