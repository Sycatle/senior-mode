#!/usr/bin/env bash
# Tests for serve and the sandbox decision (#760, spec 328 section 2.1): the launch path calls sandbox_decide, the host note is
# logged once per local day, `required` without a runtime or a model credential holds every launch with cause `sandbox` (an
# approved pull request still merges), and the hold lifts with one `recovered` alert when they appear. Offline, with the stubs
# of test-serve.sh (gh, claude, curl): the runtime is a stub named by sandbox.runtime.
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
shopt -s extglob
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
    # A line of $FIX/status-<sha> is "<context> <state> [<epoch it was set at>]"; the last line of a context wins.
    { cat "$FIX/status-$sha" 2>/dev/null || true; } | jq -Rn '[inputs | split(" ") | {key: .[0], value: {state: .[1], at: .[2]}}] | from_entries
      | to_entries | {statuses: map({context: .key, state: .value.state, updated_at: (.value.at | if . then tonumber | todate else null end)})}' | respond ;;
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
  "api repos/acme/app/issues/"*"/sub_issues"*)
    { cat "$FIX/subs-$(sed -E 's#^api repos/acme/app/issues/([0-9]+)/.*#\1#' <<<"$*").json" 2>/dev/null || echo '[]'; } | respond ;;
  "api -X POST repos/acme/app/issues/"*"/sub_issues"*) echo "$*" >>"$FIX/sub-issues" ;;
  "api repos/acme/app/issues/"[0-9]*" --jq .id") echo 1 ;;
  "api repos/acme/app/issues/"+([0-9])" -X PATCH"*) echo "$*" >>"$FIX/issue-patch" ;;
  "api repos/acme/app/issues/"+([0-9])" --jq "*) { cat "$FIX/issue-$(sed -E 's#^api repos/acme/app/issues/([0-9]+) .*#\1#' <<<"$*").json" 2>/dev/null || true; } | respond ;;
  "api repos/acme/app/issues/"*"/comments"*)
    # The comments of an issue: $FIX/comments-<n>.json holds them (body, author_association); a POST is only logged.
    { cat "$FIX/comments-$(sed -E 's#^api repos/acme/app/issues/([0-9]+)/.*#\1#' <<<"$*").json" 2>/dev/null || echo '{}'; } | respond ;;
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
n=$(sed -nE 's#.*/senior-mode/worktrees/[^/]+/(review-|idea-)?([0-9]+)(-[rb][0-9]+)?$#\2#p' <<<"$PWD")
[ -n "$n" ] || exit 0
printf '%s\n' "${*:1:$#-1}" >"$FIX/args-$n"
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
    autonomy: ({minMemoryMB: 0, parallel: 1, maxConsecutiveFailures: 2, ticketsPerHour: 6} + $a), wip: 1, bestOf: {n: 2}, process: {profile: "strict"},
    serve: $s, notify: ({digest: false} + $nt), github: {protection: "ruleset"}, audit: false,
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
# Helpers for the pull request cases: the remote has real branches (a scratch clone makes them).
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

# A container runtime that does nothing and succeeds (its calls are logged), and the model credential file of the sandbox.
cat >"$work/stub/mystub" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$RT_LOG"
STUB
chmod +x "$work/stub/mystub"
export RT_LOG="$work/rt.log"
cred=$work/credentials.env
# sbx <sandbox json>: the sandbox keys of the project's config, over what `config` wrote. runtime `nonexistent` is no runtime.
sbx() {
  jq --argjson s "$1" '.sandbox = $s' "$repo/.claude/senior-mode.json" >"$work/cfg.json" && mv "$work/cfg.json" "$repo/.claude/senior-mode.json"
  git -C "$repo" add -A
  git -C "$repo" -c user.name=t -c user.email=t@t commit -q -m "chore: sandbox" --allow-empty
  git -C "$repo" push -q origin main
}
notified() { grep -c "\"event\":\"$1\"" "$CURL_LOG"; }
day=86400

# auto and no runtime: the session runs on the host as today, and `sandbox: off (no runtime)` is logged once per local day.
config '{}'
sbx '{"mode": "auto", "runtime": "nonexistent", "credentialFile": "'"$cred"'"}'
board 10
session 10-sonnet delivered pr
fresh
once || fail "A: serve failed: $(cat "$work/out")"
started 10 || fail "A: no session on the host: $(cat "$CLAUDE_LOG")"
[ "$(grep -c 'serve: sandbox: off (no runtime)' "$work/out")" = 1 ] || fail "A: the host note is not logged once: $(cat "$work/out")"
[ ! -e "$state/held" ] || fail "A: auto holds: $(cat "$state/held")"
board 11
session 11-sonnet delivered pr
once || fail "A: serve failed: $(cat "$work/out")"
started 11 || fail "A: no session on the second poll: $(cat "$CLAUDE_LOG")"
grep -q 'sandbox: off (no runtime)' "$work/out" && fail "A: the second poll of the day is not silent: $(cat "$work/out")"
board 12
session 12-sonnet delivered pr
SENIOR_MODE_NOW=$((1800000000 + day)) once || fail "A: serve failed: $(cat "$work/out")"
grep -q 'serve: sandbox: off (no runtime)' "$work/out" || fail "A: the note is not logged again the next day: $(cat "$work/out")"

# required and no runtime: held with cause sandbox, nothing launches, an approved pull request still merges; a poll that
# still finds no runtime keeps the hold (the generic probe of serve_hold would read the environment as green).
config '{}' '{}' '{"webhook": "https://hooks.example/h"}'
sbx '{"mode": "required", "runtime": "nonexistent", "credentialFile": "'"$cred"'"}'
printf 'CLAUDE_CODE_OAUTH_TOKEN=tok\n' >"$cred"
chmod 600 "$cred"
boardx "94:In review:S:P1 next" "95:Ready:S:P1 next"
prs_reset
sha94=$(mkbranch feat/94-x f94.txt)
pr 194 feat/94-x "$sha94" clean
green "$sha94"
session 95-sonnet delivered pr
fresh
: >"$CURL_LOG"
once || fail "B: serve failed: $(cat "$work/out")"
[ "$(jq -r .cause "$state/held" 2>/dev/null)" = sandbox ] || fail "B: no sandbox hold: $(cat "$work/out")"
jq -e '.detail | test("^sandbox required: no container runtime")' "$state/held" >/dev/null || fail "B: the hold does not name the runtime: $(cat "$state/held")"
started 95 && fail "B: a ticket started in the hold: $(cat "$CLAUDE_LOG")"
grep -q "^pr merge 194 --rebase --match-head-commit $sha94 -R acme/app$" "$GH_LOG" || fail "B: the approved pull request did not merge: $(grep '^pr ' "$GH_LOG")"
[ "$(notified environment)" = 1 ] || fail "B: not one alert for the hold: $(cat "$CURL_LOG")"
board 95
SENIOR_MODE_NOW=1800000100 once || fail "B: serve failed: $(cat "$work/out")"
[ "$(jq -r .cause "$state/held" 2>/dev/null)" = sandbox ] || fail "B: the hold was lifted with no runtime: $(cat "$work/out")"
started 95 && fail "B: a ticket started in the hold on the next poll"
[ "$(notified recovered)" = 0 ] || fail "B: a recovered alert while held: $(cat "$CURL_LOG")"
# The runtime appears: the hold lifts with exactly one recovered alert, and the ticket starts in a container.
sbx '{"mode": "required", "runtime": "mystub", "credentialFile": "'"$cred"'"}'
SENIOR_MODE_NOW=1800000200 once || fail "B: serve failed: $(cat "$work/out")"
[ ! -e "$state/held" ] || fail "B: the hold is not lifted when the runtime appears: $(cat "$state/held")"
[ "$(notified recovered)" = 1 ] || fail "B: not one recovered alert: $(cat "$CURL_LOG")"
started 95 || fail "B: #95 not started once the hold is lifted: $(cat "$work/out")"
grep -q '^image inspect senior-mode/base:' "$RT_LOG" || fail "B: the image of the container is not looked up: $(cat "$RT_LOG" 2>&1)"
SENIOR_MODE_NOW=1800000300 once || fail "B: serve failed: $(cat "$work/out")"
[ "$(notified recovered)" = 1 ] || fail "B: a second recovered alert: $(cat "$CURL_LOG")"

# required with a runtime and no model credential: held, naming it; the credential file appears (0600): one recovered alert.
config '{}' '{}' '{"webhook": "https://hooks.example/h"}'
sbx '{"mode": "required", "runtime": "mystub", "credentialFile": "'"$cred"'"}'
rm -f "$cred"
board 96
session 96-sonnet delivered pr
fresh
: >"$CURL_LOG"
once || fail "C: serve failed: $(cat "$work/out")"
[ "$(jq -r .cause "$state/held" 2>/dev/null)" = sandbox ] || fail "C: no sandbox hold: $(cat "$work/out")"
jq -e '.detail == "no model credential for containers: run claude setup-token"' "$state/held" >/dev/null || fail "C: the hold does not name the credential: $(cat "$state/held")"
started 96 && fail "C: a ticket started with no credential"
printf 'CLAUDE_CODE_OAUTH_TOKEN=tok\n' >"$cred"
chmod 644 "$cred"
SENIOR_MODE_NOW=1800000100 once || fail "C: serve failed: $(cat "$work/out")"
[ "$(jq -r .cause "$state/held" 2>/dev/null)" = sandbox ] || fail "C: a file readable by others lifted the hold: $(cat "$work/out")"
chmod 600 "$cred"
SENIOR_MODE_NOW=1800000200 once || fail "C: serve failed: $(cat "$work/out")"
[ ! -e "$state/held" ] || fail "C: the hold is not lifted when the credential appears: $(cat "$state/held")"
[ "$(notified recovered)" = 1 ] || fail "C: not one recovered alert: $(cat "$CURL_LOG")"
started 96 || fail "C: #96 not started once the hold is lifted: $(cat "$work/out")"

# auto with a runtime and no credential runs on the host (decision of #851) and holds nothing.
config '{}'
sbx '{"mode": "auto", "runtime": "mystub", "credentialFile": "'"$work"'/none.env"}'
board 97
session 97-sonnet delivered pr
fresh
once || fail "D: serve failed: $(cat "$work/out")"
started 97 || fail "D: no session on the host: $(cat "$work/out")"
grep -q 'sandbox: off (no model credential)' "$work/out" || fail "D: the note is missing: $(cat "$work/out")"
[ ! -e "$state/held" ] || fail "D: auto holds: $(cat "$state/held")"

[ "$failures" -eq 0 ] || exit 1
echo "serve sandbox: ok"
