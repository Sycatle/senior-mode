#!/usr/bin/env bash
# Tests for `senior-mode run`. Offline: gh, claude and tmux are stubs. gh answers the board query and
# the REST calls from fixtures in $FIX; claude plays a ticket session from $FIX/claude-<n>-<model>
# (line 1: the outcome to write, empty for none; line 2: "pr" to open a pull request).
# shellcheck disable=SC2016 # jq programs and stub bodies, not expanded here
set -u
cli=$(cd "$(dirname "$0")/.." && pwd)/senior-mode
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

mkdir -p "$work/stub" "$work/tmux" "$work/fix"
cat >"$work/stub/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$GH_LOG"
case "$*" in
  "api graphql --input -") cat >/dev/null; cat "$FIX/board.json" ;;
  "project item-add"*) echo "ITEM_$(sed -E 's#.*/issues/([0-9]+).*#\1#' <<<"$*")" ;;
  "project item-edit"*) ;;
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
n=$(sed -nE 's/.*-run-([0-9]+)$/\1/p' <<<"$PWD")
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
chmod +x "$work/stub/"* "$work/tmux/tmux"
export PATH="$work/stub:$PATH" GH_LOG="$work/gh.log" CLAUDE_LOG="$work/claude.log" TMUX_LOG="$work/tmux.log" \
  FIX="$work/fix" SENIOR_MODE_RETRY_DELAY=0 SENIOR_MODE_POLL=0.1

# A local origin whose path ends like a GitHub URL, so the slug reads acme/app.
git init -q --bare -b main "$work/github.com/acme/app.git"
repo="$work/app"
git init -q -b main "$repo"
git -C "$repo" remote add origin "$work/github.com/acme/app.git"
mkdir -p "$repo/.claude"
fields='{"Status": {"id": "F_S", "options": {"Ready": "o1", "In progress": "o2", "In review": "o3", "Backlog": "o0"}}}'
config() {
  jq -n --argjson f "$fields" --argjson a "$1" '{project: {id: "PVT_1", owner: "acme", number: 3, fields: $f}, autonomy: $a}
    + $ARGS.named' ${2:+--argjson github "$2"} >"$repo/.claude/senior-mode.json"
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
      content: {number: $n, title: "Ticket \($n) é", url: "u", state: "OPEN", closedAt: null,
        labels: {nodes: ($l | map({name: .}))}, milestone: null, blockedBy: {nodes: []}}}]' <<<"$items")
    shift 2
  done
  jq -nc --argjson i "$items" '{data: {node: {items: {pageInfo: {hasNextPage: false}, nodes: $i}}}}' >"$FIX/board.json"
}
session() { printf '%s\n%s\n' "$2" "${3:-}" >"$FIX/claude-$1"; }
green='{"statuses": [{"context": "senior-mode/ci", "state": "success"}, {"context": "senior-mode/review", "state": "success"}]}'
run() { : >"$GH_LOG"; : >"$CLAUDE_LOG"; (cd "$repo" && "$cli" run "$@") >"$work/out" 2>&1; }

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
[ "$(git -C "$work/app-run-10" branch --show-current 2>/dev/null)" = fix/10-ticket-10-e ] ||
  fail "A: no worktree on fix/10-ticket-10-e: $(git -C "$repo" worktree list)"
git -C "$work/app-run-11" branch --show-current 2>/dev/null | grep -qx feat/11-ticket-11-e || fail "A: no feat branch for #11"
grep -q 'app-run-10 sonnet run=1 -p --model sonnet --permission-mode bypassPermissions --output-format json' "$CLAUDE_LOG" ||
  fail "A: claude not called as expected: $(cat "$CLAUDE_LOG")"
grep -q '^app-run-10 opus' "$CLAUDE_LOG" && fail "A: a delivered ticket was retried on Opus"
grep -q '^app-run-11 opus' "$CLAUDE_LOG" || fail "A: a failed ticket was not retried on Opus"
grep -q '^app-run-12 opus' "$CLAUDE_LOG" || fail "A: #12 not retried on Opus"
grep -q 'app-run-13' "$CLAUDE_LOG" && fail "A: more than maxTickets tickets started"
grep -qx 'pr merge 110 --rebase -R acme/app' "$GH_LOG" || fail "A: green #10 not merged: $(grep merge "$GH_LOG")"
grep -q 'pr merge 111' "$GH_LOG" && fail "A: #11 merged without a green review"
grep -q 'PUT' "$GH_LOG" && fail "A: the REST merge endpoint was used"
grep -q 'issues/12/comments' "$GH_LOG" || fail "A: no comment on the failed ticket"
grep -q 'issues/1[01]/comments' "$GH_LOG" && fail "A: a comment on a delivered ticket"
grep -c 'item-edit.*--single-select-option-id o2' "$GH_LOG" | grep -qx 3 || fail "A: tickets not set In progress"
grep -c 'item-edit.*--single-select-option-id o0' "$GH_LOG" | grep -qx 1 || fail "A: the failed ticket not set back to Backlog"
grep -c 'new-session\|new-window' "$TMUX_LOG" | grep -qx 5 || fail "A: not one tmux window per session: $(cat "$TMUX_LOG")"
grep -q 'docs' "$CLAUDE_LOG" || fail "A: no docs session after a merge"
grep -q 'Merged.*#10' "$work/out" || fail "A: report misses the merge: $(cat "$work/out")"
grep -q 'Waiting for a human.*#11.*senior-mode/review' "$work/out" || fail "A: report misses #11 waiting: $(cat "$work/out")"
grep -q 'Failed.*#12.*still cannot build' "$work/out" || fail "A: report misses why #12 failed: $(cat "$work/out")"
git -C "$repo" status --porcelain | grep -q . && fail "A: run left the checkout dirty: $(git -C "$repo" status --porcelain)"

# B: no tmux, merging off (default), no escalation, circuit breaker at one failure. #20 says
# delivered but opened no pull request: a failure. #21 is never started.
export PATH=${PATH#"$work/tmux:"}
config '{"maxConsecutiveFailures": 1, "escalate": false}'
board 20 '[]' 21 '[]'
session 20-sonnet delivered
session 21-sonnet delivered pr
run || fail "B: run failed: $(cat "$work/out")"
grep -q 'app-run-21' "$CLAUDE_LOG" && fail "B: circuit breaker did not stop the run"
grep -q 'opus' "$CLAUDE_LOG" && fail "B: escalated although autonomy.escalate is false"
grep -q 'Failed.*#20.*no open pull request' "$work/out" || fail "B: report misses #20: $(cat "$work/out")"
grep -q 'Not started.*#21' "$work/out" || fail "B: report misses #21 not started: $(cat "$work/out")"

# C: an outgrown ticket stops the run and is not retried on Opus.
config '{}'
board 30 '[]' 31 '[]'
session 30-sonnet "outgrown: needs a data migration"
run || fail "C: run failed: $(cat "$work/out")"
grep -q 'app-run-30 opus' "$CLAUDE_LOG" && fail "C: an outgrown ticket was retried"
grep -q 'app-run-31' "$CLAUDE_LOG" && fail "C: run went on after an outgrown ticket"
grep -q 'issues/30/comments' "$GH_LOG" || fail "C: no comment on the outgrown ticket"
grep -q 'needs a data migration' "$work/out" || fail "C: report misses the reason: $(cat "$work/out")"

# D: merging on but no protection on the server, and a needs-human label: nothing merges. --max 1.
config '{"merge": true}' '{"protection": "none"}'
board 40 '[]' 41 '[]'
session 40-sonnet delivered pr
echo "$green" >"$FIX/status-40"
run --max 1 || fail "D: run failed: $(cat "$work/out")"
grep -q 'pr merge' "$GH_LOG" && fail "D: merged without server-side protection"
grep -q 'app-run-41' "$CLAUDE_LOG" && fail "D: --max 1 started two tickets"
grep -q 'Waiting for a human.*#40.*protection' "$work/out" || fail "D: report misses why #40 waits: $(cat "$work/out")"
config '{"merge": true}' '{"protection": "ruleset"}'
board 42 '[]'
session 42-sonnet delivered pr
echo '[{"name": "needs-human"}]' >"$FIX/labels-42"
echo "$green" >"$FIX/status-42"
run || fail "D: run failed: $(cat "$work/out")"
grep -q 'pr merge' "$GH_LOG" && fail "D: merged a needs-human pull request"
grep -q 'Waiting for a human.*#42.*needs-human' "$work/out" || fail "D: report misses the label: $(cat "$work/out")"

# E: nothing Ready, bad arguments.
board
run || fail "E: run with an empty board failed"
grep -q 'No Ready ticket' "$work/out" || fail "E: empty board not reported: $(cat "$work/out")"
run --max 0 && fail "E: --max 0 accepted"
run --parallel x && fail "E: --parallel x accepted"

[ "$failures" -eq 0 ] && echo "run: all cases pass"
exit "$((failures > 0))"
