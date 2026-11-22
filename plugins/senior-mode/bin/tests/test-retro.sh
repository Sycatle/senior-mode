#!/usr/bin/env bash
# Tests for `senior-mode retro`. Offline: gh is a stub answering two GraphQL queries, the Project
# board (the one `status` uses) and the history of recent issues and pull requests, from fixtures.
set -u
cli=$(cd "$(dirname "$0")/.." && pwd)/senior-mode
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0
# shellcheck source=/dev/null
. "$(dirname "$0")/fixture-runs.sh"

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

mkdir -p "$work/stub" "$work/fix"
cat >"$work/stub/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$GH_LOG"
jqf="" prev=""
for a in "$@"; do [ "$prev" = --jq ] && jqf=$a; prev=$a; done
respond() { if [ -n "$jqf" ]; then jq -r "$jqf"; else cat; fi; }
arg() { local prev=""; for a in "$@"; do [ "$prev" = "$FLAG" ] && echo "$a"; prev=$a; done; }
[ -z "${GH_FAIL:-}" ] || { echo "HTTP 401: bad credentials" >&2; exit 1; }
case "$*" in
  "api graphql --input -")
    body=$(cat)
    if grep -q ProjectV2ItemStatusChangedEvent <<<"$body"; then
      printf '%s\n' "$body" >>"$FIX/history-bodies"
      cat "$FIX/history.json"
    else
      printf '%s\n' "$body" >>"$FIX/board-bodies"
      cat "$FIX/board.json"
    fi ;;
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
  "project item-add"*) echo ITEM ;;
  "project item-edit"*) ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$work/stub/gh"
export PATH="$work/stub:$PATH" GH_LOG="$work/gh.log" FIX="$work/fix" SENIOR_MODE_RETRY_DELAY=0

repo="$work/repo"
git init -q "$repo"
git -C "$repo" remote add origin git@github.com:acme/app.git
mkdir -p "$repo/.claude"
echo '{"project": {"id": "PVT_1", "owner": "acme", "number": 3}}' >"$repo/.claude/senior-mode.json"
git -C "$repo" add -A
git -C "$repo" -c user.name=t -c user.email=t@t commit -q -m "chore: config"

ago() { date -u -d "@$(($(date +%s) - $1))" +%Y-%m-%dT%H:%M:%SZ; }
HOUR=3600
DAY=86400

# item <number> <status> <size> <state>
item() {
  jq -nc --argjson n "$1" --arg s "$2" --arg z "$3" --arg st "$4" '{
    fieldValues: {nodes: [{name: $s, field: {name: "Status"}}, {name: $z, field: {name: "Size"}}]},
    content: {number: $n, title: "Ticket \($n)", url: "u\($n)", state: $st, closedAt: null,
      labels: {nodes: []}, milestone: null, blockedBy: {nodes: []}}}'
}
items=$(jq -sc '.' < <(
  item 4 Done S CLOSED
  item 5 Done S CLOSED
  item 6 Done M CLOSED
  item 7 Done S CLOSED
  item 8 "In progress" M OPEN
  item 3 Done S CLOSED
))
prs=$(jq -nc '[{number: 31, title: "Ticket 8 slice", url: "u31", isDraft: false, headRefName: "feat/8-slice",
  labels: {nodes: [{name: "needs-human"}]}, commits: {nodes: [{commit: {statusCheckRollup: null}}]}}]')
closed=$(jq -nc --arg a "$(ago $DAY)" --arg b "$(ago $((2 * DAY)))" --arg c "$(ago $((20 * DAY)))" '[
  {number: 5, title: "Ticket 5", closedAt: $a, stateReason: "COMPLETED"},
  {number: 6, title: "Ticket 6", closedAt: $b, stateReason: "COMPLETED"},
  {number: 7, title: "Ticket 7", closedAt: $a, stateReason: "COMPLETED"},
  {number: 4, title: "Ticket 4", closedAt: $c, stateReason: "COMPLETED"},
  {number: 3, title: "Ticket 3", closedAt: $a, stateReason: "NOT_PLANNED"}]')
jq -nc --argjson items "$items" --argjson prs "$prs" --argjson closed "$closed" '{data: {node: {items: {
  pageInfo: {hasNextPage: false, endCursor: null}, nodes: $items}},
  repository: {latestRelease: null, pullRequests: {nodes: $prs}, closed: {nodes: $closed}, merged: {nodes: []}}}}' >"$FIX/board.json"

# History: status changes and reopenings of recently updated issues, recently merged pull requests.
# Ticket 5 started 30 hours before it closed, ticket 6 four days before, ticket 7 has no recorded start.
ev() { jq -nc --arg t "$1" --arg at "$2" --arg s "${3:-}" \
  'if $t == "status" then {__typename: "ProjectV2ItemStatusChangedEvent", createdAt: $at, status: $s, previousStatus: "Ready"}
   else {__typename: "ReopenedEvent", createdAt: $at} end'; }
issue() { jq -nc --argjson n "$1" --argjson ev "$2" '{number: $n, title: "Ticket \($n)", timelineItems: {nodes: $ev}}'; }
pr() { # number branch additions deletions mergedAt labels-json reviews-json
  jq -nc --argjson n "$1" --arg b "$2" --argjson a "$3" --argjson d "$4" --arg m "$5" --argjson l "$6" --argjson r "$7" \
    '{number: $n, title: "PR \($n)", headRefName: $b, additions: $a, deletions: $d, mergedAt: $m,
      labels: {nodes: ($l | map({name: .}))}, reviews: {nodes: $r}}'; }
issues=$(jq -sc '.' < <(
  issue 5 "[$(ev status "$(ago $((DAY + 30 * HOUR)))" "In progress"), $(ev status "$(ago $DAY)" Done)]"
  issue 6 "[$(ev status "$(ago $((6 * DAY)))" "In progress"), $(ev status "$(ago $((2 * DAY)))" Done)]"
  issue 7 "[]"
  issue 8 "[$(ev status "$(ago $((3 * DAY)))" "In progress"), $(ev reopened "$(ago $DAY)")]"
  issue 9 "[$(ev reopened "$(ago $((20 * DAY)))")]"
  issue 4 "[$(ev status "$(ago $((22 * DAY)))" "In progress")]"
))
merged=$(jq -sc '.' < <(
  pr 40 feat/5-slice 30 10 "$(ago $DAY)" '[]' '[{"state": "APPROVED", "bodyText": "ok", "author": {"login": "bot"}}]'
  pr 41 feat/6-slice 800 100 "$(ago $((2 * DAY)))" '["needs-human"]' \
    '[{"state": "CHANGES_REQUESTED", "bodyText": "Split this\nin two", "author": {"login": "alice"}}]'
  pr 42 feat/4-slice 10 0 "$(ago $((20 * DAY)))" '["needs-human"]' '[]'
  pr 43 fix/7-slice 5 5 "$(ago $DAY)" '[]' '[]'
))
jq -nc --argjson i "$issues" --argjson m "$merged" \
  '{data: {repository: {issues: {nodes: $i}, pullRequests: {nodes: $m}}}}' >"$FIX/history.json"

# Local facts: run outcomes (the records of fixture-runs.sh, the same ones test-run.sh checks
# `run` against, in the folder `run` writes them to) and recorded check results. Ticket 12 finished long
# ago; a broken file and a session log of `run` sit next to them and are ignored.
runs="$repo/.git/senior-mode/runs/20260101-000000-1"
mkdir -p "$runs" "$repo/.git/senior-mode/checks"
while IFS= read -r rec; do
  n=$(jq -r .ticket <<<"$rec")
  at=$(ago $DAY)
  [ "$n" != 12 ] || at=$(ago $((20 * DAY)))
  jq -c --arg at "$at" '. + {finishedAt: $at}' <<<"$rec" >"$runs/$n.json"
done < <(jq -c '.[]' <<<"$RUN_OUTCOMES")
echo 'not json {' >"$runs/broken.json"
jq -nc --arg at "$(ago $DAY)" '{ticket: 99, outcome: "failed", reason: "a session log, not an outcome", finishedAt: $at}' >"$runs/10-sonnet.json"
checks="$repo/.git/senior-mode/checks"
printf 'failure\nfailed: lint\n' >"$checks/aaaaaaa1111111111111111111111111111111111"
printf 'success\n6/6 checks passed\n' >"$checks/bbbbbbb2222222222222222222222222222222222"
printf 'failure\nfailed: test\n' >"$checks/ccccccc3333333333333333333333333333333333"
touch -d "20 days ago" "$checks/ccccccc3333333333333333333333333333333333"

run() { : >"$GH_LOG"; : >"$FIX/board-bodies"; : >"$FIX/history-bodies"; (cd "$repo" && "$cli" "$@") >"$work/out" 2>"$work/err"; }
json() { jq -c "$1" "$work/out"; }

run retro --json || fail "retro --json failed: $(cat "$work/err")"
[ "$(grep -c '^api ' "$GH_LOG")" -eq 4 ] || fail "retro makes $(grep -c '^api ' "$GH_LOG") gh calls, wanted 4 (the two alert lists, board, history)"
[ "$(jq -r '.variables.repo' "$FIX/board-bodies")" = true ] || fail "retro does not reuse the board with repository facts"
[ "$(jq -r '.variables.owner + "/" + .variables.name' "$FIX/history-bodies")" = acme/app ] || fail "history repository: $(cat "$FIX/history-bodies")"
since_sent=$(jq -r '.variables.since' "$FIX/history-bodies")
[ "$since_sent" = "$(json .since | tr -d '"')" ] || fail "history since $since_sent differs from the output's"
[ "$(json '.since[:10]')" = "\"$(ago $((7 * DAY)) | cut -c1-10)\"" ] || fail "default period is not 7 days: $(json .since)"

[ "$(json '.done | map(.number)')" = "[5,6,7]" ] || fail "done: $(json .done)"
[ "$(json '.done[0] | [.size, .cycleHours, .lines] | map(tostring) | join("|")')" = '"S|30|40"' ] || fail "ticket 5: $(json '.done[0]')"
[ "$(json '.done[2] | [.cycleHours, .lines] | map(tostring) | join("|")')" = '"null|10"' ] || fail "ticket 7 has no start: $(json '.done[2]')"
[ "$(json '.cycle | [.measured, .medianHours, .worst.number, .worst.hours] | map(tostring) | join("|")')" = '"2|63|6|96"' ] ||
  fail "cycle time: $(json .cycle)"

[ "$(json '.humanPullRequests | map([.number, .state])')" = '[[31,"open"],[41,"merged"]]' ] || fail "human PRs: $(json .humanPullRequests)"
[ "$(json '.humanPullRequests[0].why')" = '["needs-human label"]' ] || fail "open PR why: $(json '.humanPullRequests[0]')"
[ "$(json '.humanPullRequests[1].why')" = '["needs-human label","changes requested by alice: Split this in two"]' ] ||
  fail "merged PR why: $(json '.humanPullRequests[1]')"

[ "$(json '.runs.found')" = true ] || fail "runs not found"
[ "$(json '.runs.failed | map(.ticket)')" = "[20,30]" ] || fail "failed runs: $(json .runs)"
[ "$(json '.runs.failed[1].reason')" = '"needs a data migration"' ] || fail "outgrown run: $(json .runs)"
[ "$(json '.runs.escalated | map([.ticket, .reason])')" = '[[11,"tests do not pass"]]' ] || fail "escalated runs: $(json .runs)"
[ "$(json '.reopened | map(.number)')" = "[8]" ] || fail "reopened: $(json .reopened)"
[ "$(json '.checkFailures | map(.description)')" = '["failed: lint"]' ] || fail "check failures: $(json .checkFailures)"
[ "$(json '.checkFailures[0].commit')" = '"aaaaaaa"' ] || fail "check failure commit: $(json .checkFailures)"
[ "$(json '.sizes | map([.number, .size, .lines, .limit, .over])')" = '[[5,"S",40,50,false],[6,"M",900,400,true],[7,"S",10,50,false]]' ] ||
  fail "sizes: $(json .sizes)"

# --since widens the window for every source.
run retro --json --since 30d || fail "--since failed: $(cat "$work/err")"
[ "$(json '.done | map(.number)')" = "[4,5,6,7]" ] || fail "--since 30d done: $(json .done)"
[ "$(json '.humanPullRequests | map(.number)')" = "[31,41,42]" ] || fail "--since 30d human PRs: $(json .humanPullRequests)"
[ "$(json '.reopened | map(.number)')" = "[8,9]" ] || fail "--since 30d reopened: $(json .reopened)"
[ "$(json '.runs.failed | map(.ticket)')" = "[12,20,30]" ] || fail "--since 30d failed runs: $(json .runs)"
[ "$(json '.runs.escalated | map(.ticket)')" = "[11,12]" ] || fail "--since 30d escalated runs: $(json .runs)"
[ "$(json '.checkFailures | length')" -eq 2 ] || fail "--since 30d check failures: $(json .checkFailures)"

# Plain words.
run retro || fail "retro failed: $(cat "$work/err")"
for want in "Done in the last 7d (3)" "#5 Ticket 5" "Cycle time" "median 63h" "worst 96h (#6 Ticket 6)" \
  "Needed a human" "pull request #41 PR 41: needs-human label; changes requested by alice: Split this in two" \
  "Failed or escalated runs" "#20: failed: the session said delivered but there is no open pull request" "#11: escalated: tests do not pass" \
  "Reopened" "#8 Ticket 8" "Check failures" "aaaaaaa: failed: lint" "Estimates against reality" "#6 M: 900 lines"; do
  grep -qF -- "$want" "$work/out" || fail "plain retro lacks '$want': $(cat "$work/out")"
done
grep -qF "#4 " "$work/out" && fail "a ticket outside the period is listed: $(cat "$work/out")"
grep -qF "#5 S" "$work/out" && fail "a ticket within its size is flagged: $(cat "$work/out")"
[ "$(git -C "$repo" status --porcelain | wc -l)" -eq 0 ] || fail "retro left changes in the tree: $(git -C "$repo" status --porcelain)"

# From a linked worktree, retro reads the same outcomes: they live in the git common directory.
git -C "$repo" worktree add -q -b wt "$work/app-wt"
(cd "$work/app-wt" && "$cli" retro --json) >"$work/out" 2>"$work/err" || fail "retro from a worktree failed: $(cat "$work/err")"
[ "$(json '.runs.failed | map(.ticket)')" = "[20,30]" ] || fail "runs seen from a worktree: $(json .runs)"
git -C "$repo" worktree remove --force "$work/app-wt"

# Without run logs, check records or cycle data, sections say nothing and the command still works.
rm -rf "$repo/.git/senior-mode"
jq -c '.data.repository.issues.nodes = [] | .data.repository.pullRequests.nodes = []' "$FIX/history.json" >"$FIX/history.empty"
cp "$FIX/history.json" "$FIX/history.full"
cp "$FIX/history.empty" "$FIX/history.json"
run retro --json || fail "retro without local facts failed: $(cat "$work/err")"
[ "$(json '.runs')" = '{"found":false,"failed":[],"escalated":[]}' ] || fail "absent run logs: $(json .runs)"
[ "$(json '.checkFailures')" = "[]" ] || fail "absent check records: $(json .checkFailures)"
[ "$(json '.cycle')" = '{"measured":0,"medianHours":null,"worst":null}' ] || fail "no cycle data: $(json .cycle)"
run retro || fail "plain retro without local facts failed"
grep -qF "nothing" "$work/out" || fail "empty sections: $(cat "$work/out")"
cp "$FIX/history.full" "$FIX/history.json"

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
}

# Open high or critical alerts are filed when retro runs (#172), once; --json stays pure JSON.
echo '{"project": {"id": "PVT_1", "owner": "acme", "number": 3, "fields": {
  "Status": {"id": "F_S", "options": {"Backlog": "o0"}},
  "Priority": {"id": "F_P", "options": {"P0 now": "p0", "P1 next": "p1"}}, "Size": {"id": "F_Z", "options": {"S": "z1"}},
  "Severity": {"id": "F_V", "options": {"critical": "v1", "high": "v2", "moderate": "v3", "low": "v4"}}}}}' >"$repo/.claude/senior-mode.json"
fix_alerts
run retro --json || fail "retro with alerts failed: $(cat "$work/err")"
check_alert_issues retro
jq -e .repository "$work/out" >/dev/null || fail "retro --json is not pure JSON with alerts: $(cat "$work/out")"
for src in dependabot secret-scanning; do
  grep -q "$src/alerts?state=open" "$GH_LOG" || fail "retro did not read the open $src alerts"
done
run retro || fail "second retro failed: $(cat "$work/err")"
grep -q 'issue create' "$GH_LOG" && fail "a second pass files again"
[ "$(jq 'length' "$FIX/issues.json")" -eq 2 ] || fail "a second pass changed the issues"
ALERTS_ERR="gh: Secret scanning is disabled on this repository. (HTTP 404)" run retro || fail "an alerts error stopped retro: $(cat "$work/err")"
grep -q 'disabled on this repository' "$work/err" || fail "alerts error not said: $(cat "$work/err")"
grep -q 'Done in the last' "$work/out" || fail "retro gave no report after an alerts error"
echo '[]' >"$FIX/dependabot.json"; echo '[]' >"$FIX/secret-scanning.json"
echo '{"project": {"id": "PVT_1", "owner": "acme", "number": 3}}' >"$repo/.claude/senior-mode.json"

# Errors.
run retro --since soon && fail "accepted --since soon"
grep -q "duration" "$work/err" || fail "bad duration not explained: $(cat "$work/err")"
run retro --nope && fail "accepted --nope"
run retro --since && fail "accepted --since without a value"
GH_FAIL=1 run retro && fail "retro exits zero when GitHub fails"
echo '{"errors": [{"message": "Could not resolve to a Repository"}]}' >"$FIX/history.json"
run retro && fail "retro exits zero on a GraphQL error"
grep -q "Could not resolve" "$work/err" || fail "GraphQL error not shown: $(cat "$work/err")"
echo '{}' >"$repo/.claude/senior-mode.json"
run retro && fail "retro without a Project"
grep -q "setup" "$work/err" || fail "no setup hint without a Project: $(cat "$work/err")"

[ "$failures" -eq 0 ] && echo "retro: all cases pass"
exit "$failures"
