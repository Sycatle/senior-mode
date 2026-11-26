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
  "pr list "*) echo "${GH_PR_MERGED:-0}" ;;
  "project item-add"*) echo "ITEM" ;;
  "project item-edit"*) ;;
  "api graphql --input -") body=$(cat)
    if grep -q ProjectV2IterationField <<<"$body"; then cat "${GH_ITERATION:-/dev/null}"; exit 0; fi
    jq -nc --argjson i "${GH_IN_PROGRESS:-[]}" '{data: {node: {items: {
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
# Worktrees go to $XDG_DATA_HOME/senior-mode/worktrees/<repo>-<hash>/<name> (#224): never the real home.
export PATH="$work/stub:$PATH" GH_LOG="$work/gh.log" SENIOR_MODE_RETRY_DELAY=0 XDG_DATA_HOME="$work/xdg"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

git init -q --bare -b main "$work/origin.git"
repo="$work/app"
# <basename of the main checkout>-<8 hex of the cksum of its absolute path>
wt=$XDG_DATA_HOME/senior-mode/worktrees/app-$(printf '%08x' "$(printf '%s' "$repo" | cksum | cut -d' ' -f1)")
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

# The worktree lives in the user's data dir, never beside the repository nor under its .git (#224).
case $wt in "$work"/xdg/senior-mode/worktrees/app-????????) ;; *) fail "unexpected worktree root $wt" ;; esac
[ -z "$(ls -A "$repo/.git/senior-mode" 2>/dev/null)" ] || fail "something was created under .git/senior-mode: $(ls "$repo/.git/senior-mode")"
compgen -G "$work/app-[0-9]*" >/dev/null && fail "a ticket worktree beside the repository: $(ls "$work")"
[ -z "$(git -C "$repo" status --porcelain)" ] || fail "the main checkout is dirty: $(git -C "$repo" status --porcelain)"

# Rerunning reuses the branch and the worktree.
start 89 || fail "rerun failed: $(cat "$work/err")"
grep -qx "worktree $wt/89" "$work/out" || fail "rerun worktree line: $(cat "$work/out")"
[ "$(git -C "$repo" worktree list | grep -c "\[$branch\]")" -eq 1 ] || fail "rerun added a second worktree"
[ "$(wc -l <"$PM_LOG")" -eq 1 ] || fail "rerun installed again: $(cat "$PM_LOG")"

# #180: with the cycle fields on the board, the ticket gets the current iteration and Start today; without them, nothing more.
today=$(date -u +%Y-%m-%d)
day() { date -u -d "@$(($(date +%s) + $1 * 86400))" +%Y-%m-%d; }
cp "$repo/.claude/senior-mode.json" "$work/config.keep"
jq '.project.fields += {Iteration: {id: "F_I", iteration: true}, Start: {id: "F_St", date: true}, End: {id: "F_E", date: true}}' "$work/config.keep" >"$repo/.claude/senior-mode.json"
export GH_ITERATION="$work/iteration.json"
jq -nc --arg a "$(day -20)" --arg b "$(day -2)" '{data: {node: {field: {id: "F_I", configuration: {duration: 14,
  completedIterations: [{id: "it1", title: "Iteration 1", startDate: $a, duration: 14}],
  iterations: [{id: "it2", title: "Iteration 2", startDate: $b, duration: 14}]}}}}}' >"$GH_ITERATION"
issue "feat: cycle" '{"name": "type:feature"}'
start 77 || fail "start with cycle fields failed: $(cat "$work/err")"
logged "project item-edit --project-id PVT_1 --id ITEM --field-id F_I --iteration-id it2" || fail "iteration not set: $(cat "$GH_LOG")"
logged "project item-edit --project-id PVT_1 --id ITEM --field-id F_St --date $today" || fail "Start not set: $(cat "$GH_LOG")"
logged "--field-id F_E" && fail "End set at the start of a ticket: $(cat "$GH_LOG")"
issue "feat: late cycle" '{"name": "type:feature"}'
jq -nc --arg a "$(day -60)" '{data: {node: {field: {id: "F_I", configuration: {duration: 14, completedIterations: [],
  iterations: [{id: "it1", title: "Iteration 1", startDate: $a, duration: 14}]}}}}}' >"$GH_ITERATION"
start 78 || fail "start with no current iteration failed: $(cat "$work/err")"
logged "--field-id F_St --date $today" || fail "Start not set without an iteration: $(cat "$GH_LOG")"
logged "--iteration-id" && fail "an iteration that does not hold today was set: $(cat "$GH_LOG")"
grep -q "no iteration holds today" "$work/err" || fail "missing iteration not said: $(cat "$work/err")"
echo '{"data": {"node": {"field": null}}}' >"$GH_ITERATION"
start 78 || fail "start with a missing Iteration field failed: $(cat "$work/err")"
cp "$work/config.keep" "$repo/.claude/senior-mode.json"
unset GH_ITERATION
issue "feat: no cycle" '{"name": "type:feature"}'
start 79 || fail "start without cycle fields failed: $(cat "$work/err")"
logged "ProjectV2IterationField" && fail "the iteration is read on a board without the cycle fields"
logged "--date" && fail "a date was set on a board without the cycle fields"
# A reworded title does not fork the branch.
issue "Another title" '{"name": "type:feature"}'
start 89 || fail "reworded title failed: $(cat "$work/err")"
grep -qx "branch $branch" "$work/out" || fail "reworded title changed the branch: $(cat "$work/out")"

# A branch left without a worktree gets one again.
git -C "$repo" worktree remove "$wt/89"
start 89 || fail "existing branch failed: $(cat "$work/err")"
[ "$(git -C "$wt/89" symbolic-ref --short HEAD)" = "$branch" ] || fail "existing branch not checked out"

# Started from inside another worktree, the new one is still under the main repository's directory.
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

# A ticket started under .git/senior-mode/worktrees (the first form of #224) is reused too.
issue "Git dir style" ''
git -C "$repo" worktree add -q --no-track -b feat/86-git-dir-style "$repo/.git/senior-mode/worktrees/86" origin/main
start 86 || fail "start over a .git-path worktree failed: $(cat "$work/err")"
grep -qx "worktree $repo/.git/senior-mode/worktrees/86" "$work/out" || fail ".git-path worktree not reported: $(cat "$work/out")"
[ ! -e "$wt/86" ] || fail "a second worktree was created next to the .git-path one"

# Two clones with the same name never share a directory.
mkdir -p "$work/clones"
git clone -q "$work/origin.git" "$work/clones/app"
git -C "$work/clones/app" remote set-url origin git@github.com:acme/app.git
git -C "$work/clones/app" config url."$work/origin.git".insteadOf git@github.com:acme/app.git
issue "Second clone" ''
(cd "$work/clones/app" && "$cli" start 85) >"$work/out" 2>"$work/err" || fail "start in a second clone failed: $(cat "$work/err")"
second=$(sed -n 's/^worktree //p' "$work/out")
case $second in "$XDG_DATA_HOME"/senior-mode/worktrees/app-????????/85) ;; *) fail "second clone worktree: $second" ;; esac
[ "$(dirname "$second")" != "$wt" ] || fail "two clones named app share $wt"

# The type follows the label: bug, task, chore, none.
issue "Crash on login" '{"name": "type:bug"}, {"name": "needs-info"}'
branch_is 90 fix/90-crash-on-login
issue "Tidy things" '{"name": "type:task"}'
branch_is 91 chore/91-tidy-things
issue "Bump deps" '{"name": "type:chore"}'
branch_is 92 chore/92-bump-deps
# A spike (#321) works on a chore branch: a note is no feature, and the guards know that type.
issue "Can we use OAuth?" '{"name": "type:spike"}'
branch_is 84 chore/84-can-we-use-oauth
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
# A wip of 0 or a string is refused (#163), not read as a limit.
issue "Fourth thing" ''
for bad in 0 '"two"'; do
  jq --argjson w "$bad" '.wip = $w' "$repo/.claude/senior-mode.json" >"$work/c" && mv "$work/c" "$repo/.claude/senior-mode.json"
  start 104 && fail "started with wip $bad"
  grep -q 'wip must be a positive whole number' "$work/err" || fail "wip $bad refusal not explained: $(cat "$work/err")"
  [ -e "$wt/104" ] && fail "worktree created with wip $bad"
done
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
grep -qx "worktree $wt/frame-login-flow" "$work/out" || fail "frame worktree line: $(cat "$work/out")"
[ "$(git -C "$wt/frame-login-flow" symbolic-ref --short HEAD)" = docs/login-flow ] || fail "frame worktree is not on its branch"
[ -f "$wt/frame-login-flow/new.txt" ] || fail "frame branch not started from the fetched origin/main"
[ "$(git -C "$repo" symbolic-ref --short HEAD)" = main ] || fail "frame start moved the main checkout"
logged "project item" && fail "frame start touched the board"
fstart login-flow || fail "frame start rerun failed: $(cat "$work/err")"
[ "$(git -C "$repo" worktree list | grep -c "\[docs/login-flow\]")" -eq 1 ] || fail "frame start rerun added a second worktree"
fstart "Billing, Stripe & invoices" || fail "frame start with a sentence failed: $(cat "$work/err")"
grep -qx "branch docs/billing-stripe-invoices" "$work/out" || fail "frame slug not normalised: $(cat "$work/out")"
for bad in "" "!!!"; do
  fstart "$bad" && fail "frame start accepted '$bad'"
done

compgen -G "$work/app-frame-*" >/dev/null && fail "a framing worktree beside the repository: $(ls "$work")"

# A framing opened beside the repository before #224 is reused, not opened twice.
git -C "$repo" worktree add -q --no-track -b docs/old-idea "$work/app-frame-old-idea" origin/main
fstart old-idea || fail "frame start over an old-path worktree failed: $(cat "$work/err")"
grep -qx "worktree $work/app-frame-old-idea" "$work/out" || fail "old-path framing not reported: $(cat "$work/out")"
[ ! -e "$wt/frame-old-idea" ] || fail "a second framing worktree was created next to the old-path one"

# Started from inside a worktree, a framing is still under the main repository's git dir.
(cd "$wt/89" && "$cli" frame start from-a-worktree) >"$work/out" 2>"$work/err" || fail "frame start from a worktree failed: $(cat "$work/err")"
grep -qx "worktree $wt/frame-from-a-worktree" "$work/out" || fail "frame start from a worktree: $(cat "$work/out")"

# Two framings at once get two worktrees.
fstart other-idea || fail "second framing failed: $(cat "$work/err")"
[ -d "$wt/frame-other-idea" ] || fail "second framing has no worktree of its own"

# An unpushed commit on the local default branch (a setup commit) would leak into the framing pull request.
git -C "$repo" merge -q --ff-only origin/main
echo local >"$repo/local.txt"
git -C "$repo" add -A
git -C "$repo" commit -q -m "chore: unpushed setup"
fstart ahead-idea && fail "frame start ran with main ahead of origin"
grep -q "ahead of origin" "$work/err" || fail "main ahead not explained: $(cat "$work/err")"
[ -e "$wt/frame-ahead-idea" ] && fail "worktree created despite main ahead of origin"
git -C "$repo" show-ref -q --verify refs/heads/docs/ahead-idea && fail "branch created despite main ahead of origin"

# frame decide <issue> <question> <answer> (#310): one dated line per framing answer in docs/decisions.md of the
# repository it runs in, linked to its ticket; a rerun adds nothing.
decide() {
  (cd "$wt/frame-login-flow" && "$cli" frame decide "$@") >"$work/out" 2>"$work/err"
}
log=$wt/frame-login-flow/docs/decisions.md
today=$(date -u +%F)
decide 310 "Where do answers go?" "docs/decisions.md" || fail "frame decide failed: $(cat "$work/err")"
[ -f "$log" ] || fail "frame decide wrote no docs/decisions.md"
head -n 1 "$log" | grep -qx "# Decision log" || fail "decision log has no title: $(cat "$log")"
grep -qxF -- "- $today #310: Where do answers go? -> docs/decisions.md" "$log" || fail "decision line missing: $(cat "$log")"
decide 310 "Where do answers go?" "docs/decisions.md" || fail "frame decide rerun failed: $(cat "$work/err")"
[ "$(grep -c '^- ' "$log")" -eq 1 ] || fail "rerun duplicated the decision: $(cat "$log")"
decide 311 $'One question\nover two lines?' "the recommended one (assumed)" || fail "second decide failed: $(cat "$work/err")"
grep -qxF -- "- $today #311: One question over two lines? -> the recommended one (assumed)" "$log" || fail "newline not folded or line not appended: $(cat "$log")"
[ "$(grep -c '^- ' "$log")" -eq 2 ] || fail "decisions not appended: $(cat "$log")"
[ "$(sed -n 's/^- [0-9-]* #310.*/x/p' "$log" | head -n 1)" = x ] || fail "oldest decision not first: $(cat "$log")"
for bad in "abc|q|a" "310||a" "310|q|" "0|q|a"; do
  IFS='|' read -r i q a <<<"$bad"
  decide "$i" "$q" "$a" && fail "frame decide accepted '$bad'"
done
(cd "$work" && "$cli" frame decide 310 q a) >"$work/out" 2>"$work/err" && fail "frame decide ran outside a repository"

# #639: frame decide says which branch received the line, and refuses on the default branch and on a branch whose pull
# request is merged; the log merges as a union, so two framings that each log a decision rebase without a conflict.
decide 312 "Which branch?" "this one" || fail "frame decide failed: $(cat "$work/err")"
grep -q 'on branch docs/login-flow' "$work/out" || fail "frame decide does not name its branch: $(cat "$work/out")"
(cd "$repo" && "$cli" frame decide 313 q a) >"$work/out" 2>"$work/err" && fail "frame decide wrote on the default branch"
grep -q 'default branch' "$work/err" || fail "default branch refusal not explained: $(cat "$work/err")"
[ ! -e "$repo/docs/decisions.md" ] || fail "frame decide wrote docs/decisions.md on the default branch"
GH_PR_MERGED=1 decide 314 q a && fail "frame decide wrote on a branch whose pull request is merged"
grep -q 'merged' "$work/err" || fail "merged branch refusal not explained: $(cat "$work/err")"
grep -q '#314' "$log" && fail "a decision was logged on a merged branch"
[ "$(git -C "$wt/frame-login-flow" check-attr merge -- docs/decisions.md | sed 's/.*: //')" = union ] ||
  fail "frame decide did not set merge=union for the log: $(cat "$wt/frame-login-flow/.gitattributes" 2>&1)"
(cd "$wt/frame-other-idea" && "$cli" frame decide 320 "Other question?" "other answer") >"$work/out" 2>"$work/err" || fail "decide on the second framing failed: $(cat "$work/err")"
git -C "$wt/frame-login-flow" add -A && git -C "$wt/frame-login-flow" commit -q -m "docs: decisions of login-flow"
git -C "$wt/frame-other-idea" add -A && git -C "$wt/frame-other-idea" commit -q -m "docs: decisions of other-idea"
git -C "$wt/frame-other-idea" rebase -q docs/login-flow >"$work/out" 2>&1 || {
  git -C "$wt/frame-other-idea" rebase --abort 2>/dev/null
  fail "two framings that each log a decision conflict on a rebase: $(cat "$work/out")"
}
for n in 310 320; do
  grep -q "#$n" "$wt/frame-other-idea/docs/decisions.md" || fail "the rebased log lost #$n: $(cat "$wt/frame-other-idea/docs/decisions.md")"
done

# #311: the Given/When/Then criteria of the body become failing test skeletons, the first commit of a new branch.
body=$'## Context\n\nx\n\n## Acceptance criteria\n\n- Given a user, when she signs in, then she sees "home".\n- [ ] Given a bad token,\n  when it is sent, then the API says 401.\n- When nothing is said, then nothing happens.\n\n```\n- Given code, it is not read\n```\n'
GH_ISSUE=$(jq -nc --arg b "$body" '{title: "feat: skeletons", state: "OPEN", labels: [{name: "type:feature"}], body: $b}')
start 311 || fail "start with criteria failed: $(cat "$work/err")"
sk=$wt/311
[ "$(git -C "$sk" rev-list --count origin/main..HEAD)" -eq 1 ] || fail "skeletons are not one first commit: $(git -C "$sk" log --oneline origin/main..HEAD)"
git -C "$sk" log -1 --format=%B | grep -qx 'Refs #311' || fail "skeleton commit does not name the ticket"
[ -z "$(git -C "$sk" status --porcelain)" ] || fail "skeleton left the worktree dirty: $(git -C "$sk" status --porcelain)"
grep -q '^skeleton tests/ticket-311.test.js (2 failing cases, first commit)' "$work/out" || fail "skeleton line: $(cat "$work/out")"
[ "$(grep -c '^it(' "$sk/tests/ticket-311.test.js")" -eq 2 ] || fail "one case per Given criterion, none for the fence or a bare When: $(cat "$sk/tests/ticket-311.test.js")"
grep -qF 'it("Given a user, when she signs in, then she sees \"home\".", () => {' "$sk/tests/ticket-311.test.js" || fail "a case is not named after its criterion: $(cat "$sk/tests/ticket-311.test.js")"
grep -qF 'it("Given a bad token, when it is sent, then the API says 401.", () => {' "$sk/tests/ticket-311.test.js" || fail "a continuation line is not folded: $(cat "$sk/tests/ticket-311.test.js")"
grep -q 'not implemented' "$sk/tests/ticket-311.test.js" || fail "a skeleton does not fail"
# Rerunning adds nothing; a ticket with no criterion, or no feature or fix, gets no skeleton.
start 311 || fail "rerun with a skeleton failed"
[ "$(git -C "$sk" rev-list --count origin/main..HEAD)" -eq 1 ] || fail "rerun added a commit"
GH_ISSUE=$(jq -nc '{title: "feat: plain", state: "OPEN", labels: [{name: "type:feature"}], body: "## Acceptance criteria\n\n- It works.\n"}')
start 312 || fail "start without criteria failed: $(cat "$work/err")"
[ "$(git -C "$wt/312" rev-list --count origin/main..HEAD)" -eq 0 ] || fail "a ticket with no Given criterion got a commit"
GH_ISSUE=$(jq -nc --arg b "$body" '{title: "chore: tidy", state: "OPEN", labels: [{name: "type:chore"}], body: $b}')
start 313 || fail "start of a chore failed: $(cat "$work/err")"
[ "$(git -C "$wt/313" rev-list --count origin/main..HEAD)" -eq 0 ] || fail "a chore got a skeleton"
# A commit the project refuses (a hook) leaves nothing behind and does not stop start.
GH_ISSUE=$(jq -nc --arg b "$body" '{title: "feat: hooked", state: "OPEN", labels: [{name: "type:feature"}], body: $b}')
mkdir -p "$work/hooks"
printf '#!/bin/sh\nexit 1\n' >"$work/hooks/commit-msg"
chmod +x "$work/hooks/commit-msg"
git -C "$repo" config core.hooksPath "$work/hooks"
start 314 || fail "start with a refusing hook failed: $(cat "$work/err")"
git -C "$repo" config --unset core.hooksPath
grep -q 'could not commit the test skeletons' "$work/err" || fail "a refused commit is not said: $(cat "$work/err")"
[ -z "$(git -C "$wt/314" status --porcelain)" ] || fail "a refused skeleton left files: $(git -C "$wt/314" status --porcelain)"
unset GH_ISSUE

# The skeleton of each preset names its cases after the criteria and fails.
skel() { bash -c 'source "$1/lib/common.sh"; source "$1/lib/skeleton.sh"; shift; skeleton_render "$@"' _ "$(dirname "$cli")" "$@"; }
crit=$'Given a user, when she signs in, then 100% of "x" works\nGiven b, when c, then d'
skel python 7 py <<<"$crit" >"$work/t_py.py"
grep -q '^def test_ticket7_1_given_a_user_when_she_signs_in_th' "$work/t_py.py" || fail "python case name: $(cat "$work/t_py.py")"
if command -v python3 >/dev/null; then
  python3 -m pytest --version >/dev/null 2>&1 && { (cd "$work" && python3 -m pytest -q t_py.py >/dev/null 2>&1) && fail "a python skeleton passes"; }
  python3 -m py_compile "$work/t_py.py" 2>/dev/null || fail "python skeleton does not compile"
fi
skel go 7 go <<<"$crit" >"$work/t_go.go"
grep -q '^func TestTicket7_2_given_b_when_c_then_d(t \*testing.T) {' "$work/t_go.go" || fail "go case name: $(cat "$work/t_go.go")"
grep -q '^package tests' "$work/t_go.go" || fail "go package: $(cat "$work/t_go.go")"
skel rust 7 rs <<<"$crit" >"$work/t_rs.rs"
grep -q '^fn ticket_7_2_given_b_when_c_then_d() {' "$work/t_rs.rs" || fail "rust case name: $(cat "$work/t_rs.rs")"
grep -q '#\[test\]' "$work/t_rs.rs" || fail "rust test attribute"
skel node 7 ts <<<"$crit" >"$work/t_ts.ts"
grep -q '^import { expect, it } from "vitest";' "$work/t_ts.ts" || fail "vitest import: $(cat "$work/t_ts.ts")"
skel node 7 js <<<"$crit" >"$work/t_js.js"
grep -q 'vitest' "$work/t_js.js" && fail "a jest skeleton imports vitest"
skel generic 7 sh <<<"$crit" >"$work/t.sh"
bash -n "$work/t.sh" || fail "bash skeleton does not parse: $(cat "$work/t.sh")"
bash "$work/t.sh" >"$work/t.out" 2>&1 && fail "a bash skeleton passes"
grep -q '^FAIL: Given b, when c, then d: not implemented' "$work/t.out" || fail "bash skeleton output: $(cat "$work/t.out")"
[ "$(grep -c 'not implemented' "$work/t.out")" -eq 2 ] || fail "bash skeleton does not fail once per criterion: $(cat "$work/t.out")"
if command -v go >/dev/null; then
  mkdir -p "$work/gomod/tests" && printf 'module x\n\ngo 1.21\n' >"$work/gomod/go.mod" && cp "$work/t_go.go" "$work/gomod/tests/ticket_7_test.go"
  (cd "$work/gomod" && go test ./... >/dev/null 2>&1) && fail "a go skeleton passes"
fi

# #416: `--base <ref>` starts a new branch from origin/<ref> (a stacked pull request) and says so; a branch of the
# ticket on origin only comes back as a local branch that tracks it; a branch that exists wins over --base; a
# missing ref stops before anything is created.
git -C "$other" checkout -q -b feat/200-base main
echo stacked >"$other/stacked.txt"
git -C "$other" add -A
git -C "$other" commit -q -m "feat: base"
git -C "$other" push -q origin feat/200-base
git -C "$other" checkout -q -b feat/420-remote-work main
echo remote >"$other/remote.txt"
git -C "$other" add -A
git -C "$other" commit -q -m "feat: remote work"
git -C "$other" push -q origin feat/420-remote-work
issue "feat: stacked" '{"name": "type:feature"}'
start 410 --base feat/200-base || fail "start --base failed: $(cat "$work/err")"
[ -f "$wt/410/stacked.txt" ] || fail "--base: the worktree is not made from origin/feat/200-base"
grep -qx "base origin/feat/200-base" "$work/out" || fail "--base: the base used is not printed: $(cat "$work/out")"
git -C "$repo" config --get "branch.feat/410-stacked.remote" >/dev/null && fail "--base: the new branch tracks its base"
start 410 --base feat/200-base || fail "rerun with --base failed: $(cat "$work/err")"
grep -qx "base feat/200-base ignored: the branch feat/410-stacked exists" "$work/out" || fail "--base on an existing branch: $(cat "$work/out")"
[ "$(grep -c ignored "$work/out")" -eq 1 ] || fail "the ignored base is not said once: $(cat "$work/out")"
issue "feat: remote work" '{"name": "type:feature"}'
start 420 || fail "start of a branch on origin failed: $(cat "$work/err")"
grep -qx "branch feat/420-remote-work" "$work/out" || fail "remote branch name: $(cat "$work/out")"
[ -f "$wt/420/remote.txt" ] || fail "the commits of the remote branch are missing"
[ "$(git -C "$repo" config --get branch.feat/420-remote-work.remote)" = origin ] || fail "the local branch does not track origin"
[ "$(git -C "$repo" config --get branch.feat/420-remote-work.merge)" = refs/heads/feat/420-remote-work ] || fail "wrong upstream branch"
[ "$(git -C "$wt/420" rev-list --count origin/main..HEAD)" -eq 1 ] || fail "a skeleton or a stray commit on the remote branch"
git -C "$repo" worktree remove "$wt/420"
git -C "$repo" branch -q -D feat/420-remote-work
start 420 --base feat/200-base || fail "remote branch with --base failed: $(cat "$work/err")"
[ -f "$wt/420/remote.txt" ] && [ ! -f "$wt/420/stacked.txt" ] || fail "--base won over the branch on origin"
grep -q "^base feat/200-base ignored" "$work/out" || fail "--base on a remote branch not said: $(cat "$work/out")"
issue "feat: no such base" '{"name": "type:feature"}'
start 430 --base no/such-ref && fail "--base with a missing ref succeeded"
grep -q "no/such-ref" "$work/err" || fail "missing ref not named: $(cat "$work/err")"
[ ! -e "$wt/430" ] || fail "a worktree was created for a missing base"
git -C "$repo" show-ref -q --verify "refs/heads/feat/430-no-such-base" && fail "a branch was created for a missing base"
start 430 --base && fail "--base without a value succeeded"
start 430 --nope && fail "an unknown flag succeeded"

[ "$failures" -eq 0 ] && echo "start: all cases pass"
exit "$failures"
