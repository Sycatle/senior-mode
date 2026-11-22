#!/usr/bin/env bash
# Tests for `senior-mode run`. Offline: gh, claude and tmux are stubs. gh answers the board query and
# the REST calls from fixtures in $FIX; claude plays a ticket session from $FIX/claude-<n>-<model>
# (line 1: the outcome to write, empty for none; line 2: "pr" to open a pull request; line 3: "hang" to
# never end, with a child process, recorded in $FIX/pids-<n>, to check that a killed session leaves none;
# "decoy": the same, but the session's recorded process group is swapped for another group, whose leader is
# not the session's script, to check that run kills nothing it does not recognise).
# A claude session whose prompt says "guard probe" is the daily probe of #117: $FIX/probe says whether the
# stub honours the deny (default: prints the deny, runs nothing), ignores it (runs the denied command) or
# is silent (no deny to see). CLAUDE_CONFIG_DIR holds the user settings that enable the plugin.
# The per-ticket outcome files `run` leaves are checked against the records of fixture-runs.sh, the same
# ones test-retro.sh feeds to `retro`.
# shellcheck disable=SC2016 # jq programs and stub bodies, not expanded here
set -u
cli=$(cd "$(dirname "$0")/.." && pwd)/senior-mode
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0
# shellcheck source=/dev/null
. "$(dirname "$0")/fixture-runs.sh"

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

mkdir -p "$work/stub" "$work/tmux" "$work/fix"
cat >"$work/stub/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$GH_LOG"
jqf="" prev=""
for a in "$@"; do [ "$prev" = --jq ] && jqf=$a; prev=$a; done
respond() { if [ -n "$jqf" ]; then jq -r "$jqf"; else cat; fi; }
arg() { local prev=""; for a in "$@"; do [ "$prev" = "$FLAG" ] && echo "$a"; prev=$a; done; }
case "$*" in
  "api graphql --input -") cat >/dev/null; cat "$FIX/board.json" ;;
  "api repos/acme/app/dependabot/alerts"* | "api repos/acme/app/secret-scanning/alerts"*)
    [ -z "${ALERTS_ERR:-}" ] || { echo "$ALERTS_ERR" >&2; exit 1; }
    f=${2#repos/acme/app/}; f=$FIX/${f%%/*}.json
    if [ -f "$f" ]; then respond <"$f"; else echo '[]' | respond; fi ;;
  "issue list"*) respond <"$FIX/issues.json" ;;
  "issue create"*)
    f=$(FLAG=--body-file arg "$@")
    n=$(jq '[42, (.[].number + 1)] | max' "$FIX/issues.json")
    labels=$(FLAG=--label arg "$@" | jq -R . | jq -sc 'map({name: .})')
    jq --argjson n "$n" --arg t "$(FLAG=--title arg "$@")" --rawfile b "$f" --argjson l "$labels" \
      '. + [{number: $n, title: $t, body: $b, labels: $l}]' "$FIX/issues.json" >"$FIX/i" && mv "$FIX/i" "$FIX/issues.json"
    echo "https://github.com/acme/app/issues/$n" ;;
  "repo view"*) echo '{"isPrivate": false}' | respond ;;
  "api -X POST repos/acme/app/security-advisories"*)
    cat >>"$FIX/advisories"; echo '{"html_url": "https://github.com/acme/app/security/advisories/GHSA-1"}' | respond ;;

  "issue view "*)
    n=$(sed -E 's#^issue view ([0-9]+) .*#\1#' <<<"$*")
    jq -c --argjson n "$n" '.data.node.items.nodes[] | select(.content.number == $n) | .content
      | {title, state, labels: .labels.nodes}' "$FIX/board.json" ;;
  "project item-add"*) echo "ITEM_$(sed -E 's#.*/issues/([0-9]+).*#\1#' <<<"$*")" ;;
  "project item-edit"*) ;;
  "api repos/acme/app/pulls/"*"/files"*)
    pr=$(sed -E 's#.*/pulls/([0-9]+)/files.*#\1#' <<<"$*")
    cat "$FIX/files-$pr" 2>/dev/null || echo src/app.ts ;;
  "api repos/acme/app/pulls?head="*)
    n=$(sed -E 's#.*head=acme:[a-z]+/([0-9]+)-.*#\1#' <<<"$*")
    cat "$FIX/pulls-$n" 2>/dev/null || echo '[]' ;;
  "api repos/acme/app/commits/sha"*"/status")
    n=$(sed -E 's#.*/sha([0-9]+)/status#\1#' <<<"$*")
    cat "$FIX/status-$n" 2>/dev/null || echo '{"statuses": []}' ;;
  "api repos/acme/app/issues/"*"/comments"*) echo '{}' ;;
  "api repos/acme/app/issues/"*"/labels"*) echo '[]' ;;
  "pr merge"*) ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac
STUB
cat >"$work/stub/claude" <<'STUB'
#!/usr/bin/env bash
args=("$@")
for ((i = 0; i < $#; i++)); do [ "${args[i]}" != --model ] || model=${args[i + 1]}; done
echo "$(basename "$PWD") $model run=${SENIOR_MODE_RUN:-} ${*:1:$# - 1}" >>"$CLAUDE_LOG"
if [[ ${!#} == *"guard probe"* ]]; then
  case $(cat "$FIX/probe" 2>/dev/null || echo honour) in
    honour) echo '{"type": "user", "message": {"content": "senior-mode: skipping checks is denied (core.hooksPath); fix what the check reports instead."}}' ;;
    ignore) git init -q "$(sed -nE 's#.*init -q ([^ `]+).*#\1#p' <<<"${!#}")"; echo '{"type": "result"}' ;;
    silent) echo '{"type": "result"}' ;;
    hang) exec sleep 30 ;;
  esac
  exit 0
fi
if [[ $PWD == *-run-docs-* ]] && [ "$(cat "$FIX/docs" 2>/dev/null)" = hang ]; then
  sleep 300 &
  echo "$$ $!" >"$FIX/pids-docs"
  wait
fi
n=$(sed -nE 's#.*/app-([0-9]+)$#\1#p' <<<"$PWD")
[ -n "$n" ] || exit 0
fx=$FIX/claude-$n-$model
[ -f "$fx" ] || exit 1
if [ "$(sed -n 3p "$fx")" = hang ]; then
  sleep 300 &
  echo "$$ $!" >"$FIX/pids-$n"
  wait
fi
if [ "$(sed -n 3p "$fx")" = decoy ]; then
  setsid sleep 301 &
  decoy=$!
  echo "$decoy" >"${SENIOR_MODE_RUN_OUTCOME%.outcome}.pgid"
  sleep 300 &
  echo "$$ $! $decoy" >"$FIX/pids-$n"
  wait
fi
outcome=$(sed -n 1p "$fx")
[ -z "$outcome" ] || echo "$outcome" >"$SENIOR_MODE_RUN_OUTCOME"
[ "$(sed -n 2p "$fx")" != pr ] ||
  echo "[{\"number\": $((n + 100)), \"head\": {\"sha\": \"sha$n\"}, \"labels\": $(cat "$FIX/labels-$n" 2>/dev/null || echo '[]')}]" >"$FIX/pulls-$n"
echo '{"result": "ok"}'
STUB
cat >"$work/tmux/tmux" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$TMUX_LOG"
case $1 in
  has-session) [ -f "$FIX/tmux-session" ] ;;
  new-session | new-window)
    touch "$FIX/tmux-session"
    setsid bash -c "${*: -1}" >/dev/null 2>&1 &
    ;;
esac
STUB
sed 's/CLAUDE_LOG/SYACODE_LOG/' "$work/stub/claude" >"$work/stub/syacode"
chmod +x "$work/stub/"* "$work/tmux/tmux"
export PATH="$work/stub:$PATH" GH_LOG="$work/gh.log" CLAUDE_LOG="$work/claude.log" SYACODE_LOG="$work/syacode.log" TMUX_LOG="$work/tmux.log" \
  FIX="$work/fix" SENIOR_MODE_RETRY_DELAY=0 SENIOR_MODE_POLL=0.1 CLAUDE_CONFIG_DIR="$work/claude-home"
mkdir -p "$CLAUDE_CONFIG_DIR"
echo '{"enabledPlugins": {"senior-mode@senior-mode": true}}' >"$CLAUDE_CONFIG_DIR/settings.json"

# A local origin whose path ends like a GitHub URL, so the slug reads acme/app.
git init -q --bare -b main "$work/github.com/acme/app.git"
repo="$work/app"
git init -q -b main "$repo"
git -C "$repo" remote add origin "$work/github.com/acme/app.git"
mkdir -p "$repo/.claude"
fields='{"Status": {"id": "F_S", "options": {"Ready": "o1", "In progress": "o2", "In review": "o3", "Backlog": "o0", "Done": "o4"}}}'
config() {
  jq -n --argjson f "$fields" --argjson a "$1" '{project: {id: "PVT_1", owner: "acme", number: 3, fields: $f}, autonomy: $a}
    + $ARGS.named' ${2:+--argjson github "$2"} ${3:+--argjson agent "$3"} >"$repo/.claude/senior-mode.json"
  git -C "$repo" add -A
  git -C "$repo" -c user.name=t -c user.email=t@t commit -q -m "chore: config" --allow-empty
  git -C "$repo" push -q origin main
}

# board <number> <labels json>...: Ready tickets, in priority order.
board() {
  local items="[]" n
  while [ $# -gt 0 ]; do
    n=$1
    items=$(jq -c --argjson n "$n" --argjson l "$2" '. + [{fieldValues: {nodes: [{name: "Ready", field: {name: "Status"}},
      {name: "P1 next", field: {name: "Priority"}}, {name: "S", field: {name: "Size"}}]},
      content: {number: $n, title: "Ticket \($n)", url: "u", state: "OPEN", closedAt: null,
        labels: {nodes: ($l | map({name: .}))}, milestone: null, blockedBy: {nodes: []}}}]' <<<"$items")
    shift 2
  done
  jq -nc --argjson i "$items" '{data: {node: {items: {pageInfo: {hasNextPage: false}, nodes: $i}}}}' >"$FIX/board.json"
}
session() { printf '%s\n%s\n%s\n' "$2" "${3:-}" "${4:-}" >"$FIX/claude-$1"; }
green='{"statuses": [{"context": "senior-mode/ci", "state": "success"}, {"context": "senior-mode/review", "state": "success"},
  {"context": "senior-mode/security", "state": "success"}]}'
# outcome_is <ticket>: the outcome file of the ticket, in .git/senior-mode/runs/<stamp>/<n>.json, holds the
# fixture record and a finishedAt time.
outcome_is() {
  local f want got
  f=$(find "$repo/.git/senior-mode/runs" -name "$1.json" 2>/dev/null | tail -n 1)
  [ -n "$f" ] || { fail "no outcome file for #$1"; return; }
  want=$(jq -cS --argjson n "$1" '.[] | select(.ticket == $n)' <<<"$RUN_OUTCOMES")
  got=$(jq -cS 'del(.finishedAt)' "$f")
  [ "$got" = "$want" ] || fail "outcome of #$1: $got, wanted $want"
  jq -e '.finishedAt | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' "$f" >/dev/null ||
    fail "outcome of #$1 has no ISO finishedAt: $(cat "$f")"
}
outcome_is_delivered() {
  jq -e '.outcome == "delivered"' "$repo/.git/senior-mode/runs/"*/"$1.json" >/dev/null || fail "#$1 not recorded as delivered"
}
run() { : >"$GH_LOG"; : >"$CLAUDE_LOG"; : >"$SYACODE_LOG"; (cd "$repo" && "$cli" run "$@") >"$work/out" 2>&1; }

# A: three tickets two at a time in tmux; merging on. #10 merges; #11 succeeds on Opus but its review
# is not green; #12 fails on Sonnet and on Opus.
export PATH="$work/tmux:$PATH"
config '{"maxTickets": 3, "parallel": 2, "merge": true}' '{"protection": "ruleset"}'
board 10 '["type:bug"]' 11 '[]' 12 '[]' 13 '[]'
session 10-sonnet delivered pr
echo "$green" >"$FIX/status-10"
session 11-sonnet "failed: tests do not pass"
session 11-opus delivered pr
echo '{"statuses": [{"context": "senior-mode/ci", "state": "success"}, {"context": "senior-mode/review", "state": "pending"},
  {"context": "senior-mode/security", "state": "success"}]}' >"$FIX/status-11"
session 12-sonnet "failed: cannot build"
session 12-opus "failed: still cannot build"
run || fail "A: run failed: $(cat "$work/out")"
[ "$(git -C "$work/app-10" branch --show-current 2>/dev/null)" = fix/10-ticket-10 ] ||
  fail "A: no worktree on fix/10-ticket-10: $(git -C "$repo" worktree list)"
git -C "$work/app-11" branch --show-current 2>/dev/null | grep -qx feat/11-ticket-11 || fail "A: no feat branch for #11"
grep -q 'issue view 10 ' "$GH_LOG" || fail "A: the worktree was not opened by senior-mode start: $(cat "$GH_LOG")"
grep -q 'app-10 sonnet run=1 -p --model sonnet --permission-mode bypassPermissions --output-format json' "$CLAUDE_LOG" ||
  fail "A: claude not called as expected: $(cat "$CLAUDE_LOG")"
grep -q 'senior-mode issue create --severity' "$repo/.git/senior-mode/runs/"*/10.prompt ||
  fail "A: the session prompt does not say to file a risk outside the ticket"
grep -q '^app-10 opus' "$CLAUDE_LOG" && fail "A: a delivered ticket was retried on Opus"
grep -q '^app-11 opus' "$CLAUDE_LOG" || fail "A: a failed ticket was not retried on Opus"
grep -q '^app-12 opus' "$CLAUDE_LOG" || fail "A: #12 not retried on Opus"
grep -q 'app-13' "$CLAUDE_LOG" && fail "A: more than maxTickets tickets started"
grep -qx 'pr merge 110 --rebase --match-head-commit sha10 -R acme/app' "$GH_LOG" || fail "A: green #10 not merged: $(grep merge "$GH_LOG")"
grep -q 'pr merge 111' "$GH_LOG" && fail "A: #11 merged without a green review"
grep -q 'PUT' "$GH_LOG" && fail "A: the REST merge endpoint was used"
grep -q 'issues/12/comments' "$GH_LOG" || fail "A: no comment on the failed ticket"
grep -q 'issues/1[01]/comments' "$GH_LOG" && fail "A: a comment on a delivered ticket"
grep -c 'item-edit.*--single-select-option-id o2' "$GH_LOG" | grep -qx 3 || fail "A: tickets not set In progress"
grep -c 'item-edit.*--single-select-option-id o0' "$GH_LOG" | grep -qx 1 || fail "A: the failed ticket not set back to Backlog"
grep -c 'item-edit.*--single-select-option-id o4' "$GH_LOG" | grep -qx 1 || fail "A: only the merged ticket is set Done"
grep -c 'new-session\|new-window' "$TMUX_LOG" | grep -qx 5 || fail "A: not one tmux window per session: $(cat "$TMUX_LOG")"
grep -q 'docs' "$CLAUDE_LOG" || fail "A: no docs session after a merge"
grep -q 'Merged.*#10' "$work/out" || fail "A: report misses the merge: $(cat "$work/out")"
grep -q 'Waiting for a human.*#11.*senior-mode/review' "$work/out" || fail "A: report misses #11 waiting: $(cat "$work/out")"
grep -q 'Failed.*#12.*still cannot build' "$work/out" || fail "A: report misses why #12 failed: $(cat "$work/out")"
outcome_is 10
outcome_is 11
outcome_is 12
git -C "$repo" status --porcelain | grep -q . && fail "A: run left the checkout dirty: $(git -C "$repo" status --porcelain)"

# B: no tmux, merging off (default), no escalation, circuit breaker at one failure. #20 says
# delivered but opened no pull request: a failure. #21 is never started.
export PATH=${PATH#"$work/tmux:"}
config '{"maxConsecutiveFailures": 1, "escalate": false}'
board 20 '[]' 21 '[]'
session 20-sonnet delivered
session 21-sonnet delivered pr
run || fail "B: run failed: $(cat "$work/out")"
grep -q 'app-21' "$CLAUDE_LOG" && fail "B: circuit breaker did not stop the run"
grep -q 'opus' "$CLAUDE_LOG" && fail "B: escalated although autonomy.escalate is false"
grep -q 'Failed.*#20.*no open pull request' "$work/out" || fail "B: report misses #20: $(cat "$work/out")"
grep -q 'Not started.*#21' "$work/out" || fail "B: report misses #21 not started: $(cat "$work/out")"
outcome_is 20

# C: an outgrown ticket stops the run and is not retried on Opus.
config '{}'
board 30 '[]' 31 '[]'
session 30-sonnet "outgrown: needs a data migration"
run || fail "C: run failed: $(cat "$work/out")"
grep -q 'app-30 opus' "$CLAUDE_LOG" && fail "C: an outgrown ticket was retried"
grep -q 'app-31' "$CLAUDE_LOG" && fail "C: run went on after an outgrown ticket"
grep -q 'issues/30/comments' "$GH_LOG" || fail "C: no comment on the outgrown ticket"
grep -q 'needs a data migration' "$work/out" || fail "C: report misses the reason: $(cat "$work/out")"
outcome_is 30

# D: merging on but no protection on the server, and a needs-human label: nothing merges. --max 1.
config '{"merge": true}' '{"protection": "none"}'
board 40 '[]' 41 '[]'
session 40-sonnet delivered pr
echo "$green" >"$FIX/status-40"
run --max 1 || fail "D: run failed: $(cat "$work/out")"
grep -q 'pr merge' "$GH_LOG" && fail "D: merged without server-side protection"
grep -q 'app-41' "$CLAUDE_LOG" && fail "D: --max 1 started two tickets"
grep -q 'Waiting for a human.*#40.*protection' "$work/out" || fail "D: report misses why #40 waits: $(cat "$work/out")"
config '{"merge": true}' '{"protection": "ruleset"}'
board 42 '[]'
session 42-sonnet delivered pr
echo '[{"name": "needs-human"}]' >"$FIX/labels-42"
echo "$green" >"$FIX/status-42"
run || fail "D: run failed: $(cat "$work/out")"
grep -q 'pr merge' "$GH_LOG" && fail "D: merged a needs-human pull request"
grep -q 'Waiting for a human.*#42.*needs-human' "$work/out" || fail "D: report misses the label: $(cat "$work/out")"
config '{"merge": true}'
board 43 '[]'
session 43-sonnet delivered pr
echo "$green" >"$FIX/status-43"
run || fail "D: run failed: $(cat "$work/out")"
grep -q 'pr merge' "$GH_LOG" && fail "D: merged with github.protection unset"
grep -q 'option-id o4' "$GH_LOG" && fail "D: an unmerged ticket set Done"

# H: green and unlabelled, but a protected zone of the base branch is touched (a rename out of it
# counts): no merge, whatever the reviewer said. The branch's own config cannot lift it.
config '{"merge": true}' '{"protection": "ruleset"}'
jq '.protected = ["auth/**"]' "$repo/.claude/senior-mode.json" >"$work/c" && mv "$work/c" "$repo/.claude/senior-mode.json"
git -C "$repo" -c user.name=t -c user.email=t@t commit -qam "chore: protect auth" && git -C "$repo" push -q origin main
board 44 '[]'
session 44-sonnet delivered pr
echo "$green" >"$FIX/status-44"
printf 'src/session.ts\nauth/session.ts\n' >"$FIX/files-144"
run || fail "H: run failed: $(cat "$work/out")"
grep -q 'pr merge' "$GH_LOG" && fail "H: merged a pull request that touches a protected zone"
grep -q 'Waiting for a human.*#44.*protected zone (auth/session.ts)' "$work/out" ||
  fail "H: report misses the protected zone: $(cat "$work/out")"

# K: ci and review green but the security status is missing or not success: no merge, and the report
# names it. A security status that is success merges (A, #10).
config '{"merge": true}' '{"protection": "ruleset"}'
board 45 '[]' 46 '[]'
session 45-sonnet delivered pr
session 46-sonnet delivered pr
echo '{"statuses": [{"context": "senior-mode/ci", "state": "success"}, {"context": "senior-mode/review", "state": "success"}]}' >"$FIX/status-45"
echo '{"statuses": [{"context": "senior-mode/ci", "state": "success"}, {"context": "senior-mode/review", "state": "success"},
  {"context": "senior-mode/security", "state": "pending"}]}' >"$FIX/status-46"
run || fail "K: run failed: $(cat "$work/out")"
grep -q 'pr merge' "$GH_LOG" && fail "K: merged without senior-mode/security success: $(grep merge "$GH_LOG")"
grep -q 'Waiting for a human.*#45.*senior-mode/security not green' "$work/out" || fail "K: report misses #45: $(cat "$work/out")"
grep -q 'Waiting for a human.*#46.*senior-mode/security not green' "$work/out" || fail "K: report misses #46: $(cat "$work/out")"

# F: a ticket already opened with `senior-mode start` (its worktree and branch exist) is reused as it is.
config '{}'
board 50 '["type:bug"]'
(cd "$repo" && "$cli" start 50) >/dev/null 2>&1 || fail "F: start 50 failed"
session 50-sonnet delivered pr
run || fail "F: run failed: $(cat "$work/out")"
[ "$(git -C "$repo" worktree list | grep -c 'app-50 ')" -eq 1 ] || fail "F: not one worktree for #50: $(git -C "$repo" worktree list)"
grep -q '^app-50 sonnet' "$CLAUDE_LOG" || fail "F: no session in the worktree of start: $(cat "$CLAUDE_LOG")"
outcome_is_delivered 50

# G: agent.command launches another headless CLI instead of claude, for the tickets and the docs session.
config '{"merge": true}' '{"protection": "ruleset"}' '{"command": "syacode"}'
board 60 '[]'
session 60-sonnet delivered pr
echo "$green" >"$FIX/status-60"
run || fail "G: run failed: $(cat "$work/out")"
grep -q 'app-60 sonnet run=1 -p --model sonnet' "$SYACODE_LOG" || fail "G: agent.command not used: $(cat "$SYACODE_LOG")"
grep -q 'docs' "$SYACODE_LOG" || fail "G: the docs session did not use agent.command"
[ -s "$CLAUDE_LOG" ] && fail "G: claude was started although agent.command is syacode: $(cat "$CLAUDE_LOG")"
config '{}' '' '{"command": "no-such-agent"}'
board 61 '[]'
run && fail "G: run started with an agent command that does not exist"
grep -q 'no-such-agent' "$work/out" || fail "G: missing agent not named: $(cat "$work/out")"

# I: the wip limit binds people, not runs (#125): parallel 2, wip 1 and #70 already In progress.
config '{"parallel": 2}'
board 71 '[]' 72 '[]'
jq '.data.node.items.nodes += [{fieldValues: {nodes: [{name: "In progress", field: {name: "Status"}}]},
  content: {number: 70, title: "Ticket 70", url: "u", state: "OPEN", closedAt: null, labels: {nodes: []},
    milestone: null, blockedBy: {nodes: []}}}]' "$FIX/board.json" >"$work/b" && mv "$work/b" "$FIX/board.json"
session 71-sonnet delivered pr
session 72-sonnet delivered pr
run || fail "I: run failed: $(cat "$work/out")"
[ "$(grep -c '^app-7[12] sonnet' "$CLAUDE_LOG")" -eq 2 ] ||
  fail "I: the wip limit stopped a run ticket: $(cat "$work/out")"

# J: the base branch has no .claude/senior-mode.json, so its protected zones are unknown: no merge (#116).
config '{"merge": true}' '{"protection": "ruleset"}'
git -C "$repo" rm -q --cached .claude/senior-mode.json &&
  git -C "$repo" -c user.name=t -c user.email=t@t commit -qm "chore: drop config" && git -C "$repo" push -q origin main
board 80 '[]'
session 80-sonnet delivered pr
echo "$green" >"$FIX/status-80"
run || fail "J: run failed: $(cat "$work/out")"
grep -q 'pr merge' "$GH_LOG" && fail "J: merged without the base branch's protected zones"
grep -q 'Waiting for a human.*#80.*protected zones could not be read' "$work/out" ||
  fail "J: report misses why #80 waits: $(cat "$work/out")"

# K: a session that outlives autonomy.sessionTimeout (1 minute, scaled to a second) is killed with its
# processes, the ticket gets needs-human and a comment with the log path, stays In progress, is not retried
# on Opus and counts for the breaker (#115). #91 is never started.
config '{"maxConsecutiveFailures": 1, "sessionTimeout": 1}'
board 90 '[]' 91 '[]'
session 90-sonnet "" "" hang
session 91-sonnet delivered pr
SENIOR_MODE_TIMEOUT_UNIT=1 run || fail "K: run failed: $(cat "$work/out")"
grep -q 'app-90 opus' "$CLAUDE_LOG" && fail "K: a timed out session was retried on Opus"
grep -q 'app-91' "$CLAUDE_LOG" && fail "K: the breaker did not count the timeout"
grep -q 'issues/90/labels.*needs-human' "$GH_LOG" || fail "K: #90 not labelled needs-human: $(cat "$GH_LOG")"
grep -q '90-sonnet.log' "$GH_LOG" || fail "K: no comment with the log path on #90"
grep -q 'item-edit.*--single-select-option-id o0' "$GH_LOG" && fail "K: #90 was set back to Backlog"
grep -q 'Failed.*#90.*timed out after 1 minute' "$work/out" || fail "K: report misses the timeout: $(cat "$work/out")"
jq -e '.outcome == "failed" and .escalated == false and .reason == "timed out after 1 minute"' \
  "$repo/.git/senior-mode/runs/"*"/90.json" >/dev/null || fail "K: #90 not recorded as timed out"
read -r -a pids <"$FIX/pids-90"
for pid in "${pids[@]}"; do kill -0 "$pid" 2>/dev/null && fail "K: process $pid of the session is still alive"; done
for pid in "${pids[@]}"; do kill -9 "$pid" 2>/dev/null; done
config '{"sessionTimeout": 0}'
run && fail "K: sessionTimeout 0 accepted"
grep -q 'sessionTimeout' "$work/out" || fail "K: bad sessionTimeout not named: $(cat "$work/out")"
config '{"sessionTimeout": 1441}'
board
run && fail "K: sessionTimeout above a day accepted"
grep -q 'sessionTimeout' "$work/out" || fail "K: too long a sessionTimeout not named: $(cat "$work/out")"

# L: the recorded process group is not the session's (its leader is not <n>.sh): nothing is killed, run
# says so, and the ticket is still labelled needs-human and recorded as timed out.
config '{"sessionTimeout": 1}'
board 92 '[]'
session 92-sonnet "" "" decoy
SENIOR_MODE_TIMEOUT_UNIT=1 run || fail "L: run failed: $(cat "$work/out")"
read -r -a pids <"$FIX/pids-92"
kill -0 "${pids[2]}" 2>/dev/null || fail "L: run killed a process group that is not the session's"
for pid in "${pids[@]}"; do kill -9 "$pid" 2>/dev/null; done
grep -q '#92.*not stopped' "$work/out" || fail "L: the unstopped session is not reported: $(cat "$work/out")"
grep -q 'issues/92/labels.*needs-human' "$GH_LOG" || fail "L: #92 not labelled needs-human"
jq -e '.outcome == "failed" and .reason == "timed out after 1 minute"' "$repo/.git/senior-mode/runs/"*"/92.json" >/dev/null ||
  fail "L: #92 not recorded as timed out"

# N: the docs session after a merge is bounded by the same timeout (#120): killed with its processes, recorded
# in the run log (docs-outcome.json) and reported, and run ends normally. Without a timeout it is recorded done.
config '{"sessionTimeout": 1, "merge": true}' '{"protection": "ruleset"}'
board 110 '[]'
session 110-sonnet delivered pr
echo "$green" >"$FIX/status-110"
echo hang >"$FIX/docs"
SECONDS=0
SENIOR_MODE_TIMEOUT_UNIT=2 run || fail "N: run failed: $(cat "$work/out")"
[ "$SECONDS" -lt 30 ] || fail "N: run hung on the docs session ($SECONDS s)"
grep -qx 'pr merge 210 --rebase --match-head-commit sha110 -R acme/app' "$GH_LOG" || fail "N: #110 not merged: $(cat "$GH_LOG")"
read -r -a pids <"$FIX/pids-docs"
for pid in "${pids[@]}"; do kill -0 "$pid" 2>/dev/null && fail "N: process $pid of the docs session is still alive"; done
for pid in "${pids[@]}"; do kill -9 "$pid" 2>/dev/null; done
jq -e '.session == "docs" and .outcome == "failed" and .reason == "docs session timed out after 1 minute" and (.finishedAt | length > 0)' \
  "$repo/.git/senior-mode/runs/"*"/docs-outcome.json" >/dev/null || fail "N: the docs timeout is not recorded: $(cat "$repo"/.git/senior-mode/runs/*/docs-outcome.json)"
grep -q 'docs session timed out after 1 minute' "$work/out" || fail "N: report misses the docs timeout: $(cat "$work/out")"
grep -q 'issues/.*labels' "$GH_LOG" && fail "N: a docs timeout labelled a ticket"
rm -f "$FIX/docs"
board 111 '[]'
session 111-sonnet delivered pr
echo "$green" >"$FIX/status-111"
run || fail "N: run failed: $(cat "$work/out")"
jq -e '.session == "docs" and .outcome == "done" and .reason == null' "$repo/.git/senior-mode/runs/"*"/docs-outcome.json" >/dev/null ||
  fail "N: a docs session that finished is not recorded done"

# M: before a run starts (#117): the plugin must be enabled and hooks.json present, and once a day a probe
# session tries a denied, inert command (git -c core.hooksPath=... init <tmp>/ran). The deny must show in
# the session's output and the command must not have run, else run refuses to start.
config '{}'
board 100 '[]'
session 100-sonnet delivered pr
probe=$repo/.git/senior-mode/probe
rm -f "$probe"
echo ignore >"$FIX/probe"
run && fail "M: run started although the probe session ran the denied command"
grep -q 'guard' "$work/out" || fail "M: the failed probe is not explained: $(cat "$work/out")"
grep -q 'hooksPath' "$work/out" || fail "M: the failed probe does not name the denied command: $(cat "$work/out")"
grep -q 'app-100' "$CLAUDE_LOG" && fail "M: a ticket started after a failed probe"
[ -e "$probe" ] && fail "M: a failed probe was recorded as passed"
echo silent >"$FIX/probe"
run && fail "M: run started although no deny showed in the probe session"
grep -q 'app-100' "$CLAUDE_LOG" && fail "M: a ticket started after a silent probe"
echo honour >"$FIX/probe"
run || fail "M: run failed with a probe that honours the deny: $(cat "$work/out")"
grep -q 'haiku' "$CLAUDE_LOG" || fail "M: no probe session: $(cat "$CLAUDE_LOG")"
grep -q 'run=1 -p --model haiku --permission-mode bypassPermissions' "$CLAUDE_LOG" || fail "M: probe not launched like a run session: $(cat "$CLAUDE_LOG")"
[ "$(cat "$probe" 2>/dev/null)" = "$(date +%F)" ] || fail "M: probe date not recorded: $(cat "$probe" 2>/dev/null)"
echo ignore >"$FIX/probe"
board 101 '[]'
session 101-sonnet delivered pr
run || fail "M: the probe ran twice in a day: $(cat "$work/out")"
grep -q 'haiku' "$CLAUDE_LOG" && fail "M: a second probe the same day"
date -d yesterday +%F >"$probe" 2>/dev/null || date -v-1d +%F >"$probe"
run && fail "M: a probe of yesterday was not repeated"
echo honour >"$FIX/probe"
run || fail "M: run failed after a new honoured probe: $(cat "$work/out")"

echo '{"enabledPlugins": {"senior-mode@senior-mode": false}}' >"$CLAUDE_CONFIG_DIR/settings.json"
board 102 '[]'
session 102-sonnet delivered pr
run && fail "M: run started with the plugin disabled"
grep -q 'enabled' "$work/out" || fail "M: the disabled plugin is not named: $(cat "$work/out")"
grep -q 'app-102' "$CLAUDE_LOG" && fail "M: a ticket started with the plugin disabled"
# Ticket sessions run in fresh worktrees of the base branch: an untracked settings.local.json is not there.
echo '{"enabledPlugins": {"senior-mode@senior-mode": true}}' >"$repo/.claude/settings.local.json"
run && fail "M: run started with the plugin enabled only in the untracked settings.local.json"
grep -q 'enabled' "$work/out" || fail "M: the plugin not enabled for worktrees is not named: $(cat "$work/out")"
grep -q 'app-102' "$CLAUDE_LOG" && fail "M: a ticket started with the plugin enabled only in settings.local.json"
rm -f "$repo/.claude/settings.local.json"
# Enabled in the project's tracked settings on the base branch: ticket worktrees have it.
echo '{"enabledPlugins": {"senior-mode@senior-mode": true}}' >"$repo/.claude/settings.json"
git -C "$repo" add .claude/settings.json && git -C "$repo" -c user.name=t -c user.email=t@t commit -qm "chore: enable the plugin" &&
  git -C "$repo" push -q origin main
run || fail "M: the project's tracked setting did not enable the plugin: $(cat "$work/out")"
git -C "$repo" rm -q .claude/settings.json && git -C "$repo" -c user.name=t -c user.email=t@t commit -qm "chore: drop settings" &&
  git -C "$repo" push -q origin main
rm -f "$CLAUDE_CONFIG_DIR/settings.json"
run && fail "M: run started with no settings at all"
echo '{"enabledPlugins": {"senior-mode@senior-mode": true}}' >"$CLAUDE_CONFIG_DIR/settings.json"
# --plugin-dir loads the plugin without enabling it; its hooks.json must still be there.
mkdir -p "$work/plugin/hooks"
echo '{"enabledPlugins": {}}' >"$CLAUDE_CONFIG_DIR/settings.json"
SENIOR_MODE_PLUGIN_DIR="$work/plugin" run && fail "M: run started with a plugin dir that has no hooks.json"
grep -q 'hooks.json' "$work/out" || fail "M: the missing hooks.json is not named: $(cat "$work/out")"
echo '{}' >"$work/plugin/hooks/hooks.json"
SENIOR_MODE_PLUGIN_DIR="$work/plugin" run || fail "M: a plugin dir with hooks.json was refused: $(cat "$work/out")"
echo '{"enabledPlugins": {"senior-mode@senior-mode": true}}' >"$CLAUDE_CONFIG_DIR/settings.json"
# The probe runs in a throwaway worktree of the base branch, as ticket sessions do, and removes it.
rm -f "$probe"
board 103 '[]'
session 103-sonnet delivered pr
run || fail "M: run failed: $(cat "$work/out")"
grep -q '^probe haiku' "$CLAUDE_LOG" || fail "M: the probe did not run in a throwaway worktree: $(cat "$CLAUDE_LOG")"
git -C "$repo" worktree list | grep -q probe && fail "M: the probe worktree was left: $(git -C "$repo" worktree list)"
# A probe session that never ends is stopped after SENIOR_MODE_PROBE_TIMEOUT seconds (no `timeout` needed).
rm -f "$probe"
echo hang >"$FIX/probe"
SECONDS=0
SENIOR_MODE_PROBE_TIMEOUT=1 run && fail "M: run started although the probe session never ended"
[ "$SECONDS" -lt 20 ] || fail "M: the probe was not stopped after its timeout ($SECONDS s)"
grep -q 'app-103' "$CLAUDE_LOG" && fail "M: a ticket started after a probe that timed out"
echo honour >"$FIX/probe"

# Open alerts: a high Dependabot alert, a moderate and a low one (nothing to file), and an exposed secret
# whose value must never reach an issue.
fix_alerts() {
  jq -n '[{number: 1, state: "open", html_url: "https://github.com/acme/app/security/dependabot/1",
      security_advisory: {ghsa_id: "GHSA-aaaa-bbbb-cccc", severity: "high", summary: "Prototype pollution via crafted payload"},
      dependency: {package: {ecosystem: "npm", name: "lodash"}, manifest_path: "package-lock.json"}},
    {number: 2, state: "open", html_url: "u2", security_advisory: {ghsa_id: "GHSA-dddd", severity: "medium"},
      dependency: {package: {ecosystem: "npm", name: "minimist"}, manifest_path: "package-lock.json"}},
    {number: 3, state: "open", html_url: "u3", security_advisory: {ghsa_id: "GHSA-eeee", severity: "low"},
      dependency: {package: {ecosystem: "npm", name: "tiny"}, manifest_path: "package-lock.json"}}]' >"$FIX/dependabot.json"
  jq -n '[{number: 7, state: "open", secret_type: "github_personal_access_token",
    secret_type_display_name: "GitHub Personal Access Token", html_url: "https://github.com/acme/app/security/secret-scanning/7",
    secret: "SUPERSECRETVALUE"}]' >"$FIX/secret-scanning.json"
  echo '[]' >"$FIX/issues.json"
  rm -f "$FIX/advisories"
}
# What the alerts must have produced: one issue for the high alert, one for the secret, no secret value.
check_alert_issues() { # label
  [ "$(jq 'length' "$FIX/issues.json")" -eq 2 ] || fail "$1: issues filed: $(jq -c 'map(.title)' "$FIX/issues.json")"
  jq -e 'map(select(.title | test("lodash"))) | length == 1 and (.[0].labels | map(.name) | index("security"))' "$FIX/issues.json" >/dev/null ||
    fail "$1: no security issue for the high Dependabot alert: $(jq -c 'map(.title)' "$FIX/issues.json")"
  jq -e 'map(select(.title | test("[Ss]ecret"))) | length == 1' "$FIX/issues.json" >/dev/null ||
    fail "$1: no issue for the exposed secret: $(jq -c 'map(.title)' "$FIX/issues.json")"
  jq -r '.[].body' "$FIX/issues.json" | grep -q "^security-id: [0-9a-f]\{64\}\$" || fail "$1: a body lacks its security-id"
  cat "$FIX/issues.json" "$FIX/advisories" 2>/dev/null | grep -q "SUPERSECRETVALUE" && fail "$1: the secret value was written out"
  jq -r '.[].body' "$FIX/issues.json" | grep -q "Prototype pollution" && fail "$1: advisory detail in an issue body"
  # An alert is not a vulnerability in this project's code: no repository security advisory, even for a
  # critical one in a public repository, and the repository's visibility is not even read.
  [ ! -e "$FIX/advisories" ] || fail "$1: a repository security advisory was opened for an alert"
  grep -qE 'security-advisories|repo view' "$GH_LOG" && fail "$1: the advisory path was taken for an alert: $(grep -E 'security-advisories|repo view' "$GH_LOG")"
}

# N: open alerts become issues when a run starts, before it looks for a Ready ticket (#172). A high
# Dependabot alert and an exposed secret are filed (critical, P0) through issue create, a moderate or
# low alert is not, and a second run files nothing new. The secret's value is never written.
fields='{"Status": {"id": "F_S", "options": {"Ready": "o1", "In progress": "o2", "In review": "o3", "Backlog": "o0", "Done": "o4"}},
  "Priority": {"id": "F_P", "options": {"P0 now": "p0", "P1 next": "p1"}}, "Size": {"id": "F_Z", "options": {"S": "z1"}},
  "Severity": {"id": "F_V", "options": {"critical": "v1", "high": "v2", "moderate": "v3", "low": "v4"}}}'
config '{}'
board
fix_alerts
run || fail "N: run failed: $(cat "$work/out")"
check_alert_issues N
grep -q 'No Ready ticket' "$work/out" || fail "N: the run did not go on to look for tickets: $(cat "$work/out")"
grep -q 'dependabot/alerts?state=open' "$GH_LOG" || fail "N: open Dependabot alerts not read: $(cat "$GH_LOG")"
grep -q 'secret-scanning/alerts?state=open' "$GH_LOG" || fail "N: open secret-scanning alerts not read"
for o in v1 v2 p0 p1; do
  grep -q "option-id $o" "$GH_LOG" || fail "N: option $o not set: high is P1 and critical P0, each with its Severity"
done
grep -q 'GHSA-aaaa-bbbb-cccc' "$work/out" || fail "N: filing not reported: $(cat "$work/out")"
run || fail "N: second run failed: $(cat "$work/out")"
grep -q 'issue create' "$GH_LOG" && fail "N: a second pass files again: $(grep 'issue create' "$GH_LOG")"
[ "$(jq 'length' "$FIX/issues.json")" -eq 2 ] || fail "N: a second pass changed the issues"
# No open alert, nothing filed.
echo '[]' >"$FIX/dependabot.json"; echo '[]' >"$FIX/secret-scanning.json"; echo '[]' >"$FIX/issues.json"
run || fail "N: run with no alerts failed"
grep -q 'issue create' "$GH_LOG" && fail "N: an issue filed without an alert"
# An API error (scanning off, no permission) is said and does not stop the run, nor the other source.
fix_alerts
ALERTS_ERR="gh: Dependabot alerts are disabled for this repository. (HTTP 403)" run || fail "N: an alerts error stopped the run: $(cat "$work/out")"
grep -q 'disabled for this repository' "$work/out" || fail "N: alerts error not said: $(cat "$work/out")"
grep -q 'No Ready ticket' "$work/out" || fail "N: run stopped after an alerts error"
[ "$(jq 'length' "$FIX/issues.json")" -eq 0 ] || fail "N: filed alerts it could not read"
# A failure to file (no Priority option on the board) is said, and the run goes on.
fields='{"Status": {"id": "F_S", "options": {"Ready": "o1", "In progress": "o2", "In review": "o3", "Backlog": "o0", "Done": "o4"}}}'
config '{}'
run || fail "N: a filing error stopped the run: $(cat "$work/out")"
grep -q 'No Ready ticket' "$work/out" || fail "N: run stopped after a filing error"
grep -qi 'not filed' "$work/out" || fail "N: filing error not said: $(cat "$work/out")"

# E: nothing Ready, bad arguments.
config '{}'
board
run || fail "E: run with an empty board failed"
grep -q 'No Ready ticket' "$work/out" || fail "E: empty board not reported: $(cat "$work/out")"
run --max 0 && fail "E: --max 0 accepted"
run --parallel x && fail "E: --parallel x accepted"

[ "$failures" -eq 0 ] && echo "run: all cases pass"
exit "$((failures > 0))"
