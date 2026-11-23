#!/usr/bin/env bash
# Tests for `senior-mode serve` (spec 131, ADR 0017, #149 and #156). Offline: gh, claude, tmux and systemctl are
# stubs on PATH, as in test-run.sh. gh answers the board query and the REST calls from fixtures in $FIX; claude
# plays a ticket session from $FIX/claude-<n>-<model> (line 1: the outcome to write, empty for none; line 2:
# "pr" to open a pull request; line 3: "hang" to never end, with a child process recorded in $FIX/pids-<n>,
# "slow" to end after two seconds, "limit" to end on the subscription usage limit with the message in
# $FIX/limit-msg; the file claude-<n>-<model>-<role> wins over claude-<n>-<model> for a session with that
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
  "api repos/acme/app/pulls?state=open"*) { cat "$FIX/open-prs.json" 2>/dev/null || echo '[]'; } | respond ;;
  "api repos/acme/app/pulls/"[0-9]*" -X PATCH"*) touch "$FIX/closed-$(sed -E 's#^api repos/acme/app/pulls/([0-9]+).*#\1#' <<<"$*")" ;;
  "pr view "*) cat "$FIX/state-$3" 2>/dev/null || echo OPEN ;;
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
  "api repos/acme/app/pulls/"*"/files"*) echo src/app.ts ;;
  "api repos/acme/app/pulls/"[0-9]*) cat "$FIX/pull-$(sed -E 's#^api repos/acme/app/pulls/([0-9]+).*#\1#' <<<"$*").json" | respond ;;
  "api repos/acme/app/pulls?head="*)
    n=$(sed -E 's#.*head=acme:[a-z]+/([0-9]+)-.*#\1#' <<<"$*")
    { cat "$FIX/pulls-$n" 2>/dev/null || echo '[]'; } | respond ;;
  "api repos/acme/app/issues/"*"/comments"*) echo '{}' ;;
  "api repos/acme/app/issues/"*"/labels"*) echo '[]' ;;
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
  limit)
    jq -nc --rawfile m "$FIX/limit-msg" '{type: "result", is_error: true, result: $m}'
    exit 1 ;;
esac
outcome=$(sed -n 1p "$fx")
[ -z "$outcome" ] || echo "$outcome" >"$SENIOR_MODE_RUN_OUTCOME"
case $(sed -n 2p "$fx") in
  pr) num=$((n + 100)) ;;
  pr:*) num=$(sed -n 2p "$fx"); num=${num#pr:} ;;
  *) num="" ;;
esac
[ -z "$num" ] || echo "[{\"number\": $num, \"head\": {\"sha\": \"sha$n\"}, \"labels\": []}]" >"$FIX/pulls-$n"
case $(sed -n 4p "$fx") in
  review:*) echo "senior-mode/review $(sed -n 4p "$fx" | cut -d: -f2)" >>"$FIX/status-$(git rev-parse HEAD)" ;;
  commit) echo "red $n" >"tests-$n.txt"; git add "tests-$n.txt"; git -c user.name=t -c user.email=t@t commit -q -m "test: red tests" ;;
esac
echo '{"result": "ok"}'
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
      content: {number: $n, title: "Ticket \($n)", url: "u", state: "OPEN", closedAt: null,
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

# I: options and config are checked.
(cd "$repo" && "$cli" serve --bogus) >"$work/out" 2>&1 && fail "I: an unknown option was accepted"
grep -q 'usage:.*serve' "$work/out" || fail "I: usage does not name serve: $(cat "$work/out")"
config '{}' '{"interval": 0}'
once && fail "I: serve.interval 0 accepted"
grep -q 'serve.interval must be' "$work/out" || fail "I: bad interval not explained: $(cat "$work/out")"
echo '{}' >"$repo/.claude/senior-mode.json"
[ "$(cd "$repo" && "$cli" config get serve.interval)" = 60 ] &&
  [ "$(cd "$repo" && "$cli" config get serve.grace)" = 600 ] &&
  [ "$(cd "$repo" && "$cli" config get serve.breakerCooldown)" = 3600 ] &&
  [ "$(cd "$repo" && "$cli" config get autonomy.sessionsPerHour)" = 6 ] &&
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
      content: {number: $n, title: "Ticket \($n)", url: "u", state: "OPEN", closedAt: null,
        labels: {nodes: (if $lb == "" then [] else [{name: $lb}] end)}, milestone: null, blockedBy: {nodes: []}}}]' <<<"$items")
  done
  jq -nc --argjson i "$items" '{data: {node: {items: {pageInfo: {hasNextPage: false}, nodes: $i}}}}' >"$FIX/board.json"
}
prs_reset() { rm -rf "$FIX/open.d" "$FIX/open-prs.json" "$FIX"/pull-*.json "$FIX"/state-* "$FIX"/status-* "$FIX"/closed-* "$FIX/allow-auto" "$FIX/auto-queues" "$FIX/no-auto" "$FIX/merge-fails" "$FIX/update-conflict"; }
# pr <number> <branch> <sha> <mergeable_state> [<label>]: an open pull request.
pr() {
  mkdir -p "$FIX/open.d"
  jq -nc --argjson p "$1" --arg b "$2" --arg s "$3" --arg m "$4" --arg l "${5:-}" '{number: $p, draft: false, head: {ref: $b, sha: $s},
    mergeable_state: $m, labels: (if $l == "" then [] else [{name: $l}] end), body: ""}' >"$FIX/open.d/$1.json"
  cp "$FIX/open.d/$1.json" "$FIX/pull-$1.json"
  jq -s '.' "$FIX"/open.d/*.json >"$FIX/open-prs.json"
}
# st <sha> <context state>...: the statuses of a commit.
st() { local sha=$1; shift; printf '%s\n' "$@" >"$FIX/status-$sha"; }
green() { st "$1" "senior-mode/ci success" "senior-mode/review success" "senior-mode/security success"; }
status_of() { sed -n "s#^$2 ##p" "$FIX/status-$1" | tail -n 1; }
merged() { echo MERGED >"$FIX/state-$1"; jq -c --argjson n "$1" 'map(select(.number != $n))' "$FIX/open-prs.json" >"$FIX/open-prs.tmp" && mv "$FIX/open-prs.tmp" "$FIX/open-prs.json"; }
done_count() { grep -c 'item-edit.*--single-select-option-id o4' "$GH_LOG" || true; }

# J: a ticket session has its role and a prompt that leaves the review to the reviewer.
config '{}'
board 60
session 60-sonnet delivered pr
fresh
once || fail "J: serve failed: $(cat "$work/out")"
grep -q '^app-60 sonnet run=1 role=ticket$' "$CLAUDE_LOG" || fail "J: the ticket session has no role: $(cat "$CLAUDE_LOG")"
grep -q 'SENIOR_MODE_ROLE=ticket' "$state/60.prompt" || fail "J: the prompt does not name the role"
grep -qi 'at most 2 fix rounds\|reviewer agent reviews the pull request' "$state/60.prompt" && fail "J: the ticket session is still asked to review"
grep -q 'never set it' "$state/60.prompt" || fail "J: the prompt does not forbid senior-mode/review"

# K: In review with CI success and no review status: a reviewer session on Opus, role reviewer, in a worktree of
# the head that is gone afterwards. Nothing starts without CI success, with a review status, or with needs-human.
config '{}'
sha=$(mkbranch feat/61-x f61.txt)
boardx "61:In review:S:P1 next"
prs_reset
pr 161 feat/61-x "$sha" clean
st "$sha" "senior-mode/ci success"
session 61-opus-reviewer "reviewed: success" "" "" review:success
fresh
once || fail "K: serve failed: $(cat "$work/out")"
grep -q '^app-review-61 opus run=1 role=reviewer$' "$CLAUDE_LOG" || fail "K: no reviewer session: $(cat "$CLAUDE_LOG")"
[ "$(status_of "$sha" senior-mode/review)" = success ] || fail "K: the reviewer's status is missing"
[ -z "$(find "$XDG_DATA_HOME/senior-mode/worktrees" -name review-61 2>/dev/null)" ] || fail "K: the review worktree is left"
grep -q 'reviewed: senior-mode/review is success' "$work/out" || fail "K: the review is not said: $(cat "$work/out")"
st "$sha" "senior-mode/ci pending"
once || fail "K: serve failed: $(cat "$work/out")"
[ ! -s "$CLAUDE_LOG" ] || fail "K: reviewed without CI success: $(cat "$CLAUDE_LOG")"
st "$sha" "senior-mode/ci success" "senior-mode/review pending"
once || fail "K: serve failed: $(cat "$work/out")"
[ ! -s "$CLAUDE_LOG" ] || fail "K: reviewed again with a review status: $(cat "$CLAUDE_LOG")"
st "$sha" "senior-mode/ci success"
pr 161 feat/61-x "$sha" clean needs-human
once || fail "K: serve failed: $(cat "$work/out")"
[ ! -s "$CLAUDE_LOG" ] || fail "K: reviewed a needs-human pull request: $(cat "$CLAUDE_LOG")"
pr 161 feat/61-x "$sha" clean
boardx "61:In review:S:P1 next:needs-human"
once || fail "K: serve failed: $(cat "$work/out")"
[ ! -s "$CLAUDE_LOG" ] || fail "K: reviewed a needs-human ticket: $(cat "$CLAUDE_LOG")"
boardx "61:In review:S:P1 next"
session 61-opus-reviewer "" "" ""
once || fail "K: serve failed: $(cat "$work/out")"
grep -q 'issues/161/labels' "$GH_LOG" || fail "K: a reviewer that sets no status leaves the pull request unlabelled: $(cat "$GH_LOG")"
grep -q 'issues/61/labels' "$GH_LOG" || fail "K: its ticket is not labelled either"

# L: changes requested: the ticket session resumes on the same branch with the findings, twice; then needs-human.
boardx "62:In review:S:P1 next"
prs_reset
sha=$(mkbranch feat/62-x f62.txt)
pr 162 feat/62-x "$sha" clean
st "$sha" "senior-mode/ci success" "senior-mode/review failure"
session 62-sonnet-ticket delivered pr
fresh
once || fail "L: serve failed: $(cat "$work/out")"
grep -q '^app-62 sonnet run=1 role=ticket$' "$CLAUDE_LOG" || fail "L: the ticket session did not resume: $(cat "$CLAUDE_LOG")"
grep -q 'round 1 of 2' "$state/62.prompt" || fail "L: the prompt does not say the round: $(cat "$state/62.prompt")"
grep -q 'gh pr view 162 --comments' "$state/62.prompt" || fail "L: the findings are not pointed to"
[ "$(cat "$state/rounds-62")" = 1 ] || fail "L: round not counted"
once || fail "L: serve failed: $(cat "$work/out")"
grep -q 'round 2 of 2' "$state/62.prompt" || fail "L: second round missing"
once || fail "L: serve failed: $(cat "$work/out")"
[ ! -s "$CLAUDE_LOG" ] || fail "L: a third round started: $(cat "$CLAUDE_LOG")"
grep -q 'issues/162/labels' "$GH_LOG" || fail "L: no needs-human after 2 rounds: $(cat "$GH_LOG")"
grep -q 'issues/62/labels' "$GH_LOG" || fail "L: no needs-human after 2 rounds: $(cat "$GH_LOG")"
grep -q 'Waiting for a human.*pull request #162.*2 fix rounds' "$work/out" || fail "L: not reported: $(cat "$work/out")"

# M: an M ticket: the test-author session first, then red-tests record, then the ticket session on the same branch.
boardx "63:Ready:M:P1 next" "64:Ready:M:P1 next"
prs_reset
session 63-sonnet-test-author delivered "" "" commit
session 63-sonnet-ticket delivered pr
session 64-sonnet-test-author "failed: criterion 2 cannot be tested"
config '{"parallel": 2}'
fresh
once || fail "M: serve failed: $(cat "$work/out")"
first=$(grep -n '^app-63 sonnet run=1 role=test-author$' "$CLAUDE_LOG" | cut -d: -f1)
second=$(grep -n '^app-63 sonnet run=1 role=ticket$' "$CLAUDE_LOG" | cut -d: -f1)
{ [ -n "$first" ] && [ -n "$second" ] && [ "$first" -lt "$second" ]; } || fail "M: test-author then ticket expected: $(cat "$CLAUDE_LOG")"
grep -qx 'tests-63.txt' "$repo/.git/senior-mode/runs/63/red-tests" || fail "M: the red tests are not recorded: $(cat "$repo/.git/senior-mode/runs/63/red-tests" 2>&1)"
grep -q 'written and committed already' "$state/63.prompt" || fail "M: the ticket prompt does not tell about the red tests"
grep -q '^app-64 sonnet run=1 role=ticket$' "$CLAUDE_LOG" && fail "M: a ticket session after a failed test-author"
outcome_of 64 failed M
grep -c 'item-edit.*--single-select-option-id o0' "$GH_LOG" | grep -qx 1 || fail "M: #64 is not back in Backlog: $(grep item-edit "$GH_LOG")"
boardx "63:Ready:M:P1 next"
rm -f "$FIX/pulls-63"
fresh
once || fail "M: serve failed: $(cat "$work/out")"
grep -q '^app-63 sonnet run=1 role=test-author$' "$CLAUDE_LOG" && fail "M: the red tests are recorded, no test-author again: $(cat "$CLAUDE_LOG")"
grep -q '^app-63 sonnet run=1 role=ticket$' "$CLAUDE_LOG" || fail "M: no ticket session"
config '{}'

# N: the usage limit holds the reviewers too, without a failure; the pull request is reviewed after the reset. A
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
once || fail "N: serve failed: $(cat "$work/out")"
[ "$(cat "$state/limit-until" 2>/dev/null)" = 1800005000 ] || fail "N: reset time not kept: $(cat "$state/limit-until" 2>&1)"
grep -q 'issues/65/' "$GH_LOG" && fail "N: a usage limit labelled the ticket: $(grep issues/65/ "$GH_LOG")"
grep -q 'item-edit' "$GH_LOG" && ! grep -q -- '--single-select-option-id o4' "$GH_LOG" && fail "N: a status was changed for a reviewer that hit the limit"
[ -z "$(status_of "$sha" senior-mode/review)" ] || fail "N: a review status was set"
session 65-opus-reviewer "reviewed: success" "" "" review:success
pr 175 feat/75-x "$sha75" clean
SENIOR_MODE_NOW=1800004000 once || fail "N: serve failed: $(cat "$work/out")"
[ ! -s "$CLAUDE_LOG" ] || fail "N: a reviewer started before the reset: $(cat "$CLAUDE_LOG")"
grep -q 'usage limit' "$work/out" || fail "N: the hold is not said"
grep -q "^pr merge 175 --rebase --match-head-commit $sha75 -R acme/app" "$GH_LOG" || fail "N: no merge during the hold: $(grep '^pr ' "$GH_LOG")"
SENIOR_MODE_NOW=1800005001 once || fail "N: serve failed: $(cat "$work/out")"
grep -q '^app-review-65 opus run=1 role=reviewer$' "$CLAUDE_LOG" || fail "N: not reviewed after the reset: $(cat "$CLAUDE_LOG")"

# O: the integrator pass: at most one merge per poll, by priority, --match-head-commit, merged read back then Done.
boardx "66:In review:S:P1 next" "67:In review:S:P0 now"
prs_reset
sha66=$(mkbranch feat/66-x f66.txt)
sha67=$(mkbranch feat/67-x f67.txt)
pr 166 feat/66-x "$sha66" clean
pr 167 feat/67-x "$sha67" clean
green "$sha66"
green "$sha67"
fresh
once || fail "O: serve failed: $(cat "$work/out")"
grep -q "^pr merge 167 --rebase --match-head-commit $sha67 -R acme/app$" "$GH_LOG" || fail "O: #67 (P0) not merged first: $(grep '^pr ' "$GH_LOG")"
grep -q '^pr merge 166' "$GH_LOG" && fail "O: two merges in one poll"
grep -q 'Merged: #67' "$work/out" || fail "O: the merge is not reported: $(cat "$work/out")"
[ "$(done_count)" = 1 ] || fail "O: #67 not Done: $(grep item-edit "$GH_LOG")"
once || fail "O: serve failed: $(cat "$work/out")"
grep -q "^pr merge 166 --rebase --match-head-commit $sha66" "$GH_LOG" || fail "O: #66 not merged at the next poll"
# What waits: needs-human, a missing success, a protected zone, merge off, a merge that fails.
boardx "66:In review:S:P1 next"
prs_reset
pr 166 feat/66-x "$sha66" clean
st "$sha66" "senior-mode/ci success" "senior-mode/review success" "senior-mode/security pending"
once || fail "O: serve failed: $(cat "$work/out")"
grep -q '^pr merge' "$GH_LOG" && fail "O: merged with the security pass pending"
grep -q 'Waiting for a human.*#66.*pull request #166, senior-mode/security not green' "$work/out" || fail "O: the wait is not said: $(cat "$work/out")"
green "$sha66"
PROT='src/**' config '{}'
once || fail "O: serve failed: $(cat "$work/out")"
grep -q '^pr merge' "$GH_LOG" && fail "O: merged a protected zone"
grep -q 'protected zone (src/app.ts)' "$work/out" || fail "O: protected zone not said: $(cat "$work/out")"
config '{"merge": false}'
once || fail "O: serve failed: $(cat "$work/out")"
grep -q '^pr merge' "$GH_LOG" && fail "O: merged with autonomy.merge false"
grep -q 'merging is off' "$work/out" || fail "O: merge off not said: $(cat "$work/out")"
config '{}'
pr 166 feat/66-x "$sha66" clean needs-human
once || fail "O: serve failed: $(cat "$work/out")"
grep -q '^pr merge' "$GH_LOG" && fail "O: merged a needs-human pull request"
pr 166 feat/66-x "$sha66" clean
touch "$FIX/merge-fails"
once || fail "O: serve failed: $(cat "$work/out")"
grep -q 'the merge failed: Pull request is not mergeable' "$work/out" || fail "O: a failed merge is not said: $(cat "$work/out")"
[ "$(done_count)" = 0 ] || fail "O: Done after a failed merge"
rm -f "$FIX/merge-fails"
# Auto-merge (#173): queued with --auto and the head; Done only when MERGED is read back.
echo true >"$FIX/allow-auto"
touch "$FIX/auto-queues"
fresh
once || fail "O: serve failed: $(cat "$work/out")"
grep -q "^pr merge 166 --auto --rebase --match-head-commit $sha66 -R acme/app$" "$GH_LOG" || fail "O: not queued for auto-merge: $(grep '^pr ' "$GH_LOG")"
grep -q '^pr merge 166 --rebase' "$GH_LOG" && fail "O: merged by hand after queuing"
[ -f "$state/queued-166" ] || fail "O: the queue is not remembered"
[ "$(done_count)" = 0 ] || fail "O: Done before the merge"
once || fail "O: serve failed: $(cat "$work/out")"
grep -q '^pr merge' "$GH_LOG" && fail "O: a queued pull request was queued again"
merged 166
once || fail "O: serve failed: $(cat "$work/out")"
[ "$(done_count)" = 1 ] || fail "O: not Done once merged: $(grep item-edit "$GH_LOG")"
[ ! -e "$state/queued-166" ] || fail "O: the queue entry is left"
# GitHub refuses auto-merge: the integrator merges.
rm -f "$FIX/auto-queues" "$FIX/state-166"
touch "$FIX/no-auto"
pr 166 feat/66-x "$sha66" clean
fresh
once || fail "O: serve failed: $(cat "$work/out")"
grep -q '^pr merge 166 --auto' "$GH_LOG" || fail "O: no fallback to a direct merge: $(grep '^pr ' "$GH_LOG")"
grep -q "^pr merge 166 --rebase --match-head-commit $sha66" "$GH_LOG" || fail "O: no fallback to a direct merge: $(grep '^pr ' "$GH_LOG")"
[ "$(done_count)" = 1 ] || fail "O: not Done after the direct merge"

# P: a pull request behind its base is rebased by the server. Same patches (git range-diff): check and publish
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
once || fail "P: serve failed: $(cat "$work/out")"
grep -q '^pr update-branch 170 --rebase -R acme/app$' "$GH_LOG" || fail "P: not rebased on the server: $(grep '^pr ' "$GH_LOG")"
grep -q "statuses/$new70 .*context=senior-mode/ci" "$GH_LOG" || fail "P: check and publish did not run on the new head: $(grep statuses "$GH_LOG")"
[ "$(status_of "$new70" senior-mode/review)" = success ] || fail "P: the review is not carried over: $(cat "$FIX/status-$new70" 2>&1)"
grep -q "^pr merge 170 --rebase --match-head-commit $new70 " "$GH_LOG" || fail "P: not merged on the new head: $(grep '^pr ' "$GH_LOG")"
[ ! -e "$state/rebased-170" ] || fail "P: the rebase marker is left"
[ -z "$(find "$XDG_DATA_HOME/senior-mode/worktrees" -name 'integrate-*' 2>/dev/null)" ] || fail "P: the check worktree is left"
prs_reset
pr 171 feat/71-x "$old71" behind
green "$old71"
echo "$new71" >"$FIX/rebase-171"
fresh
once || fail "P: serve failed: $(cat "$work/out")"
grep -q '^pr update-branch 171' "$GH_LOG" || fail "P: #71 not rebased"
[ -z "$(status_of "$new71" senior-mode/review)" ] || fail "P: a changed patch kept its review"
[ "$(status_of "$new71" senior-mode/ci)" = success ] || fail "P: no check on the changed head"
grep -q '^pr merge' "$GH_LOG" && fail "P: merged a rebase that changed the patches"
grep -q 'issues/171/comments' "$GH_LOG" || fail "P: no word on the pull request about the new review"
session 71-opus-reviewer "reviewed: success" "" "" review:success
once || fail "P: serve failed: $(cat "$work/out")"
grep -q '^app-review-71 opus run=1 role=reviewer$' "$CLAUDE_LOG" || fail "P: a new review is not requested: $(cat "$CLAUDE_LOG")"

# Q: a conflict starts an Opus integrator session on the -r2 branch; its pull request supersedes the old one,
# which is closed; unresolved, the pull request is needs-human. A resolution tried twice is a person's.
boardx "80:In review:S:P1 next" "81:In review:S:P1 next" "82:In review:S:P1 next"
prs_reset
sha80=$(mkbranch feat/80-x f80.txt)
sha81=$(mkbranch feat/81-x f81.txt)
sha82=$(mkbranch feat/82-x-r3 f82.txt)
pr 180 feat/80-x "$sha80" dirty
green "$sha80"
session 80-opus-integrator delivered pr:300
fresh
once || fail "Q: serve failed: $(cat "$work/out")"
grep -q '^app-80-r2 opus run=1 role=integrator$' "$CLAUDE_LOG" || fail "Q: no integrator session: $(cat "$CLAUDE_LOG")"
git -C "$repo" rev-parse --verify -q feat/80-x-r2 >/dev/null || fail "Q: no -r2 branch"
grep -q 'Supersedes #180' "$state/80.prompt" || fail "Q: the prompt does not say what it supersedes"
[ -f "$FIX/closed-180" ] || fail "Q: the old pull request is not closed: $(grep PATCH "$GH_LOG")"
grep -q 'pull request #300 supersedes #180' "$work/out" || fail "Q: not said: $(cat "$work/out")"
prs_reset
pr 180 feat/80-x "$sha80" dirty
green "$sha80"
session 80-opus-integrator "failed: the two sides disagree"
fresh
once || fail "Q: serve failed: $(cat "$work/out")"
[ ! -f "$FIX/closed-180" ] || fail "Q: closed a pull request the integrator did not resolve"
grep -q 'issues/180/labels' "$GH_LOG" || fail "Q: unresolved but not needs-human: $(grep issues "$GH_LOG")"
grep -q 'issues/80/labels' "$GH_LOG" || fail "Q: unresolved but not needs-human: $(grep issues "$GH_LOG")"
grep -q 'Waiting for a human.*#180' "$work/out" || fail "Q: not reported: $(cat "$work/out")"
# A conflict found by the server's rebase is the same.
prs_reset
pr 181 feat/81-x "$sha81" behind
green "$sha81"
touch "$FIX/update-conflict"
session 81-opus-integrator delivered pr:301
fresh
once || fail "Q: serve failed: $(cat "$work/out")"
grep -q '^app-81-r2 opus run=1 role=integrator$' "$CLAUDE_LOG" || fail "Q: a conflict at the rebase starts no integrator: $(cat "$CLAUDE_LOG")"
# Already resolved twice.
prs_reset
pr 182 feat/82-x-r3 "$sha82" dirty
green "$sha82"
fresh
once || fail "Q: serve failed: $(cat "$work/out")"
[ ! -s "$CLAUDE_LOG" ] || fail "Q: a third resolution started: $(cat "$CLAUDE_LOG")"
grep -q 'issues/182/labels' "$GH_LOG" || fail "Q: a third conflict is not needs-human"

[ "$failures" -eq 0 ] && echo "serve: all cases pass"
exit "$failures"
