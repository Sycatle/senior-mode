#!/usr/bin/env bash
# Tests for `senior-mode run`. Offline: gh, claude and tmux are stubs. gh answers the board query and
# the REST calls from fixtures in $FIX; claude plays a ticket session from $FIX/claude-<n>-<model>
# (line 1: the outcome to write, empty for none; line 2: "pr" to open a pull request).
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
case "$*" in
  "api graphql --input -") cat >/dev/null; cat "$FIX/board.json" ;;
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
  "pr merge"*) ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac
STUB
cat >"$work/stub/claude" <<'STUB'
#!/usr/bin/env bash
args=("$@")
for ((i = 0; i < $#; i++)); do [ "${args[i]}" != --model ] || model=${args[i + 1]}; done
echo "$(basename "$PWD") $model run=${SENIOR_MODE_RUN:-} ${*:1:$# - 1}" >>"$CLAUDE_LOG"
n=$(sed -nE 's#.*/app-([0-9]+)$#\1#p' <<<"$PWD")
[ -n "$n" ] || exit 0
fx=$FIX/claude-$n-$model
[ -f "$fx" ] || exit 1
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
    bash -c "${*: -1}" >/dev/null 2>&1 &
    ;;
esac
STUB
sed 's/CLAUDE_LOG/SYACODE_LOG/' "$work/stub/claude" >"$work/stub/syacode"
chmod +x "$work/stub/"* "$work/tmux/tmux"
export PATH="$work/stub:$PATH" GH_LOG="$work/gh.log" CLAUDE_LOG="$work/claude.log" SYACODE_LOG="$work/syacode.log" TMUX_LOG="$work/tmux.log" \
  FIX="$work/fix" SENIOR_MODE_RETRY_DELAY=0 SENIOR_MODE_POLL=0.1

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
session() { printf '%s\n%s\n' "$2" "${3:-}" >"$FIX/claude-$1"; }
green='{"statuses": [{"context": "senior-mode/ci", "state": "success"}, {"context": "senior-mode/review", "state": "success"}]}'
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
echo '{"statuses": [{"context": "senior-mode/ci", "state": "success"}, {"context": "senior-mode/review", "state": "pending"}]}' >"$FIX/status-11"
session 12-sonnet "failed: cannot build"
session 12-opus "failed: still cannot build"
run || fail "A: run failed: $(cat "$work/out")"
[ "$(git -C "$work/app-10" branch --show-current 2>/dev/null)" = fix/10-ticket-10 ] ||
  fail "A: no worktree on fix/10-ticket-10: $(git -C "$repo" worktree list)"
git -C "$work/app-11" branch --show-current 2>/dev/null | grep -qx feat/11-ticket-11 || fail "A: no feat branch for #11"
grep -q 'issue view 10 ' "$GH_LOG" || fail "A: the worktree was not opened by senior-mode start: $(cat "$GH_LOG")"
grep -q 'app-10 sonnet run=1 -p --model sonnet --permission-mode bypassPermissions --output-format json' "$CLAUDE_LOG" ||
  fail "A: claude not called as expected: $(cat "$CLAUDE_LOG")"
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

# E: nothing Ready, bad arguments.
config '{}'
board
run || fail "E: run with an empty board failed"
grep -q 'No Ready ticket' "$work/out" || fail "E: empty board not reported: $(cat "$work/out")"
run --max 0 && fail "E: --max 0 accepted"
run --parallel x && fail "E: --parallel x accepted"

[ "$failures" -eq 0 ] && echo "run: all cases pass"
exit "$((failures > 0))"
