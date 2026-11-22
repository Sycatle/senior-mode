#!/usr/bin/env bash
# Tests for bin/senior-mode. Runs offline: gh is replaced by a stub that logs its arguments.
set -u
cli=$(cd "$(dirname "$0")/.." && pwd)/senior-mode
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

# Stub gh: log every call, answer item-add with a fixed item id.
mkdir -p "$work/stub"
cat >"$work/stub/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$GH_LOG"
case "$*" in
  *item-add*) echo "ITEM_1" ;;
  "api graphql"*) cat >"$GH_QUERY"; cat "$GH_ANSWER" ;;
esac
STUB
chmod +x "$work/stub/gh"
export PATH="$work/stub:$PATH" GH_LOG="$work/gh.log" GH_QUERY="$work/query.json" GH_ANSWER="$work/answer.json"

repo="$work/repo"
git init -q "$repo"
git -C "$repo" remote add origin https://github.com/acme/app.git
mkdir -p "$repo/.claude"
config() { printf '%s\n' "$1" >"$repo/.claude/senior-mode.json"; }
run() { (cd "$repo" && "$cli" "$@"); }

# expect <wanted status> <wanted stdout or "-" to ignore> <args...>
expect() {
  local want=$1 out=$2 got status
  shift 2
  got=$(run "$@" 2>"$work/err")
  status=$?
  [ "$status" -eq "$want" ] || fail "senior-mode $* exited $status, wanted $want ($(cat "$work/err"))"
  [ "$out" = - ] || [ "$got" = "$out" ] || fail "senior-mode $* printed '$got', wanted '$out'"
}

PROJECT='"project":{"owner":"acme","number":1,"id":"PVT_1","fields":{"Status":{"id":"F_STATUS","options":{"Ready":"O_READY"}}}}'

config '{"language":"fr"}'
expect 0 3 config get autonomy.maxTickets
expect 0 fr config get language
expect 0 local config get ci.mode
expect 1 - config get unknown.key

config '{"autonomy":{"maxTickets":5,"merge":true}}'
expect 0 5 config get autonomy.maxTickets
expect 0 true config get autonomy.merge
expect 0 2 config get autonomy.maxConsecutiveFailures
expect 0 true config get autonomy.escalate
expect 0 90 config get autonomy.sessionTimeout
config '{}'
expect 0 false config get autonomy.merge
expect 1 - config get autonomy.autoMerge
expect 0 true config get audit
config '{"audit":false}'
expect 0 false config get audit
config '{}'

# Documented optional keys read as empty when absent (a list for the list keys, an empty line for a
# string), and as set when present; a key nobody documents is still an error.
for key in review.sections docs.extra envGuard.forbidden protected secrets; do
  expect 0 '[]' config get "$key"
done
expect 0 '' config get github.protection
expect 1 - config get review.nope
expect 1 - config get docs.extra.path
config '{"protected":["a/**"],"review":{"sections":["x.md"]},"github":{"protection":"ruleset"}}'
expect 0 '["a/**"]' config get protected
expect 0 '["x.md"]' config get review.sections
expect 0 ruleset config get github.protection
expect 0 '[]' config get secrets

config '{not json'
expect 1 - config get language
grep -q setup "$work/err" || fail "invalid config message does not mention setup"

rm "$repo/.claude/senior-mode.json"
expect 1 - config get language
grep -q setup "$work/err" || fail "missing config message does not mention setup"

config "{$PROJECT}"
: >"$GH_LOG"
expect 0 "#12 Status = Ready" item set 12 Status Ready
grep -q -- "project item-add 1 --owner acme --url https://github.com/acme/app/issues/12" "$GH_LOG" ||
  fail "item-add not called as expected: $(cat "$GH_LOG")"
grep -q -- "--project-id PVT_1 --id ITEM_1 --field-id F_STATUS --single-select-option-id O_READY" "$GH_LOG" ||
  fail "item-edit not called as expected: $(cat "$GH_LOG")"

: >"$GH_LOG"
expect 1 - item set 12 Status Nope
expect 1 - item set 12 Colour Ready
[ -s "$GH_LOG" ] && fail "gh called despite an unknown field or option"

git -C "$repo" remote set-url origin git@github.com:acme/app.git
: >"$GH_LOG"
expect 0 - item set 7 Status Ready
grep -q -- "--url https://github.com/acme/app/issues/7" "$GH_LOG" || fail "ssh remote not parsed: $(cat "$GH_LOG")"

# item get: one GraphQL call reads the item of the configured Project (other Projects are ignored).
cat >"$work/answer.json" <<'JSON'
{"data": {"repository": {"issue": {"projectItems": {"nodes": [
  {"project": {"id": "PVT_OTHER"}, "fieldValues": {"nodes": [{"name": "Done", "field": {"name": "Status"}}]}},
  {"project": {"id": "PVT_1"}, "fieldValues": {"nodes": [{},
    {"name": "Ready", "field": {"name": "Status"}}, {"name": "S", "field": {"name": "Size"}}]}}]}}}}}
JSON
: >"$GH_LOG"
expect 0 Ready item get 12 Status
expect 0 S item get 12 Size
expect 0 $'#12 Status = Ready\n#12 Size = S' item get 12
[ "$(grep -c graphql "$GH_LOG")" -eq 3 ] || fail "item get: not one GraphQL call per command: $(cat "$GH_LOG")"
jq -e '.variables | .owner == "acme" and .name == "app" and .number == 12' "$GH_QUERY" >/dev/null ||
  fail "item get: wrong query variables: $(cat "$GH_QUERY")"
expect 0 "" item get 12 Priority
echo '{"data": {"repository": {"issue": {"projectItems": {"nodes": []}}}}}' >"$work/answer.json"
expect 1 - item get 12 Status
grep -q "not on the board" "$work/err" || fail "item get: no message for an issue off the board: $(cat "$work/err")"
echo '{"errors": [{"message": "Could not resolve to an Issue"}], "data": {"repository": {"issue": null}}}' >"$work/answer.json"
expect 1 - item get 99
grep -q "Could not resolve" "$work/err" || fail "item get: GitHub error not shown: $(cat "$work/err")"
expect 1 - item get
expect 1 - item get abc

expect 1 - bogus
(cd "$work" && "$cli" config get language 2>/dev/null) && fail "works outside a git repository"

[ "$failures" -eq 0 ] && echo "senior-mode: all cases pass"
exit "$failures"
