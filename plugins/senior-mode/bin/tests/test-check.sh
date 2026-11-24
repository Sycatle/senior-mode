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
grep -q "7/7 checks passed" "$work/out" || fail "summary missing: $(cat "$work/out")"
: >"$GH_LOG"
run publish || fail "publish fails after a passing check: $(cat "$work/out")"
grep -q -- "api repos/acme/app/statuses/$(sha) -f state=success -f context=senior-mode/ci -f description=7/7 checks passed" "$GH_LOG" ||
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
grep -q "7/7 checks passed" "$work/out" || fail "a skipped check is not counted as passed: $(cat "$work/out")"

# docs/vision.md (#342): no file, nothing reported; with one, `## Goals` with entries G1, G2... and `## Non-goals`
# are required and the file stays within vision.maxLines (default 100).
vision() { mkdir -p "$repo/docs" && printf '%s\n' "$@" >"$repo/docs/vision.md"; }
config '{"checks":[{"name":"tests","run":"true"}]}'
run check || fail "check fails with no vision file: $(cat "$work/out")"
grep -q "vision" "$work/out" && fail "vision reported with no file: $(cat "$work/out")"
vision '# Vision' '' '## Goals' '' '- G1: people can log in' '- **G2** people can pay' '' '## Non-goals' '' '- No mobile app' '' '## Constraints' '' '- EU hosting'
run check || fail "check fails on a valid vision: $(cat "$work/out")"
grep -q "^ok    vision" "$work/out" || fail "valid vision not reported ok: $(cat "$work/out")"
grep -q "7/7 checks passed" "$work/out" || fail "vision not counted: $(cat "$work/out")"
vision '# Vision' '' '## Goals' '' '- G1: people can log in'
run check && fail "check passes without ## Non-goals"
grep -q "FAIL  vision" "$work/out" || fail "vision failure not reported: $(cat "$work/out")"
grep -q "## Non-goals" "$work/out" || fail "missing Non-goals not named: $(cat "$work/out")"
vision '# Vision' '' '## Non-goals' '' '- No mobile app'
run check && fail "check passes without ## Goals"
grep -q "## Goals" "$work/out" || fail "missing Goals not named: $(cat "$work/out")"
vision '# Vision' '' '## Goals' '' '- people can log in' '' '## Non-goals' '' '- No mobile app'
run check && fail "check passes with a goal that has no id"
grep -q "G1" "$work/out" || fail "goal ids not asked for: $(cat "$work/out")"
vision '# Vision' '' '## Goals' '' '- G1: a' '- G1: b' '' '## Non-goals' '' '- No mobile app'
run check && fail "check passes with a duplicate goal id"
grep -q "G1.*twice\|twice.*G1" "$work/out" || fail "duplicate id not named: $(cat "$work/out")"
vision '# Vision' '' '## Goals' '' '- G1: a' '' '## Non-goals' '' '- b' '' '' '' '' '' '' ''
config '{"checks":[{"name":"tests","run":"true"}],"vision":{"maxLines":10}}'
run check && fail "check passes with a vision over vision.maxLines"
grep -q "16 lines.*(10)" "$work/out" || fail "line limit not reported: $(cat "$work/out")"
config '{"checks":[{"name":"tests","run":"true"}],"vision":{"maxLines":16}}'
run check || fail "a vision of exactly vision.maxLines fails: $(cat "$work/out")"
config '{"checks":[{"name":"tests","run":"true"}],"vision":{"maxLines":"many"}}'
run check && fail "check passes with a vision.maxLines that is no number"
rm -rf "$repo/docs"
config '{"checks":[{"name":"tests","run":"true"}]}'

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

# The spec drift is a warning, never a gate (#332, tested above): no document says CI or a check enforces it.
plugin=$(cd "$(dirname "$0")/../.." && pwd)
for f in "$plugin/skills/spec/SKILL.md" "$plugin/../../docs/adr/0002-sources-of-truth.md" "$plugin/../../docs/specs/0001-senior-mode.md" "$plugin/../../docs/guide/skills.md"; do
  [ -f "$f" ] || { fail "$f is missing"; continue; }
  grep -qiE 'CI (check )?enforces|enforced in CI|check enforces' "$f" && fail "$f claims the spec drift is enforced in CI: $(grep -iE 'CI (check )?enforces|enforced in CI|check enforces' "$f")"
done
# Added suppressions (#437): each added line that silences a check or skips a test is a warning line with
# file and line; the exit code does not change, and Markdown or a lookalike (`exit(`) is not listed.
config '{"audit":false,"checks":[{"name":"lint","run":"true"}]}'
run check || fail "check fails: $(cat "$work/out")"
grep -q "suppression added" "$work/out" && fail "suppression reported with none added: $(cat "$work/out")"
printf 'const a = 1;\n// eslint-disable-next-line no-console\nconsole.log(a); // @ts-ignore\nit.skip("x", () => {});\nxit("y");\nprocess.exit(1);\n' >"$repo/src/s.ts"
printf 'import os  # noqa: F401\nx: int = "a"  # type: ignore\n@pytest.mark.skip\ndef test_a(): pass\n' >"$repo/src/t.py"
printf 'package a\n//nolint:errcheck\nfunc TestA(t *testing.T) { t.Skip("later") }\n' >"$repo/src/a_test.go"
printf '#[allow(dead_code)]\nfn f() {}\n' >"$repo/src/lib.rs"
printf 'Use it.skip( sparingly.\n' >"$repo/src/notes.md"
commit -m "feat: suppressions"
run check || fail "a suppression changes the exit code: $(cat "$work/out")"
for want in "src/s.ts:2: // eslint-disable-next-line" "src/s.ts:3: console.log(a); // @ts-ignore" 'src/s.ts:4: it.skip(' 'src/s.ts:5: xit(' \
  "src/t.py:1: import os  # noqa" "src/t.py:2: " "src/t.py:3: @pytest.mark.skip" "src/a_test.go:2: //nolint" \
  'src/a_test.go:3: ' "src/lib.rs:1: #[allow(dead_code)]"; do
  grep -qF "warn  suppression added: $want" "$work/out" || fail "suppression not listed: $want: $(cat "$work/out")"
done
grep -q "suppression added: src/s.ts:[16]:" "$work/out" && fail "a line without suppression is listed: $(cat "$work/out")"
grep -q "suppression added: src/notes.md" "$work/out" && fail "Markdown is listed: $(cat "$work/out")"

# Knowledge notes (#333): with no docs/knowledge nothing is reported; a note needs paths, verified, origin and kind,
# a kebab-case name and a body within knowledge.maxLines; every problem names the file and the key.
config '{"audit":false,"checks":[{"name":"lint","run":"true"}]}'
run check || fail "check fails with no notes: $(cat "$work/out")"
grep -qi "knowledge" "$work/out" && fail "notes reported with no docs/knowledge: $(cat "$work/out")"
today=$(date -u +%Y-%m-%d)
note() { # file, then the lines of the file
  mkdir -p "$repo/docs/knowledge"
  local f=$1
  shift
  printf '%s\n' "$@" >"$repo/docs/knowledge/$f"
}
note money-rounding.md '---' 'paths: ["src/billing/**", "src/lib/money.ts"]' "verified: $today" 'origin: "#312"' 'kind: pitfall' '---' '' '# Imports order' '' 'money.ts patches Intl.NumberFormat.'
run check || fail "a valid note fails the check: $(cat "$work/out")"
grep -q "^ok    knowledge " "$work/out" || fail "valid note not reported ok: $(cat "$work/out")"
for o in retro docs/spikes/321-queue.md; do
  note money-rounding.md '---' 'paths: ["src/**"]' 'verified: 2026-01-31' "origin: $o" 'kind: howto' '---' 'Body.'
  run check || fail "origin $o refused: $(cat "$work/out")"
done
for k in paths verified origin kind; do
  note bad-note.md '---' 'paths: ["a/**"]' "verified: $today" 'origin: retro' 'kind: context' '---' 'Body.'
  sed -i "/^$k:/d" "$repo/docs/knowledge/bad-note.md"
  run check && fail "a note without $k passes"
  grep -q "^      docs/knowledge/bad-note.md: missing key $k$" "$work/out" || fail "missing $k not named: $(cat "$work/out")"
done
note bad-note.md '---' 'paths: ["a/**"]' "verified: $today" 'origin: retro' 'kind: opinion' '---' 'Body.'
run check && fail "an unknown kind passes"
grep -q "bad-note.md: kind must be pitfall, convention, howto or context, not opinion" "$work/out" || fail "kind not named: $(cat "$work/out")"
note bad-note.md '---' 'paths: ["a/**"]' 'verified: 2999-01-01' 'origin: retro' 'kind: context' '---' 'Body.'
run check && fail "a future verified date passes"
grep -q "bad-note.md: verified 2999-01-01 is in the future" "$work/out" || fail "future date not named: $(cat "$work/out")"
note bad-note.md '---' 'paths: ["a/**"]' 'verified: 2026-02-31' 'origin: retro' 'kind: context' '---' 'Body.'
run check && fail "an impossible date passes"
grep -q "bad-note.md: verified must be a date" "$work/out" || fail "bad date not named: $(cat "$work/out")"
note bad-note.md '---' 'paths: []' "verified: $today" 'origin: retro' 'kind: context' '---' 'Body.'
run check && fail "empty paths pass"
grep -q "bad-note.md: paths is empty" "$work/out" || fail "empty paths not named: $(cat "$work/out")"
note bad-note.md '---' 'paths: a/**' "verified: $today" 'origin: retro' 'kind: context' '---' 'Body.'
run check && fail "paths that is no list passes"
grep -q "bad-note.md: paths must be a list of globs" "$work/out" || fail "paths not a list: $(cat "$work/out")"
note bad-note.md '---' 'paths: ["a/**"]' "verified: $today" 'origin: someone' 'kind: context' '---' 'Body.'
run check && fail "an unknown origin passes"
grep -q "bad-note.md: origin must be" "$work/out" || fail "origin not named: $(cat "$work/out")"
note bad-note.md 'no front matter at all'
run check && fail "a note with no front matter passes"
grep -q "bad-note.md: missing key paths" "$work/out" || fail "no front matter not reported: $(cat "$work/out")"
rm "$repo/docs/knowledge/bad-note.md"
long=(--- 'paths: ["a/**"]' "verified: $today" 'origin: retro' 'kind: context' ---)
for i in $(seq 1 41); do long+=("line $i"); done
note long-note.md "${long[@]}"
run check && fail "a body of 41 lines passes"
grep -q "long-note.md: body has 41 lines, over knowledge.maxLines (40)" "$work/out" || fail "limit not said: $(cat "$work/out")"
config '{"audit":false,"knowledge":{"maxLines":41},"checks":[{"name":"lint","run":"true"}]}'
run check || fail "a body of exactly knowledge.maxLines fails: $(cat "$work/out")"
config '{"audit":false,"knowledge":{"maxLines":10},"checks":[{"name":"lint","run":"true"}]}'
run check && fail "knowledge.maxLines is not read"
grep -q "(10)" "$work/out" || fail "custom limit not said: $(cat "$work/out")"
config '{"audit":false,"checks":[{"name":"lint","run":"true"}]}'
rm "$repo/docs/knowledge/long-note.md"
note Bad_Name.md '---' 'paths: ["a/**"]' "verified: $today" 'origin: retro' 'kind: context' '---' 'Body.'
run check && fail "a file name that is no slug passes"
grep -q "Bad_Name.md: file name is not a kebab-case slug" "$work/out" || fail "slug not named: $(cat "$work/out")"
rm -rf "$repo/docs/knowledge"
run check || fail "check fails once the notes are gone: $(cat "$work/out")"

# Architecture rules (#337): forbidImport (relative, aliased, Python and Go imports), maxLines and banned fail the check
# naming rule, file and line; a baseline tolerates the existing violations, warns about the fixed ones and
# --update-baseline only removes; a rule with no id or an unknown kind is a configuration error.
mkdir -p "$repo/arch/ui" "$repo/arch/db" "$repo/arch/lib"
printf 'import a from "./local";\nimport { q } from "../db/x";\n' >"$repo/arch/ui/a.ts"
printf 'import b from "@/db/x";\nexport const k = 1;\n' >"$repo/arch/ui/b.ts"
printf 'import os\nfrom arch.db import x\n' >"$repo/arch/ui/c.py"
printf 'package ui\n\nimport (\n\t"fmt"\n\t"example.com/app/arch/db"\n)\n' >"$repo/arch/ui/d.go"
printf 'export const x = 1;\n' >"$repo/arch/db/x.ts"
printf 'import { z } from "./z";\n' >"$repo/arch/lib/clean.ts"
printf 'one\ntwo\nthree\nfour\nfive\n' >"$repo/arch/lib/big.txt"
printf 'console.log("a");\nconst ok = 1;\n  console.log("b");\n' >"$repo/arch/lib/noisy.ts"
printf '// a comment\n{"compilerOptions": {\n  "paths": {"@/*": ["./arch/*"]}}}\n' >"$repo/tsconfig.json"
printf 'module example.com/app\n' >"$repo/go.mod"
commit -m "feat: arch fixtures"
rules='{"id":"ui-not-db","forbidImport":{"from":"arch/ui/**","to":"arch/db/**"},"why":"ui goes through services"}'
cfg() { config "{\"audit\":false,\"checks\":[{\"name\":\"lint\",\"run\":\"true\"}],\"architecture\":{\"rules\":[$1]}}"; }
cfg "$rules"
run check && fail "a forbidden import passes"
for want in "ui-not-db: arch/ui/a.ts:2: imports ../db/x, which resolves under arch/db/\*\* (ui goes through services)" \
  "ui-not-db: arch/ui/b.ts:1: imports @/db/x" "ui-not-db: arch/ui/c.py:2: imports arch.db" "ui-not-db: arch/ui/d.go:5: imports example.com/app/arch/db"; do
  grep -q -- "$want" "$work/out" || fail "violation not reported: $want: $(cat "$work/out")"
done
grep -q "arch/ui/a.ts:1:\|c.py:1:\|d.go:4:" "$work/out" && fail "an import that is allowed is reported: $(cat "$work/out")"
grep -q "^FAIL  architecture " "$work/out" || fail "step not named: $(cat "$work/out")"
cfg '{"id":"ui-not-db","forbidImport":{"from":"arch/lib/**","to":"arch/db/**"}}'
run check || fail "a rule with no violation fails: $(cat "$work/out")"
grep -q "^ok    architecture " "$work/out" || fail "architecture not reported ok: $(cat "$work/out")"
cfg '{"id":"size","maxLines":3,"paths":["arch/lib/**"],"why":"small files"},{"id":"no-console","banned":"console\\.log","paths":["arch/lib/**"]}'
run check && fail "maxLines and banned pass"
grep -q "size: arch/lib/big.txt:4: has 5 lines, over the limit of 3 (small files)" "$work/out" || fail "maxLines: $(cat "$work/out")"
grep -q 'no-console: arch/lib/noisy.ts:1: matches banned /console\\.log/: console.log("a");' "$work/out" || fail "banned line 1: $(cat "$work/out")"
grep -q "no-console: arch/lib/noisy.ts:3: " "$work/out" || fail "banned line 3: $(cat "$work/out")"
grep -q "no-console: arch/lib/clean.ts" "$work/out" && fail "a clean file is reported"
# The baseline: what it lists is tolerated, the rest fails; a fixed entry is a warning.
cfg '{"id":"size","maxLines":3,"paths":["arch/lib/**"]},{"id":"no-console","banned":"console\\.log","paths":["arch/lib/**"]}'
printf '{"violations":[{"rule":"size","file":"arch/lib/big.txt"},{"rule":"no-console","file":"arch/lib/noisy.ts","count":2}]}\n' >"$repo/.claude/architecture-baseline.json"
run check || fail "baselined violations fail: $(cat "$work/out")"
printf 'console.log("c");\n' >>"$repo/arch/lib/noisy.ts"
run check && fail "a violation beyond the baseline passes"
grep -q "no-console: arch/lib/noisy.ts:4: .*(the baseline allows 2)" "$work/out" || fail "the new violation is not named: $(cat "$work/out")"
printf 'console.log("a");\n' >"$repo/arch/lib/noisy.ts"
printf 'one\n' >"$repo/arch/lib/big.txt"
run check || fail "a fixed violation fails the check: $(cat "$work/out")"
grep -q "warning: architecture baseline: size in arch/lib/big.txt no longer violates, remove it" "$work/out" || fail "fixed entry not warned: $(cat "$work/out")"
grep -q "warning: architecture baseline: no-console in arch/lib/noisy.ts has 1 violations, the baseline allows 2" "$work/out" || fail "lowerable entry not warned: $(cat "$work/out")"
run check --update-baseline || fail "--update-baseline fails with nothing to add: $(cat "$work/out")"
[ "$(jq -c '.violations' "$repo/.claude/architecture-baseline.json")" = '[{"rule":"no-console","file":"arch/lib/noisy.ts","count":1}]' ] ||
  fail "baseline not pruned: $(cat "$repo/.claude/architecture-baseline.json")"
# It never adds: a new violation is refused, the file keeps its entries.
printf 'console.log("z");\n' >"$repo/arch/lib/new.ts"
before=$(cat "$repo/.claude/architecture-baseline.json")
run check --update-baseline && fail "--update-baseline accepts a new violation"
grep -q "no-console: arch/lib/new.ts:1: " "$work/out" || fail "the refused violation is not named: $(cat "$work/out")"
[ "$(cat "$repo/.claude/architecture-baseline.json")" = "$before" ] || fail "the baseline grew: $(cat "$repo/.claude/architecture-baseline.json")"
rm "$repo/arch/lib/new.ts"
printf 'x\n' >"$repo/arch/lib/noisy.ts"
run check --update-baseline || fail "--update-baseline: $(cat "$work/out")"
[ "$(jq -c '.violations' "$repo/.claude/architecture-baseline.json")" = '[]' ] || fail "the fixed entry stays: $(cat "$repo/.claude/architecture-baseline.json")"
rm "$repo/.claude/architecture-baseline.json"
run check --update-baseline && fail "--update-baseline creates a baseline"
[ ! -e "$repo/.claude/architecture-baseline.json" ] || fail "--update-baseline created the file"
# A rule with no id, an unknown kind, two kinds or no part is a configuration error.
for bad in '{"maxLines":3,"paths":["a"]}|needs an id' '{"id":"r","forbidImpurt":{"from":"a","to":"b"}}|rule r: unknown kind or key "forbidImpurt"' \
  '{"id":"r","maxLines":3,"banned":"x","paths":["a"]}|rule r: has several kinds' '{"id":"r","forbidImport":{"from":"a"}}|rule r: forbidImport needs a from and a to' \
  '{"id":"r","maxLines":3}|rule r: needs paths' '{"id":"r"}|rule r: has no kind' '{"id":"r","banned":"x","paths":["a"]},{"id":"r","banned":"y","paths":["a"]}|rule r: the id is used twice'; do
  cfg "${bad%%|*}"
  run check && fail "a bad rule passes: ${bad%%|*}"
  grep -q "configuration error: .*${bad#*|}" "$work/out" || fail "configuration error not said for ${bad%%|*}: $(cat "$work/out")"
done
cfg '{"id":"r","banned":"(","paths":["arch/**"]}'
run check && fail "a banned that is no regular expression passes"
grep -q "banned is not a valid regular expression" "$work/out" || fail "bad regular expression not said: $(cat "$work/out")"
rm -rf "$repo/arch" "$repo/tsconfig.json" "$repo/go.mod"
config '{"audit":false,"checks":[{"name":"lint","run":"true"}]}'

# Context hygiene (#314, #335): an oversized CLAUDE.md or SKILL.md, or an ADR whose paths is no list of
# strings, fails; a dead path cited in a CLAUDE.md is a warning; a bare name is not a path.
run context-hygiene || fail "context hygiene fails on a clean repo: $(cat "$work/out")"
printf 'See %s.\n' "\`src/s.ts\`, \`docs/gone.md\`, \`lib/\` and \`x.sh\`" >"$repo/CLAUDE.md"
commit -m "docs: claude"
run context-hygiene || fail "a dead path fails the hygiene: $(cat "$work/out")"
grep -q "warning: CLAUDE.md cites docs/gone.md, which does not exist" "$work/out" || fail "dead path not warned: $(cat "$work/out")"
grep -qE "cites (src/s.ts|lib/|x.sh)" "$work/out" && fail "a live path or a bare name is warned: $(cat "$work/out")"
seq 81 | sed 's/^/line /' >>"$repo/CLAUDE.md"
commit -m "docs: long claude"
run context-hygiene && fail "a CLAUDE.md over 80 lines passes"
grep -q "CLAUDE.md: 82 lines, over context.claudeMdLines (80)" "$work/out" || fail "long CLAUDE.md not named: $(cat "$work/out")"
config '{"audit":false,"context":{"claudeMdLines":100},"checks":[{"name":"lint","run":"true"}]}'
run context-hygiene || fail "context.claudeMdLines is not read: $(cat "$work/out")"
mkdir -p "$repo/skills/big" "$repo/docs/adr"
head -c 3100 /dev/zero | tr '\0' x >"$repo/skills/big/SKILL.md"
printf -- '---\nid: 0001\npaths: src/**\n---\n' >"$repo/docs/adr/0001-a.md"
printf -- '---\nid: 0002\npaths: ["src/**"]\n---\n' >"$repo/docs/adr/0002-b.md"
commit -m "docs: skill and adrs"
run context-hygiene && fail "an oversized SKILL.md or a bad ADR paths passes"
grep -q "skills/big/SKILL.md: 3100 bytes, over 3072" "$work/out" || fail "big SKILL.md not named: $(cat "$work/out")"
grep -q "docs/adr/0001-a.md: paths must be a list of strings" "$work/out" || fail "bad ADR paths not named: $(cat "$work/out")"
grep -q "0002-b.md" "$work/out" && fail "a good ADR paths is named: $(cat "$work/out")"

git -C "$repo" rm -q -f CLAUDE.md skills/big/SKILL.md docs/adr/0001-a.md
commit -m "chore: drop the hygiene fixtures"
# Assertion-free test cases (#306): an added case with no assertion is a warning, and an error in a run or serve session
# (SENIOR_MODE_RUN=1). Per preset: node, python, go, rust. A case that asserts, a todo and a file that is no test are not listed.
config '{"audit":false,"preset":"node","checks":[{"name":"lint","run":"true"}]}'
printf 'it("a", () => {\n  expect(1).toBe(1);\n});\nit("b", () => {\n  run();\n});\ntest.todo("c");\n' >"$repo/src/a.test.ts"
printf 'def test_a():\n    assert 1\n\ndef test_b():\n    run()\n' >"$repo/src/test_b.py"
printf 'package a\nfunc TestA(t *testing.T) {\n\tif x() { t.Errorf("no") }\n}\nfunc TestB(t *testing.T) {\n\trun()\n}\n' >"$repo/src/b_test.go"
mkdir -p "$repo/tests"
printf '#[test]\nfn a() { assert_eq!(1, 1); }\n#[test]\nfn b() { run(); }\n' >"$repo/tests/c.rs"
printf 'it("d", () => { run(); });\n' >"$repo/src/helper.ts"
commit -m "feat: tests"
run check || fail "an assertion-free test fails a local check: $(cat "$work/out")"
grep -qF 'warn  test case with no assertion: src/a.test.ts:4: it("b"' "$work/out" || fail "assertion-free case not listed: $(cat "$work/out")"
# Another preset's files are not read.
grep -q "no assertion: src/test_b.py\|no assertion: src/b_test.go\|no assertion: tests/c.rs" "$work/out" && fail "a file of another preset is read under node: $(cat "$work/out")"
grep -q "no assertion: src/a.test.ts:1:\|no assertion: src/a.test.ts:7:\|no assertion: src/helper.ts\|no assertion: src/b_test.go:2:" "$work/out" &&
  fail "a case that asserts, a todo or a non-test file is listed: $(cat "$work/out")"
(cd "$repo" && SENIOR_MODE_RUN=1 "$cli" check) >"$work/out" 2>&1 && fail "an assertion-free test passes under run and serve"
grep -q "FAIL  assertion-free tests" "$work/out" || fail "the error is not named: $(cat "$work/out")"
config '{"audit":false,"preset":"python","checks":[{"name":"lint","run":"true"}]}'
run check || fail "check fails: $(cat "$work/out")"
grep -qF "warn  test case with no assertion: src/test_b.py:4: def test_b" "$work/out" || fail "python case not listed: $(cat "$work/out")"
grep -q "src/test_b.py:1:" "$work/out" && fail "a python case that asserts is listed: $(cat "$work/out")"
config '{"audit":false,"preset":"go","checks":[{"name":"lint","run":"true"}]}'
run check || fail "check fails: $(cat "$work/out")"
grep -qF "warn  test case with no assertion: src/b_test.go:5: func TestB" "$work/out" || fail "go case not listed: $(cat "$work/out")"
grep -q "src/b_test.go:2:" "$work/out" && fail "a go case that asserts is listed: $(cat "$work/out")"
config '{"audit":false,"preset":"rust","checks":[{"name":"lint","run":"true"}]}'
run check || fail "check fails: $(cat "$work/out")"
grep -qF "warn  test case with no assertion: tests/c.rs:3: fn b()" "$work/out" || fail "rust case not listed: $(cat "$work/out")"
grep -q "tests/c.rs:1:" "$work/out" && fail "a rust case that asserts is listed: $(cat "$work/out")"

[ "$failures" -eq 0 ] && echo "check: all cases pass"
exit "$failures"
