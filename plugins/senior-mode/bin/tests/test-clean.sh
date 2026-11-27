#!/usr/bin/env bash
# Tests for `senior-mode clean` (#225). Offline: gh is a stub serving the pull requests ($FIX/prs.ndjson),
# the issues ($FIX/issues.json: number -> state) and the board (tickets $GH_IN_PROGRESS In progress);
# origin is a local bare repository reached through an insteadOf rewrite of the GitHub URL. Worktrees go
# to a temporary XDG_DATA_HOME, never the real home.
# shellcheck disable=SC2016 # jq programs and stub bodies, not expanded here
set -u
cli=$(cd "$(dirname "$0")/.." && pwd)/senior-mode
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

mkdir -p "$work/stub" "$work/fix"
cat >"$work/stub/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$GH_LOG"
case "$*" in
  "pr list"*) [ -f "$FIX/prs.ndjson" ] && jq -s . "$FIX/prs.ndjson" || echo '[]' ;;
  "api repos/"*"/branches?protected"*)
    [ ! -f "$FIX/protected-fail" ] || { echo "HTTP 403" >&2; exit 1; }
    cat "$FIX/protected" 2>/dev/null; true ;;
  "issue view "*)
    n=$(sed -E 's#^issue view ([0-9]+) .*#\1#' <<<"$*")
    jq -nc --arg s "$(jq -r --arg n "$n" '.[$n] // "OPEN"' "$FIX/issues.json")" '{state: $s}' ;;
  "api graphql --input -") cat >/dev/null; jq -nc --argjson i "${GH_IN_PROGRESS:-[]}" '{data: {node: {items: {
    pageInfo: {hasNextPage: false}, nodes: ($i | map({fieldValues: {nodes: [{name: "In progress", field: {name: "Status"}}]},
      content: {number: ., title: "Ticket \(.)", url: "u", state: "OPEN", labels: {nodes: []}, milestone: null,
        blockedBy: {nodes: []}}}))}}}}' ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$work/stub/gh"
echo '{"7": "CLOSED", "9": "OPEN"}' >"$work/fix/issues.json"
export PATH="$work/stub:$PATH" GH_LOG="$work/gh.log" FIX="$work/fix" SENIOR_MODE_RETRY_DELAY=0 XDG_DATA_HOME="$work/xdg"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
: >"$GH_LOG"

git init -q --bare -b main "$work/origin.git"
repo="$work/app"
wt=$XDG_DATA_HOME/senior-mode/worktrees/app-$(printf '%08x' "$(printf '%s' "$repo" | cksum | cut -d' ' -f1)")
git init -q -b main "$repo"
git -C "$repo" remote add origin git@github.com:acme/app.git
git -C "$repo" config url."$work/origin.git".insteadOf git@github.com:acme/app.git
mkdir -p "$repo/.claude"
echo '{"project": {"id": "PVT_1", "owner": "acme", "number": 3}}' >"$repo/.claude/senior-mode.json"
git -C "$repo" add -A
git -C "$repo" commit -q -m "chore: start"
git -C "$repo" push -q origin main
git -C "$repo" fetch -q origin
git -C "$repo" remote set-head origin main >/dev/null

ago() { date -u -d "@$(($(date +%s) - $1 * 86400))" +%Y-%m-%dT%H:%M:%SZ; }
tip() { git -C "$repo" rev-parse "refs/heads/$1"; }
# A branch with a commit of its own in a worktree at $2, pushed to origin unless $3 is nopush.
mk() {
  git -C "$repo" worktree add -q --no-track -b "$1" "$2" main
  (cd "$2" && echo "$1" >"file-$$.txt" && git add -A && git commit -q -m "feat: $1")
  [ "${3:-}" = nopush ] || git -C "$2" push -q origin "$1"
}
# A commit of its own, on no branch: its sha.
orphan() { git -C "$repo" commit-tree -p main -m "$1" 'main^{tree}'; }
# pr <number> <state> <branch> <days ago> <head sha> [base branch, main by default]
pr() {
  jq -nc --argjson n "$1" --arg s "$2" --arg b "$3" --arg t "$(ago "$4")" --arg o "$5" --arg base "${6:-main}" '{number: $n, state: $s,
    headRefName: $b, baseRefName: $base, headRefOid: $o, isCrossRepository: false,
    mergedAt: (if $s == "MERGED" then $t else null end), closedAt: (if $s == "OPEN" then null else $t end)}' >>"$FIX/prs.ndjson"
}

# A squash merge: the default branch moves on without the commits of the branches.
git -C "$repo" commit -q --allow-empty -m "feat: squashed"
git -C "$repo" push -q origin main
main_tip=$(git -C "$repo" rev-parse main)

mk feat/1-merged-old "$wt/1"
pr 101 MERGED feat/1-merged-old 30 "$(tip feat/1-merged-old)"
mk feat/2-merged-new "$wt/2"
pr 102 MERGED feat/2-merged-new 3 "$(tip feat/2-merged-new)"
mk feat/3-dirty "$wt/3"
pr 103 MERGED feat/3-dirty 3 "$(tip feat/3-dirty)"
echo wip >"$wt/3/untracked.txt"
mk feat/4-unpushed "$wt/4" nopush
pr 104 CLOSED feat/4-unpushed 3 "$main_tip"
mk feat/5-open "$wt/5"
pr 105 OPEN feat/5-open 0 "$(tip feat/5-open)"
mk feat/6-progress "$wt/6"
pr 106 MERGED feat/6-progress 30 "$(tip feat/6-progress)"
# Ticket worktrees of the earlier forms: beside the repository, under .git/senior-mode/worktrees.
mk feat/7-issue-closed "$work/app-7"
mk fix/8-gitdir "$repo/.git/senior-mode/worktrees/8"
pr 108 CLOSED fix/8-gitdir 3 "$(tip fix/8-gitdir)"
mk feat/9-issue-open "$wt/9"
mk feat/10-current "$wt/10"
pr 110 MERGED feat/10-current 3 "$(tip feat/10-current)"
# The remote branch of a squash-merged pull request was deleted by GitHub: the local tip is the pull request's head.
mk feat/15-autodeleted "$wt/15" nopush
pr 115 MERGED feat/15-autodeleted 30 "$(tip feat/15-autodeleted)"
# A branch without a worktree: one at a commit of the default branch, one with a commit pushed nowhere.
git -C "$repo" branch feat/11-nowt main
pr 111 MERGED feat/11-nowt 3 "$main_tip"
git -C "$repo" branch feat/14-bare "$(orphan bare)"
pr 114 CLOSED feat/14-bare 3 "$main_tip"
# Remote branches nobody has locally.
sha12=$(orphan remote12)
git -C "$repo" push -q origin "$sha12:refs/heads/chore/12-remote"
pr 112 MERGED chore/12-remote 20 "$sha12"
git -C "$repo" push -q origin "$(orphan after-merge):refs/heads/feat/16-after"
pr 116 MERGED feat/16-after 30 "$sha12"
# Long-lived branches whose pull request merged long ago (dev into main) are never deleted, locally or on origin,
# nor a release branch; neither is the base of any pull request, open, closed or merged (a stack), nor a
# protected branch. Only the branches start and frame make are candidates.
git -C "$repo" branch dev "$(orphan dev)"
git -C "$repo" push -q origin dev
pr 130 MERGED dev 30 "$(tip dev)"
git -C "$repo" push -q origin "$sha12:refs/heads/release/1.0"
pr 131 MERGED release/1.0 30 "$sha12"
git -C "$repo" branch feat/18-base "$(orphan base18)"
git -C "$repo" push -q origin feat/18-base
pr 132 MERGED feat/18-base 30 "$(tip feat/18-base)"
pr 133 OPEN feat/19-stack 0 "$main_tip" feat/18-base
git -C "$repo" branch feat/22-closedbase "$(orphan base22)"
git -C "$repo" push -q origin feat/22-closedbase
pr 134 MERGED feat/22-closedbase 30 "$(tip feat/22-closedbase)"
pr 135 CLOSED feat/23-old 40 "$main_tip" feat/22-closedbase
git -C "$repo" branch chore/24-protected "$(orphan prot24)"
git -C "$repo" push -q origin chore/24-protected
pr 136 MERGED chore/24-protected 30 "$(tip chore/24-protected)"
echo chore/24-protected >"$FIX/protected"
# #243: only the names `frame start` makes (`docs/<slug>`, a slug of lower-case letters, digits and single
# hyphens, 40 characters at most) and `run` makes (`docs/run-<stamp>`) are candidates; any other docs/ branch is kept.
git -C "$repo" push -q origin "$sha12:refs/heads/docs/frame-idea"
pr 140 MERGED docs/frame-idea 30 "$sha12"
git -C "$repo" push -q origin "$sha12:refs/heads/docs/run-20260101-101010-42"
pr 141 MERGED docs/run-20260101-101010-42 30 "$sha12"
git -C "$repo" push -q origin "$sha12:refs/heads/docs/next.v2"
pr 142 MERGED docs/next.v2 30 "$sha12"
git -C "$repo" push -q origin "$sha12:refs/heads/docs/Next_notes"
pr 143 MERGED docs/Next_notes 30 "$sha12"
git -C "$repo" push -q origin "$sha12:refs/heads/docs/a/b"
pr 144 MERGED docs/a/b 30 "$sha12"
git -C "$repo" branch docs/frame-local main
pr 145 MERGED docs/frame-local 3 "$main_tip"
git -C "$repo" branch docs/Local_notes main
pr 146 MERGED docs/Local_notes 3 "$main_tip"
# A branch deleted on origin behind our back: its tracking ref is stale and must not count as pushed.
mk feat/17-stale "$wt/17"
git -C "$work/origin.git" branch -q -D feat/17-stale
pr 117 CLOSED feat/17-stale 3 "$main_tip"
# Files of the runs.
common=$repo/.git/senior-mode
mkdir -p "$common/runs/old" "$common/runs/new" "$common/checks"
echo t >"$common/runs/old/token"
echo log >"$common/runs/old/10-sonnet.log"
echo log >"$common/runs/new/10-sonnet.log"
echo 2026-01-01 >"$common/probe"
echo out >"$common/probe.log"
echo ok >"$common/checks/abc"
touch -d '30 days ago' "$common/runs/old/token" "$common/runs/old/10-sonnet.log" "$common/runs/old" "$common/probe"

export GH_IN_PROGRESS='[6]'
snapshot() {
  git -C "$repo" worktree list
  git -C "$repo" for-each-ref --format='%(refname) %(objectname)' refs/heads refs/tags
  git -C "$repo" ls-remote origin
  (cd "$common" && find . -type f -o -type d | sort)
  ls -A "$wt/3"
}
clean() {
  (cd "${CLEAN_FROM:-$repo}" && "$cli" clean "$@") >"$work/out" 2>"$work/err"
}
has() { grep -qF -- "$1" "$work/out"; }
heads() { git -C "$repo" ls-remote --heads origin | sed 's#.*refs/heads/##'; }
branches() { git -C "$repo" for-each-ref --format='%(refname:short)' refs/heads; }

# --dry-run: says exactly what it would remove, changes nothing.
before=$(snapshot)
clean --dry-run || fail "dry run failed: $(cat "$work/err")"
[ "$(snapshot)" = "$before" ] || fail "--dry-run changed something"
for l in "would remove worktree $wt/1 " "would remove worktree $wt/2 " "would remove worktree $wt/15 " \
  "would remove worktree $work/app-7 " "would remove worktree $repo/.git/senior-mode/worktrees/8 " \
  "would remove worktree $wt/10 " "would remove branch feat/1-merged-old " "would remove branch feat/11-nowt " \
  "would remove remote branch feat/1-merged-old " "would remove remote branch chore/12-remote " \
  "would remove run $common/runs/old " "would remove file $common/probe "; do
  has "$l" || fail "dry run does not say: $l: $(cat "$work/out")"
done
for l in "feat/5-open" "feat/9-issue-open" "$common/runs/new" "$common/probe.log" \
  "$common/checks"; do
  ! grep -F "would remove" "$work/out" | grep -qF -- "$l" || fail "dry run would remove: $l"
done
! grep -F "would remove remote branch" "$work/out" | grep -qF feat/2-merged-new || fail "dry run would remove a recent remote branch"
for l in "would remove remote branch docs/frame-idea " "would remove remote branch docs/run-20260101-101010-42 " \
  "would remove branch docs/frame-local " "kept remote branch docs/next.v2: not a branch senior-mode makes" \
  "kept remote branch docs/Next_notes: not a branch senior-mode makes" "kept remote branch docs/a/b: not a branch senior-mode makes" \
  "kept branch docs/Local_notes: not a branch senior-mode makes"; do
  has "$l" || fail "dry run does not say: $l: $(cat "$work/out")"
done
has "pull request #101 merged" || fail "dry run gives no reason: $(cat "$work/out")"
has "would run: git worktree prune" || fail "dry run does not mention the prune: $(cat "$work/out")"

for l in "kept branch dev: " "kept remote branch dev: " "kept remote branch release/1.0: " "kept branch feat/18-base: base of pull request #133" \
  "kept remote branch feat/18-base: base of pull request #133" "kept remote branch feat/22-closedbase: base of pull request #135" \
  "kept branch chore/24-protected: protected" "kept remote branch chore/24-protected: protected" \
  "kept worktree $wt/17 (feat/17-stale): 1 commit on no remote branch"; do
  has "$l" || fail "dry run does not say: $l: $(cat "$work/out")"
done
grep -F "would remove" "$work/out" | grep -qE 'branch (dev|release/1.0|feat/18-base|feat/22-closedbase|chore/24-protected)( |$)' &&
  fail "dry run would remove a long-lived, base or protected branch: $(cat "$work/out")"
grep -q 'fetch' "$GH_LOG" && fail "fetch is git, not gh"
# --days and hygiene.days move the line: a 30 day old pull request and old files are not old enough for 40.
clean --dry-run --days 40 || fail "dry run --days failed: $(cat "$work/err")"
has "would remove remote branch" && fail "--days 40 still removes a remote branch: $(cat "$work/out")"
has "would remove run" && fail "--days 40 still removes a run: $(cat "$work/out")"
has "would remove worktree $wt/1 " || fail "--days 40 spares the worktree of a merged pull request: $(cat "$work/out")"
jq '.hygiene.days = 40' "$repo/.claude/senior-mode.json" >"$work/cfg" && cp "$work/cfg" "$repo/.claude/senior-mode.json"
clean --dry-run || fail "dry run with hygiene.days failed: $(cat "$work/err")"
has "would remove remote branch" && fail "hygiene.days 40 still removes a remote branch: $(cat "$work/out")"
clean --dry-run --days 1 || fail "dry run --days 1 failed: $(cat "$work/err")"
has "would remove remote branch feat/2-merged-new " || fail "--days 1 spares a 3 day old pull request: $(cat "$work/out")"
git -C "$repo" checkout -q -- .claude/senior-mode.json
for bad in "--days 0" "--days abc" "--days" "--bogus"; do
  # shellcheck disable=SC2086
  clean $bad && fail "clean $bad accepted"
done
echo '{"project": {"id": "PVT_1", "owner": "acme", "number": 3}, "hygiene": {"days": "x"}}' >"$work/cfg"
cp "$repo/.claude/senior-mode.json" "$work/cfg.keep"
cp "$work/cfg" "$repo/.claude/senior-mode.json"
clean && fail "a bad hygiene.days was accepted"
grep -q 'hygiene.days' "$work/err" || fail "bad hygiene.days not explained: $(cat "$work/err")"
cp "$work/cfg.keep" "$repo/.claude/senior-mode.json"

# For real, from inside the worktree of #10: it is the current one and stays.
CLEAN_FROM=$wt/10 clean || fail "clean failed: $(cat "$work/err")"
for n in 1 2 15; do [ ! -e "$wt/$n" ] || fail "worktree $n not removed"; done
[ ! -e "$work/app-7" ] || fail "the worktree beside the repository was not removed"
[ ! -e "$repo/.git/senior-mode/worktrees/8" ] || fail "the worktree under .git/senior-mode/worktrees was not removed"
for n in 3 4 5 6 9 10; do [ -d "$wt/$n" ] || fail "worktree $n was removed"; done
[ -d "$repo" ] || fail "the main worktree is gone"
git -C "$repo" worktree list | grep -q "$wt/1 " && fail "worktree 1 still registered"
for b in feat/1-merged-old feat/2-merged-new feat/7-issue-closed fix/8-gitdir feat/15-autodeleted feat/11-nowt; do
  branches | grep -qx "$b" && fail "branch $b not removed"
done
for b in feat/3-dirty feat/4-unpushed feat/5-open feat/6-progress feat/9-issue-open feat/10-current feat/14-bare; do
  branches | grep -qx "$b" || fail "branch $b was removed"
done
branches | grep -qx main || fail "main was removed"
heads | grep -qx feat/1-merged-old && fail "remote branch of a pull request merged 30 days ago kept"
heads | grep -qx chore/12-remote && fail "remote-only branch of a pull request merged 20 days ago kept"
for b in main feat/2-merged-new feat/3-dirty feat/5-open feat/6-progress feat/7-issue-closed fix/8-gitdir feat/9-issue-open \
  feat/10-current feat/16-after; do
  heads | grep -qx "$b" || fail "remote branch $b was removed"
done
for b in dev feat/18-base feat/22-closedbase chore/24-protected feat/17-stale; do
  branches | grep -qx "$b" || fail "branch $b was removed"
done
for b in dev release/1.0 feat/18-base feat/22-closedbase chore/24-protected; do
  heads | grep -qx "$b" || fail "remote branch $b was removed"
done
[ ! -e "$common/runs/old" ] || fail "old run not removed"
[ -f "$common/runs/new/10-sonnet.log" ] || fail "recent run removed"
[ ! -e "$common/probe" ] || fail "old probe date not removed"
[ -f "$common/probe.log" ] || fail "recent probe.log removed"
[ -f "$common/checks/abc" ] || fail "a check record was removed"
[ -f "$wt/3/untracked.txt" ] || fail "uncommitted work lost"
has "removed worktree $wt/1 " || fail "no 'removed' line: $(cat "$work/out")"
grep -q "kept worktree $wt/3 .*uncommitted changes" "$work/out" || fail "dirty worktree not listed with its reason: $(cat "$work/out")"
grep -q "kept worktree $wt/4 .*1 commit on no remote branch and not in origin/main" "$work/out" ||
  fail "unpushed worktree not listed with its reason: $(cat "$work/out")"
grep -q "kept branch feat/14-bare: 1 commit on no remote branch" "$work/out" || fail "unpushed branch not listed: $(cat "$work/out")"
grep -q "kept .*feat/6-progress.*In progress" "$work/out" || fail "In progress ticket not listed: $(cat "$work/out")"
grep -q "kept remote branch feat/16-after.*commits" "$work/out" || fail "remote branch past its pull request not listed: $(cat "$work/out")"
grep -q "$wt/10" "$work/out" && fail "the current worktree is mentioned: $(cat "$work/out")"
grep -q 'worktree prune' "$work/out" && fail "a real run only says it would prune"
git -C "$repo" worktree list | grep -q 'prunable' && fail "stale worktree records left"
grep -q "pr list" "$GH_LOG" || fail "the pull requests were not read from GitHub"

# From the main checkout it removes #10 too; a third run has nothing left to remove.
clean || fail "second clean failed: $(cat "$work/err")"
[ ! -e "$wt/10" ] || fail "worktree 10 not removed once it is not the current one"
branches | grep -qx feat/10-current && fail "branch 10 kept"
clean || fail "third clean failed: $(cat "$work/err")"
grep -q '^removed\|^would' "$work/out" && fail "a third run removed something: $(cat "$work/out")"

# A prunable worktree (its directory deleted by hand) is pruned, and its branch goes with it.
git -C "$repo" worktree add -q --no-track -b feat/20-gone "$wt/20" main
pr 120 MERGED feat/20-gone 3 "$main_tip"
rm -rf "$wt/20"
clean || fail "clean with a prunable worktree failed: $(cat "$work/err")"
git -C "$repo" worktree list | grep -q "$wt/20" && fail "prunable worktree not pruned"
branches | grep -qx feat/20-gone && fail "the branch of a worktree deleted by hand is kept"

# The board cannot be read: nothing is removed.
git -C "$repo" worktree add -q --no-track -b feat/21-late "$wt/21" main
pr 121 MERGED feat/21-late 3 "$main_tip"
before=$(snapshot)
mkdir -p "$work/failstub"
cat >"$work/failstub/gh" <<'STUB'
#!/usr/bin/env bash
[ "$*" = "api graphql --input -" ] && { cat >/dev/null; echo "HTTP 401" >&2; exit 1; }
exec "$REAL_STUB" "$@"
STUB
chmod +x "$work/failstub/gh"
REAL_STUB=$work/stub/gh PATH="$work/failstub:$PATH" clean && fail "clean succeeded without the board"
[ "$(snapshot)" = "$before" ] || fail "clean removed something without the board"

# #243: when origin cannot be fetched (no ssh agent in a scheduled run) the remote-tracking refs may be stale, so
# whether a commit is pushed is unknown: a branch whose commits only a tracking ref vouches for is kept, and it
# says so. What GitHub vouches for (its commits are in the default branch or in its pull request) still goes.
mk feat/30-vanished "$wt/30"
git -C "$work/origin.git" branch -q -D feat/30-vanished
pr 150 CLOSED feat/30-vanished 3 "$main_tip"
git -C "$repo" branch feat/31-in-main main
pr 151 MERGED feat/31-in-main 3 "$main_tip"
mv "$work/origin.git" "$work/origin.gone"
clean || fail "clean failed when origin could not be fetched: $(cat "$work/err")"
mv "$work/origin.gone" "$work/origin.git"
[ -d "$wt/30" ] || fail "a worktree whose commits are vouched for by a tracking ref only was removed after a failed fetch"
branches | grep -qx feat/30-vanished || fail "feat/30-vanished was removed after a failed fetch"
grep -q "kept worktree $wt/30 (feat/30-vanished): .*could not be fetched.*unknown" "$work/out" ||
  fail "the unknown pushed state is not said: $(cat "$work/out")"
grep -q 'could not fetch origin' "$work/err" || fail "a failed fetch is not warned about: $(cat "$work/err")"
branches | grep -qx feat/31-in-main && fail "a branch inside the default branch was kept after a failed fetch"

# #243: an unreadable list of protected branches is said, and a docs/ branch is kept then (it could be one).
git -C "$repo" branch docs/frame-late main
pr 152 MERGED docs/frame-late 3 "$main_tip"
touch "$FIX/protected-fail"
clean --dry-run || fail "clean --dry-run failed without the protected branches: $(cat "$work/err")"
grep -q 'protected branches' "$work/err" || fail "an unreadable protected list is not said: $(cat "$work/err")"
has "kept branch docs/frame-late: protected branches could not be read" || fail "docs branch not kept: $(cat "$work/out")"
has "would remove branch docs/frame-late" && fail "a docs branch would go with the protected list unreadable"
rm -f "$FIX/protected-fail"
clean --dry-run || fail "clean --dry-run failed: $(cat "$work/err")"
has "would remove branch docs/frame-late " || fail "a docs branch is kept with the protected list readable: $(cat "$work/out")"
grep -q 'protected branches' "$work/err" && fail "a readable protected list is complained about"

# #792: pr-<n> of the orphan branch senior-mode/shots goes seven days after its pull request closed, not before.
git init -q "$work/shots-src"
mkdir -p "$work/shots-src/pr-501" "$work/shots-src/pr-502"
echo a >"$work/shots-src/pr-501/index-390x844-after.png"
echo b >"$work/shots-src/pr-502/index-390x844-after.png"
git -C "$work/shots-src" add -A
git -C "$work/shots-src" commit -q -m "shots"
git -C "$work/shots-src" push -q "$work/origin.git" HEAD:refs/heads/senior-mode/shots
pr 501 CLOSED zz/501 10 "$main_tip"
pr 502 CLOSED zz/502 3 "$main_tip"
shots_dirs() { git -C "$work/origin.git" ls-tree --name-only senior-mode/shots | tr '\n' ' '; }
clean --dry-run || fail "shots: dry run failed: $(cat "$work/err")"
has "would remove screenshots pr-501 " || fail "shots: pr-501 (closed 10 days ago) would not go: $(cat "$work/out")"
has "pr-502" && fail "shots: pr-502 (closed 3 days ago) would go: $(cat "$work/out")"
[ "$(shots_dirs)" = "pr-501 pr-502 " ] || fail "shots: --dry-run changed the branch: $(shots_dirs)"
clean || fail "shots: clean failed: $(cat "$work/err")"
[ "$(shots_dirs)" = "pr-502 " ] || fail "shots: the branch holds '$(shots_dirs)' after clean, expected only pr-502"

[ "$failures" -eq 0 ] && echo "test-clean: ok"
exit "$failures"
