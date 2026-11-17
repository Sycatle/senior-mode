#!/usr/bin/env bash
# Tests for `senior-mode issue create`. Offline: gh is a stub keeping issues and links in $FIX.
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
jqf="" prev=""
for a in "$@"; do [ "$prev" = --jq ] && jqf=$a; prev=$a; done
respond() { if [ -n "$jqf" ]; then jq -r "$jqf"; else cat; fi; }
links() { if [ -f "$FIX/$1" ]; then respond <"$FIX/$1"; else echo '[]' | respond; fi; }
add_link() {
  [ -z "${LINK_ERR:-}" ] || { echo "$LINK_ERR" >&2; exit 1; }
  [ -f "$FIX/$1" ] || echo '[]' >"$FIX/$1"
  jq --argjson n "$(($2 - 1000))" '. + [{number: $n}]' "$FIX/$1" >"$FIX/l" && mv "$FIX/l" "$FIX/$1"
}
arg() { local prev=""; for a in "$@"; do [ "$prev" = "$FLAG" ] && echo "$a"; prev=$a; done; }
case "$*" in
  "issue list"*) respond <"$FIX/issues.json" ;;
  "issue create"*)
    [ -z "${CREATE_ERR:-}" ] || { echo "$CREATE_ERR" >&2; exit 1; }
    n=$(($(jq length "$FIX/issues.json") + 40))
    jq --argjson n "$n" --arg t "$(FLAG=--title arg "$@")" '. + [{number: $n, title: $t}]' \
      "$FIX/issues.json" >"$FIX/i" && mv "$FIX/i" "$FIX/issues.json"
    echo "https://github.com/acme/app/issues/$n" ;;
  "project item-add"*) echo "ITEM" ;;
  "project item-edit"*) ;;
  "api repos/acme/app/issues/"*"/dependencies/blocked_by --paginate"*) n=${2#repos/acme/app/issues/}; links "blocked-${n%%/*}" ;;
  "api repos/acme/app/issues/"*"/sub_issues --paginate"*) n=${2#repos/acme/app/issues/}; links "subs-${n%%/*}" ;;
  "api -X POST repos/acme/app/issues/"*"/dependencies/blocked_by"*)
    n=${4#repos/acme/app/issues/}; add_link "blocked-${n%%/*}" "${6#issue_id=}" ;;
  "api -X POST repos/acme/app/issues/"*"/sub_issues"*)
    n=${4#repos/acme/app/issues/}; add_link "subs-${n%%/*}" "${6#sub_issue_id=}" ;;
  "api repos/acme/app/issues/"*) n=${2#repos/acme/app/issues/}; echo "{\"id\": $((n + 1000))}" | respond ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$work/stub/gh"
export PATH="$work/stub:$PATH" GH_LOG="$work/gh.log" FIX="$work/fix" SENIOR_MODE_RETRY_DELAY=0

repo="$work/repo"
git init -q "$repo"
git -C "$repo" remote add origin git@github.com:acme/app.git
mkdir -p "$repo/.claude" "$FIX"
cat >"$repo/.claude/senior-mode.json" <<'EOF'
{"project": {"id": "PVT_1", "owner": "acme", "number": 3, "fields": {
  "Status": {"id": "F_S", "options": {"Backlog": "o1", "Ready": "o2"}},
  "Priority": {"id": "F_P", "options": {"P0 now": "o3", "P1 next": "o4"}},
  "Size": {"id": "F_Z", "options": {"S": "o5", "M": "o6", "L": "o7"}}}}}
EOF
echo '[{"number": 7, "title": "Epic"}, {"number": 8, "title": "Earlier slice"}]' >"$FIX/issues.json"
printf '## Acceptance criteria\n- Given a, when b, then c.\n' >"$work/body.md"

create() {
  : >"$GH_LOG"
  (cd "$repo" && "$cli" issue create "$@") >"$work/out" 2>"$work/err"
}
logged() { grep -qF -- "$1" "$GH_LOG"; }
count() { grep -cF -- "$1" "$GH_LOG" || true; }
slice=(--title "A slice" --body-file "$work/body.md" --size M --priority "P1 next"
  --milestone "v0.1 Bootstrap" --type feature --blocked-by 8 --parent 7)

# A new slice of an epic.
create "${slice[@]}" || fail "create exited non-zero: $(cat "$work/err")"
logged "issue create --repo acme/app --title A slice --body-file $work/body.md --milestone v0.1 Bootstrap --label type:feature" ||
  fail "issue not created with milestone and type: $(cat "$GH_LOG")"
head -1 "$work/out" | grep -q '^#42 ' || fail "first line does not give the number: $(cat "$work/out")"
for f in "o1" "o4" "o6"; do
  logged "--single-select-option-id $f" || fail "board option $f not set"
done
logged "api -X POST repos/acme/app/issues/42/dependencies/blocked_by -F issue_id=1008" || fail "blocked-by link missing"
logged "api -X POST repos/acme/app/issues/7/sub_issues -F sub_issue_id=1042" || fail "not added under the epic"

# Run again: the open issue with the same title is reused, links are not added twice.
create "${slice[@]}" || fail "second run exited non-zero: $(cat "$work/err")"
[ "$(count "issue create")" -eq 0 ] || fail "second run creates a duplicate"
[ "$(count "-X POST")" -eq 0 ] || fail "second run adds links again: $(cat "$GH_LOG")"
head -1 "$work/out" | grep -q '^#42 .*already open' || fail "reuse not reported: $(cat "$work/out")"

# Defaults: Status Backlog, no milestone, label or links.
create --title "Small" --body-file "$work/body.md" --size S --priority "P0 now" ||
  fail "minimal create failed: $(cat "$work/err")"
logged "--single-select-option-id o1" || fail "default status is not Backlog"
logged "--milestone" && fail "milestone passed without --milestone"
logged "--label" && fail "label passed without --type"

# Bad input is refused before anything is created.
bad() {
  create "$@" && fail "accepted: $*"
  [ "$(count "issue create")" -eq 0 ] || fail "created despite bad input: $*"
}
bad --title "X" --body-file "$work/body.md" --size XL --priority "P0 now"
bad --title "X" --body-file "$work/body.md" --size S --priority "urgent"
bad --title "X" --body-file "$work/body.md" --size S --priority "P0 now" --status Doing
bad --title "X" --body-file "$work/missing.md" --size S --priority "P0 now"
bad --title "X" --body-file "$work/body.md" --size S --priority "P0 now" --type epic
bad --title "X" --body-file "$work/body.md" --size S --priority "P0 now" --blocked-by seven
bad --body-file "$work/body.md" --size S --priority "P0 now"
bad --title "X" --body-file "$work/body.md" --size S --priority

# A failed create stops before touching the board.
CREATE_ERR="milestone 'v9' not found" create --title "Y" --body-file "$work/body.md" --size S --priority "P0 now" &&
  fail "a failed create exits zero"
logged "project item-add" && fail "board touched after a failed create"

# A failed link is reported, not hidden.
LINK_ERR="HTTP 422: cycle" create --title "Z" --body-file "$work/body.md" --size S --priority "P0 now" --blocked-by 8 &&
  fail "a failed link exits zero"
grep -q cycle "$work/err" || fail "link error not shown: $(cat "$work/err")"

[ "$failures" -eq 0 ] && echo "issue: all cases pass"
exit "$failures"
