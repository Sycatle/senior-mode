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
[ -z "${GH_FAIL_ON:-}" ] || [[ "$*" != "$GH_FAIL_ON"* ]] || { echo "HTTP 403: forbidden" >&2; exit 1; }
case "$*" in
  "project item-add"*) sed -E 's#.*/issues/([0-9]+).*#ITEM_\1#' <<<"$*"; exit 0 ;;
  "project item-edit"*) exit 0 ;;
  "pr close"* | "issue comment"* | "api -X DELETE"*) exit 0 ;;
  "api repos/acme/app/compare/main...chore/60-lost "*) echo 0; exit 0 ;;
  "api repos/acme/app/compare/main...feat/61-wip "*) echo 3; exit 0 ;;
  "api repos/acme/app/compare/main...chore/70-late "*) echo 0; exit 0 ;;
esac
[ "$*" = "api graphql --input -" ] || { echo "unexpected: $*" >&2; exit 1; }
body=$(cat)
printf '%s\n' "$body" >>"$FIX/bodies"
after=$(jq -r '.variables.after // "first"' <<<"$body")
[ "$(jq -r '.variables.branchesAfter // empty' <<<"$body")" != B1 ] || { cat "$FIX/more-branches.json"; exit 0; }
cat "$FIX/page-$after.json"
STUB
chmod +x "$work/stub/gh"
export PATH="$work/stub:$PATH" GH_LOG="$work/gh.log" FIX="$work/fix" SENIOR_MODE_RETRY_DELAY=0 XDG_DATA_HOME="$work/xdg"

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
  item 24 "In review" "P1 next" S null '[]' '[]' CLOSED
  item 25 Done "P1 next" S null '[]' '[]'
  item 26 Backlog "P2 later" S null '[]' '[]' CLOSED
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
      pullRequests: {nodes: $prs}, branches: {nodes: [{name: "main"}, {name: "feat/17-thing"}, {name: "fix/210-other"}]},
      closed: {nodes: $closed}, merged: {nodes: $merged}}} else {} end))}'
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

# A critical ticket leads its priority, ahead of an earlier milestone; Severity is read from the board.
cp "$FIX/page-first.json" "$FIX/page-first.keep"
crit=$(item 30 Ready "P0 now" S '"2028-01-01T00:00:00Z"' '[]' '[]' | jq -c '.fieldValues.nodes += [{name: "critical", field: {name: "Severity"}}]')
jq -c --argjson c "$crit" '.data.node.items.nodes += [$c]' "$FIX/page-first.keep" >"$FIX/page-first.json"
run pick --json || fail "pick with a critical ticket failed: $(cat "$work/err")"
[ "$(json 'map(.number)')" = "[30,11,16,12,10]" ] || fail "critical not first: $(cat "$work/out")"
cp "$FIX/page-first.keep" "$FIX/page-first.json"

for bad in "--max 0" "--max x" "--max" "--nope"; do
  # shellcheck disable=SC2086 # the words are the arguments
  run pick $bad && fail "pick accepted: $bad"
done

# #17 has a worktree in the data dir, #21 none (#224).
wt17=$work/xdg/senior-mode/worktrees/app-0/17
git -C "$repo" worktree add -q -b feat/17-thing "$wt17"


# status --json: everything from one call.
run status --json || fail "status --json failed: $(cat "$work/err")"
[ "$(calls)" -eq 1 ] || fail "status makes $(calls) gh calls, wanted 1"
[ "$(jq -r '.variables.repo' "$FIX/bodies")" = true ] || fail "status does not ask for repository facts"
[ "$(json '.done | map(.number)')" = "[5]" ] || fail "done since the default 7 days: $(json .done)"
[ "$(json '.mergedPullRequests')" = 2 ] || fail "merged count: $(json .mergedPullRequests)"
[ "$(json '.inProgress | map(.number)')" = "[17,21]" ] || fail "in progress: $(json .inProgress)"
[ "$(json '.inProgress | map(.worktree)')" = "[\"$(cd "$wt17" && pwd -P)\",null]" ] ||
  fail "in progress worktrees: $(json '.inProgress')"
# A worktree on a branch `start` never makes (docs/21-notes) is not #21's.
git -C "$repo" worktree add -q -b docs/21-notes "$work/notes"
run status --json || fail "status --json with a docs worktree failed: $(cat "$work/err")"
[ "$(json '.inProgress[1].worktree')" = null ] || fail "docs/21-notes attached to #21: $(json .inProgress)"
git -C "$repo" worktree remove "$work/notes"
git -C "$repo" branch -q -D docs/21-notes
run status --json || fail "status --json failed again: $(cat "$work/err")"
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

grep -qF "#17 Ticket 17 (worktree $(cd "$wt17" && pwd -P))" "$work/out" ||
  fail "plain status does not show the worktree of #17: $(cat "$work/out")"
grep -qx "  #21 Ticket 21" "$work/out" || fail "a ticket without worktree gets a path: $(cat "$work/out")"

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

# The dependency audit (#142): on by default and quiet, shown when `audit: false` turns it off.
run status --json --since 7d || fail "status --json failed: $(cat "$work/err")"
[ "$(json .audit)" = true ] || fail "audit on by default: $(json .audit)"
run status --since 7d || fail "status failed: $(cat "$work/err")"
grep -qi "audit" "$work/out" && fail "status mentions the audit while it is on: $(cat "$work/out")"
echo '{"project": {"id": "PVT_1", "owner": "acme", "number": 3}, "audit": false}' >"$repo/.claude/senior-mode.json"
run status --json --since 7d || fail "status --json with audit false failed: $(cat "$work/err")"
[ "$(json .audit)" = false ] || fail "audit false in JSON: $(json .audit)"
run status --since 7d || fail "status with audit false failed: $(cat "$work/err")"
grep -qF "Dependency audit: off (audit: false)" "$work/out" || fail "audit off not shown: $(cat "$work/out")"
echo '{"project": {"id": "PVT_1", "owner": "acme", "number": 3}}' >"$repo/.claude/senior-mode.json"

# Board drift (#124): closed but not Done (#24, #26), open but Done (#25), In progress or In review with
# no open pull request and no branch (#21; #17 has a branch, #18 and #22 a pull request).
run status --json --since 7d || fail "status --json failed: $(cat "$work/err")"
[ "$(json '.drift | map([.number, .kind])')" = '[[24,"closed"],[26,"closed"],[25,"open-done"],[21,"stale"]]' ] ||
  fail "drift: $(json .drift)"
json 'has("fixed")' | grep -qx false || fail "fixed listed without --fix"
run status --since 7d || fail "status failed: $(cat "$work/err")"
for want in "Board drift (4)" "#24 Ticket 24: closed but In review" "#26 Ticket 26: closed but Backlog" \
  "#25 Ticket 25: open but Done" "#21 Ticket 21: In progress with no open pull request and no branch"; do
  grep -qF -- "$want" "$work/out" || fail "drift section lacks '$want': $(cat "$work/out")"
done
grep -q 'item-edit' "$GH_LOG" && fail "status without --fix changed the board"
# A local branch that was never pushed counts as a branch: #21 is not stale while one exists.
git -C "$repo" branch feat/21-local-only
run status --json --since 7d || fail "status --json with a local branch failed: $(cat "$work/err")"
[ "$(json '.drift | map(.number)')" = '[24,26,25]' ] || fail "a local branch does not count: $(json .drift)"
git -C "$repo" branch -q -D feat/21-local-only
# --fix sets the closed ones Done and leaves the rest, saying why.
cfg_fields='{"project": {"id": "PVT_1", "owner": "acme", "number": 3, "fields": {"Status": {"id": "F_S",
  "options": {"Backlog": "o0", "Ready": "o1", "In review": "o3", "Done": "o4"}}}}}'
echo "$cfg_fields" >"$repo/.claude/senior-mode.json"
run status --fix --since 7d || fail "status --fix failed: $(cat "$work/err")"
[ "$(grep -c 'item-edit.*--single-select-option-id o4' "$GH_LOG")" -eq 2 ] || fail "--fix edits: $(cat "$GH_LOG")"
[ "$(grep -cE 'issues/(24|26) ' "$GH_LOG")" -eq 2 ] || fail "--fix did not set #24 and #26: $(cat "$GH_LOG")"
# #21 is also In progress with no worktree: the hygiene repair moves it to Ready, the drift repair leaves it.
grep -qE 'issues/25 ' "$GH_LOG" && fail "--fix touched an open ticket: $(cat "$GH_LOG")"
[ "$(grep -c 'item-edit.*--single-select-option-id o1' "$GH_LOG")" -eq 1 ] || fail "--fix did not move #21 back to Ready only: $(cat "$GH_LOG")"
grep -q '^fixed: #24 .*Done' "$work/out" || fail "--fix does not say what it fixed: $(cat "$work/out")"
grep -q '^left: #25 .*human' "$work/out" || fail "--fix does not say why #25 is left: $(cat "$work/out")"
grep -q '^left: #21 .*human' "$work/out" || fail "--fix does not say why #21 is left: $(cat "$work/out")"
run status --fix --json --since 7d || fail "status --fix --json failed: $(cat "$work/err")"
[ "$(json '.fixed | map(.number)')" = "[24,26]" ] || fail "--fix --json fixed: $(cat "$work/out")"
run status --fix --watch && fail "--fix --watch accepted"
grep -q 'watch' "$work/err" || fail "--fix --watch refusal not explained: $(cat "$work/err")"
echo '{"project": {"id": "PVT_1", "owner": "acme", "number": 3}}' >"$repo/.claude/senior-mode.json"

# Hygiene (#226): stale pull requests, remote branches with no pull request, a pull request still open
# that another supersedes, tickets In progress with no worktree and no open pull request. Reported by a
# plain status; only --fix acts.
cp "$FIX/page-first.json" "$FIX/page-first.keep"
jq -c --arg old "$(ago $((20 * DAY)))" --arg older "$(ago $((25 * DAY)))" --arg recent "$(ago DAY)" '
  .data.repository.defaultBranchRef = {name: "main"}
  | .data.repository.pullRequests.nodes += [
    {number: 50, title: "Old work", url: "u50", isDraft: false, headRefName: "feat/50-old", labels: {nodes: []}, commits: {nodes: []}, updatedAt: $old, body: ""},
    {number: 51, title: "Old work, redone", url: "u51", isDraft: false, headRefName: "feat/51-redo", labels: {nodes: []}, commits: {nodes: []},
     updatedAt: $recent, body: "Closes #1\nSupersedes #50 and #999"},
    {number: 53, title: "Forgotten", url: "u53", isDraft: false, headRefName: "feat/53-forgotten", labels: {nodes: []}, commits: {nodes: []}, updatedAt: $older, body: null}]
  | .data.repository.branches = {pageInfo: {hasNextPage: false, endCursor: null}, nodes: [
    {name: "main", associatedPullRequests: {totalCount: 0}}, {name: "feat/17-thing", associatedPullRequests: {totalCount: 1}},
    {name: "feat/50-old", associatedPullRequests: {totalCount: 1}}, {name: "chore/60-lost", associatedPullRequests: {totalCount: 0}},
    {name: "feat/61-wip", associatedPullRequests: {totalCount: 0}}, {name: "fix/62-merged", associatedPullRequests: {totalCount: 2}}]}' \
  "$FIX/page-first.keep" >"$FIX/page-first.json"
hyg='{"stale": [50, 53], "branches": ["chore/60-lost", "feat/61-wip"], "superseded": [[50, 51]], "orphans": [21]}'
check_hygiene() {
  [ "$(json '.hygiene.stale | map(.number)')" = "$(jq -c .stale <<<"$hyg")" ] || fail "$1: stale: $(json .hygiene)"
  [ "$(json '.hygiene.stale[0].days')" = 20 ] || fail "$1: stale days: $(json .hygiene.stale)"
  [ "$(json '.hygiene.branches | map(.name)')" = "$(jq -c .branches <<<"$hyg")" ] || fail "$1: branches: $(json .hygiene.branches)"
  [ "$(json '.hygiene.superseded | map([.number, .by])')" = "$(jq -c .superseded <<<"$hyg")" ] || fail "$1: superseded: $(json .hygiene.superseded)"
  [ "$(json '.hygiene.orphans | map(.number)')" = "$(jq -c .orphans <<<"$hyg")" ] || fail "$1: orphans: $(json .hygiene.orphans)"
}
run status --json --since 7d || fail "status --json with hygiene failed: $(cat "$work/err")"
check_hygiene "default days"
[ "$(calls)" -eq 1 ] || fail "hygiene makes status take $(calls) gh calls, wanted 1"
run status --since 7d || fail "status with hygiene failed: $(cat "$work/err")"
for want in "Hygiene (6)" "pull request #50 Old work: no activity for 20 days" "pull request #53 Forgotten: no activity for 25 days" \
  "branch chore/60-lost: no pull request" "branch feat/61-wip: no pull request" \
  "pull request #50 Old work: superseded by #51, still open" "#21 Ticket 21: In progress with no worktree and no open pull request"; do
  grep -qF -- "$want" "$work/out" || fail "hygiene section lacks '$want': $(cat "$work/out")"
done
grep -qE 'branch (main|feat/17-thing|feat/50-old|fix/62-merged):' "$work/out" && fail "a branch with a pull request is listed: $(cat "$work/out")"
grep -qF "#999" "$work/out" && fail "a superseded pull request that is not open is listed: $(cat "$work/out")"
grep -qE 'item-edit|pr close|issue comment|DELETE' "$GH_LOG" && fail "plain status changed something on GitHub: $(cat "$GH_LOG")"
# hygiene.days moves the line: 22 days leaves only #53.
echo '{"project": {"id": "PVT_1", "owner": "acme", "number": 3}, "hygiene": {"days": 22}}' >"$repo/.claude/senior-mode.json"
run status --json --since 7d || fail "status --json with hygiene.days failed: $(cat "$work/err")"
[ "$(json '.hygiene.stale | map(.number)')" = "[53]" ] || fail "hygiene.days 22: $(json .hygiene.stale)"
echo '{"project": {"id": "PVT_1", "owner": "acme", "number": 3}, "hygiene": {"days": "x"}}' >"$repo/.claude/senior-mode.json"
run status --json --since 7d && fail "a bad hygiene.days was accepted"
grep -q 'hygiene.days' "$work/err" || fail "bad hygiene.days not explained: $(cat "$work/err")"

# --fix prints the report first, then acts: closes the superseded pull request with a comment, deletes the
# branch with no commit outside main, moves the orphan ticket back to Ready with a comment; the stale pull
# requests and the branch with commits stay.
echo '{"project": {"id": "PVT_1", "owner": "acme", "number": 3, "fields": {"Status": {"id": "F_S",
  "options": {"Backlog": "o0", "Ready": "o1", "In review": "o3", "Done": "o4"}}}}}' >"$repo/.claude/senior-mode.json"
run status --fix --since 7d || fail "status --fix with hygiene failed: $(cat "$work/err")"
grep -q '^pr close 50 --comment .*#51' "$GH_LOG" || fail "--fix did not close #50 naming #51: $(cat "$GH_LOG")"
[ "$(grep -c '^pr close' "$GH_LOG")" -eq 1 ] || fail "--fix closed more than the superseded pull request: $(grep '^pr close' "$GH_LOG")"
grep -q '^api -X DELETE repos/acme/app/git/refs/heads/chore/60-lost$' "$GH_LOG" || fail "--fix did not delete chore/60-lost: $(cat "$GH_LOG")"
[ "$(grep -c 'DELETE' "$GH_LOG")" -eq 1 ] || fail "--fix deleted another branch: $(grep DELETE "$GH_LOG")"
grep -qE 'issues/21 ' "$GH_LOG" && grep -q 'item-edit.*--single-select-option-id o1' "$GH_LOG" || fail "--fix did not move #21 to Ready: $(cat "$GH_LOG")"
grep -q '^issue comment 21 --body' "$GH_LOG" || fail "--fix did not comment on #21: $(cat "$GH_LOG")"
[ "$(grep -n '^Hygiene' "$work/out" | cut -d: -f1)" -lt "$(grep -n '^fixed: pull request #50' "$work/out" | cut -d: -f1)" ] ||
  fail "--fix acted before the report: $(cat "$work/out")"
for want in "fixed: pull request #50 Old work: closed, superseded by #51" "fixed: branch chore/60-lost: deleted, no commit outside main" \
  "left: branch feat/61-wip: 3 commits outside main" "fixed: #21 Ticket 21: moved back to Ready" \
  "left: pull request #53 Forgotten: stale, a human decides"; do
  grep -qF -- "$want" "$work/out" || fail "--fix output lacks '$want': $(cat "$work/out")"
done
run status --fix --json --since 7d || fail "status --fix --json with hygiene failed: $(cat "$work/err")"
[ "$(json '.hygiene.fixed | map(.kind)')" = '["superseded","branch","orphan"]' ] || fail "--fix --json hygiene fixed: $(json .hygiene)"
# A repair that fails is said and fails the command.
export GH_FAIL_ON="pr close"
run status --fix --since 7d && fail "--fix exits zero when a repair failed"
grep -q '^not fixed: pull request #50' "$work/out" || fail "failed repair not said: $(cat "$work/out")"
unset GH_FAIL_ON
echo '{"project": {"id": "PVT_1", "owner": "acme", "number": 3}}' >"$repo/.claude/senior-mode.json"

# More than one page of branches: the next page is read, so a branch past the first 100 is judged too.
jq -c '.data.repository.branches.pageInfo = {hasNextPage: true, endCursor: "B1"}' "$FIX/page-first.json" >"$FIX/page-first.tmp" && mv "$FIX/page-first.tmp" "$FIX/page-first.json"
echo '{"data": {"repository": {"branches": {"pageInfo": {"hasNextPage": false, "endCursor": null}, "nodes": [
  {"name": "chore/70-late", "associatedPullRequests": {"totalCount": 0}}, {"name": "feat/17-late", "associatedPullRequests": {"totalCount": 1}}]}}}}' >"$FIX/more-branches.json"
run status --json --since 7d || fail "status --json with two pages of branches failed: $(cat "$work/err")"
[ "$(calls)" -eq 2 ] || fail "two pages of branches took $(calls) calls"
[ "$(json '.hygiene.branches | map(.name)')" = '["chore/60-lost","feat/61-wip","chore/70-late"]' ] || fail "branch past the first page: $(json .hygiene.branches)"
cp "$FIX/page-first.keep" "$FIX/page-first.json"

# Quiet board: every section says nothing rather than disappearing.
jq -c '.data.node.items.nodes = [] | .data.repository.pullRequests.nodes = [] | .data.repository.closed.nodes = []
  | .data.repository.merged.nodes = [] | .data.repository.latestRelease = null' "$FIX/page-first.json" >"$FIX/quiet.json"
cp "$FIX/page-first.json" "$FIX/page-first.full"
cp "$FIX/quiet.json" "$FIX/page-first.json"
run status || fail "quiet status failed: $(cat "$work/err")"
grep -qF "nothing" "$work/out" || fail "quiet board: $(cat "$work/out")"
grep -q "No release yet" "$work/out" || fail "no release message: $(cat "$work/out")"
grep -q "Board drift" "$work/out" && fail "drift section on a board without drift: $(cat "$work/out")"
run status --json || fail "quiet status --json failed: $(cat "$work/err")"
[ "$(json .drift)" = "[]" ] || fail "quiet board drift: $(json .drift)"
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
