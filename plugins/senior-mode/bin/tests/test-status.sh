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
  "pr list --state open"*) cat "$FIX/open-heads"; exit 0 ;;
  "pr list"*) echo '[]'; exit 0 ;;
  "api repos/acme/app/branches?protected"*) exit 0 ;;
  "api repos/acme/app/compare/main...feat/61-wip "*) echo 3; exit 0 ;;
  "api repos/acme/app/compare/"*) echo 0; exit 0 ;;
  "api repos/acme/app/branches --paginate"*) cat "$FIX/remote-branches"; exit 0 ;;
  "api repos/acme/app/branches/"*)
    ref=${2#repos/acme/app/branches/}
    case $ref in
      feat/81-moved) printf 'false\tsha:elsewhere\n' ;;
      chore/90-ruleset) printf 'true\tsha:%s\n' "$ref" ;;
      *) printf 'false\tsha:%s\n' "$ref" ;;
    esac
    exit 0 ;;
esac
[ "$*" = "api graphql --input -" ] || { echo "unexpected: $*" >&2; exit 1; }
body=$(cat)
printf '%s\n' "$body" >>"$FIX/bodies"
if grep -q createProjectV2StatusUpdate <<<"$body"; then
  [ -z "${UPDATE_FAIL:-}" ] || { echo "HTTP 403: forbidden" >&2; exit 1; }
  printf '%s\n' "$body" >>"$FIX/status-updates"
  echo '{"data": {"createProjectV2StatusUpdate": {"statusUpdate": {"id": "SU_1"}}}}'
  exit 0
fi
if grep -q LABELED_EVENT <<<"$body"; then cat "$FIX/labeled.json"; exit 0; fi
[ -z "$(jq -r '.variables.number // empty' <<<"$body")" ] || { cat "$FIX/item-$(jq -r .variables.number <<<"$body").json"; exit 0; }
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

run() { : >"$GH_LOG"; : >"$FIX/bodies"; : >"$FIX/status-updates"; (cd "$repo" && "$cli" "$@") >"$work/out" 2>"$work/err"; }
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

# Batches (#189): Ready S tickets whose Paths overlap are grouped, up to 3 (and limits.prLines / 50, an S being
# ~50 lines); an M or L ticket, a ticket without Paths and an S that overlaps nothing are never batched.
cp "$FIX/page-first.json" "$FIX/page-first.keep"
with_paths() { # <item json> <paths>
  jq -c --arg p "$2" '.fieldValues.nodes += [{text: $p, field: {name: "Paths"}}]' <<<"$1"
}
batch_items=$(jq -sc '.' < <(
  with_paths "$(item 41 Ready "P2 later" S null '[]' '[]')" "src/a/**, docs/x.md"
  with_paths "$(item 42 Ready "P2 later" S null '[]' '[]')" "src/a/x.ts"
  with_paths "$(item 43 Ready "P2 later" M null '[]' '[]')" "src/a/**"
  with_paths "$(item 44 Ready "P2 later" S null '[]' '[]')" "docs/guide/**"
  item 45 Ready "P2 later" S null '[]' '[]'
  with_paths "$(item 46 Ready "P2 later" S null '[]' '[]')" "src/a/y.ts"
  with_paths "$(item 47 Ready "P2 later" S null '[]' '[]')" "src/a/z.ts"
  with_paths "$(item 48 Ready "P2 later" S null '[]' '[]')" "lib/**"
  with_paths "$(item 49 Ready "P2 later" S null '[]' '[]')" "lib/b.ts"
))
page "" "$batch_items" >"$FIX/page-first.json"
run pick --json || fail "pick of batches failed: $(cat "$work/err")"
[ "$(json 'map(.number)')" = "[41,42,43,44,45,46,47,48,49]" ] || fail "batches change the order: $(cat "$work/out")"
[ "$(json 'map(.batch)')" = "[[41,42,46],[41,42,46],null,null,null,[41,42,46],null,[48,49],[48,49]]" ] ||
  fail "batches: $(json 'map({number, batch})')"
[ "$(json '.[0].paths')" = '["src/a/**","docs/x.md"]' ] || fail "paths not listed: $(json '.[0].paths')"
[ "$(json '.[4].paths')" = '[]' ] || fail "a ticket without Paths lists some: $(json '.[4].paths')"
run pick || fail "pick of batches failed: $(cat "$work/err")"
grep -q '^#41 P2 later · S · Ticket 41 \[batch #41 #42 #46\]$' "$work/out" || fail "batch not shown in a line: $(cat "$work/out")"
grep -q '^#43 P2 later · M · Ticket 43$' "$work/out" || fail "an M ticket shown as batched: $(cat "$work/out")"
grep -q '^#45 .*batch' "$work/out" && fail "a ticket without Paths is batched: $(cat "$work/out")"
run pick --max 2 --json || fail "pick --max with batches failed: $(cat "$work/err")"
[ "$(json 'map(.batch)')" = "[[41,42],[41,42]]" ] || fail "--max cuts batches: $(json 'map(.batch)')"
# limits.prLines caps a batch at prLines / 50 tickets: 100 lines, 2 tickets; under 100 lines, none.
cp "$repo/.claude/senior-mode.json" "$work/config.keep"
jq '.limits.prLines = 100' "$work/config.keep" >"$repo/.claude/senior-mode.json"
run pick --json || fail "pick with limits.prLines 100 failed: $(cat "$work/err")"
[ "$(json 'map(.batch)')" = "[[41,42],[41,42],null,null,null,null,null,[48,49],[48,49]]" ] || fail "prLines 100: $(json 'map({number, batch})')"
jq '.limits.prLines = 99' "$work/config.keep" >"$repo/.claude/senior-mode.json"
run pick --json || fail "pick with limits.prLines 99 failed: $(cat "$work/err")"
[ "$(json 'map(.batch) | unique')" = "[null]" ] || fail "prLines 99 still batches: $(json 'map(.batch)')"
cp "$work/config.keep" "$repo/.claude/senior-mode.json"
cp "$FIX/page-first.keep" "$FIX/page-first.json"
run pick --json || fail "pick failed after the batch cases"
[ "$(json 'map(.batch) | unique')" = "[null]" ] || fail "tickets without Paths are batched: $(json 'map(.batch)')"

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
# A wip of 0 or a string is refused (#163), not read as a limit.
for bad in 0 '"two"'; do
  echo '{"project": {"id": "PVT_1", "owner": "acme", "number": 3}, "wip": '"$bad"'}' >"$repo/.claude/senior-mode.json"
  run status --json --since 7d && fail "status accepted wip $bad"
  grep -q 'wip must be a positive whole number' "$work/err" || fail "wip $bad refusal not explained: $(cat "$work/err")"
done
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
grep -q 'pr list' "$GH_LOG" && fail "status without --fix cleaned the repository"
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
grep -qE 'issues/2[15] ' "$GH_LOG" && fail "--fix touched an open ticket: $(cat "$GH_LOG")"
grep -q '^fixed: #24 .*Done' "$work/out" || fail "--fix does not say what it fixed: $(cat "$work/out")"
grep -q '^left: #25 .*human' "$work/out" || fail "--fix does not say why #25 is left: $(cat "$work/out")"
grep -q '^left: #21 .*human' "$work/out" || fail "--fix does not say why #21 is left: $(cat "$work/out")"
# --fix then cleans the repository (#225), after the report: its pull request query is the last call, and --json stays JSON.
[ "$(grep -c '^pr list' "$GH_LOG")" -eq 1 ] || fail "--fix did not call clean once: $(cat "$GH_LOG")"
[ "$(grep -n '^pr list' "$GH_LOG" | cut -d: -f1)" -gt "$(grep -n 'item-edit' "$GH_LOG" | tail -1 | cut -d: -f1)" ] ||
  fail "--fix cleaned before it repaired: $(cat "$GH_LOG")"
run status --fix --json --since 7d || fail "status --fix --json failed: $(cat "$work/err")"
[ "$(json '.fixed | map(.number)')" = "[24,26]" ] || fail "--fix --json fixed: $(cat "$work/out")"
grep -q '^pr list' "$GH_LOG" || fail "--fix --json did not clean"
run status --fix --watch && fail "--fix --watch accepted"
grep -q 'watch' "$work/err" || fail "--fix --watch refusal not explained: $(cat "$work/err")"
# A repair of a closed ticket that fails (#163): said as "not fixed:", and the command fails.
export GH_FAIL_ON="project item-edit"
run status --fix --since 7d && fail "--fix exits zero when the Status could not be set Done"
grep -q '^not fixed: #24 .*Done' "$work/out" || fail "failed Done repair of #24 not said: $(cat "$work/out")"
grep -q '^fixed: #24' "$work/out" && fail "#24 said fixed although the edit failed: $(cat "$work/out")"
unset GH_FAIL_ON
echo '{"project": {"id": "PVT_1", "owner": "acme", "number": 3}}' >"$repo/.claude/senior-mode.json"

# Hygiene (#226): stale pull requests, remote branches with no pull request, pull requests that another
# supersedes, tickets In progress that nothing shows alive. Reported by a plain status; only --fix acts.
enc() { jq -rn --arg n "$1" '$n | split("/") | map(@uri) | join("/")'; }
old30=$(ago $((30 * DAY)))
cp "$FIX/page-first.json" "$FIX/page-first.keep"
# branch <name> <pull requests> <commit age in days> [protected]
branch() {
  jq -nc --arg n "$1" --argjson p "$2" --arg d "$(ago $(($3 * DAY)))" --arg o "sha:$(enc "$1")" --argjson pr "${4:-false}" \
    '{name: $n, associatedPullRequests: {totalCount: $p}, branchProtectionRule: (if $pr then {id: "R1"} else null end), target: {oid: $o, committedDate: $d}}'
}
# pr <number> <head> <base> <author> <association> <draft> <fork> <updated days ago> <body>
pr() {
  jq -nc --argjson n "$1" --arg h "$2" --arg b "$3" --arg a "$4" --arg s "$5" --argjson d "$6" --argjson f "$7" --arg u "$(ago $(($8 * DAY)))" --arg body "$9" \
    '{number: $n, title: "PR \($n)", url: "u\($n)", isDraft: $d, isCrossRepository: $f, headRefName: $h, baseRefName: $b, author: {login: $a},
      authorAssociation: $s, labels: {nodes: []}, commits: {nodes: []}, updatedAt: $u, body: $body}'
}
extra_prs=$(jq -sc '.' < <(
  pr 50 feat/50-old main alice MEMBER false false 20 ""
  pr 51 feat/51-redo main alice MEMBER false false 1 $'Closes #1\nSupersedes #50 and #999'
  pr 53 feat/53-forgotten main alice MEMBER false false 25 ""
  pr 54 feat/54-a main alice MEMBER false false 1 "Supersedes #55"
  pr 55 feat/55-b main alice MEMBER false false 1 "Supersedes #54"
  pr 56 feat/56-fork main mallory NONE false true 1 "Supersedes #57"
  pr 57 feat/57-victim main alice MEMBER false false 1 ""
  pr 58 feat/58-stranger main mallory NONE false false 1 "Supersedes #59"
  pr 59 feat/59-target main alice MEMBER false false 1 ""
  pr 63 feat/63-into-dev dev alice MEMBER false false 1 "see: Supersedes #65"
  pr 65 feat/65-quoted main alice MEMBER false false 1 ""
  pr 66 feat/66-fenced main alice MEMBER false false 1 $'Notes:\n```\nSupersedes #67\n```'
  pr 67 feat/67-example main alice MEMBER false false 1 ""))
extra_branches=$(jq -sc '.' < <(
  branch main 0 1; branch feat/17-thing 1 1; branch feat/50-old 1 1; branch fix/62-merged 2 30; branch feat/63-into-dev 1 1
  branch dev 0 30; branch release/1.0 0 30 true; branch staging 0 30
  branch chore/60-lost 0 30; branch feat/61-wip 0 30; branch "fix/70-a#b" 0 30; branch "fix/71-100%" 0 30
  branch feat/80-fresh 0 1; branch feat/81-moved 0 30; branch chore/90-ruleset 0 30; branch feat/27-pushed 0 2))
jq -c --argjson prs "$extra_prs" --argjson br "$extra_branches" --arg old "$old30" --arg recent "$(ago DAY)" \
  --argjson i27 "$(item 27 "In progress" "P1 next" S null '[]' '[]')" --argjson i28 "$(item 28 "In progress" "P1 next" S null '[]' '[]')" \
  --argjson i35 "$(item 35 "In progress" "P1 next" S null '[]' '[]')" '
  .data.repository.defaultBranchRef = {name: "main"}
  | .data.repository.pullRequests.nodes += $prs
  | .data.repository.branches = {pageInfo: {hasNextPage: false, endCursor: null}, nodes: $br}
  | .data.node.items.nodes |= (map(if .content.number == 21 then .content.updatedAt = $old else . end)
    + [($i27 | .content.updatedAt = $old), ($i28 | .content.updatedAt = $recent),
       ($i35 | .content.updatedAt = $old | .updatedAt = $recent)])' "$FIX/page-first.keep" >"$FIX/page-first.json"
run status --json --since 7d || fail "status --json with hygiene failed: $(cat "$work/err")"
[ "$(calls)" -eq 1 ] || fail "hygiene makes status take $(calls) gh calls, wanted 1"
[ "$(json '.hygiene.stale | map(.number)')" = "[50,53]" ] || fail "stale: $(json .hygiene.stale)"
[ "$(json '.hygiene.stale[0].days')" = 20 ] || fail "stale days: $(json .hygiene.stale)"
want='["staging","chore/60-lost","feat/61-wip","fix/70-a#b","fix/71-100%","feat/80-fresh","feat/81-moved","chore/90-ruleset","feat/27-pushed"]'
[ "$(json '.hygiene.branches | map(.name)')" = "$want" ] || fail "branches (not main, a base of an open pull request, a protected one): $(json '.hygiene.branches | map(.name)')"
[ "$(json '.hygiene.branches | map(select(.ticket) | .name) | length')" = 8 ] || fail "ticket branches: $(json .hygiene.branches)"
# Only a line starting with "Supersedes #m", from an open non-draft pull request of this repository whose author
# wrote #m or may write here; a pull request that supersedes another itself is never closed (two that supersede
# each other: neither). The others are reported, not acted on.
[ "$(json '.hygiene.superseded | map(select(.act) | [.number, .by])')" = "[[50,51]]" ] || fail "superseded to close: $(json .hygiene.superseded)"
[ "$(json '.hygiene.superseded | map(select(.act | not) | .number)')" = "[54,55,57,59]" ] || fail "superseded left: $(json .hygiene.superseded)"
[ "$(json '.hygiene.superseded | map(select(.number == 54 or .number == 57 or .number == 59) | .why)')" = \
  '["they supersede each other","comes from a fork","is by someone who cannot write here"]' ] || fail "superseded why: $(json .hygiene.superseded)"
[ "$(json '.hygiene.superseded | map(select(.number == 65))')" = "[]" ] || fail "a Supersedes inside a line counts: $(json .hygiene.superseded)"
[ "$(json '.hygiene.superseded | map(select(.number == 67))')" = "[]" ] || fail "a Supersedes inside a fenced code block counts: $(json .hygiene.superseded)"
# A ticket is an orphan when it has no worktree, no open pull request, no branch anywhere (local or remote)
# and has not moved for hygiene.days: #27 has a remote branch, #28 moved yesterday, #35 has an old issue but
# was moved to In progress yesterday (a Status change touches the board item, not the issue).
[ "$(json '.hygiene.orphans | map(.number)')" = "[21]" ] || fail "orphans: $(json .hygiene.orphans)"
[ "$(json '.drift | map(.number)')" = "[24,26,25,28,35]" ] || fail "an orphan is also drift: $(json .drift)"
run status --since 7d || fail "status with hygiene failed: $(cat "$work/err")"
n=$(jq -r '.hygiene | (.stale + .branches + .superseded + .orphans) | length' < <(cd "$repo" && "$cli" status --json --since 7d))
for want in "Hygiene ($n)" "pull request #50 PR 50: no activity for 20 days" "pull request #53 PR 53: no activity for 25 days" \
  "branch chore/60-lost: no pull request" "branch fix/70-a#b: no pull request" "branch staging: no pull request" \
  "pull request #50 PR 50: superseded by #51, still open" "pull request #54 PR 54: #55 says it supersedes it, but they supersede each other" \
  "pull request #57 PR 57: #56 says it supersedes it, but comes from a fork" \
  "#21 Ticket 21: In progress with no worktree and no open pull request" \
  "#28 Ticket 28: In progress with no open pull request and no branch"; do
  grep -qF -- "$want" "$work/out" || fail "hygiene section lacks '$want': $(cat "$work/out")"
done
grep -qE 'branch (main|dev|release/1.0|feat/17-thing|feat/50-old|fix/62-merged):' "$work/out" && fail "a branch that is not a leftover is listed: $(cat "$work/out")"
! grep -q "#21 Ticket 21: In progress with no open pull request and no branch" "$work/out" ||
  fail "#21 is reported as drift and as hygiene: $(cat "$work/out")"
grep -qE 'item-edit|pr close|issue comment|DELETE' "$GH_LOG" && fail "plain status changed something on GitHub: $(cat "$GH_LOG")"
# hygiene.days moves the line: 22 days leaves only #53, and the 2 day old branch is old enough for 1 day.
echo '{"project": {"id": "PVT_1", "owner": "acme", "number": 3}, "hygiene": {"days": 22}}' >"$repo/.claude/senior-mode.json"
run status --json --since 7d || fail "status --json with hygiene.days failed: $(cat "$work/err")"
[ "$(json '.hygiene.stale | map(.number)')" = "[53]" ] || fail "hygiene.days 22: $(json .hygiene.stale)"
echo '{"project": {"id": "PVT_1", "owner": "acme", "number": 3}, "hygiene": {"days": "x"}}' >"$repo/.claude/senior-mode.json"
run status --json --since 7d && fail "a bad hygiene.days was accepted"
grep -q 'hygiene.days' "$work/err" || fail "bad hygiene.days not explained: $(cat "$work/err")"

# --fix prints the report first, then acts, and only on what is safe: closes the pull request a trusted one
# supersedes, deletes ticket branches with no pull request, no commit outside main, and an old last commit
# (names are percent-encoded per segment), moves the orphan ticket back to Ready after a fresh look at it.
echo '{"project": {"id": "PVT_1", "owner": "acme", "number": 3, "fields": {"Status": {"id": "F_S",
  "options": {"Backlog": "o0", "Ready": "o1", "In review": "o3", "Done": "o4"}}}}}' >"$repo/.claude/senior-mode.json"
: >"$FIX/open-heads"
jq -r '.data.repository.branches.nodes[].name' "$FIX/page-first.json" >"$FIX/remote-branches"
# live21 <Status> <issue updatedAt> <board item updatedAt>: what a fresh read of #21 answers
live21() {
  jq -nc --arg s "$1" --arg i "$2" --arg b "$3" '{data: {repository: {issue: {state: "OPEN", updatedAt: $i, projectItems: {nodes: [
    {project: {id: "PVT_1"}, updatedAt: $b, fieldValues: {nodes: [{name: $s, field: {name: "Status"}}]}}]}}}}}' >"$FIX/item-21.json"
}
live21 "In progress" "$old30" "$old30"
run status --fix --since 7d || fail "status --fix with hygiene failed: $(cat "$work/err")"
grep -q '^pr close 50 --comment .*#51' "$GH_LOG" || fail "--fix did not close #50 naming #51: $(cat "$GH_LOG")"
[ "$(grep -c '^pr close' "$GH_LOG")" -eq 1 ] || fail "--fix closed more than the superseded pull request: $(grep '^pr close' "$GH_LOG")"
for b in chore/60-lost 'fix/70-a%23b' 'fix/71-100%25'; do
  grep -qxF "api -X DELETE repos/acme/app/git/refs/heads/$b" "$GH_LOG" || fail "--fix did not delete $b: $(grep DELETE "$GH_LOG")"
done
[ "$(grep -c 'DELETE' "$GH_LOG")" -eq 3 ] || fail "--fix deleted another branch (a base, a protected or young one, one with commits): $(grep DELETE "$GH_LOG")"
grep -q 'compare/main...fix/70-a%23b ' "$GH_LOG" || fail "the compare of fix/70-a#b is not encoded: $(grep compare "$GH_LOG")"
{ grep -qE 'issues/21 ' "$GH_LOG" && grep -q 'item-edit.*--single-select-option-id o1' "$GH_LOG"; } || fail "--fix did not move #21 to Ready: $(cat "$GH_LOG")"
[ "$(grep -c 'item-edit.*--single-select-option-id o1' "$GH_LOG")" -eq 1 ] || fail "--fix moved another ticket to Ready: $(cat "$GH_LOG")"
grep -q '^issue comment 21 --body' "$GH_LOG" || fail "--fix did not comment on #21: $(cat "$GH_LOG")"
[ "$(grep -n '^Hygiene' "$work/out" | cut -d: -f1)" -lt "$(grep -n '^fixed: pull request #50' "$work/out" | cut -d: -f1)" ] ||
  fail "--fix acted before the report: $(cat "$work/out")"
for want in "fixed: pull request #50 PR 50: closed, superseded by #51" "fixed: branch chore/60-lost: deleted, no commit outside main" \
  "fixed: branch fix/70-a#b: deleted" "fixed: branch fix/71-100%: deleted" "left: branch feat/61-wip: 3 commits outside main" \
  "left: branch staging: not a ticket branch" "left: branch feat/80-fresh: last commit 1d ago" "left: branch feat/81-moved: moved since the report" \
  "left: branch chore/90-ruleset: protected" "left: branch feat/27-pushed: last commit 2d ago" \
  "fixed: #21 Ticket 21: moved back to Ready" "left: pull request #53 PR 53: stale, a human decides"; do
  grep -qF -- "$want" "$work/out" || fail "--fix output lacks '$want': $(cat "$work/out")"
done
grep -q '^left: #21 ' "$work/out" && fail "#21 is moved and also left to a human: $(cat "$work/out")"
grep -q '^left: #28 .*human' "$work/out" || fail "--fix does not leave the recent #28 to a human: $(cat "$work/out")"
run status --fix --json --since 7d || fail "status --fix --json with hygiene failed: $(cat "$work/err")"
[ "$(json '.hygiene.fixed | map(.kind)')" = '["superseded","branch","branch","branch","orphan"]' ] || fail "--fix --json hygiene fixed: $(json .hygiene.fixed)"
# A fresh look before moving a ticket: the issue moved since the report, or only the board item did (a Status
# change touches the item, not the issue: a ticket just started, with no branch pushed yet), it has a branch
# now, or it left In progress.
notmoved() { grep -q 'item-edit.*--single-select-option-id o1' "$GH_LOG" && fail "--fix moved #21 $1: $(cat "$GH_LOG")"; }
live21 "In progress" "$(ago 3600)" "$old30"
run status --fix --since 7d || fail "status --fix with an orphan whose issue moved failed: $(cat "$work/err")"
notmoved "whose issue was updated since the report"
grep -q '^left: #21 .*changed since the report' "$work/out" || fail "an orphan whose issue moved is not said: $(cat "$work/out")"
live21 "In progress" "$old30" "$(ago 3600)"
run status --fix --since 7d || fail "status --fix with an orphan whose board item moved failed: $(cat "$work/err")"
notmoved "whose Status changed since the report"
grep -q '^left: #21 .*changed since the report' "$work/out" || fail "an orphan whose Status moved is not said: $(cat "$work/out")"
live21 "In progress" "$old30" "$old30"
echo "feat/21-late" >>"$FIX/remote-branches"
run status --fix --since 7d || fail "status --fix with an orphan that got a branch failed: $(cat "$work/err")"
notmoved "that has a branch now"
sed -i '$d' "$FIX/remote-branches"
live21 Ready "$old30" "$old30"
run status --fix --since 7d || fail "status --fix with an orphan no longer In progress failed: $(cat "$work/err")"
notmoved "that is not In progress anymore"
# A repair that fails is said and fails the command.
export GH_FAIL_ON="pr close"
run status --fix --since 7d && fail "--fix exits zero when a repair failed"
grep -q '^not fixed: pull request #50' "$work/out" || fail "failed repair not said: $(cat "$work/out")"
unset GH_FAIL_ON
echo '{"project": {"id": "PVT_1", "owner": "acme", "number": 3}}' >"$repo/.claude/senior-mode.json"

# More than one page of branches (#164): the next page is read, so a branch past the first 100 is judged too, and a
# ticket whose only branch is on it is not an orphan.
i29=$(item 29 "In progress" "P1 next" S null '[]' '[]' | jq -c --arg old "$old30" '.content.updatedAt = $old')
jq -c --argjson i "$i29" '.data.repository.branches.pageInfo = {hasNextPage: true, endCursor: "B1"} | .data.node.items.nodes += [$i]' \
  "$FIX/page-first.json" >"$FIX/page-first.tmp" && mv "$FIX/page-first.tmp" "$FIX/page-first.json"
echo '{"data": {"repository": {"branches": {"pageInfo": {"hasNextPage": false, "endCursor": null}, "nodes": [
  {"name": "chore/70-late", "associatedPullRequests": {"totalCount": 0}}, {"name": "feat/17-late", "associatedPullRequests": {"totalCount": 1}},
  {"name": "feat/29-late", "associatedPullRequests": {"totalCount": 0}}]}}}}' >"$FIX/more-branches.json"
run status --json --since 7d || fail "status --json with two pages of branches failed: $(cat "$work/err")"
[ "$(calls)" -eq 2 ] || fail "two pages of branches took $(calls) calls"
[ "$(json '.hygiene.branches | map(.name) | index("chore/70-late") != null and index("feat/17-late") == null')" = true ] ||
  fail "branch past the first page: $(json '.hygiene.branches | map(.name)')"
[ "$(json '.hygiene.orphans | map(.number)')" = "[21]" ] || fail "a ticket with a branch on page 2 is an orphan: $(json .hygiene.orphans)"
[ "$(json '.drift | map(.number) | index(29)')" = null ] || fail "a ticket with a branch on page 2 is stale: $(json .drift)"
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

# #177: `status` alone never publishes; --publish posts the health of the Project as a status update.
run status || fail "status failed: $(cat "$work/err")"
[ ! -s "$FIX/status-updates" ] || fail "status alone posted a status update: $(cat "$FIX/status-updates")"
run status --json || fail "status --json failed"
[ ! -s "$FIX/status-updates" ] || fail "status --json posted a status update"
jq -nc --arg at "$(ago $((3 * 3600)))" '{data: {repository: {i22: {timelineItems: {nodes: [{createdAt: "2020-01-01T00:00:00Z", label: {name: "needs-human"}},
  {createdAt: $at, label: {name: "needs-human"}}, {createdAt: "2026-01-01T00:00:00Z", label: {name: "blocked"}}]}}}}}' >"$FIX/labeled.json"
run status --publish || fail "status --publish failed: $(cat "$work/err")"
[ "$(grep -c createProjectV2StatusUpdate "$FIX/status-updates")" -eq 1 ] || fail "--publish did not post once: $(cat "$FIX/status-updates")"
[ "$(jq -r '.variables | [.status, .start, .target] | join("|")' "$FIX/status-updates")" = "OFF_TRACK|$(date -u +%Y-%m-%d)|2026-11-01" ] ||
  fail "off track fields: $(cat "$FIX/status-updates")"
jq -e '.variables.body | startswith("Off track: milestone Stage 12 was due 2026-11-01 and has 1 open issue\n")
  and contains("Board: Backlog ") and contains("Needs a human: #22 Ticket 22") and contains("Failing pull requests: #30 ") and contains("Drift: #")' \
  "$FIX/status-updates" >/dev/null || fail "off track body: $(cat "$FIX/status-updates")"
grep -q '^Project status update posted: Off track: milestone Stage 12' "$work/out" || fail "--publish does not say the update: $(cat "$work/out")"
grep -q '^Done in\|^In progress' "$work/out" || fail "--publish drops the report: $(cat "$work/out")"
# The 24 hours of needs-human count from the last `labeled` event of the ticket (3 hours ago here): not at risk for it.
jq -c '(.data.node.items.nodes[] | select(.content.number == 12) | .content.milestone.dueOn) = "2027-02-01T00:00:00Z"' "$FIX/page-first.json" >"$FIX/page-first.late"
cp "$FIX/page-first.json" "$FIX/page-first.keep"
cp "$FIX/page-first.late" "$FIX/page-first.json"
run status --publish --json || fail "status --publish --json failed: $(cat "$work/err")"
[ "$(json '.health | [.status, .label, .targetDate] | join("|")')" = '"AT_RISK|At risk|2026-12-01"' ] || fail "json health: $(json .health)"
json '.health | has("body")' | grep -qx false || fail "the body is repeated in the JSON"
jq -e '.variables.body | startswith("At risk: pull request #30 fails its checks (senior-mode/ci); ") and contains("board drift items (#")' "$FIX/status-updates" >/dev/null ||
  fail "at risk body: $(cat "$FIX/status-updates")"
jq -e '.variables.body | contains("needed a human") | not' "$FIX/status-updates" >/dev/null || fail "a fresh needs-human counted: $(cat "$FIX/status-updates")"
jq -nc '{data: {repository: {i22: {timelineItems: {nodes: [{createdAt: "2020-01-01T00:00:00Z", label: {name: "needs-human"}}]}}}}}' >"$FIX/labeled.json"
run status --publish || fail "status --publish failed: $(cat "$work/err")"
jq -e '.variables.body | startswith("At risk: #22 has needed a human for ")' "$FIX/status-updates" >/dev/null || fail "stuck needs-human not first: $(cat "$FIX/status-updates")"
# Quiet board: On track, with the rule that decided.
quiet=$(jq -sc '.' < <(item 10 Ready "P1 next" S '"2026-12-01T00:00:00Z"' '[]' '[]'; item 17 "In progress" "P1 next" S null '[]' '[]'; item 5 Done "P1 next" S null '[]' '[]' CLOSED))
jq -nc --argjson items "$quiet" '{data: {node: {items: {pageInfo: {hasNextPage: false, endCursor: null}, nodes: $items}},
  repository: {latestRelease: null, pullRequests: {nodes: []}, branches: {nodes: [{name: "feat/17-thing"}]}, closed: {nodes: []}, merged: {nodes: []}}}}' >"$FIX/page-first.json"
run status --publish || fail "status --publish on a quiet board failed: $(cat "$work/err")"
[ "$(jq -r '.variables | [.status, .target] | join("|")' "$FIX/status-updates")" = "ON_TRACK|2026-12-01" ] || fail "on track: $(cat "$FIX/status-updates")"
jq -e '.variables.body | startswith("On track: no milestone past due") and contains("Board: Ready 1 · In progress 1 · Done 1\n") and endswith("Drift: none")' \
  "$FIX/status-updates" >/dev/null || fail "on track body: $(cat "$FIX/status-updates")"
grep -q 'LABELED_EVENT' "$FIX/bodies" && fail "the timeline is read with no needs-human ticket"
# An archived item is not on the board any more: not counted.
jq -c '(.data.node.items.nodes[] | select(.content.number == 5)) += {isArchived: true}' "$FIX/page-first.json" >"$FIX/p" && mv "$FIX/p" "$FIX/page-first.json"
run status --publish || fail "status --publish with an archived item failed"
jq -e '.variables.body | contains("Board: Ready 1 · In progress 1\n")' "$FIX/status-updates" >/dev/null || fail "archived item counted: $(cat "$FIX/status-updates")"
cp "$FIX/page-first.keep" "$FIX/page-first.json"
UPDATE_FAIL=1 run status --publish && fail "a failed update exits zero"
grep -q "could not post the status update" "$work/err" || fail "failed update not said: $(cat "$work/err")"
grep -q '^In progress' "$work/out" || fail "a failed update loses the report"
run status --watch --publish && fail "--watch --publish accepted"

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
