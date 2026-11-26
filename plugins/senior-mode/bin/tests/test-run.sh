#!/usr/bin/env bash
# Tests for `senior-mode run`. Offline: gh, claude and tmux are stubs. gh answers the board query and
# the REST calls from fixtures in $FIX; claude plays a ticket session from $FIX/claude-<n>-<model>
# (line 1: the outcome to write, empty for none; line 2: "pr" to open a pull request; line 3: "hang" to
# never end, with a child process, recorded in $FIX/pids-<n>, to check that a killed session leaves none;
# "slow": the session lasts 3 seconds, long enough for the others to start in a loaded machine; $FIX/trace gets "start <n>" and "end <n>" around every session;
# $FIX/outcome-<n>: the lines of a batch session's outcome file (#263);
# "die": the session script is killed, so no exit file is ever written;
# "decoy": the same, but the session's recorded process group is swapped for another group, whose leader is
# not the session's script, to check that run kills nothing it does not recognise).
# A claude session whose prompt says "guard probe" is the daily probe of #117: $FIX/probe says whether the
# stub honours the deny (default: prints the deny, runs nothing), ignores it (runs the denied command) or
# is silent (no deny to see), hangs ("hang") or hangs with a child process, recorded in $FIX/pids-probe,
# to check that a stopped probe leaves none ("hangkids"). CLAUDE_CONFIG_DIR holds the user settings that enable the plugin.
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
# alive <pid>: is the process still running after it was killed? A killed process is a zombie until its parent
# reaps it, and a loaded machine can take seconds: polls up to 10 s for it to be gone (a zombie is gone) (#253).
alive() {
  local st
  for _ in $(seq 100); do
    st=$(ps -o stat= -p "$1" 2>/dev/null) || st=""
    st=${st# }
    [ -n "$st" ] && [ "${st:0:1}" != Z ] || return 1
    sleep 0.1
  done
  return 0
}

mkdir -p "$work/stub" "$work/tmux" "$work/fix"
cat >"$work/stub/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$GH_LOG"
jqf="" prev=""
for a in "$@"; do [ "$prev" = --jq ] && jqf=$a; prev=$a; done
respond() { if [ -n "$jqf" ]; then jq -r "$jqf"; else cat; fi; }
arg() { local prev=""; for a in "$@"; do [ "$prev" = "$FLAG" ] && echo "$a"; prev=$a; done; }
case "$*" in
  "api graphql --input -")
    q=$(cat)
    if [[ $q == *archiveProjectV2Item* ]]; then
      [ -z "${ARCHIVE_FAIL:-}" ] || { echo "HTTP 403: forbidden" >&2; exit 1; }
      echo "$q" >>"$FIX/archived"
      echo '{"data": {"archiveProjectV2Item": {"item": {"id": "x"}}}}'
    elif [[ $q == *ProjectV2IterationField* ]]; then
      cat "$FIX/iteration.json"
    elif [[ $q == *projectItems* ]]; then
      n=$(jq -r '.variables.number' <<<"$q")
      s=$(cat "$FIX/itemstatus-$n" 2>/dev/null || echo "In progress")
      jq -nc --arg s "$s" '{data: {repository: {issue: {projectItems: {nodes: [{project: {id: "PVT_1"},
        fieldValues: {nodes: [{name: $s, field: {name: "Status"}}]}}]}}}}}'
    else cat "$FIX/board.json"; fi ;;
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
      | {title, state, labels: .labels.nodes} + {body: $b}' --arg b "$(cat "$FIX/body-$n" 2>/dev/null)" "$FIX/board.json" ;;
  "project item-add"*) echo "ITEM_$(sed -E 's#.*/issues/([0-9]+).*#\1#' <<<"$*")" ;;
  "project item-edit"*)
    [ -z "${EDIT_FAIL:-}" ] || [[ "$*" != $EDIT_FAIL ]] || { echo "edit refused" >&2; exit 1; } ;;
  "api repos/acme/app/pulls/"*"/files"*)
    pr=$(sed -E 's#.*/pulls/([0-9]+)/files.*#\1#' <<<"$*")
    cat "$FIX/files-$pr" 2>/dev/null || echo src/app.ts ;;
  "api repos/acme/app/pulls?head="*)
    n=$(sed -E 's#.*head=acme:[a-z]+/([0-9]+)-.*#\1#' <<<"$*")
    cat "$FIX/pulls-$n" 2>/dev/null || echo '[]' ;;
  "api repos/acme/app/commits/sha"*"/status")
    n=$(sed -E 's#.*/sha([0-9]+)/status#\1#' <<<"$*")
    cat "$FIX/status-$n" 2>/dev/null || echo '{"statuses": []}' ;;
  "api repos/acme/app/compare/"*)
    n=$(sed -E 's#.*\.\.\.sha([0-9]+).*#\1#' <<<"$*")
    echo "{\"behind_by\": $(cat "$FIX/behind-$n" 2>/dev/null || echo 0)}" | respond ;;
  "api repos/acme/app/issues?labels=needs-decision"*) respond <"$FIX/decisions.json" 2>/dev/null || echo '[]' | respond ;;
  "api repos/acme/app/issues/"*"/comments"*)
    n=$(sed -E 's#.*/issues/([0-9]+)/comments.*#\1#' <<<"$*")
    if [[ " $* " != *" -f "* ]] && [ -f "$FIX/comments-$n" ]; then respond <"$FIX/comments-$n"; else echo '{}'; fi ;;
  "api -X DELETE repos/acme/app/issues/"*"/labels/"*) ;;
  "api repos/acme/app/issues/"*"/labels"*) echo '[]' ;;
  "pr merge"*) ;;
  "pr list"*) echo '[]' ;;
  "api repos/acme/app/branches?protected"*) ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac
STUB
cat >"$work/stub/claude" <<'STUB'
#!/usr/bin/env bash
args=("$@")
for ((i = 0; i < $#; i++)); do [ "${args[i]}" != --model ] || model=${args[i + 1]}; done
# A ticket worktree is $XDG_DATA_HOME/senior-mode/worktrees/<repo>-<hash>/<n>; the log names it app-<n>.
tag=$(basename "$PWD")
[[ $PWD == */senior-mode/worktrees/* ]] && tag=app-$tag
echo "$tag $model run=${SENIOR_MODE_RUN:-} ${*:1:$# - 1}" >>"$CLAUDE_LOG"
if [[ ${!#} == *"guard probe"* ]]; then
  case $(cat "$FIX/probe" 2>/dev/null || echo honour) in
    honour) echo '{"type": "user", "message": {"content": "senior-mode: skipping checks is denied (core.hooksPath); fix what the check reports instead."}}' ;;
    ignore) git init -q "$(sed -nE 's#.*init -q ([^ `]+).*#\1#p' <<<"${!#}")"; echo '{"type": "result"}' ;;
    silent) echo '{"type": "result"}' ;;
    hang) exec sleep 30 ;;
    hangkids)
      sleep 300 &
      echo "$$ $!" >"$FIX/pids-probe"
      wait
      ;;
  esac
  exit 0
fi
[[ $PWD == */senior-mode/worktrees/*/run-docs-* ]] && echo "$PWD" >>"$FIX/docs-pwd"
if [[ $PWD == */senior-mode/worktrees/*/run-docs-* ]]; then
  case $(cat "$FIX/docs" 2>/dev/null) in
    fail) echo "docs: the session broke" >&2; exit 3 ;;
    die) kill -9 "$PPID"; exit 0 ;;
  esac
fi
if [[ $PWD == */senior-mode/worktrees/*/run-docs-* ]] && [ "$(cat "$FIX/docs" 2>/dev/null)" = hang ]; then
  date +%s >"$FIX/docs-start"
  sleep 300 &
  echo "$$ $!" >"$FIX/pids-docs"
  wait
fi
n=$(sed -nE 's#.*/senior-mode/worktrees/[^/]+/([0-9]+)$#\1#p' <<<"$PWD")
# #299: the token use the session prints, which its script appends to the ledger.
usage='{"result": "ok", "modelUsage": {"claude-'$model'": {"inputTokens": 3, "outputTokens": 5, "cacheReadInputTokens": 11, "cacheCreationInputTokens": 7, "cacheCreationEphemeral1hInputTokens": 2}}}'
[ -n "$n" ] || { echo "$usage"; exit 0; }
echo "$n ${SENIOR_MODE_SLOT:-none} ${PORT:-none}" >>"$FIX/slot-seen"
fx=$FIX/claude-$n-$model
[ -f "$fx" ] || exit 1
# A hanging session records its processes first: under load, the steps below can outlast a one-second
# timeout and the session would be killed before the test can read what to check.
# A spike's note, left in its worktree before the session hangs (#321).
[ ! -f "$FIX/note-$n" ] || { mkdir -p docs/spikes && cp "$FIX/note-$n" docs/spikes/note.md; }
if [ "$(sed -n 3p "$fx")" = hang ]; then
  sleep 300 &
  echo "$$ $!" >"$FIX/pids-$n"
  wait
fi
[ "$(sed -n 3p "$fx")" != die ] || { kill -9 "$PPID"; exit 0; }
if [ "$(sed -n 3p "$fx")" = decoy ]; then
  setsid sleep 301 &
  decoy=$!
  echo "$decoy" >"${SENIOR_MODE_RUN_OUTCOME%.outcome}.pgid"
  sleep 300 &
  echo "$$ $! $decoy" >"$FIX/pids-$n"
  wait
fi
echo "start $n" >>"$FIX/trace"
# #145: the token file of the run, as the session sees it: its mode, never its content.
for t in "$(git rev-parse --path-format=absolute --git-common-dir)"/senior-mode/runs/*/token; do
  [ ! -f "$t" ] || echo "$n $(stat -c %a "$t" 2>/dev/null || stat -f %Lp "$t")" >>"$FIX/token-seen"
done
outcome=$(sed -n 1p "$fx")
[ -z "$outcome" ] || echo "$outcome" >"$SENIOR_MODE_RUN_OUTCOME"
# #352: the plan file of the session ($SENIOR_MODE_RUN_PLAN): $FIX/plan-<n> holds it ("none": no file), else an approved plan.
if [ ! -f "$FIX/plan-$n" ]; then printf 'plan 1:\nx\narchitect 1: approve\n' >"$SENIOR_MODE_RUN_PLAN"
elif [ "$(cat "$FIX/plan-$n")" != none ]; then cp "$FIX/plan-$n" "$SENIOR_MODE_RUN_PLAN"; fi
# A batch session (#263) writes one outcome line per ticket: $FIX/outcome-<lead> holds them.
[ ! -f "$FIX/outcome-$n" ] || cp "$FIX/outcome-$n" "$SENIOR_MODE_RUN_OUTCOME"
[ "$(sed -n 2p "$fx")" != pr ] ||
  echo "[{\"number\": $((n + 100)), \"author_association\": \"OWNER\", \"head\": {\"sha\": \"sha$n\"}, \"labels\": $(cat "$FIX/labels-$n" 2>/dev/null || echo '[]')}]" >"$FIX/pulls-$n"
# $FIX/external-<n>: a jq filter that makes the pull request of the ticket external (#427).
[ ! -f "$FIX/external-$n" ] || { jq -c "$(cat "$FIX/external-$n")" "$FIX/pulls-$n" >"$FIX/pulls-$n.x" && mv "$FIX/pulls-$n.x" "$FIX/pulls-$n"; }
[ "$(sed -n 3p "$fx")" != slow ] || sleep 3
echo "end $n" >>"$FIX/trace"
echo "$usage"
STUB
cat >"$work/tmux/tmux" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$TMUX_LOG"
case $1 in
  has-session) [ -f "$FIX/tmux-session" ] ;;
  new-session | new-window)
    # $FIX/tmux-fail holds how many windows start before tmux fails to start one (none when it is 0).
    if [ -f "$FIX/tmux-fail" ] && [ "$(grep -c 'new-' "$TMUX_LOG")" -gt "$(cat "$FIX/tmux-fail")" ]; then
      echo "tmux: server exited unexpectedly" >&2
      exit 1
    fi
    touch "$FIX/tmux-session"
    setsid bash -c "${*: -1}" >/dev/null 2>&1 &
    ;;
esac
STUB
sed 's/CLAUDE_LOG/SYACODE_LOG/' "$work/stub/claude" >"$work/stub/syacode"
chmod +x "$work/stub/"* "$work/tmux/tmux"
export PATH="$work/stub:$PATH" GH_LOG="$work/gh.log" CLAUDE_LOG="$work/claude.log" SYACODE_LOG="$work/syacode.log" TMUX_LOG="$work/tmux.log" \
  FIX="$work/fix" SENIOR_MODE_RETRY_DELAY=0 XDG_DATA_HOME="$work/xdg" SENIOR_MODE_POLL=0.1 CLAUDE_CONFIG_DIR="$work/claude-home" \
  SENIOR_MODE_PROBE_RETRY=0 SENIOR_MODE_MANAGED_SETTINGS="$work/managed-settings.json" SENIOR_MODE_MANAGED_MCP="$work/managed-mcp.json"
mkdir -p "$CLAUDE_CONFIG_DIR"
echo '{"enabledPlugins": {"senior-mode@senior-mode": true}}' >"$CLAUDE_CONFIG_DIR/settings.json"

# A local origin whose path ends like a GitHub URL, so the slug reads acme/app.
git init -q --bare -b main "$work/github.com/acme/app.git"
repo="$work/app"
wt=$XDG_DATA_HOME/senior-mode/worktrees/app-$(printf '%08x' "$(printf '%s' "$repo" | cksum | cut -d' ' -f1)")
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
      content: {authorAssociation: "OWNER", number: $n, title: "Ticket \($n)", url: "u", state: "OPEN", closedAt: null,
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
# run_dir: the run directory of the last `run`, as it said it ("sessions and logs in <dir>").
run_dir() { sed -nE 's/^run: .*logs in (.*)$/\1/p' "$work/out" | head -n 1; }

# A: three tickets two at a time in tmux; merging on. #10 merges; #11 succeeds on Opus but its review
# is not green; #12 fails on Sonnet and on Opus.
export PATH="$work/tmux:$PATH"
config '{"maxTickets": 3, "parallel": 2, "merge": true}' '{"protection": "ruleset"}'
jq '.slot = "echo PORT=$((4000 + SENIOR_MODE_SLOT))"' "$repo/.claude/senior-mode.json" >"$work/c" && mv "$work/c" "$repo/.claude/senior-mode.json"
git -C "$repo" -c user.name=t -c user.email=t@t commit -qam "chore: slot command" && git -C "$repo" push -q origin main
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
[ "$(git -C "$wt/10" branch --show-current 2>/dev/null)" = fix/10-ticket-10 ] ||
  fail "A: no worktree on fix/10-ticket-10: $(git -C "$repo" worktree list)"
git -C "$wt/11" branch --show-current 2>/dev/null | grep -qx feat/11-ticket-11 || fail "A: no feat branch for #11"
compgen -G "$work/app-[0-9]*" >/dev/null && fail "A: a ticket worktree beside the repository: $(ls "$work")"
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
grep -q "^$wt/run-docs-" "$FIX/docs-pwd" 2>/dev/null || fail "A: the docs session did not run under the data dir: $(cat "$FIX/docs-pwd" 2>&1)"
compgen -G "$work/app-*" >/dev/null && fail "A: a worktree beside the repository: $(ls "$work")"
grep -q 'Merged.*#10' "$work/out" || fail "A: report misses the merge: $(cat "$work/out")"
grep -q 'Waiting for a human.*#11.*senior-mode/review' "$work/out" || fail "A: report misses #11 waiting: $(cat "$work/out")"
grep -q 'Failed.*#12.*still cannot build' "$work/out" || fail "A: report misses why #12 failed: $(cat "$work/out")"
outcome_is 10
outcome_is 11
outcome_is 12
# #299: every session, the docs one included, left its tokens in the ledger.
[ "$(jq -sc '[.[] | [.ticket, .role, .model]] | sort' "$repo/.git/senior-mode/usage.jsonl" 2>&1)" = \
  '[[null,"docs","claude-sonnet"],[10,"ticket","claude-sonnet"],[11,"ticket","claude-opus"],[11,"ticket","claude-sonnet"],[12,"ticket","claude-opus"],[12,"ticket","claude-sonnet"]]' ] ||
  fail "A: the token ledger: $(cat "$repo/.git/senior-mode/usage.jsonl" 2>&1)"
jq -e 'select(.ticket == 10) | [.input, .output, .cacheRead, .cacheWrite5m, .cacheWrite1h] == [3, 5, 11, 5, 2] and (.at | test("^20[0-9-]+T"))' \
  "$repo/.git/senior-mode/usage.jsonl" >/dev/null || fail "A: the tokens of #10: $(cat "$repo/.git/senior-mode/usage.jsonl")"
# #153: every session sees a slot of 1..2 and the port its slot command derives.
awk '$2 !~ /^[12]$/ || $3 != 4000 + $2 {bad = 1} END {exit bad}' "$FIX/slot-seen" || fail "A: a session without its slot and port: $(cat "$FIX/slot-seen")"
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
# #225: `clean` runs when a run starts, before any ticket is opened, and when it ends, after the last one.
[ "$(grep -c '^pr list' "$GH_LOG")" -eq 2 ] || fail "C: clean not called at the start and the end: $(cat "$GH_LOG")"
[ "$(grep -n '^pr list' "$GH_LOG" | head -1 | cut -d: -f1)" -lt "$(grep -n '^issue view 30 ' "$GH_LOG" | head -1 | cut -d: -f1)" ] ||
  fail "C: clean did not run before the first ticket: $(cat "$GH_LOG")"
[ "$(grep -n '^pr list' "$GH_LOG" | tail -1 | cut -d: -f1)" -gt "$(grep -n 'issues/30/comments' "$GH_LOG" | tail -1 | cut -d: -f1)" ] ||
  fail "C: clean did not run after the last ticket: $(cat "$GH_LOG")"
outcome_is 30

# C2 (#582): a blocked or duplicate ticket is neither outgrown nor failed, and is not retried on Opus: `blocked` labels the
# ticket and names the blocker, `duplicate` asks a human to close it; neither stops the run or counts for the breaker.
config '{"maxConsecutiveFailures": 1}'
board 35 '[]' 36 '[]' 37 '[]'
session 35-sonnet "blocked: #23 the code it changes is in an unmerged pull request"
session 36-sonnet "duplicate: #32 already merged"
session 37-sonnet delivered pr
run || fail "C2: run failed: $(cat "$work/out")"
grep -q 'app-3[56] opus' "$CLAUDE_LOG" && fail "C2: a blocked or duplicate ticket was retried on Opus"
grep -q 'app-37' "$CLAUDE_LOG" || fail "C2: the run stopped after a blocked or duplicate ticket"
grep -q 'issues/35/labels -f labels\[\]=blocked' "$GH_LOG" || fail "C2: #35 not labelled blocked"
grep -q 'issues/35/comments.*blocked by #23' "$GH_LOG" || fail "C2: the comment on #35 does not name its blocker"
grep -q 'issues/35/labels -f labels\[\]=needs-human' "$GH_LOG" && fail "C2: a blocked ticket was labelled needs-human"
grep -q 'issues/36/labels -f labels\[\]=needs-human' "$GH_LOG" || fail "C2: the duplicate #36 does not ask a human to close it"
grep -q 'issues/36/comments.*duplicate of #32' "$GH_LOG" || fail "C2: the comment on #36 does not name the original"
grep -q 'issues/36/labels -f labels\[\]=blocked' "$GH_LOG" && fail "C2: a duplicate ticket was labelled blocked"
grep -q 'outgrew' "$GH_LOG" "$work/out" && fail "C2: reported as outgrown"
grep -q 'Failed: #3[56]' "$work/out" && fail "C2: reported as failed: $(cat "$work/out")"
grep -q 'Waiting for a human: #35.*blocked by #23' "$work/out" || fail "C2: report misses #35 blocked: $(cat "$work/out")"
grep -q 'Waiting for a human: #36.*duplicate of #32' "$work/out" || fail "C2: report misses #36 duplicate: $(cat "$work/out")"
jq -e '.outcome == "blocked" and .escalated == false and (.reason | startswith("#23"))' "$repo/.git/senior-mode/runs/"*/35.json >/dev/null ||
  fail "C2: #35 not recorded as blocked: $(cat "$repo"/.git/senior-mode/runs/*/35.json)"
jq -e '.outcome == "duplicate" and .escalated == false and (.reason | startswith("#32"))' "$repo/.git/senior-mode/runs/"*/36.json >/dev/null ||
  fail "C2: #36 not recorded as duplicate: $(cat "$repo"/.git/senior-mode/runs/*/36.json)"

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

# K2 (#296): github.requiredChecks false (ADR 0016): the ruleset requires no status, so none is waited for;
# the other bounds hold (protection, needs-human, protected zones).
config '{"merge": true}' '{"protection": "ruleset", "requiredChecks": false}'
board 49 '[]'
session 49-sonnet delivered pr
run || fail "K2: run failed: $(cat "$work/out")"
grep -q 'pr merge' "$GH_LOG" || fail "K2: not merged although the ruleset requires no status: $(cat "$work/out")"
grep -q 'not green' "$work/out" && fail "K2: a status waited for: $(cat "$work/out")"
config '{"merge": true}' '{"protection": "none", "requiredChecks": false}'
board 49 '[]'
session 49-sonnet delivered pr
run || fail "K2: run failed: $(cat "$work/out")"
grep -q 'pr merge' "$GH_LOG" && fail "K2: merged with no protection on the server"

# K3 (#523, ADR 0032): github.protection local (GitHub Free): senior-mode is the gate. The three statuses are required whatever
# github.requiredChecks says, and the branch must be up to date with the base. Green and up to date merges.
config '{"merge": true}' '{"protection": "local", "requiredChecks": false}'
board 94 '[]'
session 94-sonnet delivered pr
echo "$green" >"$FIX/status-94"
run || fail "K3: run failed: $(cat "$work/out")"
grep -q 'pr merge 194' "$GH_LOG" || fail "K3: green and up to date not merged under local: $(cat "$work/out")"
grep -q 'compare/main...sha94' "$GH_LOG" || fail "K3: the distance to the base was not read: $(cat "$GH_LOG")"
board 95 '[]'
session 95-sonnet delivered pr
echo '{"statuses": [{"context": "senior-mode/ci", "state": "success"}, {"context": "senior-mode/review", "state": "success"}]}' >"$FIX/status-95"
run || fail "K3: run failed: $(cat "$work/out")"
grep -q 'pr merge 195' "$GH_LOG" && fail "K3: merged under local without senior-mode/security"
grep -q 'Waiting for a human.*#95.*senior-mode/security not green' "$work/out" || fail "K3: report misses the status: $(cat "$work/out")"
board 96 '[]'
session 96-sonnet delivered pr
echo "$green" >"$FIX/status-96"
echo 3 >"$FIX/behind-96"
run || fail "K3: run failed: $(cat "$work/out")"
grep -q 'pr merge 196' "$GH_LOG" && fail "K3: merged a branch that is behind its base"
grep -q 'Waiting for a human.*#96.*it is behind main by 3 commits' "$work/out" || fail "K3: report misses the distance: $(cat "$work/out")"
# The ruleset reads no distance (the server holds it), and none merges nothing.
config '{"merge": true}' '{"protection": "ruleset"}'
board 97 '[]'
session 97-sonnet delivered pr
echo "$green" >"$FIX/status-97"
run || fail "K3: run failed: $(cat "$work/out")"
grep -q 'compare/' "$GH_LOG" && fail "K3: the distance was read under ruleset"

# F: a ticket already opened with `senior-mode start` (its worktree and branch exist) is reused as it is.
config '{}'
board 50 '["type:bug"]'
(cd "$repo" && "$cli" start 50) >/dev/null 2>&1 || fail "F: start 50 failed"
session 50-sonnet delivered pr
run || fail "F: run failed: $(cat "$work/out")"
[ "$(git -C "$repo" worktree list | grep -c "\[fix/50-ticket-50\]")" -eq 1 ] || fail "F: not one worktree for #50: $(git -C "$repo" worktree list)"
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
  content: {authorAssociation: "OWNER", number: 70, title: "Ticket 70", url: "u", state: "OPEN", closedAt: null, labels: {nodes: []},
    milestone: null, blockedBy: {nodes: []}}}]' "$FIX/board.json" >"$work/b" && mv "$work/b" "$FIX/board.json"
session 71-sonnet delivered pr
session 72-sonnet delivered pr
rm -f "$FIX/token-seen"
run || fail "I: run failed: $(cat "$work/out")"
[ "$(grep -c '^app-7[12] sonnet' "$CLAUDE_LOG")" -eq 2 ] ||
  fail "I: the wip limit stopped a run ticket: $(cat "$work/out")"
# #145: it did so with a token file of mode 0600 that is gone when the run ends, and the sessions never
# get the path in their environment.
[ "$(sort "$FIX/token-seen" | tr '\n' ' ')" = "71 600 72 600 " ] ||
  fail "I: token file seen by the sessions: $(cat "$FIX/token-seen" 2>/dev/null)"
ls "$repo"/.git/senior-mode/runs/*/token >/dev/null 2>&1 && fail "I: the token file outlived the run"
grep -q 'TOKEN' "$CLAUDE_LOG" && fail "I: a session got the token in its arguments"

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

# Q: a session that outlives autonomy.sessionTimeout (1 minute, scaled to 3 seconds: run counts in whole
# seconds of $SECONDS, so a scale of 1 can fire at once, before the session stub has started) is killed with its
# processes, the ticket gets needs-human and a comment with the log path, stays In progress, is not retried
# on Opus and counts for the breaker (#115). #91 is never started.
config '{"maxConsecutiveFailures": 1, "sessionTimeout": 1}'
board 90 '[]' 91 '[]'
session 90-sonnet "" "" hang
session 91-sonnet delivered pr
SENIOR_MODE_TIMEOUT_UNIT=3 run || fail "Q: run failed: $(cat "$work/out")"
grep -q 'app-90 opus' "$CLAUDE_LOG" && fail "Q: a timed out session was retried on Opus"
grep -q 'app-91' "$CLAUDE_LOG" && fail "Q: the breaker did not count the timeout"
grep -q 'issues/90/labels.*needs-human' "$GH_LOG" || fail "Q: #90 not labelled needs-human: $(cat "$GH_LOG")"
grep -q '90-sonnet.log' "$GH_LOG" || fail "Q: no comment with the log path on #90"
grep -q 'item-edit.*--single-select-option-id o0' "$GH_LOG" && fail "Q: #90 was set back to Backlog"
grep -q 'Failed.*#90.*timed out after 1 minute' "$work/out" || fail "Q: report misses the timeout: $(cat "$work/out")"
jq -e '.outcome == "failed" and .escalated == false and .reason == "timed out after 1 minute"' \
  "$repo/.git/senior-mode/runs/"*"/90.json" >/dev/null || fail "Q: #90 not recorded as timed out"
read -r -a pids <"$FIX/pids-90"
for pid in "${pids[@]}"; do alive "$pid" && fail "Q: process $pid of the session is still alive"; done
for pid in "${pids[@]}"; do kill -9 "$pid" 2>/dev/null; done
config '{"sessionTimeout": 0}'
run && fail "Q: sessionTimeout 0 accepted"
grep -q 'sessionTimeout' "$work/out" || fail "Q: bad sessionTimeout not named: $(cat "$work/out")"
config '{"sessionTimeout": 1441}'
board
run && fail "Q: sessionTimeout above a day accepted"
grep -q 'sessionTimeout' "$work/out" || fail "Q: too long a sessionTimeout not named: $(cat "$work/out")"

# L: the recorded process group is not the session's (its leader is not <n>.sh): nothing is killed, run
# says so, and the ticket is still labelled needs-human and recorded as timed out.
config '{"sessionTimeout": 1}'
board 92 '[]'
session 92-sonnet "" "" decoy
SENIOR_MODE_TIMEOUT_UNIT=3 run || fail "L: run failed: $(cat "$work/out")"
read -r -a pids <"$FIX/pids-92"
kill -0 "${pids[2]}" 2>/dev/null || fail "L: run killed a process group that is not the session's"
for pid in "${pids[@]}"; do kill -9 "$pid" 2>/dev/null; done
grep -q '#92.*not stopped' "$work/out" || fail "L: the unstopped session is not reported: $(cat "$work/out")"
grep -q 'issues/92/labels.*needs-human' "$GH_LOG" || fail "L: #92 not labelled needs-human"
jq -e '.outcome == "failed" and .reason == "timed out after 1 minute"' "$repo/.git/senior-mode/runs/"*"/92.json" >/dev/null ||
  fail "L: #92 not recorded as timed out"

# SP: a spike (#321) that reaches its Timebox is stopped before the session timeout, its note is put in a comment,
# the ticket is labelled needs-human and recorded as delivered; it is not a failure. A spike with no Timebox line
# (or a token budget) is not stopped by the daemon.
config '{"sessionTimeout": 90}'
board 140 '["type:spike"]'
printf 'Timebox: 2m\n' >"$FIX/body-140"
printf '# OAuth\nUse the device flow.\n' >"$FIX/note-140"
session 140-sonnet "" "" hang
SECONDS=0
SENIOR_MODE_TIMEOUT_UNIT=3 run || fail "SP: run failed: $(cat "$work/out")"
[ "$SECONDS" -lt 30 ] || fail "SP: the spike ran past its timebox ($SECONDS s)"
read -r -a pids <"$FIX/pids-140"
for pid in "${pids[@]}"; do alive "$pid" && fail "SP: process $pid of the spike is still alive"; done
for pid in "${pids[@]}"; do kill -9 "$pid" 2>/dev/null; done
grep -q 'issues/140/labels.*needs-human' "$GH_LOG" || fail "SP: #140 not labelled needs-human"
grep -q 'issues/140/comments.*timebox reached (2 minutes)' "$GH_LOG" || fail "SP: no comment on the timebox: $(cat "$GH_LOG")"
grep -q 'Use the device flow' "$GH_LOG" || fail "SP: the note is not in the comment"
jq -e '.outcome == "delivered" and (.reason | test("timebox reached"))' "$repo/.git/senior-mode/runs/"*"/140.json" >/dev/null ||
  fail "SP: #140 not recorded as delivered at its timebox"
grep -q '^Waiting for a human: #140 .*spike stopped' "$work/out" || fail "SP: not reported: $(cat "$work/out")"
grep -q '^Failed: #140' "$work/out" && fail "SP: a stopped spike is reported as failed"
rm -f "$FIX/body-140" "$FIX/note-140"

# R: the docs session after a merge is bounded by the same timeout (#120): killed with its processes, recorded
# in the run log (docs-outcome.json) and reported, and run ends normally. Without a timeout it is recorded done.
config '{"sessionTimeout": 1, "merge": true}' '{"protection": "ruleset"}'
board 110 '[]'
session 110-sonnet delivered pr
echo "$green" >"$FIX/status-110"
echo hang >"$FIX/docs"
SECONDS=0
SENIOR_MODE_TIMEOUT_UNIT=2 run || fail "R: run failed: $(cat "$work/out")"
[ "$SECONDS" -lt 30 ] || fail "R: run hung on the docs session ($SECONDS s)"
grep -qx 'pr merge 210 --rebase --match-head-commit sha110 -R acme/app' "$GH_LOG" || fail "R: #110 not merged: $(cat "$GH_LOG")"
read -r -a pids <"$FIX/pids-docs"
for pid in "${pids[@]}"; do alive "$pid" && fail "R: process $pid of the docs session is still alive"; done
for pid in "${pids[@]}"; do kill -9 "$pid" 2>/dev/null; done
jq -e '.session == "docs" and .outcome == "failed" and .reason == "docs session timed out after 1 minute" and (.finishedAt | length > 0)' \
  "$(run_dir)/docs-outcome.json" >/dev/null || fail "R: the docs timeout is not recorded: $(cat "$(run_dir)/docs-outcome.json")"
grep -q 'docs session timed out after 1 minute' "$work/out" || fail "R: report misses the docs timeout: $(cat "$work/out")"
grep -q 'issues/.*labels' "$GH_LOG" && fail "R: a docs timeout labelled a ticket"
rm -f "$FIX/docs"
board 111 '[]'
session 111-sonnet delivered pr
echo "$green" >"$FIX/status-111"
run || fail "R: run failed: $(cat "$work/out")"
jq -e '.session == "docs" and .outcome == "done" and .reason == null' "$(run_dir)/docs-outcome.json" >/dev/null ||
  fail "R: a docs session that finished is not recorded done"
# A docs session that ends with a non-zero exit code: recorded failed with the code and the log, reported, no ticket labelled.
echo fail >"$FIX/docs"
board 112 '[]'
session 112-sonnet delivered pr
echo "$green" >"$FIX/status-112"
run || fail "R: run failed on a docs session that exited 3: $(cat "$work/out")"
jq -e '.session == "docs" and .outcome == "failed" and (.reason | test("^docs session failed \\(exit code 3, log in .*/docs\\.log\\)$"))' \
  "$(run_dir)/docs-outcome.json" >/dev/null || fail "R: the docs failure is not recorded: $(cat "$(run_dir)/docs-outcome.json")"
grep -q 'docs: docs session failed (exit code 3' "$work/out" || fail "R: report misses the docs failure: $(cat "$work/out")"
grep -q 'issues/.*labels' "$GH_LOG" && fail "R: a docs failure labelled a ticket"
# A docs script that dies without writing its exit file: the real cause is reported at once, not a timeout.
echo die >"$FIX/docs"
board 113 '[]'
session 113-sonnet delivered pr
echo "$green" >"$FIX/status-113"
SECONDS=0
SENIOR_MODE_TIMEOUT_UNIT=30 run || fail "R: run failed on a docs script that died: $(cat "$work/out")"
[ "$SECONDS" -lt 20 ] || fail "R: run waited for the timeout on a docs script that died ($SECONDS s)"
jq -e '.session == "docs" and .outcome == "failed" and (.reason | test("ended without leaving its exit code"))' \
  "$(run_dir)/docs-outcome.json" >/dev/null || fail "R: the dead docs script is not recorded: $(cat "$(run_dir)/docs-outcome.json")"
grep -q 'timed out' "$work/out" && fail "R: a dead docs script is reported as a timeout: $(cat "$work/out")"
# The poll never overshoots the timeout: with a 60 s poll and a 2 s timeout the docs session is killed long before
# the poll comes round (a loaded machine delays it by seconds, never by the poll).
echo hang >"$FIX/docs"
board 114 '[]'
session 114-sonnet delivered pr
echo "$green" >"$FIX/status-114"
SENIOR_MODE_POLL=60 SENIOR_MODE_TIMEOUT_UNIT=2 run || fail "R: run failed: $(cat "$work/out")"
docs_took=$(($(date +%s) - $(cat "$FIX/docs-start")))
[ "$docs_took" -lt 30 ] || fail "R: the docs session outlived its 2 s timeout by the poll interval ($docs_took s)"
read -r -a pids <"$FIX/pids-docs"
for pid in "${pids[@]}"; do kill -9 "$pid" 2>/dev/null; done
rm -f "$FIX/docs"

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

# M2: sessions see the project's settings and the plugin, not the owner's (#348), in a trusted directory (#350).
board 170 '[]'
session 170-sonnet delivered pr
echo '{"projects": {"/elsewhere": {"hasTrustDialogAccepted": true}}, "userID": "u"}' >"$CLAUDE_CONFIG_DIR/.claude.json"
echo '{"mcpServers": {}}' >"$repo/.mcp.json"
git -C "$repo" add .mcp.json && git -C "$repo" -c user.name=t -c user.email=t@t commit -qm "chore: mcp" && git -C "$repo" push -q origin main
run || fail "M2: run failed: $(cat "$work/out")"
line=$(grep '^app-170 ' "$CLAUDE_LOG")
[[ $line == *"--setting-sources project,local --strict-mcp-config --mcp-config "*"/170/.mcp.json --plugin-dir "*/plugins/senior-mode* ]] ||
  fail "M2: the session is not isolated from the user's settings: $line"
wt170=$(sed -nE 's#^app-170 .*--mcp-config ([^ ]+)/\.mcp\.json.*#\1#p' "$CLAUDE_LOG")
jq -e --arg p "$wt170" '.projects[$p].hasTrustDialogAccepted == true and .projects["/elsewhere"].hasTrustDialogAccepted == true and .userID == "u"' \
  "$CLAUDE_CONFIG_DIR/.claude.json" >/dev/null || fail "M2: the worktree is not trusted, or the config lost entries: $(cat "$CLAUDE_CONFIG_DIR/.claude.json")"
config '{"userSettings": true}'
board 171 '[]'
session 171-sonnet delivered pr
run || fail "M2: run failed with userSettings: $(cat "$work/out")"
grep '^app-171 ' "$CLAUDE_LOG" | grep -q -- '--setting-sources' && fail "M2: userSettings true still isolates the session: $(grep '^app-171 ' "$CLAUDE_LOG")"
# #540: a managed MCP config makes claude refuse --strict-mcp-config; the session keeps the rest of its isolation.
config '{"userSettings": false}'
echo '{"mcpServers": {}}' >"$work/managed-mcp.json"
board 172 '[]'
session 172-sonnet delivered pr
run || fail "M2: run failed under a managed MCP config: $(cat "$work/out")"
line=$(grep '^app-172 ' "$CLAUDE_LOG")
[[ $line == *"--setting-sources project,local"* && $line != *--strict-mcp-config* ]] ||
  fail "M2: --strict-mcp-config passed under a managed MCP config: $line"
rm -f "$work/managed-mcp.json"
config '{"userSettings": true}'
git -C "$repo" rm -q .mcp.json && git -C "$repo" -c user.name=t -c user.email=t@t commit -qm "chore: no mcp" && git -C "$repo" push -q origin main
rm -f "$CLAUDE_CONFIG_DIR/.claude.json"

# With autonomy.userSettings, the user settings must enable the plugin.
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
config '{}'
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

# probe-group (#209): a probe stopped on its timeout is stopped with the processes it started (hooks, MCP
# servers): it runs in its own process group, which is killed.
config '{}'
board 104 '[]'
session 104-sonnet delivered pr
probe_failed=$repo/.git/senior-mode/probe-failed
rm -f "$probe" "$probe_failed" "$FIX/pids-probe"
echo hangkids >"$FIX/probe"
SENIOR_MODE_PROBE_TIMEOUT=1 run && fail "probe-group: run started although the probe session never ended"
[ -s "$FIX/pids-probe" ] || fail "probe-group: the probe stub did not start its child"
pids=()
read -r -a pids <"$FIX/pids-probe" || true
for p in "${pids[@]}"; do
  if alive "$p"; then
    fail "probe-group: process $p of the probe survived its timeout"
    kill -KILL "$p" 2>/dev/null
  fi
done

# probe-signal (#209): Ctrl-C or a TERM during the probe leaves neither its worktree, nor its temporary
# directory, nor its processes behind.
rm -f "$probe" "$probe_failed" "$FIX/pids-probe"
mkdir -p "$work/tmp"
(cd "$repo" && TMPDIR="$work/tmp" SENIOR_MODE_PROBE_TIMEOUT=60 exec "$cli" run) >"$work/out" 2>&1 &
rp=$!
for _ in $(seq 100); do
  { git -C "$repo" worktree list | grep -q probe && [ -s "$FIX/pids-probe" ]; } && break
  sleep 0.1
done
kill -TERM "$rp" 2>/dev/null
wait "$rp"
git -C "$repo" worktree list | grep -q probe && fail "probe-signal: the probe worktree was left: $(git -C "$repo" worktree list)"
[ -z "$(ls -A "$work/tmp")" ] || fail "probe-signal: the probe left its temporary directory: $(ls "$work/tmp")"
pids=()
read -r -a pids <"$FIX/pids-probe" || true
for p in "${pids[@]}"; do
  if alive "$p"; then
    fail "probe-signal: process $p of the probe survived the signal"
    kill -KILL "$p" 2>/dev/null
  fi
done
[ -e "$probe" ] && fail "probe-signal: an interrupted probe was recorded as passed"

# probe-backoff (#209): a failed probe is recorded with its time and not retried for an hour
# (SENIOR_MODE_PROBE_RETRY, in seconds), so a cron tick does not start a Haiku session every time; run
# still refuses to start meanwhile, and the probe is retried once the hour is past.
rm -f "$probe" "$probe_failed"
echo silent >"$FIX/probe"
SENIOR_MODE_PROBE_RETRY=3600 run && fail "probe-backoff: run started although no deny showed in the probe session"
[ -s "$probe_failed" ] || fail "probe-backoff: the failure was not recorded"
echo honour >"$FIX/probe"
SENIOR_MODE_PROBE_RETRY=3600 run && fail "probe-backoff: run started although the probe failed less than an hour ago"
grep -q 'haiku' "$CLAUDE_LOG" && fail "probe-backoff: a second probe session within the hour"
grep -q 'guard probe' "$work/out" || fail "probe-backoff: the refusal does not name the probe: $(cat "$work/out")"
grep -q 'probe.log' "$work/out" || fail "probe-backoff: the refusal does not point at the probe log: $(cat "$work/out")"
grep -q 'app-104' "$CLAUDE_LOG" && fail "probe-backoff: a ticket started during the back-off"
printf '%s\nstale\n' "$(($(date +%s) - 4000))" >"$probe_failed"
SENIOR_MODE_PROBE_RETRY=3600 run || fail "probe-backoff: run refused after the hour, with a probe that honours the deny: $(cat "$work/out")"
grep -q 'haiku' "$CLAUDE_LOG" || fail "probe-backoff: no new probe after the hour"
[ -e "$probe_failed" ] && fail "probe-backoff: a pass left the failure record"
[ "$(cat "$probe" 2>/dev/null)" = "$(date +%F)" ] || fail "probe-backoff: probe date not recorded"

# probe-managed (#209): the managed settings (SENIOR_MODE_MANAGED_SETTINGS stands for the platform's
# managed-settings.json) count, and win over the user's, as they do for Claude Code. With autonomy.userSettings
# only: otherwise sessions load the plugin with --plugin-dir.
config '{"userSettings": true}'
rm -f "$probe" "$probe_failed"
echo '{"enabledPlugins": {"senior-mode@senior-mode": true}}' >"$work/managed-settings.json"
echo '{}' >"$CLAUDE_CONFIG_DIR/settings.json"
run || fail "probe-managed: a plugin enabled by the managed settings was refused: $(cat "$work/out")"
echo '{"enabledPlugins": {"senior-mode@senior-mode": false}}' >"$work/managed-settings.json"
echo '{"enabledPlugins": {"senior-mode@senior-mode": true}}' >"$CLAUDE_CONFIG_DIR/settings.json"
run && fail "probe-managed: run started with the plugin disabled by the managed settings"
grep -q 'enabled' "$work/out" || fail "probe-managed: the disabled plugin is not named: $(cat "$work/out")"
rm -f "$work/managed-settings.json"
run || fail "probe-managed: run failed with the user settings alone: $(cat "$work/out")"
config '{}'

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

# O: tmux fails to start the window of a session (#201): the ticket fails at once, not after the session
# timeout: needs-human, a comment, an outcome record, one failure for the breaker. A failed retry window
# on Opus is the same. sessionTimeout is a second here, so a run that waited would report a timeout.
export PATH="$work/tmux:$PATH"
echo '[]' >"$FIX/dependabot.json"; echo '[]' >"$FIX/secret-scanning.json"
config '{"maxConsecutiveFailures": 1, "sessionTimeout": 1}'
board 120 '[]' 121 '[]'
session 120-sonnet delivered pr
session 121-sonnet delivered pr
echo 0 >"$FIX/tmux-fail"
: >"$TMUX_LOG"
SENIOR_MODE_TIMEOUT_UNIT=3 run || fail "O: run failed: $(cat "$work/out")"
grep -q 'app-12[01]' "$CLAUDE_LOG" && fail "O: a session ran although its window did not start: $(cat "$CLAUDE_LOG")"
grep -q 'Failed.*#120.*window did not start.*server exited unexpectedly' "$work/out" || fail "O: report misses why #120 failed: $(cat "$work/out")"
grep -q 'timed out' "$work/out" && fail "O: the report talks of a timeout: $(cat "$work/out")"
grep -q 'session started' "$work/out" && fail "O: a session is reported started: $(cat "$work/out")"
grep -q 'issues/120/labels.*needs-human' "$GH_LOG" || fail "O: #120 not labelled needs-human: $(cat "$GH_LOG")"
grep -q 'issues/120/comments' "$GH_LOG" || fail "O: no comment on #120"
# The comment says tmux's error is in a file, not that a session log exists (no session ever started).
grep -q "could not start this ticket's session: the session window did not start: tmux: server exited unexpectedly" "$GH_LOG" ||
  fail "O: the comment on #120 does not say the window did not start: $(grep -A3 'issues/120/comments' "$GH_LOG")"
grep -q "tmux's error output is \`.*/120.tmux\`" "$GH_LOG" || fail "O: the comment on #120 does not point at tmux's error output"
grep -q 'The session log is `.*/120' "$GH_LOG" && fail "O: the comment on #120 names a session log that does not exist"
grep -q 'item-edit.*--single-select-option-id o0' "$GH_LOG" && fail "O: #120 was set back to Backlog"
grep -q 'Not started.*#121' "$work/out" || fail "O: the breaker did not count the failed window: $(cat "$work/out")"
jq -e '.outcome == "failed" and .escalated == false and (.reason | test("window did not start"))' \
  "$repo/.git/senior-mode/runs/"*"/120.json" >/dev/null || fail "O: #120 not recorded as failed: $(cat "$repo"/.git/senior-mode/runs/*/120.json)"
# The retry window on Opus: the first window starts, the second does not. The first session has 5 seconds to
# fail: on a loaded machine (checks running side by side) one second was too short to even start it (#295).
config '{"maxConsecutiveFailures": 1, "sessionTimeout": 5}'
board 122 '[]'
session 122-sonnet "failed: tests do not pass"
session 122-opus delivered pr
echo 1 >"$FIX/tmux-fail"
: >"$TMUX_LOG"
SENIOR_MODE_TIMEOUT_UNIT=3 run || fail "O: run failed: $(cat "$work/out")"
grep -q '^app-122 sonnet' "$CLAUDE_LOG" || fail "O: the first window did not run: $(cat "$CLAUDE_LOG")"
grep -q '^app-122 opus' "$CLAUDE_LOG" && fail "O: an Opus session ran although its window did not start"
grep -q 'Failed.*#122.*window did not start' "$work/out" || fail "O: report misses the Opus window: $(cat "$work/out")"
grep -q 'issues/122/labels.*needs-human' "$GH_LOG" || fail "O: #122 not labelled needs-human"
jq -e '.outcome == "failed" and .escalated == true and (.reason | test("window did not start"))' \
  "$repo/.git/senior-mode/runs/"*"/122.json" >/dev/null || fail "O: #122 not recorded as failed on Opus: $(cat "$repo"/.git/senior-mode/runs/*/122.json)"
rm -f "$FIX/tmux-fail"
export PATH=${PATH#"$work/tmux:"}

# P: without setsid (macOS), a session that outlives the timeout could not be killed (#201). run starts
# nothing unless it can stop sessions: setsid, else perl's POSIX::setsid, which then does the same job.
mkdir -p "$work/nosetsid" "$work/noperl"
for f in /usr/bin/* /bin/*; do
  [ -x "$f" ] && [ ! -d "$f" ] || continue
  case ${f##*/} in setsid) continue ;; perl*) ln -sf "$f" "$work/nosetsid/${f##*/}" ;; *) ln -sf "$f" "$work/nosetsid/${f##*/}"; ln -sf "$f" "$work/noperl/${f##*/}" ;; esac
done
config '{"sessionTimeout": 1}'
board 130 '[]'
session 130-sonnet "" "" hang
saved=$PATH
PATH="$work/stub:$work/noperl"
run && fail "P: run started with neither setsid nor perl"
grep -q 'setsid' "$work/out" || fail "P: the missing setsid is not named: $(cat "$work/out")"
grep -q 'app-130' "$CLAUDE_LOG" && fail "P: a session started without a way to stop it"
grep -q 'item-edit' "$GH_LOG" && fail "P: a ticket was touched although nothing could start"
PATH="$work/stub:$work/nosetsid"
SENIOR_MODE_TIMEOUT_UNIT=3 run || fail "P: run failed with perl as the fallback: $(cat "$work/out")"
grep -q 'Failed.*#130.*timed out after 1 minute' "$work/out" || fail "P: report misses the timeout: $(cat "$work/out")"
grep -q 'not stopped' "$work/out" && fail "P: a session was not stopped with perl: $(cat "$work/out")"
read -r -a pids <"$FIX/pids-130"
for pid in "${pids[@]}"; do alive "$pid" && fail "P: process $pid of the session is still alive"; done
for pid in "${pids[@]}"; do kill -9 "$pid" 2>/dev/null; done
PATH=$saved

# S: a merge that succeeds but whose Status could not be set Done (#161): the pull request is merged and the
# ticket is still listed as merged, and the report says the Status is not Done, with the ticket. A ticket
# whose Status was set is not in that line.
config '{"merge": true}' '{"protection": "ruleset"}'
board 47 '[]' 48 '[]'
session 47-sonnet delivered pr
session 48-sonnet delivered pr
echo "$green" >"$FIX/status-47"
echo "$green" >"$FIX/status-48"
EDIT_FAIL="*--id ITEM_47 *--single-select-option-id o4" run || fail "S: run failed: $(cat "$work/out")"
unset EDIT_FAIL
grep -q 'pr merge 147' "$GH_LOG" || fail "S: #47 not merged: $(cat "$GH_LOG")"
grep -q 'Merged.*#47' "$work/out" || fail "S: report misses the merge of #47: $(cat "$work/out")"
grep -q 'Status not set to Done.*#47' "$work/out" || fail "S: report misses #47 left off Done: $(cat "$work/out")"
grep -q 'Status not set to Done.*#48' "$work/out" && fail "S: #48 was set Done, but is reported: $(cat "$work/out")"

# U: a delivered ticket whose pull request is left for a human (merging off) is set In review by the run itself
# (#261), and the report says so when it had to; a ticket already In review is not written again. When the
# write fails, the report lists the ticket under "Status not set to In review".
config '{"merge": false}'
board 60 '[]' 61 '[]' 62 '[]'
session 60-sonnet delivered pr
session 61-sonnet delivered pr
session 62-sonnet delivered pr
echo "In review" >"$FIX/itemstatus-61"
EDIT_FAIL="*--id ITEM_62 *--single-select-option-id o3" run || fail "U: run failed: $(cat "$work/out")"
unset EDIT_FAIL
rm -f "$FIX/itemstatus-61"
grep -q 'item-edit.*--id ITEM_60 .*--single-select-option-id o3' "$GH_LOG" || fail "U: #60 not set In review: $(cat "$GH_LOG")"
grep -q 'item-edit.*--id ITEM_61 .*--single-select-option-id o3' "$GH_LOG" && fail "U: #61 was already In review but written again"
grep -q 'Status set to In review.*#60' "$work/out" || fail "U: report misses #60 set In review: $(cat "$work/out")"
grep -q 'Status set to In review.*#61' "$work/out" && fail "U: #61 was already In review, but is reported: $(cat "$work/out")"
grep -q 'Status not set to In review.*#62' "$work/out" || fail "U: report misses #62 left off In review: $(cat "$work/out")"
grep -q 'Waiting for a human.*#60' "$work/out" || fail "U: #60 not waiting for a human: $(cat "$work/out")"

# U: a delivered ticket whose pull request is left for a human (merging off) is set In review by the run itself
# (#261), and the report says so when it had to; a ticket already In review is not written again. When the
# write fails, the report lists the ticket under "Status not set to In review".
config '{"merge": false}'
board 60 '[]' 61 '[]' 62 '[]'
session 60-sonnet delivered pr
session 61-sonnet delivered pr
session 62-sonnet delivered pr
echo "In review" >"$FIX/itemstatus-61"
EDIT_FAIL="*--id ITEM_62 *--single-select-option-id o3" run || fail "U: run failed: $(cat "$work/out")"
unset EDIT_FAIL
rm -f "$FIX/itemstatus-61"
grep -q 'item-edit.*--id ITEM_60 .*--single-select-option-id o3' "$GH_LOG" || fail "U: #60 not set In review: $(cat "$GH_LOG")"
grep -q 'item-edit.*--id ITEM_61 .*--single-select-option-id o3' "$GH_LOG" && fail "U: #61 was already In review but written again"
grep -q 'Status set to In review.*#60' "$work/out" || fail "U: report misses #60 set In review: $(cat "$work/out")"
grep -q 'Status set to In review.*#61' "$work/out" && fail "U: #61 was already In review, but is reported: $(cat "$work/out")"
grep -q 'Status not set to In review.*#62' "$work/out" || fail "U: report misses #62 left off In review: $(cat "$work/out")"
grep -q 'Waiting for a human.*#60' "$work/out" || fail "U: #60 not waiting for a human: $(cat "$work/out")"

# T: a ticket session script that dies without leaving its exit file (#242) is noticed at once, not after the
# timeout: needs-human, a comment with the log, a failed record, one failure for the breaker, not retried on
# Opus, and not reported as a timeout. #151 is never started.
# Time unit: SENIOR_MODE_TIMEOUT_UNIT is the length of a "minute" in seconds; no wall-clock budget is asserted.
config '{"maxConsecutiveFailures": 1, "sessionTimeout": 1}'
board 150 '[]' 151 '[]'
session 150-sonnet "" "" die
session 151-sonnet delivered pr
SENIOR_MODE_TIMEOUT_UNIT=30 run || fail "T: run failed on a session script that died: $(cat "$work/out")"
grep -q 'app-150 opus' "$CLAUDE_LOG" && fail "T: a dead session was retried on Opus"
grep -q 'app-151' "$CLAUDE_LOG" && fail "T: the breaker did not count the dead session"
grep -q 'issues/150/labels.*needs-human' "$GH_LOG" || fail "T: #150 not labelled needs-human: $(cat "$GH_LOG")"
grep -q '150-sonnet.log' "$GH_LOG" || fail "T: no comment with the log path on #150"
grep -q 'item-edit.*--single-select-option-id o0' "$GH_LOG" && fail "T: #150 was set back to Backlog"
grep -q 'Failed.*#150.*ended without leaving its exit code' "$work/out" || fail "T: report misses the dead session: $(cat "$work/out")"
grep -q 'timed out' "$work/out" && fail "T: a dead session is reported as a timeout: $(cat "$work/out")"
jq -e '.outcome == "failed" and .escalated == false and (.reason | test("ended without leaving its exit code"))' \
  "$repo/.git/senior-mode/runs/"*"/150.json" >/dev/null || fail "T: #150 not recorded as a dead session"
# The poll never sleeps past the timeout: with a 60 s poll and a 2 s timeout the session is stopped long before
# the poll comes round.
config '{"sessionTimeout": 1}'
board 152 '[]'
session 152-sonnet "" "" hang
SENIOR_MODE_POLL=60 SENIOR_MODE_TIMEOUT_UNIT=2 run || fail "T: run failed: $(cat "$work/out")"
grep -q 'Failed.*#152.*timed out after 1 minute' "$work/out" || fail "T: report misses the timeout of #152: $(cat "$work/out")"
read -r -a pids <"$FIX/pids-152"
for pid in "${pids[@]}"; do kill -9 "$pid" 2>/dev/null; done

# U: tickets whose Paths overlap never run at the same time (#152), a ticket without Paths runs alone.
# The board has a Paths field. #301 and #302 overlap, #303 is apart, #304 has no Paths.
paths_of() { # <ticket> <globs>: Paths of a ticket of the board
  jq -c --argjson n "$1" --arg p "$2" '(.data.node.items.nodes[] | select(.content.number == $n) | .fieldValues.nodes)
    += [{text: $p, field: {name: "Paths"}}]' "$FIX/board.json" >"$work/b" && mv "$work/b" "$FIX/board.json"
}
size_of() { # <ticket> <size>: Size of a ticket of the board (an S with overlapping Paths is batched, an M never)
  jq -c --argjson n "$1" --arg s "$2" '(.data.node.items.nodes[] | select(.content.number == $n) | .fieldValues.nodes[]
    | select(.field.name == "Size") | .name) = $s' "$FIX/board.json" >"$work/b" && mv "$work/b" "$FIX/board.json"
}
# serial <a> <b>: the sessions of the tickets did not overlap in the trace.
serial() {
  local sa sb ea eb
  sa=$(grep -nx "start $1" "$FIX/trace" | cut -d: -f1) ea=$(grep -nx "end $1" "$FIX/trace" | cut -d: -f1)
  sb=$(grep -nx "start $2" "$FIX/trace" | cut -d: -f1) eb=$(grep -nx "end $2" "$FIX/trace" | cut -d: -f1)
  [ -n "$sa" ] && [ -n "$ea" ] && [ -n "$sb" ] && [ -n "$eb" ] || return 2
  [ "$ea" -lt "$sb" ] || [ "$eb" -lt "$sa" ]
}
saved_fields=$fields
fields=$(jq '. + {Paths: {id: "F_PA"}}' <<<"$fields")
config '{"maxTickets": 4, "parallel": 4}'
board 301 '[]' 302 '[]' 303 '[]' 304 '[]'
paths_of 301 'src/a/**, docs/x.md'
paths_of 302 'src/a/x.ts'
paths_of 303 'docs/guide/**'
for n in 301 302 303 304; do size_of "$n" M; done
session 301-sonnet delivered pr slow
session 302-sonnet delivered pr
session 303-sonnet delivered pr slow
session 304-sonnet delivered pr
rm -f "$FIX/trace"
run || fail "U: run failed: $(cat "$work/out")"
for n in 301 302 303 304; do grep -qx "end $n" "$FIX/trace" || fail "U: #$n did not run: $(cat "$FIX/trace")"; done
serial 301 302 || fail "U: #301 and #302 ran at the same time: $(tr '\n' ' ' <"$FIX/trace")"
serial 301 303 && fail "U: #301 and #303 do not overlap and did not run together: $(tr '\n' ' ' <"$FIX/trace")"
for n in 301 302 303; do serial "$n" 304 || fail "U: #304 has no Paths and ran with #$n: $(tr '\n' ' ' <"$FIX/trace")"; done
grep -q 'Not started' "$work/out" && fail "U: a ticket was left in the queue: $(cat "$work/out")"

# A board without the Paths field (created before it existed) has no Paths on its tickets: no collision handling.
# (A board that carries Paths is compared whatever the config lists, #344.)
fields=$saved_fields
config '{"maxTickets": 2, "parallel": 2}'
board 311 '[]' 312 '[]'
size_of 311 M
size_of 312 M
session 311-sonnet delivered pr slow
session 312-sonnet delivered pr
rm -f "$FIX/trace"
run || fail "U: run without a Paths field failed: $(cat "$work/out")"
serial 311 312 && fail "U: a config without the Paths field serialised the tickets: $(tr '\n' ' ' <"$FIX/trace")"

# V: Ready S tickets whose Paths overlap are one session in one worktree, one pull request (#263). #401 and #402
# are a batch (one slot), #403 is apart, #405 is an M that overlaps the batch. #402 fails inside the batch: it goes
# back alone, #401 is delivered and merged.
fields=$(jq '. + {Paths: {id: "F_PA"}}' <<<"$saved_fields")
config '{"maxTickets": 5, "parallel": 3, "merge": true}' '{"protection": "ruleset"}'
board 401 '[]' 402 '[]' 403 '[]' 405 '[]'
paths_of 401 'src/b/**'
paths_of 402 'src/b/x.ts'
paths_of 403 'docs/guide/**'
paths_of 405 'src/b/y.ts'
size_of 405 M
session 401-sonnet "" pr slow
printf '#401 delivered\n#402 failed: tests do not pass\n' >"$FIX/outcome-401"
echo "$green" >"$FIX/status-401"
session 403-sonnet delivered pr slow
echo "$green" >"$FIX/status-403"
session 405-sonnet delivered pr
echo "$green" >"$FIX/status-405"
rm -f "$FIX/trace" "$FIX/pulls-401"
run || fail "V: run failed: $(cat "$work/out")"
[ -d "$wt/401" ] && [ ! -e "$wt/402" ] || fail "V: not one worktree for the batch: $(ls "$wt")"
grep -q '^app-402 ' "$CLAUDE_LOG" && fail "V: a session for #402 of the batch: $(cat "$CLAUDE_LOG")"
grep -q '#402' "$repo/.git/senior-mode/runs/"*/401.prompt || fail "V: the batch prompt does not name its tickets"
grep -q 'Closes #402' "$repo/.git/senior-mode/runs/"*/401.prompt || fail "V: the batch prompt does not give each ticket its Closes"
grep -qi 'one commit per' "$repo/.git/senior-mode/runs/"*/401.prompt || fail "V: the batch prompt does not ask one commit per ticket"
grep -q 'reviewer agent reviews' "$repo/.git/senior-mode/runs/"*/401.prompt || fail "V: run's batch prompt lost its review step (#305)"
grep -c 'item-edit.*--single-select-option-id o2' "$GH_LOG" | grep -qx 4 || fail "V: #401, #402, #403 and #405 not all In progress: $(grep -c item-edit "$GH_LOG")"
grep -qx 'pr merge 501 --rebase --match-head-commit sha401 -R acme/app' "$GH_LOG" || fail "V: the batch pull request not merged: $(grep merge "$GH_LOG")"
grep -c 'item-edit.*--single-select-option-id o4' "$GH_LOG" | grep -qx 3 || fail "V: #401, #403 and #405 not set Done"
grep -c 'item-edit.*--single-select-option-id o0' "$GH_LOG" | grep -qx 1 || fail "V: #402 not set back to Backlog"
grep -q 'issues/402/labels' "$GH_LOG" || fail "V: #402 not labelled needs-human"
grep -q 'issues/401/labels\|issues/401/comments' "$GH_LOG" && fail "V: the delivered #401 was labelled or commented"
grep -q '^app-401 opus' "$CLAUDE_LOG" && fail "V: a batch with a delivered ticket was retried on Opus"
grep -q 'Merged: #401 ' "$work/out" || fail "V: #401 not reported merged: $(cat "$work/out")"
grep -q 'Failed: #402 ' "$work/out" || fail "V: #402 not reported failed: $(cat "$work/out")"
outcome_is_delivered 401
jq -e '.outcome == "failed" and .reason == "tests do not pass" and .model == "sonnet"' "$repo/.git/senior-mode/runs/"*/402.json >/dev/null ||
  fail "V: #402 not recorded as failed: $(cat "$repo/.git/senior-mode/runs/"*/402.json)"
serial 401 403 && fail "V: the batch and #403 did not run together (the batch is one slot): $(tr '\n' ' ' <"$FIX/trace")"
serial 401 405 || fail "V: #405 overlaps the batch and ran with it: $(tr '\n' ' ' <"$FIX/trace")"

# W: a batch whose session fails altogether goes on Opus once, then every ticket goes back alone.
rm -f "$FIX/outcome-401" "$FIX/trace" "$FIX/pulls-401"
board 411 '[]' 412 '[]'
paths_of 411 'src/c/**'
paths_of 412 'src/c/x.ts'
session 411-sonnet "failed: cannot build"
session 411-opus "failed: still cannot build"
run || fail "W: run failed: $(cat "$work/out")"
grep -c '^app-411 ' "$CLAUDE_LOG" | grep -qx 2 || fail "W: the batch not tried once on Sonnet and once on Opus: $(cat "$CLAUDE_LOG")"
grep -q '^app-412 ' "$CLAUDE_LOG" && fail "W: a session for #412"
grep -c 'item-edit.*--single-select-option-id o0' "$GH_LOG" | grep -qx 2 || fail "W: both tickets not set back to Backlog"
for n in 411 412; do
  jq -e '.outcome == "failed" and .escalated == true' "$repo/.git/senior-mode/runs/"*/$n.json >/dev/null || fail "W: #$n not recorded as failed on Opus"
  grep -q "issues/$n/labels" "$GH_LOG" || fail "W: #$n not labelled needs-human"
done

# W2 (#582): a batch whose session reports one ticket blocked and another duplicate does not go on Opus, and neither is a failure.
board 421 '[]' 422 '[]'
paths_of 421 'src/d/**'
paths_of 422 'src/d/x.ts'
session 421-sonnet ""
printf '#421 blocked: #23 unmerged pull request\n#422 duplicate: #32 already merged\n' >"$FIX/outcome-421"
run || fail "W2: run failed: $(cat "$work/out")"
grep -c '^app-421 ' "$CLAUDE_LOG" | grep -qx 1 || fail "W2: the batch was retried: $(cat "$CLAUDE_LOG")"
grep -q 'issues/421/labels -f labels\[\]=blocked' "$GH_LOG" || fail "W2: #421 not labelled blocked"
grep -q 'issues/422/labels -f labels\[\]=needs-human' "$GH_LOG" || fail "W2: #422 does not ask a human to close it"
jq -e '.outcome == "blocked" and .escalated == false' "$repo/.git/senior-mode/runs/"*/421.json >/dev/null || fail "W2: #421 not recorded as blocked"
jq -e '.outcome == "duplicate" and .escalated == false' "$repo/.git/senior-mode/runs/"*/422.json >/dev/null || fail "W2: #422 not recorded as duplicate"
grep -q 'Failed: #42[12]' "$work/out" && fail "W2: reported as failed: $(cat "$work/out")"
rm -f "$FIX/outcome-421"

# X: Done items closed more than board.archiveAfterDays ago (default 14) are archived when a run starts and listed (#179);
# an open item, an item not Done, one closed recently and one already archived are left alone.
config '{}'
board
jq -c --arg old "$(date -u -d '@'$(($(date +%s) - 20 * 86400)) +%Y-%m-%dT%H:%M:%SZ)" --arg new "$(date -u -d '@'$(($(date +%s) - 3 * 86400)) +%Y-%m-%dT%H:%M:%SZ)" '
  def it($n; $s; $st; $at; $arch): {id: "PVTI_\($n)", isArchived: $arch, fieldValues: {nodes: [{name: $s, field: {name: "Status"}}]},
    content: {authorAssociation: "OWNER", number: $n, title: "Ticket \($n)", url: "u", state: $st, closedAt: $at, labels: {nodes: []}, milestone: null, blockedBy: {nodes: []}}};
  .data.node.items.nodes += [it(60; "Done"; "CLOSED"; $old; false), it(61; "Done"; "CLOSED"; $new; false), it(62; "Done"; "OPEN"; null; false),
    it(63; "In review"; "CLOSED"; $old; false), it(64; "Done"; "CLOSED"; $old; true)]' "$FIX/board.json" >"$FIX/b" && mv "$FIX/b" "$FIX/board.json"
rm -f "$FIX/archived"
run || fail "X: run failed: $(cat "$work/out")"
[ "$(grep -c '^Archived: ' "$work/out")" -eq 1 ] || fail "X: not one item listed: $(cat "$work/out")"
grep -q '^Archived: #60 Ticket 60 (Done, closed more than 14 days ago)$' "$work/out" ||
  fail "X: archived items not listed: $(cat "$work/out")"
[ "$(grep -c archiveProjectV2Item "$FIX/archived")" -eq 1 ] || fail "X: not one item archived: $(cat "$FIX/archived")"
jq -e '.variables | .project == "PVT_1" and .item == "PVTI_60"' "$FIX/archived" >/dev/null || fail "X: wrong item archived: $(cat "$FIX/archived")"
grep -q 'No Ready ticket' "$work/out" || fail "X: the run did not go on after archiving: $(cat "$work/out")"
jq '.board.archiveAfterDays = 2' "$repo/.claude/senior-mode.json" >"$work/c" && mv "$work/c" "$repo/.claude/senior-mode.json"
rm -f "$FIX/archived"
run || fail "X: run with archiveAfterDays 2 failed: $(cat "$work/out")"
grep -q '^Archived: #61 .*closed more than 2 days ago' "$work/out" || fail "X: board.archiveAfterDays not read: $(cat "$work/out")"
ARCHIVE_FAIL=1 run || fail "X: a refused archive stops the run: $(cat "$work/out")"
grep -q 'could not archive #60' "$work/out" || fail "X: a refused archive is not said: $(cat "$work/out")"
grep -q 'No Ready ticket' "$work/out" || fail "X: the run stopped after a refused archive"
jq '.board.archiveAfterDays = "soon"' "$repo/.claude/senior-mode.json" >"$work/c" && mv "$work/c" "$repo/.claude/senior-mode.json"
run && fail "X: archiveAfterDays soon accepted"
grep -q 'board.archiveAfterDays must be a positive whole number' "$work/out" || fail "X: bad archiveAfterDays not explained: $(cat "$work/out")"
git -C "$repo" checkout -q -- .claude/senior-mode.json

# Y: a ticket starts in the current iteration with Start today, and its merge sets End (#180).
today=$(date -u +%Y-%m-%d)
fields='{"Status": {"id": "F_S", "options": {"Ready": "o1", "In progress": "o2", "In review": "o3", "Backlog": "o0", "Done": "o4"}},
  "Iteration": {"id": "F_I", "iteration": true}, "Start": {"id": "F_St", "date": true}, "End": {"id": "F_E", "date": true}}'
jq -nc --arg a "$(date -u -d "@$(($(date +%s) - 3 * 86400))" +%Y-%m-%d)" '{data: {node: {field: {id: "F_I", configuration: {duration: 14, completedIterations: [],
  iterations: [{id: "it7", title: "Iteration 7", startDate: $a, duration: 14}]}}}}}' >"$FIX/iteration.json"
config '{"merge": true}' '{"protection": "ruleset"}'
board 70 '[]'
session 70-sonnet delivered pr
echo "$green" >"$FIX/status-70"
run || fail "Y: run failed: $(cat "$work/out")"
grep -q "item-edit.*--field-id F_I --iteration-id it7" "$GH_LOG" || fail "Y: no iteration at the start: $(grep item-edit "$GH_LOG")"
grep -q "item-edit.*--field-id F_St --date $today" "$GH_LOG" || fail "Y: no Start at the start"
grep -q "item-edit.*--field-id F_E --date $today" "$GH_LOG" || fail "Y: no End after the merge: $(grep item-edit "$GH_LOG")"
[ "$(grep -n -- '--single-select-option-id o4' "$GH_LOG" | head -1 | cut -d: -f1)" -lt "$(grep -n -- '--field-id F_E' "$GH_LOG" | head -1 | cut -d: -f1)" ] ||
  fail "Y: End set before Done"
grep -c -- '--field-id F_E' "$GH_LOG" | grep -qx 1 || fail "Y: End not set once"
# Not merged: no End.
config '{}'
board 71 '[]'
session 71-sonnet delivered pr
run || fail "Y: run without merge failed: $(cat "$work/out")"
grep -q -- '--field-id F_E' "$GH_LOG" && fail "Y: End set without a merge"
fields='{"Status": {"id": "F_S", "options": {"Ready": "o1", "In progress": "o2", "In review": "o3", "Backlog": "o0", "Done": "o4"}}}'

# E: nothing Ready, bad arguments.
config '{}'
board
run || fail "E: run with an empty board failed"
grep -q 'No Ready ticket' "$work/out" || fail "E: empty board not reported: $(cat "$work/out")"
[ "$(grep -c '^pr list' "$GH_LOG")" -eq 1 ] || fail "E: a run with no ticket cleans once, at its start: $(cat "$GH_LOG")"
run --max 0 && fail "E: --max 0 accepted"
run --parallel x && fail "E: --parallel x accepted"

# X2: an external pull request (#427) is never merged, whatever its statuses say: one from a fork, one by a
# non-collaborator, one whose association is unknown; a collaborator's own pull request still merges.
config '{"maxTickets": 4, "parallel": 4, "merge": true}' '{"protection": "ruleset"}'
for n in 481 482 483 484; do echo "$green" >"$FIX/status-$n"; done
echo '.[0].head.repo.full_name = "mallory/app" | .[0].base.repo.full_name = "acme/app"' >"$FIX/external-481"
echo '.[0].author_association = "CONTRIBUTOR"' >"$FIX/external-482"
echo '.[0] |= del(.author_association)' >"$FIX/external-483"
echo '.[0].author_association = "COLLABORATOR"' >"$FIX/external-484"
board 481 '[]' 482 '[]' 483 '[]' 484 '[]'
for n in 481 482 483 484; do session "$n-sonnet" delivered pr; done
run || fail "X2: run failed: $(cat "$work/out")"
for n in 581 582 583; do grep -q "pr merge $n" "$GH_LOG" && fail "X2: merged the external pull request #$n"; done
grep -qx 'pr merge 584 --rebase --match-head-commit sha484 -R acme/app' "$GH_LOG" || fail "X2: a collaborator's pull request not merged: $(grep merge "$GH_LOG")"
for n in 481 482 483; do grep -q "Waiting for a human.*#$n.*external" "$work/out" || fail "X2: #$n not reported as external: $(cat "$work/out")"; done
rm -f "$FIX"/external-48*

# Y: an irreversible choice the session cannot settle (#363) goes to the decision inbox: the question and a recommended
# option in a comment, `needs-decision` (and `needs-human`, the inbox until a decision list exists), the ticket back to
# Ready, the work kept; no retry on Opus, the run goes on with the next ticket; a ticket labelled needs-decision is
# not picked.
config '{"maxTickets": 3}'
board 710 '[]' 711 '[]' 712 '["needs-decision"]'
session 710-sonnet "decision: Which table owns the audit trail? | Add a new table audit_log | done: tests written, next: the migration"
session 711-sonnet delivered pr
# #346: the checkpoint block of the draft pull request of the ticket goes in the comment.
printf '%s\n' '[{"number": 810, "body": "Closes #710\n\n<!-- senior-mode:checkpoint -->\n**Done**\n\n- the audit schema\n<!-- /senior-mode:checkpoint -->\n\nafter"}]' >"$FIX/pulls-710"
run || fail "Y: run failed: $(cat "$work/out")"
rm -f "$FIX/pulls-710"
grep -q 'app-710 opus' "$CLAUDE_LOG" && fail "Y: a decision was retried on Opus"
grep -q 'app-711' "$CLAUDE_LOG" || fail "Y: the run did not go on with the next ticket"
grep -q 'app-712' "$CLAUDE_LOG" && fail "Y: a needs-decision ticket was picked"
grep -q 'issues/710/labels -f labels\[\]=needs-decision' "$GH_LOG" || fail "Y: #710 not labelled needs-decision"
grep -q 'issues/710/labels -f labels\[\]=needs-human' "$GH_LOG" || fail "Y: #710 not labelled needs-human"
c=$(grep -A8 'issues/710/comments -f body=<!-- senior-mode:decision' "$GH_LOG" || true)
for want in 'Which table owns the audit trail?' 'Add a new table audit_log' 'tests written, next: the migration'; do
  grep -qF "$want" <<<"$c" || fail "Y: the comment on #710 misses '$want': $c"
done
c=$(grep -A24 'issues/710/comments -f body=<!-- senior-mode:decision' "$GH_LOG" || true)
for want in 'Checkpoint block of the draft pull request' '- the audit schema'; do
  grep -qF -- "$want" <<<"$c" || fail "Y: the comment on #710 misses the checkpoint block ('$want'): $c"
done
grep -qF 'senior-mode:checkpoint' <<<"$c" && fail "Y: the markers of the block are in the comment on #710"
grep -q 'item-edit.*--single-select-option-id o1' "$GH_LOG" || fail "Y: #710 not set back to Ready"
grep -q 'item-edit.*--single-select-option-id o0' "$GH_LOG" && fail "Y: #710 was set back to Backlog"
jq -e '.outcome == "decision" and .reason == "Which table owns the audit trail?"' "$repo/.git/senior-mode/runs/"*/710.json >/dev/null ||
  fail "Y: #710 not recorded as a decision: $(cat "$repo"/.git/senior-mode/runs/*/710.json)"
grep -q 'Waiting for a human: #710' "$work/out" || fail "Y: report misses #710 waiting for a decision: $(cat "$work/out")"
grep -q 'Failed: #710' "$work/out" && fail "Y: a decision was reported as a failure"

# Y2: a reply of a collaborator after the question removes the labels (the ticket is Ready, so it is picked again);
# no reply, or a reply of a non-collaborator, or only senior-mode's own comments, leave them.
config '{}'
board 722 '[]'
echo '[{"number": 720}, {"number": 721}, {"number": 723}]' >"$FIX/decisions.json"
mark='<!-- senior-mode:decision -->'
jq -n --arg m "$mark" '[{body: "@owner this needs a human", author_association: "OWNER"}, {body: ($m + "\nQuestion"), author_association: "OWNER"},
  {body: "Go with audit_log", author_association: "COLLABORATOR"}]' >"$FIX/comments-720"
jq -n --arg m "$mark" '[{body: ($m + "\nQuestion"), author_association: "OWNER"}, {body: "<!-- senior-mode:status -->", author_association: "OWNER"}]' >"$FIX/comments-721"
jq -n --arg m "$mark" '[{body: ($m + "\nQuestion"), author_association: "OWNER"}, {body: "me too", author_association: "NONE"}]' >"$FIX/comments-723"
run || fail "Y2: run failed: $(cat "$work/out")"
grep -q 'DELETE repos/acme/app/issues/720/labels/needs-decision' "$GH_LOG" || fail "Y2: #720 answered but needs-decision kept"
grep -q 'DELETE repos/acme/app/issues/720/labels/needs-human' "$GH_LOG" || fail "Y2: #720 answered but needs-human kept"
grep -q 'DELETE repos/acme/app/issues/721/' "$GH_LOG" && fail "Y2: #721 has no reply"
grep -q 'DELETE repos/acme/app/issues/723/' "$GH_LOG" && fail "Y2: #723 has a reply of a non-collaborator"
rm -f "$FIX"/decisions.json "$FIX"/comments-72*

# PL: a verified plan before coding on M and L tickets (#352). The prompt of an M ticket asks for the plan and the
# architect's answer; an S ticket has no plan step. An M ticket delivered with no approved plan, or with two `revise`, fails
# (no Opus retry here: escalate is off); a plan rejected twice is `plan-rejected`: needs-human with both plans in a comment,
# back in Backlog, not a failure.
config '{"maxTickets": 8, "parallel": 3, "escalate": false, "maxConsecutiveFailures": 9}'
board 901 '[]' 902 '[]' 903 '[]' 904 '[]' 905 '[]' 906 '[]' 907 '[]'
for n in 901 903 904 905 906 907; do size_of "$n" M; done
session 901-sonnet delivered pr
printf 'plan 1:\nedit a.sh\narchitect 1: revise: the spec wants b.sh too\nplan 2:\nedit a.sh and b.sh\narchitect 2: approve\n' >"$FIX/plan-901"
session 902-sonnet delivered pr
echo none >"$FIX/plan-902"
session 903-sonnet delivered pr
echo none >"$FIX/plan-903"
session 904-sonnet "plan-rejected: it still ignores ADR 0012"
printf 'plan 1:\nfirst plan\narchitect 1: revise: breaks ADR 0012\nplan 2:\nsecond plan\narchitect 2: revise: it still ignores ADR 0012\n' >"$FIX/plan-904"
session 905-sonnet delivered pr
printf 'plan 1:\nfirst\narchitect 1: revise: no\nplan 2:\nsecond\narchitect 2: revise: no\n' >"$FIX/plan-905"
session 906-sonnet delivered pr
printf 'plan 1:\nfirst\narchitect 1: revise: no\n' >"$FIX/plan-906"
# #346: with no plan file, the plan in the checkpoint block of the pull request counts.
session 907-sonnet delivered pr
echo none >"$FIX/plan-907"
printf '%s\n' '.[0].body = "Closes #907\n\n<!-- senior-mode:checkpoint -->\n**Plan**\n\n```text\nplan 1:\nedit a.sh\narchitect 1: approve\n```\n<!-- /senior-mode:checkpoint -->"' >"$FIX/external-907"
run || fail "PL: run failed: $(cat "$work/out")"
runs=$(find "$repo/.git/senior-mode/runs" -mindepth 1 -maxdepth 1 -type d | sort | tail -n 1)
for want in 'Plan first (size M)' 'at most 15 lines' 'architect agent' 'architect 1: approve' 'architect 1: revise' 'plan-rejected: <the architect' 'SENIOR_MODE_RUN_PLAN'; do
  grep -qF "$want" "$runs/901.prompt" || fail "PL: the prompt of an M ticket misses '$want'"
done
grep -qF 'No code' "$runs/901.prompt" || grep -qF 'no code' "$runs/901.prompt" || fail "PL: the prompt does not forbid code before approve"
grep -q 'Plan first\|plan-rejected' "$runs/902.prompt" && fail "PL: an S ticket has a plan step"
# #346: every ticket session writes a checkpoint at each commit and fills the draft pull request it opened.
for t in 901 902; do
  for want in 'senior-mode checkpoint --done' 'senior-mode:checkpoint -->' 'gh pr ready'; do
    grep -qF -- "$want" "$runs/$t.prompt" || fail "PL: the prompt of #$t misses '$want'"
  done
done
grep -q '^Failed.*#907' "$work/out" && fail "PL: #907, whose plan is in the checkpoint block, failed: $(cat "$work/out")"
outcome_is_delivered 907
grep -q '^Failed.*#901' "$work/out" && fail "PL: #901, approved after one revise, failed: $(cat "$work/out")"
outcome_is_delivered 901
outcome_is_delivered 902
grep -q 'Failed.*#903.*no plan' "$work/out" || fail "PL: an M ticket delivered without a plan did not fail: $(cat "$work/out")"
grep -q 'Failed.*#905.*second revision' "$work/out" || fail "PL: two revise then delivered did not fail: $(cat "$work/out")"
grep -q 'Failed.*#906.*no plan' "$work/out" || fail "PL: a last answer of revise then delivered did not fail: $(cat "$work/out")"
grep -q 'app-904 opus' "$CLAUDE_LOG" && fail "PL: a rejected plan was retried on Opus"
grep -q 'issues/904/labels -f labels\[\]=needs-human' "$GH_LOG" || fail "PL: #904 not labelled needs-human"
c=$(grep -A14 'issues/904/comments -f body=An autonomous senior-mode session stopped on this ticket: the architect' "$GH_LOG" || true)
for want in 'it still ignores ADR 0012' 'first plan' 'second plan' 'architect 1: revise: breaks ADR 0012'; do
  grep -qF "$want" <<<"$c" || fail "PL: the comment on #904 misses '$want': $c"
done
grep -q 'Waiting for a human: #904.*rejected twice' "$work/out" || fail "PL: report misses #904 waiting: $(cat "$work/out")"
grep -q 'Failed: #904' "$work/out" && fail "PL: a rejected plan was reported as a failure"
jq -e '.outcome == "plan-rejected" and .reason == "it still ignores ADR 0012"' "$runs/904.json" >/dev/null ||
  fail "PL: #904 not recorded as plan-rejected: $(cat "$runs/904.json")"
rm -f "$FIX"/plan-9* "$FIX"/external-907

[ "$failures" -eq 0 ] && echo "run: all cases pass"
exit "$((failures > 0))"
