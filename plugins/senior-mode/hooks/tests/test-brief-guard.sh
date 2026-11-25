#!/usr/bin/env bash
# Tests for brief-guard.sh (PreToolUse, Agent|Task): a brief without its seven sections is refused.
set -u
hook=$(cd "$(dirname "$0")/.." && pwd)/brief-guard.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0
fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

repo="$work/repo"
git init -q "$repo"
mkdir -p "$repo/.claude"
echo '{"checks": []}' >"$repo/.claude/senior-mode.json"
briefs="$repo/.git/senior-mode/briefs.jsonl"

call() { # prompt -> sets rc and err
  jq -nc --arg d "$repo" --arg p "$1" \
    '{hook_event_name: "PreToolUse", session_id: "s1", cwd: $d, tool_name: "Agent", tool_input: {prompt: $p}}' |
    "$hook" 2>"$work/err" >/dev/null
  rc=$?
  err=$(cat "$work/err")
}

ok=$'## Goal\ng\n\n## Context\nc\n\n## Constraints\nk\n\n## Acceptance\na\n\n## Verify\nv\n\n## Return\nr\n\n## Model\nm'
call "$ok"
[ "$rc" = 0 ] || fail "complete brief refused: $err"

nover=$'## Goal\ng\n\n## Context\nc\n\n## Constraints\nk\n\n## Acceptance\na\n\n## Return\nr\n\n## Model\nm'
call "$nover"
[ "$rc" = 2 ] || fail "missing Verify: expected exit 2, got $rc"
[ "$err" = "brief: missing ## Verify (skill brief)" ] || fail "missing Verify: wrong message: $err"

call $'## Goal\n\n## Context\nc\n\n## Constraints\nk\n\n## Acceptance\na\n\n## Verify\nv\n\n## Return\nr\n\n## Model\nm'
[ "$rc" = 2 ] || fail "empty Goal: expected exit 2, got $rc"
grep -qF "missing ## Goal" <<<"$err" || fail "empty Goal: wrong message: $err"

[ "$(wc -l <"$briefs")" = 1 ] || fail "only the accepted call is logged"
exit "$failures"
