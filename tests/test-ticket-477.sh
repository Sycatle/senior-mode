#!/usr/bin/env bash
# Tests for #477: brief-guard.sh (PreToolUse, Agent|Task) refuses a delegation without its seven sections.
set -u
hook=$(cd "$(dirname "$0")/.." && pwd)/plugins/senior-mode/hooks/brief-guard.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0
fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

repo="$work/repo" bare="$work/bare"
git init -q "$repo"
git init -q "$bare"
mkdir -p "$repo/.claude"
echo '{"checks": []}' >"$repo/.claude/senior-mode.json"
briefs="$repo/.git/senior-mode/briefs.jsonl"

full=$'## Goal\nShip the thing\n\n## Context\nTicket #1, see src/a.ts\n\n## Constraints\nLane fast\n\n## Acceptance\nCriteria hold\n\n## Verify\nsenior-mode check shows green\n\n## Return\nOne line with file:line\n\n## Model\nsonnet, routine work'

call() { # dir prompt tool -> stdout; sets rc and err
  jq -nc --arg d "$1" --arg p "$2" --arg t "${3:-Agent}" \
    '{hook_event_name: "PreToolUse", session_id: "s1", cwd: $d, tool_name: $t,
      tool_input: {subagent_type: "senior-mode:implementer", model: "sonnet", description: "x", prompt: $p}}' |
    "$hook" 2>"$work/err"
  rc=$?
  err=$(cat "$work/err")
}

# Given an Agent call whose prompt has the seven headings, each followed by text, then it runs and briefs.jsonl has its line.
call "$repo" "$full" >/dev/null
[ "$rc" = 0 ] || fail "complete brief refused (rc=$rc): $err"
[ "$(wc -l <"$briefs" 2>/dev/null)" = 1 ] || fail "briefs.jsonl should have one line"
line=$(tail -n1 "$briefs" 2>/dev/null)
[ "$(jq -r '.session' <<<"$line" 2>/dev/null)" = s1 ] || fail "briefs line lacks the session: $line"
[ "$(jq -r '.agent_type // .agent' <<<"$line" 2>/dev/null)" = senior-mode:implementer ] || fail "briefs line lacks the agent type: $line"
[ "$(jq -r '.model' <<<"$line" 2>/dev/null)" = sonnet ] || fail "briefs line lacks the model: $line"
[ "$(jq -r '.goal // .Goal' <<<"$line" 2>/dev/null)" = "Ship the thing" ] || fail "briefs line lacks the Goal: $line"
[ -n "$(jq -r '.time // .ts // empty' <<<"$line" 2>/dev/null)" ] || fail "briefs line lacks the time: $line"
call "$repo" "$full" Task >/dev/null
[ "$rc" = 0 ] || fail "Task call with a complete brief refused (rc=$rc)"

# Given a call missing ## Verify, then the hook exits 2 with `brief: missing ## Verify (skill brief)`.
before=$(wc -l <"$briefs")
call "$repo" "${full/## Verify/## Check}" >/dev/null
[ "$rc" = 2 ] || fail "missing Verify: expected exit 2, got $rc"
grep -qF "brief: missing ## Verify (skill brief)" <<<"$err" || fail "missing Verify: wrong message: $err"
[ "$(wc -l <"$briefs")" = "$before" ] || fail "a refused call must not be logged"

# Given a call with an empty section, then the hook refuses it the same way.
empty=${full/$'Ship the thing'/}
call "$repo" "$empty" >/dev/null
[ "$rc" = 2 ] || fail "empty Goal: expected exit 2, got $rc"
grep -qF "brief: missing ## Goal (skill brief)" <<<"$err" || fail "empty Goal: wrong message: $err"
call "$repo" $'## Goal\ng\n\n## Context\nc\n\n## Constraints\nk\n\n## Acceptance\na\n\n## Verify\n\n\n## Return\nr\n\n## Model\nm' >/dev/null
[ "$rc" = 2 ] || fail "empty Verify (middle): expected exit 2, got $rc"
grep -qF "brief: missing ## Verify (skill brief)" <<<"$err" || fail "empty Verify: wrong message: $err"
call "$repo" "just do it" >/dev/null
[ "$rc" = 2 ] || fail "plain prompt: expected exit 2, got $rc"

# Given a repository without .claude/senior-mode.json, then the hook lets every call through.
call "$bare" "just do it" >/dev/null
[ "$rc" = 0 ] || fail "repository without senior-mode.json: expected exit 0, got $rc"
[ ! -e "$bare/.git/senior-mode/briefs.jsonl" ] || fail "repository without senior-mode.json must not log"

exit "$failures"
