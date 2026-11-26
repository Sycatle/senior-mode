#!/usr/bin/env bash
# Tests for `senior-mode serve` (spec 131, ADR 0017, #149 and #156). Offline: gh, claude, tmux and systemctl are
# stubs on PATH, as in test-run.sh. gh answers the board query and the REST calls from fixtures in $FIX; claude
# plays a ticket session from $FIX/claude-<n>-<model> (line 1: the outcome to write, empty for none; line 2:
# "pr" to open a pull request; line 3: "hang" to never end, with a child process recorded in $FIX/pids-<n>,
# "slow" to end once $FIX/release-<n> exists (the case creates it; bounded at 60 s), "limit" to end on the subscription usage limit with the message in
# $FIX/limit-msg, "flaky:<message>" to die once with the message on stderr (exit 1), then behave; the file claude-<n>-<model>-<role> wins over claude-<n>-<model> for a session with that
# SENIOR_MODE_ROLE, and <file>.<k> wins for the k-th session of that ticket, model and role; line 2 may be "pr:<number>" for another pull request number; line 4: "review:<state>" posts
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
[ ! -f "$FIX/gh-dead" ] || exec sleep 30
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
  "issue list"*) { cat "$FIX/issues.json" 2>/dev/null || echo '[]'; } | respond ;;
  "issue create"*)
    # The tickets serve files (#497): kept in $FIX/issues.json, which `issue list` serves back.
    t="" bf="" prev=""
    for a in "$@"; do [ "$prev" = --title ] && t=$a; [ "$prev" = --body-file ] && bf=$a; prev=$a; done
    n=$(jq '[500, (.[].number + 1)] | max' "$FIX/issues.json" 2>/dev/null || echo 500)
    [ -z "$bf" ] || cp "$bf" "$FIX/body-$n"
    jq --argjson n "$n" --arg t "$t" '. + [{number: $n, title: $t, body: "", labels: []}]' "$FIX/issues.json" >"$FIX/i" && mv "$FIX/i" "$FIX/issues.json"
    echo "https://github.com/acme/app/issues/$n" ;;
  "api repos/acme/app/dependabot/alerts"* | "api repos/acme/app/secret-scanning/alerts"*) echo '[]' | respond ;;
  "issue view "*)
    n=$(sed -E 's#^issue view ([0-9]+) .*#\1#' <<<"$*")
    jq -c --argjson n "$n" '.data.node.items.nodes[] | select(.content.number == $n) | .content
      | {title, state, labels: .labels.nodes}' "$FIX/board.json" | respond ;;
  "project item-add"*) echo "ITEM_$(sed -E 's#.*/issues/([0-9]+).*#\1#' <<<"$*")" ;;
  "project item-edit"*) ;;
  "auth status"*) [ ! -f "$FIX/gh-auth-bad" ] ;;
  "api repos/acme/app/compare/"*)
    sha=$(sed -E 's#^api repos/acme/app/compare/[^ ]*\.\.\.([^ ]+) .*#\1#' <<<"$*")
    echo "{\"behind_by\": $(cat "$FIX/behind-$sha" 2>/dev/null || echo 0)}" | respond ;;
  "api repos/acme/app/pulls/"*"/commits"*) cat "$FIX/commits-$(sed -E 's#.*/pulls/([0-9]+)/commits.*#\1#' <<<"$*").json" | respond ;;
  "api repos/acme/app/pulls/"*"/files"*) cat "$FIX/files-$(sed -E 's#.*/pulls/([0-9]+)/files.*#\1#' <<<"$*")" 2>/dev/null || echo src/app.ts ;;
  "api repos/acme/app/pulls -X POST"*)
    # A pull request opened by serve (spec 373, section 2): recorded, and served by the head queries after it.
    echo "$*" >>"$FIX/pr-created"
    br=$(sed -E 's#.* head=([^ ]+) .*#\1#' <<<"${*//$'\n'/ }")
    n=$(sed -E 's#^[a-z]+/([0-9]+)-.*#\1#' <<<"$br")
    echo "[{\"number\": $((n + 100)), \"author_association\": \"OWNER\", \"head\": {\"sha\": \"sha$n\"}, \"labels\": []}]" >"$FIX/pulls-$n" ;;
  "api repos/acme/app/pulls/"[0-9]*) cat "$FIX/pull-$(sed -E 's#^api repos/acme/app/pulls/([0-9]+).*#\1#' <<<"$*").json" | respond ;;
  "api repos/acme/app/pulls?head="*)
    n=$(sed -E 's#.*head=acme:[a-z]+/([0-9]+)-.*#\1#' <<<"$*")
    { cat "$FIX/pulls-$n" 2>/dev/null || echo '[]'; } | respond ;;
  "api repos/acme/app/issues/"*"/sub_issues"*) echo '[]' | respond ;;
  "api -X POST repos/acme/app/issues/"*"/sub_issues"*) echo "$*" >>"$FIX/sub-issues" ;;
  "api repos/acme/app/issues/"[0-9]*" --jq .id") echo 1 ;;
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
# The k-th session of that ticket, model and role plays <fixture>.<k> when it exists; the prompt it got is kept.
k=$(($(cat "$FIX/calls-$n-$model-${SENIOR_MODE_ROLE:-}" 2>/dev/null || echo 0) + 1))
echo "$k" >"$FIX/calls-$n-$model-${SENIOR_MODE_ROLE:-}"
printf '%s\n' "${!#}" >"$FIX/prompt-$n-${SENIOR_MODE_ROLE:-}-$k"
if [ -f "$fx.$k" ]; then fx=$fx.$k
elif [ ! -f "$fx" ]; then fx=$FIX/claude-$n-$model; [ -f "$fx.$k" ] && fx=$fx.$k
fi
[ -f "$fx" ] || exit 1
case $(sed -n 3p "$fx") in
  hang)
    sleep 300 &
    echo "$$ $!" >"$FIX/pids-$n"
    wait ;;
  slow) for _ in $(seq 600); do [ -f "$FIX/release-$n" ] && break; sleep 0.1; done ;;
  busy) for i in $(seq 30); do echo "$i" >>busy.txt; sleep 0.3; done; rm -f busy.txt ;;
  flaky*:*)
    # flaky:<message> dies once, flaky<k>:<message> k times (the count is in $FIX/flaky-done-<n>-<model>).
    spec=$(sed -n 3p "$fx")
    k=${spec%%:*}
    k=${k#flaky}
    done_=$(cat "$FIX/flaky-done-$n-$model" 2>/dev/null || echo 0)
    if [ "$done_" -lt "${k:-1}" ]; then
      echo $((done_ + 1)) >"$FIX/flaky-done-$n-$model"
      echo "${spec#*:}" >&2
      exit 1
    fi ;;
  limit)
    jq -nc --rawfile m "$FIX/limit-msg" '{type: "result", is_error: true, result: $m}'
    exit 1 ;;
esac
outcome=$(sed -n 1p "$fx")
[ -z "$outcome" ] || echo "$outcome" >"$SENIOR_MODE_RUN_OUTCOME"
# #352: the plan file of the session ($SENIOR_MODE_RUN_PLAN): $FIX/plan-<n> holds it ("none": no file), else an approved plan.
if [ ! -f "$FIX/plan-$n" ]; then printf 'plan 1:\nx\narchitect 1: approve\n' >"$SENIOR_MODE_RUN_PLAN"
elif [ "$(cat "$FIX/plan-$n")" != none ]; then cp "$FIX/plan-$n" "$SENIOR_MODE_RUN_PLAN"; fi
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
  commit)
    tf=tests-$n.txt
    [ "$k" = 1 ] || tf=tests-$n-$k.txt
    echo "red $n" >"$tf"; git add "$tf"; git -c user.name=t -c user.email=t@t commit -q -m "test: red tests" ;;
esac
# $FIX/after-<n>: a shell snippet run when the session is about to end (something it did to the machine).
[ ! -f "$FIX/after-$n" ] || bash "$FIX/after-$n"
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
  SENIOR_MODE_NOW=1800000000 SENIOR_MODE_LOADAVG=0 SENIOR_MODE_DISK_FREE_MB=100000 SENIOR_MODE_DISK_FREE_FILE="$work/fix/disk-free" SENIOR_MODE_BACKOFF_JITTER=0
mkdir -p "$CLAUDE_CONFIG_DIR"
echo '{"enabledPlugins": {"senior-mode@senior-mode": true}}' >"$CLAUDE_CONFIG_DIR/settings.json"
echo no >"$FIX/linger"

git init -q --bare -b main "$work/github.com/acme/app.git"
repo="$work/app"
state="$repo/.git/senior-mode/serve"
git init -q -b main "$repo"
git -C "$repo" remote add origin "$work/github.com/acme/app.git"
mkdir -p "$repo/.claude"
fields='{"Status": {"id": "F_S", "options": {"Ready": "o1", "In progress": "o2", "In review": "o3", "Backlog": "o0", "Done": "o4"}},
  "Priority": {"id": "F_P", "options": {"P0 now": "p0", "P1 next": "p1", "P2 later": "p2", "P3 someday": "p3"}},
  "Size": {"id": "F_Z", "options": {"S": "z1", "M": "z2", "L": "z3"}}, "Paths": {"id": "F_Paths"}}'
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
once() { : >"$GH_LOG"; : >"$CLAUDE_LOG"; rm -f "$FIX"/calls-*; (cd "$repo" && SENIOR_MODE_SERVE_ONCE=1 "$cli" serve) >"$work/out" 2>&1; }
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
[ "$(cat "$state/limit-until" 2>/dev/null)" = 1800005060 ] || fail "E: reset time plus a minute not kept: $(cat "$state/limit-until" 2>&1)"
grep -q '^app-30 opus' "$CLAUDE_LOG" && fail "E: retried on Opus after a usage limit"
grep -c 'item-edit.*--single-select-option-id o1' "$GH_LOG" | grep -qx 1 || fail "E: ticket not set back to Ready: $(grep item-edit "$GH_LOG")"
grep -q 'issues/30/' "$GH_LOG" && fail "E: a usage limit was treated as a failure"
[ ! -e "$state/30.json" ] || fail "E: an outcome was recorded for a usage limit"
SENIOR_MODE_NOW=1800004000 once || fail "E: serve failed: $(cat "$work/out")"
[ ! -s "$CLAUDE_LOG" ] || fail "E: launched before the reset: $(cat "$CLAUDE_LOG")"
grep -q 'usage limit' "$work/out" || fail "E: the hold is not said: $(cat "$work/out")"
session 30-sonnet delivered pr
SENIOR_MODE_NOW=1800005030 once || fail "E: serve failed: $(cat "$work/out")"
started 30 && fail "E: launched within the minute after the reset: $(cat "$CLAUDE_LOG")"
SENIOR_MODE_NOW=1800005061 once || fail "E: serve failed: $(cat "$work/out")"
started 30 || fail "E: not launched after the reset: $(cat "$CLAUDE_LOG")"
[ ! -e "$state/limit-until" ] || fail "E: the limit is not lifted"
# A clock time with a zone: the reset time plus a minute, in the zone the message names.
fresh
board 32
printf "You've hit your limit · resets 3pm (UTC)" >"$FIX/limit-msg"
session 32-sonnet "" "" limit
SENIOR_MODE_NOW=$(date -u -d '2026-11-23 10:00' +%s) once || fail "E: serve failed: $(cat "$work/out")"
[ "$(cat "$state/limit-until" 2>/dev/null)" = "$(date -u -d '2026-11-23 15:01' +%s)" ] || fail "E: 3pm UTC not read: $(cat "$state/limit-until" 2>&1)"
fresh
printf "You've hit your limit · resets 3pm (Europe/Paris)" >"$FIX/limit-msg"
SENIOR_MODE_NOW=$(date -u -d '2026-11-23 10:00' +%s) once || fail "E: serve failed: $(cat "$work/out")"
[ "$(cat "$state/limit-until" 2>/dev/null)" = "$(TZ=Europe/Paris date -d '2026-11-23 15:01' +%s)" ] || fail "E: 3pm Paris not read: $(cat "$state/limit-until" 2>&1)"
session 32-sonnet delivered pr
SENIOR_MODE_NOW=$(TZ=Europe/Paris date -d '2026-11-23 15:00:30' +%s) once || fail "E: serve failed: $(cat "$work/out")"
started 32 && fail "E: launched before 15:01 Paris time: $(cat "$CLAUDE_LOG")"
SENIOR_MODE_NOW=$(TZ=Europe/Paris date -d '2026-11-23 15:01:01' +%s) once || fail "E: serve failed: $(cat "$work/out")"
started 32 || fail "E: not launched after 15:01 Paris time: $(cat "$work/out")"
# No reset time: 5, 10, 20, 40, then 60 minutes, never a flat hour; a ticket's own end starts the streak again.
fresh
printf 'limit reached, try later' >"$FIX/limit-msg"
session 32-sonnet "" "" limit
for want in 300 600 1200 2400 3600 3600; do
  rm -f "$state/limit-until" "$state/launches"
  SENIOR_MODE_NOW=1800000000 once || fail "E: serve failed: $(cat "$work/out")"
  [ "$(cat "$state/limit-until" 2>/dev/null)" = $((1800000000 + want)) ] || fail "E: no reset time is not $want s: $(cat "$state/limit-until" 2>&1)"
done
session 32-sonnet delivered pr
rm -f "$state/limit-until" "$state/launches"
SENIOR_MODE_NOW=1800000000 once || fail "E: serve failed: $(cat "$work/out")"
started 32 || fail "E: #32 not started after the last wait: $(cat "$work/out")"
[ ! -e "$state/limit-streak" ] || fail "E: the streak outlived a session that ran"

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
# Time unit: the cases wait on events (a file, a process) with polls of 0.1 s bounded by a count, never on a
# wall-clock budget, so a loaded machine slows them without failing them.
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
: >"$FIX/release-50"
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
# A timeout is a needs-human event; a failing webhook is said on stderr and serve goes on. batchMinutes 0: no wait (#308).
config '{"sessionTimeout": 1}' '{}' '{"webhook": "https://hooks.example/senior", "batchMinutes": 0}'
board 61
session 61-sonnet "" "" hang
touch "$FIX/curl-fails"
fresh
# The watchdog stops a session once and resumes it; this is the second stop, the ticket's own.
mkdir -p "$state" && echo 1 >"$state/61.resumed"
SENIOR_MODE_TIMEOUT_UNIT=1 once || fail "J: serve failed with a failing webhook: $(cat "$work/out")"
rm -f "$FIX/curl-fails"
grep -q '"event":"decisions"' "$CURL_LOG" || fail "J: no decisions event: $(cat "$CURL_LOG")"
grep -q 'webhook' "$work/out" || fail "J: the failing webhook is not said: $(cat "$work/out")"
# The questions are batched (#308): a needs-human event labels and mentions at once but is queued, and the webhook gets one
# `decisions` notification once the oldest has waited notify.batchMinutes (default 60), whatever the number of questions.
config '{"sessionTimeout": 1}' '{}' '{"webhook": "https://hooks.example/senior"}'
board 61
session 61-sonnet "" "" hang
: >"$CURL_LOG"
fresh
# The second stop again: the first is resumed, and which of the two timers fires first is a race.
mkdir -p "$state" && echo 1 >"$state/61.resumed"
SENIOR_MODE_TIMEOUT_UNIT=1 once || fail "J: serve failed: $(cat "$work/out")"
grep -q 'issues/61/labels.*needs-human' "$GH_LOG" || fail "J: the question did not label the ticket at once: $(cat "$GH_LOG")"
[ ! -s "$CURL_LOG" ] || fail "J: a question went out before its batch: $(cat "$CURL_LOG")"
[ "$(wc -l <"$state/questions")" = 1 ] || fail "J: the question is not queued: $(cat "$state/questions" 2>&1)"
now=$SENIOR_MODE_NOW
printf '{"at": %s, "number": 7, "url": "https://github.com/acme/app/issues/7", "reason": "first\\u0007 question"}\n' "$((now - 600))" >>"$state/questions"
printf '{"at": %s, "number": 8, "url": "https://github.com/acme/app/issues/8", "reason": "second"}\n' "$((now - 300))" >>"$state/questions"
board
once || fail "J: serve failed: $(cat "$work/out")"
[ ! -s "$CURL_LOG" ] || fail "J: the batch went out before batchMinutes: $(cat "$CURL_LOG")"
SENIOR_MODE_NOW=$((now + 3601)) once || fail "J: serve failed: $(cat "$work/out")"
[ "$(wc -l <"$CURL_LOG")" = 1 ] || fail "J: not one notification for three questions: $(cat "$CURL_LOG")"
jq -e '.event == "decisions" and .number == null and .count == 3 and (.items | map(.number) | sort) == [7, 8, 61]
  and (.reason | startswith("3 decisions wait for you: ") and length <= 300 and (test("[[:cntrl:]]") | not))' \
  <<<"$(sed -n 's/.* -d //p' "$CURL_LOG")" >/dev/null || fail "J: batched payload wrong: $(cat "$CURL_LOG")"
[ ! -s "$state/questions" ] || fail "J: the queue is not emptied: $(cat "$state/questions")"
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

# K2: the digest of the day through the webhook (#309). Sent once a day after notify.digestAt, with the pull requests
# merged and the cost of the tokens; nothing without activity, before the time, without a webhook or twice a day.
export TZ=UTC
digest_cfg='{"digestAt": "08:00", "webhook": "https://hooks.example/digest"}'
digests() { grep -c '"event":"digest"' "$CURL_LOG"; }
usage_line() { printf '{"ticket": 70, "role": "ticket", "at": "2027-01-15T06:00:00Z", "model": "claude-fable-5-2", "input": 1000000, "output": 0, "cacheRead": 0, "cacheWrite5m": 0, "cacheWrite1h": 0}\n' >"$repo/.git/senior-mode/usage.jsonl"; }
rm -f "$repo/.git/senior-mode/usage.jsonl"
config '{}' '{}' "$digest_cfg"
board
fresh
: >"$CURL_LOG"
once || fail "K2: serve failed: $(cat "$work/out")"
[ "$(digests)" = 0 ] || fail "K2: a digest with no activity: $(cat "$CURL_LOG")"
jq -c '.data.repository = {merged: {nodes: [{number: 300, title: "A change", mergedAt: "2027-01-15T07:00:00Z"}]}}' "$FIX/board.json" >"$FIX/board.tmp" &&
  mv "$FIX/board.tmp" "$FIX/board.json"
usage_line
: >"$CURL_LOG"
SENIOR_MODE_NOW=1799999000 once || fail "K2: serve failed: $(cat "$work/out")"
[ "$(digests)" = 0 ] || fail "K2: a digest before digestAt: $(cat "$CURL_LOG")"
fresh
config '{}' '{}' '{"digestAt": "08:00"}'
: >"$CURL_LOG"
once || fail "K2: serve failed: $(cat "$work/out")"
[ "$(digests)" = 0 ] || fail "K2: a digest without a webhook: $(cat "$CURL_LOG")"
config '{}' '{}' "$digest_cfg"
fresh
: >"$CURL_LOG"
once || fail "K2: serve failed: $(cat "$work/out")"
[ "$(digests)" = 1 ] || fail "K2: no digest at digestAt: $(cat "$work/out")"
grep -q 'https://hooks.example/digest' "$CURL_LOG" || fail "K2: webhook url not called: $(cat "$CURL_LOG")"
jq -e '.event == "digest" and .repo == "acme/app" and .number == null and .url == null and .digest.merged == 1
  and .digest.tokens.usd == 8 and .digest.tokens.input == 1000000 and (.digest.board | has("drift"))
  and (.reason | test("Merged pull requests: 1")) and (.reason | test("Needs a human: nothing")) and (.reason | test("Token cost: \\$8 "))' \
  <<<"$(sed -n 's/.* -d //p' "$CURL_LOG" | head -n 1)" >/dev/null || fail "K2: digest payload wrong: $(cat "$CURL_LOG")"
[ "$(cat "$state/digest-at")" = 2027-01-15 ] || fail "K2: the day is not kept: $(cat "$state/digest-at" 2>&1)"
: >"$CURL_LOG"
once || fail "K2: serve failed: $(cat "$work/out")"
[ "$(digests)" = 0 ] || fail "K2: a second digest the same day"
SENIOR_MODE_NOW=1800086400 once || fail "K2: serve failed: $(cat "$work/out")"
[ "$(digests)" = 1 ] || fail "K2: no digest the next day: $(cat "$work/out")"
rm -f "$repo/.git/senior-mode/usage.jsonl"
unset TZ

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
mkdir -p "$state"
echo 1799999900 >"$state/ready-last"
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
# A ticket the batch session gives up is no longer of the batch: the merge of its pull request leaves it open.
board 21 22
paths_of 21 'src/a/**'
paths_of 22 'src/a/x.ts'
session 21-sonnet "" pr
printf '#21 outgrown: fixes code of an unmerged pull request\n#22 delivered\n' >"$FIX/outcome-21"
fresh
once || fail "J: serve failed: $(cat "$work/out")"
[ "$(cat "$state/21.batch")" = 22 ] || fail "J: the batch keeps a ticket it gave up: $(cat "$state/21.batch")"
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
# The cut is kept for the rest of the poll (spec 373, section 2): nothing that needs GitHub starts, and the next poll does.
started 64 && fail "Y2: a ticket started in a poll where gh did not answer: $(cat "$work/out")"
[ ! -e "$state/gh-down" ] || fail "Y2: the cut outlived serve: $(ls "$state")"
once || fail "Y2: serve failed on the next poll: $(cat "$work/out")"
started 64 || fail "Y2: the next poll did not launch #64: $(cat "$work/out")"

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
grep -q 'end 3 in a row' "$work/out" || fail "AA: the third end is not said: $(cat "$work/out")"
# A transient end never becomes a ticket's: the tenth in a row sends one environment alert, the retries go on at the
# longest delay, no failure, no escalation, no needs-human; the session that finally runs sends `recovered`.
config '{"maxConsecutiveFailures": 1}' '{}' '{"webhook": "https://hooks.example/h"}'
board 70
for k in 9 10 11 12; do
  rm -f "$FIX"/flaky-done-*
  fresh
  mkdir -p "$state"
  echo $((k - 1)) >"$state/70.transient"
  : >"$CURL_LOG"
  SENIOR_MODE_NOW=1800000000 once || fail "AA: serve failed: $(cat "$work/out")"
  grep -q '^app-70 opus' "$CLAUDE_LOG" && fail "AA: transient end $k escalated: $(cat "$CLAUDE_LOG")"
  [ ! -e "$state/paused" ] && [ ! -e "$state/70.json" ] || fail "AA: transient end $k counted as a failure"
  grep -q 'issues/70/' "$GH_LOG" && fail "AA: transient end $k made the ticket needs-human"
  [ "$(cat "$state/70.transient")" = "$k" ] || fail "AA: end $k not counted: $(cat "$state/70.transient" 2>&1)"
  want=$((k < 6 ? 30 * (1 << (k - 1)) : 900))
  [ "$(cat "$state/70.retry" 2>/dev/null)" = $((1800000000 + want)) ] || fail "AA: end $k not retried in ${want}s: $(cat "$state/70.retry" 2>&1)"
  alerts=$(grep -c '"event":"environment"' "$CURL_LOG" || true)
  if [ "$k" = 10 ]; then
    [ "$alerts" = 1 ] || fail "AA: the tenth end sent $alerts environment alerts: $(cat "$CURL_LOG")"
    grep -q 'unreachable for about an hour' "$CURL_LOG" || fail "AA: the alert does not say why: $(cat "$CURL_LOG")"
  else
    [ "$alerts" = 0 ] || fail "AA: end $k sent an environment alert: $(cat "$CURL_LOG")"
  fi
done
: >"$CURL_LOG"
SENIOR_MODE_NOW=1800000901 once || fail "AA: serve failed: $(cat "$work/out")"
grep -q '"event":"recovered"' "$CURL_LOG" || fail "AA: no recovered alert once the API answers: $(cat "$CURL_LOG")"
outcome_of 70 delivered AA
# A session that dies at startup with no output at all is a transient end too (#334); the third in a row, across tickets,
# holds every launch until launch-backoff-until, said in the log, and escalates nothing.
config '{"parallel": 3, "maxConsecutiveFailures": 1}'
board 76 77 78 79
for t in 76 77 78; do session "$t-sonnet" delivered pr "flaky:Claude Code is still loading your organization's settings."; done
session 79-sonnet delivered pr
rm -f "$FIX"/flaky-done-*
fresh
SENIOR_MODE_NOW=1800000000 once || fail "AA: serve failed: $(cat "$work/out")"
grep -q '^app-7[678] opus' "$CLAUDE_LOG" && fail "AA: a startup failure escalated: $(cat "$CLAUDE_LOG")"
[ "$(cat "$state/startup-streak" 2>/dev/null)" = 3 ] || fail "AA: the startup streak is not 3: $(cat "$state/startup-streak" 2>&1)"
[ "$(cut -d' ' -f1 "$state/launch-backoff-until" 2>/dev/null)" = 1800000120 ] || fail "AA: no launch backoff of 120s: $(cat "$state/launch-backoff-until" 2>&1)"
grep -q '3 sessions in a row died at startup; not launching until' "$work/out" || fail "AA: the streak is not said: $(cat "$work/out")"
[ ! -e "$state/paused" ] || fail "AA: startup failures tripped the breaker"
SENIOR_MODE_NOW=1800000060 once || fail "AA: serve failed: $(cat "$work/out")"
[ ! -s "$CLAUDE_LOG" ] || fail "AA: a session started in the launch backoff: $(cat "$CLAUDE_LOG")"
grep -q 'died at startup in a row' "$work/out" || fail "AA: the launch backoff is not said: $(cat "$work/out")"
SENIOR_MODE_NOW=1800000121 once || fail "AA: serve failed: $(cat "$work/out")"
started 76 || fail "AA: not launched after the launch backoff: $(cat "$CLAUDE_LOG")"
# No output and exit 1 within autonomy.startupSeconds: the same, by itself.
board 80
rm -f "$FIX/claude-80-sonnet"
fresh
SENIOR_MODE_NOW=1800000000 once || fail "AA: serve failed: $(cat "$work/out")"
[ "$(cat "$state/80.transient" 2>/dev/null)" = 1 ] || fail "AA: a session with no output at startup is not a transient end: $(cat "$work/out")"
{ [ ! -e "$state/80.json" ] && ! grep -q 'issues/80/' "$GH_LOG"; } || fail "AA: a session with no output at startup counted as a failure"

# AB: a disk problem (#377, spec 373 section 1): the session's end cleans (logs over 7 days), probes again and, still
# red, holds every launch with the exact cause, one alert, no failure, no needs-human; the cheap probes run at each
# poll, and a green one lifts the hold by itself with a `recovered` alert and the ticket starts.
config '{"maxConsecutiveFailures": 1}' '{}' '{"webhook": "https://hooks.example/h"}'
board 72 73
session 72-sonnet "failed: environment: npm install failed: ENOSPC: no space left on device"
session 73-sonnet delivered pr
fresh
mkdir -p "$state"
echo old >"$state/9-sonnet.log"
echo new >"$state/10-sonnet.log"
touch -d '10 days ago' "$state/9-sonnet.log"
: >"$FIX/status-updates"
: >"$CURL_LOG"
echo 'echo 100 >"$FIX/disk-free"' >"$FIX/after-72"
SENIOR_MODE_NOW=1800000000 once || fail "AB: serve failed: $(cat "$work/out")"
grep -q '^app-72 opus' "$CLAUDE_LOG" && fail "AB: an environment end was escalated"
[ ! -e "$state/9-sonnet.log" ] && [ -e "$state/10-sonnet.log" ] || fail "AB: the logs over 7 days are not the ones removed: $(ls "$state")"
grep -q 'holding all launches, environment problem (disk): #72: .*no space left' "$work/out" || fail "AB: no diagnosis in the log: $(cat "$work/out")"
[ "$(jq -r .cause "$state/held" 2>/dev/null)" = disk ] || fail "AB: no hold: $(cat "$state/held" 2>&1)"
jq -e '.detail | test("disk full, 100 MB free of autonomy.minDiskMB 2048 on /")' "$state/held" >/dev/null || fail "AB: the hold does not name the disk and mount: $(cat "$state/held")"
[ ! -e "$state/paused" ] && [ ! -e "$state/72.json" ] || fail "AB: an environment end counted as a failure"
grep -q 'issues/72/' "$GH_LOG" && fail "AB: an environment end made the ticket needs-human"
grep -q AT_RISK "$FIX/status-updates" || fail "AB: the hold is not in the Project status: $(cat "$FIX/status-updates")"
[ "$(grep -c '"event":"environment"' "$CURL_LOG")" = 1 ] || fail "AB: not exactly one alert: $(cat "$CURL_LOG" 2>&1)"
grep -c 'item-edit.*--single-select-option-id o1' "$GH_LOG" | grep -qx 1 || fail "AB: #72 not back to Ready"
[ ! -s "$CLAUDE_LOG" ] || [ "$(grep -c '^app-' "$CLAUDE_LOG")" = 1 ] || fail "AB: a second session started in the hold: $(cat "$CLAUDE_LOG")"
# Held: nothing starts, the cheap probe is red at every poll, and there is still one alert.
: >"$CLAUDE_LOG"
SENIOR_MODE_NOW=1800000030 once || fail "AB: serve failed: $(cat "$work/out")"
[ ! -s "$CLAUDE_LOG" ] || fail "AB: a session started while held: $(cat "$CLAUDE_LOG")"
grep -q 'environment problem (disk)' "$work/out" || fail "AB: the hold is not said: $(cat "$work/out")"
grep -q 'the probe is red' "$work/out" || fail "AB: a red probe is not said: $(cat "$work/out")"
[ "$(grep -c '"event":"environment"' "$CURL_LOG")" = 1 ] || fail "AB: a second alert for the same hold: $(cat "$CURL_LOG")"
session 72-sonnet delivered pr
rm -f "$FIX/disk-free" "$FIX/after-72"
SENIOR_MODE_NOW=1800000061 once || fail "AB: serve failed: $(cat "$work/out")"
grep -q 'environment is healthy again' "$work/out" || fail "AB: not resumed on a green probe: $(cat "$work/out")"
[ ! -e "$state/held" ] || fail "AB: the hold is not lifted"
started 72 || fail "AB: #72 not started after the hold: $(cat "$CLAUDE_LOG")"
grep -q ON_TRACK "$FIX/status-updates" || fail "AB: the resume is not in the Project status"
[ "$(grep -c '"event":"recovered"' "$CURL_LOG")" = 1 ] || fail "AB: no recovered alert: $(cat "$CURL_LOG")"
# With room again after the clean, a session dead of ENOSPC is a transient end: no hold, no failure.
board 72
session 72-sonnet delivered pr "flaky:ENOSPC: no space left on device"
rm -f "$FIX"/flaky-done-*
fresh
SENIOR_MODE_NOW=1800000000 once || fail "AB: serve failed: $(cat "$work/out")"
[ ! -e "$state/held" ] && [ "$(cat "$state/72.transient" 2>/dev/null)" = 1 ] || fail "AB: ENOSPC with room again is not a transient end: $(cat "$work/out")"
# gh not signed in: the probe is gh's; nothing is labelled needs-human; it resumes by itself once gh answers.
board 74
session 74-sonnet "failed: environment: HTTP 401 Bad credentials"
fresh
touch "$FIX/gh-auth-bad"
SENIOR_MODE_NOW=1800000000 once || fail "AB: serve failed: $(cat "$work/out")"
[ "$(jq -r .cause "$state/held" 2>/dev/null)" = gh-auth ] || fail "AB: gh auth not recognised: $(cat "$state/held" 2>&1)"
grep -q 'issues/74/' "$GH_LOG" && fail "AB: a gh auth problem made the ticket needs-human"
SENIOR_MODE_NOW=1800000061 once || fail "AB: serve failed: $(cat "$work/out")"
grep -q 'the probe is red' "$work/out" || fail "AB: gh auth probe not red: $(cat "$work/out")"
rm -f "$FIX/gh-auth-bad"
session 74-sonnet delivered pr
SENIOR_MODE_NOW=1800000122 once || fail "AB: serve failed: $(cat "$work/out")"
{ [ ! -e "$state/held" ] && started 74; } || fail "AB: not resumed once gh answers: $(cat "$work/out")"
# --resume lifts a hold and the breaker's pause by hand, and sets the trips to 0.
printf '%s\n%s\n' 1800009999 "paused by a test" >"$state/paused"
echo "2 1800000000" >"$state/breaker"
jq -nc '{cause: "deps", since: 1800000000, probe: "expensive", nextProbe: 1800009999, detail: "x"}' >"$state/held"
(cd "$repo" && "$cli" serve --resume) >"$work/out" 2>&1 || fail "AB: --resume failed: $(cat "$work/out")"
[ ! -e "$state/held" ] && [ ! -e "$state/paused" ] && [ ! -e "$state/breaker" ] || fail "AB: --resume left a hold: $(ls "$state")"
# Diagnose before blame: an end with no verdict while a cheap probe is red is the environment's, not the ticket's. A
# session's own `failed:` verdict stands (one failure for the breaker) and the hold starts before the next launch.
config '{"maxConsecutiveFailures": 1, "escalate": false}'
board 81
echo 'touch "$FIX/gh-auth-bad"' >"$FIX/after-81"
session 81-sonnet ""
fresh
SENIOR_MODE_NOW=1800000000 once || fail "AB: serve failed: $(cat "$work/out")"
rm -f "$FIX/gh-auth-bad"
[ "$(jq -r .cause "$state/held" 2>/dev/null)" = gh-auth ] || fail "AB: an end with no verdict while gh is signed out is not the environment's: $(cat "$work/out")"
[ ! -e "$state/81.json" ] && [ ! -e "$state/paused" ] || fail "AB: it was counted as a failure: $(ls "$state")"
grep -q 'issues/81/' "$GH_LOG" && fail "AB: it made the ticket needs-human"
session 81-sonnet "failed: broke"
fresh
SENIOR_MODE_NOW=1800000000 once || fail "AB: serve failed: $(cat "$work/out")"
rm -f "$FIX/gh-auth-bad"
outcome_of 81 failed AB
[ -e "$state/paused" ] && [ "$(jq -r .cause "$state/held" 2>/dev/null)" = gh-auth ] || fail "AB: a failed verdict is not both a failure and a hold: $(ls "$state")"
# With every probe green, an end with no verdict is the ticket's.
rm -f "$FIX/after-81"
session 81-sonnet ""
fresh
SENIOR_MODE_NOW=1800000000 once || fail "AB: serve failed: $(cat "$work/out")"
[ ! -e "$state/held" ] && outcome_of 81 failed AB

# AB2: a `failed: environment:` with a cause serve has no pattern for, and a probe that is always green (#569), is not
# launched again in a loop: it holds for 1, 2 minutes, the third end is needs-human with the last output and no more
# launch, one alert for the pause, nothing sent by the retries. A new commit on the base branch lets it start again with
# a fresh count; `--resume` also starts the count again.
config '{}' '{}' '{"webhook": "https://hooks.example/h"}'
board 691
session 691-sonnet "failed: environment: the build box is haunted"
fresh
: >"$CURL_LOG"
launches=0
poll691() { SENIOR_MODE_NOW=$1 once || fail "AB2: serve failed: $(cat "$work/out")"; if started 691; then launches=$((launches + 1)); fi; }
poll691 1800000000
[ "$launches" = 1 ] || fail "AB2: the first launch is missing: $(cat "$work/out")"
[ "$(jq -r .cause "$state/held" 2>/dev/null)" = unknown ] || fail "AB2: no unknown hold: $(cat "$state/held" 2>&1)"
[ "$(jq -r .retryAt "$state/held")" = 1800000060 ] || fail "AB2: the first backoff is not 1 minute: $(cat "$state/held")"
grep -q 'issues/691/' "$GH_LOG" && fail "AB2: the first end made the ticket needs-human"
poll691 1800000030
[ "$launches" = 1 ] || fail "AB2: relaunched inside the backoff: $(cat "$work/out")"
poll691 1800000061
[ "$launches" = 2 ] || fail "AB2: no retry after the backoff: $(cat "$work/out")"
[ "$(jq -r .retryAt "$state/held")" = 1800000181 ] || fail "AB2: the second backoff is not 2 minutes: $(cat "$state/held")"
poll691 1800000150
[ "$launches" = 2 ] || fail "AB2: relaunched inside the second backoff: $(cat "$work/out")"
poll691 1800000182
[ "$launches" = 3 ] || fail "AB2: no third launch: $(cat "$work/out")"
grep -q 'issues/691/labels' "$GH_LOG" || fail "AB2: the third end did not raise needs-human: $(cat "$GH_LOG")"
grep -q 'the build box is haunted' "$state/questions" || fail "AB2: the decision has no error output: $(cat "$state/questions" 2>&1)"
[ "$(jq -r .retryAt "$state/held")" = 0 ] || fail "AB2: attempts used up but a retry is planned: $(cat "$state/held")"
for t in 1800000300 1800010000 1800090000; do poll691 "$t"; done
[ "$launches" = 3 ] || fail "AB2: $launches launches of one ticket with nothing changed: $(cat "$work/out")"
grep -q 'attempts used up' "$work/out" || fail "AB2: the stop is not said: $(cat "$work/out")"
[ "$(grep -c '"event":"environment"' "$CURL_LOG")" = 1 ] || fail "AB2: not one alert for the pause: $(cat "$CURL_LOG")"
[ "$(grep -c '"event":"recovered"' "$CURL_LOG")" = 0 ] || fail "AB2: a retry sent recovered: $(cat "$CURL_LOG")"
[ ! -e "$state/paused" ] && [ ! -e "$state/691.json" ] || fail "AB2: the unknown failures counted for the breaker"
# A new commit on the base branch: one new attempt, counted from 1.
git -C "$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "fix: something"
git -C "$repo" push -q origin main
poll691 1800090060
[ "$launches" = 4 ] || fail "AB2: a change on the base branch did not lift the hold: $(cat "$work/out")"
[ "$(jq -r .retryAt "$state/held")" = 1800090120 ] || fail "AB2: the count did not start again: $(cat "$state/held")"
# --resume lifts the hold and starts the count again.
(cd "$repo" && "$cli" serve --resume) >"$work/out" 2>&1 || fail "AB2: --resume failed: $(cat "$work/out")"
[ ! -e "$state/held" ] && [ ! -e "$state/691.envfail" ] || fail "AB2: --resume left the count: $(ls "$state")"
# The backoff is capped by serve.unknownBackoffMax and the attempts by serve.unknownMaxAttempts.
config '{}' '{"unknownBackoffMax": 1, "unknownMaxAttempts": 3}'
fresh
launches=0
poll691 1800100000
poll691 1800100061
[ "$(jq -r .retryAt "$state/held")" = 1800100121 ] || fail "AB2: the second backoff is not capped at 1 minute: $(cat "$state/held")"
config '{}' '{"unknownMaxAttempts": 2}'
fresh
launches=0
poll691 1800200000
poll691 1800200061
[ "$(jq -r .retryAt "$state/held")" = 0 ] && [ "$launches" = 2 ] || fail "AB2: two attempts are not the cap: $launches $(cat "$state/held")"

# AC: the breaker counts ticket failures only; its pause is min(serve.breakerMax, serve.breakerCooldown * 2^(trips-1)),
# 15, 30, 60, 120 then 240 minutes by default, and the trips start again after 24 hours without one (#377).
config '{"parallel": 1, "maxConsecutiveFailures": 1, "escalate": false}' '{"breakerCooldown": 100, "breakerMax": 350}'
board 75
session 75-sonnet "failed: broke"
fresh
SENIOR_MODE_NOW=1800000000 once || fail "AC: serve failed: $(cat "$work/out")"
[ "$(sed -n 1p "$state/paused" 2>/dev/null)" = 1800000100 ] || fail "AC: first pause is not 100s: $(cat "$state/paused" 2>&1)"
[ "$(cut -d' ' -f1 "$state/breaker")" = 1 ] || fail "AC: trips not counted: $(cat "$state/breaker" 2>&1)"
rm -f "$state/paused"
SENIOR_MODE_NOW=1800000000 once || fail "AC: serve failed: $(cat "$work/out")"
[ "$(sed -n 1p "$state/paused" 2>/dev/null)" = 1800000200 ] || fail "AC: second pause is not 200s: $(cat "$state/paused" 2>&1)"
rm -f "$state/paused"
SENIOR_MODE_NOW=1800000000 once || fail "AC: serve failed: $(cat "$work/out")"
[ "$(sed -n 1p "$state/paused" 2>/dev/null)" = 1800000350 ] || fail "AC: third pause is not capped at breakerMax: $(cat "$state/paused" 2>&1)"
# A delivery is not a merge: the trips stay. 24 hours without a trip start them again.
rm -f "$state/paused"
session 75-sonnet delivered pr
SENIOR_MODE_NOW=1800000000 once || fail "AC: serve failed: $(cat "$work/out")"
[ "$(cut -d' ' -f1 "$state/breaker" 2>/dev/null)" = 3 ] || fail "AC: a delivery reset the trips: $(cat "$state/breaker" 2>&1)"
session 75-sonnet "failed: broke"
rm -f "$state/paused"
SENIOR_MODE_NOW=$((1800000000 + 86400)) once || fail "AC: serve failed: $(cat "$work/out")"
[ "$(sed -n 1p "$state/paused" 2>/dev/null)" = $((1800000000 + 86400 + 100)) ] || fail "AC: trips not reset after 24 hours: $(cat "$state/paused" 2>&1)"
# Five transient ends never trip it.
config '{"parallel": 1, "maxConsecutiveFailures": 1, "escalate": false}' '{"breakerCooldown": 100}'
board 75
session 75-sonnet delivered pr "flaky5:API Error: 529 overloaded_error"
rm -f "$FIX"/flaky-done-*
fresh
for t in 0 31 92 213 454 935; do
  SENIOR_MODE_NOW=$((1800000000 + t)) once || fail "AC: serve failed: $(cat "$work/out")"
  [ ! -e "$state/paused" ] || fail "AC: transient ends tripped the breaker at +$t: $(cat "$work/out")"
done
outcome_of 75 delivered AC
grep -q '^app-75 opus' "$CLAUDE_LOG" && fail "AC: escalated"

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
  [ "$(cd "$repo" && "$cli" config get serve.breakerCooldown)" = 900 ] &&
  [ "$(cd "$repo" && "$cli" config get serve.breakerMax)" = 14400 ] &&
  [ "$(cd "$repo" && "$cli" config get serve.backoffBase)" = 30 ] &&
  [ "$(cd "$repo" && "$cli" config get serve.backoffMax)" = 900 ] &&
  [ "$(cd "$repo" && "$cli" config get autonomy.minDiskMB)" = 2048 ] &&
  [ "$(cd "$repo" && "$cli" config get autonomy.startupSeconds)" = 30 ] &&
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
grep -q 'red-tests verify' "$state/63.prompt" && fail "U: the prompt asks to verify tests the test-author recorded (#563)"
grep -q '^app-64 sonnet run=1 role=ticket$' "$CLAUDE_LOG" && fail "U: a ticket session after a failed test-author"
# #352: an M ticket session is asked for a plan the architect approves before any code; an S ticket's is not.
grep -q 'Plan first (size M)' "$state/63.prompt" || fail "U: the prompt of an M ticket has no plan step: $(cat "$state/63.prompt")"
grep -q 'plan-rejected:' "$state/63.prompt" || fail "U: the prompt of an M ticket has no plan-rejected outcome"
outcome_of 64 failed M
grep -c 'item-edit.*--single-select-option-id o0' "$GH_LOG" | grep -qx 1 || fail "U: #64 is not back in Backlog: $(grep item-edit "$GH_LOG")"
boardx "63:Ready:M:P1 next"
rm -f "$FIX/pulls-63"
fresh
once || fail "U: serve failed: $(cat "$work/out")"
grep -q '^app-63 sonnet run=1 role=test-author$' "$CLAUDE_LOG" && fail "U: the red tests are recorded, no test-author again: $(cat "$CLAUDE_LOG")"
grep -q '^app-63 sonnet run=1 role=ticket$' "$CLAUDE_LOG" || fail "U: no ticket session"
config '{}'

# UP: an M ticket delivered without a plan the architect approved is not delivered (#352); an S ticket needs none.
config '{"parallel": 2, "escalate": false}'
boardx "66:Ready:M:P1 next" "67:Ready:S:P1 next"
prs_reset
session 66-sonnet-test-author delivered "" "" commit
session 66-sonnet-ticket delivered pr
echo none >"$FIX/plan-66"
session 67-sonnet delivered pr
echo none >"$FIX/plan-67"
fresh
once || fail "UP: serve failed: $(cat "$work/out")"
outcome_of 66 failed UP
grep -q 'no plan' "$state/66.json" || fail "UP: the reason does not say the plan is missing: $(cat "$state/66.json")"
outcome_of 67 delivered UP
grep -q 'Plan first' "$state/67.prompt" && fail "UP: an S ticket has a plan step"
# #346: the ticket session writes a checkpoint at each commit and fills in the draft pull request.
for want in 'senior-mode checkpoint --done' 'senior-mode:checkpoint -->' 'gh pr ready'; do
  grep -qF -- "$want" "$state/67.prompt" || fail "UP: the ticket prompt misses '$want'"
done
rm -f "$FIX"/plan-6*
config '{}'

# UW: the implementer of an M ticket reports a red test as wrong (#589): the test-author is called back once, with the
# finding, on the same branch, then the implementer again; a second report is needs-human, as before.
boardx "880:Ready:M:P1 next" "881:Ready:M:P1 next"
prs_reset
session 880-sonnet-test-author delivered "" "" commit
session 880-sonnet-test-author.2 delivered "" "" commit
session 880-sonnet-ticket.1 "wrong-test: tests-880.txt anchors on # so it never fails for the right reason"
session 880-sonnet-ticket.2 delivered pr
session 881-sonnet-test-author delivered "" "" commit
session 881-sonnet-ticket.1 "wrong-test: the first finding"
session 881-sonnet-ticket.2 "wrong-test: the second finding"
config '{"parallel": 2}'
fresh
rm -f "$FIX"/prompt-*
once || fail "UW: serve failed: $(cat "$work/out")"
seq880=$(grep '^app-880 ' "$CLAUDE_LOG" | sed -E 's/.*role=//' | paste -sd' ')
[ "$seq880" = "test-author ticket test-author ticket" ] || fail "UW: #880 sessions: $seq880"
grep -q 'tests-880.txt anchors on #' "$FIX/prompt-880-test-author-2" || fail "UW: the finding is not in the test-author prompt: $(cat "$FIX/prompt-880-test-author-2" 2>&1)"
grep -q 'wrong-test' "$FIX/prompt-880-ticket-1" || fail "UW: the ticket prompt does not offer the wrong-test outcome"
grep -qx 'tests-880.txt' "$repo/.git/senior-mode/runs/880/red-tests" || fail "UW: the first red tests are not recorded"
grep -qx 'tests-880-2.txt' "$repo/.git/senior-mode/runs/880/red-tests" || fail "UW: the revised tests are not recorded: $(cat "$repo/.git/senior-mode/runs/880/red-tests")"
grep -q 'written and committed already' "$state/880.prompt" || fail "UW: the second ticket session has no ticket prompt: $(cat "$state/880.prompt")"
outcome_of 880 delivered UW
seq881=$(grep '^app-881 ' "$CLAUDE_LOG" | sed -E 's/.*role=//' | paste -sd' ')
[ "$seq881" = "test-author ticket test-author ticket" ] || fail "UW: #881 sessions: $seq881"
outcome_of 881 failed UW
grep -q 'issues/881/labels' "$GH_LOG" || fail "UW: no needs-human after a second wrong test: $(grep 881 "$GH_LOG")"
grep -q 'issues/880/labels' "$GH_LOG" && fail "UW: needs-human on #880, which was delivered"
grep -c 'item-edit.*--single-select-option-id o0' "$GH_LOG" | grep -qx 1 || fail "UW: #881 is not back in Backlog: $(grep item-edit "$GH_LOG")"
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
[ "$(cat "$state/limit-until" 2>/dev/null)" = 1800005060 ] || fail "V: reset time not kept: $(cat "$state/limit-until" 2>&1)"
grep -q 'issues/65/' "$GH_LOG" && fail "V: a usage limit labelled the ticket: $(grep issues/65/ "$GH_LOG")"
grep -q 'item-edit' "$GH_LOG" && ! grep -q -- '--single-select-option-id o4' "$GH_LOG" && fail "V: a status was changed for a reviewer that hit the limit"
[ -z "$(status_of "$sha" senior-mode/review)" ] || fail "V: a review status was set"
session 65-opus-reviewer "reviewed: success" "" "" review:success
pr 175 feat/75-x "$sha75" clean
SENIOR_MODE_NOW=1800004000 once || fail "V: serve failed: $(cat "$work/out")"
[ ! -s "$CLAUDE_LOG" ] || fail "V: a reviewer started before the reset: $(cat "$CLAUDE_LOG")"
grep -q 'usage limit' "$work/out" || fail "V: the hold is not said"
grep -q "^pr merge 175 --rebase --match-head-commit $sha75 -R acme/app" "$GH_LOG" || fail "V: no merge during the hold: $(grep '^pr ' "$GH_LOG")"
SENIOR_MODE_NOW=1800005061 once || fail "V: serve failed: $(cat "$work/out")"
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
config '{}' '{}' '{"webhook": "https://hooks.example/senior", "batchMinutes": 0}'
rm -f "$state/questions"
jq '.github.protection = "none"' "$repo/.claude/senior-mode.json" >"$work/cfg.json" && mv "$work/cfg.json" "$repo/.claude/senior-mode.json"
: >"$CURL_LOG"
once || fail "W: serve failed: $(cat "$work/out")"
grep -q '^pr merge' "$GH_LOG" && fail "W: merged without server protection"
grep -q 'issues/166/labels.*needs-human' "$GH_LOG" || fail "W: #166 not labelled needs-human: $(cat "$GH_LOG")"
grep -q 'issues/66/labels.*needs-human' "$GH_LOG" || fail "W: ticket #66 not labelled needs-human: $(cat "$GH_LOG")"
grep -q 'issues/166/comments.*@acme.*no branch protection' "$GH_LOG" || fail "W: no comment with the reason: $(cat "$GH_LOG")"
[ "$(grep -c 'hooks.example' "$CURL_LOG")" = 1 ] || fail "W: the alert did not fire once: $(cat "$CURL_LOG")"
jq -e '.event == "decisions" and .count == 1 and .items[0].number == 166 and (.items[0].reason | test("no branch protection"))' <<<"$(sed -n 's/.* -d //p' "$CURL_LOG")" >/dev/null ||
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

# XC: a rebase whose new head has the tree of a commit with senior-mode/ci success (#412) runs no check: the status is carried
# over with a description naming the tree and the commit, one comment says so; another tree runs check and publish as in X.
config '{}'
boardx "90:In review:S:P1 next" "91:In review:S:P1 next"
prs_reset
old90=$(mkbranch feat/90-x f90.txt)
config '{}'
new90=$(mkrebased feat/90-x "$old90")
pr 190 feat/90-x "$old90" behind
green "$old90"
echo "$new90" >"$FIX/rebase-190"
fresh
once || fail "XC: serve failed: $(cat "$work/out")"
tree90=$(git -C "$repo" rev-parse "$new90^{tree}")
[ "$(git -C "$repo" rev-parse "$old90^{tree}")" = "$tree90" ] || fail "XC: the fixture's trees differ"
grep -q '^pr update-branch 190 --rebase' "$GH_LOG" || fail "XC: #90 not rebased: $(grep '^pr ' "$GH_LOG")"
[ ! -e "$state/90.check.log" ] || fail "XC: check ran on a tree that passed it: $(cat "$state/90.check.log")"
grep -q "statuses/$new90 .*state=success.*context=senior-mode/ci.*description=carried over from ${old90:0:7}: same tree ${tree90:0:12}" "$GH_LOG" ||
  fail "XC: the status does not name the tree and the commit: $(grep "statuses/$new90" "$GH_LOG")"
[ "$(status_of "$new90" senior-mode/ci)" = success ] || fail "XC: no senior-mode/ci success on the new head"
[ "$(grep -c 'issues/190/comments' "$GH_LOG")" = 1 ] || fail "XC: not one comment: $(grep 'issues/190/comments' "$GH_LOG")"
grep 'issues/190/comments' "$GH_LOG" | grep -q "${tree90:0:12}.*${old90:0:7}.*no check ran\|${old90:0:7}.*${tree90:0:12}.*no check ran" ||
  fail "XC: the comment does not say the tree, the commit and that no check ran: $(grep 'issues/190/comments' "$GH_LOG")"
[ "$(status_of "$new90" senior-mode/review)" = success ] || fail "XC: the review is not carried over"
grep -q "^pr merge 190 --rebase --match-head-commit $new90 " "$GH_LOG" || fail "XC: not merged on the new head: $(grep '^pr ' "$GH_LOG")"
# Another tree (main moved on): check and publish run as today.
prs_reset
old91=$(mkbranch feat/91-x f91.txt)
echo moved >"$repo/moved-main.txt"
git -C "$repo" add -A
git -C "$repo" -c user.name=t -c user.email=t@t commit -q -m "feat: main moves"
git -C "$repo" push -q origin main
new91=$(mkrebased feat/91-x "$old91")
pr 191 feat/91-x "$old91" behind
green "$old91"
echo "$new91" >"$FIX/rebase-191"
fresh
once || fail "XC: serve failed: $(cat "$work/out")"
[ "$(git -C "$repo" rev-parse "$old91^{tree}")" != "$(git -C "$repo" rev-parse "$new91^{tree}")" ] || fail "XC: the fixture's trees are the same"
[ -e "$state/91.check.log" ] || fail "XC: no check on a tree no check passed"
grep -q "statuses/$new91 .*context=senior-mode/ci" "$GH_LOG" || fail "XC: publish did not run: $(grep statuses "$GH_LOG")"
grep -q "statuses/$new91 .*context=senior-mode/ci.*description=carried over from" "$GH_LOG" && fail "XC: a status carried over for another tree"
grep 'issues/191/comments' "$GH_LOG" | grep -q 'check and publish ran again' || fail "XC: the comment does not say check ran: $(grep 'issues/191/comments' "$GH_LOG")"

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

# LP (#523, ADR 0032): github.protection local. GitHub has no up-to-date rule to call a branch behind (it says clean), so
# senior-mode reads the distance: a branch behind is rebased by the server and merges on its new head; one up to date merges.
# A missing status waits, and under none nothing merges.
boardx "73:In review:S:P1 next" "74:In review:S:P1 next"
prs_reset
old73=$(mkbranch feat/73-x f73.txt)
sha74=$(mkbranch feat/74-x f74.txt)
config '{}'
new73=$(mkrebased feat/73-x "$old73")
jq '.github.protection = "local" | .github.requiredChecks = false' "$repo/.claude/senior-mode.json" >"$work/cfg.json" && mv "$work/cfg.json" "$repo/.claude/senior-mode.json"
pr 173 feat/73-x "$old73" clean
green "$old73"
echo 2 >"$FIX/behind-$old73"
echo "$new73" >"$FIX/rebase-173"
fresh
once || fail "LP: serve failed: $(cat "$work/out")"
grep -q '^pr update-branch 173 --rebase -R acme/app$' "$GH_LOG" || fail "LP: a branch behind is not rebased: $(grep '^pr ' "$GH_LOG")"
grep -q "^pr merge 173 --rebase --match-head-commit $new73 " "$GH_LOG" || fail "LP: not merged on the new head: $(grep '^pr ' "$GH_LOG")"
prs_reset
pr 174 feat/74-x "$sha74" clean
green "$sha74"
fresh
once || fail "LP: serve failed: $(cat "$work/out")"
grep -q '^pr update-branch' "$GH_LOG" && fail "LP: a branch up to date is rebased"
grep -q "^pr merge 174 --rebase --match-head-commit $sha74 " "$GH_LOG" || fail "LP: an up-to-date branch is not merged: $(grep '^pr ' "$GH_LOG")"
prs_reset
pr 174 feat/74-x "$sha74" clean
st "$sha74" "senior-mode/ci success" "senior-mode/review success"
fresh
once || fail "LP: serve failed: $(cat "$work/out")"
grep -q '^pr merge' "$GH_LOG" && fail "LP: merged with senior-mode/security missing: $(grep '^pr ' "$GH_LOG")"
grep -q 'Waiting for a human.*#74.*senior-mode/security not green' "$work/out" || fail "LP: the missing status is not said: $(cat "$work/out")"

# AC: the reviewer runs on another model than the implementer (#304). Sonnet implemented: Opus reviews. A ticket that
# ended on Opus (escalated) is reviewed on review.otherModel. review.crossModel false keeps Opus. The model is
# written in the description of senior-mode/review.
config '{}'
sha=$(mkbranch feat/95-x f95.txt)
boardx "95:In review:S:P1 next"
prs_reset
pr 195 feat/95-x "$sha" clean
st "$sha" "senior-mode/ci success"
session 95-opus-reviewer "reviewed: success" "" "" review:success
fresh
once || fail "AC: serve failed: $(cat "$work/out")"
grep -q '^app-review-95 opus run=1 role=reviewer$' "$CLAUDE_LOG" || fail "AC: not reviewed on Opus after Sonnet: $(cat "$CLAUDE_LOG")"
grep -q 'reviewed on opus' "$state/95.prompt" || fail "AC: the prompt does not say the model: $(cat "$state/95.prompt")"
grep -q 'statuses/.* -f state=success -f context=senior-mode/review -f description=reviewed on opus' "$GH_LOG" ||
  fail "AC: the model is not recorded in the status description: $(grep statuses "$GH_LOG")"
st "$sha" "senior-mode/ci success"
session 95-sonnet-reviewer "reviewed: success" "" "" review:success
fresh
mkdir -p "$state"
echo '{"ticket": 95, "outcome": "delivered", "escalated": true, "model": "opus"}' >"$state/95.json"
once || fail "AC: serve failed: $(cat "$work/out")"
grep -q '^app-review-95 sonnet run=1 role=reviewer$' "$CLAUDE_LOG" || fail "AC: an Opus ticket is reviewed on Opus: $(cat "$CLAUDE_LOG")"
grep -q 'description=reviewed on sonnet' "$GH_LOG" || fail "AC: the Sonnet review is not recorded: $(grep statuses "$GH_LOG")"
config '{}'
jq '.review = {crossModel: false}' "$repo/.claude/senior-mode.json" >"$work/c" && mv "$work/c" "$repo/.claude/senior-mode.json"
git -C "$repo" -c user.name=t -c user.email=t@t commit -q -am "chore: cross model off"
git -C "$repo" push -q origin main
st "$sha" "senior-mode/ci success"
fresh
mkdir -p "$state"
echo '{"ticket": 95, "outcome": "delivered", "escalated": true, "model": "opus"}' >"$state/95.json"
once || fail "AC: serve failed: $(cat "$work/out")"
grep -q '^app-review-95 opus run=1 role=reviewer$' "$CLAUDE_LOG" || fail "AC: crossModel false does not keep Opus: $(cat "$CLAUDE_LOG")"

# AD: a feature or bug pull request needs a red-tests record (#306). Without one the ticket session resumes once to
# prove its tests, then the pull request is needs-human; with a record (red-tests or red-verified) it merges; a chore, or
# a ticket with no type, needs none.
config '{}'
sha96=$(mkbranch feat/96-x f96.txt)
sha97=$(mkbranch feat/97-x f97.txt)
sha98=$(mkbranch feat/98-x f98.txt)
boardx "96:In review:S:P1 next:type:feature" "97:In review:S:P1 next:type:chore" "98:In review:S:P1 next:type:bug"
prs_reset
for n in 96 97 98; do size_item "$n" S; done
PRBODY="Closes #96" pr 196 feat/96-x "$sha96" clean
PRBODY="Closes #97" pr 197 feat/97-x "$sha97" clean
PRBODY="Closes #98" pr 198 feat/98-x "$sha98" clean
for x in "$sha96" "$sha97" "$sha98"; do green "$x"; done
session 96-sonnet-ticket delivered pr:196
fresh
once || fail "AD: serve failed: $(cat "$work/out")"
grep -q '^app-96 sonnet run=1 role=ticket$' "$CLAUDE_LOG" || fail "AD: the feature ticket session did not resume: $(cat "$CLAUDE_LOG")"
grep -q 'red-tests verify 96' "$state/96.prompt" || fail "AD: the retry prompt does not name the proof: $(cat "$state/96.prompt")"
grep -q '^pr merge 196' "$GH_LOG" && fail "AD: a feature pull request with no red tests was merged"
[ -f "$state/red-retry-96" ] || fail "AD: the retry is not counted"
grep -q 'issues/196/labels' "$GH_LOG" && fail "AD: needs-human before the retry"
once || fail "AD: serve failed: $(cat "$work/out")"
grep -q '^app-96 ' "$CLAUDE_LOG" && fail "AD: a second retry: $(cat "$CLAUDE_LOG")"
grep -q 'issues/196/labels.*needs-human' "$GH_LOG" || fail "AD: no needs-human after the retry: $(cat "$GH_LOG")"
grep -q 'Waiting for a human.*pull request #196, not ready: no red-tests record for #96 (feature)' "$work/out" || fail "AD: not reported: $(cat "$work/out")"
grep -q '^pr merge 197' "$GH_LOG" || fail "AD: a chore pull request needs no red tests: $(grep '^pr ' "$GH_LOG")"
# A bug ticket whose tests were verified merges; a recorded file the pull request lacks does not.
mkdir -p "$repo/.git/senior-mode/runs/98"
echo f98.txt >"$repo/.git/senior-mode/runs/98/red-verified"
printf 'f98.txt\n' >"$FIX/files-198"
once || fail "AD: serve failed: $(cat "$work/out")"
grep -q '^pr merge 198' "$GH_LOG" || fail "AD: a verified bug pull request is not merged: $(cat "$work/out") $(cat "$GH_LOG")"
echo other.txt >"$repo/.git/senior-mode/runs/98/red-verified"
prs_reset
PRBODY="Closes #98" pr 198 feat/98-x "$sha98" clean
green "$sha98"
once || fail "AD: serve failed: $(cat "$work/out")"
grep -q '^pr merge 198' "$GH_LOG" && fail "AD: merged with a red test the pull request does not carry"
grep -q 'the red tests of #98 include other.txt' "$work/out" || fail "AD: the missing red test is not named: $(cat "$work/out")"
rm -f "$FIX/files-198" "$FIX"/item-*.json

# AH: a red base head (spec 373 section 1): no ticket session starts, an approved green pull request still merges, and
# the merge sets the breaker's trips back to 0; a green main lifts the hold by itself.
config '{}'
boardx "94:In review:S:P1 next" "95:Ready:S:P1 next"
prs_reset
sha94=$(mkbranch feat/94-x f94.txt)
pr 194 feat/94-x "$sha94" clean
green "$sha94"
base=$(git -C "$repo" rev-parse origin/main)
st "$base" "senior-mode/ci failure"
session 95-sonnet delivered pr
fresh
mkdir -p "$state"
echo "2 1800000000" >"$state/breaker"
once || fail "AH: serve failed: $(cat "$work/out")"
[ "$(jq -r .cause "$state/held" 2>/dev/null)" = main-red ] || fail "AH: a red main is not a hold: $(cat "$work/out")"
started 95 && fail "AH: a ticket started on a red main: $(cat "$CLAUDE_LOG")"
grep -q "^pr merge 194 --rebase --match-head-commit $sha94 -R acme/app$" "$GH_LOG" || fail "AH: the green pull request did not merge: $(grep '^pr ' "$GH_LOG")"
[ ! -e "$state/breaker" ] || fail "AH: a merged ticket did not reset the trips: $(cat "$state/breaker")"
grep -q 'issues/95/' "$GH_LOG" && fail "AH: a red main made a ticket needs-human"
st "$base" "senior-mode/ci success"
once || fail "AH: serve failed: $(cat "$work/out")"
[ ! -e "$state/held" ] || fail "AH: a green main did not lift the hold: $(cat "$state/held")"
started 95 || fail "AH: #95 not started once main is green: $(cat "$work/out")"

# AE: the state files (spec 373 section 3). A serve.pid of a process that is not a serve (a reused pid) is replaced; a
# serve that runs refuses the second (G). Files cut to half, as a power cut leaves them without the atomic write, are set
# aside as <file>.corrupt-<epoch> once, the default applies, and the ticket still ends delivered.
config '{}'
board 98
session 98-sonnet delivered pr
fresh
mkdir -p "$state"
sleep 60 &
stale=$!
echo "$stale" >"$state/serve.pid"
half() { local n; n=$(wc -c <"$1"); head -c $((n / 2)) "$1" >"$1.half" && mv "$1.half" "$1"; }
jq -nc '{cause: "deps", since: 1800000000, probe: "expensive", nextProbe: 1900000000, detail: "npm install failed"}' >"$state/held"
echo "0123456789abcdef 98" >"$state/queued-300"
echo "1" >"$state/rounds-98"
echo "sonnet" >"$state/98.model"
echo "1800000000 ticket" >"$state/launches"
echo "1800000001 ticket" >>"$state/launches"
for f in held queued-300 rounds-98 98.model; do half "$state/$f"; done
half "$state/launches"
once || fail "AE: serve failed on cut files: $(cat "$work/out")"
kill "$stale" 2>/dev/null || true
grep -q 'already runs' "$work/out" && fail "AE: a pid that is not a serve stopped it: $(cat "$work/out")"
outcome_of 98 delivered AE
for f in held queued-300; do
  [ "$(find "$state" -name "$f.corrupt-*" | wc -l)" -eq 1 ] || fail "AE: $f was not set aside: $(ls "$state")"
  [ ! -e "$state/$f" ] || fail "AE: $f is still there"
done
[ "$(grep -c 'held could not be read' "$work/out")" -eq 1 ] || fail "AE: the cut hold is not said once: $(cat "$work/out")"
SENIOR_MODE_NOW=1800000030 once || fail "AE: serve failed on the next poll: $(cat "$work/out")"
grep -q 'could not be read' "$work/out" && fail "AE: a file set aside is said again: $(cat "$work/out")"
# A temporary file of a write that a kill cut stays out of the way and is removed at the next start.
echo partial >"$state/limit-until.tmp.4999990"
echo "done" >"$state/held.tmp.$$"
once || fail "AE: serve failed: $(cat "$work/out")"
[ ! -e "$state/limit-until.tmp.4999990" ] || fail "AE: the temporary file of a dead writer is left"
[ -e "$state/held.tmp.$$" ] || fail "AE: the temporary file of a live writer was removed"
rm -f "$state/held.tmp.$$"

# AF: reconciliation (#379, spec 373 section 2). Whatever a dead serve left, the next poll reads it from GitHub and the disk.
# AF1: a gh that never answers: the poll ends within serve.callTimeout plus the steps that need no GitHub, once, not once per call.
config '{}' '{"callTimeout": 1}'
board 100
session 100-sonnet delivered pr
fresh
touch "$FIX/gh-dead"
start=$SECONDS
once || fail "AF1: serve failed: $(cat "$work/out")"
rm -f "$FIX/gh-dead"
[ $((SECONDS - start)) -lt 25 ] || fail "AF1: the poll did not end within the call timeout: $((SECONDS - start))s"
[ "$(grep -c . "$GH_LOG")" -lt 8 ] || fail "AF1: every call waited for its own timeout: $(cat "$GH_LOG")"
started 100 && fail "AF1: a ticket started with gh down"
grep -q 'gh timed out after 1s' "$work/out" || fail "AF1: not said: $(cat "$work/out")"
fresh
once || fail "AF1: serve failed with gh back: $(cat "$work/out")"
started 100 || fail "AF1: the next poll did not launch #100: $(cat "$work/out")"

# AF2: a session that wrote `delivered` and ended while serve was down is read at the next start: the ticket goes In
# review (o3), not back to Ready (o1).
config '{}'
items="[]"
fitem 101 "In progress" '[]' "x"
fboard
fresh
mkdir -p "$state"
echo '#!/usr/bin/env bash' >"$state/101.sh"
jq -nc '{ticket: 101, role: "ticket", model: "sonnet", branch: "feat/101-x", worktree: "/nonexistent", cwd: "", batch: "", pr: "", sha: "", started: 1799999000}' >"$state/101.meta"
echo 4999994 >"$state/101.pgid"
echo 0 >"$state/101.exit"
echo delivered >"$state/101.outcome"
echo '[{"number": 201, "author_association": "OWNER", "head": {"sha": "sha101"}, "labels": []}]' >"$FIX/pulls-101"
once || fail "AF2: serve failed: $(cat "$work/out")"
grep -q 'item-edit.*--single-select-option-id o3' "$GH_LOG" || fail "AF2: the delivered ticket is not In review: $(grep item-edit "$GH_LOG")"
grep -q 'item-edit.*--single-select-option-id o1' "$GH_LOG" && fail "AF2: the delivered ticket went back to Ready"
outcome_of 101 delivered AF2
grep -q 'taking over' "$work/out" || fail "AF2: the take-over is not said: $(cat "$work/out")"

# AF3: the serve dir deleted. The ticket In progress whose worktree holds serve's marker and where nothing runs goes back
# to Ready; the one In review is left to the pull request logic, nothing is done to it here.
config '{}'
items="[]"
fitem 102 "In progress" '[]' "x"
fitem 103 "In review" '[]' "x"
fboard
fresh
git -C "$repo" worktree add -q -b feat/102-x "$work/wt102" main
git -C "$work/wt102" rev-parse --absolute-git-dir | { read -r gd; echo 102 >"$gd/senior-mode-session"; }
once || fail "AF3: serve failed: $(cat "$work/out")"
grep -q 'issues/102' "$GH_LOG" || fail "AF3: #102 (worktree with the marker, no serve dir) not recovered: $(cat "$GH_LOG")"
[ "$(grep -c 'item-edit.*--single-select-option-id o1' "$GH_LOG")" = 1 ] || fail "AF3: not exactly #102 set Ready: $(grep item-edit "$GH_LOG")"
grep -q 'issues/103/' "$GH_LOG" && fail "AF3: #103, In review, was touched: $(cat "$GH_LOG")"
git -C "$repo" worktree remove --force "$work/wt102" 2>/dev/null
git -C "$repo" branch -D feat/102-x >/dev/null 2>&1

# AF4: a pull request MERGED whose ticket is In review (serve died after the merge): the next poll sets it Done, with no
# queued-<pr> file, and says so once.
config '{}'
items="[]"
fitem 104 "In review" '[]' "x"
fboard
echo '[{"number": 204, "headRefName": "feat/104-x", "body": "Closes #104"}]' >"$FIX/merged-prs"
fresh
once || fail "AF4: serve failed: $(cat "$work/out")"
grep -q 'item-edit.*--single-select-option-id o4' "$GH_LOG" || fail "AF4: #104 not set Done: $(cat "$GH_LOG")"
[ ! -e "$state/queued-204" ] || fail "AF4: a queued file appeared"
# An open pull request for the same ticket (a follow-up) keeps it In review.
echo '[{"number": 205, "head": {"ref": "feat/104-y", "sha": "sha205"}, "author_association": "OWNER", "labels": [], "mergeable_state": "clean"}]' >"$FIX/open-prs.json"
once || fail "AF4: serve failed: $(cat "$work/out")"
grep -q 'item-edit.*--single-select-option-id o4' "$GH_LOG" && fail "AF4: a ticket with an open pull request was set Done"
rm -f "$FIX/merged-prs" "$FIX/open-prs.json"

# AF5: a pushed branch with commits, `delivered` and no pull request: serve opens one, and only one when its end is read
# twice (the second read is the one of a serve that died after the pull request was opened).
config '{}'
board 105
session 105-sonnet delivered "" "" commit
fresh
rm -f "$FIX/pr-created" "$FIX/pulls-105"
once || fail "AF5: serve failed: $(cat "$work/out")"
[ "$(grep -c . "$FIX/pr-created" 2>/dev/null)" = 1 ] || fail "AF5: not exactly one pull request opened: $(cat "$FIX/pr-created" 2>&1)"
grep -q 'Closes #105' "$FIX/pr-created" || fail "AF5: the pull request does not close the ticket: $(cat "$FIX/pr-created")"
git -C "$work/github.com/acme/app.git" rev-parse -q --verify refs/heads/feat/105-ticket-105 >/dev/null ||
  [ -n "$(git -C "$work/github.com/acme/app.git" branch --list 'feat/105-*')" ] || fail "AF5: the branch was not pushed"
items="[]"
fitem 105 "In progress" '[]' "x"
fboard
rm -f "$state/105.json"
once || fail "AF5: serve failed on the second read: $(cat "$work/out")"
[ "$(grep -c . "$FIX/pr-created")" = 1 ] || fail "AF5: a second pull request was opened: $(cat "$FIX/pr-created")"
outcome_of 105 delivered AF5


# AG: the watchdog (#384, spec 373 section 4). The minutes are seconds here (SENIOR_MODE_TIMEOUT_UNIT=1: the time unit of the delays); no wall-clock budget is asserted. A session on which
# nothing moves is stopped; the first stop is an interruption (the ticket goes back to Ready, resumes after the backoff, no
# failure counted), the second is needs-human. A session that works is left alone. What an ended session left behind is
# killed, and so is a stale git index.lock.
export SENIOR_MODE_TIMEOUT_UNIT=1
config '{"startupMinutes": 1, "stallMinutes": 1}'
board 110
session 110-sonnet "" "" hang
fresh
once || fail "AG: serve failed: $(cat "$work/out")"
grep -q '#110: the session is stopped, hung at startup' "$work/out" || fail "AG: the stop is not said: $(cat "$work/out")"
read -r -a pids <"$FIX/pids-110"
for p in "${pids[@]}"; do ! kill -0 "$p" 2>/dev/null || fail "AG: the hung session is still running (pid $p)"; done
grep -q 'issues/110/labels' "$GH_LOG" && fail "AG: the first stop is needs-human: $(cat "$GH_LOG")"
grep -q 'item-edit.*--single-select-option-id o1' "$GH_LOG" || fail "AG: the ticket is not back to Ready: $(grep item-edit "$GH_LOG")"
[ "$(cat "$state/110.resumed")" = 1 ] || fail "AG: the stop is not counted: $(cat "$state/110.resumed" 2>&1)"
grep -q 'was stopped' "$state/110.prompt" || fail "AG: the resumed session is not told: $(cat "$state/110.prompt")"
[ ! -e "$state/paused" ] || fail "AG: the first stop counted for the breaker"
SENIOR_MODE_NOW=1800003600 once || fail "AG: serve failed: $(cat "$work/out")"
started 110 || fail "AG: the ticket did not resume: $(cat "$CLAUDE_LOG")"
grep -q 'issues/110/labels.*needs-human' "$GH_LOG" || fail "AG: the second stop is not needs-human: $(cat "$GH_LOG")"
grep -q 'issues/110/comments' "$GH_LOG" || fail "AG: no comment on the second stop"
# A session that works, with a child that comes and goes, runs past the stall delay and is left alone.
# The delays are wide (30 s, 4 s): a loaded machine may start the session late, and the session still outlasts the stall delay.
config '{"startupMinutes": 30, "stallMinutes": 4}'
board 111
session 111-sonnet delivered pr "busy"
fresh
once || fail "AG: serve failed: $(cat "$work/out")"
grep -q 'is stopped' "$work/out" && fail "AG: a session that works was stopped: $(cat "$work/out")"
outcome_of 111 delivered AG
# What the session left behind is killed at the next poll, and only that.
config '{}'
board 112
session 112-sonnet delivered pr
printf 'sleep 300 &\necho $! >"%s/orphan-112"\ndisown\n' "$FIX" >"$FIX/after-112"
fresh
once || fail "AG: serve failed: $(cat "$work/out")"
orphan=$(cat "$FIX/orphan-112")
kill -0 "$orphan" 2>/dev/null || fail "AG: the process of the session ended at once, nothing to kill"
rm -f "$FIX/after-112"
once || fail "AG: serve failed: $(cat "$work/out")"
! kill -0 "$orphan" 2>/dev/null || fail "AG: the process the session left behind is still running"
grep -q 'its session left behind' "$work/out" || fail "AG: the kill is not said: $(cat "$work/out")"
# An index.lock over 10 minutes old, with no git running, goes; a recent one stays.
: >"$repo/.git/index.lock"
touch -d '20 minutes ago' "$repo/.git/index.lock"
once || fail "AG: serve failed: $(cat "$work/out")"
[ ! -e "$repo/.git/index.lock" ] || fail "AG: the stale index.lock is still there"
grep -q 'removed the stale' "$work/out" || fail "AG: not said: $(cat "$work/out")"
: >"$repo/.git/index.lock"
once || fail "AG: serve failed: $(cat "$work/out")"
[ -e "$repo/.git/index.lock" ] || fail "AG: a recent index.lock was removed"
rm -f "$repo/.git/index.lock"
unset SENIOR_MODE_TIMEOUT_UNIT

# DF: dependency freshness (#497, spec 471 section 8). Once a week serve reads the outdated list of the ecosystem
# (`npm outdated --json` here, a stub) and files one `chore(deps): <package> <from> to <to>` ticket per major, reusing
# an open one of the same title. The time of the pass is kept in <serve dir>/deps-at, as the digest keeps its own.
cat >"$work/stub/npm" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$NPM_LOG"
[ "$1 $2" = "outdated --json" ] || exit 0
cat "$FIX/npm-outdated.json" 2>/dev/null || echo '{}'
exit 1
STUB
chmod +x "$work/stub/npm"
export NPM_LOG="$work/npm.log"
echo '{"name": "app", "dependencies": {"next": "^14.2.0", "react": "^18.2.0"}}' >"$repo/package.json"
echo '{"next": {"current": "14.2.0", "wanted": "14.2.5", "latest": "15.0.0", "dependent": "app"},
  "react": {"current": "18.2.0", "wanted": "18.3.1", "latest": "18.3.1", "dependent": "app"}}' >"$FIX/npm-outdated.json"
echo '[]' >"$FIX/issues.json"
config '{}'
board
dep_tickets() { jq -r '[.[] | select(.title | startswith("chore(deps): "))] | length' "$FIX/issues.json"; }
fresh
: >"$NPM_LOG"
SENIOR_MODE_NOW=1800000000 once || fail "DF: serve failed: $(cat "$work/out")"
grep -q '^outdated --json' "$NPM_LOG" || fail "DF: the outdated list was not read: $(cat "$NPM_LOG")"
[ "$(dep_tickets)" = 1 ] || fail "DF: not one ticket for the major of next: $(cat "$FIX/issues.json")"
jq -e 'any(.[]; .title == "chore(deps): next 14.2.0 to 15.0.0")' "$FIX/issues.json" >/dev/null ||
  fail "DF: the ticket is not titled for next 14.2.0 to 15.0.0: $(cat "$FIX/issues.json")"
jq -e 'any(.[]; .title | test("react"))' "$FIX/issues.json" >/dev/null && fail "DF: a minor of react became a ticket: $(cat "$FIX/issues.json")"
[ -s "$state/deps-at" ] || fail "DF: the pass is not kept in $state/deps-at"
# The same week: no new pass.
: >"$NPM_LOG"
SENIOR_MODE_NOW=1800086400 once || fail "DF: serve failed: $(cat "$work/out")"
grep -q '^outdated' "$NPM_LOG" && fail "DF: a second pass within the week: $(cat "$NPM_LOG")"
[ "$(dep_tickets)" = 1 ] || fail "DF: a second ticket within the week: $(cat "$FIX/issues.json")"
# The next week, the ticket still open: the pass runs again and files nothing more.
: >"$NPM_LOG"
SENIOR_MODE_NOW=1800700000 once || fail "DF: serve failed: $(cat "$work/out")"
grep -q '^outdated --json' "$NPM_LOG" || fail "DF: no pass a week later: $(cat "$NPM_LOG")"
[ "$(dep_tickets)" = 1 ] || fail "DF: the weekly pass run twice filed $(dep_tickets) tickets: $(cat "$FIX/issues.json")"
# A restart that lost the mark does not file a second one either.
rm -f "$state/deps-at"
SENIOR_MODE_NOW=1800700100 once || fail "DF: serve failed: $(cat "$work/out")"
[ "$(dep_tickets)" = 1 ] || fail "DF: a lost mark filed a second ticket: $(cat "$FIX/issues.json")"
# A newer major of the same package is another title, hence another ticket.
echo '{"next": {"current": "14.2.0", "wanted": "14.2.5", "latest": "16.0.0"}}' >"$FIX/npm-outdated.json"
rm -f "$state/deps-at"
SENIOR_MODE_NOW=1801400000 once || fail "DF: serve failed: $(cat "$work/out")"
jq -e 'any(.[]; .title == "chore(deps): next 14.2.0 to 16.0.0")' "$FIX/issues.json" >/dev/null || fail "DF: no ticket for 16.0.0: $(cat "$FIX/issues.json")"
# Nothing outdated, no ticket; no package.json, no pass.
echo '[]' >"$FIX/issues.json"
echo '{}' >"$FIX/npm-outdated.json"
rm -f "$state/deps-at"
SENIOR_MODE_NOW=1802000000 once || fail "DF: serve failed: $(cat "$work/out")"
[ "$(dep_tickets)" = 0 ] || fail "DF: a ticket with nothing outdated: $(cat "$FIX/issues.json")"
rm -f "$repo/package.json"
config '{}'
echo '{"next": {"current": "14.2.0", "wanted": "14.2.5", "latest": "15.0.0"}}' >"$FIX/npm-outdated.json"
rm -f "$state/deps-at"
: >"$NPM_LOG"
SENIOR_MODE_NOW=1802700000 once || fail "DF: serve failed: $(cat "$work/out")"
[ ! -s "$NPM_LOG" ] || fail "DF: npm asked in a project with no package.json: $(cat "$NPM_LOG")"
[ "$(dep_tickets)" = 0 ] || fail "DF: a ticket for a project with no package.json: $(cat "$FIX/issues.json")"

# DF2 (ADR 0024): a Dependabot pull request is not from a collaborator: green, reviewed, it still waits for a human.
config '{}'
boardx "98:In review:S:P1 next"
prs_reset
sha98=$(mkbranch feat/98-x f98.txt)
pr 198 feat/98-x "$sha98" clean
patch_pr 198 '.user.login = "dependabot[bot]" | .user.type = "Bot" | .author_association = "CONTRIBUTOR"'
green "$sha98"
fresh
once || fail "DF2: serve failed: $(cat "$work/out")"
grep -q '^pr merge' "$GH_LOG" && fail "DF2: a Dependabot pull request was merged: $(grep '^pr ' "$GH_LOG")"
grep -q "pull request #198, it is external" "$work/out" || fail "DF2: the Dependabot pull request is not left to a human: $(cat "$work/out")"

# GD: gardening of the knowledge notes (#357, spec 325 section 5). Once a day serve files one `chore(knowledge): re-verify <slug>`
# ticket (S, P2, labelled gardening, under the open epic labelled maintenance, the note as Paths) for a note on the base branch
# with more than knowledge.churnCommits commits on its paths since `verified`, or verified more than knowledge.staleMonths ago.
# Real dates here (a commit date is the real clock): the notes are verified relative to today.
note() { # <slug> <verified> <paths json>
  mkdir -p "$repo/docs/knowledge"
  printf -- '---\npaths: %s\nverified: %s\norigin: retro\nkind: pitfall\n---\nBody of %s.\n' "$3" "$2" "$1" >"$repo/docs/knowledge/$1.md"
}
churn() { # <dir> <commits>
  local i
  mkdir -p "$repo/src/$1"
  for i in $(seq "$2"); do
    echo "$i" >>"$repo/src/$1/f.txt"
    git -C "$repo" add -A
    git -C "$repo" -c user.name=t -c user.email=t@t commit -q -m "feat: change $1 $i"
  done
}
gd_tickets() { jq -r '[.[] | select(.title | startswith("chore(knowledge): re-verify "))] | map(.title | sub("^chore.*verify "; "")) | sort | join(" ")' "$FIX/issues.json"; }
gd_config() { # <jq filter>: the config on the base branch (it is read from there)
  jq "$1" "$repo/.claude/senior-mode.json" >"$work/cfg.json" && mv "$work/cfg.json" "$repo/.claude/senior-mode.json"
  git -C "$repo" -c user.name=t -c user.email=t@t commit -qam "chore: config" --allow-empty
  git -C "$repo" push -q origin main
}
gd_epic='{"number": 7, "title": "Maintenance", "body": "", "labels": [{"name": "maintenance"}]}'
config '{}'
board
churn hot 16
churn warm 15
churn today 16
churn calm 3
note hot "$(date -u -d '20 days ago' +%F)" '["src/hot/**"]'
note warm "$(date -u -d '20 days ago' +%F)" '["src/warm/**"]'
note calm "$(date -u -d '20 days ago' +%F)" '["src/calm/**"]'
note today "$(date -u +%F)" '["src/today/**"]'
note old "$(date -u -d '400 days ago' +%F)" '["src/none/**"]'
note cold "$(date -u -d '500 days ago' +%F)" '["src/none/**"]'
git -C "$repo" add -A
git -C "$repo" -c user.name=t -c user.email=t@t commit -q -m "docs(knowledge): notes"
git -C "$repo" push -q origin main
now=$(date +%s)
echo "[$gd_epic]" >"$FIX/issues.json"
rm -f "$FIX/sub-issues"
fresh
SENIOR_MODE_NOW=$now once || fail "GD: serve failed: $(cat "$work/out")"
[ "$(gd_tickets)" = "cold hot old" ] || fail "GD: wrong notes ticketed ($(gd_tickets)): more than 15 commits since verified, or older than 6 months, only: $(cat "$work/out")"
grep -q 'F_Paths.*docs/knowledge/hot.md' "$GH_LOG" || fail "GD: the note is not the Paths of its ticket: $(grep -c . "$GH_LOG") calls"
grep -q 'issues/7/sub_issues' "$FIX/sub-issues" 2>/dev/null || fail "GD: the tickets are not under the maintenance epic: $(cat "$FIX/sub-issues" 2>&1)"
[ "$(wc -l <"$FIX/sub-issues")" = 3 ] || fail "GD: not three tickets under the epic: $(cat "$FIX/sub-issues")"
for n in 500 501 502; do
  grep -q "issues/$n/labels.*labels\[\]=gardening" "$GH_LOG" || fail "GD: #$n is not labelled gardening"
done
grep -q 'Given the note `docs/knowledge/cold.md`' "$FIX/body-500" || fail "GD: no acceptance criterion on the note: $(cat "$FIX/body-500" 2>&1)"
grep -q 'bumps `verified`.*or deletes it, in one pull request' "$FIX/body-500" || fail "GD: the body does not say what the session does: $(cat "$FIX/body-500")"
grep -q 'filed-by: agent' "$FIX/body-500" || fail "GD: the ticket is not filed as an agent's, so ready would not take it: $(cat "$FIX/body-500")"
grep -q 'size-option z1\|--single-select-option-id z1' "$GH_LOG" || fail "GD: the ticket is not size S"
[ -s "$state/gardening-at" ] || fail "GD: the pass is not kept in $state/gardening-at"
# The same day: no second pass, nothing filed.
echo "[$gd_epic]" >"$FIX/issues.json"
SENIOR_MODE_NOW=$((now + 3600)) once || fail "GD: serve failed: $(cat "$work/out")"
[ -z "$(gd_tickets)" ] || fail "GD: a second pass within the day: $(gd_tickets)"
# A day later, a ticket open for a note: it is not filed again; the others are.
echo "[$gd_epic, {\"number\": 8, \"title\": \"chore(knowledge): re-verify hot\", \"body\": \"\", \"labels\": [{\"name\": \"gardening\"}]}]" >"$FIX/issues.json"
SENIOR_MODE_NOW=$((now + 86400)) once || fail "GD: serve failed: $(cat "$work/out")"
[ "$(gd_tickets)" = "cold hot old" ] || fail "GD: with hot open, the pass should file cold and old once more ($(gd_tickets))"
[ "$(jq '[.[] | select(.title == "chore(knowledge): re-verify hot")] | length' "$FIX/issues.json")" = 1 ] || fail "GD: a second ticket for a note that has one open"
# maintenance.maxOpen caps the open gardening tickets: 3 open, a cap of 4, one more filed (cold, the first in order).
gd_config '.maintenance = {maxOpen: 4}'
echo "[$gd_epic$(printf ', {"number": %s, "title": "chore(architecture): v%s", "body": "", "labels": [{"name": "gardening"}]}' 11 1 12 2 13 3)]" >"$FIX/issues.json"
SENIOR_MODE_NOW=$((now + 2 * 86400)) once || fail "GD: serve failed: $(cat "$work/out")"
[ "$(gd_tickets)" = "cold" ] || fail "GD: with 3 open and maxOpen 4, exactly one ticket (cold) was expected, got: $(gd_tickets)"
gd_config '.maintenance = {maxOpen: 3}'
echo "[$gd_epic$(printf ', {"number": %s, "title": "chore(architecture): v%s", "body": "", "labels": [{"name": "gardening"}]}' 11 1 12 2 13 3)]" >"$FIX/issues.json"
SENIOR_MODE_NOW=$((now + 3 * 86400)) once || fail "GD: serve failed: $(cat "$work/out")"
[ -z "$(gd_tickets)" ] || fail "GD: a ticket filed with maxOpen reached: $(gd_tickets)"
# No epic labelled maintenance: nothing is filed, and it is said.
gd_config 'del(.maintenance)'
echo '[]' >"$FIX/issues.json"
SENIOR_MODE_NOW=$((now + 4 * 86400)) once || fail "GD: serve failed: $(cat "$work/out")"
[ -z "$(gd_tickets)" ] || fail "GD: tickets filed with no maintenance epic: $(gd_tickets)"
grep -q 'no open epic labelled maintenance' "$work/out" || fail "GD: the missing epic is not said: $(cat "$work/out")"
# knowledge.churnCommits: 2 makes the 3 commits of calm one too many, and warm and today the same as before.
gd_config '.knowledge = {churnCommits: 2}'
echo "[$gd_epic]" >"$FIX/issues.json"
SENIOR_MODE_NOW=$((now + 5 * 86400)) once || fail "GD: serve failed: $(cat "$work/out")"
[ "$(gd_tickets)" = "calm cold hot old warm" ] || fail "GD: churnCommits 2 not applied ($(gd_tickets)); today has no commit after its verified day"
# No docs/knowledge on the base branch: no pass, no issue list.
git -C "$repo" rm -rq docs/knowledge src
git -C "$repo" -c user.name=t -c user.email=t@t commit -q -m "chore: drop notes"
git -C "$repo" push -q origin main
gd_config 'del(.knowledge)'
rm -f "$state/gardening-at"
echo "[$gd_epic]" >"$FIX/issues.json"
SENIOR_MODE_NOW=$((now + 6 * 86400)) once || fail "GD: serve failed: $(cat "$work/out")"
[ -z "$(gd_tickets)" ] || fail "GD: tickets filed with no notes: $(gd_tickets)"
[ ! -e "$state/gardening-at" ] || fail "GD: a pass kept with no notes"

# MB: the maintenance budget (#351, spec 325 section 6.1). maintenance.share of autonomy.parallel, rounded up, is kept for Ready
# gardening tickets: feature tickets cannot take the last reserved slot while one waits; with none waiting the slot goes to features.
mb_sessions() { local n; for n in "$@"; do session "$n-sonnet" delivered pr; done; }
mb_started() { local n out=""; for n in "$@"; do ! started "$n" || out="$out $n"; done; echo "${out# }"; }
mb_sessions 31 32 33 34 35 40 41
config '{"parallel": 4}'
boardx "31:Ready:S:P1 next" "32:Ready:S:P1 next" "33:Ready:S:P1 next" "34:Ready:S:P1 next" "35:Ready:S:P1 next" "40:Ready:S:P2 later:gardening"
fresh
once || fail "MB: serve failed: $(cat "$work/out")"
[ "$(mb_started 31 32 33 34 35 40 41)" = "31 32 33 40" ] || fail "MB: share 0.2 of 4 slots keeps one for gardening, expected 31 32 33 40: $(mb_started 31 32 33 34 35 40 41)"
grep -q 'the last free slot is kept for a gardening ticket' "$work/out" || fail "MB: the held slot is not said: $(cat "$work/out")"
# No Ready gardening ticket: the slot goes to features.
boardx "31:Ready:S:P1 next" "32:Ready:S:P1 next" "33:Ready:S:P1 next" "34:Ready:S:P1 next" "35:Ready:S:P1 next"
fresh
once || fail "MB: serve failed: $(cat "$work/out")"
[ "$(mb_started 31 32 33 34 35)" = "31 32 33 34" ] || fail "MB: with no gardening ticket the four slots go to features: $(mb_started 31 32 33 34 35)"
# A gardening ticket In progress in no queue does not hold the slot either: only a Ready one that could start does.
boardx "31:Ready:S:P1 next" "32:Ready:S:P1 next" "33:Ready:S:P1 next" "34:Ready:S:P1 next" "40:In progress:S:P2 later:gardening"
fresh
once || fail "MB: serve failed: $(cat "$work/out")"
[ "$(mb_started 31 32 33 34)" = "31 32 33 34" ] || fail "MB: a gardening ticket that is not Ready holds a slot: $(mb_started 31 32 33 34)"
# maintenance.share 0: nothing is reserved, pick order as before.
gd_config '.maintenance = {share: 0}'
boardx "31:Ready:S:P1 next" "32:Ready:S:P1 next" "33:Ready:S:P1 next" "34:Ready:S:P1 next" "35:Ready:S:P1 next" "40:Ready:S:P2 later:gardening"
fresh
once || fail "MB: serve failed: $(cat "$work/out")"
[ "$(mb_started 31 32 33 34 35 40 41)" = "31 32 33 34" ] || fail "MB: share 0 reserves nothing: $(mb_started 31 32 33 34 35 40 41)"
grep -q 'kept for a gardening ticket' "$work/out" && fail "MB: a slot is kept with share 0: $(cat "$work/out")"
# share 0.5 of 4 slots keeps two, gardening first or not: two features and two gardening tickets.
gd_config '.maintenance = {share: 0.5}'
boardx "31:Ready:S:P1 next" "32:Ready:S:P1 next" "33:Ready:S:P1 next" "40:Ready:S:P2 later:gardening" "41:Ready:S:P2 later:gardening"
fresh
once || fail "MB: serve failed: $(cat "$work/out")"
[ "$(mb_started 31 32 33 40 41)" = "31 32 40 41" ] || fail "MB: share 0.5 of 4 slots keeps two for gardening: $(mb_started 31 32 33 40 41)"

# AF: the hourly snapshot (#423): one JSON line in snapshots.jsonl the first poll and then once an hour, with the sessions
# running, the free slots, the Ready tickets that could run, and null where nothing is known (no train, no quota band).
config '{"parallel": 2}'
board 10 11 12
session 10-sonnet delivered pr
session 11-sonnet delivered pr
fresh
SENIOR_MODE_NOW=1800000000 once || fail "AF: serve failed: $(cat "$work/out")"
snaps="$state/snapshots.jsonl"
[ "$(awk 'END { print NR }' "$snaps" 2>/dev/null)" = 1 ] || fail "AF: no snapshot at the first poll: $(cat "$snaps" 2>&1)"
jq -e '.at == 1800000000 and .running == 2 and .free == 0 and .runnable == 1 and .train == null and .band == null and .held == null and (.started | type) == "number"' "$snaps" >/dev/null ||
  fail "AF: snapshot fields: $(cat "$snaps")"
jq -e 'has("leases") and has("mainCi") and has("drift")' "$snaps" >/dev/null || fail "AF: snapshot lacks leases, mainCi or drift: $(cat "$snaps")"
[ "$(cat "$state/snapshot-at")" = 1800000000 ] || fail "AF: the time of the snapshot is not kept: $(cat "$state/snapshot-at" 2>&1)"
SENIOR_MODE_NOW=1800001800 once || fail "AF: serve failed: $(cat "$work/out")"
[ "$(awk 'END { print NR }' "$snaps")" = 1 ] || fail "AF: a second snapshot within the hour: $(cat "$snaps")"
echo '{"id": "t1", "phase": "checking", "entries": [{"pr": 1}, {"pr": 2}], "evicted": [{"pr": 3}]}' >"$state/train"
echo 'reserve 72%' >"$state/band"
printf '%s\nthe breaker tripped\n' "$((1800003600 + 99999))" >"$state/paused"
SENIOR_MODE_NOW=1800003600 once || fail "AF: serve failed: $(cat "$work/out")"
[ "$(awk 'END { print NR }' "$snaps")" = 2 ] || fail "AF: no snapshot an hour later: $(cat "$snaps")"
tail -n 1 "$snaps" | jq -e '.at == 1800003600 and .train == {id: "t1", phase: "checking", entries: 2, evicted: 1} and .band == "reserve 72%" and .held == "paused"' >/dev/null ||
  fail "AF: train, band or hold not in the snapshot: $(tail -n 1 "$snaps")"

[ "$failures" -eq 0 ] && echo "serve: all cases pass"
exit "$failures"
