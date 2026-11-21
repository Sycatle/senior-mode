#!/usr/bin/env bash
# Tests for `senior-mode e2e-lock` and its use by `check` for the command named e2e. Offline.
# shellcheck disable=SC2016 # commands for bash -c, not expanded here
set -u
cli=$(cd "$(dirname "$0")/.." && pwd)/senior-mode
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

export XDG_RUNTIME_DIR="$work/runtime" SENIOR_MODE_LOCK_POLL=0.05
mkdir -p "$XDG_RUNTIME_DIR"
repo="$work/repo"
git init -q "$repo"
mkdir -p "$repo/.claude"
config() {
  printf '%s\n' "$1" >"$repo/.claude/senior-mode.json"
  git -C "$repo" add -A
  git -C "$repo" -c user.name=t -c user.email=t@t commit -q -m "chore: config" --allow-empty
}

# Two runs of a 0.4 s job that log start and end times; prints "overlap" when they ran together.
pair() {
  local log=$work/times
  : >"$log"
  job='echo "start $(date +%s.%N) $SENIOR_MODE_E2E_SLOT" >>'"$log"'; sleep 0.4; echo "end $(date +%s.%N)" >>'"$log"
  (cd "$repo" && "$cli" e2e-lock -- bash -c "$job") &
  (cd "$repo" && "$cli" e2e-lock -- bash -c "$job") &
  wait
  # Sorted by time: two starts in a row means the jobs overlapped.
  sort -k2 -n "$log" | awk '{print $1}' | tr '\n' ' ' | grep -q 'start start' && echo overlap || echo serial
}

config '{"e2e": {"slots": 1}}'
[ "$(pair)" = serial ] || fail "one slot: two e2e runs overlapped"
grep -q 'start .* 1$' "$work/times" || fail "SENIOR_MODE_E2E_SLOT not exported: $(cat "$work/times")"

config '{"e2e": {"slots": 2}}'
[ "$(pair)" = overlap ] || fail "two slots: the e2e runs did not run together"

config '{}'
[ "$(pair)" = overlap ] || fail "default of 2 slots not applied"
(cd "$repo" && "$cli" config get e2e.slots) | grep -qx 2 || fail "e2e.slots has no default of 2"

# The exit code of the command comes through.
(cd "$repo" && "$cli" e2e-lock -- bash -c 'exit 3')
[ $? -eq 3 ] || fail "e2e-lock does not return the command's exit code"
(cd "$repo" && "$cli" e2e-lock true 2>/dev/null) && fail "e2e-lock without -- accepted"

config '{"e2e": {"slots": 0}}'
(cd "$repo" && "$cli" e2e-lock -- true 2>"$work/err") && fail "e2e.slots 0 accepted"
grep -q 'e2e.slots' "$work/err" || fail "bad e2e.slots not explained: $(cat "$work/err")"

# Outside a configured repository it still works, with the default.
(cd "$work" && "$cli" e2e-lock -- true) || fail "e2e-lock fails outside a configured repository"

# check runs the command named e2e through the lock, and only that one.
config '{"checks": [{"name": "e2e", "run": "test -n \"$SENIOR_MODE_E2E_SLOT\""}, {"name": "unit", "run": "test -z \"${SENIOR_MODE_E2E_SLOT:-}\""}]}'
(cd "$repo" && "$cli" check) >"$work/out" 2>&1 || fail "check does not run e2e through the lock: $(cat "$work/out")"

[ "$failures" -eq 0 ] && echo "e2e-lock: all cases pass"
exit "$((failures > 0))"
