#!/usr/bin/env bash
# Tests for `senior-mode slot -- <command>`: a slot per session (#153). Offline: only local git repositories.
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
config() { printf '%s\n' "$1" >"$repo/.claude/senior-mode.json"; }
slot() { (cd "$repo" && "$cli" slot -- "$@"); }

# The session sees its slot, from 1.
config '{"autonomy": {"parallel": 3}}'
[ "$(slot bash -c 'echo $SENIOR_MODE_SLOT')" = 1 ] || fail "a lone session is not in slot 1"
slot bash -c 'exit 3'
[ $? -eq 3 ] || fail "slot does not return the command's exit code"
(cd "$repo" && "$cli" slot true 2>/dev/null) && fail "slot without -- accepted"

# Two sessions at once never share a slot; a third one waits for the first to end when only two exist.
config '{"autonomy": {"parallel": 2}}'
log=$work/log
: >"$log"
job='echo "$SENIOR_MODE_SLOT start $(date +%s.%N)" >>'"$log"'; sleep 0.5; echo "$SENIOR_MODE_SLOT end $(date +%s.%N)" >>'"$log"
for _ in 1 2 3; do slot bash -c "$job" & done
wait
[ "$(grep -c start "$log")" -eq 3 ] || fail "three sessions did not all run: $(cat "$log")"
# Replays the log in time order: a slot taken twice without an end in between is shared.
shared=$(sort -k3 -n "$log" | awk '$2 == "start" {if (held[$1]++) bad = 1} $2 == "end" {held[$1]--} END {print bad ? "shared" : "ok"}')
[ "$shared" = ok ] || fail "two sessions shared a slot: $(cat "$log")"
awk '{print $1}' "$log" | sort -u | grep -qvE '^[12]$' && fail "a slot outside 1..autonomy.parallel: $(cat "$log")"

# The slot count of a run, when it differs from the config, comes in SENIOR_MODE_SLOTS.
: >"$log"
for _ in 1 2 3; do SENIOR_MODE_SLOTS=3 slot bash -c "$job" & done
wait
sort -u "$log" | awk '$2 == "start" {print $1}' | tr '\n' ' ' | grep -qx '1 2 3 ' || fail "SENIOR_MODE_SLOTS=3 did not give three slots: $(cat "$log")"
slot bash -c 'echo ${SENIOR_MODE_SLOTS:-unset}' | grep -qx unset || fail "SENIOR_MODE_SLOTS leaks into the session"

# A project `slot` command: its KEY=VALUE lines are exported into the session, and it sees the slot.
config '{"autonomy": {"parallel": 2}, "slot": "echo PORT=$((3000 + SENIOR_MODE_SLOT)); echo; echo \"# a comment\"; echo DATABASE_URL=postgres://localhost/app_$SENIOR_MODE_SLOT?a=b"}'
[ "$(slot bash -c 'echo "$PORT $DATABASE_URL"')" = "3001 postgres://localhost/app_1?a=b" ] || fail "slot command output not exported: $(slot bash -c 'echo "$PORT $DATABASE_URL"')"
: >"$log"
for _ in 1 2; do slot bash -c 'echo "$PORT" >>'"$log"'; sleep 0.3' & done
wait
[ "$(sort "$log" | tr '\n' ' ')" = "3001 3002 " ] || fail "two sessions did not get two ports: $(cat "$log")"
(cd "$repo" && "$cli" config get slot) | grep -q 'PORT=' || fail "config get slot does not print the command"

# The slot command runs where the session runs, and a failing or malformed one stops the session.
config '{"slot": "pwd"}'
(cd "$repo" && "$cli" slot -- true 2>"$work/err") && fail "a slot command that prints no KEY=VALUE accepted"
grep -q 'KEY=VALUE' "$work/err" || fail "malformed slot output not explained: $(cat "$work/err")"
config '{"slot": "echo 1BAD=x"}'
slot true 2>/dev/null && fail "an invalid variable name accepted"
config '{"slot": "echo SENIOR_MODE_ROLE=reviewer"}'
slot true 2>"$work/err" && fail "a slot command set a SENIOR_MODE_ variable"
grep -q SENIOR_MODE_ROLE "$work/err" || fail "reserved variable not named: $(cat "$work/err")"
config '{"slot": "echo boom >&2; exit 4"}'
slot bash -c 'touch '"$work/ran" 2>/dev/null && fail "a failing slot command did not stop the session"
[ ! -e "$work/ran" ] || fail "the session ran after its slot command failed"

# Without a slot command nothing but SENIOR_MODE_SLOT is added.
config '{}'
[ "$(slot bash -c 'echo ${PORT:-none}')" = none ] || fail "PORT set without a slot command"

# Locks of another repository are not ours: the same slot number can be held there at once.
other=$work/other
git init -q "$other"
mkdir -p "$other/.claude"
echo '{}' >"$other/.claude/senior-mode.json"
(cd "$other" && "$cli" slot -- bash -c 'sleep 0.6; echo $SENIOR_MODE_SLOT' >"$work/other-slot") &
sleep 0.2
[ "$(slot bash -c 'echo $SENIOR_MODE_SLOT')" = 1 ] || fail "another repository's session holds our slot 1"
wait
[ "$(cat "$work/other-slot")" = 1 ] || fail "the other repository did not get its own slot 1"

[ "$failures" -eq 0 ] && echo "slot: all cases pass"
exit "$((failures > 0))"
