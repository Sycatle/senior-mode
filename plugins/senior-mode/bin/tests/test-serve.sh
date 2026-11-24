#!/usr/bin/env bash
# Tests for `senior-mode serve` (spec 131, ADR 0017, #149 and #156). Offline: gh, claude, tmux and systemctl are
# stubs on PATH, as in test-run.sh. gh answers the board query and the REST calls from fixtures in $FIX; claude
# plays a ticket session from $FIX/claude-<n>-<model> (line 1: the outcome to write, empty for none; line 2:
# "pr" to open a pull request; line 3: "hang" to never end, with a child process recorded in $FIX/pids-<n>,
# "slow" to end after two seconds, "limit" to end on the subscription usage limit with the message in
# $FIX/limit-msg, "flaky:<message>" to die once with the message on stderr (exit 1), then behave; the file claude-<n>-<model>-<role> wins over claude-<n>-<model> for a session with that
# SENIOR_MODE_ROLE; line 2 may be "pr:<number>" for another pull request number; line 4: "review:<state>" posts
# senior-mode/review on the head checked out, "commit" commits a test file). gh serves the open pull requests,
# their statuses and their merge state from $FIX (see the helpers below). systemctl logs its calls to $SYS_LOG. SENIOR_MODE_SERVE_ONCE=1 makes serve poll once, wait for
# its sessions and exit; SENIOR_MODE_NOW is its clock; SENIOR_MODE_LOADAVG stands in for the load average.
# shellcheck disable=SC2016 # jq programs and stub bodies, not expanded here
set -u
cli=$(cd "$(dirname "$0")/.." && pwd)/senior-mode
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

mkdir -p "$work/stub" "$work/fix" "$work/home"
cat >"$work/stub/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$GH_LOG"
jqf="" prev=""
for a in "$@"; do [ "$prev" = --jq ] && jqf=$a; prev=$a; done
respond() { if [ -n "$jqf" ]; then jq -r "$jqf"; else cat; fi; }
case "$*" in
  "api graphql --input -")
    cat >"$FIX/graphql-in"
    if grep -q createProjectV2StatusUpdate "$FIX/graphql-in"; then
      cat "$FIX/graphql-in" >>"$FIX/status-updates"
      echo '{"data": {"createProjectV2StatusUpdate": {"statusUpdate": {"id": "SU_1"}}}}'
    elif grep -q '"sha":' "$FIX/graphql-in"; then
      echo '{"data": {"repository": {"object": {"associatedPullRequests": {"nodes": [{"state": "OPEN", "closingIssuesReferences": {"nodes": []}}]}}}}}'
    elif grep -q projectItems "$FIX/graphql-in" && [ -f "$FIX/item-$(jq -r '.variables.number' "$FIX/graphql-in").json" ]; then
      cat "$FIX/item-$(jq -r '.variables.number' "$FIX/graphql-in").json"
    else cat "$FIX/board.json"; fi ;;
  "api repos/acme/app --jq "*) echo "{\"allow_auto_merge\": $(cat "$FIX/allow-auto" 2>/dev/null || echo false)}" | respond ;;
  "api repos/acme/app/commits/"*"/status"*)
    sha=$(sed -E 's#^api repos/acme/app/commits/([^/ ]+)/status.*#\1#' <<<"$*")
    { cat "$FIX/status-$sha" 2>/dev/null || true; } | jq -Rn '[inputs | split(" ") | {key: .[0], value: .[1]}] | from_entries
      | to_entries | {statuses: map({context: .key, state: .value})}' | respond ;;
  "api repos/acme/app/statuses/"*)
    sha=$(sed -E 's#^api repos/acme/app/statuses/([^ ]+) .*#\1#' <<<"$*")
    st="" cx=""
    for a in "$@"; do case $a in state=*) st=${a#state=} ;; context=*) cx=${a#context=} ;; esac; done
    echo "$cx $st" >>"$FIX/status-$sha" ;;
  "api repos/acme/app/pulls?state=open"*) [ ! -f "$FIX/gh-hang" ] || sleep 30; { cat "$FIX/open-prs.json" 2>/dev/null || echo '[]'; } | respond ;;
  "api repos/acme/app/pulls/"[0-9]*" -X PATCH"*) touch "$FIX/closed-$(sed -E 's#^api repos/acme/app/pulls/([0-9]+).*#\1#' <<<"$*")" ;;
  "pr view "*"--json state --jq .state") cat "$FIX/state-$3" 2>/dev/null || echo OPEN ;;
  "pr merge "*)
    [ ! -f "$FIX/merge-fails" ] || { echo "Pull request is not mergeable" >&2; exit 1; }
    if [[ $* == *--auto* ]]; then
      [ ! -f "$FIX/no-auto" ] || { echo "auto merge is not allowed for this repository" >&2; exit 1; }
      [ -f "$FIX/auto-queues" ] || echo MERGED >"$FIX/state-$3"
    else
      echo MERGED >"$FIX/state-$3"
      jq -c --argjson n "$3" 'map(select(.number != $n))' "$FIX/open-prs.json" >"$FIX/open-prs.tmp" && mv "$FIX/open-prs.tmp" "$FIX/open-prs.json"
    fi ;;
  "pr update-branch "*)
    [ ! -f "$FIX/update-conflict" ] || { echo "merge conflict between base and head" >&2; exit 1; }
    jq -c --arg s "$(cat "$FIX/rebase-$3")" '.head.sha = $s | .mergeable_state = "clean"' "$FIX/pull-$3.json" >"$FIX/pull-$3.tmp"
    mv "$FIX/pull-$3.tmp" "$FIX/pull-$3.json"
    cp "$FIX/pull-$3.json" "$FIX/open.d/$3.json"
    jq -s '.' "$FIX"/open.d/*.json >"$FIX/open-prs.json" ;;
  "api repos/acme/app/dependabot/alerts"* | "api repos/acme/app/secret-scanning/alerts"*) echo '[]' | respond ;;
  "issue view "*)
    n=$(sed -E 's#^issue view ([0-9]+) .*#\1#' <<<"$*")
    jq -c --argjson n "$n" '.data.node.items.nodes[] | select(.content.number == $n) | .content
      | {title, state, labels: .labels.nodes}' "$FIX/board.json" ;;
  "project item-add"*) echo "ITEM_$(sed -E 's#.*/issues/([0-9]+).*#\1#' <<<"$*")" ;;
  "project item-edit"*) ;;
  "auth status"*) [ ! -f "$FIX/gh-auth-bad" ] ;;
  "api repos/acme/app/pulls/"*"/commits"*) cat "$FIX/commits-$(sed -E 's#.*/pulls/([0-9]+)/commits.*#\1#' <<<"$*").json" | respond ;;
  "api repos/acme/app/pulls/"*"/files"*) cat "$FIX/files-$(sed -E 's#.*/pulls/([0-9]+)/files.*#\1#' <<<"$*")" 2>/dev/null || echo src/app.ts ;;
  "api repos/acme/app/pulls/"[0-9]*) cat "$FIX/pull-$(sed -E 's#^api repos/acme/app/pulls/([0-9]+).*#\1#' <<<"$*").json" | respond ;;
  "api repos/acme/app/pulls?head="*)
    n=$(sed -E 's#.*head=acme:[a-z]+/([0-9]+)-.*#\1#' <<<"$*")
    { cat "$FIX/pulls-$n" 2>/dev/null || echo '[]'; } | respond ;;
  "api repos/acme/app/issues/"*"/comments"*) echo '{}' ;;
  "api repos/acme/app/issues/"*"/labels"*) echo '[]' ;;
  "pr list"*"--state merged"*) cat "$FIX/merged-prs" 2>/dev/null || echo '[]' ;;
  "pr view "*) n=$(sed -E 's#^pr view ([0-9]+) .*#\1#' <<<"$*"); cat "$FIX/pr-$n.json" ;;
  "pr list"*) echo '[]' ;;
  "api repos/acme/app/branches?protected"*) ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac
STUB
cat >"$work/stub/claude" <<'STUB'
#!/usr/bin/env bash
args=("$@")
for ((i = 0; i < $#; i++)); do [ "${args[i]}" != --model ] || model=${args[i + 1]}; done
tag=$(basename "$PWD")
[[ $PWD == */senior-mode/worktrees/* ]] && tag=app-$tag
echo "$tag $model run=${SENIOR_MODE_RUN:-} role=${SENIOR_MODE_ROLE:-}" >>"$CLAUDE_LOG"
if [[ ${!#} == *"guard probe"* ]]; then
  echo '{"type": "user", "message": {"content": "senior-mode: skipping checks is denied (core.hooksPath); fix what the check reports instead."}}'
  exit 0
fi
n=$(sed -nE 's#.*/senior-mode/worktrees/[^/]+/(review-)?([0-9]+)(-r[0-9]+)?$#\2#p' <<<"$PWD")
[ -n "$n" ] || exit 0
fx=$FIX/claude-$n-$model-${SENIOR_MODE_ROLE:-}
[ -f "$fx" ] || fx=$FIX/claude-$n-$model
[ -f "$fx" ] || exit 1
case $(sed -n 3p "$fx") in
  hang)
    sleep 300 &
    echo "$$ $!" >"$FIX/pids-$n"
    wait ;;
  slow) sleep 2 ;;
  flaky:*)
    if [ ! -f "$FIX/flaky-done-$n-$model" ]; then
      touch "$FIX/flaky-done-$n-$model"
      sed -n 3p "$fx" | cut -d: -f2- >&2
      exit 1
    fi ;;
  limit)
    jq -nc --rawfile m "$FIX/limit-msg" '{type: "result", is_error: true, result: $m}'
    exit 1 ;;
esac
outcome=$(sed -n 1p "$fx")
[ -z "$outcome" ] || echo "$outcome" >"$SENIOR_MODE_RUN_OUTCOME"
# A batch session (#263) writes one outcome line per ticket: $FIX/outcome-<lead> holds them.
[ ! -f "$FIX/outcome-$n" ] || cp "$FIX/outcome-$n" "$SENIOR_MODE_RUN_OUTCOME"
case $(sed -n 2p "$fx") in
  pr) num=$((n + 100)) ;;
  pr:*) num=$(sed -n 2p "$fx"); num=${num#pr:} ;;
  *) num="" ;;
esac
# $FIX/board-after-<n>: the board the session leaves behind it (the ticket moved by something it ran).
[ ! -f "$FIX/board-after-$n" ] || cp "$FIX/board-after-$n" "$FIX/board.json"
[ -z "$num" ] || echo "[{\"number\": $num, \"author_association\": \"OWNER\", \"head\": {\"sha\": \"sha$n\"}, \"labels\": []}]" >"$FIX/pulls-$n"
case $(sed -n 4p "$fx") in
  review:*) echo "senior-mode/review $(sed -n 4p "$fx" | cut -d: -f2)" >>"$FIX/status-$(git rev-parse HEAD)" ;;
  commit) echo "red $n" >"tests-$n.txt"; git add "tests-$n.txt"; git -c user.name=t -c user.email=t@t commit -q -m "test: red tests" ;;
esac
echo '{"result": "ok", "modelUsage": {"claude-'"$model"'": {"inputTokens": 1, "outputTokens": 2}}}'
STUB
cat >"$work/stub/curl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$CURL_LOG"
[ ! -f "$FIX/curl-fails" ]
STUB
cat >"$work/stub/tmux" <<'STUB'
#!/usr/bin/env bash
case $1 in
  has-session) [ -f "$FIX/tmux-session" ] ;;
  new-session | new-window)
    touch "$FIX/tmux-session"
    setsid bash -c "${*: -1}" >/dev/null 2>&1 &
    ;;
esac
STUB
cat >"$work/stub/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$SYS_LOG"
[ "$*" != "--user show-environment" ] || [ ! -f "$FIX/no-systemd" ]
STUB
cat >"$work/stub/loginctl" <<'STUB'
#!/usr/bin/env bash
echo "Linger=$(cat "$FIX/linger")"
STUB
chmod +x "$work/stub/"*
export PATH="$work/stub:$PATH" GH_LOG="$work/gh.log" CLAUDE_LOG="$work/claude.log" SYS_LOG="$work/sys.log" CURL_LOG="$work/curl.log" FIX="$work/fix" \
  SENIOR_MODE_RETRY_DELAY=0 XDG_DATA_HOME="$work/xdg" SENIOR_MODE_POLL=0.1 CLAUDE_CONFIG_DIR="$work/claude-home" \
  SENIOR_MODE_PROBE_RETRY=0 SENIOR_MODE_MANAGED_SETTINGS="$work/managed-settings.json" XDG_CONFIG_HOME="$work/cfg" USER=tester \
  SENIOR_MODE_NOW=1800000000 SENIOR_MODE_LOADAVG=0
mkdir -p "$CLAUDE_CONFIG_DIR"
echo '{"enabledPlugins": {"senior-mode@senior-mode": true}}' >"$CLAUDE_CONFIG_DIR/settings.json"
echo no >"$FIX/linger"

git init -q --bare -b main "$work/github.com/acme/app.git"
repo="$work/app"
state="$repo/.git/senior-mode/serve"
git init -q -b main "$repo"
git -C "$repo" remote add origin "$work/github.com/acme/app.git"
mkdir -p "$repo/.claude"
fields='{"Status": {"id": "F_S", "options": {"Ready": "o1", "In progress": "o2", "In review": "o3", "Backlog": "o0", "Done": "o4"}}}'
# config <autonomy json> [<serve json> [<notify json>]]; the daily digest is off unless the notify json turns it on.
config() {
  jq -n --argjson f "$fields" --argjson a "$1" --argjson s "${2:-{\}}" --argjson nt "${3:-{\}}" '{project: {id: "PVT_1", owner: "acme", number: 3, fields: $f},
    autonomy: ({minMemoryMB: 0} + $a), serve: $s, notify: ({digest: false} + $nt), github: {protection: "ruleset"}, audit: false,
    checks: [{name: "ok", run: "true"}], protected: ($ENV.PROT // "" | if . == "" then [] else split(",") end)}' >"$repo/.claude/senior-mode.json"
  git -C "$repo" add -A
  git -C "$repo" -c user.name=t -c user.email=t@t commit -q -m "chore: config" --allow-empty
  git -C "$repo" push -q origin main
}
# board <number>...: Ready tickets, P1, in number order.
board() {
  local items="[]" n
  for n in "$@"; do
    items=$(jq -c --argjson n "$n" '. + [{fieldValues: {nodes: [{name: "Ready", field: {name: "Status"}},
      {name: "P1 next", field: {name: "Priority"}}, {name: "S", field: {name: "Size"}}]},
      content: {authorAssociation: "OWNER", number: $n, title: "Ticket \($n)", url: "u", state: "OPEN", closedAt: null,
        labels: {nodes: []}, milestone: null, blockedBy: {nodes: []}}}]' <<<"$items")
  done
  jq -nc --argjson i "$items" '{data: {node: {items: {pageInfo: {hasNextPage: false}, nodes: $i}}}}' >"$FIX/board.json"
}
session() { printf '%s\n%s\n%s\n%s\n' "$2" "${3:-}" "${4:-}" "${5:-}" >"$FIX/claude-$1"; }
# fresh: an empty state directory; once: one poll of serve in $repo.
fresh() { rm -rf "$state"; }
once() { : >"$GH_LOG"; : >"$CLAUDE_LOG"; (cd "$repo" && SENIOR_MODE_SERVE_ONCE=1 "$cli" serve) >"$work/out" 2>&1; }
started() { grep -q "^app-$1 " "$CLAUDE_LOG"; }
# outcome_of <n> <outcome>: the record serve left for the ticket under .git/senior-mode/serve/.
outcome_of() {
  jq -e --arg o "$2" '.outcome == $o' "$state/$1.json" >/dev/null 2>&1 || fail "$3: #$1 not recorded as $2: $(cat "$state/$1.json" 2>&1)"
}

# A: Ready tickets, free slots: one session per ticket, in pick order, outcomes recorded under serve/, state tidy.
config '{"parallel": 2}'
board 10 11 12
session 10-sonnet delivered pr
session 11-sonnet delivered pr
session 12-sonnet delivered pr
fresh
once || fail "A: serve failed: $(cat "$work/out")"
started 10 || fail "A: no session for #10: $(cat "$CLAUDE_LOG")"
started 11 || fail "A: no session for #11: $(cat "$CLAUDE_LOG")"
started 12 && fail "A: more sessions than autonomy.parallel"
grep -q '^app-10 sonnet run=1' "$CLAUDE_LOG" || fail "A: session not started as run does: $(cat "$CLAUDE_LOG")"
outcome_of 10 delivered A
outcome_of 11 delivered A
[ "$(awk 'END { print NR }' "$state/launches")" -eq 2 ] || fail "A: launches not counted: $(cat "$state/launches" 2>&1)"
[ ! -e "$state/serve.pid" ] && [ ! -e "$state/token" ] || fail "A: pid or token file left: $(ls "$state")"
[ ! -e "$repo/.git/senior-mode/runs" ] || fail "A: serve wrote under runs/"
grep -q 'Waiting for a human' "$work/out" && fail "A: a delivered ticket is reported as waiting, the reviewer takes it from here: $(cat "$work/out")"
grep -q '^pr merge' "$GH_LOG" && fail "A: a ticket session was merged by the reaper, the integrator pass does that"
grep -q 'issue view 10 ' "$GH_LOG" || fail "A: the worktree was not opened by senior-mode start"
grep -c 'item-edit.*--single-select-option-id o2' "$GH_LOG" | grep -qx 2 || fail "A: tickets not set In progress"
board 10 11
config '{"parallel": 1}'
fresh
once || fail "A: serve failed: $(cat "$work/out")"
started 10 || fail "A: one slot: #10 comes first: $(cat "$CLAUDE_LOG")"
started 11 && fail "A: one slot: #11 started too"

# B: a failed ticket is retried on Opus as in run; a second poll starts no session when no ticket is Ready.
config '{"parallel": 1}'
board 15
session 15-sonnet "failed: no luck"
session 15-opus delivered pr
fresh
once || fail "B: serve failed: $(cat "$work/out")"
grep -q '^app-15 opus' "$CLAUDE_LOG" || fail "B: not retried on Opus: $(cat "$CLAUDE_LOG")"
outcome_of 15 delivered B
board
once || fail "B: serve failed on an empty board: $(cat "$work/out")"
[ ! -s "$CLAUDE_LOG" ] || fail "B: a session started with nothing Ready"

# C: sessions per hour. One launch an hour: the second ticket waits; an hour later it starts.
config '{"parallel": 2, "sessionsPerHour": 1}'
board 20 21
session 20-sonnet delivered pr
session 21-sonnet delivered pr
fresh
once || fail "C: serve failed: $(cat "$work/out")"
started 20 || fail "C: no launch: $(cat "$CLAUDE_LOG")"
started 21 && fail "C: two launches in the hour"
grep -q 'autonomy.sessionsPerHour 1' "$work/out" || fail "C: the wait is not said: $(cat "$work/out")"
board 21
SENIOR_MODE_NOW=1800000100 once || fail "C: serve failed: $(cat "$work/out")"
started 21 && fail "C: launched within the hour"
SENIOR_MODE_NOW=1800003601 once || fail "C: serve failed: $(cat "$work/out")"
started 21 || fail "C: not launched an hour later: $(cat "$work/out")"
# C2: tickets per hour (#355) count ticket starts, not role sessions; the log names the binding cap.
config '{"parallel": 2, "ticketsPerHour": 1}'
board 20 21
fresh
once || fail "C2: serve failed: $(cat "$work/out")"
started 20 || fail "C2: no launch: $(cat "$CLAUDE_LOG")"
started 21 && fail "C2: two tickets started in the hour"
grep -q 'autonomy.ticketsPerHour 1' "$work/out" || fail "C2: the binding cap is not named: $(cat "$work/out")"
grep -q 'autonomy.sessionsPerHour' "$work/out" && fail "C2: the session cap is named, it does not bind: $(cat "$work/out")"
# Without sessionsPerHour, the safety cap is 6 sessions per slot: 6 role sessions in the hour stop one slot, not two.
config '{"parallel": 1}'
board 20
fresh
mkdir -p "$state" && printf '1800000000\n%.0s' 1 2 3 4 5 6 >"$state/launches"
SENIOR_MODE_NOW=1800000100 once || fail "C2: serve failed: $(cat "$work/out")"
started 20 && fail "C2: launched past the safety cap of one slot"
grep -q 'autonomy.sessionsPerHour 6, the safety cap' "$work/out" || fail "C2: the safety cap is not named: $(cat "$work/out")"
config '{"parallel": 2}'
fresh
mkdir -p "$state" && printf '1800000000\n%.0s' 1 2 3 4 5 6 >"$state/launches"
SENIOR_MODE_NOW=1800000100 once || fail "C2: serve failed: $(cat "$work/out")"
started 20 || fail "C2: the safety cap does not scale with parallel: $(cat "$work/out")"

# D: memory and CPU: a launch waits for the next poll.
config '{"minMemoryMB": 99999999}'
board 25
session 25-sonnet delivered pr
fresh
once || fail "D: serve failed: $(cat "$work/out")"
started 25 && fail "D: launched with too little memory"
grep -q 'MB of memory available.*minMemoryMB' "$work/out" || fail "D: memory wait not said: $(cat "$work/out")"
config '{}'
SENIOR_MODE_LOADAVG=9999 once || fail "D: serve failed: $(cat "$work/out")"
started 25 && fail "D: launched with the load over the CPU count"
grep -q 'load average 9999' "$work/out" || fail "D: load wait not said: $(cat "$work/out")"
SENIOR_MODE_LOADAVG=0 once || fail "D: serve failed: $(cat "$work/out")"
started 25 || fail "D: not launched with room: $(cat "$work/out")"

# E: the usage limit. The reset time is in the message: nothing launches before it, the ticket goes back to Ready
# without a failure, and nothing is retried on Opus.
config '{}'
board 30 31
fresh
printf 'Claude AI usage limit reached|1800005000' >"$FIX/limit-msg"
session 30-sonnet "" "" limit
session 30-opus delivered pr
session 31-sonnet delivered pr
once || fail "E: serve failed: $(cat "$work/out")"
[ "$(cat "$state/limit-until" 2>/dev/null)" = 1800005000 ] || fail "E: reset time not kept: $(cat "$state/limit-until" 2>&1)"
grep -q '^app-30 opus' "$CLAUDE_LOG" && fail "E: retried on Opus after a usage limit"
grep -c 'item-edit.*--single-select-option-id o1' "$GH_LOG" | grep -qx 1 || fail "E: ticket not set back to Ready: $(grep item-edit "$GH_LOG")"
grep -q 'issues/30/' "$GH_LOG" && fail "E: a usage limit was treated as a failure"
[ ! -e "$state/30.json" ] || fail "E: an outcome was recorded for a usage limit"
SENIOR_MODE_NOW=1800004000 once || fail "E: serve failed: $(cat "$work/out")"
[ ! -s "$CLAUDE_LOG" ] || fail "E: launched before the reset: $(cat "$CLAUDE_LOG")"
grep -q 'usage limit' "$work/out" || fail "E: the hold is not said: $(cat "$work/out")"
session 30-sonnet delivered pr
SENIOR_MODE_NOW=1800005001 once || fail "E: serve failed: $(cat "$work/out")"
started 30 || fail "E: not launched after the reset: $(cat "$CLAUDE_LOG")"
[ ! -e "$state/limit-until" ] || fail "E: the limit is not lifted"
# A clock time with a zone, and no time at all.
fresh
board 32
printf "You've hit your limit · resets 3pm (UTC)" >"$FIX/limit-msg"
session 32-sonnet "" "" limit
SENIOR_MODE_NOW=$(date -u -d '2026-11-23 10:00' +%s) once || fail "E: serve failed: $(cat "$work/out")"
[ "$(cat "$state/limit-until" 2>/dev/null)" = "$(date -u -d '2026-11-23 15:00' +%s)" ] || fail "E: 3pm UTC not read: $(cat "$state/limit-until" 2>&1)"
fresh
printf 'limit reached, try later' >"$FIX/limit-msg"
SENIOR_MODE_NOW=1800000000 once || fail "E: serve failed: $(cat "$work/out")"
[ "$(cat "$state/limit-until" 2>/dev/null)" = 1800003600 ] || fail "E: no reset time is not one hour: $(cat "$state/limit-until" 2>&1)"

# F: the circuit breaker pauses and does not exit; the cooldown or --resume lifts it.
config '{"parallel": 3, "maxConsecutiveFailures": 2, "escalate": false}' '{"breakerCooldown": 100}'
board 40 41
session 40-sonnet "failed: broke"
session 41-sonnet "failed: broke too"
fresh
SENIOR_MODE_NOW=1800000000 once || fail "F: serve exited with the breaker: $(cat "$work/out")"
[ "$(sed -n 1p "$state/paused" 2>/dev/null)" = 1800000100 ] || fail "F: no pause for the cooldown: $(cat "$state/paused" 2>&1)"
grep -q 'paused' "$work/out" || fail "F: the pause is not said: $(cat "$work/out")"
board 43
session 43-sonnet delivered pr
SENIOR_MODE_NOW=1800000050 once || fail "F: serve failed while paused: $(cat "$work/out")"
started 43 && fail "F: launched while paused"
grep -q 'circuit breaker' "$work/out" || fail "F: the hold is not said: $(cat "$work/out")"
(cd "$repo" && "$cli" serve --resume) >"$work/out" 2>&1 || fail "F: --resume failed: $(cat "$work/out")"
[ ! -e "$state/paused" ] || fail "F: --resume left the pause"
once || fail "F: serve failed: $(cat "$work/out")"
started 43 || fail "F: not launched after --resume: $(cat "$work/out")"
(cd "$repo" && "$cli" serve --resume) >"$work/out" 2>&1 || fail "F: --resume failed when not paused"
grep -q 'not paused' "$work/out" || fail "F: --resume when not paused: $(cat "$work/out")"
printf '%s\npaused by a test\n' 1800000100 >"$state/paused"
board 44
session 44-sonnet delivered pr
SENIOR_MODE_NOW=1800000101 once || fail "F: serve failed after the cooldown: $(cat "$work/out")"
started 44 || fail "F: not launched after the cooldown: $(cat "$work/out")"
[ ! -e "$state/paused" ] || fail "F: the pause outlived its cooldown"

# G: TERM stops the launching at once and gives the sessions the grace. A session that ends within it is read;
# one that does not is killed and its ticket labelled needs-human. A second serve is refused meanwhile.
config '{"parallel": 1}' '{"interval": 5, "grace": 30}'
board 50
session 50-sonnet delivered pr "slow"
fresh
: >"$GH_LOG"; : >"$CLAUDE_LOG"
(cd "$repo" && exec "$cli" serve) >"$work/out" 2>&1 &
pid=$!
for _ in $(seq 100); do started 50 && break; sleep 0.1; done
started 50 || fail "G: no session started: $(cat "$work/out")"
(cd "$repo" && "$cli" serve) >"$work/out2" 2>&1 && fail "G: a second serve was accepted"
grep -q 'already runs' "$work/out2" || fail "G: second serve not refused for that: $(cat "$work/out2")"
board 51
kill -TERM "$pid"
rc=0
wait "$pid" || rc=$?
[ "$rc" -eq 0 ] || fail "G: serve exited $rc on TERM: $(cat "$work/out")"
outcome_of 50 delivered G
started 51 && fail "G: launched after TERM"
[ ! -e "$state/serve.pid" ] || fail "G: pid file left"
config '{"parallel": 1}' '{"interval": 1, "grace": 1}'
board 52
session 52-sonnet "" "" hang
: >"$GH_LOG"; : >"$CLAUDE_LOG"
(cd "$repo" && exec "$cli" serve) >"$work/out" 2>&1 &
pid=$!
for _ in $(seq 100); do [ -f "$FIX/pids-52" ] && break; sleep 0.1; done
[ -f "$FIX/pids-52" ] || fail "G: the hanging session did not start: $(cat "$work/out")"
kill -TERM "$pid"
rc=0
wait "$pid" || rc=$?
[ "$rc" -eq 0 ] || fail "G: serve exited $rc after the grace: $(cat "$work/out")"
read -r -a pids <"$FIX/pids-52"
for p in "${pids[@]}"; do
  ! kill -0 "$p" 2>/dev/null || fail "G: the session is still running after the grace (pid $p)"
done
grep -q 'issues/52/labels' "$GH_LOG" || fail "G: no needs-human on the ticket killed at the end of the grace: $(cat "$GH_LOG")"
grep -q '^app-52 opus' "$CLAUDE_LOG" && fail "G: retried on Opus while stopping"

# J: alerts (#155). A failed ticket gets needs-human and a mention of the repository owner, and the webhook gets
# {event, repo, number, url, reason}; a ticket stopped for good (timeout) is a needs-human event; the breaker
# pause is an event without a number. A webhook that fails does not stop serve; no webhook, no curl.
: >"$CURL_LOG"
config '{"escalate": false}' '{}' '{"webhook": "https://hooks.example/senior"}'
board 60
session 60-sonnet "failed: it broke"
fresh
once || fail "J: serve failed: $(cat "$work/out")"
grep -q 'issues/60/labels.*needs-human' "$GH_LOG" || fail "J: failed ticket not labelled needs-human: $(cat "$GH_LOG")"
grep -q 'issues/60/comments.*@acme' "$GH_LOG" || fail "J: the owner is not mentioned: $(cat "$GH_LOG")"
jq -e '.event == "failed" and .repo == "acme/app" and .number == 60 and .url == "https://github.com/acme/app/issues/60"
  and (.reason | test("it broke"))' <<<"$(sed -n 's/.* -d //p' "$CURL_LOG" | head -n 1)" >/dev/null ||
  fail "J: webhook payload wrong: $(cat "$CURL_LOG")"
grep -q 'https://hooks.example/senior' "$CURL_LOG" || fail "J: webhook url not called: $(cat "$CURL_LOG")"
config '{"escalate": false}' '{}' '{"mention": "bob"}'
session 60-sonnet "failed: it broke"
: >"$CURL_LOG"
fresh
once || fail "J: serve failed: $(cat "$work/out")"
grep -q 'issues/60/comments.*@bob' "$GH_LOG" || fail "J: notify.mention not used: $(cat "$GH_LOG")"
[ ! -s "$CURL_LOG" ] || fail "J: curl called without notify.webhook: $(cat "$CURL_LOG")"
# SENIOR_MODE_NOTIFY_WEBHOOK (#522) gives the webhook out of the tracked config and wins over the key; empty, the
# key applies.
session 60-sonnet "failed: it broke"
: >"$CURL_LOG"
fresh
SENIOR_MODE_NOTIFY_WEBHOOK=https://env.example/alone once || fail "J: serve failed: $(cat "$work/out")"
grep -q 'https://env.example/alone' "$CURL_LOG" || fail "J: the variable alone is not used: $(cat "$CURL_LOG")"
config '{"escalate": false}' '{}' '{"webhook": "https://hooks.example/senior"}'
session 60-sonnet "failed: it broke"
: >"$CURL_LOG"
fresh
SENIOR_MODE_NOTIFY_WEBHOOK=https://env.example/wins once || fail "J: serve failed: $(cat "$work/out")"
grep -q 'https://env.example/wins' "$CURL_LOG" || fail "J: the variable does not win over notify.webhook: $(cat "$CURL_LOG")"
! grep -q 'hooks.example' "$CURL_LOG" || fail "J: notify.webhook called despite the variable: $(cat "$CURL_LOG")"
session 60-sonnet "failed: it broke"
: >"$CURL_LOG"
fresh
SENIOR_MODE_NOTIFY_WEBHOOK='' once || fail "J: serve failed: $(cat "$work/out")"
grep -q 'https://hooks.example/senior' "$CURL_LOG" || fail "J: an empty variable hides notify.webhook: $(cat "$CURL_LOG")"
# A timeout is a needs-human event; a failing webhook is said on stderr and serve goes on.
config '{"sessionTimeout": 1}' '{}' '{"webhook": "https://hooks.example/senior"}'
board 61
session 61-sonnet "" "" hang
touch "$FIX/curl-fails"
fresh
SENIOR_MODE_TIMEOUT_UNIT=1 once || fail "J: serve failed with a failing webhook: $(cat "$work/out")"
rm -f "$FIX/curl-fails"
grep -q '"event":"needs-human"' "$CURL_LOG" || fail "J: no needs-human event: $(cat "$CURL_LOG")"
grep -q 'webhook' "$work/out" || fail "J: the failing webhook is not said: $(cat "$work/out")"
# The breaker pause.
config '{"parallel": 3, "maxConsecutiveFailures": 2, "escalate": false}' '{"breakerCooldown": 100}' '{"webhook": "https://hooks.example/senior"}'
board 62 63
session 62-sonnet "failed: broke"
session 63-sonnet "failed: broke too"
: >"$CURL_LOG"
fresh
once || fail "J: serve failed: $(cat "$work/out")"
[ "$(grep -c '"event":"breaker"' "$CURL_LOG")" = 1 ] || fail "J: breaker event not sent once: $(cat "$CURL_LOG")"
grep '"event":"breaker"' "$CURL_LOG" | grep -q '"number":null' || fail "J: breaker event has a number: $(cat "$CURL_LOG")"
rm -f "$state/paused"

# K: the daily digest (#155): `status --since 24h` posted as a Project status update once a day.
: >"$FIX/status-updates"
config '{}' '{}' '{"digest": true}'
board 70
session 70-sonnet delivered pr
fresh
SENIOR_MODE_NOW=1800000000 once || fail "K: serve failed: $(cat "$work/out")"
[ "$(grep -c 'createProjectV2StatusUpdate' "$FIX/status-updates")" = 1 ] || fail "K: no status update posted: $(cat "$work/out")"
jq -e '.variables.project == "PVT_1" and (.variables.body | test("Done in the last 24h"))' "$FIX/status-updates" >/dev/null ||
  fail "K: status update wrong: $(cat "$FIX/status-updates")"
[ "$(cat "$state/digest" 2>/dev/null)" = 1800000000 ] || fail "K: the mark is not kept: $(cat "$state/digest" 2>&1)"
SENIOR_MODE_NOW=1800003600 once || fail "K: serve failed: $(cat "$work/out")"
[ "$(grep -c 'createProjectV2StatusUpdate' "$FIX/status-updates")" = 1 ] || fail "K: a second digest within the day"
SENIOR_MODE_NOW=1800086400 once || fail "K: serve failed: $(cat "$work/out")"
[ "$(grep -c 'createProjectV2StatusUpdate' "$FIX/status-updates")" = 2 ] || fail "K: no digest the next day: $(cat "$work/out")"
config '{}' '{}' '{"digest": false}'
rm -f "$state/digest"
SENIOR_MODE_NOW=1800200000 once || fail "K: serve failed: $(cat "$work/out")"
[ "$(grep -c 'createProjectV2StatusUpdate' "$FIX/status-updates")" = 2 ] || fail "K: digest posted with notify.digest false"

# L: ready by rule (#272). A framing pull request (docs/...) merged since the last poll gets `ready --pr <n>`;
# once a poll `ready` looks at the tickets agents filed. Pull requests merged before the last poll, or from another
# branch, are not read. The first poll only sets the mark.
criteria=$'## Acceptance criteria\n\n- Given a, when b, then c.\n'
# fitem <number> <status> <labels json> <body>: appends to $items a ticket with a Size, a Priority and Paths.
fitem() {
  items=$(jq -c --argjson n "$1" --arg s "$2" --argjson l "$3" --arg b "$4" '. + [{fieldValues: {nodes: [{name: $s, field: {name: "Status"}},
    {name: "P1 next", field: {name: "Priority"}}, {name: "S", field: {name: "Size"}}, {text: "docs/**", field: {name: "Paths"}}]},
    content: {authorAssociation: "OWNER", number: $n, title: "Ticket \($n)", url: "u", state: "OPEN", closedAt: null, body: $b,
      labels: {nodes: ($l | map({name: .}))}, milestone: null, blockedBy: {nodes: []}}}]' <<<"$items")
}
fboard() { jq -nc --argjson i "$items" '{data: {node: {items: {pageInfo: {hasNextPage: false}, nodes: $i}}}}' >"$FIX/board.json"; }
items="[]"
fitem 80 Backlog '[]' "$criteria"
fitem 81 Backlog '[]' "$criteria"$'\nfiled-by: agent\n'
fitem 82 Backlog '[]' "$criteria"
fitem 83 Backlog '[]' "no criteria here"
fboard
cat >"$FIX/merged-prs" <<'JSON'
[{"number": 300, "headRefName": "docs/wave", "mergedAt": "2027-01-15T07:59:00Z"},
 {"number": 301, "headRefName": "feat/x", "mergedAt": "2027-01-15T07:59:30Z"},
 {"number": 302, "headRefName": "docs/old", "mergedAt": "2027-01-15T07:00:00Z"}]
JSON
echo '{"state": "MERGED", "headRefName": "docs/wave", "body": "Framing: #80 #83"}' >"$FIX/pr-300.json"
config '{}'
fresh
once || fail "L: serve failed on the first poll: $(cat "$work/out")"
grep -q '^pr view' "$GH_LOG" && fail "L: a pull request was read on the first poll: $(cat "$GH_LOG")"
[ -f "$state/ready-last" ] || fail "L: no mark kept: $(ls "$state")"
grep -q 'issues/81' "$GH_LOG" || fail "L: ready was not run for the agent-filed tickets on the first poll: $(cat "$GH_LOG")"
fresh
echo 1799999900 >"$state/ready-last" 2>/dev/null || { mkdir -p "$state"; echo 1799999900 >"$state/ready-last"; }
once || fail "L: serve failed: $(cat "$work/out")"
grep -q '^pr view 300 ' "$GH_LOG" || fail "L: ready --pr 300 not run: $(cat "$GH_LOG")"
grep -q '^pr view 301 \|^pr view 302 ' "$GH_LOG" && fail "L: a pull request that is not a new framing one was read: $(cat "$GH_LOG")"
grep -q 'issues/80' "$GH_LOG" || fail "L: #80 not set Ready: $(cat "$GH_LOG")"
grep -q 'issues/81' "$GH_LOG" || fail "L: #81 (agent-filed) not set Ready: $(cat "$GH_LOG")"
grep -q 'issues/83/labels.*needs-human' "$GH_LOG" || fail "L: #83 not labelled needs-human: $(cat "$GH_LOG")"
grep -q 'issues/82' "$GH_LOG" && fail "L: #82 was touched"
[ "$(cat "$state/ready-last")" = 1800000000 ] || fail "L: mark not moved to now: $(cat "$state/ready-last")"
once || fail "L: serve failed: $(cat "$work/out")"
grep -q '^pr view' "$GH_LOG" && fail "L: a pull request was read twice: $(cat "$GH_LOG")"
# A ready that fails keeps the mark, so the pull request is read again at the next poll.
echo 1799999900 >"$state/ready-last"
rm -f "$FIX/pr-300.json"
once || fail "L: serve stopped on a failing ready: $(cat "$work/out")"
[ "$(cat "$state/ready-last")" = 1799999900 ] || fail "L: mark moved although ready failed: $(cat "$state/ready-last")"
echo '{"state": "MERGED", "headRefName": "docs/wave", "body": "Framing: #80 #83"}' >"$FIX/pr-300.json"
rm -f "$FIX/merged-prs"

# M: recovery (#272). After a crash, a ticket serve launched that is still In progress with no live session goes
# back to Ready (a second poll then picks it again), or gets needs-human once autonomy.maxConsecutiveFailures
# recoveries are used up. A live session, a ticket serve already read the end of (its record is newer than its
# script), a ticket that waits for a human and one serve never launched are left alone.
config '{"maxConsecutiveFailures": 3}'
items="[]"
for n in 90 91 92 93 94 95 96; do fitem "$n" "In progress" '[]' "x"; done
items=$(jq -c 'map(if .content.number == 93 then .content.labels.nodes = [{name: "needs-human"}] else . end)' <<<"$items")
fboard
fresh
mkdir -p "$state"
for n in 90 91 92 93 94 96; do echo '#!/usr/bin/env bash' >"$state/$n.sh"; done
echo 4999999 >"$state/90.pgid"
setsid sleep 60 &
live=$!
echo "$live" >"$state/91.pgid"
echo 4999998 >"$state/92.pgid"
echo '{}' >"$state/92.json"
touch -d '2 minutes ago' "$state/92.sh"
echo 4999997 >"$state/93.pgid"
echo 0 >"$state/94.exit"
echo 4999996 >"$state/96.pgid"
echo 2 >"$state/96.recovered"
once || fail "M: serve failed: $(cat "$work/out")"
kill "$live" 2>/dev/null
grep -q 'item-edit.*--single-select-option-id o1' "$GH_LOG" || fail "M: nothing set back to Ready: $(cat "$GH_LOG")"
[ "$(grep -c 'item-edit.*--single-select-option-id o1' "$GH_LOG")" = 2 ] || fail "M: not exactly #90 and #94 set Ready: $(grep item-edit "$GH_LOG")"
grep -q 'issues/90' "$GH_LOG" || fail "M: #90 (session gone) not recovered: $(cat "$GH_LOG")"
grep -q 'issues/94' "$GH_LOG" || fail "M: #94 (session ended unread) not recovered: $(cat "$GH_LOG")"
for n in 91 92 93 95; do grep -q "issues/$n/" "$GH_LOG" && fail "M: #$n was touched: $(cat "$GH_LOG")"; done
[ "$(cat "$state/90.recovered")" = 1 ] || fail "M: recovery not counted: $(cat "$state/90.recovered" 2>&1)"
grep -q 'issues/96/labels.*needs-human' "$GH_LOG" || fail "M: #96 not needs-human at the breaker count: $(cat "$GH_LOG")"
grep -q 'issues/96/comments.*needs a human' "$GH_LOG" || fail "M: #96 not commented: $(cat "$GH_LOG")"
grep -q 'recover' "$work/out" || fail "M: recovery not said: $(cat "$work/out")"

# N: a batch session lost in a crash puts every ticket of the batch back to Ready (#263).
config '{"maxConsecutiveFailures": 3}'
items="[]"
for n in 97 98; do fitem "$n" "In progress" '[]' "x"; done
fboard
fresh
mkdir -p "$state"
echo '#!/usr/bin/env bash' >"$state/97.sh"
echo 4999995 >"$state/97.pgid"
echo "97 98" >"$state/97.batch"
once || fail "N: serve failed: $(cat "$work/out")"
[ "$(grep -c 'item-edit.*--single-select-option-id o1' "$GH_LOG")" = 2 ] || fail "N: #97 and #98 not both set Ready: $(grep item-edit "$GH_LOG")"
grep -q '#98 was In progress' "$work/out" || fail "N: #98 of the batch not recovered: $(cat "$work/out")"

# H: install and uninstall of the systemd user unit.
config '{}' '{"grace": 120}'
unit=$XDG_CONFIG_HOME/systemd/user/senior-mode-serve.service
: >"$SYS_LOG"
(cd "$repo" && "$cli" serve --install) >"$work/out" 2>&1 || fail "H: install failed: $(cat "$work/out")"
[ -f "$unit" ] || fail "H: no unit file at $unit"
grep -qx "WorkingDirectory=$repo" "$unit" || fail "H: the unit does not run in the repository: $(cat "$unit" 2>&1)"
grep -q '^ExecStart=/bin/bash -lc "exec '"'"'.*bin/senior-mode'"'"' serve"$' "$unit" || fail "H: ExecStart wrong: $(cat "$unit" 2>&1)"
grep -qx 'Restart=on-failure' "$unit" || fail "H: no restart on failure"
grep -qx 'KillMode=mixed' "$unit" || fail "H: sessions would get the TERM too"
grep -qx 'TimeoutStopSec=180' "$unit" || fail "H: stop timeout is not the grace plus a minute: $(cat "$unit")"
grep -qx 'WantedBy=default.target' "$unit" || fail "H: no [Install] target"
grep -qx -- '--user enable --now senior-mode-serve.service' "$SYS_LOG" || fail "H: not enabled: $(cat "$SYS_LOG")"
grep -q 'enable-linger tester' "$work/out" || fail "H: no linger warning: $(cat "$work/out")"
(cd "$repo" && "$cli" serve --install) >"$work/out" 2>&1 || fail "H: second install failed: $(cat "$work/out")"
other="$work/other"
git init -q -b main "$other"
mkdir -p "$other/.claude"
cp "$repo/.claude/senior-mode.json" "$other/.claude/"
(cd "$other" && "$cli" serve --install) >"$work/out" 2>&1 && fail "H: a second repository took the unit"
grep -q "already serves $repo" "$work/out" || fail "H: the conflict is not said: $(cat "$work/out")"
: >"$SYS_LOG"
(cd "$repo" && "$cli" serve --uninstall) >"$work/out" 2>&1 || fail "H: uninstall failed: $(cat "$work/out")"
[ ! -e "$unit" ] || fail "H: unit file still there"
grep -qx -- '--user disable --now senior-mode-serve.service' "$SYS_LOG" || fail "H: not disabled: $(cat "$SYS_LOG")"
(cd "$repo" && "$cli" serve --uninstall) >"$work/out" 2>&1 || fail "H: second uninstall failed"
grep -q 'Nothing installed' "$work/out" || fail "H: second uninstall did not say so: $(cat "$work/out")"
touch "$FIX/no-systemd"
(cd "$repo" && "$cli" serve --install) >"$work/out" 2>&1 && fail "H: installed without systemd"
grep -q 'systemd user services' "$work/out" || fail "H: no systemd not explained: $(cat "$work/out")"
rm -f "$FIX/no-systemd"

# J: Ready S tickets whose Paths overlap are one session and one slot (#263); what runs next to it overlaps nothing.
paths_of() { # <ticket> <globs>: Paths of a ticket of the board
  jq -c --argjson n "$1" --arg p "$2" '(.data.node.items.nodes[] | select(.content.number == $n) | .fieldValues.nodes)
    += [{text: $p, field: {name: "Paths"}}]' "$FIX/board.json" >"$work/b" && mv "$work/b" "$FIX/board.json"
}
saved_fields=$fields
fields=$(jq '. + {Paths: {id: "F_PA"}}' <<<"$fields")
config '{"parallel": 2}'
board 21 22 23 24
paths_of 21 'src/a/**'
paths_of 22 'src/a/x.ts'
paths_of 23 'docs/guide/**'
paths_of 24 'docs/guide/y.md'
jq -c '(.data.node.items.nodes[] | select(.content.number == 24) | .fieldValues.nodes[] | select(.field.name == "Size") | .name) = "M"' \
  "$FIX/board.json" >"$work/b" && mv "$work/b" "$FIX/board.json"
session 21-sonnet "" pr
printf '#21 delivered\n#22 delivered\n' >"$FIX/outcome-21"
session 23-sonnet delivered pr
session 24-sonnet delivered pr
fresh
once || fail "J: serve failed: $(cat "$work/out")"
started 21 || fail "J: no session for the batch of #21 and #22: $(cat "$CLAUDE_LOG")"
started 22 && fail "J: a session of its own for #22, a ticket of the batch"
started 23 || fail "J: the batch is one slot, #23 should have started: $(cat "$CLAUDE_LOG")"
started 24 && fail "J: #24 overlaps #23 and started with it"
grep -c 'item-edit.*--single-select-option-id o2' "$GH_LOG" | grep -qx 3 || fail "J: #21, #22 and #23 not all In progress"
for n in 21 22; do
  grep -q "Status set to In review: #$n " "$work/out" || fail "J: #$n of the batch not set In review: $(cat "$work/out")"
done
grep -c 'item-edit.*--single-select-option-id o3' "$GH_LOG" | grep -qx 3 || fail "J: the delivered tickets are not In review"
outcome_of 21 delivered J
outcome_of 22 delivered J
# #305: the batch session is told what a ticket session of serve is told: no review step, one delivered line per ticket.
grep -q 'SENIOR_MODE_ROLE=ticket' "$state/21.prompt" || fail "J: the batch prompt does not name the role: $(cat "$state/21.prompt")"
grep -qi 'at most 2 fix rounds\|reviewer agent reviews the pull request' "$state/21.prompt" && fail "J: the batch session is asked to review"
grep -q 'you never set it' "$state/21.prompt" || fail "J: the batch prompt does not forbid senior-mode/review"
grep -q 'delivered.*senior-mode/ci and senior-mode/security' "$state/21.prompt" || fail "J: the batch prompt does not end at ci and security"
grep -q '#22 ("Ticket 22")' "$state/21.prompt" || fail "J: the batch prompt does not list #22"
fields=$saved_fields

# Z: a ticket launched in a poll reserves its Paths for the rest of that poll (#344), also when the config of the
# repository does not list the Paths field (a board carries Paths its config does not know): of two overlapping
# tickets that are not batched (#62 is not an S), only the first starts, next to the disjoint one.
size_of() { # <ticket> <size>: Size of a ticket of the board
  jq -c --argjson n "$1" --arg s "$2" '(.data.node.items.nodes[] | select(.content.number == $n) | .fieldValues.nodes[]
    | select(.field.name == "Size") | .name) = $s' "$FIX/board.json" >"$work/b" && mv "$work/b" "$FIX/board.json"
}
config '{"parallel": 3}'
board 61 62 63
paths_of 61 'src/lib/math.ts,src/lib/math.test.ts'
paths_of 62 'src/lib/math.ts,src/lib/math.test.ts'
paths_of 63 'docs/guide/**'
size_of 62 XS
session 61-sonnet delivered pr
session 62-sonnet delivered pr
session 63-sonnet delivered pr
fresh
once || fail "Z: serve failed: $(cat "$work/out")"
started 61 || fail "Z: no session for #61: $(cat "$CLAUDE_LOG")"
started 62 && fail "Z: #62 started in the poll of #61, with the same Paths"
started 63 || fail "Z: the disjoint #63 did not start: $(cat "$CLAUDE_LOG")"
[ "$(grep -c '^app-' "$CLAUDE_LOG")" -eq 2 ] || fail "Z: not exactly two sessions: $(cat "$CLAUDE_LOG")"

# Y2: a gh call that hangs after a network blip does not stall serve (#382): it is cut, retried, and the poll goes on.
config '{}'
board 64
session 64-sonnet delivered pr
touch "$FIX/gh-hang"
fresh
start=$SECONDS
SENIOR_MODE_GH_TIMEOUT=1 once || fail "Y2: serve failed: $(cat "$work/out")"
rm -f "$FIX/gh-hang"
[ $((SECONDS - start)) -lt 60 ] || fail "Y2: the hanging gh call was not cut: $((SECONDS - start))s"
grep -q 'cannot read the open pull requests; trying again at the next poll' "$work/out" || fail "Y2: not said: $(cat "$work/out")"
started 64 || fail "Y2: the poll did not go on to launch #64: $(cat "$work/out")"

# AA: a session that ends on a transient error (#377, #334) is resumed on the same model after a backoff, with no
# failure counted, no escalation, no needs-human and no launch against sessionsPerHour; nothing else starts meanwhile.
config '{"maxConsecutiveFailures": 1}'
for msg in "Claude Code is still loading your organization's settings. Your organization requires them before a session can start." \
  'API Error: 529 {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}' \
  'getaddrinfo EAI_AGAIN api.anthropic.com' 'API Error: 503 Service Unavailable'; do
  board 70 71
  rm -f "$FIX"/flaky-done-*
  session 70-sonnet delivered pr "flaky:$msg"
  session 71-sonnet delivered pr
  fresh
  SENIOR_MODE_NOW=1800000000 once || fail "AA: serve failed: $(cat "$work/out")"
  grep -q '^app-70 opus' "$CLAUDE_LOG" && fail "AA: escalated to Opus after a transient end ($msg)"
  [ ! -e "$state/70.json" ] || fail "AA: an outcome was recorded for a transient end: $(cat "$state/70.json")"
  [ ! -e "$state/paused" ] || fail "AA: a transient end counted as a failure ($msg)"
  grep -q 'issues/70/' "$GH_LOG" && fail "AA: a transient end made the ticket needs-human"
  grep -q 'transient error' "$work/out" || fail "AA: not said ($msg): $(cat "$work/out")"
  [ "$(cat "$state/70.retry" 2>/dev/null)" = 1800000030 ] || fail "AA: no backoff of 30s: $(cat "$state/70.retry" 2>&1)"
  [ "$(cat "$state/70.model" 2>/dev/null)" = sonnet ] || fail "AA: the model is not kept"
  [ "$(awk 'END { print NR }' "$state/launches")" -eq 0 ] || fail "AA: the dead launch is counted: $(cat "$state/launches")"
  grep -c 'item-edit.*--single-select-option-id o1' "$GH_LOG" | grep -qx 1 || fail "AA: #70 not back to Ready: $(grep item-edit "$GH_LOG")"
  # In the backoff nothing starts, #71 included; after it #70 resumes on Sonnet.
  SENIOR_MODE_NOW=1800000010 once || fail "AA: serve failed: $(cat "$work/out")"
  [ ! -s "$CLAUDE_LOG" ] || fail "AA: a session started during the backoff: $(cat "$CLAUDE_LOG")"
  grep -q 'backing off' "$work/out" || fail "AA: the backoff is not said: $(cat "$work/out")"
  SENIOR_MODE_NOW=1800000031 once || fail "AA: serve failed: $(cat "$work/out")"
  grep -q '^app-70 sonnet' "$CLAUDE_LOG" || fail "AA: #70 not resumed on Sonnet: $(cat "$CLAUDE_LOG")"
  outcome_of 70 delivered AA
  [ ! -e "$state/70.retry" ] || fail "AA: the backoff is not cleared by the delivery"
done
# The backoff doubles at each end in a row; the seventh is a ticket's.
board 70
rm -f "$FIX"/flaky-done-*
session 70-sonnet delivered pr "flaky:getaddrinfo EAI_AGAIN api.anthropic.com"
fresh
mkdir -p "$state"
echo 2 >"$state/70.transient"
SENIOR_MODE_NOW=1800000000 once || fail "AA: serve failed: $(cat "$work/out")"
[ "$(cat "$state/70.retry" 2>/dev/null)" = 1800000120 ] || fail "AA: the third end in a row is not 120s: $(cat "$state/70.retry" 2>&1)"
grep -q '3 transient ends in a row' "$work/out" || fail "AA: the third end is not said: $(cat "$work/out")"
rm -f "$FIX"/flaky-done-*
fresh
mkdir -p "$state"
echo 6 >"$state/70.transient"
SENIOR_MODE_NOW=1800000000 once || fail "AA: serve failed: $(cat "$work/out")"
grep -q '^app-70 opus' "$CLAUDE_LOG" || fail "AA: the seventh transient end in a row is not a ticket's: $(cat "$CLAUDE_LOG")"

# AB: an environment end pauses the whole daemon, with the diagnosis, no failure, no needs-human; a probe that is
# green lifts it by itself, with the backoff of the probes in between; --resume lifts it by hand.
config '{"maxConsecutiveFailures": 1}' '{}' '{"webhook": "https://hooks.example/h"}'
board 72 73
session 72-sonnet "failed: environment: npm install failed: ENOSPC: no space left on device"
session 73-sonnet delivered pr
fresh
: >"$FIX/status-updates"
SENIOR_MODE_DISK_FREE_MB=10 SENIOR_MODE_NOW=1800000000 once || fail "AB: serve failed: $(cat "$work/out")"
grep -q '^app-72 opus' "$CLAUDE_LOG" && fail "AB: an environment end was escalated"
grep -q 'paused, environment problem (disk): #72: .*no space left' "$work/out" || fail "AB: no diagnosis in the log: $(cat "$work/out")"
[ "$(sed -n 2p "$state/environment" 2>/dev/null)" = disk ] || fail "AB: no environment state: $(cat "$state/environment" 2>&1)"
[ ! -e "$state/paused" ] && [ ! -e "$state/72.json" ] || fail "AB: an environment end counted as a failure"
grep -q 'issues/72/' "$GH_LOG" && fail "AB: an environment end made the ticket needs-human"
grep -q AT_RISK "$FIX/status-updates" || fail "AB: the pause is not in the Project status: $(cat "$FIX/status-updates")"
grep -q 'environment' "$CURL_LOG" || fail "AB: the webhook did not get the pause: $(cat "$CURL_LOG" 2>&1)"
grep -c 'item-edit.*--single-select-option-id o1' "$GH_LOG" | grep -qx 1 || fail "AB: #72 not back to Ready"
# Paused: nothing starts, the probe is red (no room) and the next one is later.
SENIOR_MODE_DISK_FREE_MB=10 SENIOR_MODE_NOW=1800000030 once || fail "AB: serve failed: $(cat "$work/out")"
[ ! -s "$CLAUDE_LOG" ] || fail "AB: a session started while paused: $(cat "$CLAUDE_LOG")"
grep -q 'environment problem (disk)' "$work/out" || fail "AB: the hold is not said: $(cat "$work/out")"
SENIOR_MODE_DISK_FREE_MB=10 SENIOR_MODE_NOW=1800000061 once || fail "AB: serve failed: $(cat "$work/out")"
grep -q 'the probe is red' "$work/out" || fail "AB: a red probe is not said: $(cat "$work/out")"
[ "$(sed -n 1p "$state/environment")" = 1800000181 ] || fail "AB: the next probe is not 120s later: $(cat "$state/environment")"
[ ! -s "$CLAUDE_LOG" ] || fail "AB: a session started on a red probe"
SENIOR_MODE_DISK_FREE_MB=100000 SENIOR_MODE_NOW=1800000100 once || fail "AB: serve failed: $(cat "$work/out")"
[ -e "$state/environment" ] || fail "AB: probed before its time"
session 72-sonnet delivered pr
SENIOR_MODE_DISK_FREE_MB=100000 SENIOR_MODE_NOW=1800000200 once || fail "AB: serve failed: $(cat "$work/out")"
grep -q 'environment is healthy again' "$work/out" || fail "AB: not resumed on a green probe: $(cat "$work/out")"
[ ! -e "$state/environment" ] || fail "AB: the pause is not lifted"
started 72 || fail "AB: #72 not started after the pause: $(cat "$CLAUDE_LOG")"
grep -q ON_TRACK "$FIX/status-updates" || fail "AB: the resume is not in the Project status"
# gh not signed in: the probe is gh's; --resume lifts it by hand.
board 74
session 74-sonnet "failed: environment: HTTP 401 Bad credentials"
fresh
SENIOR_MODE_NOW=1800000000 once || fail "AB: serve failed: $(cat "$work/out")"
[ "$(sed -n 2p "$state/environment" 2>/dev/null)" = gh-auth ] || fail "AB: gh auth not recognised: $(cat "$state/environment" 2>&1)"
touch "$FIX/gh-auth-bad"
SENIOR_MODE_NOW=1800000061 once || fail "AB: serve failed: $(cat "$work/out")"
grep -q 'the probe is red' "$work/out" || fail "AB: gh auth probe not red: $(cat "$work/out")"
rm -f "$FIX/gh-auth-bad"
(cd "$repo" && "$cli" serve --resume) >"$work/out" 2>&1 || fail "AB: --resume failed: $(cat "$work/out")"
[ ! -e "$state/environment" ] || fail "AB: --resume left the environment pause"

# AC: the breaker counts ticket failures only and its pause doubles at each pause with no delivery in between (#377).
config '{"parallel": 1, "maxConsecutiveFailures": 1, "escalate": false}' '{"breakerCooldown": 100}'
board 75
session 75-sonnet "failed: broke"
fresh
SENIOR_MODE_NOW=1800000000 once || fail "AC: serve failed: $(cat "$work/out")"
[ "$(sed -n 1p "$state/paused" 2>/dev/null)" = 1800000100 ] || fail "AC: first pause is not 100s: $(cat "$state/paused" 2>&1)"
rm -f "$state/paused"
SENIOR_MODE_NOW=1800000000 once || fail "AC: serve failed: $(cat "$work/out")"
[ "$(sed -n 1p "$state/paused" 2>/dev/null)" = 1800000200 ] || fail "AC: second pause is not 200s: $(cat "$state/paused" 2>&1)"
rm -f "$state/paused"
session 75-sonnet delivered pr
SENIOR_MODE_NOW=1800000000 once || fail "AC: serve failed: $(cat "$work/out")"
[ ! -e "$state/trips" ] || fail "AC: a delivery does not reset the pauses: $(cat "$state/trips")"

# I: options and config are checked.
(cd "$repo" && "$cli" serve --bogus) >"$work/out" 2>&1 && fail "I: an unknown option was accepted"
grep -q 'usage:.*serve' "$work/out" || fail "I: usage does not name serve: $(cat "$work/out")"
config '{}' '{"interval": 0}'
# With a last valid config the daemon keeps it (test-config-layers.sh); with none, the keys stand and serve refuses.
rm -f "$repo"/.git/senior-mode/config.valid.json "$repo"/.git/senior-mode/config.cache.json
once && fail "I: serve.interval 0 accepted"
grep -q 'serve.interval must be' "$work/out" || fail "I: bad interval not explained: $(cat "$work/out")"
echo '{}' >"$repo/.claude/senior-mode.json"
[ "$(cd "$repo" && "$cli" config get serve.interval)" = 60 ] &&
  [ "$(cd "$repo" && "$cli" config get serve.grace)" = 600 ] &&
  [ "$(cd "$repo" && "$cli" config get serve.breakerCooldown)" = 300 ] &&
  [ "$(cd "$repo" && "$cli" config get autonomy.sessionsPerHour)" = 0 ] &&
  [ "$(cd "$repo" && "$cli" config get autonomy.ticketsPerHour)" = 6 ] &&
  [ "$(cd "$repo" && "$cli" config get autonomy.minMemoryMB)" = 1024 ] &&
  [ "$(cd "$repo" && "$cli" config get notify.digest)" = true ] &&
  [ -z "$(cd "$repo" && "$cli" config get notify.mention)" ] &&
  [ -z "$(cd "$repo" && "$cli" config get notify.webhook)" ] || fail "I: config defaults wrong"


# Helpers for the pull request cases: the remote has real branches (a scratch clone makes them), gh serves the
# open pull requests, their merge state and their statuses from $FIX.
scratch=$work/scratch
git clone -q "$work/github.com/acme/app.git" "$scratch"
gitx() { git -C "$scratch" -c user.name=t -c user.email=t@t "$@"; }
# mkbranch <branch> <file>: a commit adding <file> on a branch of the remote, from its main; prints the sha.
mkbranch() {
  gitx fetch -q origin
  gitx checkout -q -B "$1" origin/main
  echo "$1" >"$scratch/$2"
  gitx add "$2"
  gitx commit -q -m "feat: $2"
  gitx push -q -f origin "$1"
  gitx rev-parse HEAD
}
# mkrebased <branch> <old sha> [<file>]: the patch of <old> on the main of the remote, as the server's rebase
# makes it; with <file>, the patch changed. On the branch rebased-<branch>. Prints the sha.
mkrebased() {
  gitx fetch -q origin
  gitx checkout -q -B "rebased-$1" origin/main
  gitx cherry-pick "$2" >/dev/null
  if [ -n "${3:-}" ]; then
    echo changed >"$scratch/$3"
    gitx add "$3"
    gitx commit -q --amend --no-edit
  fi
  gitx push -q -f origin "rebased-$1"
  gitx rev-parse HEAD
}
# boardx <n>:<Status>:<Size>:<Priority>[:<label>]...: the tickets of the board.
boardx() {
  local items="[]" spec n st sz pr lb
  for spec in "$@"; do
    IFS=: read -r n st sz pr lb <<<"$spec"
    items=$(jq -c --argjson n "$n" --arg st "$st" --arg sz "$sz" --arg pr "$pr" --arg lb "$lb" '. + [{fieldValues: {nodes:
      [{name: $st, field: {name: "Status"}}, {name: $pr, field: {name: "Priority"}}, {name: $sz, field: {name: "Size"}}]},
      content: {authorAssociation: "OWNER", number: $n, title: "Ticket \($n)", url: "u", state: "OPEN", closedAt: null,
        labels: {nodes: (if $lb == "" then [] else [{name: $lb}] end)}, milestone: null, blockedBy: {nodes: []}}}]' <<<"$items")
  done
  jq -nc --argjson i "$items" '{data: {node: {items: {pageInfo: {hasNextPage: false}, nodes: $i}}}}' >"$FIX/board.json"
}
prs_reset() { rm -rf "$FIX/open.d" "$FIX/open-prs.json" "$FIX"/pull-*.json "$FIX"/state-* "$FIX"/status-* "$FIX"/closed-* "$FIX/allow-auto" "$FIX/auto-queues" "$FIX/no-auto" "$FIX/merge-fails" "$FIX/update-conflict"; }
# pr <number> <branch> <sha> <mergeable_state> [<label>]: an open pull request.
pr() {
  mkdir -p "$FIX/open.d"
  jq -nc --argjson p "$1" --arg b "$2" --arg s "$3" --arg m "$4" --arg l "${5:-}" '{number: $p, draft: false, author_association: "OWNER", head: {ref: $b, sha: $s},
    mergeable_state: $m, labels: (if $l == "" then [] else [{name: $l}] end), body: ($ENV.PRBODY // "")}' >"$FIX/open.d/$1.json"
  cp "$FIX/open.d/$1.json" "$FIX/pull-$1.json"
  jq -s '.' "$FIX"/open.d/*.json >"$FIX/open-prs.json"
}
# st <sha> <context state>...: the statuses of a commit.
st() { local sha=$1; shift; printf '%s\n' "$@" >"$FIX/status-$sha"; }
green() { st "$1" "senior-mode/ci success" "senior-mode/review success" "senior-mode/security success"; }
status_of() { sed -n "s#^$2 ##p" "$FIX/status-$1" | tail -n 1; }
merged() { echo MERGED >"$FIX/state-$1"; jq -c --argjson n "$1" 'map(select(.number != $n))' "$FIX/open-prs.json" >"$FIX/open-prs.tmp" && mv "$FIX/open-prs.tmp" "$FIX/open-prs.json"; }
done_count() { grep -c 'item-edit.*--single-select-option-id o4' "$GH_LOG" || true; }

# R: a ticket session has its role and a prompt that leaves the review to the reviewer.
config '{}'
board 60
session 60-sonnet delivered pr
fresh
once || fail "R: serve failed: $(cat "$work/out")"
grep -q '^app-60 sonnet run=1 role=ticket$' "$CLAUDE_LOG" || fail "R: the ticket session has no role: $(cat "$CLAUDE_LOG")"
grep -q 'SENIOR_MODE_ROLE=ticket' "$state/60.prompt" || fail "R: the prompt does not name the role"
grep -qi 'at most 2 fix rounds\|reviewer agent reviews the pull request' "$state/60.prompt" && fail "R: the ticket session is still asked to review"
grep -q 'never set it' "$state/60.prompt" || fail "R: the prompt does not forbid senior-mode/review"

# S: In review with CI success and no review status: a reviewer session on Opus, role reviewer, in a worktree of
# the head that is gone afterwards. Nothing starts without CI success, with a review status, or with needs-human.
config '{}'
sha=$(mkbranch feat/61-x f61.txt)
boardx "61:In review:S:P1 next"
prs_reset
pr 161 feat/61-x "$sha" clean
st "$sha" "senior-mode/ci success"
session 61-opus-reviewer "reviewed: success" "" "" review:success
fresh
once || fail "S: serve failed: $(cat "$work/out")"
grep -q '^app-review-61 opus run=1 role=reviewer$' "$CLAUDE_LOG" || fail "S: no reviewer session: $(cat "$CLAUDE_LOG")"
[ "$(status_of "$sha" senior-mode/review)" = success ] || fail "S: the reviewer's status is missing"
jq -se 'any(.[]; .ticket == 61 and .role == "reviewer" and .model == "claude-opus" and .output == 2)' "$repo/.git/senior-mode/usage.jsonl" >/dev/null ||
  fail "S: the reviewer's tokens are not in the ledger: $(cat "$repo/.git/senior-mode/usage.jsonl" 2>&1)"
[ -z "$(find "$XDG_DATA_HOME/senior-mode/worktrees" -name review-61 2>/dev/null)" ] || fail "S: the review worktree is left"
grep -q 'reviewed: senior-mode/review is success' "$work/out" || fail "S: the review is not said: $(cat "$work/out")"
st "$sha" "senior-mode/ci pending"
once || fail "S: serve failed: $(cat "$work/out")"
[ ! -s "$CLAUDE_LOG" ] || fail "S: reviewed without CI success: $(cat "$CLAUDE_LOG")"
st "$sha" "senior-mode/ci success" "senior-mode/review pending"
once || fail "S: serve failed: $(cat "$work/out")"
[ ! -s "$CLAUDE_LOG" ] || fail "S: reviewed again with a review status: $(cat "$CLAUDE_LOG")"
st "$sha" "senior-mode/ci success"
pr 161 feat/61-x "$sha" clean needs-human
once || fail "S: serve failed: $(cat "$work/out")"
[ ! -s "$CLAUDE_LOG" ] || fail "S: reviewed a needs-human pull request: $(cat "$CLAUDE_LOG")"
pr 161 feat/61-x "$sha" clean
boardx "61:In review:S:P1 next:needs-human"
once || fail "S: serve failed: $(cat "$work/out")"
[ ! -s "$CLAUDE_LOG" ] || fail "S: reviewed a needs-human ticket: $(cat "$CLAUDE_LOG")"
boardx "61:In review:S:P1 next"
session 61-opus-reviewer "" "" ""
once || fail "S: serve failed: $(cat "$work/out")"
grep -q 'issues/161/labels' "$GH_LOG" || fail "S: a reviewer that sets no status leaves the pull request unlabelled: $(cat "$GH_LOG")"
grep -q 'issues/61/labels' "$GH_LOG" || fail "S: its ticket is not labelled either"

# T: changes requested: the ticket session resumes on the same branch with the findings, twice; then needs-human.
boardx "62:In review:S:P1 next"
prs_reset
sha=$(mkbranch feat/62-x f62.txt)
pr 162 feat/62-x "$sha" clean
st "$sha" "senior-mode/ci success" "senior-mode/review failure"
session 62-sonnet-ticket delivered pr
fresh
once || fail "T: serve failed: $(cat "$work/out")"
grep -q '^app-62 sonnet run=1 role=ticket$' "$CLAUDE_LOG" || fail "T: the ticket session did not resume: $(cat "$CLAUDE_LOG")"
grep -q 'round 1 of 2' "$state/62.prompt" || fail "T: the prompt does not say the round: $(cat "$state/62.prompt")"
grep -q 'gh pr view 162 --comments' "$state/62.prompt" || fail "T: the findings are not pointed to"
[ "$(cat "$state/rounds-62")" = 1 ] || fail "T: round not counted"
once || fail "T: serve failed: $(cat "$work/out")"
grep -q 'round 2 of 2' "$state/62.prompt" || fail "T: second round missing"
once || fail "T: serve failed: $(cat "$work/out")"
[ ! -s "$CLAUDE_LOG" ] || fail "T: a third round started: $(cat "$CLAUDE_LOG")"
grep -q 'issues/162/labels' "$GH_LOG" || fail "T: no needs-human after 2 rounds: $(cat "$GH_LOG")"
grep -q 'issues/62/labels' "$GH_LOG" || fail "T: no needs-human after 2 rounds: $(cat "$GH_LOG")"
grep -q 'Waiting for a human.*pull request #162.*2 fix rounds' "$work/out" || fail "T: not reported: $(cat "$work/out")"

# U: an M ticket: the test-author session first, then red-tests record, then the ticket session on the same branch.
boardx "63:Ready:M:P1 next" "64:Ready:M:P1 next"
prs_reset
session 63-sonnet-test-author delivered "" "" commit
session 63-sonnet-ticket delivered pr
session 64-sonnet-test-author "failed: criterion 2 cannot be tested"
config '{"parallel": 2}'
fresh
once || fail "U: serve failed: $(cat "$work/out")"
first=$(grep -n '^app-63 sonnet run=1 role=test-author$' "$CLAUDE_LOG" | cut -d: -f1)
second=$(grep -n '^app-63 sonnet run=1 role=ticket$' "$CLAUDE_LOG" | cut -d: -f1)
{ [ -n "$first" ] && [ -n "$second" ] && [ "$first" -lt "$second" ]; } || fail "U: test-author then ticket expected: $(cat "$CLAUDE_LOG")"
grep -qx 'tests-63.txt' "$repo/.git/senior-mode/runs/63/red-tests" || fail "U: the red tests are not recorded: $(cat "$repo/.git/senior-mode/runs/63/red-tests" 2>&1)"
grep -q 'written and committed already' "$state/63.prompt" || fail "U: the ticket prompt does not tell about the red tests"
grep -q '^app-64 sonnet run=1 role=ticket$' "$CLAUDE_LOG" && fail "U: a ticket session after a failed test-author"
outcome_of 64 failed M
grep -c 'item-edit.*--single-select-option-id o0' "$GH_LOG" | grep -qx 1 || fail "U: #64 is not back in Backlog: $(grep item-edit "$GH_LOG")"
boardx "63:Ready:M:P1 next"
rm -f "$FIX/pulls-63"
fresh
once || fail "U: serve failed: $(cat "$work/out")"
grep -q '^app-63 sonnet run=1 role=test-author$' "$CLAUDE_LOG" && fail "U: the red tests are recorded, no test-author again: $(cat "$CLAUDE_LOG")"
grep -q '^app-63 sonnet run=1 role=ticket$' "$CLAUDE_LOG" || fail "U: no ticket session"
config '{}'

# V: the usage limit holds the reviewers too, without a failure; the pull request is reviewed after the reset. A
# merge needs no session: an approved pull request merges during the hold.
boardx "65:In review:S:P1 next" "75:In review:S:P1 next"
prs_reset
sha=$(mkbranch feat/65-x f65.txt)
sha75=$(mkbranch feat/75-x f75.txt)
pr 165 feat/65-x "$sha" clean
pr 175 feat/75-x "$sha75" clean
st "$sha" "senior-mode/ci success"
green "$sha75"
printf 'Claude AI usage limit reached|1800005000' >"$FIX/limit-msg"
session 65-opus-reviewer "" "" limit
fresh
once || fail "V: serve failed: $(cat "$work/out")"
[ "$(cat "$state/limit-until" 2>/dev/null)" = 1800005000 ] || fail "V: reset time not kept: $(cat "$state/limit-until" 2>&1)"
grep -q 'issues/65/' "$GH_LOG" && fail "V: a usage limit labelled the ticket: $(grep issues/65/ "$GH_LOG")"
grep -q 'item-edit' "$GH_LOG" && ! grep -q -- '--single-select-option-id o4' "$GH_LOG" && fail "V: a status was changed for a reviewer that hit the limit"
[ -z "$(status_of "$sha" senior-mode/review)" ] || fail "V: a review status was set"
session 65-opus-reviewer "reviewed: success" "" "" review:success
pr 175 feat/75-x "$sha75" clean
SENIOR_MODE_NOW=1800004000 once || fail "V: serve failed: $(cat "$work/out")"
[ ! -s "$CLAUDE_LOG" ] || fail "V: a reviewer started before the reset: $(cat "$CLAUDE_LOG")"
grep -q 'usage limit' "$work/out" || fail "V: the hold is not said"
grep -q "^pr merge 175 --rebase --match-head-commit $sha75 -R acme/app" "$GH_LOG" || fail "V: no merge during the hold: $(grep '^pr ' "$GH_LOG")"
SENIOR_MODE_NOW=1800005001 once || fail "V: serve failed: $(cat "$work/out")"
grep -q '^app-review-65 opus run=1 role=reviewer$' "$CLAUDE_LOG" || fail "V: not reviewed after the reset: $(cat "$CLAUDE_LOG")"

# W: the integrator pass: at most one merge per poll, by priority, --match-head-commit, merged read back then Done.
boardx "66:In review:S:P1 next" "67:In review:S:P0 now"
prs_reset
sha66=$(mkbranch feat/66-x f66.txt)
sha67=$(mkbranch feat/67-x f67.txt)
pr 166 feat/66-x "$sha66" clean
pr 167 feat/67-x "$sha67" clean
green "$sha66"
green "$sha67"
fresh
once || fail "W: serve failed: $(cat "$work/out")"
grep -q "^pr merge 167 --rebase --match-head-commit $sha67 -R acme/app$" "$GH_LOG" || fail "W: #67 (P0) not merged first: $(grep '^pr ' "$GH_LOG")"
grep -q '^pr merge 166' "$GH_LOG" && fail "W: two merges in one poll"
grep -q 'Merged: #67' "$work/out" || fail "W: the merge is not reported: $(cat "$work/out")"
[ "$(done_count)" = 1 ] || fail "W: #67 not Done: $(grep item-edit "$GH_LOG")"
once || fail "W: serve failed: $(cat "$work/out")"
grep -q "^pr merge 166 --rebase --match-head-commit $sha66" "$GH_LOG" || fail "W: #66 not merged at the next poll"
# A batch (#263): one pull request, merged under its lead; every ticket of the batch is Done.
boardx "68:In review:S:P0 now" "69:In review:S:P1 next"
prs_reset
sha68=$(mkbranch feat/68-x f68.txt)
pr 168 feat/68-x "$sha68" clean
green "$sha68"
echo "68 69" >"$state/68.batch"
once || fail "W: serve failed: $(cat "$work/out")"
grep -q "^pr merge 168 --rebase --match-head-commit $sha68 -R acme/app$" "$GH_LOG" || fail "W: the batch pull request not merged: $(grep '^pr ' "$GH_LOG")"
grep -q 'Merged: #69' "$work/out" || fail "W: #69 of the batch not reported merged: $(cat "$work/out")"
[ "$(done_count)" = 2 ] || fail "W: #68 and #69 not both Done: $(grep item-edit "$GH_LOG")"
rm -f "$state/68.batch"
# What waits: needs-human, a missing success, a protected zone, merge off, a merge that fails.
boardx "66:In review:S:P1 next"
prs_reset
pr 166 feat/66-x "$sha66" clean
st "$sha66" "senior-mode/ci success" "senior-mode/review success" "senior-mode/security pending"
once || fail "W: serve failed: $(cat "$work/out")"
grep -q '^pr merge' "$GH_LOG" && fail "W: merged with the security pass pending"
grep -q 'Waiting for a human.*#66.*pull request #166, senior-mode/security not green' "$work/out" || fail "W: the wait is not said: $(cat "$work/out")"
green "$sha66"
PROT='src/**' config '{}'
once || fail "W: serve failed: $(cat "$work/out")"
grep -q '^pr merge' "$GH_LOG" && fail "W: merged a protected zone"
grep -q 'protected zone (src/app.ts)' "$work/out" || fail "W: protected zone not said: $(cat "$work/out")"
config '{"merge": false}'
once || fail "W: serve failed: $(cat "$work/out")"
grep -q '^pr merge' "$GH_LOG" && fail "W: merged with autonomy.merge false"
grep -q 'merging is off' "$work/out" || fail "W: merge off not said: $(cat "$work/out")"
config '{}'
pr 166 feat/66-x "$sha66" clean needs-human
once || fail "W: serve failed: $(cat "$work/out")"
grep -q '^pr merge' "$GH_LOG" && fail "W: merged a needs-human pull request"
pr 166 feat/66-x "$sha66" clean
touch "$FIX/merge-fails"
once || fail "W: serve failed: $(cat "$work/out")"
grep -q 'the merge failed: Pull request is not mergeable' "$work/out" || fail "W: a failed merge is not said: $(cat "$work/out")"
[ "$(done_count)" = 0 ] || fail "W: Done after a failed merge"
rm -f "$FIX/merge-fails"
# A pull request that can never merge on its own (#282): protection none, a protected zone, merge off. The pull
# request and its ticket get needs-human, a comment with the reason and one alert; a pull request that already
# has the label is left alone, so the next poll does nothing. A status not green yet is only logged, retried.
config '{}' '{}' '{"webhook": "https://hooks.example/senior"}'
jq '.github.protection = "none"' "$repo/.claude/senior-mode.json" >"$work/cfg.json" && mv "$work/cfg.json" "$repo/.claude/senior-mode.json"
: >"$CURL_LOG"
once || fail "W: serve failed: $(cat "$work/out")"
grep -q '^pr merge' "$GH_LOG" && fail "W: merged without server protection"
grep -q 'issues/166/labels.*needs-human' "$GH_LOG" || fail "W: #166 not labelled needs-human: $(cat "$GH_LOG")"
grep -q 'issues/66/labels.*needs-human' "$GH_LOG" || fail "W: ticket #66 not labelled needs-human: $(cat "$GH_LOG")"
grep -q 'issues/166/comments.*@acme.*no branch protection' "$GH_LOG" || fail "W: no comment with the reason: $(cat "$GH_LOG")"
[ "$(grep -c 'hooks.example' "$CURL_LOG")" = 1 ] || fail "W: the alert did not fire once: $(cat "$CURL_LOG")"
jq -e '.event == "needs-human" and .number == 166 and (.reason | test("no branch protection"))' <<<"$(sed -n 's/.* -d //p' "$CURL_LOG")" >/dev/null ||
  fail "W: webhook payload wrong: $(cat "$CURL_LOG")"
grep -q 'Waiting for a human.*#66.*pull request #166, the server enforces no branch protection' "$work/out" || fail "W: not reported: $(cat "$work/out")"
pr 166 feat/66-x "$sha66" clean needs-human
: >"$CURL_LOG"
once || fail "W: serve failed: $(cat "$work/out")"
grep -q 'issues/.*/labels\|issues/.*/comments' "$GH_LOG" && fail "W: a needs-human pull request is flagged again: $(cat "$GH_LOG")"
[ ! -s "$CURL_LOG" ] || fail "W: the alert fired again: $(cat "$CURL_LOG")"
pr 166 feat/66-x "$sha66" clean
PROT='src/**' config '{}'
once || fail "W: serve failed: $(cat "$work/out")"
grep -q 'issues/166/labels.*needs-human' "$GH_LOG" || fail "W: a protected zone is not needs-human: $(cat "$GH_LOG")"
config '{"merge": false}'
once || fail "W: serve failed: $(cat "$work/out")"
grep -q 'issues/166/comments.*merging is off' "$GH_LOG" || fail "W: merge off is not needs-human: $(cat "$GH_LOG")"
config '{}'
st "$sha66" "senior-mode/ci success" "senior-mode/review success" "senior-mode/security pending"
once || fail "W: serve failed: $(cat "$work/out")"
grep -q 'issues/.*/labels\|issues/.*/comments' "$GH_LOG" && fail "W: a transient blocker got needs-human: $(cat "$GH_LOG")"
grep -q 'Waiting for a human.*senior-mode/security not green' "$work/out" || fail "W: the transient wait is not said: $(cat "$work/out")"
green "$sha66"
# A pull request that is not ready for its tickets (#297, #303): needs-human on the pull request and the ticket, with
# the numbers; it is never merged. One that is within budget, with a commit per ticket, merges.
size_item() { jq -nc --arg s "$2" '{data: {repository: {issue: {projectItems: {nodes: [{project: {id: "PVT_1"},
  fieldValues: {nodes: [{name: $s, field: {name: "Size"}}]}}]}}}}}' >"$FIX/item-$1.json"; }
size_item 66 S
size_item 67 S
printf 'src/big.ts\t450\npackage-lock.json\t9000\n' >"$FIX/files-166"
PRBODY="Closes #66" pr 166 feat/66-x "$sha66" clean
fresh
once || fail "X: serve failed: $(cat "$work/out")"
grep -q '^pr merge' "$GH_LOG" && fail "X: merged a pull request over its size budget"
grep -q 'issues/166/comments.*450 changed lines, 150 over the size budget of 300' "$GH_LOG" || fail "X: no comment with the numbers: $(grep 'issues/166' "$GH_LOG")"
grep -q 'issues/166/labels.*needs-human' "$GH_LOG" || fail "X: #166 not needs-human: $(cat "$GH_LOG")"
grep -q 'issues/66/labels.*needs-human' "$GH_LOG" || fail "X: ticket #66 not needs-human: $(cat "$GH_LOG")"
printf 'src/ok.ts\t200\n' >"$FIX/files-166"
printf '%s\n' '[{"commit": {"message": "feat: both\n\nRefs #66"}}]' >"$FIX/commits-166.json"
PRBODY=$'Closes #66\nCloses #67' pr 166 feat/66-x "$sha66" clean
fresh
once || fail "X: serve failed: $(cat "$work/out")"
grep -q '^pr merge' "$GH_LOG" && fail "X: merged a batch without a commit for #67"
grep -q 'issues/166/comments.*no commit references #67' "$GH_LOG" || fail "X: the missing ticket is not named: $(grep 'issues/166' "$GH_LOG")"
printf '%s\n' '[{"commit": {"message": "feat: a\n\nRefs #66"}}, {"commit": {"message": "feat: b\n\nCloses #67"}}]' >"$FIX/commits-166.json"
PRBODY=$'Closes #66\nCloses #67' pr 166 feat/66-x "$sha66" clean
fresh
once || fail "X: serve failed: $(cat "$work/out")"
grep -q "^pr merge 166 --rebase --match-head-commit $sha66" "$GH_LOG" || fail "X: a ready batch pull request was not merged: $(cat "$work/out")"
rm -f "$FIX"/item-*.json "$FIX/files-166" "$FIX/commits-166.json"
prs_reset
pr 166 feat/66-x "$sha66" clean
green "$sha66"
# Auto-merge (#173): queued with --auto and the head; Done only when MERGED is read back.
echo true >"$FIX/allow-auto"
touch "$FIX/auto-queues"
fresh
once || fail "W: serve failed: $(cat "$work/out")"
grep -q "^pr merge 166 --auto --rebase --match-head-commit $sha66 -R acme/app$" "$GH_LOG" || fail "W: not queued for auto-merge: $(grep '^pr ' "$GH_LOG")"
grep -q '^pr merge 166 --rebase' "$GH_LOG" && fail "W: merged by hand after queuing"
[ -f "$state/queued-166" ] || fail "W: the queue is not remembered"
[ "$(done_count)" = 0 ] || fail "W: Done before the merge"
once || fail "W: serve failed: $(cat "$work/out")"
grep -q '^pr merge' "$GH_LOG" && fail "W: a queued pull request was queued again"
merged 166
once || fail "W: serve failed: $(cat "$work/out")"
[ "$(done_count)" = 1 ] || fail "W: not Done once merged: $(grep item-edit "$GH_LOG")"
[ ! -e "$state/queued-166" ] || fail "W: the queue entry is left"
# GitHub refuses auto-merge: the integrator merges.
rm -f "$FIX/auto-queues" "$FIX/state-166"
touch "$FIX/no-auto"
pr 166 feat/66-x "$sha66" clean
fresh
once || fail "W: serve failed: $(cat "$work/out")"
grep -q '^pr merge 166 --auto' "$GH_LOG" || fail "W: no fallback to a direct merge: $(grep '^pr ' "$GH_LOG")"
grep -q "^pr merge 166 --rebase --match-head-commit $sha66" "$GH_LOG" || fail "W: no fallback to a direct merge: $(grep '^pr ' "$GH_LOG")"
[ "$(done_count)" = 1 ] || fail "W: not Done after the direct merge"

# X: a pull request behind its base is rebased by the server. Same patches (git range-diff): check and publish
# run again on the new head, the review is carried over and the merge follows. Changed patches: a new review.
config '{}'
boardx "70:In review:S:P1 next" "71:In review:S:P1 next"
prs_reset
old70=$(mkbranch feat/70-x f70.txt)
old71=$(mkbranch feat/71-x f71.txt)
config '{}'
new70=$(mkrebased feat/70-x "$old70")
new71=$(mkrebased feat/71-x "$old71" extra71.txt)
pr 170 feat/70-x "$old70" behind
green "$old70"
echo "$new70" >"$FIX/rebase-170"
fresh
once || fail "X: serve failed: $(cat "$work/out")"
grep -q '^pr update-branch 170 --rebase -R acme/app$' "$GH_LOG" || fail "X: not rebased on the server: $(grep '^pr ' "$GH_LOG")"
grep -q "statuses/$new70 .*context=senior-mode/ci" "$GH_LOG" || fail "X: check and publish did not run on the new head: $(grep statuses "$GH_LOG")"
[ "$(status_of "$new70" senior-mode/review)" = success ] || fail "X: the review is not carried over: $(cat "$FIX/status-$new70" 2>&1)"
grep -q "^pr merge 170 --rebase --match-head-commit $new70 " "$GH_LOG" || fail "X: not merged on the new head: $(grep '^pr ' "$GH_LOG")"
[ ! -e "$state/rebased-170" ] || fail "X: the rebase marker is left"
[ -z "$(find "$XDG_DATA_HOME/senior-mode/worktrees" -name 'integrate-*' 2>/dev/null)" ] || fail "X: the check worktree is left"
prs_reset
pr 171 feat/71-x "$old71" behind
green "$old71"
echo "$new71" >"$FIX/rebase-171"
fresh
once || fail "X: serve failed: $(cat "$work/out")"
grep -q '^pr update-branch 171' "$GH_LOG" || fail "X: #71 not rebased"
[ -z "$(status_of "$new71" senior-mode/review)" ] || fail "X: a changed patch kept its review"
[ "$(status_of "$new71" senior-mode/ci)" = success ] || fail "X: no check on the changed head"
grep -q '^pr merge' "$GH_LOG" && fail "X: merged a rebase that changed the patches"
grep -q 'issues/171/comments' "$GH_LOG" || fail "X: no word on the pull request about the new review"
session 71-opus-reviewer "reviewed: success" "" "" review:success
once || fail "X: serve failed: $(cat "$work/out")"
grep -q '^app-review-71 opus run=1 role=reviewer$' "$CLAUDE_LOG" || fail "X: a new review is not requested: $(cat "$CLAUDE_LOG")"

# Y: a conflict starts an Opus integrator session on the -r2 branch; its pull request supersedes the old one,
# which is closed; unresolved, the pull request is needs-human. A resolution tried twice is a person's.
boardx "80:In review:S:P1 next" "81:In review:S:P1 next" "82:In review:S:P1 next"
prs_reset
sha80=$(mkbranch feat/80-x f80.txt)
sha81=$(mkbranch feat/81-x f81.txt)
sha82=$(mkbranch feat/82-x-r3 f82.txt)
pr 180 feat/80-x "$sha80" dirty
green "$sha80"
session 80-opus-integrator delivered pr:300
# The integrator session leaves #80 In progress (#285).
boardx "80:In progress:S:P1 next" "81:In review:S:P1 next" "82:In review:S:P1 next"
cp "$FIX/board.json" "$FIX/board-after-80"
boardx "80:In review:S:P1 next" "81:In review:S:P1 next" "82:In review:S:P1 next"
fresh
once || fail "Y: serve failed: $(cat "$work/out")"
rm -f "$FIX/board-after-80"
grep -q '^app-80-r2 opus run=1 role=integrator$' "$CLAUDE_LOG" || fail "Y: no integrator session: $(cat "$CLAUDE_LOG")"
git -C "$repo" rev-parse --verify -q feat/80-x-r2 >/dev/null || fail "Y: no -r2 branch"
grep -q 'Supersedes #180' "$state/80.prompt" || fail "Y: the prompt does not say what it supersedes"
[ -f "$FIX/closed-180" ] || fail "Y: the old pull request is not closed: $(grep PATCH "$GH_LOG")"
grep -q 'pull request #300 supersedes #180' "$work/out" || fail "Y: not said: $(cat "$work/out")"
# The ticket is In review again, on the new pull request, and serve does not recover it as a lost session (#285).
grep -q 'item-edit.*--single-select-option-id o3' "$GH_LOG" || fail "Y: #80 not left In review after its integrator: $(grep item-edit "$GH_LOG")"
outcome_of 80 delivered Y
once || fail "Y: serve failed: $(cat "$work/out")"
grep -q 'item-edit.*--single-select-option-id o1' "$GH_LOG" && fail "Y: #80 sent back to Ready after its integrator: $(cat "$work/out")"
grep -q '#80 was In progress' "$work/out" && fail "Y: #80 recovered after its integrator: $(cat "$work/out")"
boardx "80:In review:S:P1 next" "81:In review:S:P1 next" "82:In review:S:P1 next"
prs_reset
pr 180 feat/80-x "$sha80" dirty
green "$sha80"
session 80-opus-integrator "failed: the two sides disagree"
fresh
once || fail "Y: serve failed: $(cat "$work/out")"
[ ! -f "$FIX/closed-180" ] || fail "Y: closed a pull request the integrator did not resolve"
grep -q 'issues/180/labels' "$GH_LOG" || fail "Y: unresolved but not needs-human: $(grep issues "$GH_LOG")"
grep -q 'issues/80/labels' "$GH_LOG" || fail "Y: unresolved but not needs-human: $(grep issues "$GH_LOG")"
grep -q 'Waiting for a human.*#180' "$work/out" || fail "Y: not reported: $(cat "$work/out")"
# A conflict found by the server's rebase is the same.
prs_reset
pr 181 feat/81-x "$sha81" behind
green "$sha81"
touch "$FIX/update-conflict"
session 81-opus-integrator delivered pr:301
fresh
once || fail "Y: serve failed: $(cat "$work/out")"
grep -q '^app-81-r2 opus run=1 role=integrator$' "$CLAUDE_LOG" || fail "Y: a conflict at the rebase starts no integrator: $(cat "$CLAUDE_LOG")"
# Already resolved twice.
prs_reset
pr 182 feat/82-x-r3 "$sha82" dirty
green "$sha82"
fresh
once || fail "Y: serve failed: $(cat "$work/out")"
[ ! -s "$CLAUDE_LOG" ] || fail "Y: a third resolution started: $(cat "$CLAUDE_LOG")"
grep -q 'issues/182/labels' "$GH_LOG" || fail "Y: a third conflict is not needs-human"
# An integrator writes in its ticket's files: a Ready ticket whose Paths overlap waits for it (#426); a disjoint one runs.
config '{"parallel": 3}'
boardx "84:In review:S:P1 next" "85:Ready:S:P1 next" "86:Ready:S:P1 next"
paths_of 84 'src/lib/math.ts'
paths_of 85 'src/lib/math.ts'
paths_of 86 'docs/guide/**'
prs_reset
sha84=$(mkbranch feat/84-x f84.txt)
pr 184 feat/84-x "$sha84" dirty
green "$sha84"
session 84-opus-integrator delivered pr:302
for n in 85 86; do session "$n-sonnet" delivered pr; done
fresh
once || fail "Y: serve failed: $(cat "$work/out")"
grep -q '^app-84-r2 opus run=1 role=integrator$' "$CLAUDE_LOG" || fail "Y: no integrator session for #84: $(cat "$CLAUDE_LOG")"
started 85 && fail "Y: #85 started next to the integrator of #84, on the same Paths: $(cat "$CLAUDE_LOG")"
started 86 || fail "Y: the disjoint #86 did not start next to the integrator: $(cat "$CLAUDE_LOG")"
config '{}'

# Z: the trust gate (#427). A Ready ticket is never launched when its author is not a collaborator, or when it
# carries `triage`, unless a collaborator qualified it (`qualified`); the same ticket goes once it is trusted.
mark() { jq -c --argjson n "$1" --arg a "$2" --argjson l "$3" '.data.node.items.nodes |= map(if .content.number == $n
  then .content.authorAssociation = $a | .content.labels.nodes = ($l | map({name: .})) else . end)' "$FIX/board.json" >"$FIX/b" && mv "$FIX/b" "$FIX/board.json"; }
config '{"parallel": 6}'
board 70 71 72 73 74 75
mark 71 NONE '[]'
mark 72 OWNER '["triage"]'
mark 73 FIRST_TIMER '["qualified"]'
mark 74 MEMBER '[]'
mark 75 NONE '["triage", "qualified"]'
for n in 70 71 72 73 74 75; do session "$n-sonnet" delivered pr; done
fresh
once || fail "Z: serve failed: $(cat "$work/out")"
for n in 70 73 74; do started "$n" || fail "Z: #$n (trusted) not launched: $(cat "$CLAUDE_LOG")"; done
for n in 71 72 75; do started "$n" && fail "Z: #$n (untrusted) was launched: $(cat "$CLAUDE_LOG")"; done
# Opening a worktree reads the ticket's title and labels; `clean` reading a branch's issue state is not one.
grep -qE 'issue view (71|72|75) .*title' "$GH_LOG" && fail "Z: a worktree was opened for an untrusted ticket: $(grep 'issue view' "$GH_LOG")"
mark 71 NONE '["qualified"]'
mark 72 OWNER '[]'
fresh
once || fail "Z: serve failed: $(cat "$work/out")"
started 71 || fail "Z: #71 qualified by a collaborator not launched"
started 72 || fail "Z: #72 without triage not launched"
started 75 && fail "Z: #75 (triage still on) launched"

# External pull requests (#427): the daemon never merges one that comes from a fork or from a non-collaborator,
# even with the three statuses green; it is flagged for a human, as any pull request that cannot merge on its own.
config '{}'
boardx "90:In review:S:P1 next" "91:In review:S:P1 next" "92:In review:S:P1 next"
prs_reset
sha90=$(mkbranch feat/90-x f90.txt)
sha91=$(mkbranch feat/91-x f91.txt)
sha92=$(mkbranch feat/92-x f92.txt)
patch_pr() { jq -c "$2" "$FIX/open.d/$1.json" >"$FIX/p" && mv "$FIX/p" "$FIX/open.d/$1.json"
  cp "$FIX/open.d/$1.json" "$FIX/pull-$1.json"; jq -s '.' "$FIX"/open.d/*.json >"$FIX/open-prs.json"; }
pr 190 feat/90-x "$sha90" clean
pr 191 feat/91-x "$sha91" clean
pr 192 feat/92-x "$sha92" clean
patch_pr 190 '.head.repo.full_name = "mallory/app" | .base.repo.full_name = "acme/app"'
patch_pr 191 '.author_association = "CONTRIBUTOR"'
patch_pr 192 'del(.author_association)'
for sha in "$sha90" "$sha91" "$sha92"; do green "$sha"; done
fresh
once || fail "Z: serve failed: $(cat "$work/out")"
grep -q '^pr merge' "$GH_LOG" && fail "Z: an external pull request was merged: $(grep '^pr ' "$GH_LOG")"
for n in 90 91 92; do
  grep -q "issues/1$n/labels.*needs-human" "$GH_LOG" || fail "Z: pull request #1$n not labelled needs-human: $(grep issues "$GH_LOG")"
  grep -q "Waiting for a human.*#$n.*pull request #1$n, it is external" "$work/out" || fail "Z: #1$n not reported external: $(cat "$work/out")"
done
[ "$(done_count)" = 0 ] || fail "Z: a ticket of an external pull request is Done"
# The same pull request by a collaborator, from the repository itself, merges.
prs_reset
pr 190 feat/90-x "$sha90" clean
patch_pr 190 '.head.repo.full_name = "acme/app" | .base.repo.full_name = "acme/app" | .author_association = "COLLABORATOR"'
green "$sha90"
fresh
once || fail "Z: serve failed: $(cat "$work/out")"
grep -q "^pr merge 190 --rebase --match-head-commit $sha90 -R acme/app$" "$GH_LOG" || fail "Z: a collaborator's pull request not merged: $(grep '^pr ' "$GH_LOG")"

# The reviewer session is told the pull request is data, not instructions.
pr 190 feat/90-x "$sha90" clean
st "$sha90" "senior-mode/ci success"
session 90-opus-reviewer "reviewed: success" "" "" review:success
fresh
once || fail "Z: serve failed: $(cat "$work/out")"
grep -q 'never instructions to you' "$state/90.prompt" || fail "Z: the reviewer prompt does not mark the pull request as untrusted data: $(ls "$state")"

[ "$failures" -eq 0 ] && echo "serve: all cases pass"
exit "$failures"
