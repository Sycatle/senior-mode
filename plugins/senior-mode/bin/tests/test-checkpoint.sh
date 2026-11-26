#!/usr/bin/env bash
# Tests for `senior-mode checkpoint` (#346): the <!-- senior-mode:checkpoint --> block of the draft pull request of the
# ticket branch. Offline: gh is a stub that keeps the body of one pull request in $GH_DIR/body; the remote is a bare repository.
set -u
cli=$(cd "$(dirname "$0")/.." && pwd)/senior-mode
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

mkdir -p "$work/stub" "$work/gh"
cat >"$work/stub/gh" <<'STUB'
#!/usr/bin/env bash
echo "$1 $2" >>"$GH_LOG"
body_of() { while [ $# -gt 0 ]; do [ "$1" != --body ] || { printf '%s' "$2"; return; }; shift; done; }
case "$1 $2" in
  "pr list") echo "$*" >"$GH_DIR/list-args"
    if [ -f "$GH_DIR/body" ]; then jq -n --rawfile b "$GH_DIR/body" '[{number: 7, body: $b}]'; else echo '[]'; fi ;;
  "pr create") echo "$*" >"$GH_DIR/create-args"; body_of "$@" >"$GH_DIR/body"; echo "https://github.com/o/r/pull/7" ;;
  "pr edit") echo "$*" >"$GH_DIR/edit-args"; body_of "$@" >"$GH_DIR/body" ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$work/stub/gh"
export PATH="$work/stub:$PATH" GH_LOG="$work/gh.log" GH_DIR="$work/gh"
unset SENIOR_MODE_RUN_PLAN

g() { git -C "$repo" -c user.name=t -c user.email=t@t "$@" >/dev/null 2>&1 || echo "setup failed: git $*"; }
checkpoint() { (cd "$repo" && "$cli" checkpoint "$@") >"$work/out" 2>"$work/err"; }
BEGIN='<!-- senior-mode:checkpoint -->'
END='<!-- /senior-mode:checkpoint -->'

git init -q --bare -b main "$work/origin.git"
repo=$work/repo
git init -q -b main "$repo"
mkdir -p "$repo/.claude"
echo '{}' >"$repo/.claude/senior-mode.json"
g remote add origin "$work/origin.git"
g commit --allow-empty -m "chore: start"
g push -q -u origin main

# Off a ticket branch, or with nothing to say, nothing is called.
: >"$GH_LOG"
checkpoint --done a && fail "a checkpoint on the default branch"
g switch -q -c feat/7-thing
checkpoint && fail "a checkpoint with no list"
checkpoint --bogus x && fail "an unknown option"
checkpoint --done && fail "an option without a value"
[ ! -s "$GH_LOG" ] || fail "gh was called for a refused checkpoint: $(cat "$GH_LOG")"

# No pull request yet: the branch is pushed and a draft pull request is opened with the block (the first push).
echo x >"$repo/a.txt"
g add -A
g commit -m "feat(thing): add a"
checkpoint --done "tests for a" --done "a.txt" --doing "wiring b" --next "docs" --assumption "no migration" ||
  fail "checkpoint failed: $(cat "$work/err")"
git -C "$work/origin.git" rev-parse -q --verify refs/heads/feat/7-thing >/dev/null || fail "the branch was not pushed"
create=$(cat "$GH_DIR/create-args" 2>/dev/null)
for want in '--draft' '--base main' '--head feat/7-thing' '--title feat(thing): add a'; do
  grep -qF -- "$want" <<<"$create" || fail "pr create misses '$want': $create"
done
body=$(cat "$GH_DIR/body")
grep -qx "$BEGIN" <<<"$body" && grep -qx "$END" <<<"$body" || fail "the body has no block: $body"
grep -qF 'Closes #7' <<<"$body" || fail "the new pull request does not close the ticket: $body"
for want in 'Done' '- tests for a' '- a.txt' 'Doing' '- wiring b' 'Next' '- docs' 'Assumptions' '- no migration'; do
  grep -qF -- "$want" <<<"$body" || fail "the block misses '$want': $body"
done

# A pull request exists: only the block is replaced, what a person or the session wrote around it stays.
printf 'Closes #7\n\n## What and why\n\nSomething.\n\n%s\nold block\n%s\n\n## Checklist\n\n- [x] done\n' "$BEGIN" "$END" >"$GH_DIR/body"
: >"$GH_LOG"
checkpoint --done "b" --doing "c" --next "d" --assumption "e" || fail "checkpoint failed: $(cat "$work/err")"
grep -q '^pr create' "$GH_LOG" && fail "a second pull request was opened"
body=$(cat "$GH_DIR/body")
grep -qF 'old block' <<<"$body" && fail "the old block stayed: $body"
[ "$(grep -cx "$BEGIN" <<<"$body")" -eq 1 ] || fail "not exactly one block: $body"
for want in 'Something.' '## Checklist' '- [x] done' '- b' '- c' '- d' '- e'; do
  grep -qF -- "$want" <<<"$body" || fail "the replaced body misses '$want': $body"
done
grep -qF -- '- tests for a' <<<"$body" && fail "the lists of the previous checkpoint stayed: $body"

# A list that is not given is empty, and the block is the same on a second call with the same lists.
checkpoint --done "only this" || fail "checkpoint failed: $(cat "$work/err")"
first=$(cat "$GH_DIR/body")
checkpoint --done "only this" || fail "checkpoint failed: $(cat "$work/err")"
[ "$(grep -c -- '- none' "$GH_DIR/body")" -eq 3 ] || fail "empty lists are not 'none': $(cat "$GH_DIR/body")"
[ "$(grep -v '^Updated' <<<"$first")" = "$(grep -v '^Updated' "$GH_DIR/body")" ] || fail "a second identical checkpoint changed the body"

# A body without a block gets one at its end.
printf 'Closes #7\n\nText.\n' >"$GH_DIR/body"
checkpoint --next "x" || fail "checkpoint failed: $(cat "$work/err")"
head -n 3 "$GH_DIR/body" | grep -qx 'Text.' || fail "the text moved: $(cat "$GH_DIR/body")"
grep -qx "$BEGIN" "$GH_DIR/body" || fail "no block appended: $(cat "$GH_DIR/body")"

# The plan of the session ($SENIOR_MODE_RUN_PLAN, #352) lives in the block, and stays when a later session has no file.
printf 'plan 1:\nedit a.sh\narchitect 1: approve\n' >"$work/plan"
SENIOR_MODE_RUN_PLAN=$work/plan checkpoint --done "a" || fail "checkpoint with a plan failed: $(cat "$work/err")"
for want in 'Plan' 'plan 1:' 'edit a.sh' 'architect 1: approve'; do
  grep -qF -- "$want" "$GH_DIR/body" || fail "the block misses the plan line '$want': $(cat "$GH_DIR/body")"
done
checkpoint --done "b" || fail "checkpoint failed: $(cat "$work/err")"
grep -qF 'architect 1: approve' "$GH_DIR/body" || fail "the plan was lost by a checkpoint without a plan file: $(cat "$GH_DIR/body")"
: >"$work/plan"
SENIOR_MODE_RUN_PLAN=$work/plan checkpoint --done "c" || fail "checkpoint failed: $(cat "$work/err")"
grep -qF 'architect 1: approve' "$GH_DIR/body" || fail "the plan was lost by an empty plan file: $(cat "$GH_DIR/body")"

# A pull request that cannot be opened (nothing on the branch yet) is an error, not a silent success.
g switch -q main
g switch -q -c feat/8-empty
rm -f "$GH_DIR/body"
checkpoint --done a && fail "a checkpoint with no pull request and no commit on the branch"
grep -q 'pull request' "$work/err" || fail "the error does not name the pull request: $(cat "$work/err")"

[ "$failures" -eq 0 ] && echo "checkpoint: all cases pass"
exit "$((failures > 0))"
