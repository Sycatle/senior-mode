#!/usr/bin/env bash
# Tests for `senior-mode check` and `senior-mode publish`. Offline: gh is a stub that logs its arguments.
set -u
cli=$(cd "$(dirname "$0")/.." && pwd)/senior-mode
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

mkdir -p "$work/stub"
# The stub answers the pull request lookup (ASSOC), the board query of an issue (ITEM) and the combined
# status (STATUS) from files in $FIX; anything else it only logs.
cat >"$work/stub/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$GH_LOG"
case "$*" in
  "api graphql --input -")
    q=$(cat)
    if grep -q closingIssuesReferences <<<"$q"; then cat "$FIX/assoc" 2>/dev/null || exit 1
    elif grep -q 'c0: object(oid:' <<<"$q"; then
      # The spec drift (#331): no commit belongs to a pull request, unless $FIX/spec-pr-body is set (every commit does).
      jq -r .query <<<"$q" | grep -oE 'c[0-9]+: ' | jq -nRc --arg b "$(cat "$FIX/spec-pr-body" 2>/dev/null)" '[inputs | rtrimstr(": ")]
        | map({key: ., value: {associatedPullRequests: {nodes: (if $b == "" then [] else [{number: 5, state: "MERGED", body: $b}] end)}}})
        | from_entries | {data: {repository: .}}'
    else cat "$FIX/item" 2>/dev/null || exit 1; fi ;;
  "api repos/acme/app/commits/"*"/status --jq "*) all=$*; jq -r "${all#*--jq }" "$FIX/status" 2>/dev/null || true ;;
esac
STUB
chmod +x "$work/stub/gh"
mkdir -p "$work/fix"
export PATH="$work/stub:$PATH" GH_LOG="$work/gh.log" FIX="$work/fix"

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
grep -q "4/4 checks passed" "$work/out" || fail "summary missing: $(cat "$work/out")"
: >"$GH_LOG"
run publish || fail "publish fails after a passing check: $(cat "$work/out")"
grep -q -- "api repos/acme/app/statuses/$(sha) -f state=success -f context=senior-mode/ci -f description=4/4 checks passed" "$GH_LOG" ||
  fail "success status not published as expected: $(cat "$GH_LOG")"

config '{"checks":[{"name":"lint","run":"true"},{"name":"tests","run":"echo boom; exit 3"}]}'
run check && fail "check passes although a check fails"
grep -q "FAIL  tests" "$work/out" || fail "failing check not named: $(cat "$work/out")"
grep -q boom "$work/out" || fail "failing check output not shown: $(cat "$work/out")"
: >"$GH_LOG"
run publish || fail "publish fails after a failing check: $(cat "$work/out")"
grep -q -- "-f state=failure -f context=senior-mode/ci -f description=failed: tests" "$GH_LOG" ||
  fail "failure status not published as expected: $(cat "$GH_LOG")"

# A check that has nothing to do says why on its first line ("skipped: <reason>"): it passes, and the
# reason is shown instead of a bare ok.
config '{"checks":[{"name":"lint db","run":"echo \"skipped: tool not installed\""},{"name":"tests","run":"true"}]}'
run check || fail "a skipped check fails the run: $(cat "$work/out")"
grep -q "^skip  lint db: tool not installed ([0-9.]*s)$" "$work/out" || fail "skip reason not shown: $(cat "$work/out")"
grep -q "^ok    tests ([0-9.]*s)$" "$work/out" || fail "the other check lost its ok: $(cat "$work/out")"
grep -q "4/4 checks passed" "$work/out" || fail "a skipped check is not counted as passed: $(cat "$work/out")"

# Git exports GIT_DIR to hooks, absolute in a linked worktree: a check must not inherit it, or a
# test that runs git on a fixture writes into this repository.
config '{"checks":[{"name":"env","run":"env | grep -E \"^GIT_(DIR|WORK_TREE|INDEX_FILE)=\" && exit 1; true"}]}'
(cd "$repo" && GIT_DIR="$repo/.git" GIT_WORK_TREE="$repo" GIT_INDEX_FILE="$repo/.git/index" "$cli" check) \
  >"$work/out" 2>&1 || fail "a check sees git's hook environment: $(cat "$work/out")"

# senior-mode/security (ADR 0015): success "not required" unless a protected zone of the base branch is
# touched or a closing ticket is L; then pending, never success, and never a downgrade of a verdict.
git -C "$repo" branch -M main
# A local origin whose path ends like a GitHub URL, so the slug reads acme/app.
origin="$work/github.com/acme/app.git"
git init -q --bare "$origin"
git -C "$repo" remote set-url origin "$origin"
git -C "$repo" push -q origin main
git -C "$repo" checkout -q -b feat/9-x
sec() { grep -- "context=senior-mode/security" "$GH_LOG" | sed 's/.* -f state=\([a-z]*\) .*description=\(.*\)$/\1 \2/'; }
assoc() { # numbers of the issues the open pull request closes
  jq -nc --argjson n "[$1]" '{data: {repository: {object: {associatedPullRequests: {nodes: [{number: 7, state: "OPEN",
    closingIssuesReferences: {nodes: ($n | map({number: .}))}}]}}}}}' >"$FIX/assoc"
}
item() { # the Size of the issue on the board
  jq -nc --arg s "$1" '{data: {repository: {issue: {projectItems: {nodes: [{project: {id: "PVT_1"},
    fieldValues: {nodes: [{name: $s, field: {name: "Size"}}]}}]}}}}}' >"$FIX/item"
}
published() { # a config, then check and publish on a new commit
  config "$1"
  git -C "$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "feat: x"
  run check || fail "check: $(cat "$work/out")"
  : >"$GH_LOG"
  run publish || fail "publish: $(cat "$work/out")"
}
ok='"checks":[{"name":"lint","run":"true"}]'
proj='"project":{"id":"PVT_1","owner":"acme","number":3,"fields":{}}'
assoc ""
published "{$ok}"
[ "$(sec)" = "success not required: no protected zone, not L" ] || fail "not required not published: $(sec)"
# A pull request that closes no issue is not required either (release and framing pull requests).
# A status the security agent set on the commit is never overwritten; publish's own is.
status() { printf '{"statuses": [{"context": "senior-mode/security", "state": "%s", "description": "%s"}]}\n' "$1" "$2" >"$FIX/status"; }
status failure "1 high"
: >"$GH_LOG"; run publish || fail "publish: $(cat "$work/out")"
[ -z "$(sec)" ] || fail "not required overwrote a failure of the security agent: $(sec)"
status success "no high or critical finding"
: >"$GH_LOG"; run publish || fail "publish: $(cat "$work/out")"
[ -z "$(sec)" ] || fail "not required overwrote a success of the security agent: $(sec)"
status pending "agent could not finish"
: >"$GH_LOG"; run publish || fail "publish: $(cat "$work/out")"
[ -z "$(sec)" ] || fail "not required overwrote a pending of the security agent: $(sec)"
status pending "required: protected zone (a)"
: >"$GH_LOG"; run publish || fail "publish: $(cat "$work/out")"
[ "$(sec | cut -d' ' -f1)" = success ] || fail "publish's own pending not replaced when the pass stops being due: $(sec)"
rm -f "$FIX/status"
assoc 9; item S
published "{$ok,$proj}"
[ "$(sec | cut -d' ' -f1)" = success ] || fail "an S ticket needs the security pass: $(sec)"
item L
published "{$ok,$proj}"
[ "$(sec | cut -d' ' -f1)" = pending ] || fail "an L ticket does not leave security pending: $(sec)"
sec | grep -q "L ticket #9" || fail "pending without the reason: $(sec)"
item ""
published "{$ok,$proj}"
[ "$(sec | cut -d' ' -f1)" = pending ] || fail "an unknown Size counts as not L: $(sec)"
rm "$FIX/assoc"
published "{$ok,$proj}"
[ "$(sec | cut -d' ' -f1)" = pending ] || fail "an unreadable pull request counts as not required: $(sec)"
assoc ""
# The zones are the base branch's: a branch cannot lift its own.
git -C "$repo" checkout -q main
config "{$ok,\"protected\":[\"auth/**\"]}"
git -C "$repo" push -q origin main
git -C "$repo" checkout -q -b feat/10-y
config "{$ok,\"protected\":[]}"
mkdir -p "$repo/auth" && echo x >"$repo/auth/a.txt" && git -C "$repo" add -A
git -C "$repo" -c user.name=t -c user.email=t@t commit -q -m "feat: auth"
run check || fail "check: $(cat "$work/out")"
: >"$GH_LOG"
run publish || fail "publish: $(cat "$work/out")"
[ "$(sec | cut -d' ' -f1)" = pending ] || fail "a protected zone does not leave security pending: $(sec)"
sec | grep -q "auth/a.txt" || fail "the zone is not named: $(sec)"
# A verdict the security agent already set on this commit stays; a "not required" on a due pass goes.
status failure "1 high"
: >"$GH_LOG"
run publish || fail "publish: $(cat "$work/out")"
[ -z "$(sec)" ] || fail "publish overwrote the verdict of the security agent: $(sec)"
status success "no high or critical finding"
: >"$GH_LOG"
run publish || fail "publish: $(cat "$work/out")"
[ -z "$(sec)" ] || fail "publish replaced a success of the security agent: $(sec)"
echo '{"statuses": [{"context": "senior-mode/security", "state": "success", "description": "not required: no protected zone, not L"}]}' >"$FIX/status"
: >"$GH_LOG"
run publish || fail "publish: $(cat "$work/out")"
[ "$(sec | cut -d' ' -f1)" = pending ] || fail "a due pass stays marked not required: $(sec)"
rm -f "$FIX/status"
# The base branch is fetched first: the globs are those of the default branch as it is now, not as it
# was at the last fetch. Offline, publish goes on with what it has.
git -C "$repo" push -q origin main
git -C "$repo" checkout -q -b feat/11-z main
mkdir -p "$repo/gen" && echo x >"$repo/gen/x.txt" && git -C "$repo" add -A
git -C "$repo" -c user.name=t -c user.email=t@t commit -q -m "feat: gen"
git clone -q "$origin" "$work/other"
printf '%s\n' "{$ok,\"protected\":[\"gen/**\"]}" >"$work/other/.claude/senior-mode.json"
git -C "$work/other" -c user.name=t -c user.email=t@t commit -q -am "chore: protect gen"
git -C "$work/other" push -q origin HEAD:main
run check || fail "check: $(cat "$work/out")"
git -C "$repo" remote set-url origin "$work/github.com/acme/gone.git"
: >"$GH_LOG"
run publish || fail "publish fails offline: $(cat "$work/out")"
[ "$(sec | cut -d' ' -f1)" = success ] || fail "setup of the test: the stale base should not know gen/: $(sec)"
git -C "$repo" remote set-url origin "$origin"
: >"$GH_LOG"
run publish || fail "publish: $(cat "$work/out")"
[ "$(sec | cut -d' ' -f1)" = pending ] || fail "the base branch was not fetched before its globs were read: $(sec)"
sec | grep -q "gen/x.txt" || fail "the zone is not named: $(sec)"

config '{"checks":[{"name":"lint","run":"true"}]}'
: >"$GH_LOG"
run publish && fail "publish works without a check result for this commit"
[ -s "$GH_LOG" ] && fail "gh called without a check result"

echo dirty >"$repo/untracked.txt"
run check || fail "check fails on a dirty tree although every check passes"
run publish && fail "a check on a dirty tree was recorded for HEAD"
rm "$repo/untracked.txt"

# Each check shows how long it took, whatever its outcome.
config '{"checks":[{"name":"slow","run":"sleep 1"},{"name":"bad","run":"false"},{"name":"idle","run":"echo \"skipped: nothing to do\""}]}'
run check
grep -Eq "^ok    slow \(1\.[0-9]s\)$" "$work/out" || fail "time of a passing check not shown: $(cat "$work/out")"
grep -Eq "^FAIL  bad \([0-9]+\.[0-9]s\)$" "$work/out" || fail "time of a failing check not shown: $(cat "$work/out")"
grep -Eq "^skip  idle: nothing to do \([0-9]+\.[0-9]s\)$" "$work/out" || fail "time of a skipped check not shown: $(cat "$work/out")"

# `check --pre-push` reads the lines git gives a pre-push hook and tells the checks which paths the push
# changes (SENIOR_MODE_CHANGED_FILES); a check that cannot narrow itself ignores it. Anything the hook cannot
# work out means no list, so the checks run in full. A narrowed run is not recorded: publish needs a full one.
config "$(jq -nc --arg out "$work/scope" '{checks: [{name: "scope", run: ("if [ -n \"${SENIOR_MODE_CHANGED_FILES:-}\" ]; then cat \"$SENIOR_MODE_CHANGED_FILES\"; else echo FULL; fi >" + $out)}]}')"
old=$(sha)
mkdir -p "$repo/a" "$repo/b" && echo x >"$repo/a/x.txt" && echo x >"$repo/b/y.txt"
git -C "$repo" add -A
git -C "$repo" -c user.name=t -c user.email=t@t commit -q -m "feat: two files"
zero=0000000000000000000000000000000000000000
pushed() { (cd "$repo" && printf '%s\n' "$1" | "$cli" check --pre-push) >"$work/out" 2>&1; }
pushed "refs/heads/feat/11-z $(sha) refs/heads/feat/11-z $old" || fail "pre-push check fails: $(cat "$work/out")"
[ "$(sort "$work/scope" | paste -sd' ')" = "a/x.txt b/y.txt" ] || fail "changed paths of an update: $(cat "$work/scope")"
run publish && fail "a narrowed run was recorded for publishing"
pushed "refs/heads/feat/12-new $(sha) refs/heads/feat/12-new $zero"
[ "$(grep -cx -e "a/x.txt" -e "b/y.txt" "$work/scope")" = 2 ] || fail "changed paths of a new branch: $(cat "$work/scope")"
pushed "refs/heads/feat/11-z $(sha) refs/heads/feat/11-z 1111111111111111111111111111111111111111"
[ "$(cat "$work/scope")" = FULL ] || fail "an unknown remote commit did not mean a full run: $(cat "$work/scope")"
pushed "(delete) $zero refs/heads/old $old"
[ "$(cat "$work/scope")" = FULL ] || fail "a deletion did not mean a full run: $(cat "$work/scope")"
(cd "$repo" && "$cli" check --pre-push </dev/null) >"$work/out" 2>&1
[ "$(cat "$work/scope")" = FULL ] || fail "no pushed ref did not mean a full run: $(cat "$work/scope")"
echo a/x.txt >"$work/list"
(cd "$repo" && SENIOR_MODE_CHANGED_FILES="$work/list" "$cli" check) >"$work/out" 2>&1
[ "$(cat "$work/scope")" = FULL ] || fail "check without --pre-push honours a list from the environment: $(cat "$work/scope")"
run publish || fail "a full run is not recorded: $(cat "$work/out")"

# A node project whose dependencies are not installed fails at once, naming the command that installs
# them, instead of running a typecheck that fails on missing modules (#110).
config '{"preset":"node","checks":[{"name":"typecheck","run":"echo cryptic error; exit 1"}]}'
echo '{"name": "app", "devDependencies": {"typescript": "5.0.0"}}' >"$repo/package.json"
echo '{"lockfileVersion": 3}' >"$repo/package-lock.json"
git -C "$repo" add -A
git -C "$repo" -c user.name=t -c user.email=t@t commit -q -m "chore: node"
run check && fail "check passes without node_modules"
grep -q "^FAIL  dependencies not installed: run npm ci$" "$work/out" || fail "missing dependencies not reported: $(cat "$work/out")"
grep -q cryptic "$work/out" && fail "the checks ran without dependencies: $(cat "$work/out")"
touch "$repo/pnpm-lock.yaml"
git -C "$repo" add -A
git -C "$repo" -c user.name=t -c user.email=t@t commit -q -m "chore: pnpm"
run check
grep -q "run pnpm install --frozen-lockfile$" "$work/out" || fail "install command ignores the lockfile: $(cat "$work/out")"
config '{"preset":"node","audit":false,"commands":{"install":"make deps"},"checks":[{"name":"typecheck","run":"true"}]}'
run check
grep -q "run make deps$" "$work/out" || fail "configured install command not named: $(cat "$work/out")"
mkdir "$repo/node_modules"
run check || fail "check fails although dependencies are installed: $(cat "$work/out")"
rm -rf "$repo/node_modules"
echo '{"name": "app"}' >"$repo/package.json"
run check || fail "a project with no dependencies needs no node_modules: $(cat "$work/out")"

# Spec drift (#169): an accepted spec whose paths changed after it, with no Spec-Unchanged line, is a
# warning line of `check`; it never changes the exit code. No accepted spec, no line.
config '{"audit":false,"checks":[{"name":"lint","run":"true"}]}'
commit() { git -C "$repo" add -A && git -C "$repo" -c user.name=t -c user.email=t@t commit -q "$@"; }
run check || fail "check fails before any spec: $(cat "$work/out")"
grep -q "spec drift" "$work/out" && fail "spec drift reported with no spec: $(cat "$work/out")"
mkdir -p "$repo/docs/specs" "$repo/src"
printf -- '---\nid: 1\ntitle: Alpha\nstatus: accepted\npaths: ["src/**"]\n---\n' >"$repo/docs/specs/0001-alpha.md"
commit -m "docs(spec): alpha"
run check || fail "check fails on a spec with no drift: $(cat "$work/out")"
grep -q "spec drift" "$work/out" && fail "spec drift reported with no change after the spec: $(cat "$work/out")"
echo a >"$repo/src/a.txt"
commit -m "feat: a"
run check || fail "drift changes the exit code: $(cat "$work/out")"
grep -q "^warn  spec drift: docs/specs/0001-alpha.md: 1 commit " "$work/out" || fail "drift not warned about: $(cat "$work/out")"
echo b >"$repo/src/b.txt"
commit -m "feat: b" -m "Spec-Unchanged: internal only"
run check || fail "check fails: $(cat "$work/out")"
grep -q "^warn  spec drift: docs/specs/0001-alpha.md: 1 commit " "$work/out" || fail "a Spec-Unchanged commit is counted: $(cat "$work/out")"
# The Spec-Unchanged line of the body of the pull request of a commit clears it, whatever its subject (#331).
echo c >"$repo/src/c.txt"
commit -m "feat: c"
run check || fail "check fails: $(cat "$work/out")"
grep -q "^warn  spec drift: docs/specs/0001-alpha.md: 2 commits " "$work/out" || fail "the commit without a pull request is not counted: $(cat "$work/out")"
printf 'Intro\n\nSpec-Unchanged: no behaviour change\n' >"$FIX/spec-pr-body"
run check || fail "check fails: $(cat "$work/out")"
grep -q "spec drift" "$work/out" && fail "commits whose pull request has Spec-Unchanged are counted: $(cat "$work/out")"
rm -f "$FIX/spec-pr-body"
config '{"audit":false,"checks":[{"name":"bad","run":"false"}]}'
run check && fail "a failing check passes"
grep -q "^warn  spec drift" "$work/out" || fail "the warning is lost when a check fails: $(cat "$work/out")"
grep -q "^FAIL  bad" "$work/out" || fail "the failing check is not shown: $(cat "$work/out")"

# The full output of a failed check is kept in a log of its own, its path printed under the shown tail (#294);
# the logs are bounded, the oldest go first.
logs=$(git -C "$repo" rev-parse --path-format=absolute --git-path senior-mode/check-logs)
rm -rf "$logs"
config '{"audit":false,"checks":[{"name":"noisy test","run":"seq 1 50; exit 3"},{"name":"fine","run":"true"}]}'
run check && fail "a failing check passes"
log=$(sed -n 's/^      full log: //p' "$work/out")
[ -n "$log" ] && [ -f "$log" ] || fail "the log of the failed check is not printed or does not exist: $(cat "$work/out")"
[ "$(wc -l <"$log")" = 50 ] && [ "$(head -n 1 "$log")" = 1 ] || fail "the log does not hold the full output: $(head -n 3 "$log")"
case $log in "$logs"/*noisy-test.log) ;; *) fail "log path: $log" ;; esac
{ grep -q '^      31$' "$work/out" && grep -q '^      50$' "$work/out" && ! grep -q '^      30$' "$work/out"; } ||
  fail "the tail shown is not the last 20 lines: $(cat "$work/out")"
[ "$(grep -c 'full log' "$work/out")" = 1 ] || fail "a log for a check that passed: $(cat "$work/out")"
for i in $(seq 1 30); do : >"$logs/old-$i.log"; touch -d "@$((1000000 + i))" "$logs/old-$i.log"; done
run check && fail "a failing check passes"
kept=$(find "$logs" -type f | wc -l)
[ "$kept" = 20 ] || fail "the logs are not bounded to 20: $kept"
[ -f "$(sed -n 's/^      full log: //p' "$work/out")" ] || fail "the new log was removed"
[ -e "$logs/old-30.log" ] && [ ! -e "$logs/old-1.log" ] || fail "the oldest logs were not the ones removed: $(printf "%s " "$logs"/* | head -c 300)"

# Two checks started together in two worktrees both pass (#295): each run gives its checks a temp directory of
# its own, so a fixed name under TMPDIR never collides, and removes it when it ends.
config "$(jq -nc --arg d "$work" '{audit: false, checks: [{name: "fixed name", run: ("mkdir \"$TMPDIR/fixed-name\" && sleep 1 && echo \"$TMPDIR\" >>" + $d + "/tmps")}]}')"
git -C "$repo" worktree add -q --detach "$work/wt2"
: >"$work/tmps"
(cd "$repo" && "$cli" check) >"$work/out1" 2>&1 &
p1=$!
(cd "$work/wt2" && "$cli" check) >"$work/out2" 2>&1 &
p2=$!
wait "$p1" || fail "the first of two concurrent checks fails: $(cat "$work/out1")"
wait "$p2" || fail "the second of two concurrent checks fails: $(cat "$work/out2")"
[ "$(sort -u "$work/tmps" | wc -l)" = 2 ] || fail "the checks share a temp directory: $(cat "$work/tmps")"
[ ! -e "$(head -n 1 "$work/tmps")" ] || fail "the temp directory of a run is left behind"

[ "$failures" -eq 0 ] && echo "check: all cases pass"
exit "$failures"
