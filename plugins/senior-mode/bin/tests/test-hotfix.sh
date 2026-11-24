#!/usr/bin/env bash
# Tests for `senior-mode hotfix <issue>` (#322). Offline: gh is a stub serving an issue and logging every call; origin
# is a local bare repository reached through an insteadOf rewrite of the GitHub URL.
set -u
cli=$(cd "$(dirname "$0")/.." && pwd)/senior-mode
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

mkdir -p "$work/stub"
cat >"$work/stub/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$GH_LOG"
case "$*" in
  "issue view 9 "*) exit 1 ;;
  "issue view "*) echo "$GH_ISSUE" ;;
  "label create "*) ;;
  "issue edit "*) ;;
  "project item-add"*) echo "ITEM" ;;
  "project item-edit"*) ;;
  "api graphql --input -") cat >/dev/null
    jq -nc --argjson i "${GH_IN_PROGRESS:-[]}" '{data: {node: {items: {
    pageInfo: {hasNextPage: false}, nodes: ($i | map({fieldValues: {nodes: [{name: "In progress", field: {name: "Status"}}]},
      content: {number: ., title: "Ticket \(.)", url: "u", state: "OPEN", labels: {nodes: []}, milestone: null,
        blockedBy: {nodes: []}}}))}}}}' ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$work/stub/gh"
export PATH="$work/stub:$PATH" GH_LOG="$work/gh.log" SENIOR_MODE_RETRY_DELAY=0 XDG_DATA_HOME="$work/xdg"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

git init -q --bare -b main "$work/origin.git"
repo="$work/app"
wt=$XDG_DATA_HOME/senior-mode/worktrees/app-$(printf '%08x' "$(printf '%s' "$repo" | cksum | cut -d' ' -f1)")
git init -q -b main "$repo"
git -C "$repo" remote add origin git@github.com:acme/app.git
git -C "$repo" config url."$work/origin.git".insteadOf git@github.com:acme/app.git
mkdir -p "$repo/.claude"
cat >"$repo/.claude/senior-mode.json" <<'JSON'
{"project": {"id": "PVT_1", "owner": "acme", "number": 3, "fields": {
  "Status": {"id": "F_S", "options": {"Backlog": "s1", "Ready": "s2", "In progress": "s3"}},
  "Priority": {"id": "F_P", "options": {"P0": "p0", "P1": "p1"}},
  "Size": {"id": "F_Z", "options": {"S": "z1", "M": "z2", "L": "z3"}},
  "Severity": {"id": "F_V", "options": {"critical": "v1", "low": "v2"}}}}}
JSON
git -C "$repo" add -A
git -C "$repo" commit -q -m "chore: start"
git -C "$repo" push -q origin main
git -C "$repo" fetch -q origin
git -C "$repo" remote set-head origin main >/dev/null

hotfix() {
  : >"$GH_LOG"
  (cd "$repo" && "$cli" hotfix "$@") >"$work/out" 2>"$work/err"
}
logged() { grep -qF -- "$1" "$GH_LOG"; }

# An emergency: labelled (the stub serves the issue as it was, so the branch type is the one of an untyped ticket), P0 critical S, started at once, with its incident note.
export GH_ISSUE='{"title": "Checkout returns 500 for every card", "state": "OPEN", "labels": []}'
hotfix 500 || fail "hotfix exited non-zero: $(cat "$work/err")"
logged "label create hotfix --repo " || fail "the label hotfix is not made: $(cat "$GH_LOG")"
grep -qE "^issue edit 500 --repo [^ ]+ --add-label hotfix,type:bug$" "$GH_LOG" || fail "the ticket is not labelled: $(cat "$GH_LOG")"
for f in "F_P --single-select-option-id p0" "F_Z --single-select-option-id z1" "F_V --single-select-option-id v1" "F_S --single-select-option-id s2" "F_S --single-select-option-id s3"; do
  logged "--field-id $f" || fail "board field not set ($f): $(cat "$GH_LOG")"
done
grep -qx "branch feat/500-checkout-returns-500-for-every-card" "$work/out" || fail "branch line: $(cat "$work/out")"
grep -qx "worktree $wt/500" "$work/out" || fail "worktree line: $(cat "$work/out")"
note=$(ls "$wt"/500/docs/incidents/*-500-checkout-returns-500-for-every-card.md 2>/dev/null)
[ -n "$note" ] || fail "no incident note in the worktree: $(ls "$wt/500/docs" 2>&1)"
grep -qx "# Incident: Checkout returns 500 for every card" "$note" || fail "incident title: $(head -3 "$note")"
grep -qx "Ticket: #500" "$note" || fail "incident note does not name the ticket"
grep -q "^incident $note$" "$work/out" || fail "the note is not announced: $(cat "$work/out")"
[ -z "$(git -C "$repo" status --porcelain)" ] || fail "the main checkout is dirty"

# Rerun: one note.
hotfix 500 || fail "rerun failed: $(cat "$work/err")"
notes=("$wt"/500/docs/incidents/*)
[ "${#notes[@]}" -eq 1 ] || fail "a rerun wrote a second note: ${notes[*]}"

# The wip limit does not hold a hotfix back; a ticket with a type keeps it.
export GH_ISSUE='{"title": "Login loops", "state": "OPEN", "labels": [{"name": "type:bug"}, {"name": "hotfix"}]}' GH_IN_PROGRESS='[89]'
hotfix 501 || fail "a hotfix was held by the wip limit: $(cat "$work/err")"
grep -qE -- "--add-label hotfix$" "$GH_LOG" || fail "type:bug was added to a typed ticket, or the label is missing: $(cat "$GH_LOG")"
grep -qx "branch fix/501-login-loops" "$work/out" || fail "branch of #501: $(cat "$work/out")"
[ -d "$wt/501/docs/incidents" ] || fail "no incident note for #501"

# A board without Severity still works: Priority P0 puts it first.
unset GH_IN_PROGRESS
jq 'del(.project.fields.Severity)' "$repo/.claude/senior-mode.json" >"$work/c" && mv "$work/c" "$repo/.claude/senior-mode.json"
export GH_ISSUE='{"title": "Mail is down", "state": "OPEN", "labels": []}'
hotfix 502 || fail "no Severity field stopped the hotfix: $(cat "$work/err")"
grep -q "Severity critical" "$work/err" || fail "the missing Severity is not said: $(cat "$work/err")"
logged "field-id null" && fail "an unknown field was written"

# Refusals.
export GH_ISSUE='{"title": "Old", "state": "CLOSED", "labels": []}'
hotfix 503 && fail "a closed issue was started"
grep -q "closed" "$work/err" || fail "closed refusal: $(cat "$work/err")"
logged "label create" && fail "a closed issue was labelled"
hotfix && fail "hotfix without an issue"
hotfix abc && fail "hotfix of a non-number"
grep -q "usage: senior-mode" "$work/err" || fail "no usage: $(cat "$work/err")"

# The review gate of a hotfix: serve and run read these two (hotfix_item on the board, pr_hotfix on a pull request).
(
  cd "$repo" || exit 1
  lib=$(dirname "$cli")/lib
  # shellcheck source=/dev/null
  . "$lib/common.sh"
  # shellcheck source=/dev/null
  . "$lib/board.sh"
  # shellcheck source=/dev/null
  . "$lib/hotfix.sh"
  board='{"items": [{"number": 7, "labels": ["hotfix"]}, {"number": 8, "labels": ["type:bug"]}]}'
  hotfix_item "$board" 7 || { echo "FAIL: #7 is not seen as a hotfix"; exit 1; }
  ! hotfix_item "$board" 8 || { echo "FAIL: #8 is seen as a hotfix"; exit 1; }
  ! hotfix_item "$board" 9 || { echo "FAIL: an absent ticket is seen as a hotfix"; exit 1; }
  GH_ISSUE=hotfix pr_hotfix acme/app '{"body": "Closes #7"}' || { echo "FAIL: a pull request closing a hotfix is not one"; exit 1; }
  ! GH_ISSUE=type:bug pr_hotfix acme/app '{"body": "Closes #8"}' || { echo "FAIL: a pull request closing a bug is a hotfix"; exit 1; }
  pr_hotfix acme/app '{"body": "Closes #9"}' || { echo "FAIL: unreadable labels lift the review"; exit 1; }
) || failures=$((failures + 1))

[ "$failures" -eq 0 ] && echo "hotfix: all cases pass"
exit "$((failures > 0))"
