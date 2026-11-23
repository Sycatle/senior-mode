#!/usr/bin/env bash
# Tests for script-tests.sh: test files run in parallel, bounded by the CPU count, with their output
# printed in order and a failing file named; a push only runs the files its changed paths touch.
set -u
script=$(cd "$(dirname "$0")" && pwd)/script-tests.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

repo="$work/repo"
git init -q "$repo"
mkdir -p "$work/stub" "$repo/t" "$repo/src" "$repo/docs"
ran="$work/ran"
# A test file: its name is appended to $ran, then <body> runs.
# shellcheck disable=SC2016 # the fixture's $0 is for the fixture to expand
tfile() {
  printf '#!/usr/bin/env bash\necho "$0" >>%q\n%s\n' "$ran" "${2:-}" >"$repo/t/test-$1.sh"
  chmod +x "$repo/t/test-$1.sh"
}
commit() {
  git -C "$repo" add -A
  git -C "$repo" -c user.name=t -c user.email=t@t commit -q -m "chore: fixture" --allow-empty
}
run() { (cd "$repo" && "$script") >"$work/out" 2>&1; }

# Every file runs, at once when the machine has the cores for it.
printf '#!/bin/sh\necho 4\n' >"$work/stub/nproc"
chmod +x "$work/stub/nproc"
for n in a b c d; do tfile "$n" 'sleep 1'; done
commit
SECONDS=0
PATH="$work/stub:$PATH" run || fail "fails although every file passes: $(cat "$work/out")"
[ "$SECONDS" -lt 3 ] || fail "four one-second files took $SECONDS s: not run in parallel"
[ "$(wc -l <"$ran")" = 4 ] || fail "not every file ran: $(cat "$ran")"
grep -Eq '^ok    t/test-a\.sh \([0-9]+\.[0-9]s\)$' "$work/out" || fail "file result without its time: $(cat "$work/out")"

# The bound is the CPU count: two cores, never more than two files at a time.
for n in a b c d; do
  tfile "$n" "mkdir $work/slots-$n; ls -d $work/slots-* | wc -l >>$work/peak; sleep 0.5; rmdir $work/slots-$n"
done
commit
printf '#!/bin/sh\necho 2\n' >"$work/stub/nproc"
: >"$work/peak"
PATH="$work/stub:$PATH" run || fail "fails on the two-core run: $(cat "$work/out")"
[ "$(sort -n "$work/peak" | tail -n 1)" = 2 ] || fail "files not run two at a time: $(tr '\n' ' ' <"$work/peak")"

# Output comes in the order of the files, whatever the order they finish in.
tfile a 'sleep 1'
tfile b 'true'
commit
PATH="$work/stub:$PATH" run
[ "$(grep -n 'test-[ab]\.sh' "$work/out" | head -n 1 | grep -c 'test-a')" = 1 ] || fail "a fast file printed before the one that precedes it: $(cat "$work/out")"

# A failing file is named with its output, the others still run, and the run fails.
for n in a b c d; do tfile "$n" 'true'; done
tfile b 'echo boom; exit 1'
commit
: >"$ran"
PATH="$work/stub:$PATH" run && fail "passes with a failing file"
grep -q '^FAIL  t/test-b\.sh' "$work/out" || fail "failing file not named: $(cat "$work/out")"
grep -q 'boom' "$work/out" || fail "failing file output not shown: $(cat "$work/out")"
[ "$(wc -l <"$ran")" = 4 ] || fail "a failure stopped the other files: $(cat "$ran")"
[ "$(tail -n 1 "$work/out")" = "failed: t/test-b.sh" ] || fail "the last line does not name the failing files: $(tail -n 1 "$work/out")"

# A push runs the files its changed paths touch: a changed test file, a test that names the changed file.
for n in a b c d; do tfile "$n" 'true'; done
tfile a 'true # uses foo.sh'
echo x >"$repo/src/foo.sh"
echo x >"$repo/src/other.sh"
echo x >"$repo/docs/guide.md"
commit
changed() { printf '%s\n' "$@" >"$work/changed"; }
scoped() { : >"$ran"; SENIOR_MODE_CHANGED_FILES="$work/changed" run || fail "scoped run fails: $(cat "$work/out")"; }
ran_files() { sed 's|.*/||' "$ran" | sort | paste -sd' '; }
changed src/foo.sh
scoped
[ "$(ran_files)" = "test-a.sh" ] || fail "a file named by a test: ran $(ran_files)"
changed t/test-c.sh t/test-d.sh
scoped
[ "$(ran_files)" = "test-c.sh test-d.sh" ] || fail "changed test files: ran $(ran_files)"
# Documents are covered by no test: nothing runs, and the check says why.
changed docs/guide.md
scoped
[ -z "$(ran_files)" ] || fail "a document change ran $(ran_files)"
[ "$(head -n 1 "$work/out")" = "skipped: no test file is affected by this push" ] || fail "no skip reason: $(cat "$work/out")"
# A path no test names cannot be mapped: everything runs. So does a shared file, and no list at all.
changed src/other.sh
scoped
[ "$(ran_files)" = "test-a.sh test-b.sh test-c.sh test-d.sh" ] || fail "an unmappable path: ran $(ran_files)"
changed plugins/senior-mode/bin/senior-mode
scoped
[ "$(ran_files)" = "test-a.sh test-b.sh test-c.sh test-d.sh" ] || fail "the shared script: ran $(ran_files)"
changed plugins/senior-mode/bin/lib/common.sh
scoped
[ "$(ran_files)" = "test-a.sh test-b.sh test-c.sh test-d.sh" ] || fail "a module of the shared script: ran $(ran_files)"
changed docs/guide.md src/foo.sh
scoped
[ "$(ran_files)" = "test-a.sh" ] || fail "a document next to a mapped path: ran $(ran_files)"
: >"$ran"
run || fail "full run fails: $(cat "$work/out")"
[ "$(ran_files)" = "test-a.sh test-b.sh test-c.sh test-d.sh" ] || fail "without a list: ran $(ran_files)"

[ "$failures" -eq 0 ] && echo "script-tests: all cases pass"
exit "$failures"
