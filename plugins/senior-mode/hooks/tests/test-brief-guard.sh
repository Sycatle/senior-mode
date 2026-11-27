#!/usr/bin/env bash
# Tests for brief-guard.sh (PreToolUse, Agent|Task): a brief without a Goal or a Verify is refused, the other sections are advised.
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
    "$hook" 2>"$work/err" >"$work/out"
  rc=$?
  err=$(cat "$work/err")
  ctx=$(jq -r '.hookSpecificOutput.additionalContext // empty' "$work/out" 2>/dev/null)
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

minimal=$'## Goal\ng\n\n## Verify\nv'
call "$minimal"
[ "$rc" = 0 ] || fail "goal and verify only: expected exit 0, got $rc: $err"
for s in Context Constraints Acceptance Return Model; do
  grep -qF "## $s" <<<"$ctx" || fail "goal and verify only: reminder misses ## $s: $ctx"
done
grep -qF "## Goal" <<<"$ctx" && fail "reminder names a section that is present: $ctx"
call "$ok"
[ -z "$ctx" ] || fail "complete brief: unexpected reminder: $ctx"
call $'## Goal\ng\n\n## Context\nc'
[ "$rc" = 2 ] || fail "no Verify: expected exit 2, got $rc"
grep -qF "missing ## Verify" <<<"$err" || fail "no Verify: wrong message: $err"
call $'## Verify\nv\n\n## Context\nc'
[ "$rc" = 2 ] || fail "no Goal: expected exit 2, got $rc"
grep -qF "missing ## Goal" <<<"$err" || fail "no Goal: wrong message: $err"

[ "$(wc -l <"$briefs")" = 3 ] || fail "only the accepted calls are logged"
exit "$failures"
