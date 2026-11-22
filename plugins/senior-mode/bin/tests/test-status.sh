#!/usr/bin/env bash
# Tests for `senior-mode pick` and `senior-mode status`. Offline: gh is a stub answering the one
# GraphQL query from fixtures in $FIX (one file per page cursor).
set -u
cli=$(cd "$(dirname "$0")/.." && pwd)/senior-mode
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

mkdir -p "$work/stub" "$work/fix"
cat >"$work/stub/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$GH_LOG"
[ -z "${GH_FAIL:-}" ] || { echo "HTTP 401: bad credentials" >&2; exit 1; }
[ "$*" = "api graphql --input -" ] || { echo "unexpected: $*" >&2; exit 1; }
body=$(cat)
printf '%s\n' "$body" >>"$FIX/bodies"
after=$(jq -r '.variables.after // "first"' <<<"$body")
cat "$FIX/page-$after.json"
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
DAY=86400

# item <number> <status> <priority> <size> <due|null> <labels json> <blockers json> [state]
item() {
  jq -nc --argjson n "$1" --arg s "$2" --arg p "$3" --arg z "$4" --argjson due "$5" --argjson l "$6" \
    --argjson b "$7" --arg st "${8:-OPEN}" '{
    fieldValues: {nodes: ([{}, {name: $s, field: {name: "Status"}}]
      + (if $p == "" then [] else [{name: $p, field: {name: "Priority"}}] end)
      + (if $z == "" then [] else [{name: $z, field: {name: "Size"}}] end))},
    content: {number: $n, title: "Ticket \($n)", url: "https://github.com/acme/app/issues/\($n)", state: $st,
      closedAt: null, labels: {nodes: ($l | map({name: .}))},
      milestone: (if $due == null then null else {title: "Stage \($n)", dueOn: $due} end),
      blockedBy: {nodes: $b}}}'
}
open99='[{"number": 99, "state": "OPEN"}]'
closed98='[{"number": 98, "state": "CLOSED"}]'

items=$(jq -sc '.' < <(
  item 10 Ready "P1 next" S '"2026-12-01T00:00:00Z"' '[]' '[]'
  item 11 Ready "P0 now" M '"2027-01-01T00:00:00Z"' '[]' '[]'
  item 12 Ready "P1 next" M '"2026-11-01T00:00:00Z"' '[]' '[]'
  item 13 Ready "P0 now" L null '[]' '[]'
  item 14 Ready "P0 now" S null '[]' "$open99"
  item 15 Ready "P0 now" S null '["blocked"]' '[]'
  item 16 Ready "P0 now" S null '[]' "$closed98"
  item 17 "In progress" "P1 next" S null '[]' '[]'
  item 18 "In review" "P1 next" S null '[]' '[]'
  item 19 Backlog "P2 later" S null '["needs-info"]' '[]'
  item 20 Backlog "P2 later" S null '[]' "$open99"
  item 21 "In progress" "P1 next" M null '[]' "$open99"
  item 22 "In review" "P1 next" M null '["needs-human"]' '[]'
  item 23 Ready "P0 now" S null '["needs-info"]' '[]'
  item 5 Done "P1 next" S null '[]' '[]' CLOSED
  echo '{"fieldValues": {"nodes": []}, "content": {}}'
))
prs=$(jq -nc '[
  {number: 30, title: "Ticket 18 slice", url: "u30", isDraft: false, headRefName: "feat/18-slice", labels: {nodes: []},
   commits: {nodes: [{commit: {statusCheckRollup: {state: "FAILURE", contexts: {nodes: [
     {__typename: "StatusContext", context: "senior-mode/ci", state: "FAILURE"},
     {__typename: "StatusContext", context: "senior-mode/review", state: "SUCCESS"}]}}}}]}},
  {number: 31, title: "Ticket 22 slice", url: "u31", isDraft: false, headRefName: "fix/22-slice", labels: {nodes: [{name: "needs-human"}]},
   commits: {nodes: [{commit: {statusCheckRollup: {state: "SUCCESS", contexts: {nodes: [
     {__typename: "CheckRun", name: "lint", conclusion: "SUCCESS"}]}}}}]}},
  {number: 32, title: "chore(main): release 0.2.0", url: "u32", isDraft: false, headRefName: "release-please--branches--main",
   labels: {nodes: []}, commits: {nodes: [{commit: {statusCheckRollup: null}}]}}]')
closed=$(jq -nc --arg a "$(ago $DAY)" --arg b "$(ago $((20 * DAY)))" --arg c "$(ago $DAY)" '[
  {number: 5, title: "Ticket 5", closedAt: $a, stateReason: "COMPLETED"},
  {number: 4, title: "Ticket 4", closedAt: $b, stateReason: "COMPLETED"},
  {number: 3, title: "Ticket 3", closedAt: $c, stateReason: "NOT_PLANNED"}]')
merged=$(jq -nc --arg a "$(ago 3600)" --arg b "$(ago $((2 * DAY)))" --arg c "$(ago $((20 * DAY)))" '[
  {number: 40, title: "m1", mergedAt: $a}, {number: 41, title: "m2", mergedAt: $b}, {number: 42, title: "m3", mergedAt: $c}]')

# page <next cursor or ""> <items json> [with repository facts]
page() {
  jq -nc --arg next "$1" --argjson items "$2" --argjson prs "$prs" --argjson closed "$closed" --argjson merged "$merged" \
    --argjson repo "${3:-true}" '{data: ({node: {items: {pageInfo: {hasNextPage: ($next != ""), endCursor: (if $next == "" then null else $next end)},
      nodes: $items}}} + (if $repo then {repository: {latestRelease: {tagName: "v0.1.2", publishedAt: "2026-11-10T09:00:00Z"},
      pullRequests: {nodes: $prs}, closed: {nodes: $closed}, merged: {nodes: $merged}}} else {} end))}'
}
page "" "$items" >"$FIX/page-first.json"

run() { : >"$GH_LOG"; : >"$FIX/bodies"; (cd "$repo" && "$cli" "$@") >"$work/out" 2>"$work/err"; }
calls() { wc -l <"$GH_LOG" | tr -d ' '; }
json() { jq -c "$1" "$work/out"; }

# pick: Priority, then milestone due date, then number; blocked, needs-info and size L are left out.
run pick || fail "pick exited non-zero: $(cat "$work/err")"
want='11
16
12
10'
[ "$(grep -oE '^#[0-9]+' "$work/out" | tr -d '#')" = "$want" ] || fail "pick order: $(cat "$work/out")"
grep -q '^#11 P0 now · M · Ticket 11 (Stage 11)$' "$work/out" || fail "pick line format: $(cat "$work/out")"
[ "$(calls)" -eq 1 ] || fail "pick makes $(calls) gh calls, wanted 1"
[ "$(jq -r '.variables.repo' "$FIX/bodies")" = false ] || fail "pick asks for repository facts it does not use"
[ "$(jq -r '.variables.project' "$FIX/bodies")" = PVT_1 ] || fail "pick does not query the cached project id"

run pick --max 2 || fail "pick --max failed: $(cat "$work/err")"
[ "$(grep -c '^#' "$work/out")" -eq 2 ] || fail "--max 2 prints: $(cat "$work/out")"

run pick --json || fail "pick --json failed: $(cat "$work/err")"
[ "$(json 'map(.number)')" = "[11,16,12,10]" ] || fail "pick --json numbers: $(cat "$work/out")"
[ "$(json '.[0] | [.priority, .size, .milestone, .title, .url] | join("|")')" = '"P0 now|M|Stage 11|Ticket 11|https://github.com/acme/app/issues/11"' ] ||
  fail "pick --json fields: $(json '.[0]')"

jq -c '.data.node.items.nodes |= map(select(.fieldValues.nodes | any(.name == "Ready") | not))' "$FIX/page-first.json" >"$FIX/none.json"
cp "$FIX/page-first.json" "$FIX/page-first.full"
cp "$FIX/none.json" "$FIX/page-first.json"
run pick || fail "pick without Ready tickets failed"
grep -q 'No Ready ticket' "$work/out" || fail "empty pick message: $(cat "$work/out")"
run pick --json || fail "empty pick --json failed"
[ "$(cat "$work/out")" = "[]" ] || fail "empty pick --json: $(cat "$work/out")"
cp "$FIX/page-first.full" "$FIX/page-first.json"

for bad in "--max 0" "--max x" "--max" "--nope"; do
  # shellcheck disable=SC2086 # the words are the arguments
  run pick $bad && fail "pick accepted: $bad"
done

# status --json: everything from one call.
run status --json || fail "status --json failed: $(cat "$work/err")"
[ "$(calls)" -eq 1 ] || fail "status makes $(calls) gh calls, wanted 1"
[ "$(jq -r '.variables.repo' "$FIX/bodies")" = true ] || fail "status does not ask for repository facts"
[ "$(json '.done | map(.number)')" = "[5]" ] || fail "done since the default 7 days: $(json .done)"
[ "$(json '.mergedPullRequests')" = 2 ] || fail "merged count: $(json .mergedPullRequests)"
[ "$(json '.inProgress | map(.number)')" = "[17,21]" ] || fail "in progress: $(json .inProgress)"
[ "$(json '.inReview | map([.number, .pr])')" = "[[18,30],[22,31]]" ] || fail "in review: $(json .inReview)"
[ "$(json '.blocked | map(.number)')" = "[14,15,19,21,23]" ] || fail "blocked: $(json .blocked)"
[ "$(json '.blocked[] | select(.number == 21) | .reasons')" = '["waits for #99"]' ] || fail "blocked reasons: $(json .blocked)"
[ "$(json '.waiting | map([.kind, .number])')" = '[["pull request",30],["pull request",31],["ticket",22]]' ] || fail "waiting: $(json .waiting)"
[ "$(json '.waiting[0].why')" = '"failing: senior-mode/ci"' ] || fail "failing statuses: $(json .waiting)"
[ "$(json '.next | map(.number)')" = "[11,16,12]" ] || fail "next: $(json .next)"
[ "$(json '.release | [.latest.tag, .pr.number] | join("|")')" = '"v0.1.2|32"' ] || fail "release: $(json .release)"

run status --json --since 30d || fail "--since failed: $(cat "$work/err")"
[ "$(json '.done | map(.number)')" = "[5,4]" ] || fail "--since 30d done: $(json .done)"
[ "$(json '.mergedPullRequests')" = 3 ] || fail "--since 30d merged: $(json .mergedPullRequests)"
run status --json --since 2h || fail "--since 2h failed"
[ "$(json '.done | length')" -eq 0 ] && [ "$(json '.mergedPullRequests')" -eq 1 ] || fail "--since 2h: $(cat "$work/out")"

# The plain dashboard.
run status --since 7d || fail "status --since 7d failed: $(cat "$work/err")"
for want in "Done in the last 7d" "#5 Ticket 5" "2 pull requests merged" "In progress" "#17 Ticket 17" "In review" \
  "#18 Ticket 18 (pull request #30)" "Blocked or missing information" "#19 Ticket 19: needs information" \
  "Waiting for a human" "pull request #30 Ticket 18 slice: failing: senior-mode/ci" \
  "pull request #31 Ticket 22 slice: needs a human decision" "Next Ready" "#11 P0 now · M · Ticket 11" \
  "Release" "v0.1.2" "pull request #32"; do
  grep -qF -- "$want" "$work/out" || fail "plain status lacks '$want': $(cat "$work/out")"
done
grep -qF "#13" "$work/out" && fail "an L ticket is listed: $(cat "$work/out")"

# Work in progress against the wip limit (#125): default 1, two tickets In progress.
grep -qF "In progress (2, over the limit of 1)" "$work/out" || fail "wip over the limit not shown: $(cat "$work/out")"
run status --json --since 7d || fail "status --json failed: $(cat "$work/err")"
[ "$(json .wip)" = '{"limit":1,"count":2}' ] || fail "wip in JSON: $(json .wip)"
echo '{"project": {"id": "PVT_1", "owner": "acme", "number": 3}, "wip": 2}' >"$repo/.claude/senior-mode.json"
run status --json --since 7d || fail "status --json with wip 2 failed: $(cat "$work/err")"
[ "$(json .wip)" = '{"limit":2,"count":2}' ] || fail "wip 2 in JSON: $(json .wip)"
run status --since 7d || fail "status with wip 2 failed: $(cat "$work/err")"
grep -qx "In progress (2)" "$work/out" || fail "wip at the limit shown as over: $(cat "$work/out")"
echo '{"project": {"id": "PVT_1", "owner": "acme", "number": 3}}' >"$repo/.claude/senior-mode.json"

# Quiet board: every section says nothing rather than disappearing.
jq -c '.data.node.items.nodes = [] | .data.repository.pullRequests.nodes = [] | .data.repository.closed.nodes = []
  | .data.repository.merged.nodes = [] | .data.repository.latestRelease = null' "$FIX/page-first.json" >"$FIX/quiet.json"
cp "$FIX/page-first.json" "$FIX/page-first.full"
cp "$FIX/quiet.json" "$FIX/page-first.json"
run status || fail "quiet status failed: $(cat "$work/err")"
grep -qF "nothing" "$work/out" || fail "quiet board: $(cat "$work/out")"
grep -q "No release yet" "$work/out" || fail "no release message: $(cat "$work/out")"
cp "$FIX/page-first.full" "$FIX/page-first.json"
rm -rf "$repo/.claude/senior-mode"

# "Since last time": a plain run reads then updates the cache, which git ignores.
run status || fail "status failed: $(cat "$work/err")"
cache="$repo/.claude/senior-mode/status-seen"
[ -f "$cache" ] || fail "no cache after a plain status"
[ -z "$(git -C "$repo" status --porcelain)" ] || fail "the cache dirties the tree: $(git -C "$repo" status --porcelain)"
run status || fail "second status failed"
grep -qF "#5 Ticket 5" "$work/out" && fail "done again after the cache moved on: $(cat "$work/out")"
ago $((2 * DAY)) >"$cache"
run status || fail "status with a cache failed"
grep -qF "#5 Ticket 5" "$work/out" || fail "cache 2 days old: #5 missing: $(cat "$work/out")"
grep -qF "Done since last time" "$work/out" || fail "cache heading: $(cat "$work/out")"
echo 2026-01-01T00:00:00Z >"$cache"
run status --json || fail "json failed"
run status --since 7d || fail "since failed"
[ "$(cat "$cache")" = 2026-01-01T00:00:00Z ] || fail "--json or --since moved the cache: $(cat "$cache")"

# Pages of items are followed; repository facts only come with the first.
rm -f "$FIX"/page-*.json
page C1 "$(jq -c '.[0:4]' <<<"$items")" >"$FIX/page-first.json"
page "" "$(jq -c '.[4:]' <<<"$items")" false >"$FIX/page-C1.json"
run pick --json || fail "paged pick failed: $(cat "$work/err")"
[ "$(calls)" -eq 2 ] || fail "two pages took $(calls) calls"
[ "$(json 'map(.number)')" = "[11,16,12,10]" ] || fail "paged pick: $(cat "$work/out")"
run status --json || fail "paged status failed: $(cat "$work/err")"
[ "$(jq -r '.variables | [.repo, .after] | map(tostring) | join("|")' <(sed -n 2p "$FIX/bodies"))" = "false|C1" ] ||
  fail "second page request: $(sed -n 2p "$FIX/bodies")"
[ "$(json '.inProgress | length')" -eq 2 ] || fail "items of page 2 lost: $(json .inProgress)"

# Errors.
run status --since soon && fail "accepted --since soon"
grep -q "duration" "$work/err" || fail "bad duration not explained: $(cat "$work/err")"
GH_FAIL=1 run status && fail "status exits zero when GitHub fails"
echo '{"errors": [{"message": "Could not resolve to a node"}]}' >"$FIX/page-first.json"
run pick && fail "pick exits zero on a GraphQL error"
grep -q "Could not resolve" "$work/err" || fail "GraphQL error not shown: $(cat "$work/err")"
echo '{}' >"$repo/.claude/senior-mode.json"
run pick && fail "pick without a Project"
grep -q "setup" "$work/err" || fail "no setup hint without a Project: $(cat "$work/err")"
echo '{"project": {"id": "PVT_1", "owner": "acme", "number": 3}}' >"$repo/.claude/senior-mode.json"

# --watch redraws until stopped and does not mix with --json.
page "" "$items" >"$FIX/page-first.json"
: >"$GH_LOG"
(cd "$repo" && timeout 3 "$cli" status --watch 1 >"$work/out" 2>"$work/err") || true
[ "$(calls)" -ge 2 ] || fail "--watch 1 redraws $(calls) times in 3 seconds"
[ "$(grep -c '^In progress' "$work/out")" -ge 2 ] || fail "--watch output: $(cat "$work/out")"
run status --watch --json && fail "--watch --json accepted"
[ "$(git -C "$repo" status --porcelain | wc -l)" -eq 0 ] || fail "watch left changes in the tree"

[ "$failures" -eq 0 ] && echo "status: all cases pass"
exit "$failures"
