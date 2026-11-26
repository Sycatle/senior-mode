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
export SENIOR_MODE_READBACK_DELAY=off

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

# #633: `item set` reads a Status back and warns when a Project workflow turned it back; it stays quiet when the
# Status held, when the read fails, and for another field.
answer() { # status
  jq -nc --arg s "$1" '{data: {repository: {issue: {projectItems: {nodes: [{project: {id: "PVT_1"},
    fieldValues: {nodes: [{name: $s, field: {name: "Status"}}]}}]}}}}}' >"$GH_ANSWER"
}
answer Backlog
got=$(cd "$repo" && SENIOR_MODE_READBACK_DELAY=0 "$cli" item set 12 Status Ready 2>"$work/err")
[ "$got" = "#12 Status = Ready" ] || fail "readback: the write is not printed: $got"
grep -q 'warning: #12 Status is Backlog, not Ready, 0 seconds after it was set' "$work/err" || fail "readback: a reverted Status is not warned: $(cat "$work/err")"
answer Ready
(cd "$repo" && SENIOR_MODE_READBACK_DELAY=0 "$cli" item set 12 Status Ready) >/dev/null 2>"$work/err" || fail "readback: a held Status fails"
[ -s "$work/err" ] && fail "readback: a held Status is warned: $(cat "$work/err")"
rm -f "$GH_ANSWER"
(cd "$repo" && SENIOR_MODE_READBACK_DELAY=0 "$cli" item set 12 Status Ready) >/dev/null 2>"$work/err" || fail "readback: an unreadable Status fails"
grep -q warning "$work/err" && fail "readback: an unreadable Status is warned"
answer Backlog
(cd "$repo" && SENIOR_MODE_READBACK_DELAY=off "$cli" item set 12 Status Ready) >/dev/null 2>"$work/err"
grep -q warning "$work/err" && fail "readback: SENIOR_MODE_READBACK_DELAY=off still reads"
rm -f "$GH_ANSWER"

: >"$GH_LOG"
expect 1 - item set 12 Status Nope
expect 1 - item set 12 Colour Ready
[ -s "$GH_LOG" ] && fail "gh called despite an unknown field or option"

# #560: the same without `set -e` in the caller (`(item_set ...) || ...`, as hotfix and status do): the error names the
# field, the call fails, and nothing is written (no `--field-id null`).
loose() { (cd "$repo" && bash -c 'lib=$1; shift; . "$lib/common.sh"; . "$lib/config.sh"; . "$lib/board.sh"; item_set "$@" && echo written' _ "$(dirname "$cli")/lib" "$@") 2>"$work/err"; }
: >"$GH_LOG"
[ -z "$(loose 12 Colour Ready)" ] || fail "item_set wrote an unknown field without set -e"
grep -q 'unknown board field: Colour' "$work/err" || fail "unknown field not named: $(cat "$work/err")"
[ -z "$(loose 12 Status Nope)" ] || fail "item_set wrote an unknown option without set -e"
grep -q 'unknown option Nope for Status' "$work/err" || fail "unknown option not named: $(cat "$work/err")"
[ -z "$(loose 12 Status Ready Colour Ready)" ] || fail "item_set wrote a pair next to an unknown field"
[ -s "$GH_LOG" ] && fail "gh called despite an unknown field or option, without set -e: $(cat "$GH_LOG")"
[ "$(loose 12 Status Ready | tail -n 1)" = written ] || fail "a known field was refused without set -e: $(cat "$work/err")"

# A field cached without options is a text field (Paths, #174): its value is passed as text, mixed with a
# single select in one call, and every pair is checked before gh is called.
config '{"project":{"owner":"acme","number":1,"id":"PVT_1","fields":{"Status":{"id":"F_STATUS","options":{"Ready":"O_READY"}},"Paths":{"id":"F_PATHS"}}}}'
: >"$GH_LOG"
expect 0 $'#12 Paths = a/**,b.sh\n#12 Status = Ready' item set 12 Paths "a/**,b.sh" Status Ready
grep -q -- "--field-id F_PATHS --text a/\*\*,b.sh" "$GH_LOG" || fail "text field not set with --text: $(cat "$GH_LOG")"
grep -q -- "--field-id F_STATUS --single-select-option-id O_READY" "$GH_LOG" || fail "single select next to a text field: $(cat "$GH_LOG")"
: >"$GH_LOG"
expect 1 - item set 12 Paths "a/**" Status Nope
[ -s "$GH_LOG" ] && fail "gh called although an option is unknown next to a text field"
config "{$PROJECT}"
expect 1 - item set 12 Paths "a/**"
grep -q 'setup github' "$work/err" || fail "item set Paths without the field does not point to setup github: $(cat "$work/err")"

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
# A text field (Paths) is read like the others.
cat >"$work/answer.json" <<'JSON'
{"data": {"repository": {"issue": {"projectItems": {"nodes": [
  {"project": {"id": "PVT_1"}, "fieldValues": {"nodes": [{"name": "Ready", "field": {"name": "Status"}},
    {"text": "a/**,b.sh", "field": {"name": "Paths"}}]}}]}}}}}
JSON
expect 0 "a/**,b.sh" item get 12 Paths
expect 0 $'#12 Status = Ready\n#12 Paths = a/**,b.sh' item get 12
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
