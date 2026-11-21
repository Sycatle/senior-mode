#!/usr/bin/env bash
# Tests for `senior-mode start`. Offline: gh is a stub serving an issue and logging every call; origin is
# a local bare repository reached through an insteadOf rewrite of the GitHub URL.
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
case "$*" in
  "issue view "*) echo "$GH_ISSUE" ;;
  "project item-add"*) echo "ITEM" ;;
  "project item-edit"*) ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$work/stub/gh"
export PATH="$work/stub:$PATH" GH_LOG="$work/gh.log" SENIOR_MODE_RETRY_DELAY=0
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

git init -q --bare -b main "$work/origin.git"
repo="$work/app"
git init -q -b main "$repo"
git -C "$repo" remote add origin git@github.com:acme/app.git
git -C "$repo" config url."$work/origin.git".insteadOf git@github.com:acme/app.git
mkdir -p "$repo/.claude"
cat >"$repo/.claude/senior-mode.json" <<'JSON'
{"project": {"id": "PVT_1", "owner": "acme", "number": 3, "fields": {
  "Status": {"id": "F_S", "options": {"Backlog": "o1", "Ready": "o2", "In progress": "o3"}}}}}
JSON
git -C "$repo" add -A
git -C "$repo" commit -q -m "chore: start"
git -C "$repo" push -q origin main
# origin moves on after the clone: the branch must start from it, not from the stale local main.
other="$work/other"
git clone -q "$work/origin.git" "$other"
echo new >"$other/new.txt"
git -C "$other" add -A
git -C "$other" commit -q -m "feat: newer"
git -C "$other" push -q origin main
git -C "$repo" fetch -q origin
git -C "$repo" remote set-head origin main >/dev/null

issue() { export GH_ISSUE="{\"title\": \"$1\", \"state\": \"${3:-OPEN}\", \"labels\": [$2]}"; }
start() {
  : >"$GH_LOG"
  (cd "$repo" && "$cli" start "$@") >"$work/out" 2>"$work/err"
}
# Starts ticket $1 and checks the branch it prints.
branch_is() {
  start "$1" || { fail "start $1 failed: $(cat "$work/err")"; return; }
  grep -qx "branch $2" "$work/out" || fail "branch of #$1: $(cat "$work/out")"
}
logged() { grep -qF -- "$1" "$GH_LOG"; }

# A feature: branch and worktree named after the ticket, from origin's default branch, In progress.
issue "feat: add the next command, the daily session" '{"name": "type:feature"}'
start 89 || fail "start exited non-zero: $(cat "$work/err")"
branch=feat/89-add-the-next-command-the-daily-session
grep -qx "branch $branch" "$work/out" || fail "branch line: $(cat "$work/out")"
grep -qx "worktree $work/app-89" "$work/out" || fail "worktree line: $(cat "$work/out")"
[ "$(git -C "$work/app-89" symbolic-ref --short HEAD)" = "$branch" ] || fail "worktree is not on $branch"
[ -f "$work/app-89/new.txt" ] || fail "branch not started from the fetched origin/main"
git -C "$repo" config --get "branch.$branch.remote" >/dev/null && fail "branch tracks origin/main"
logged "project item-edit --project-id PVT_1 --id ITEM --field-id F_S --single-select-option-id o3" ||
  fail "Status not set to In progress: $(cat "$GH_LOG")"
grep -q '^#89 Status = In progress' "$work/out" || fail "status line: $(cat "$work/out")"

# Rerunning reuses the branch and the worktree.
start 89 || fail "rerun failed: $(cat "$work/err")"
grep -qx "worktree $work/app-89" "$work/out" || fail "rerun worktree line: $(cat "$work/out")"
[ "$(git -C "$repo" worktree list | grep -c app-89)" -eq 1 ] || fail "rerun added a second worktree"
# A reworded title does not fork the branch.
issue "Another title" '{"name": "type:feature"}'
start 89 || fail "reworded title failed: $(cat "$work/err")"
grep -qx "branch $branch" "$work/out" || fail "reworded title changed the branch: $(cat "$work/out")"

# A branch left without a worktree gets one again.
git -C "$repo" worktree remove "$work/app-89"
start 89 || fail "existing branch failed: $(cat "$work/err")"
[ "$(git -C "$work/app-89" symbolic-ref --short HEAD)" = "$branch" ] || fail "existing branch not checked out"

# The type follows the label: bug, task, chore, none.
issue "Crash on login" '{"name": "type:bug"}, {"name": "needs-info"}'
branch_is 90 fix/90-crash-on-login
issue "Tidy things" '{"name": "type:task"}'
branch_is 91 chore/91-tidy-things
issue "Bump deps" '{"name": "type:chore"}'
branch_is 92 chore/92-bump-deps
issue "No label here" ''
branch_is 93 feat/93-no-label-here

# A very long title is cut at a word.
issue "Make the daily session pick the first ticket and deliver it" ''
branch_is 94 feat/94-make-the-daily-session-pick-the-first

# A closed issue, a bad number, a taken path and a stale item all stop before the board.
issue "Done already" '' CLOSED
start 95 && fail "a closed issue started"
grep -q closed "$work/err" || fail "closed issue not explained: $(cat "$work/err")"
logged "project item-add" && fail "board touched for a closed issue"
for bad in "" abc 0 "1 2"; do
  # shellcheck disable=SC2086
  start $bad && fail "accepted '$bad'"
done
issue "Occupied" ''
mkdir "$work/app-96"
start 96 && fail "started over an existing directory"
git -C "$repo" show-ref -q --verify refs/heads/feat/96-occupied && fail "branch created despite the taken path"

[ "$failures" -eq 0 ] && echo "start: all cases pass"
exit "$failures"
