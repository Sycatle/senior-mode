#!/usr/bin/env bash
# The chaos suite of `senior-mode serve` (#386, spec 373 section 7). Offline: `gh` is a small GitHub (a board, pull requests,
# statuses and merges kept in $FIX), `claude` plays a ticket session, `tmux` starts it detached. Each case breaks something,
# polls serve (SENIOR_MODE_SERVE_ONCE, the clock moved by 61 s at each poll) until the ticket is Done or needs-human, then
# polls twice more and asserts nothing changed, and that the invariants hold: no pull request merged twice or sharing a head
# (I2), no worktree left for a ticket that is Done (I3), every state file parses (I4), no session left alive. The cases run
# side by side, each in a directory of its own. $FIX/gh-mode (down, 5xx:<n>, 401, hang) and $FIX/claude-<n> (a mode: ok,
# startup-settings:<k>, api-529:<k>, limit, enospc, silent-hang, busy-child, orphan) are the faults; SENIOR_MODE_FAULT=<name>
# kills serve with `kill -9` the first time it passes the fault_point <name> of the code. Every fault_point of the code is
# in $sweep: the suite fails on one that is not.
# shellcheck disable=SC2016 # jq programs and stub bodies, not expanded here
# shellcheck disable=SC2329 # the case_* functions are called by name from the runner
# shellcheck disable=SC2012 # ls counts the files of a directory this suite fills itself
set -u
cli=$(cd "$(dirname "$0")/.." && pwd)/senior-mode
libs=$(cd "$(dirname "$0")/.." && pwd)/lib
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/stub" "$work/res"

cat >"$work/stub/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$GH_LOG"
mode=$(cat "$FIX/gh-mode" 2>/dev/null || true)
case $mode in
  down) echo "Post \"https://api.github.com/graphql\": dial tcp: lookup api.github.com: no such host" >&2; exit 1 ;;
  401) echo "HTTP 401: Bad credentials (https://api.github.com/graphql)" >&2; exit 1 ;;
  hang) exec sleep 30 ;;
  5xx:*)
    c=$(cat "$FIX/gh-5xx-count" 2>/dev/null || echo 0)
    if [ "$c" -lt "${mode#5xx:}" ]; then
      echo $((c + 1)) >"$FIX/gh-5xx-count"
      echo "HTTP 502: Bad Gateway (https://api.github.com/repos/acme/app)" >&2
      exit 1
    fi ;;
esac
jqf="" prev=""
for a in "$@"; do [ "$prev" = --jq ] && jqf=$a; prev=$a; done
respond() { if [ -n "$jqf" ]; then jq -r "$jqf"; else cat; fi; }
prs() { cat "$FIX"/prs/*.json 2>/dev/null | jq -s "$1"; }
base=$(git --git-dir "$REMOTE" rev-parse refs/heads/main)
case "$*" in
  "api graphql --input -")
    cat >"$FIX/graphql-in"
    if grep -q createProjectV2StatusUpdate "$FIX/graphql-in"; then
      echo '{"data": {"createProjectV2StatusUpdate": {"statusUpdate": {"id": "SU_1"}}}}'
    elif grep -q projectItems "$FIX/graphql-in"; then
      echo '{"data": {"repository": {"issue": {"projectItems": {"nodes": [{"project": {"id": "PVT_1"},
        "fieldValues": {"nodes": [{"name": "S", "field": {"name": "Size"}}]}}]}}}}}'
    elif grep -q '"sha":' "$FIX/graphql-in"; then
      echo '{"data": {"repository": {"object": {"associatedPullRequests": {"nodes": [{"state": "OPEN", "closingIssuesReferences": {"nodes": []}}]}}}}}'
    else cat "$FIX/board.json"; fi ;;
  "api repos/acme/app --jq "*) echo '{"allow_auto_merge": false}' | respond ;;
  "api repos/acme/app/commits/"*"/status"*)
    sha=$(sed -E 's#^api repos/acme/app/commits/([^/ ]+)/status.*#\1#' <<<"$*")
    ci=success
    [ ! -f "$FIX/red-main" ] || [ "$sha" != "$base" ] || ci=failure
    jq -nc --arg ci "$ci" '{statuses: [{context: "senior-mode/ci", state: $ci}, {context: "senior-mode/review", state: "success"},
      {context: "senior-mode/security", state: "success"}]}' | respond ;;
  "api repos/acme/app/statuses/"*) ;;
  "api repos/acme/app/pulls?state=open"*) prs '[.[] | select(.state == "OPEN")]' | respond ;;
  "api repos/acme/app/pulls -X POST"*)
    br=$(sed -E 's#.* head=([^ ]+) .*#\1#' <<<"${*//$'\n'/ }")
    n=$(sed -E 's#^[a-z]+/([0-9]+)-.*#\1#' <<<"$br")
    sha=$(git --git-dir "$REMOTE" rev-parse "refs/heads/$br") || { echo "HTTP 422: head is not on the remote" >&2; exit 1; }
    mkdir -p "$FIX/prs"
    jq -nc --argjson n "$((n + 100))" --arg b "$br" --arg s "$sha" --arg body "Closes #$n" '{number: $n, state: "OPEN", draft: false, author_association: "OWNER",
      head: {ref: $b, sha: $s}, headRefName: $b, headRefOid: $s, baseRefName: "main", isCrossRepository: false, mergeable_state: "clean", labels: [], body: $body,
      mergedAt: null, closedAt: null}' >"$FIX/prs/$((n + 100)).json" ;;
  "api repos/acme/app/pulls?head="*)
    br=$(sed -E 's#.*head=acme:([^&]+)&state=.*#\1#' <<<"$*")
    if [[ $* == *state=all* ]]; then q='.head.ref == $b'; else q='.head.ref == $b and .state == "OPEN"'; fi
    { cat "$FIX"/prs/*.json 2>/dev/null; } | jq -s --arg b "$br" "[.[] | select($q)]" | respond ;;
  "api repos/acme/app/pulls/"*"/files"*) echo src/app.ts ;;
  "api repos/acme/app/pulls/"[0-9]*) cat "$FIX/prs/$(sed -E 's#^api repos/acme/app/pulls/([0-9]+).*#\1#' <<<"$*").json" | respond ;;
  "pr view "*"--json state --jq .state") jq -r .state "$FIX/prs/$3.json" ;;
  "pr merge "*)
    sha=$(sed -E 's#.*--match-head-commit ([0-9a-f]+).*#\1#' <<<"$*")
    [ "$sha" = "$(jq -r .head.sha "$FIX/prs/$3.json")" ] || { echo "Head branch was modified" >&2; exit 1; }
    echo $(($(cat "$FIX/merge-count-$3" 2>/dev/null || echo 0) + 1)) >"$FIX/merge-count-$3"
    jq '.state = "MERGED" | .mergedAt = "2027-01-15T08:00:00Z"' "$FIX/prs/$3.json" >"$FIX/prs/$3.tmp" && mv "$FIX/prs/$3.tmp" "$FIX/prs/$3.json" ;;
  "pr list"*"--state merged"*) prs '[.[] | select(.state == "MERGED") | {number, headRefName, mergedAt, body}]' ;;
  "pr list"*"--state all"*) prs '[.[] | {number, state, headRefName, baseRefName, headRefOid, mergedAt, closedAt, isCrossRepository}]' ;;
  "pr list"*) echo '[]' ;;
  "issue view "*)
    n=$(sed -E 's#^issue view ([0-9]+) .*#\1#' <<<"$*")
    jq -c --argjson n "$n" '.data.node.items.nodes[] | select(.content.number == $n) | .content | {title, state, labels: .labels.nodes}' "$FIX/board.json" ;;
  "project item-add"*) echo "ITEM_$(sed -E 's#.*/issues/([0-9]+).*#\1#' <<<"$*")" ;;
  "project item-edit"*)
    n=$(sed -E 's#.*--id ITEM_([0-9]+).*#\1#' <<<"$*")
    s=$(sed -E 's#.*--single-select-option-id (o[0-9]).*#\1#' <<<"$*")
    case $s in o0) s=Backlog ;; o1) s=Ready ;; o2) s="In progress" ;; o3) s="In review" ;; o4) s=Done ;; esac
    [[ $* != *--field-id\ F_S* ]] ||
      jq -c --argjson n "$n" --arg s "$s" '(.data.node.items.nodes[] | select(.content.number == $n) | .fieldValues.nodes[] | select(.field.name == "Status") | .name) = $s' \
        "$FIX/board.json" >"$FIX/board.tmp" && mv "$FIX/board.tmp" "$FIX/board.json" ;;
  "api repos/acme/app/issues/"*"/labels"*)
    n=$(sed -E 's#^api repos/acme/app/issues/([0-9]+)/labels.*#\1#' <<<"$*")
    jq -c --argjson n "$n" '(.data.node.items.nodes[] | select(.content.number == $n) | .content.labels.nodes) += [{name: "needs-human"}]' \
      "$FIX/board.json" >"$FIX/board.tmp" && mv "$FIX/board.tmp" "$FIX/board.json"
    echo '[]' ;;
  "api repos/acme/app/issues/"*"/comments"*) echo '{}' ;;
  "api repos/acme/app/dependabot/alerts"* | "api repos/acme/app/secret-scanning/alerts"*) echo '[]' | respond ;;
  "api repos/acme/app/branches?protected"*) ;;
  "auth status"*) ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac
STUB
cat >"$work/stub/claude" <<'STUB'
#!/usr/bin/env bash
args=("$@")
for ((i = 0; i < $#; i++)); do [ "${args[i]}" != --model ] || model=${args[i + 1]}; done
echo "$(basename "$PWD") ${model:-} role=${SENIOR_MODE_ROLE:-}" >>"$CLAUDE_LOG"
if [[ ${!#} == *"guard probe"* ]]; then
  echo '{"type": "user", "message": {"content": "senior-mode: skipping checks is denied (core.hooksPath); fix what the check reports instead."}}'
  exit 0
fi
n=$(sed -nE 's#.*/senior-mode/worktrees/[^/]+/(review-)?([0-9]+)(-r[0-9]+)?$#\2#p' <<<"$PWD")
[ -n "$n" ] || exit 0
c=$(($(cat "$FIX/launch-count-$n" 2>/dev/null || echo 0) + 1))
echo "$c" >"$FIX/launch-count-$n"
spec=$(cat "$FIX/claude-$n" 2>/dev/null || echo ok)
k=${spec#*:}
[ "$k" != "$spec" ] || k=1
case $spec in
  startup-settings:*) [ "$c" -gt "$k" ] || { echo "Claude Code is still loading your organization's settings" >&2; exit 1; } ;;
  api-529:*) [ "$c" -gt "$k" ] || { echo "API Error: 529 overloaded_error" >&2; exit 1; } ;;
  limit)
    if [ "$c" -eq 1 ]; then
      jq -nc --arg m "Claude AI usage limit reached|$((SENIOR_MODE_NOW + 100))" '{type: "result", is_error: true, result: $m}'
      exit 1
    fi ;;
  enospc)
    if [ "$c" -eq 1 ]; then
      echo 100 >"$SENIOR_MODE_DISK_FREE_FILE"
      echo "ENOSPC: no space left on device, write" >&2
      exit 1
    fi ;;
  silent-hang)
    if [ "$c" -eq 1 ]; then
      sleep 300 &
      wait
    fi ;;
  busy-child)
    # Longer than the stall delay, with a child that comes and goes all along.
    for _ in $(seq 20); do sleep 0.4 & wait $!; done ;;
esac
echo "feature of $n" >"feature-$n.txt"
git add "feature-$n.txt"
git -c user.name=t -c user.email=t@t commit -q -m "feat: ticket $n"
echo delivered >"$SENIOR_MODE_RUN_OUTCOME"
if [ "$spec" = orphan ]; then
  sleep 300 &
  echo $! >"$FIX/orphan-pid"
  disown
fi
echo '{"result": "ok"}'
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
exit 1
STUB
chmod +x "$work/stub/"*
export PATH="$work/stub:$PATH" SENIOR_MODE_RETRY_DELAY=0 SENIOR_MODE_POLL=0.1 SENIOR_MODE_PROBE_RETRY=0 SENIOR_MODE_LOADAVG=0 \
  SENIOR_MODE_DISK_FREE_MB=100000 SENIOR_MODE_BACKOFF_JITTER=0 USER=tester

# The sweep: the fault points of the code. A name in the code that is not here fails the suite.
sweep="after-meta after-launch after-exit-read after-push after-pr-create before-merge after-merge after-done during-state-write during-clean"

# --- one case: its own directory, its own repository ---

# setup <case> [<config json>...]: a repository with one Ready ticket (#105), a bare remote and the stubs' state.
setup() {
  CASE=$1
  c=$work/$1
  mkdir -p "$c/fix" "$c/claude-home" "$c/xdg" "$c/cfg"
  export FIX=$c/fix GH_LOG=$c/gh.log CLAUDE_LOG=$c/claude.log XDG_DATA_HOME=$c/xdg CLAUDE_CONFIG_DIR=$c/claude-home XDG_CONFIG_HOME=$c/cfg \
    REMOTE=$c/github.com/acme/app.git SENIOR_MODE_MANAGED_SETTINGS=$c/managed.json SENIOR_MODE_DISK_FREE_FILE=$c/fix/disk-free \
    SENIOR_MODE_FAULT_DIR=$c/fix
  : >"$GH_LOG"
  : >"$CLAUDE_LOG"
  echo '{"enabledPlugins": {"senior-mode@senior-mode": true}}' >"$CLAUDE_CONFIG_DIR/settings.json"
  echo 1800000000 >"$c/clock"
  git init -q --bare -b main "$REMOTE"
  repo=$c/app
  state=$repo/.git/senior-mode/serve
  git init -q -b main "$repo"
  git -C "$repo" remote add origin "$REMOTE"
  mkdir -p "$repo/.claude"
  jq -n --argjson a "${2:-{\}}" --argjson s "${3:-{\}}" '{project: {id: "PVT_1", owner: "acme", number: 3, fields: {Status: {id: "F_S", options:
      {Ready: "o1", "In progress": "o2", "In review": "o3", Backlog: "o0", Done: "o4"}}}}, autonomy: ({minMemoryMB: 0, parallel: 1, maxConsecutiveFailures: 2, ticketsPerHour: 6} + $a), wip: 1, bestOf: {n: 2}, process: {profile: "strict"}, serve: $s,
    notify: {digest: false}, github: {protection: "ruleset"}, audit: false, checks: [{name: "ok", run: "true"}], protected: []}' \
    >"$repo/.claude/senior-mode.json"
  git -C "$repo" add -A
  git -C "$repo" -c user.name=t -c user.email=t@t commit -q -m "chore: config"
  git -C "$repo" push -q origin main
  ticket 105 Ready
}
# ticket <n> <status>: adds the ticket to the board.
ticket() {
  local items="[]"
  [ ! -f "$FIX/board.json" ] || items=$(jq -c '.data.node.items.nodes' "$FIX/board.json")
  items=$(jq -c --argjson n "$1" --arg s "$2" '. + [{fieldValues: {nodes: [{name: $s, field: {name: "Status"}},
    {name: "P1 next", field: {name: "Priority"}}, {name: "S", field: {name: "Size"}}]},
    content: {authorAssociation: "OWNER", number: $n, title: "Ticket \($n)", url: "u", state: "OPEN", closedAt: null,
      labels: {nodes: []}, milestone: null, blockedBy: {nodes: []}}}]' <<<"$items")
  jq -nc --argjson i "$items" '{data: {node: {items: {pageInfo: {hasNextPage: false}, nodes: $i}}}}' >"$FIX/board.json"
}
fail() { echo "FAIL [$CASE]: $*" >>"$c/fail"; }
# poll: one poll of serve, waiting for its sessions; the clock is 61 s further at each. FAULT=<name>[:<nth>] breaks it.
poll() {
  local now
  now=$(cat "$c/clock")
  echo $((now + 61)) >"$c/clock"
  # The group takes the notice of the shell about a serve that a fault point killed.
  {
    (cd "$repo" && SENIOR_MODE_NOW=$now SENIOR_MODE_SERVE_ONCE=1 SENIOR_MODE_TEST=1 SENIOR_MODE_FAULT="${FAULT:-}" timeout -s KILL 120 "$cli" serve) \
      >>"$c/serve.out" 2>&1 || true
  } 2>/dev/null
}
ticket_status() {
  jq -r --argjson n "$1" '.data.node.items.nodes[] | select(.content.number == $n) | [.fieldValues.nodes[] | select(.field.name == "Status") | .name][0]' "$FIX/board.json"
}
needs_human() {
  jq -e --argjson n "$1" '.data.node.items.nodes[] | select(.content.number == $n) | [.content.labels.nodes[].name] | index("needs-human") != null' "$FIX/board.json" >/dev/null
}
terminal() {
  local n
  for n in $(jq -r '.data.node.items.nodes[].content.number' "$FIX/board.json"); do
    [ "$(ticket_status "$n")" = Done ] || needs_human "$n" || return 1
  done
}
snap() {
  { cat "$FIX/board.json" "$FIX"/prs/*.json 2>/dev/null; git --git-dir "$REMOTE" for-each-ref; cat "$FIX"/merge-count-* 2>/dev/null; } | cksum
}
# settle: polls until every ticket is Done or needs-human (30 polls at most), then twice more: nothing may change.
settle() {
  local before
  for _ in $(seq 30); do
    poll
    ! terminal || break
  done
  terminal || { fail "did not settle in 30 polls: $(tail -n 4 "$c/serve.out" | cut -c1-200)"; return 1; }
  before=$(snap)
  poll
  poll
  [ "$before" = "$(snap)" ] || fail "a poll changed something after the ticket was settled"
  invariants
}
# invariants: I2 to I4 and no session left.
invariants() {
  local f dup n worktrees=0 humans=0
  for f in "$FIX"/merge-count-*; do
    [ ! -e "$f" ] || [ "$(cat "$f")" -le 1 ] || fail "I2: a pull request was merged twice ($f)"
  done
  if ls "$FIX"/prs/*.json >/dev/null 2>&1; then
    dup=$(cat "$FIX"/prs/*.json | jq -s '[.[].head.ref] | group_by(.) | map(select(length > 1)) | length')
    [ "$dup" = 0 ] || fail "I2: two pull requests share a head"
  fi
  for n in $(jq -r '.data.node.items.nodes[].content.number' "$FIX/board.json"); do ! needs_human "$n" || humans=$((humans + 1)); done
  worktrees=$(git -C "$repo" worktree list --porcelain | grep -c '^worktree .*/worktrees/')
  [ "$worktrees" -le "$humans" ] || fail "I3: $worktrees worktree(s) left for $humans ticket(s) waiting for a human"
  for f in "$state"/*.meta "$state"/held "$state"/*.json; do
    [ -e "$f" ] || continue
    case $f in */[0-9]*-sonnet.json | */[0-9]*-opus.json) continue ;; esac
    jq -e . "$f" >/dev/null 2>&1 || fail "I4: $f does not parse"
  done
  if pgrep -f "$state/[0-9]+\.sh" >/dev/null 2>&1; then fail "a session is still alive: $(pgrep -af "$state/[0-9]+\.sh" | head -n 2)"; fi
}
# done_ok <n>: the ticket is Done, with one merged pull request.
done_ok() {
  [ "$(ticket_status "$1")" = Done ] || fail "#$1 is $(ticket_status "$1"), not Done: $(tail -n 3 "$c/serve.out" | cut -c1-200)"
  [ "$(jq -r .state "$FIX/prs/$(($1 + 100)).json" 2>/dev/null)" = MERGED ] || fail "#$1: its pull request is not merged"
  [ "$(cat "$FIX/merge-count-$(($1 + 100))" 2>/dev/null)" = 1 ] || fail "#$1: not merged exactly once: $(cat "$FIX/merge-count-$(($1 + 100))" 2>/dev/null)"
}
no_human() { ! needs_human "$1" || fail "#$1 got needs-human: $(tail -n 3 "$c/serve.out" | cut -c1-200)"; }

# --- the cases ---

# F1: kill -9 at each fault point of a ticket's life.
case_sweep() {
  local point=$1
  setup "sweep-$point"
  FAULT=$point
  settle
  FAULT=""
  terminal || return 0
  done_ok 105
  [ "$(cat "$FIX/fault-${point}" 2>/dev/null || echo 0)" -ge 1 ] || fail "the fault point $point was never reached"
  [ "$(ls "$FIX"/prs/*.json 2>/dev/null | wc -l)" -eq 1 ] || fail "not exactly one pull request: $(ls "$FIX/prs")"
}
# F2: serve dies between `gh pr merge` and the Done write: the merge is read back, Done, no second merge.
case_merge() {
  setup merge
  FAULT=after-merge
  settle
  done_ok 105
  grep -c '^pr merge' "$GH_LOG" | grep -qx 1 || fail "pr merge was called more than once: $(grep '^pr merge' "$GH_LOG")"
}
# F3: the network down for 10 polls: nothing lost, nobody is called for help, the ticket is delivered once it is back.
case_network() {
  setup network
  echo down >"$FIX/gh-mode"
  for _ in $(seq 10); do poll; done
  rm -f "$FIX/gh-mode"
  no_human 105
  [ ! -e "$state/paused" ] || fail "the breaker paused serve on a network outage"
  settle
  done_ok 105
  no_human 105
}
# F4: gh answering 502 now and then: retried, no duplicate pull request.
case_5xx() {
  setup 5xx
  echo 5xx:6 >"$FIX/gh-mode"
  settle
  done_ok 105
  [ "$(ls "$FIX"/prs/*.json | wc -l)" -eq 1 ] || fail "not exactly one pull request"
}
# F5: gh answering 401 then 200: `held` names gh auth, nothing is labelled, launches resume by themselves.
case_auth() {
  setup auth
  echo 401 >"$FIX/gh-mode"
  poll
  poll
  no_human 105
  [ "$(ticket_status 105)" = Ready ] || fail "the ticket moved while gh was signed out: $(ticket_status 105)"
  rm -f "$FIX/gh-mode"
  settle
  done_ok 105
  no_human 105
  [ ! -e "$state/held" ] || fail "the hold is still on: $(cat "$state/held")"
}
# F6: claude dying at startup three times: same model, no escalation, no failure counted, delivered.
case_startup() {
  setup startup
  echo startup-settings:3 >"$FIX/claude-105"
  settle
  done_ok 105
  no_human 105
  grep -q ' opus ' "$CLAUDE_LOG" && fail "escalated to Opus after a startup error: $(cat "$CLAUDE_LOG")"
  [ ! -e "$state/paused" ] || fail "the breaker paused serve"
}
# F8: the usage limit with a reset time: nothing launches before it, then the ticket is delivered.
case_limit() {
  setup limit
  echo limit >"$FIX/claude-105"
  poll
  [ -s "$state/limit-until" ] || fail "no limit-until after the usage limit: $(tail -n 3 "$c/serve.out")"
  local launches
  launches=$(cat "$FIX/launch-count-105")
  poll
  [ "$(cat "$FIX/launch-count-105")" = "$launches" ] || fail "a session started before the reset"
  settle
  done_ok 105
  no_human 105
}
# F9: a disk that fills: the session dies of ENOSPC, the hold names the disk, the ticket is not blamed, and once there is
# room again it is delivered.
case_disk() {
  setup disk
  echo enospc >"$FIX/claude-105"
  poll
  no_human 105
  [ "$(ticket_status 105)" = Ready ] || fail "the ticket is $(ticket_status 105), not back to Ready"
  echo 100000 >"$FIX/disk-free"
  settle
  done_ok 105
  no_human 105
  [ ! -e "$state/paused" ] || fail "the breaker paused serve on a full disk"
}
# F10: a red base branch: no ticket session starts; once main is green the ticket is delivered.
case_red() {
  setup red
  touch "$FIX/red-main"
  poll
  poll
  ! grep -q 'role=ticket' "$CLAUDE_LOG" || fail "a session started on a red main: $(cat "$CLAUDE_LOG")"
  [ "$(ticket_status 105)" = Ready ] || fail "the ticket moved on a red main"
  rm -f "$FIX/red-main"
  settle
  done_ok 105
}
# F11: the state files cut in half after a kill: the old file or the quarantine, and the ticket still converges.
case_truncated() {
  setup truncated
  FAULT=after-launch
  poll
  FAULT=""
  local f n
  for f in "$state"/*; do
    case $f in *.sh | *.prompt | *.log | *-sonnet.json | *-opus.json | *.corrupt-*) continue ;; esac
    [ -f "$f" ] || continue
    n=$(wc -c <"$f")
    head -c $((n / 2)) "$f" >"$f.half" && mv "$f.half" "$f"
  done
  settle
  terminal || return 0
  [ "$(ticket_status 105)" = Done ] || needs_human 105 || fail "neither Done nor needs-human"
}
# F13: a session that goes silent is stopped and resumed once; a long one that works is left alone; what a session left
# behind is killed.
case_hang() {
  setup hang '{"startupMinutes": 2, "stallMinutes": 3}'
  export SENIOR_MODE_TIMEOUT_UNIT=1
  echo silent-hang >"$FIX/claude-105"
  settle
  done_ok 105
  no_human 105
  [ "$(cat "$FIX/launch-count-105")" = 2 ] || fail "not exactly one resumption: $(cat "$FIX/launch-count-105") launches"
  grep -q 'the session is stopped' "$c/serve.out" || fail "the stop is not said: $(cat "$c/serve.out" | cut -c1-200 | tail -n 5)"
}
case_busy() {
  setup busy '{"startupMinutes": 2, "stallMinutes": 3}'
  export SENIOR_MODE_TIMEOUT_UNIT=1
  echo busy-child >"$FIX/claude-105"
  settle
  done_ok 105
  [ "$(cat "$FIX/launch-count-105")" = 1 ] || fail "a session that works was stopped: $(cat "$FIX/launch-count-105") launches"
}
case_orphan() {
  setup orphan
  echo orphan >"$FIX/claude-105"
  settle
  done_ok 105
  ! kill -0 "$(cat "$FIX/orphan-pid")" 2>/dev/null || fail "the process the session left behind is still running"
}
# F14: a session killed from outside is recovered once; a stale index.lock is removed.
case_lost() {
  setup lost
  FAULT=after-launch
  poll
  FAULT=""
  local pgid
  pgid=$(cat "$state/105.pgid" 2>/dev/null) || pgid=""
  [ -z "$pgid" ] || kill -9 -- "-$pgid" 2>/dev/null || true
  sleep 1
  rm -f "$state/105.exit"
  : >"$repo/.git/index.lock"
  touch -d '20 minutes ago' "$repo/.git/index.lock"
  settle
  done_ok 105
  [ ! -e "$repo/.git/index.lock" ] || fail "the stale index.lock is still there"
}
# F15: a second daemon is refused; a serve.pid with a reused pid is replaced.
case_daemon() {
  setup daemon '{}' '{"interval": 1}'
  (cd "$repo" && exec "$cli" serve) >"$c/daemon.out" 2>&1 &
  local pid=$!
  for _ in $(seq 100); do [ -s "$state/serve.pid" ] && break; sleep 0.1; done
  (cd "$repo" && "$cli" serve) >"$c/second.out" 2>&1 && fail "a second serve was accepted"
  grep -q 'already runs' "$c/second.out" || fail "the second serve was not refused for that: $(cat "$c/second.out")"
  kill -TERM "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  sleep 60 &
  local stale=$!
  echo "$stale" >"$state/serve.pid"
  settle
  kill "$stale" 2>/dev/null
  done_ok 105
}

# --- the runner ---

# demo.sh is not on the serve path: test-demo.sh covers its fault point.
fault_names=$(grep -rhoE --exclude=demo.sh 'fault_point [a-z-]+' "$libs" | sed 's/fault_point //' | sort -u)
for p in $fault_names; do
  [[ " $sweep " == *" $p "* ]] || echo "FAIL: the fault point $p of the code is not in the sweep"
done >"$work/res/names"

cases=(merge network 5xx auth startup limit disk red truncated hang busy orphan lost daemon)
for p in $sweep; do cases+=("sweep:$p"); done
max=$(($(nproc 2>/dev/null || echo 2) / 2))
[ "$max" -ge 2 ] || max=2
[ "$max" -le 6 ] || max=6
for k in "${cases[@]}"; do
  while [ "$(jobs -rp | wc -l)" -ge "$max" ]; do wait -n 2>/dev/null || true; done
  (
    case $k in
      sweep:*) case_sweep "${k#sweep:}" ;;
      *) "case_$k" ;;
    esac
  ) >"$work/res/${k//:/-}.out" 2>&1 &
done
wait
failures=0
cat "$work/res/names"
[ ! -s "$work/res/names" ] || failures=$((failures + 1))
for f in "$work"/*/fail; do
  [ -e "$f" ] || continue
  cat "$f"
  failures=$((failures + 1))
done
for f in "$work"/res/*.out; do [ ! -s "$f" ] || { echo "--- $(basename "$f")"; cut -c1-300 "$f" | head -n 20; }; done
[ "$failures" -eq 0 ] && echo "chaos: all cases pass"
exit "$failures"
