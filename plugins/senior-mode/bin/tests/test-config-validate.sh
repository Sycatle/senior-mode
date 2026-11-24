#!/usr/bin/env bash
# Tests for `senior-mode config validate` and the schema of .claude/senior-mode.json (#317). Offline.
set -u
bin=$(cd "$(dirname "$0")/.." && pwd)
cli=$bin/senior-mode
schema=$bin/../schema/senior-mode.schema.json
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

repo="$work/repo"
git init -q -b main "$repo"
mkdir -p "$repo/.claude"
config() { printf '%s\n' "$1" >"$repo/.claude/senior-mode.json"; }
run() { (cd "$repo" && "$cli" "$@") >"$work/out" 2>"$work/err"; }

# The schema is JSON, and every key of the plugin's defaults is in it.
jq empty "$schema" || fail "the schema is not valid JSON"
defaults=$(bash -c '. "$1"; printf "%s" "$DEFAULTS"' _ "$bin/lib/common.sh")
missing=$(jq -nr --argjson d "$defaults" --slurpfile s "$schema" '
  [$d | paths(scalars or type == "array") | map(tostring)] as $leaves
  | $leaves[] | . as $p
  | select(reduce $p[] as $k ($s[0]; if .properties[$k] then .properties[$k] else {} end) == {})
  | join(".")')
[ -z "$missing" ] || fail "defaults keys missing from the schema: $missing"

# A valid configuration is silent and passes; the own file of this repository too.
# shellcheck disable=SC2016
config '{"$schema":"x","language":"fr","preset":"node","checks":[{"name":"lint","run":"true"}],"autonomy":{"maxTickets":5,"merge":true,"sessionTimeout":90,"schedule":"02:30","ticketsPerHour":6,"userSettings":false},"ci":{"mode":"actions"},"protected":["a/**"],"project":{"owner":"a","number":3,"id":"P","fields":{"Status":{"id":"F","options":{"Ready":"O"}},"Paths":{"id":"T"},"Iteration":{"id":"I","iteration":true},"Start":{"id":"S","date":true}}}}'
run config validate || fail "a valid config is refused: $(cat "$work/out")"
[ ! -s "$work/out" ] || fail "a valid config prints something: $(cat "$work/out")"
(cd "$bin/../../.." && "$cli" config validate) >"$work/out" 2>&1 || fail "the config of this repository is invalid: $(cat "$work/out")"

# An unknown key names the closest known one, at any depth.
config '{"autonomy":{"maxTicket":5},"langauge":"fr","wipp":2,"completely":1}'
run config validate && fail "unknown keys pass"
grep -q '^error: autonomy.maxTicket: unknown key, did you mean maxTickets$' "$work/out" || fail "nested typo: $(cat "$work/out")"
grep -q '^error: langauge: unknown key, did you mean language$' "$work/out" || fail "top-level typo: $(cat "$work/out")"
grep -q '^error: wipp: unknown key, did you mean wip$' "$work/out" || fail "short typo: $(cat "$work/out")"
grep -q '^error: completely: unknown key$' "$work/out" || fail "a key with no near match gets a guess: $(cat "$work/out")"

# A value out of its domain says what was expected.
config '{"ci":{"mode":"remote"},"autonomy":{"sessionTimeout":0,"maxTickets":"3","schedule":"2am","merge":"yes"},"wip":1.5,"language":"de","protected":"a/**","checks":[{"name":"x","runs":"y"}],"notify":{"webhook":"ftp://x"}}'
run config validate && fail "out-of-domain values pass"
grep -q '^error: ci.mode: "remote" is not one of "local", "actions", "existing"$' "$work/out" || fail "enum: $(cat "$work/out")"
grep -q '^error: autonomy.sessionTimeout: 0 is below the minimum 1$' "$work/out" || fail "minimum: $(cat "$work/out")"
grep -q '^error: autonomy.maxTickets: expected integer, got string ("3")$' "$work/out" || fail "type: $(cat "$work/out")"
grep -q '^error: autonomy.schedule: "2am" does not match' "$work/out" || fail "pattern: $(cat "$work/out")"
grep -q '^error: autonomy.merge: expected boolean, got string' "$work/out" || fail "boolean: $(cat "$work/out")"
grep -q '^error: wip: expected integer, got number (1.5)$' "$work/out" || fail "integer: $(cat "$work/out")"
grep -q '^error: language: "de" is not one of "en", "fr"$' "$work/out" || fail "language: $(cat "$work/out")"
grep -q '^error: protected: expected array, got string' "$work/out" || fail "array: $(cat "$work/out")"
grep -q '^error: checks\[0\].runs: unknown key, did you mean run$' "$work/out" || fail "item key: $(cat "$work/out")"
grep -q '^error: notify.webhook: "ftp://x" does not match' "$work/out" || fail "webhook: $(cat "$work/out")"
config '{"ci":{"mode":"actoins"}}'
run config validate && fail "a misspelt enum value passes"
grep -q 'did you mean "actions"' "$work/out" || fail "closest enum value missing: $(cat "$work/out")"

# A deprecated value is a warning: it passes and is shown.
config '{"preset":"typescript"}'
run config validate || fail "a deprecated value fails: $(cat "$work/out")"
grep -q '^warning: preset: "typescript" is deprecated, use "node"$' "$work/out" || fail "deprecated value: $(cat "$work/out")"

# A deprecated key, from a schema that marks one.
cat >"$work/old.schema.json" <<'EOF'
{"type":"object","additionalProperties":false,"properties":{
  "old":{"type":"string","deprecated":true,"x-replacedBy":"new"},"new":{"type":"string"}}}
EOF
echo '{"old":"a","new":"b"}' >"$work/old.json"
out=$(bash -c '. "$1"; SELF=$2; config_findings "$3" "$4"' _ "$bin/lib/config.sh" "$cli" "$work/old.json" "$work/old.schema.json")
[ "$(jq -r '"\(.level) \(.path) \(.message)"' <<<"$out")" = "warning old deprecated, use new" ] || fail "deprecated key: $out"

# --json carries the same findings.
config '{"wipp":2,"preset":"typescript"}'
run config validate --json && fail "--json hides the failure"
jq -e '.valid == false and (.findings | length == 2) and (.findings | any(.level == "error" and .path == "wipp"))' "$work/out" >/dev/null ||
  fail "--json: $(cat "$work/out")"
config '{"wip":2}'
run config validate --json || fail "--json fails on a valid config"
jq -e '.valid == true and .findings == []' "$work/out" >/dev/null || fail "--json valid: $(cat "$work/out")"
run config validate --bogus && fail "an unknown option is accepted"

# check runs it: an unknown key fails the config step, a deprecated value is shown under its ok.
config '{"checks":[{"name":"t","run":"true"}],"autonomy":{"maxTicket":5}}'
run check && fail "check passes with an unknown key"
grep -q '^FAIL  config' "$work/out" || fail "check does not report the config step: $(cat "$work/out")"
grep -q 'autonomy.maxTicket: unknown key, did you mean maxTickets' "$work/out" || fail "check lacks the closest key: $(cat "$work/out")"
config '{"checks":[{"name":"t","run":"true"}],"preset":"typescript"}'
run check || fail "check fails on a deprecated value: $(cat "$work/out")"
grep -q '^ok    config' "$work/out" || fail "config step not ok: $(cat "$work/out")"
grep -q 'warning: preset: "typescript" is deprecated' "$work/out" || fail "warning not shown under ok: $(cat "$work/out")"

# setup repo writes $schema, pointing at the file that ships with the plugin; the config it writes validates.
fresh="$work/fresh"
git init -q -b main "$fresh"
mkdir -p "$fresh/.claude"
echo '{"language":"en"}' >"$fresh/.claude/senior-mode.json"
(cd "$fresh" && "$cli" setup repo --command test=true >/dev/null 2>&1) || fail "setup repo failed"
url=$(jq -r '."$schema"' "$fresh/.claude/senior-mode.json")
case $url in
  *"/plugins/senior-mode/schema/senior-mode.schema.json") ;;
  *) fail "setup repo wrote \$schema '$url'" ;;
esac
[ "$(jq -r '.["$id"]' "$schema")" = "$url" ] || fail "\$schema is not the \$id of the shipped schema"
(cd "$fresh" && "$cli" config validate) >"$work/out" 2>&1 || fail "the config written by setup is invalid: $(cat "$work/out")"
(cd "$fresh" && "$cli" setup repo >/dev/null 2>&1)
[ "$(jq '[paths | select(.[0] == "$schema")] | length' "$fresh/.claude/senior-mode.json")" -eq 1 ] || fail "\$schema written twice"

[ "$failures" -eq 0 ] && echo "config validate: all cases pass"
exit "$failures"
