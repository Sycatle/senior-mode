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

# The template .senior-mode/slot.env (#755): tokens per slot, two sessions get distinct ports, databases and compose projects.
export XDG_DATA_HOME="$work/data" SENIOR_MODE_WORKER=w1
mkdir -p "$repo/.senior-mode"
template() { printf '%s\n' "$@" >"$repo/.senior-mode/slot.env"; }
config '{"autonomy": {"parallel": 2}}'
template '# a comment' '' 'PORT={{port:3000}}' 'DATABASE_URL=postgres://localhost:5432/{{repo}}_s{{slot}}' 'COMPOSE_PROJECT_NAME={{repo}}-s{{slot}}'
: >"$log"
for _ in 1 2; do slot bash -c 'echo "$PORT $DATABASE_URL $COMPOSE_PROJECT_NAME" >>'"$log"'; sleep 0.3' & done
wait
[ "$(sort "$log" | tr '\n' ';')" = "3001 postgres://localhost:5432/repo_s1 repo-s1;3002 postgres://localhost:5432/repo_s2 repo-s2;" ] ||
  fail "the template did not give two slots their own port, database and compose project: $(cat "$log")"

# A bad template stops the session before it starts, and names the line.
template 'A=1' 'B={{unknown}}'
slot touch "$work/ran" 2>"$work/err" && fail "an unknown token accepted"
{ grep -q 'line 2' "$work/err" && grep -q 'B={{unknown}}' "$work/err"; } || fail "unknown token not named: $(cat "$work/err")"
template 'SENIOR_MODE_X=1'
slot touch "$work/ran" 2>"$work/err" && fail "a SENIOR_MODE_ key accepted"
grep -q 'SENIOR_MODE_X' "$work/err" || fail "reserved key not named: $(cat "$work/err")"
template 'PORT={{port:65535}}'
slot touch "$work/ran" 2>"$work/err" && fail "a port past 65535 accepted"
{ grep -q 'line 1' "$work/err" && grep -q 'PORT={{port:65535}}' "$work/err"; } || fail "bad port not named: $(cat "$work/err")"
template 'bad name=1'
slot touch "$work/ran" 2>/dev/null && fail "a non-identifier name accepted"
[ ! -e "$work/ran" ] || fail "the session ran with a bad template"

# A port a foreign process holds: the session takes the next slot and says why; with every port busy it waits and names the port.
hold() { python3 -c 'import socket,sys,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(); time.sleep(float(sys.argv[2]))' "$@" & }
base=$(python3 -c 'import socket
s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1] - 1)')
template "PORT={{port:$base}}"
hold $((base + 1)) 2
sleep 0.5
[ "$(slot bash -c 'echo $SENIOR_MODE_SLOT $PORT' 2>"$work/err")" = "2 $((base + 2))" ] || fail "a busy port did not move the session to slot 2"
grep -q "slot 1 skipped: port $((base + 1))" "$work/err" || fail "the skipped slot is not logged: $(cat "$work/err")"
wait
hold $((base + 1)) 3
hold $((base + 2)) 3
sleep 0.5
slot bash -c 'echo $SENIOR_MODE_SLOT >'"$work/late" 2>"$work/err" &
sleep 1
[ ! -e "$work/late" ] || fail "the session started with every port busy"
grep -q "port $((base + 1)) is held\|port $((base + 2)) is held" "$work/err" || fail "the wait does not name the port: $(cat "$work/err")"
wait
[ -e "$work/late" ] || fail "the session did not start once the ports were free"

# The template is read first, the slot command's lines override; the slot directory stays, the ticket changes.
template 'PORT=1' 'KEEP=template' 'DIR={{slotdir}}' 'TICKET={{ticket}}' 'WT={{worktree}}' 'WHO={{machine}}'
config '{"slot": "echo PORT=2"}'
git -C "$repo" symbolic-ref HEAD refs/heads/feat/12-first
out1=$(slot bash -c 'echo "$PORT $KEEP $DIR $TICKET $WT $WHO"')
git -C "$repo" symbolic-ref HEAD refs/heads/feat/13-second
out2=$(slot bash -c 'echo "$PORT $KEEP $DIR $TICKET $WT $WHO"')
[ "${out1%% *}" = 2 ] || fail "the slot command did not override the template: $out1"
read -ra a <<<"$out1"
read -ra b <<<"$out2"
[ "${a[1]}" = template ] && [[ ${a[2]} == "$work/data/senior-mode/slots/"* ]] || fail "template line or slot dir wrong: $out1"
[ "${a[2]}" = "${b[2]}" ] && [ -d "${a[2]}" ] || fail "the slot directory changed between tickets: $out1 / $out2"
{ [ "${a[3]}" = 12 ] && [ "${b[3]}" = 13 ]; } || fail "{{ticket}} wrong: $out1 / $out2"
[ "${a[5]}" = w1 ] || fail "{{machine}} is not the worker name: $out1"
rm "$repo/.senior-mode/slot.env"
[ "$(slot bash -c 'echo ${KEEP:-none}')" = none ] || fail "the template still read after its removal"

# slotDown and slotUp (#764): down, up, the command, down; down runs last even when the session is killed; a failing up stops it.
hooks=$work/hooks
config '{"slotDown": "echo down $SENIOR_MODE_SLOT >>'"$hooks"'", "slotUp": "echo up $SENIOR_MODE_SLOT >>'"$hooks"'"}'
: >"$hooks"
slot bash -c 'echo command >>'"$hooks"'; exit 5'
[ $? -eq 5 ] || fail "slot with hooks does not return the command's exit code"
[ "$(tr '\n' ',' <"$hooks")" = "down 1,up 1,command,down 1," ] || fail "hooks not in the order down, up, command, down: $(cat "$hooks")"
[ "$(slot bash -c 'echo out')" = out ] || fail "the session's stdout is not left alone with hooks"
: >"$hooks"
(cd "$repo" && "$cli" slot -- bash -c 'echo command >>'"$hooks"'; sleep 30') &
pid=$!
for _ in $(seq 100); do grep -q '^command' "$hooks" && break; sleep 0.05; done
kill -TERM "$pid"
wait "$pid"
[ "$(tr '\n' ',' <"$hooks")" = "down 1,up 1,command,down 1," ] || fail "slotDown did not run last after SIGTERM: $(cat "$hooks")"
config '{"slotUp": "echo up >>'"$hooks"'; echo nope >&2; exit 7", "slotDown": "echo down >>'"$hooks"'"}'
: >"$hooks"
slot bash -c 'echo command >>'"$hooks" 2>"$work/err" && fail "a failing slotUp did not stop the session"
grep -q slotUp "$work/err" || fail "the failing hook is not named: $(cat "$work/err")"
grep -q command "$hooks" && fail "the command started after a failing slotUp: $(cat "$hooks")"

[ "$failures" -eq 0 ] && echo "slot: all cases pass"
exit "$((failures > 0))"
