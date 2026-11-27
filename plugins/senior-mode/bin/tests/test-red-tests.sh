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

# verify (#306): the added test files must fail on the base, with the test files alone, and pass on the head.
vrepo="$work/vrepo"
git init -q -b main "$vrepo"
mkdir -p "$vrepo/.claude" "$vrepo/tests"
printf '{"commands": {"test": "bash tests/t.sh"}}\n' >"$vrepo/.claude/senior-mode.json"
git -C "$vrepo" add -A && git -C "$vrepo" -c user.name=t -c user.email=t@t commit -qm "chore: start"
vg() { git -C "$vrepo" -c user.name=t -c user.email=t@t "$@" >/dev/null 2>&1 || echo "setup failed: git $*"; }
verify() { (cd "$vrepo" && "$cli" red-tests verify "$@" 2>"$work/err"); }
vlist=$vrepo/.git/senior-mode/runs/9/red-verified
vg switch -c feat/9-thing
verify 9 >/dev/null && fail "verify with no test file on the branch"
grep -q 'no test file' "$work/err" || fail "verify does not say why: $(cat "$work/err")"
# A test that passes without the change proves nothing.
printf 'exit 0\n' >"$vrepo/tests/t.sh"
vg add -A && vg commit -m "test: weak"
verify 9 >/dev/null && fail "a test that passes on the base was accepted"
grep -q 'pass on .*main.* without the change' "$work/err" || fail "the weak test is not explained: $(cat "$work/err")"
[ ! -e "$vlist" ] || fail "a record was written for a test that passes on the base"
# A test that fails on the base and passes with the change.
printf '[ -f impl.txt ]\n' >"$vrepo/tests/t.sh"
echo ok >"$vrepo/impl.txt"
vg add -A && vg commit -m "feat: impl"
# A session's sandbox keeps .git/worktrees read-only (#563): verify needs no worktree.
mkdir -p "$vrepo/.git/worktrees" && chmod a-w "$vrepo/.git/worktrees"
out=$(verify 9) || fail "verify failed: $(cat "$work/err")"
chmod u+w "$vrepo/.git/worktrees"
[ "$(cat "$vlist")" = "tests/t.sh" ] || fail "the verified list is wrong: $(cat "$vlist" 2>/dev/null)"
grep -q 'fail on .*main.* and pass on the head' <<<"$out" || fail "verify does not say what it proved: $out"
[ "$(git -C "$vrepo" worktree list | wc -l)" -eq 1 ] || fail "a base worktree is left behind"
# A test that fails on the head too.
vg switch -q -c feat/10-broken main
mkdir -p "$vrepo/tests"
printf '[ -f impl.txt ]\n' >"$vrepo/tests/t.sh"
vg add -A && vg commit -m "test: broken"
verify 10 >/dev/null && fail "a test that fails on the head was accepted"
grep -q 'do not pass on the head' "$work/err" || fail "the head failure is not explained: $(cat "$work/err")"
verify abc >/dev/null && fail "verify with a non-numeric issue"

# Journeys (#464, spec 328 section 5.3): a ticket whose Paths overlap a declared journey needs its E2E test, red.
# gh is a stub: the board says the Paths of the ticket, GH_PATHS is the Paths text.
mkdir -p "$work/stub"
cat >"$work/stub/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"api graphql"*) printf '{"data":{"repository":{"issue":{"parent":null,"projectItems":{"nodes":[{"project":{"id":"P"},"fieldValueByName":{"text":"%s"}}]}}}}}\n' "${GH_PATHS:-}" ;;
esac
STUB
chmod +x "$work/stub/gh"
jrepo="$work/jrepo"
git init -q -b main "$jrepo"
mkdir -p "$jrepo/.claude" "$jrepo/tests" "$jrepo/docs/specs"
printf '{"commands": {"test": "bash tests/t.sh"}}\n' >"$jrepo/.claude/senior-mode.json"
cat >"$jrepo/docs/specs/9-pay.md" <<'SPEC'
---
id: 9
status: accepted
paths: [src/pay/**]
journeys:
  - { id: J1, name: "A buyer pays an invoice", test: "e2e/pay.spec.ts" }
  - { id: J2, name: "A buyer downloads a receipt", test: "e2e/receipt.spec.ts" }
---
# Pay

## Users and journeys

J1: the buyer opens an invoice, pays it by card and sees it as paid.

J2: the buyer downloads the receipt of a paid invoice.

## Design
Nothing.
SPEC
mkdir -p "$jrepo/e2e"
echo 'test("J2 receipt", () => {})' >"$jrepo/e2e/receipt.spec.ts"
git -C "$jrepo" remote add origin https://github.com/o/r.git
git -C "$jrepo" add -A && git -C "$jrepo" -c user.name=t -c user.email=t@t commit -qm "chore: start"
jg() { git -C "$jrepo" -c user.name=t -c user.email=t@t "$@" >/dev/null 2>&1 || echo "setup failed: git $*"; }
jverify() { (cd "$jrepo" && PATH="$work/stub:$PATH" GH_PATHS="${paths-src/pay/**}" "$cli" red-tests verify "$@" 2>"$work/err"); }
jg switch -c feat/11-pay
# The brief of the test-author and the sentence of the implementer's prompt, as the prompts of run and serve build them.
jprompt() { # brief|readonly
  (cd "$jrepo" && PATH="$work/stub:$PATH" GH_PATHS="${paths-src/pay/**}" SELF="$cli" LIB="$(dirname "$cli")/lib" bash -c \
    'usage() { :; }; for m in common board context journeys skeleton prompts; do . "$LIB/$m.sh"; done; skeleton_journeys_prompt 11 "$1"' _ "$1" 2>"$work/err")
}
brief=$(jprompt brief)
grep -q 'J1 "A buyer pays an invoice" (spec 9), test file e2e/pay.spec.ts, missing: write it' <<<"$brief" || fail "J: the brief does not list J1: $brief"
grep -q 'the buyer opens an invoice, pays it by card' <<<"$brief" || fail "J: the brief lacks the text of J1: $brief"
grep -q 'not from the code' <<<"$brief" || fail "J: the brief does not say to write from the journey: $brief"
grep -q 'J2 "A buyer downloads a receipt" (spec 9), test file e2e/receipt.spec.ts, exists: edit only if the criteria change the journey' <<<"$brief" ||
  fail "J: the brief does not say an existing test is edited only when the criteria change: $brief"
[ "$(paths="src/other/**" jprompt brief)" = "" ] || fail "J: a ticket off the journeys' paths has a brief"
[ "$(paths="src/other/**" jprompt readonly)" = "" ] || fail "J: a ticket off the journeys' paths has a read-only sentence"
jprompt readonly | grep -q 'e2e/pay.spec.ts, e2e/receipt.spec.ts) is read-only for you' || fail "J: the implementer is not told the E2E test is read-only: $(jprompt readonly)"
printf '[ -f impl.txt ]\n' >"$jrepo/tests/t.sh"
echo ok >"$jrepo/impl.txt"
jg add -A && jg commit -m "test: unit"
# The journey J1 has no test on the base and none on the branch: verify fails naming it, whatever else is red.
jverify 11 >/dev/null && fail "J: verify passed with the E2E test of J1 absent"
grep -q 'journey J1 of spec 9 has no test at e2e/pay.spec.ts' "$work/err" || fail "J: the absent journey test is not named: $(cat "$work/err")"
# A ticket whose Paths overlap no journey is verified as before.
paths="src/other/**" jverify 11 >/dev/null || fail "J: a ticket off the journeys' paths failed: $(cat "$work/err")"
# The test is there but green on the base (the test command passes without the change): it proves nothing.
printf '[ -f impl.txt ] || [ -f e2e/pay.spec.ts ]\n' >"$jrepo/tests/t.sh"
echo 'test("J1 pay", () => {})' >"$jrepo/e2e/pay.spec.ts"
jg add -A && jg commit -m "test: J1 green"
jverify 11 >/dev/null && fail "J: verify passed with the E2E test of J1 green on the base"
grep -q 'pass on .*main.* without the change' "$work/err" || fail "J: the green journey test is not explained: $(cat "$work/err")"
# Red on the base, green on the head: verified, and the E2E test is in the list although its name is no test of the preset.
printf '[ -f impl.txt ]\n' >"$jrepo/tests/t.sh"
jg add -A && jg commit -m "test: J1 red"
jverify 11 >/dev/null || fail "J: verify failed with the E2E test of J1 written: $(cat "$work/err")"
grep -qx 'e2e/pay.spec.ts' "$jrepo/.git/senior-mode/runs/11/red-verified" || fail "J: the E2E test is not verified: $(cat "$jrepo/.git/senior-mode/runs/11/red-verified")"
# red-tests record: the E2E test the test-author committed is in the recorded set; J2, which exists and is untouched, is not.
(cd "$jrepo" && "$cli" red-tests record 11 >/dev/null 2>&1) || fail "J: record failed"
grep -qx 'e2e/pay.spec.ts' "$jrepo/.git/senior-mode/runs/11/red-tests" || fail "J: the recorded set lacks the E2E test"
grep -q 'receipt' "$jrepo/.git/senior-mode/runs/11/red-tests" && fail "J: an untouched journey test is in the recorded set"

[ "$failures" -eq 0 ] && echo "red-tests: all cases pass"
exit "$failures"
