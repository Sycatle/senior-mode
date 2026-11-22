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
  "api graphql --input -") cat >/dev/null; jq -nc --argjson i "${GH_IN_PROGRESS:-[]}" '{data: {node: {items: {
    pageInfo: {hasNextPage: false}, nodes: ($i | map({fieldValues: {nodes: [{name: "In progress", field: {name: "Status"}}]},
      content: {number: ., title: "Ticket \(.)", url: "u", state: "OPEN", labels: {nodes: []}, milestone: null,
        blockedBy: {nodes: []}}}))}}}}' ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$work/stub/gh"
# Package managers: log the call and where it ran, and create node_modules like a real install; they fail
# when PM_FAIL is set.
for pm in npm pnpm; do
  cat >"$work/stub/$pm" <<'STUB'
#!/usr/bin/env bash
echo "$(basename "$0") $* @ $PWD" >>"$PM_LOG"
[ -z "${PM_FAIL:-}" ] || { echo "install exploded" >&2; exit 1; }
mkdir -p node_modules
STUB
  chmod +x "$work/stub/$pm"
done
export PM_LOG="$work/pm.log"
: >"$PM_LOG"
export PATH="$work/stub:$PATH" GH_LOG="$work/gh.log" SENIOR_MODE_RETRY_DELAY=0
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

git init -q --bare -b main "$work/origin.git"
repo="$work/app"
wt=$repo/.git/senior-mode/worktrees
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
echo '{"name": "app", "dependencies": {"left-pad": "1.3.0"}}' >"$other/package.json"
echo '{"lockfileVersion": 3}' >"$other/package-lock.json"
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
grep -qx "worktree $wt/89" "$work/out" || fail "worktree line: $(cat "$work/out")"
[ "$(git -C "$wt/89" symbolic-ref --short HEAD)" = "$branch" ] || fail "worktree is not on $branch"
[ -f "$wt/89/new.txt" ] || fail "branch not started from the fetched origin/main"
git -C "$repo" config --get "branch.$branch.remote" >/dev/null && fail "branch tracks origin/main"
logged "project item-edit --project-id PVT_1 --id ITEM --field-id F_S --single-select-option-id o3" ||
  fail "Status not set to In progress: $(cat "$GH_LOG")"
grep -q '^#89 Status = In progress' "$work/out" || fail "status line: $(cat "$work/out")"

# A new worktree gets its dependencies, installed in it with the command of its lockfile (#110).
grep -qx "npm ci @ $wt/89" "$PM_LOG" || fail "dependencies not installed in the new worktree: $(cat "$PM_LOG")"
[ -d "$wt/89/node_modules" ] || fail "no node_modules in the new worktree"

# The worktree lives in the git common dir, never beside the repository (#224); git status stays clean.
compgen -G "$work/app-[0-9]*" >/dev/null && fail "a ticket worktree beside the repository: $(ls "$work")"
[ -z "$(git -C "$repo" status --porcelain)" ] || fail "the main checkout is dirty: $(git -C "$repo" status --porcelain)"

# Rerunning reuses the branch and the worktree.
start 89 || fail "rerun failed: $(cat "$work/err")"
grep -qx "worktree $wt/89" "$work/out" || fail "rerun worktree line: $(cat "$work/out")"
[ "$(git -C "$repo" worktree list | grep -c "worktrees/89 ")" -eq 1 ] || fail "rerun added a second worktree"
[ "$(wc -l <"$PM_LOG")" -eq 1 ] || fail "rerun installed again: $(cat "$PM_LOG")"
# A reworded title does not fork the branch.
issue "Another title" '{"name": "type:feature"}'
start 89 || fail "reworded title failed: $(cat "$work/err")"
grep -qx "branch $branch" "$work/out" || fail "reworded title changed the branch: $(cat "$work/out")"

# A branch left without a worktree gets one again.
git -C "$repo" worktree remove "$wt/89"
start 89 || fail "existing branch failed: $(cat "$work/err")"
[ "$(git -C "$wt/89" symbolic-ref --short HEAD)" = "$branch" ] || fail "existing branch not checked out"

# Started from inside another worktree, the new one is still under the main repository's git dir.
issue "From a worktree" ''
(cd "$wt/89" && "$cli" start 88) >"$work/out" 2>"$work/err" || fail "start from a worktree failed: $(cat "$work/err")"
grep -qx "worktree $wt/88" "$work/out" || fail "start from a worktree: $(cat "$work/out")"
[ -d "$wt/88/.git" ] || [ -f "$wt/88/.git" ] || fail "no worktree at $wt/88"
[ ! -e "$wt/89/senior-mode" ] || fail "worktree nested in the worktree it was started from"

# A ticket already started under the old sibling path is reused, not started twice, and its path is said.
issue "Old style" ''
git -C "$repo" fetch -q origin
git -C "$repo" worktree add -q --no-track -b feat/87-old-style "$work/app-87" origin/main
start 87 || fail "start over an old-path worktree failed: $(cat "$work/err")"
grep -qx "worktree $work/app-87" "$work/out" || fail "old-path worktree not reported: $(cat "$work/out")"
[ ! -e "$wt/87" ] || fail "a second worktree was created next to the old-path one"
[ "$(git -C "$repo" worktree list | grep -c 'feat/87-old-style')" -eq 1 ] || fail "old-path start added a worktree"

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

# A project's own install command, stored in its config, wins over the lockfile's (#110); a failing one
# does not stop the start.
jq '.commands.install = "pnpm install --offline"' "$other/.claude/senior-mode.json" >"$work/config.json"
mv "$work/config.json" "$other/.claude/senior-mode.json"
git -C "$other" add -A
git -C "$other" commit -q -m "chore: install command"
git -C "$other" push -q origin main
issue "Own installer" ''
: >"$PM_LOG"
start 97 || fail "start 97 failed: $(cat "$work/err")"
grep -qx "pnpm install --offline @ $wt/97" "$PM_LOG" || fail "configured install not run: $(cat "$PM_LOG")"
grep -q '^npm' "$PM_LOG" && fail "lockfile command ran despite the configured one"
issue "Broken installer" ''
: >"$PM_LOG"
PM_FAIL=1 start 98 || fail "a failing install stopped the start: $(cat "$work/err")"
grep -qx "branch feat/98-broken-installer" "$work/out" || fail "failed install: no branch line: $(cat "$work/out")"
grep -q "install" "$work/err" || fail "failed install not reported: $(cat "$work/err")"

# A branch name is ASCII whatever the locale (#111): accents are transliterated when iconv can, else dropped.
issue "Résumé de l'été: café Œuvre" ''
LC_ALL=C.UTF-8 branch_is 99 feat/99-resume-de-l-ete-cafe-oeuvre
issue "fix(ui): Ça déçoit" '{"name": "type:bug"}'
LC_ALL=C branch_is 100 fix/100-ca-decoit
mkdir "$work/noiconv"
printf '#!/bin/sh\nexit 127\n' >"$work/noiconv/iconv"
chmod +x "$work/noiconv/iconv"
issue "Crème brûlée" ''
PATH="$work/noiconv:$PATH" LC_ALL=C.UTF-8 branch_is 101 feat/101-crme-brle

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
mkdir "$wt/96"
start 96 && fail "started over an existing directory"
git -C "$repo" show-ref -q --verify refs/heads/feat/96-occupied && fail "branch created despite the taken path"

# The work-in-progress limit (#125): wip 1 by default, #89 In progress elsewhere.
issue "Second thing" ''
export GH_IN_PROGRESS='[89]'
start 102 && fail "started past the wip limit"
grep -q '#89' "$work/err" || fail "wip refusal does not name the ticket in progress: $(cat "$work/err")"
grep -qi 'finish' "$work/err" || fail "wip refusal does not suggest finishing it: $(cat "$work/err")"
logged "project item-" && fail "board touched past the wip limit"
[ -e "$wt/102" ] && fail "worktree created past the wip limit"
git -C "$repo" show-ref -q --verify refs/heads/feat/102-second-thing && fail "branch created past the wip limit"
issue "feat: add the next command, the daily session" '{"name": "type:feature"}'
start 89 || fail "the ticket already In progress refused: $(cat "$work/err")"
issue "Second thing" ''
# #145: only `run`, which holds the token in memory, skips the limit; a variable set by hand does not,
# even with a token file of its own and the token in the environment.
SENIOR_MODE_RUN=1 start 102 && fail "a hand-set SENIOR_MODE_RUN skipped the wip limit"
grep -q '#89' "$work/err" || fail "hand-set run: the wip refusal does not name the ticket: $(cat "$work/err")"
(umask 077; echo forged >"$work/token")
SENIOR_MODE_RUN=1 SENIOR_MODE_RUN_TOKEN_FILE="$work/token" start 102 && fail "a forged token file skipped the wip limit"
SENIOR_MODE_RUN=1 SENIOR_MODE_RUN_TOKEN_FILE="$work/token" RUN_TOKEN=forged start 102 &&
  fail "a token set in the environment skipped the wip limit"
[ -e "$wt/102" ] && fail "worktree created by a hand-set run"
jq '.wip = 2' "$repo/.claude/senior-mode.json" >"$work/c" && mv "$work/c" "$repo/.claude/senior-mode.json"
issue "Third thing" ''
start 103 || fail "wip 2 refused a second ticket: $(cat "$work/err")"
jq 'del(.wip)' "$repo/.claude/senior-mode.json" >"$work/c" && mv "$work/c" "$repo/.claude/senior-mode.json"
unset GH_IN_PROGRESS
: >"$GH_LOG"

# frame start <slug>: a worktree and a docs branch from origin's default branch, so framings do not share
# a working tree; it stops when the local default branch holds commits origin does not have.
fstart() {
  (cd "$repo" && "$cli" frame start "$@") >"$work/out" 2>"$work/err"
}
fstart login-flow || fail "frame start failed: $(cat "$work/err")"
grep -qx "branch docs/login-flow" "$work/out" || fail "frame branch line: $(cat "$work/out")"
grep -qx "worktree $work/app-frame-login-flow" "$work/out" || fail "frame worktree line: $(cat "$work/out")"
[ "$(git -C "$work/app-frame-login-flow" symbolic-ref --short HEAD)" = docs/login-flow ] || fail "frame worktree is not on its branch"
[ -f "$work/app-frame-login-flow/new.txt" ] || fail "frame branch not started from the fetched origin/main"
[ "$(git -C "$repo" symbolic-ref --short HEAD)" = main ] || fail "frame start moved the main checkout"
logged "project item" && fail "frame start touched the board"
fstart login-flow || fail "frame start rerun failed: $(cat "$work/err")"
[ "$(git -C "$repo" worktree list | grep -c app-frame-login-flow)" -eq 1 ] || fail "frame start rerun added a second worktree"
fstart "Billing, Stripe & invoices" || fail "frame start with a sentence failed: $(cat "$work/err")"
grep -qx "branch docs/billing-stripe-invoices" "$work/out" || fail "frame slug not normalised: $(cat "$work/out")"
for bad in "" "!!!"; do
  fstart "$bad" && fail "frame start accepted '$bad'"
done

# Two framings at once get two worktrees.
fstart other-idea || fail "second framing failed: $(cat "$work/err")"
[ -d "$work/app-frame-other-idea" ] || fail "second framing has no worktree of its own"

# An unpushed commit on the local default branch (a setup commit) would leak into the framing pull request.
git -C "$repo" merge -q --ff-only origin/main
echo local >"$repo/local.txt"
git -C "$repo" add -A
git -C "$repo" commit -q -m "chore: unpushed setup"
fstart ahead-idea && fail "frame start ran with main ahead of origin"
grep -q "ahead of origin" "$work/err" || fail "main ahead not explained: $(cat "$work/err")"
[ -e "$work/app-frame-ahead-idea" ] && fail "worktree created despite main ahead of origin"
git -C "$repo" show-ref -q --verify refs/heads/docs/ahead-idea && fail "branch created despite main ahead of origin"

[ "$failures" -eq 0 ] && echo "start: all cases pass"
exit "$failures"
