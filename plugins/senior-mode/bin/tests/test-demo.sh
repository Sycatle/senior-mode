#!/usr/bin/env bash
# Tests for `senior-mode demo` (#806). Offline: gh is a stub (the account, repo view/create/clone on local bare repositories
# under $work/remotes, the merged pull requests of $FIX/prs.json) and the senior-mode command that demo runs inside the demo
# repository is a stub too (SENIOR_MODE_DEMO_CLI): it logs its arguments, numbers the tickets it files, and its `serve`
# merges three pull requests one after the other until it is stopped. demo.json goes to a temporary XDG_DATA_HOME.
# shellcheck disable=SC2016 # stub bodies, not expanded here
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
  "api user --jq .login") echo tester ;;
  "api repos/"*" --jq .description") cat "$FIX/desc-$(basename "$2")" 2>/dev/null || echo "senior-mode demo (throwaway)" ;;
  "repo delete "*)
    [ ! -f "$FIX/noscope" ] || { echo "error: your authentication token is missing required scopes [delete_repo]" >&2; exit 1; } ;;
  "repo view "*) [ -d "$WORK/remotes/$3.git" ] ;;
  "repo create "*)
    git init -q --bare -b main "$WORK/remotes/$3.git" ;;
  "repo clone "*) git clone -q "$WORK/remotes/$3.git" "$4" 2>/dev/null ;;
  "pr list "*)
    jq -r "$(sed -E 's/.*--jq (.*)$/\1/' <<<"$*")" "$FIX/prs.json" 2>/dev/null || echo '[]' ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac
STUB
cat >"$work/stub/sm" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "setup repo") echo '{}' >.claude/senior-mode.json 2>/dev/null || { mkdir -p .claude && echo '{}' >.claude/senior-mode.json; } ;;
esac
case "$1" in
  issue)
    n=$(($(cat "$FIX/issues" 2>/dev/null || echo 0) + 1))
    echo "$n" >"$FIX/issues"
    args=("$@")
    while [ $# -gt 0 ]; do case $1 in --body-file) cp "$2" "$FIX/body-$n" ;; esac; shift; done
    echo "$(IFS=' '; echo "${args[*]}")" >>"$CLI_LOG"
    echo "#$n ${args[3]} (created)" ;;
  serve)
    echo "serve parallel=$(jq -r .autonomy.parallel .claude/senior-mode.local.json) merge=$(jq -r .autonomy.merge .claude/senior-mode.local.json) budget=$SENIOR_MODE_DAY_BUDGET_USD" >>"$CLI_LOG"
    trap 'exit 0' TERM
    for i in 1 2 3; do
      sleep 0.3
      jq -c --argjson i "$i" '. + [{number: (10 + $i), url: "https://github.com/pr/\(10 + $i)", closingIssuesReferences: [{number: $i}]}]' \
        <<<"$(cat "$FIX/prs.json" 2>/dev/null || echo '[]')" >"$FIX/prs.json.tmp" && mv "$FIX/prs.json.tmp" "$FIX/prs.json"
    done
    while :; do sleep 0.2; done ;;
  *) echo "$*" >>"$CLI_LOG" ;;
esac
STUB
chmod +x "$work/stub/gh" "$work/stub/sm"
export PATH="$work/stub:$PATH" WORK="$work" GH_LOG="$work/gh.log" CLI_LOG="$work/cli.log" FIX="$work/fix" SENIOR_MODE_RETRY_DELAY=0
export SENIOR_MODE_DEMO_CLI="$work/stub/sm" SENIOR_MODE_DEMO_POLL=0.2 SENIOR_MODE_DEMO_TIMEOUT=30 XDG_DATA_HOME="$work/xdg"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
unset SENIOR_MODE_FAULT

fresh() {
  rm -rf "$work/xdg" "$work/remotes" "$FIX" "$work/fault"
  mkdir -p "$work/remotes" "$FIX" "$work/fault"
  : >"$GH_LOG"
  : >"$CLI_LOG"
}

# 1. No terminal and no --yes: it prints what it would create, refuses, and creates nothing.
fresh
out=$("$cli" demo </dev/null 2>&1) && fail "demo without a terminal and without --yes succeeded"
grep -q 'will create' <<<"$out" || fail "demo did not print what it would create: $out"
! grep -q 'repo create' "$GH_LOG" || fail "demo created a repository without confirmation"

# 2. --yes: a private repository with the marker, three tickets, setup, serve with parallel 3, merge on and 3 USD.
fresh
out=$("$cli" demo --yes </dev/null 2>&1) || fail "demo --yes failed: $out"
grep -qE '^repo create tester/senior-mode-demo-[0-9a-f]{6} --private --description senior-mode demo \(throwaway\)$' "$GH_LOG" ||
  fail "no private repo with the marker: $(grep 'repo create' "$GH_LOG")"
[ "$(grep -c '^issue create' "$CLI_LOG")" = 3 ] || fail "expected three tickets: $(cat "$CLI_LOG")"
[ "$(grep -c -- '--type feature' "$CLI_LOG")" = 2 ] && [ "$(grep -c -- '--type bug' "$CLI_LOG")" = 1 ] ||
  fail "expected two features and one bug: $(cat "$CLI_LOG")"
grep -q 'Failing test' "$FIX/body-3" || fail "the bug ticket carries no failing test"
{ grep -qx 'setup github' "$CLI_LOG" && grep -qx 'setup repo' "$CLI_LOG"; } || fail "setup github / setup repo missing: $(cat "$CLI_LOG")"
grep -qx 'serve parallel=3 merge=true budget=3' "$CLI_LOG" || fail "serve not started with parallel 3, merge on, 3 USD: $(cat "$CLI_LOG")"

# 3. The narration is in order, the three pull requests are merged, the last lines are the links.
mapfile -t steps < <(grep -oE '^\[[0-9]/7\] .*, [0-9]+ s$' <<<"$out" | sed -E 's#^\[([0-9])/7\].*#\1#')
[ "${steps[*]}" = "1 2 3 4 5 6 7" ] || fail "narration steps: ${steps[*]:-none}"
grep -qE '^\[5/7\] ticket #1 delivered, [0-9]+ s$' <<<"$out" || fail "no delivery line for ticket #1: $out"
[ "$(jq length "$FIX/prs.json")" = 3 ] || fail "three pull requests should be merged"
[ "$(tail -4 <<<"$out" | head -1)" = "https://github.com/$(jq -r '.repositories[0].repo' "$XDG_DATA_HOME/senior-mode/demo.json")" ] ||
  fail "the links do not start with the repository: $(tail -4 <<<"$out")"
[ "$(tail -3 <<<"$out" | tr '\n' ' ')" = "https://github.com/pr/11 https://github.com/pr/12 https://github.com/pr/13 " ] ||
  fail "the last lines are not the pull request links: $(tail -3 <<<"$out")"

# 5. demo.json of a finished run; a second demo starts a new repository.
f=$XDG_DATA_HOME/senior-mode/demo.json
jq -e '.repositories[0] | (.repo | test("^tester/senior-mode-demo-[0-9a-f]{6}$")) and (.created | test("^20")) and .step == 7 and .finished == true' "$f" >/dev/null ||
  fail "demo.json of a finished run: $(cat "$f")"
rm -f "$FIX/prs.json"
"$cli" demo --yes --budget 5 </dev/null >/dev/null 2>&1 || fail "second demo failed"
[ "$(jq '.repositories | length' "$f")" = 2 ] || fail "the second demo should record a new repository: $(cat "$f")"
grep -qx 'serve parallel=3 merge=true budget=5' "$CLI_LOG" || fail "--budget 5 not passed: $(cat "$CLI_LOG")"

# 4. Killed after the second ticket was filed, then run again: no second repository, no duplicate ticket.
fresh
{ SENIOR_MODE_TEST=1 SENIOR_MODE_FAULT=demo-issue:2 SENIOR_MODE_FAULT_DIR="$work/fault" "$cli" demo --yes </dev/null >/dev/null 2>&1; } 2>/dev/null
[ "$(grep -c '^issue create' "$CLI_LOG")" = 2 ] || fail "the fault point did not stop demo after two tickets: $(cat "$CLI_LOG")"
jq -e '.repositories[0].finished == false and (.repositories[0].issues | length) == 2' "$f" >/dev/null || fail "demo.json after the kill: $(cat "$f")"
out=$("$cli" demo --yes </dev/null 2>&1) || fail "the resumed demo failed: $out"
[ "$(grep -c 'repo create' "$GH_LOG")" = 1 ] || fail "a second repository was created: $(grep 'repo create' "$GH_LOG")"
[ "$(grep -c '^issue create' "$CLI_LOG")" = 3 ] || fail "the resume duplicated or missed a ticket: $(grep '^issue create' "$CLI_LOG")"
jq -e '(.repositories | length) == 1 and .repositories[0].finished == true' "$f" >/dev/null || fail "demo.json after the resume: $(cat "$f")"

# 7. demo --clean (#808): only the recorded repository with the marker is deleted; the entry leaves demo.json.
fresh
mkdir -p "$XDG_DATA_HOME/senior-mode"
f=$XDG_DATA_HOME/senior-mode/demo.json
rec() { jq -n --arg a "$1" '{repositories: [{repo: $a, created: "2026-11-27T10:00:00Z", step: 7, finished: true, issues: []}]}' >"$f"; }
rec tester/senior-mode-demo-aaaaaa
out=$("$cli" demo --clean --yes </dev/null 2>&1) || fail "demo --clean --yes failed: $out"
[ "$(grep '^repo delete' "$GH_LOG")" = 'repo delete tester/senior-mode-demo-aaaaaa --yes' ] ||
  fail "only the recorded repository should be deleted (never senior-mode-demo-abc123): $(grep 'repo delete' "$GH_LOG")"
[ "$(jq '.repositories | length' "$f")" = 0 ] || fail "the deleted entry stays in demo.json: $(cat "$f")"

# Nothing recorded: it says so and deletes nothing.
: >"$GH_LOG"
out=$("$cli" demo --clean --yes </dev/null 2>&1) || fail "demo --clean with no entry failed: $out"
grep -q 'nothing to clean' <<<"$out" || fail "no 'nothing to clean': $out"
! grep -q 'repo delete' "$GH_LOG" || fail "a deletion with no entry"

# The marker is gone from the description: nothing is deleted, and the output says so.
rec tester/senior-mode-demo-bbbbbb
echo "my own project" >"$FIX/desc-senior-mode-demo-bbbbbb"
out=$("$cli" demo --clean --yes </dev/null 2>&1) || fail "demo --clean with a missing marker failed: $out"
grep -q 'marker.*missing' <<<"$out" || fail "the output does not say the marker is missing: $out"
! grep -q 'repo delete' "$GH_LOG" || fail "a repository without the marker was deleted"
[ "$(jq '.repositories | length' "$f")" = 1 ] || fail "the entry without marker should stay"

# A token without delete_repo: the refresh command is named, the entry stays, the exit is non-zero.
rec tester/senior-mode-demo-cccccc
touch "$FIX/noscope"
out=$("$cli" demo --clean --yes </dev/null 2>&1) && fail "demo --clean succeeded without the delete_repo scope"
grep -q 'gh auth refresh -s delete_repo' <<<"$out" || fail "the scope fix is not named: $out"
[ "$(jq '.repositories | length' "$f")" = 1 ] || fail "the entry should stay after a failed deletion"
rm -f "$FIX/noscope"

# No terminal and no --yes: nothing is deleted.
: >"$GH_LOG"
"$cli" demo --clean </dev/null >/dev/null 2>&1 && fail "demo --clean without a terminal and without --yes succeeded"
! grep -q 'repo delete' "$GH_LOG" || fail "a deletion without confirmation"

# 6. The usage line and the guide carry demo.
grep -q 'demo \[--yes\] \[--budget <usd>\] \[--clean\]' "$cli" || fail "usage line lacks demo"
grep -q '^| `senior-mode demo' "$(dirname "$cli")/../../../docs/guide/commands.md" || fail "commands.md has no demo row"

if [ "$failures" -eq 0 ]; then echo "test-demo: ok"; else echo "test-demo: $failures failure(s)"; exit 1; fi
