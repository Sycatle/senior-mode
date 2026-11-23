#!/usr/bin/env bash
# Tests for the state files of serve and run (lib/state.sh, spec 373 section 3, #381): atomic writes, the lock,
# tolerant readers, and the check that keeps serve and run on the API. Offline, no gh.
set -u
here=$(cd "$(dirname "$0")" && pwd)
lib=$here/../lib
guard=$here/../../../../.github/scripts/state-writes.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

# shellcheck disable=SC1091 # the modules are definitions only
. "$lib/state.sh"
# shellcheck disable=SC1091
. "$lib/serve.sh"
SERVE_DIR=$work/serve
RUN_DIR=$SERVE_DIR
RUN_LAUNCH_LOG=$SERVE_DIR/launches
mkdir -p "$SERVE_DIR"

# A write replaces the file whole and leaves no temporary file.
echo old >"$SERVE_DIR/f"
echo new | state_write "$SERVE_DIR/f"
[ "$(cat "$SERVE_DIR/f")" = new ] || fail "write: the content is not the new one"
[ -z "$(find "$SERVE_DIR" -name '*.tmp.*')" ] || fail "write: a temporary file is left"
state_put "$SERVE_DIR/g" a b
[ "$(cat "$SERVE_DIR/g")" = "a b" ] || fail "put: $(cat "$SERVE_DIR/g")"

# A process killed after the temporary file is written and before the move: the old file is intact, the next start
# removes the temporary file of the dead writer and keeps that of a live one.
echo old >"$SERVE_DIR/k"
{ bash -c '. "$1"; mv() { kill -9 $$; }; state_write "$2" <<<new' _ "$lib/state.sh" "$SERVE_DIR/k"; } 2>/dev/null
[ "$(cat "$SERVE_DIR/k")" = old ] || fail "kill: the old file is not intact: $(cat "$SERVE_DIR/k")"
[ "$(find "$SERVE_DIR" -name 'k.tmp.*' | wc -l)" -eq 1 ] || fail "kill: no temporary file was left to remove: $(ls "$SERVE_DIR")"
echo live >"$SERVE_DIR/k.tmp.$$"
state_sweep "$SERVE_DIR"
[ "$(find "$SERVE_DIR" -name 'k.tmp.*' | wc -l)" -eq 1 ] && [ -e "$SERVE_DIR/k.tmp.$$" ] || fail "sweep: not only the temporary file of the dead writer: $(ls "$SERVE_DIR")"
touch -d '2 hours ago' "$SERVE_DIR/k.tmp.$$"
state_sweep "$SERVE_DIR"
[ -z "$(find "$SERVE_DIR" -name 'k.tmp.*')" ] || fail "sweep: a temporary file over an hour old is left"
[ "$(cat "$SERVE_DIR/k")" = old ] || fail "sweep: touched the file"
echo x >"$SERVE_DIR/c.corrupt-1"
touch -d '8 days ago' "$SERVE_DIR/c.corrupt-1"
echo x >"$SERVE_DIR/d.corrupt-1"
state_sweep "$SERVE_DIR"
[ ! -e "$SERVE_DIR/c.corrupt-1" ] && [ -e "$SERVE_DIR/d.corrupt-1" ] || fail "sweep: files set aside are kept 7 days: $(ls "$SERVE_DIR")"

# Readers: a missing file is the default and says nothing; one that does not parse is set aside, said once.
[ "$(state_num "$SERVE_DIR/none" 7 2>&1)" = 7 ] || fail "num: a missing file is not the default"
echo 42 >"$SERVE_DIR/n"
[ "$(state_num "$SERVE_DIR/n")" = 42 ] || fail "num: a number is not read"
echo 4x2 >"$SERVE_DIR/n"
out=$(state_num "$SERVE_DIR/n" 5 2>&1)
[[ $out == *"could not be read"* ]] && [[ $out == *$'\n5' ]] || fail "num: junk is not set aside with the default: $out"
[ ! -e "$SERVE_DIR/n" ] && [ "$(find "$SERVE_DIR" -name 'n.corrupt-*' | wc -l)" -eq 1 ] || fail "num: the junk file is not kept as .corrupt: $(ls "$SERVE_DIR")"
: >"$SERVE_DIR/e"
[ "$(state_num "$SERVE_DIR/e" 3 2>/dev/null)" = 3 ] && [ ! -e "$SERVE_DIR/e" ] || fail "num: an empty file is not set aside"
echo '{"cause": "disk"' >"$SERVE_DIR/j"
state_json "$SERVE_DIR/j" >/dev/null 2>&1 && fail "json: half a hold was read"
[ ! -e "$SERVE_DIR/j" ] || fail "json: half a hold is not set aside"
echo '{"cause": "disk"}' >"$SERVE_DIR/j"
[ "$(state_json "$SERVE_DIR/j" | jq -r .cause)" = disk ] || fail "json: a hold is not read"

# 20 appends and 20 trims of `launches` at once: no line is lost, none is torn.
: >"$RUN_LAUNCH_LOG"
for i in $(seq 20); do
  (printf '%s ticket\n' $((1800000000 + i)) | state_append "$RUN_LAUNCH_LOG") &
  (state_update serve_launch_trim 1799999999) &
done
wait
[ "$(wc -l <"$RUN_LAUNCH_LOG")" -eq 20 ] || fail "launches: $(wc -l <"$RUN_LAUNCH_LOG") lines of 20"
[ "$(grep -cE '^18000000[0-9][0-9] ticket$' "$RUN_LAUNCH_LOG")" -eq 20 ] || fail "launches: a torn line: $(cat "$RUN_LAUNCH_LOG")"
[ "$(sort -u "$RUN_LAUNCH_LOG" | wc -l)" -eq 20 ] || fail "launches: a line twice"
# A trim keeps the last hour, and a session that died at once takes back its own line.
state_put "$RUN_DIR/5.launched" "1800000005 ticket"
state_update serve_launch_drop 5
[ "$(wc -l <"$RUN_LAUNCH_LOG")" -eq 19 ] && ! grep -q '^1800000005 ticket$' "$RUN_LAUNCH_LOG" && [ ! -e "$RUN_DIR/5.launched" ] || fail "drop: not its own line: $(cat "$RUN_LAUNCH_LOG")"
state_update serve_launch_trim 1800000010
[ "$(wc -l <"$RUN_LAUNCH_LOG")" -eq 10 ] || fail "trim: $(wc -l <"$RUN_LAUNCH_LOG") lines left, want 10"

# A counter and a later-time keeper, 20 at once.
for i in $(seq 20); do
  (state_update state_counter_add "$SERVE_DIR/count" >/dev/null) &
  (state_update state_keep_later "$SERVE_DIR/later" $((100 + i))) &
done
wait
[ "$(cat "$SERVE_DIR/count")" = 20 ] || fail "counter: $(cat "$SERVE_DIR/count") of 20"
[ "$(cat "$SERVE_DIR/later")" = 120 ] || fail "later: $(cat "$SERVE_DIR/later")"

# A lock that is not got: the command does not run, the caller hears of it.
if command -v flock >/dev/null; then
  (flock 9 && sleep 3) 9>>"$SERVE_DIR/state.lock" &
  holder=$!
  sleep 0.3
  rm -f "$work/ran"
  out=$(SENIOR_MODE_LOCK_WAIT=1 state_update touch "$work/ran" 2>&1) && fail "lock: a busy lock was taken"
  [[ $out == *"state lock is busy"* ]] && [ ! -e "$work/ran" ] || fail "lock: the command ran or nothing was said: $out"
  wait "$holder"
  state_update touch "$work/ran" || fail "lock: a free lock was refused"
fi

# The check: a function that writes under the serve dir without state_write fails it.
cat >"$work/bad.sh" <<'SH'
serve_bad() {
  echo 1 >"$SERVE_DIR/limit-until"
}
SH
"$guard" "$work/bad.sh" >/dev/null 2>&1 && fail "check: a bare write under the serve dir passed"
"$guard" "$work/bad.sh" 2>&1 | grep -q 'bad.sh:2:' || fail "check: the line is not named"
cat >"$work/bad2.sh" <<'SH'
serve_bad() {
  mv "$SERVE_DIR/a.tmp" "$SERVE_DIR/a"
  git range-diff a b >"$RUN_DIR/x.range-diff"
}
SH
"$guard" "$work/bad2.sh" >/dev/null 2>&1 && fail "check: a mv or a capture under the serve dir passed"
cat >"$work/good.sh" <<'SH'
serve_good() {
  # echo 1 >"$SERVE_DIR/a" is written in a comment
  state_put "$SERVE_DIR/limit-until" 1
  git fetch 2>"$SERVE_DIR/x.err"
  echo 1 >"$SERVE_DIR/y" # state-ok: a stream
}
SH
"$guard" "$work/good.sh" || fail "check: the API, a comment, a stderr capture and a marked line were refused"
"$guard" || fail "check: run.sh or serve.sh writes under the serve dir without state_write"

[ "$failures" -eq 0 ] && echo "state: all cases pass"
exit "$failures"
