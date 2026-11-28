#!/usr/bin/env bash
# Tests for the refs of a Project of several repositories (#450, spec 329 §2.1 and §2.2): `owner/name#n` names a ticket, the board
# keeps the items of this repository, `issue create --repo` files in another repository of the Project. Offline: gh is a stub.
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
jqf="" prev=""
for a in "$@"; do [ "$prev" = --jq ] && jqf=$a; prev=$a; done
respond() { if [ -n "$jqf" ]; then jq -r "$jqf"; else cat; fi; }
case "$*" in
  "project item-add"*) echo ITEM; exit 0 ;;
  "project item-edit"*) exit 0 ;;
  "pr list"*) echo '[]'; exit 0 ;;
  "api repos/acme/app/branches"*) exit 0 ;;
  "issue list"*) echo '[]' | respond; exit 0 ;;
  "issue create"*) echo "https://github.com/${3}/issues/5"; exit 0 ;;
  "api -X POST"*) exit 0 ;;
  "api repos/"*"/sub_issues --paginate"* | "api repos/"*"/blocked_by --paginate"*) echo '[]' | respond; exit 0 ;;
  "api repos/"*"/issues/"*) n=${2##*/}; echo "{\"id\": $((n + 1000))}" | respond; exit 0 ;;
esac
[ "$*" = "api graphql --input -" ] || { echo "unexpected: $*" >&2; exit 1; }
body=$(cat)
if grep -q 'repositories(first' <<<"$body"; then cat "$FIX/linked.json"; exit 0; fi
if grep -q 'milestones(first' <<<"$body"; then echo '{"data": {"repository": {"milestones": {"nodes": []}}}}'; exit 0; fi
if grep -q LABELED_EVENT <<<"$body"; then echo '{"data": {"repository": {}}}'; exit 0; fi
cat "$FIX/page.json"
STUB
chmod +x "$work/stub/gh"
export PATH="$work/stub:$PATH" GH_LOG="$work/gh.log" FIX="$work/fix" SENIOR_MODE_RETRY_DELAY=0 XDG_DATA_HOME="$work/xdg"

repo="$work/repo"
git init -q -b main "$repo"
git -C "$repo" remote add origin git@github.com:acme/app.git
mkdir -p "$repo/.claude"
cat >"$repo/.claude/senior-mode.json" <<'JSON'
{"project": {"id": "PVT_1", "owner": "acme", "number": 3, "fields": {
  "Status": {"id": "F_S", "options": {"Backlog": "o1", "Ready": "o2"}},
  "Priority": {"id": "F_P", "options": {"P0 now": "o3", "P1 next": "o4"}},
  "Size": {"id": "F_Z", "options": {"S": "o5", "M": "o6", "L": "o7"}},
  "Paths": {"id": "F_Pa"}}}}
JSON
git -C "$repo" add -A
git -C "$repo" -c user.name=t -c user.email=t@t commit -q -m "chore: config"
printf '## Acceptance criteria\n- Given a, when b, then c.\n' >"$work/body.md"

# item <repository|-> <number> <blockedBy json>: a Ready S ticket of the Project.
item() {
  jq -nc --arg r "$1" --argjson n "$2" --argjson b "$3" '{
    fieldValues: {nodes: [{name: "Ready", field: {name: "Status"}}, {name: "P1 next", field: {name: "Priority"}}, {name: "S", field: {name: "Size"}}]},
    content: ({authorAssociation: "OWNER", number: $n, title: "Ticket \($n)", url: "https://github.com/\($r)/issues/\($n)", state: "OPEN",
      closedAt: null, labels: {nodes: []}, milestone: null, blockedBy: {nodes: $b}}
      + (if $r == "-" then {} else {repository: {nameWithOwner: $r}} end))}'
}
page() { # items...
  jq -sc '{data: {node: {items: {pageInfo: {hasNextPage: false, endCursor: null}, nodes: .}}, repository: {
    latestRelease: null, defaultBranchRef: {name: "main"}, pullRequests: {nodes: []}, branches: {nodes: [{name: "main"}]},
    closed: {nodes: []}, merged: {nodes: []}}}}'
}
run() { : >"$GH_LOG"; (cd "$repo" && "$cli" "$@") >"$work/out" 2>"$work/err"; }
logged() { grep -qF -- "$1" "$GH_LOG"; }

# A: #7 of two repositories. Only a#7 is a ticket of acme/app; #9 waits for the blocker b#7 (a ref); b's items are other repositories.
{ item acme/app 7 '[]'; item acme/other 7 '[]'; item acme/other 8 '[]'
  item acme/app 9 '[{"number": 7, "state": "OPEN", "repository": {"nameWithOwner": "acme/other"}}]'; } | page >"$FIX/page.json"
run pick --json || fail "A: pick failed: $(cat "$work/err")"
[ "$(jq -c 'map(.number)' "$work/out")" = "[7]" ] || fail "A: pick must return a#7 only, not b#7, b#8 or the blocked #9: $(cat "$work/out")"
run status --json || fail "A: status --json failed: $(cat "$work/err")"
[ "$(jq -c '.otherRepositories' "$work/out")" = '[{"repository":"acme/other","items":2}]' ] || fail "A: other repositories not reported: $(jq -c . "$work/out" | cut -c1-400)"
[ "$(jq -c '.blocked[] | select(.number == 9) | .reasons' "$work/out")" = '["waits for acme/other#7"]' ] || fail "A: a blocker of another repository is not named by its ref: $(jq -c .blocked "$work/out")"

# A Project with items of one repository, none with a repository: nothing changes.
{ item - 7 '[]'; item - 9 '[{"number": 7, "state": "OPEN"}]'; } | page >"$FIX/page.json"
run pick --json || fail "A: single-repository pick failed: $(cat "$work/err")"
[ "$(jq -c 'map(.number)' "$work/out")" = "[7]" ] || fail "A: single-repository pick: $(cat "$work/out")"
run status --json || fail "A: single-repository status failed: $(cat "$work/err")"
[ "$(jq 'has("otherRepositories")' "$work/out")" = false ] || fail "A: status of one repository reports other repositories"

# B: item set names the repository of the ref; a plain number is this repository.
run item set acme/other#7 Size M || fail "B: item set failed: $(cat "$work/err")"
logged "project item-add 3 --owner acme --url https://github.com/acme/other/issues/7" || fail "B: the item of b is not the one set: $(cat "$GH_LOG")"
logged "https://github.com/acme/app/issues/7" && fail "B: a#7 was touched: $(cat "$GH_LOG")"
grep -qx 'acme/other#7 Size = M' "$work/out" || fail "B: the ref is not printed: $(cat "$work/out")"
run item set 7 Size M || fail "B: item set of a number failed: $(cat "$work/err")"
logged "--url https://github.com/acme/app/issues/7" || fail "B: a plain number is not this repository: $(cat "$GH_LOG")"
grep -qx '#7 Size = M' "$work/out" || fail "B: a number is not printed as before: $(cat "$work/out")"
run item set b/7 Size M && fail "B: an invalid ref was accepted"

# C: start and ready take a ref of this repository only.
run start acme/other#7 && fail "C: start of a ticket of another repository succeeded"
grep -q 'run it in a clone of acme/other' "$work/err" || fail "C: the clone is not named: $(cat "$work/err")"
[ "$(git -C "$repo" worktree list | wc -l)" -eq 1 ] && [ -z "$(git -C "$repo" branch --list 'feat/*')" ] || fail "C: start created something"
logged "issue view" && fail "C: start read the issue before refusing: $(cat "$GH_LOG")"
run ready acme/other#7 --dry-run && fail "C: ready of a ticket of another repository succeeded"
grep -q 'run it in a clone of acme/other' "$work/err" || fail "C: ready does not name the clone: $(cat "$work/err")"

# D: issue create --repo files in a repository linked to the Project, with links across repositories.
echo '{"data": {"node": {"repositories": {"nodes": [{"nameWithOwner": "acme/app"}, {"nameWithOwner": "acme/other"}]}}}}' >"$FIX/linked.json"
run issue create --repo acme/other --title "Cross" --body-file "$work/body.md" --size M --priority "P1 next" --milestone "v1 Start" \
  --parent acme/app#12 --blocked-by acme/app#13 || fail "D: issue create --repo failed: $(cat "$work/err")"
logged "issue create --repo acme/other --title Cross --body-file $work/body.md --milestone v1 Start" || fail "D: not created in b with its milestone: $(cat "$GH_LOG")"
logged "project item-add 3 --owner acme --url https://github.com/acme/other/issues/5" || fail "D: not on the Project: $(cat "$GH_LOG")"
for o in o1 o4 o6; do logged "--single-select-option-id $o" || fail "D: board option $o not set"; done
logged "api -X POST repos/acme/app/issues/12/sub_issues -F sub_issue_id=1005" || fail "D: not a sub-issue of a#12: $(cat "$GH_LOG")"
logged "api -X POST repos/acme/other/issues/5/dependencies/blocked_by -F issue_id=1013" || fail "D: not blocked by a#13: $(cat "$GH_LOG")"
grep -qx 'acme/other#5 Cross (created)' "$work/out" || fail "D: the created ticket is not named by its ref: $(cat "$work/out")"
# A repository that is not linked to the Project: nothing is created, the message names it.
run issue create --repo acme/stranger --title "Nope" --body-file "$work/body.md" --size M --priority "P1 next" && fail "D: a repository outside the Project was accepted"
grep -q 'acme/stranger' "$work/err" || fail "D: the repository is not named: $(cat "$work/err")"
logged "issue create" && fail "D: something was created in a stranger's repository: $(cat "$GH_LOG")"
# Without --repo: this repository, as before.
run issue create --title "Here" --body-file "$work/body.md" --size M --priority "P1 next" || fail "D: issue create failed: $(cat "$work/err")"
logged "issue create --repo acme/app --title Here" || fail "D: not created in this repository: $(cat "$GH_LOG")"
logged "graphql" && fail "D: the Project was read for a ticket of this repository: $(cat "$GH_LOG")"

# E: pick_free compares Paths inside one repository only.
items='{"items": [{"number": 7, "paths": "src/**"}, {"number": 7, "repo": "acme/other", "paths": "src/**"}, {"number": 8, "paths": "src/**"}]}'
# shellcheck disable=SC1091 # the module path is computed
free() { (cd "$repo" && . "$(dirname "$cli")/lib/board.sh" && pick_free "$items" "$1" "$2"); }
[ "$(free 7 acme/other#7)" = 0 ] || fail "E: the same Paths in two repositories do not run together: '$(free 7 acme/other#7)'"
[ -z "$(free 7 8)" ] || fail "E: the same Paths in one repository run together: '$(free 7 8)'"
[ "$(free "" 8)" = 0 ] || fail "E: nothing is running: '$(free "" 8)'"

[ "$failures" -eq 0 ] && echo "refs: all cases pass"
exit "$failures"
