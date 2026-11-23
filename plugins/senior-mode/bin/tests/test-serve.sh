#!/usr/bin/env bash
# Tests for `senior-mode serve` (spec 131, ADR 0017, #149 and #156). Offline: gh, claude, tmux and systemctl are
# stubs on PATH, as in test-run.sh. gh answers the board query and the REST calls from fixtures in $FIX; claude
# plays a ticket session from $FIX/claude-<n>-<model> (line 1: the outcome to write, empty for none; line 2:
# "pr" to open a pull request; line 3: "hang" to never end, with a child process recorded in $FIX/pids-<n>,
# "slow" to end after two seconds, "limit" to end on the subscription usage limit with the message in
# $FIX/limit-msg). systemctl logs its calls to $SYS_LOG. SENIOR_MODE_SERVE_ONCE=1 makes serve poll once, wait for
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
    else cat "$FIX/board.json"; fi ;;
  "api repos/acme/app/dependabot/alerts"* | "api repos/acme/app/secret-scanning/alerts"*) echo '[]' | respond ;;
  "issue view "*)
    n=$(sed -E 's#^issue view ([0-9]+) .*#\1#' <<<"$*")
    jq -c --argjson n "$n" '.data.node.items.nodes[] | select(.content.number == $n) | .content
      | {title, state, labels: .labels.nodes}' "$FIX/board.json" ;;
  "project item-add"*) echo "ITEM_$(sed -E 's#.*/issues/([0-9]+).*#\1#' <<<"$*")" ;;
  "project item-edit"*) ;;
  "api repos/acme/app/pulls/"*"/files"*) echo src/app.ts ;;
  "api repos/acme/app/pulls?head="*)
    n=$(sed -E 's#.*head=acme:[a-z]+/([0-9]+)-.*#\1#' <<<"$*")
    cat "$FIX/pulls-$n" 2>/dev/null || echo '[]' ;;
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
echo "$tag $model run=${SENIOR_MODE_RUN:-}" >>"$CLAUDE_LOG"
if [[ ${!#} == *"guard probe"* ]]; then
  echo '{"type": "user", "message": {"content": "senior-mode: skipping checks is denied (core.hooksPath); fix what the check reports instead."}}'
  exit 0
fi
n=$(sed -nE 's#.*/senior-mode/worktrees/[^/]+/([0-9]+)$#\1#p' <<<"$PWD")
[ -n "$n" ] || exit 0
fx=$FIX/claude-$n-$model
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
# A batch session (#263) writes one outcome line per ticket: $FIX/outcome-<lead> holds them.
[ ! -f "$FIX/outcome-$n" ] || cp "$FIX/outcome-$n" "$SENIOR_MODE_RUN_OUTCOME"
[ "$(sed -n 2p "$fx")" != pr ] ||
  echo "[{\"number\": $((n + 100)), \"head\": {\"sha\": \"sha$n\"}, \"labels\": []}]" >"$FIX/pulls-$n"
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
    autonomy: ({minMemoryMB: 0} + $a), serve: $s, notify: ({digest: false} + $nt), github: {protection: "ruleset"}}' >"$repo/.claude/senior-mode.json"
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
session() { printf '%s\n%s\n%s\n' "$2" "${3:-}" "${4:-}" >"$FIX/claude-$1"; }
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
grep -q 'Waiting for a human.*#10' "$work/out" || fail "A: a delivered pull request is not reported: $(cat "$work/out")"
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

# L: ready by rule (#272). A framing pull request (docs/...) merged since the last poll gets `ready --pr <n>`;
# once a poll `ready` looks at the tickets agents filed. Pull requests merged before the last poll, or from another
# branch, are not read. The first poll only sets the mark.
criteria=$'## Acceptance criteria\n\n- Given a, when b, then c.\n'
# fitem <number> <status> <labels json> <body>: appends to $items a ticket with a Size, a Priority and Paths.
fitem() {
  items=$(jq -c --argjson n "$1" --arg s "$2" --argjson l "$3" --arg b "$4" '. + [{fieldValues: {nodes: [{name: $s, field: {name: "Status"}},
    {name: "P1 next", field: {name: "Priority"}}, {name: "S", field: {name: "Size"}}, {text: "docs/**", field: {name: "Paths"}}]},
    content: {number: $n, title: "Ticket \($n)", url: "u", state: "OPEN", closedAt: null, body: $b,
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
  grep -q "Waiting for a human.*#$n.*pull request #121" "$work/out" || fail "J: #$n is not reported with the one pull request: $(cat "$work/out")"
done
grep -c 'item-edit.*--single-select-option-id o3' "$GH_LOG" | grep -qx 3 || fail "J: the delivered tickets are not In review"
outcome_of 21 delivered J
outcome_of 22 delivered J
fields=$saved_fields

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

[ "$failures" -eq 0 ] && echo "serve: all cases pass"
exit "$failures"
