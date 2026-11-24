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

run() { : >"$GH_LOG"; : >"$FIX/board-bodies"; : >"$FIX/history-bodies"; : >"$FIX/status-updates"; (cd "$repo" && "$cli" "$@") >"$work/out" 2>"$work/err"; }
json() { jq -c "$1" "$work/out"; }

run retro --json || fail "retro --json failed: $(cat "$work/err")"
[ "$(grep -c '^api ' "$GH_LOG")" -eq 5 ] || fail "retro makes $(grep -c '^api ' "$GH_LOG") gh calls, wanted 5 (the two alert lists, board, history, the status update)"
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
cal=$(bash -c 'source "$1/lib/status.sh"; printf %s "$CALIBRATION_JQ"' _ "$(dirname "$cli")")
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
