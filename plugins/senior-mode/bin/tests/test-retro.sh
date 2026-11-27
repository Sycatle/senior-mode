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
    if grep -q createProjectV2StatusUpdate <<<"$body"; then
      [ -z "${UPDATE_FAIL:-}" ] || { echo "HTTP 403: forbidden" >&2; exit 1; }
      printf '%s\n' "$body" >>"$FIX/status-updates"
      echo '{"data": {"createProjectV2StatusUpdate": {"statusUpdate": {"id": "SU_1"}}}}'
    elif grep -q ProjectV2IterationField <<<"$body"; then
      cat "$FIX/iteration.json"
    elif grep -q LABELED_EVENT <<<"$body"; then
      cat "$FIX/labeled.json"
    elif grep -q ProjectV2ItemStatusChangedEvent <<<"$body"; then
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
  "api repos/acme/app/issues/"*"/labels "*)
    n=${2#repos/acme/app/issues/}; echo "${n%%/*} $4" >>"$FIX/cause-labels"; echo '[]' ;;
  "pr list"*--state\ merged*) if [ -f "$FIX/merged-prs.json" ]; then respond <"$FIX/merged-prs.json"; else echo '[]' | respond; fi ;;
  "api repos/acme/app/commits/"*"/status"*)
    f=${2#repos/acme/app/commits/}; f=$FIX/status-${f%%/*}.json
    if [ -f "$f" ]; then respond <"$f"; else echo '{"statuses": []}' | respond; fi ;;
  "api repos/acme/app/git/matching-refs/"*) if [ -f "$FIX/lease-refs.json" ]; then respond <"$FIX/lease-refs.json"; else echo '[]' | respond; fi ;;
  "api repos/acme/app/git/commits/"*) f=${2#repos/acme/app/git/commits/}; respond <"$FIX/commit-$f.json" ;;
  "issue list"*"--state all"*) if [ -f "$FIX/issues-all.json" ]; then respond <"$FIX/issues-all.json"; else echo '[]' | respond; fi ;;
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
# #299: the token ledger the session scripts append to. A dated model id prices as its model; an unknown
# model keeps its tokens without a price; a corrupt line and a line outside the period are left out.
{
  usage() { jq -nc --argjson n "$1" --arg r "$2" --arg m "$3" --arg at "$4" --argjson u "$5" '{ticket: $n, role: $r, model: $m, at: $at} + $u'; }
  usage 10 ticket claude-opus-5-5 "$(ago $DAY)" '{"input": 1000, "output": 2000, "cacheRead": 1000000, "cacheWrite5m": 0, "cacheWrite1h": 100000}'
  usage 10 reviewer claude-sonnet-5-5-20261001 "$(ago $DAY)" '{"input": 0, "output": 10000, "cacheRead": 0, "cacheWrite5m": 200000, "cacheWrite1h": 0}'
  echo 'not json {'
  usage 11 ticket claude-mystery-1 "$(ago $DAY)" '{"input": 500, "output": 500, "cacheRead": 0, "cacheWrite5m": 0, "cacheWrite1h": 0}'
  usage null docs claude-sonnet-5-5 "$(ago $DAY)" '{"input": 0, "output": 1000, "cacheRead": 0, "cacheWrite5m": 0, "cacheWrite1h": 0}'
  usage 12 ticket claude-opus-5-5 "$(ago $((20 * DAY)))" '{"input": 1, "output": 1, "cacheRead": 0, "cacheWrite5m": 0, "cacheWrite1h": 0}'
} >"$repo/.git/senior-mode/usage.jsonl"

run() { : >"$GH_LOG"; rm -f "$FIX/cause-labels"; : >"$FIX/board-bodies"; : >"$FIX/history-bodies"; : >"$FIX/status-updates"; (cd "$repo" && "$cli" "$@") >"$work/out" 2>"$work/err"; }
json() { if [ "$1" = -r ]; then jq -r "$2" "$work/out"; else jq -c "$1" "$work/out"; fi; }

run retro --json || fail "retro --json failed: $(cat "$work/err")"
[ "$(grep -c '^api ' "$GH_LOG")" -eq 10 ] || fail "retro makes $(grep -c '^api ' "$GH_LOG") gh calls, wanted 10 (the two alert lists, board, history, the status update, three cause labels, the secret alerts and the lease refs of the run proof)"
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
# #313: per size, median and spread of hours, lines and tokens, the tickets far outside it, a recalibration hint.
[ "$(json '.calibration | map([.size, .count, .hours, .lines, .tokens])')" = \
  '[["M",1,{"median":96,"min":96,"max":96},{"median":900,"min":900,"max":900},null],["S",2,{"median":30,"min":30,"max":30},{"median":25,"min":10,"max":40},null]]' ] ||
  fail "calibration: $(json .calibration)"
[ "$(json '.calibration | map([.size, .outliers, .recalibrate])')" = '[["M",[{"number":6,"title":"Ticket 6","why":["900 lines"]}],null],["S",[],null]]' ] ||
  fail "calibration outliers: $(json .calibration)"
# Three S tickets, two of them over the budget, and one that took far longer than the others: a hint and an outlier.
cal=$(bash -c 'source "$1/lib/retro.sh"; printf %s "$CALIBRATION_JQ"' _ "$(dirname "$cli")")
[ "$(jq -c "$cal | map(select(.size == \"S\") | [.recalibrate, (.outliers | map([.number, .why]))])" <<<'{"usage": {"tickets": [{"ticket": 1, "input": 5, "output": 5, "cacheRead": 0, "cacheWrite5m": 0, "cacheWrite1h": 0}]},
  "done": [{"number": 1, "title": "a", "size": "S", "cycleHours": 1, "lines": 120}, {"number": 2, "title": "b", "size": "S", "cycleHours": 2, "lines": 90},
    {"number": 3, "title": "c", "size": "S", "cycleHours": 30, "lines": 20}]}')" = \
  '[["most S tickets exceed about 50 lines: size such work up, or split it",[[1,["120 lines"]],[2,["90 lines"]],[3,["30h"]]]]]' ] ||
  fail "recalibration: $(jq -c "$cal" <<<'{"usage":{"tickets":[]},"done":[]}')"
[ "$(json '.usage.prices.date')" = "\"$(jq -r .date "$(dirname "$cli")/lib/prices.json")\"" ] || fail "usage prices date: $(json .usage.prices)"
[ "$(json '.usage.tickets | map([.ticket, .usd])')" = '[[null,0.01],[10,1.644],[11,null]]' ] || fail "usage per ticket: $(json .usage.tickets)"
[ "$(json '.usage.tickets[1].roles | map([.role, .usd, .output, .cacheWrite5m, .cacheWrite1h])')" = '[["reviewer",0.6,10000,200000,0],["ticket",1.044,2000,0,100000]]' ] ||
  fail "usage per role: $(json '.usage.tickets[1]')"
[ "$(json '.usage.tickets[2] | [.input, .unpriced]')" = '[500,["claude-mystery-1"]]' ] || fail "unpriced model: $(json '.usage.tickets[2]')"
[ "$(json '.usage.total | [.usd, .unpriced, .input]')" = '[1.654,["claude-mystery-1"],1500]' ] || fail "usage total: $(json .usage.total)"

# --since widens the window for every source.
run retro --json --since 30d || fail "--since failed: $(cat "$work/err")"
[ "$(json '.done | map(.number)')" = "[4,5,6,7]" ] || fail "--since 30d done: $(json .done)"
[ "$(json '.humanPullRequests | map(.number)')" = "[31,41,42]" ] || fail "--since 30d human PRs: $(json .humanPullRequests)"
[ "$(json '.reopened | map(.number)')" = "[8,9]" ] || fail "--since 30d reopened: $(json .reopened)"
[ "$(json '.runs.failed | map(.ticket)')" = "[12,20,30]" ] || fail "--since 30d failed runs: $(json .runs)"
[ "$(json '.runs.escalated | map(.ticket)')" = "[11,12]" ] || fail "--since 30d escalated runs: $(json .runs)"
[ "$(json '.checkFailures | length')" -eq 2 ] || fail "--since 30d check failures: $(json .checkFailures)"

# #177: each pass ends with the health of the Project, a Project status update; the report stays pure JSON.
[ "$(grep -c createProjectV2StatusUpdate "$FIX/status-updates")" -eq 1 ] || fail "retro posted no status update: $(cat "$FIX/status-updates")"
[ "$(jq -r '.variables | [.status, .start, .target // "none"] | join("|")' "$FIX/status-updates")" = "ON_TRACK|$(date -u +%Y-%m-%d)|none" ] ||
  fail "health of a quiet board: $(cat "$FIX/status-updates")"
jq -e '.variables.body | startswith("On track: ") and contains("Board: ") and contains("Needs a human: nothing")' "$FIX/status-updates" >/dev/null ||
  fail "health body: $(cat "$FIX/status-updates")"
grep -q 'Project status update posted: On track' "$work/err" || fail "--json says the update on stderr: $(cat "$work/err")"
jq -e . "$work/out" >/dev/null || fail "retro --json with the update is not pure JSON"
UPDATE_FAIL=1 run retro --json || fail "a status update that fails fails retro: $(cat "$work/err")"
grep -q "could not post the status update" "$work/err" || fail "a failed update is not said: $(cat "$work/err")"
jq -e .done "$work/out" >/dev/null || fail "a failed update loses the report"

# Plain words.
run retro || fail "retro failed: $(cat "$work/err")"
for want in "Done in the last 7d (3)" "#5 Ticket 5" "Cycle time" "median 63h" "worst 96h (#6 Ticket 6)" \
  "Needed a human" "pull request #41 PR 41: needs-human label; changes requested by alice: Split this in two" \
  "Failed or escalated runs" "#20: failed: the session said delivered but there is no open pull request" "#11: escalated: tests do not pass" \
  "Reopened" "#8 Ticket 8" "Check failures" "aaaaaaa: failed: lint" "Estimates against reality" "#6 M: 900 lines" \
  "S: 2 tickets, median hours 30h (30-30), lines 25 (10-40), tokens n/a" "far outside M: #6 Ticket 6: 900 lines" \
  "Token use (estimated at the API prices of" "#10 ticket: input 1k, output 2k, cache read 1M, cache write 100k · \$1.04" \
  "#10 reviewer: input 0, output 10k, cache read 0, cache write 200k · \$0.6" "#11 ticket: input 500, output 500, cache read 0, cache write 0 · no price" \
  "run docs: input 0, output 1k" "total: input 1.5k, output 13.5k, cache read 1M, cache write 300k · \$1.65 (no price for claude-mystery-1)"; do
  grep -qF -- "$want" "$work/out" || fail "plain retro lacks '$want': $(cat "$work/out")"
done
grep -qF "#4 " "$work/out" && fail "a ticket outside the period is listed: $(cat "$work/out")"
grep -qF "#5 S" "$work/out" && fail "a ticket within its size is flagged: $(cat "$work/out")"
[ "$(git -C "$repo" status --porcelain | wc -l)" -eq 0 ] || fail "retro left changes in the tree: $(git -C "$repo" status --porcelain)"

grep -q "Project status update posted: On track" "$work/out" || fail "plain retro does not say the update: $(cat "$work/out")"

# #179: an archived item still counts, with its size.
cp "$FIX/board.json" "$FIX/board.keep"
jq -c '(.data.node.items.nodes[] | select(.content.number == 5)) += {isArchived: true}' "$FIX/board.keep" >"$FIX/board.json"
run retro --json || fail "retro with an archived item failed: $(cat "$work/err")"
[ "$(json '.done | map(.number)')" = "[5,6,7]" ] || fail "an archived item is not counted: $(json .done)"
[ "$(json '.done[0].size')" = '"S"' ] || fail "an archived item lost its size: $(json '.done[0]')"
cp "$FIX/board.keep" "$FIX/board.json"

# #180: --iteration reports one cycle, the current one or a named one, instead of a --since period.
iter_day() { date -u -d "@$(($(date +%s) + $1 * DAY))" +%Y-%m-%d; }
jq -nc --arg a "$(iter_day -30)" --arg b "$(iter_day -2)" '{data: {node: {field: {id: "IT", configuration: {duration: 14,
  completedIterations: [{id: "i1", title: "Iteration 1", startDate: $a, duration: 14}],
  iterations: [{id: "i2", title: "Iteration 2", startDate: $b, duration: 14}]}}}}}' >"$FIX/iteration.json"
run retro --json --iteration || fail "retro --iteration failed: $(cat "$work/err")"
[ "$(json '.iteration')" = '"Iteration 2"' ] || fail "current iteration: $(json .iteration)"
[ "$(json '.since[:10]')" = "\"$(iter_day -2)\"" ] || fail "iteration start: $(json .since)"
[ "$(json '.until[:10]')" = "\"$(iter_day 12)\"" ] || fail "iteration end: $(json .until)"
[ "$(jq -r '.variables.since[:10]' "$FIX/history-bodies")" = "$(iter_day -2)" ] || fail "history not read from the iteration start"
[ "$(json '.done | map(.number)')" = "[5,6,7]" ] || fail "iteration done: $(json .done)"
run retro --json --iteration "Iteration 1" || fail "retro --iteration <name> failed: $(cat "$work/err")"
[ "$(json '.iteration')" = '"Iteration 1"' ] || fail "named iteration: $(json .iteration)"
[ "$(json '.done | map(.number)')" = "[4]" ] || fail "an earlier cycle holds its own tickets only: $(json .done)"
run retro --iteration || fail "plain retro --iteration failed"
grep -q "Done in iteration Iteration 2 ($(iter_day -2) to $(iter_day 11)) (3)" "$work/out" || fail "iteration heading: $(cat "$work/out")"
run retro --iteration "Iteration 9" && fail "an unknown iteration is accepted"
grep -q "no iteration Iteration 9" "$work/err" || fail "unknown iteration not explained: $(cat "$work/err")"
run retro --iteration --since 7d && fail "--iteration with --since is accepted"
echo '{"data": {"node": {"field": null}}}' >"$FIX/iteration.json"
run retro --iteration && fail "--iteration on a board with no Iteration field"
grep -q "no iteration" "$work/err" || fail "no field not explained: $(cat "$work/err")"

# #177: off track and at risk, with the rule in the body and the target date of the milestone.
jq -nc '{data: {repository: {i8: {timelineItems: {nodes: [{createdAt: "2020-01-01T00:00:00Z", label: {name: "needs-human"}}]}}}}}' >"$FIX/labeled.json"
jq -c --arg due "$(ago $((3 * DAY)))" '(.data.node.items.nodes[] | select(.content.number == 8) | .content) += {milestone: {title: "v1", dueOn: $due}}' \
  "$FIX/board.keep" >"$FIX/board.json"
run retro --json || fail "retro with a late milestone failed: $(cat "$work/err")"
[ "$(jq -r '.variables | [.status, .target] | join("|")' "$FIX/status-updates")" = "OFF_TRACK|$(ago $((3 * DAY)) | cut -c1-10)" ] ||
  fail "past due milestone: $(cat "$FIX/status-updates")"
jq -e '.variables.body | startswith("Off track: milestone v1 was due ") and contains("1 open issue")' "$FIX/status-updates" >/dev/null || fail "off track rule: $(cat "$FIX/status-updates")"
jq -c '(.data.node.items.nodes[] | select(.content.number == 8) | .content.labels.nodes) += [{name: "needs-human"}]' "$FIX/board.keep" >"$FIX/board.json"
run retro --json || fail "retro with a stuck ticket failed: $(cat "$work/err")"
[ "$(jq -r '.variables.status' "$FIX/status-updates")" = AT_RISK ] || fail "needs-human for long: $(cat "$FIX/status-updates")"
jq -e '.variables.body | startswith("At risk: #8 has needed a human for ") and contains("Needs a human: #8 Ticket 8")' "$FIX/status-updates" >/dev/null ||
  fail "at risk rule: $(cat "$FIX/status-updates")"
jq -nc --arg at "$(ago $((2 * HOUR)))" '{data: {repository: {i8: {timelineItems: {nodes: [{createdAt: "2020-01-01T00:00:00Z", label: {name: "needs-human"}},
  {createdAt: $at, label: {name: "needs-human"}}]}}}}}' >"$FIX/labeled.json"
run retro --json || fail "retro with a fresh needs-human failed"
[ "$(jq -r '.variables.status' "$FIX/status-updates")" = ON_TRACK ] || fail "the last labeled event decides: $(cat "$FIX/status-updates")"
cp "$FIX/board.keep" "$FIX/board.json"

# Repository hygiene (#226): reported, never acted on.
cp "$FIX/board.json" "$FIX/board.keep"
jq -c --arg old "$(ago $((20 * DAY)))" '.data.repository.defaultBranchRef = {name: "main"}
  | (.data.repository.pullRequests.nodes[] | select(.number == 31)) += {author: {login: "alice"}}
  | .data.repository.pullRequests.nodes += [{number: 50, title: "Old work", headRefName: "feat/50-old", baseRefName: "main", isDraft: false,
    isCrossRepository: false, author: {login: "alice"}, authorAssociation: "MEMBER", labels: {nodes: []},
    commits: {nodes: []}, updatedAt: $old, body: "Supersedes #31"}]
  | .data.repository.branches = {pageInfo: {hasNextPage: false}, nodes: [{name: "main", associatedPullRequests: {totalCount: 0}},
    {name: "chore/60-lost", associatedPullRequests: {totalCount: 0}, target: {oid: "x", committedDate: $old}}, {name: "feat/50-old", associatedPullRequests: {totalCount: 1}}]}' \
  "$FIX/board.keep" >"$FIX/board.json"
run retro --json || fail "retro --json with hygiene failed: $(cat "$work/err")"
[ "$(json '.hygiene.stale | map(.number)')" = "[50]" ] || fail "retro stale: $(json .hygiene)"
[ "$(json '.hygiene.branches | map(.name)')" = '["chore/60-lost"]' ] || fail "retro branches: $(json .hygiene)"
[ "$(json '.hygiene.superseded | map([.number, .by])')" = "[[31,50]]" ] || fail "retro superseded: $(json .hygiene)"
run retro || fail "retro with hygiene failed: $(cat "$work/err")"
for want in "Repository hygiene" "pull request #50 Old work: no activity for 20 days" "branch chore/60-lost: no pull request" \
  "pull request #31 Ticket 8 slice: superseded by #50, still open"; do
  grep -qF -- "$want" "$work/out" || fail "retro hygiene lacks '$want': $(cat "$work/out")"
done
grep -qE 'pr close|issue comment|DELETE|item-edit' "$GH_LOG" && fail "retro changed something on GitHub: $(cat "$GH_LOG")"
cp "$FIX/board.keep" "$FIX/board.json"

# #364: each ticket that needed a second review round, an escalation, a stuck stop or a revert gets one cause label,
# with its evidence quoted; a cause seen retro.repeat times on the same paths opens one improvement ticket, once.
run retro --json || fail "retro --json failed: $(cat "$work/err")"
[ "$(json '.failures | map([.number, .cause, (.signals | join("+"))] | join("|"))')" = '["8|fuzzy-criterion|revert","11|weak-model|escalated","20|weak-model|stuck"]' ] ||
  fail "failure causes: $(json '.failures')"
[ "$(json '.failures[] | select(.number == 11) | .evidence')" = '["escalated to a stronger model: \"tests do not pass\""]' ] || fail "evidence of #11: $(json '.failures')"
[ "$(sort "$FIX/cause-labels" | tr '\n' ',')" = '11 labels[]=cause:weak-model,20 labels[]=cause:weak-model,8 labels[]=cause:fuzzy-criterion,' ] ||
  fail "labels written: $(cat "$FIX/cause-labels")"
[ "$(json '.learning.labelled')" = "[8,11,20]" ] || fail "labelled now: $(json .learning)"
[ "$(json '.learning.improvements')" = "[]" ] || fail "an improvement ticket without a repeat: $(json .learning)"
run retro || fail "plain retro failed: $(cat "$work/err")"
for want in "Failure causes (3)" "#8 Ticket 8: cause:fuzzy-criterion (revert)" "    reopened at " "#11: cause:weak-model (escalated)" \
  '    escalated to a stronger model: "tests do not pass"' "#20: cause:weak-model (stuck)"; do
  grep -qF -- "$want" "$work/out" || fail "plain retro lacks '$want': $(cat "$work/out")"
done
# A second review round, the evidence read for the cause; a label a human put on a ticket stays.
cp "$FIX/history.json" "$FIX/history.keep"
cp "$FIX/board.json" "$FIX/board.keep"
jq -c --arg m "$(ago $DAY)" '.data.repository.pullRequests.nodes += [{number: 44, title: "PR 44", headRefName: "feat/9-slice", additions: 5, deletions: 5, mergedAt: $m,
  labels: {nodes: []}, reviews: {nodes: [{state: "CHANGES_REQUESTED", bodyText: "The criterion is unclear:\nwhat is a valid user?", author: {login: "alice"}}, {state: "APPROVED", bodyText: "", author: {login: "alice"}}]}},
  {number: 45, title: "PR 45", headRefName: "feat/10-slice", additions: 5, deletions: 5, mergedAt: $m,
  labels: {nodes: []}, reviews: {nodes: [{state: "CHANGES_REQUESTED", bodyText: "no", author: {login: "alice"}}]}}]' "$FIX/history.keep" >"$FIX/history.json"
jq -c '(.data.node.items.nodes[] | select(.content.number == 8) | .content.labels.nodes) += [{name: "cause:tool"}]' "$FIX/board.keep" >"$FIX/board.json"
run retro --json || fail "retro with a review round failed: $(cat "$work/err")"
[ "$(json '.failures[] | select(.number == 9) | [.cause, .signals[0], .evidence[0]] | join("|")')" = '"fuzzy-criterion|second-review|pull request #44 needed a second review round after changes requested by alice: \"The criterion is unclear: what is a valid user?\""' ] ||
  fail "second review round: $(json '.failures')"
json '.failures[].number' | grep -qx 10 && fail "one changes-requested review with no later round counted: $(json '.failures')"
[ "$(json '.failures[] | select(.number == 8) | [.cause, .labelled] | map(tostring) | join("|")')" = '"tool|true"' ] || fail "an existing cause label is not kept: $(json '.failures')"
grep -q '^8 ' "$FIX/cause-labels" && fail "a second cause label was written to #8: $(cat "$FIX/cause-labels")"
grep -qx '9 labels\[\]=cause:fuzzy-criterion' "$FIX/cause-labels" || fail "#9 not labelled: $(cat "$FIX/cause-labels")"
# Three tickets on the same paths with the same cause: one improvement ticket aimed at it, linking them, filed once
# (they share two globs, and the one ticket is for the first, not one per glob).
echo '{"project": {"id": "PVT_1", "owner": "acme", "number": 3, "fields": {
  "Status": {"id": "F_S", "options": {"Backlog": "o0"}}, "Priority": {"id": "F_P", "options": {"P0 now": "p0", "P1 next": "p1"}},
  "Size": {"id": "F_Z", "options": {"S": "z1"}}}}}' >"$repo/.claude/senior-mode.json"
echo '[]' >"$FIX/issues.json"
jq -c '(.data.repository.issues.nodes[] | select(.number == 5 or .number == 6) | .timelineItems.nodes) += [{__typename: "ReopenedEvent", createdAt: "'"$(ago $HOUR)"'"}]' \
  "$FIX/history.keep" >"$FIX/history.json"
jq -c '.data.node.items.nodes |= map(if (.content.number | IN(5, 6, 8)) then .fieldValues.nodes += [{text: "src/billing/**, docs/**", field: {name: "Paths"}}] else . end)' "$FIX/board.keep" >"$FIX/board.json"
run retro --json || fail "retro with a repeated cause failed: $(cat "$work/err")"
[ "$(jq 'length' "$FIX/issues.json")" -eq 1 ] || fail "improvement tickets filed: $(jq -c 'map(.title)' "$FIX/issues.json")"
[ "$(jq -r '.[0].title' "$FIX/issues.json")" = 'chore(retro): fix repeated cause:fuzzy-criterion on docs/**' ] || fail "improvement title: $(jq -c 'map(.title)' "$FIX/issues.json")"
jq -r '.[0].body' "$FIX/issues.json" >"$work/body"
for want in "#5, #6, #8" "- #5 Ticket 5: reopened at " "stricter" "- Given a new ticket on \`docs/**\`" "retro-cause: fuzzy-criterion docs/**"; do
  grep -qF -- "$want" "$work/body" || fail "improvement body lacks '$want': $(cat "$work/body")"
done
[ "$(json '.learning.improvements | map([.cause, .area, .created, (.tickets | join(","))] | join("|"))')" = '["fuzzy-criterion|docs/**|true|5,6,8"]' ] ||
  fail "improvements: $(json .learning)"
grep -q 'cause:tool' "$FIX/issues.json" && fail "the corrected #8 counted for its old cause"
grep -qE -- '--label type:task' "$GH_LOG" || fail "improvement ticket is no task: $(grep 'issue create' "$GH_LOG")"
# Run again: the improvement ticket is open, no second one, and the report says so.
run retro || fail "second retro failed: $(cat "$work/err")"
[ "$(jq 'length' "$FIX/issues.json")" -eq 1 ] || fail "a second improvement ticket was filed: $(jq -c 'map(.title)' "$FIX/issues.json")"
grep -qF 'improvement: #42 already open for cause:fuzzy-criterion on docs/** (#5, #6, #8)' "$work/out" || fail "already-open improvement not reported: $(cat "$work/out")"
# retro.repeat: 4 asks for more; 2 makes two tickets enough, 1 does too.
jq -c '. + {retro: {repeat: 4}}' "$repo/.claude/senior-mode.json" >"$work/cfg" && cp "$work/cfg" "$repo/.claude/senior-mode.json"
echo '[]' >"$FIX/issues.json"
run retro --json || fail "retro with retro.repeat 4 failed: $(cat "$work/err")"
[ "$(jq 'length' "$FIX/issues.json")" -eq 0 ] || fail "retro.repeat 4 ignored: $(jq -c 'map(.title)' "$FIX/issues.json")"
jq -c '.retro.repeat = 0' "$repo/.claude/senior-mode.json" >"$work/cfg" && cp "$work/cfg" "$repo/.claude/senior-mode.json"
run retro --json && fail "retro.repeat 0 accepted"
jq -c 'del(.retro)' "$repo/.claude/senior-mode.json" >"$work/cfg" && cp "$work/cfg" "$repo/.claude/senior-mode.json"
echo '{"project": {"id": "PVT_1", "owner": "acme", "number": 3}}' >"$repo/.claude/senior-mode.json"
cp "$FIX/history.keep" "$FIX/history.json"
cp "$FIX/board.keep" "$FIX/board.json"

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

# #423: the run proof. A fixture snapshot file, a stub of the merged pull requests with their statuses, the secret scanning alerts,
# the lease histories and the issues of the period.
T=$(date +%s)
D0=$((T / 86400 * 86400))
mkdir -p "$repo/.git/senior-mode/serve"
snap() { # at running free runnable train ci drift held started
  jq -nc --argjson at "$1" --argjson r "$2" --argjson f "$3" --argjson q "$4" --argjson t "$5" --arg ci "$6" --argjson d "$7" --argjson h "$8" --argjson s "$9" \
    '{at: $at, running: $r, free: $f, runnable: $q, train: $t, band: null, leases: 0, mainCi: $ci, drift: $d, held: $h, started: $s}'; }
S1=$((D0 - 3 * DAY)); S2=$((D0 - DAY + 3 * HOUR))
{
  snap $((D0 - 20 * DAY)) 9 0 9 null failure 9 null $((D0 - 20 * DAY))
  snap $((D0 - 2 * DAY + HOUR)) 2 1 0 null success 1 null $S1
  snap $((D0 - 2 * DAY + 2 * HOUR)) 3 0 4 '{"id":"t1","phase":"checking","entries":3,"evicted":0}' success 0 null $S1
  echo 'not a snapshot {'
  snap $((D0 - DAY + HOUR)) 1 2 0 '{"id":"t1","phase":"merging","entries":3,"evicted":1}' failure 2 '"main-red"' $S1
  snap $((D0 - DAY + 5 * HOUR)) 2 1 2 '{"id":"t2","phase":"merging","entries":1,"evicted":0}' success 1 null $S2
} >"$repo/.git/senior-mode/serve/snapshots.jsonl"
jq -nc --arg a "$(ago $DAY)" --arg b "$(ago $((2 * DAY)))" --arg c "$(ago $((20 * DAY)))" '[
  {number: 40, title: "PR 40", headRefOid: "h400000000", mergedAt: $a, mergedBy: {login: "daemon"}},
  {number: 41, title: "PR 41", headRefOid: "h410000000", mergedAt: $b, mergedBy: {login: "owner"}},
  {number: 42, title: "PR 42", headRefOid: "h420000000", mergedAt: $c, mergedBy: {login: "owner"}}]' >"$FIX/merged-prs.json"
st() { jq -nc --arg c "$1" --arg s "$2" --arg by "$3" '{context: $c, state: $s, description: "d", creator: {login: $by}}'; }
jq -nc --argjson a "$(st senior-mode/ci success daemon)" --argjson b "$(st senior-mode/review success reviewer-bot)" --argjson c "$(st senior-mode/security success daemon)" \
  '{statuses: [$a, $b, $c]}' >"$FIX/status-h400000000.json"
jq -nc --argjson a "$(st senior-mode/ci success daemon)" --argjson b "$(st senior-mode/review failure alice)" \
  '{statuses: [$a, $b]}' >"$FIX/status-h410000000.json"
jq -nc --arg a "$(ago $((2 * DAY)))" --arg b "$(ago $((20 * DAY)))" '[
  {number: 3, state: "resolved", secret_type: "github_personal_access_token", created_at: $a, secret: "SUPERSECRETVALUE"},
  {number: 2, state: "open", secret_type: "slack_api_token", created_at: $b, secret: "SUPERSECRETVALUE"}]' >"$FIX/secret-scanning.json"
echo '[]' >"$FIX/dependabot.json"
lcommit() { # sha worker reason at expires parent
  jq -nc --arg m "$(jq -nc --arg w "$2" --arg r "$3" --argjson at "$4" --argjson e "$5" '{worker: $w, expires: $e, renewed: $at, reason: $r}')" --arg p "$6" \
    '{message: $m, parents: (if $p == "" then [] else [{sha: $p}] end)}' >"$FIX/commit-$1.json"; }
TL=$((T - 2 * DAY))
lcommit c51 w1 claim "$TL" $((TL + 600)) ""
lcommit c52 w2 takeover $((TL + 700)) $((TL + 1300)) c51
lcommit c61 w1 claim $((TL + 5000)) $((TL + 5600)) ""
lcommit c62 w2 takeover $((TL + 5100)) $((TL + 5700)) c61
echo '[{"ref": "refs/senior-mode/leases/ticket-5", "object": {"sha": "c52"}}, {"ref": "refs/senior-mode/leases/ticket-6", "object": {"sha": "c62"}}]' >"$FIX/lease-refs.json"
jq -nc --arg at "$(ago 600)" '[
  {number: 60, title: "incident: serve held its launches on a red main", body: "", createdAt: $at},
  {number: 61, title: "serve restarted after the reboot", body: "", createdAt: $at},
  {number: 62, title: "worker w1 died", body: "The ticket #5 was taken over.", createdAt: $at},
  {number: 63, title: "decision for the pull request", body: "#31 waits", createdAt: $at}]' >"$FIX/issues-all.json"

run retro --json || fail "retro with a run proof failed: $(cat "$work/err")"
[ "$(json '.proof.snapshots | [.found, .count, .meanParallel, .starvationMinutes, .mainRedMinutes, .trains, .ticketsPerTrain, .evictions] | map(tostring) | join("|")')" = \
  '"true|4|2|120|60|2|2|1"' ] || fail "snapshot metrics: $(json '.proof.snapshots')"
[ "$(json '.proof.drift | map([.day, .drift, .snapshots])')" = "[[\"$(date -u -d "@$((D0 - 2 * DAY))" +%F)\",0,2],[\"$(date -u -d "@$((D0 - DAY))" +%F)\",1,2]]" ] ||
  fail "drift per day: $(json .proof.drift)"
[ "$(json '.proof.merges | [.read, .count, .open]')" = '[true,2,1]' ] || fail "merge gate: $(json .proof.merges)"
[ "$(json '.proof.merges.pullRequests | map([.number, .reviewBy, .mergedBy, .bypass, .gaps])')" = \
  '[[40,"reviewer-bot","daemon",false,[]],[41,"alice","owner",true,["senior-mode/review failure","senior-mode/security missing"]]]' ] ||
  fail "merge gate rows: $(json '.proof.merges.pullRequests')"
[ "$(json '.proof.secrets | [.read, (.new | map([.number, .state]))]')" = '[true,[[3,"resolved"]]]' ] || fail "new secret alerts: $(json .proof.secrets)"
grep -q SUPERSECRETVALUE "$work/out" && fail "the secret value reached the retro"
[ "$(json '.proof.metrics | [.takeovers, .duplicateWork, .restarts, .evictions]')" = '[2,1,1,1]' ] || fail "lease and restart metrics: $(json .proof.metrics)"
[ "$(json '.proof.metrics.throughputPerDay')" = "0.4" ] || fail "throughput: $(json .proof.metrics)"
[ "$(json '.proof.incidents | [.read, .count, (.uncovered | map(.kind + (.ref // 0 | tostring)))]')" = '[true,7,["eviction0","takeover6","needs-human41"]]' ] ||
  fail "incidents: $(json .proof.incidents)"
run retro || fail "plain retro with a run proof failed: $(cat "$work/err")"
for want in "Run proof (7 days)" "snapshots: 4, one an hour" "#41 h410000: review set by alice, merged by owner, GATE OPEN: senior-mode/review failure; senior-mode/security missing" \
  "#40 h400000: review set by reviewer-bot, merged by daemon, ci, review and security success" "new secret scanning alerts: 1" "drift per day" \
  "incidents without an issue: 3 of 7" "starvation minutes (a free slot, no runnable ticket): 120" "main red minutes: 60" "takeovers: 2, duplicate work: 1, restarts: 1"; do
  grep -qF -- "$want" "$work/out" || fail "plain retro lacks '$want': $(sed -n '/^Run proof/,$p' "$work/out")"
done
# With no snapshot file the section says so and gives no value; what GitHub holds is still audited.
mv "$repo/.git/senior-mode/serve/snapshots.jsonl" "$work/snapshots.jsonl"
run retro --json || fail "retro without snapshots failed: $(cat "$work/err")"
[ "$(json '.proof.snapshots')" = '{"found":false,"count":0}' ] || fail "snapshots without a file: $(json .proof.snapshots)"
[ "$(json '.proof.metrics | [.meanParallel, .starvationMinutes, .mainRedMinutes, .trains, .evictions, .restarts, .takeovers]')" = '[null,null,null,null,null,null,2]' ] ||
  fail "metrics invented without snapshots: $(json .proof.metrics)"
[ "$(json '.proof.drift')" = '[]' ] || fail "drift without snapshots: $(json .proof.drift)"
run retro || fail "plain retro without snapshots failed: $(cat "$work/err")"
grep -qF "no snapshot in this period" "$work/out" || fail "no word about the missing snapshots: $(sed -n '/^Run proof/,$p' "$work/out")"
grep -qF "main red minutes: not measured" "$work/out" || fail "a missing metric is not said: $(sed -n '/^Run proof/,$p' "$work/out")"
# What cannot be read is said, never counted as clean.
ALERTS_ERR="gh: not available (HTTP 404)" run retro --json || fail "an alerts error stopped the run proof"
[ "$(json '.proof.secrets')" = '{"read":false,"new":[]}' ] || fail "unreadable alerts: $(json .proof.secrets)"
rm -f "$FIX/merged-prs.json" "$FIX"/status-h*.json "$FIX"/commit-c*.json "$FIX/lease-refs.json" "$FIX/issues-all.json" "$FIX/secret-scanning.json"
rm -rf "$repo/.git/senior-mode/serve"

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

# #340: the notes to merge or delete and the agents' drafts. Facts only: nothing is written in the repository.
mkdir -p "$repo/docs/knowledge" "$repo/src/billing" "$repo/.claude/agent-memory/reviewer" "$repo/.claude/agent-memory/architect"
touch "$repo/src/billing/money.js" "$repo/src/app.js"
knote() { # <slug> <paths-json> <kind> <origin> <verified>
  printf -- '---\npaths: %s\nverified: %s\norigin: "%s"\nkind: %s\n---\n\n# %s\n\nBody.\n' "$2" "$5" "$4" "$3" "$1" >"$repo/docs/knowledge/$1.md"
}
knote rounding '["src/billing/**", "src/app.js"]' pitfall '#41' 2026-10-01
knote rounding-again '["src/app.js", "src/billing/**"]' pitfall '#57, #41' 2026-09-01
knote rounding-howto '["src/app.js", "src/billing/**"]' howto '#60' 2026-11-01
knote lonely '["src/billing/money.js"]' convention 'retro' 2026-11-01
knote moved '["src/old/**"]' pitfall '#70' 2026-11-01
knote moved-too '["src/old/**"]' pitfall '#71' 2026-11-01
knote broken '["src/billing/**"]' nonsense '#72' 2026-11-01
printf -- '---\nkind: pitfall\n---\n' >"$repo/docs/knowledge/no-paths.md"
echo '.claude/agent-memory/' >>"$repo/.git/info/exclude"
git -C "$repo" add -A
git -C "$repo" -c user.name=t -c user.email=t@t commit -q -m "docs: notes"
printf 'A finding.\n' >"$repo/.claude/agent-memory/reviewer/recurring.md"
printf -- '- [Recurring](recurring.md)\n' >"$repo/.claude/agent-memory/reviewer/MEMORY.md"
printf 'A design habit.\n' >"$repo/.claude/agent-memory/architect/habits.md"
git -C "$repo" worktree add -q "$work/wt" -b feat/1-x
mkdir -p "$work/wt/.claude/agent-memory/reviewer"
printf 'Another.\n' >"$work/wt/.claude/agent-memory/reviewer/other.md"
run retro --json || fail "retro with notes failed: $(cat "$work/err")"
[ "$(json .knowledge.notes)" -eq 8 ] || fail "knowledge notes: $(json .knowledge)"
[ "$(json '.knowledge.merges | length')" -eq 1 ] || fail "knowledge merges: $(json .knowledge.merges)"
[ "$(json '.knowledge.merges[0] | [.kind, .notes, .keep, .origin, .verified]')" = \
  '["pitfall",["docs/knowledge/rounding-again.md","docs/knowledge/rounding.md"],"docs/knowledge/rounding-again.md","#41, #57","2026-09-01"]' ] ||
  fail "knowledge merge: $(json '.knowledge.merges[0]')"
[ "$(json '.knowledge.deletes | map(.note)')" = '["docs/knowledge/moved-too.md","docs/knowledge/moved.md"]' ] ||
  fail "knowledge deletes: $(json .knowledge.deletes)"
[ "$(json '.knowledge.drafts | map(.agent) | sort')" = '["architect","reviewer","reviewer"]' ] || fail "knowledge drafts: $(json .knowledge.drafts)"
[ "$(json '.knowledge.drafts[] | select(.file | endswith("recurring.md")) | .index | endswith("reviewer/MEMORY.md")')" = true ] ||
  fail "a draft lacks its MEMORY.md index: $(json .knowledge.drafts)"
[ "$(json '.knowledge.drafts | map(.file | endswith("MEMORY.md")) | any')" = false ] || fail "MEMORY.md is a draft: $(json .knowledge.drafts)"
[ "$(json -r '.knowledge.date')" = "$(date -u +%F)" ] || fail "knowledge date: $(json .knowledge.date)"
run retro || fail "plain retro with notes failed: $(cat "$work/err")"
for want in "Knowledge (8 notes, 3 agent drafts)" "merge: docs/knowledge/rounding-again.md, docs/knowledge/rounding.md" \
  "delete: docs/knowledge/moved.md" "draft: architect:"; do
  grep -qF -- "$want" "$work/out" || fail "plain retro lacks '$want': $(cat "$work/out")"
done
[ -z "$(git -C "$repo" status --porcelain)" ] || fail "retro wrote in the repository: $(git -C "$repo" status --porcelain)"
grep -qE 'pr create|git push' "$GH_LOG" && fail "retro opened a pull request by itself: $(cat "$GH_LOG")"
git -C "$repo" worktree remove --force "$work/wt"
rm -rf "$repo/docs" "$repo/src" "$repo/.claude/agent-memory"
git -C "$repo" reset -q --hard HEAD~1
run retro --json || fail "retro without notes failed: $(cat "$work/err")"
[ "$(json '.knowledge | [.notes, (.merges | length), (.deletes | length), (.drafts | length)]')" = "[0,0,0,0]" ] || fail "knowledge with no notes: $(json .knowledge)"

# #486: the Iteration section. Without a times file it says so; the delegations log stands on its own.
run retro --json || fail "retro without check times failed: $(cat "$work/err")"
[ "$(json '.iterationCost | [.history, (.tickets | length), (.agents | length)]')" = "[false,0,0]" ] || fail "iteration without files: $(json .iterationCost)"
run retro || fail "plain retro without check times failed: $(cat "$work/err")"
grep -qF "no check history yet" "$work/out" || fail "no history line: $(cat "$work/out")"
# Ticket 9: its tier 2 run failed on lint, then on test, then passed. Ticket 10 passed at once, with lint cached.
# A run of another tier and a line out of the period are left out.
{
  ct() { jq -nc --arg ts "$(ago "$1")" --arg b "$2" --arg c "$3" --argjson s "$4" --arg st "$5" '{ts: $ts, branch: $b, check: $c, seconds: $s, status: $st}'; }
  ct $((3 * HOUR)) feat/9-slice lint 10 fail
  ct $((3 * HOUR)) feat/9-slice test 20 ok
  ct $((2 * HOUR)) feat/9-slice lint 12 ok
  ct $((2 * HOUR)) feat/9-slice test 50 fail
  ct $((1 * HOUR)) feat/9-slice lint 11 ok
  ct $((1 * HOUR)) feat/9-slice test 40 ok
  ct $((1 * HOUR)) feat/10-slice lint 0 cached
  ct $((1 * HOUR)) feat/10-slice test 30 ok
  echo 'not json {'
  ct $((20 * DAY)) feat/11-slice test 99 fail
  jq -nc --arg ts "$(ago HOUR)" '{ts: $ts, branch: "feat/12-slice", check: "e2e", seconds: 500, status: "fail", tier: 3}'
} >"$repo/.git/senior-mode/check-times.jsonl"
{
  br() { jq -nc --arg t "$(ago "$1")" --arg s "$2" --arg a "$3" --arg g "$4" '{time: $t, session: $s, agent_type: $a, model: "sonnet", goal: $g}'; }
  br 7200 s1 implementer "Add the retro section"
  br 3600 s1 implementer "Add the retro section"
  br 3000 s1 reviewer "Review the section"
  br 100 s2 implementer "Add the retro section"
} >"$repo/.git/senior-mode/briefs.jsonl"
run retro --json || fail "retro with check times failed: $(cat "$work/err")"
[ "$(json '.iterationCost.history')" = true ] || fail "iteration history: $(json .iterationCost)"
[ "$(json '.iterationCost.tickets | map([.ticket, .roundTrips, .seconds])')" = '[[9,2,143],[10,0,30]]' ] || fail "iteration tickets: $(json .iterationCost.tickets)"
[ "$(json '.iterationCost.tickets[0].failures | map([.check, .count])')" = '[["lint",1],["test",1]]' ] || fail "both failing checks counted: $(json .iterationCost.tickets)"
[ "$(json '.iterationCost.agents | map([.agentType, .delegations, .rework])')" = '[["implementer",3,1],["reviewer",1,0]]' ] || fail "iteration agents: $(json .iterationCost.agents)"
[ "$(json '.iterationCost.costliest | map([.check, .seconds, .failures, .tripShare, .cacheRate, .recommendation])')" = \
  '[["test",140,1,0.5,0,"cache it"],["lint",33,1,0.5,0.25,"narrow its inputs"]]' ] || fail "iteration checks: $(json .iterationCost.costliest)"
run retro || fail "plain retro with check times failed: $(cat "$work/err")"
for want in "#9: 2 round trips (lint x1, test x1), 143s in check" "#10: 0 round trips, 30s in check" \
  "test: 140s over 4 runs, 1 failure, 50% of the round trips, 0 warns, cache 0%: cache it" "implementer: 3 calls, rework 1 of 3"; do
  grep -qF -- "$want" "$work/out" || fail "plain retro lacks '$want': $(cat "$work/out")"
done
rm -f "$repo/.git/senior-mode/check-times.jsonl" "$repo/.git/senior-mode/briefs.jsonl"

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
