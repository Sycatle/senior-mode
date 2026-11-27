#!/usr/bin/env bash
# Tests for proof.sh (PostToolUse, Stop, SubagentStop, PreCompact): JSON in, decision out.
set -u
hook=$(cd "$(dirname "$0")/.." && pwd)/proof.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0
export CLAUDE_PLUGIN_DATA="$work/data"

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

repo="$work/repo" bare="$work/bare"
git init -q -b feat/12-login "$repo"
git init -q "$bare"
mkdir -p "$repo/.claude"
echo '{"checks": [{"name": "unit", "run": "npm test"}]}' >"$repo/.claude/senior-mode.json"

send() { # event session [jq assignments] -> hook stdout
  jq -nc --arg e "$1" --arg s "$2" --arg d "${dir:-$repo}" "{hook_event_name: \$e, session_id: \$s, cwd: \$d} ${3:-}" | "$hook"
}
edit() { send PostToolUse "$1" '+ {tool_name: "Edit", tool_input: {file_path: "a.js"}}' >/dev/null; }
bash_ok() { send PostToolUse "$1" "+ {tool_name: \"Bash\", tool_input: {command: \"$2\"}}" >/dev/null; }
stop() { # expected (allow = silent, remind = reminder, never a block) session [extra] label
  out=$(send Stop "$2" "${3:-}")
  got=allow
  [ -n "$(jq -r '.systemMessage // empty' <<<"$out" 2>/dev/null)" ] && got=remind
  [ -z "$(jq -r '.decision // empty' <<<"$out" 2>/dev/null)" ] || fail "$4: the Stop is blocked: $out"
  [ "$got" = "$1" ] || fail "$4: expected $1, got $got"
}

stop allow s1 "" "stop without edits"
edit s1
stop remind s1 "" "stop after an edit"
grep -q "senior-mode check" <<<"$out" || fail "reminder does not name the command: $out"
stop allow s1 "+ {stop_hook_active: true}" "second stop after the reminder"
bash_ok s1 "ls -la"
stop remind s1 "" "stop after an unrelated command"
bash_ok s1 "senior-mode check"
stop allow s1 "" "stop after senior-mode check succeeded"
edit s1
stop remind s1 "" "edit after the verification"
bash_ok s1 "cd web && npm test"
stop allow s1 "" "stop after a configured check"
stop allow s2 "" "another session is not affected"

edit s3
out=$(send SubagentStop s3 '+ {agent_type: "senior-mode:implementer", stop_hook_active: false}')
[ -n "$(jq -r '.systemMessage // empty' <<<"$out" 2>/dev/null)" ] || fail "implementer stops with unverified edits are not reminded"
[ -z "$(jq -r '.decision // empty' <<<"$out" 2>/dev/null)" ] || fail "implementer stop is blocked: $out"
out=$(send SubagentStop s3 '+ {agent_type: "senior-mode:scout", stop_hook_active: false}')
[ -z "$out" ] || fail "a non-implementer subagent is reminded: $out"

dir=$bare edit s4
dir=$bare stop allow s4 "" "repository without senior-mode config"

out=$(send PreCompact s3 '+ {trigger: "auto"}')
grep -q "#12" <<<"$out" || fail "compaction instructions miss the ticket: $out"
grep -qi "not verified" <<<"$out" || fail "compaction instructions miss the verification state: $out"
grep -qi "decision" <<<"$out" || fail "compaction instructions miss the decisions: $out"

[ "$failures" -eq 0 ] && echo "proof: all cases pass"
exit "$failures"
