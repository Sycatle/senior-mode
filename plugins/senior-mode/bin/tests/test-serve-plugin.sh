#!/usr/bin/env bash
# Tests for the plugin version of `senior-mode serve` (spec 373 section 6, #782 and #784): the snapshot of the plugin per
# run and the switch to a newer installed version. The harness (stubs for gh, claude and the rest, the repository, config,
# board, session, once) is the head of test-serve.sh, up to its first case; the plugin that serve runs is a copy of this one,
# standing for the installed plugin.
# shellcheck disable=SC2154,SC2016 # variables and helpers of the harness, stub bodies
here=$(cd "$(dirname "$0")" && pwd)
harness=$(sed '/^# A: Ready tickets/,$d' "$here/test-serve.sh")
[[ $harness == *"once()"* ]] || {
  echo "FAIL: the head of test-serve.sh has no harness"
  exit 1
}
eval "$harness"

installed=$work/installed
cp -a "$here/../.." "$installed"
cli=$installed/bin/senior-mode
common=$(readlink -f "$repo/.git")
sd=$common/senior-mode/serve
# The snapshot directories under serve/plugin/.
snaps() { find "$sd/plugin" -mindepth 1 -maxdepth 1 -type d ! -name '.tmp.*' -printf '%f\n' 2>/dev/null | sort; }
# daemon <out>: serve in the background in $repo, its pid in $pid, until it has recorded its version.
daemon() {
  (cd "$repo" && exec "$cli" serve) >"$1" 2>&1 &
  pid=$!
  for _ in $(seq 200); do [ -s "$sd/version" ] && break; sleep 0.1; done
}
stop() {
  kill -TERM "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
}

config '{"parallel": 1}' '{"interval": 1, "grace": 30}'
board

# S1: at start the plugin is copied to serve/plugin/<version>-<sha>/, the daemon runs from the copy, version names it.
fresh
daemon "$work/out"
id=$(snaps)
[ "$(snaps | wc -l)" -eq 1 ] || fail "S1: not one snapshot: $(snaps)"
[[ $id == "$(jq -r .version "$installed/.claude-plugin/plugin.json")"-* ]] || fail "S1: the snapshot is not <version>-<sha>: $id"
[ "$(cat "$sd/version" 2>/dev/null)" = "$id" ] || fail "S1: version does not name the snapshot: $(cat "$sd/version" 2>&1)"
diff -r "$sd/plugin/$id" "$installed" >/dev/null || fail "S1: the snapshot is not a copy of the plugin"
cmd=$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null)
[[ $cmd == *"$sd/plugin/$id/bin/senior-mode"* ]] || fail "S1: the daemon does not run from the copy: $cmd"

# S2: the daemon already in the copy does not copy and execute again: same process, one snapshot, one start.
kill -0 "$pid" 2>/dev/null || fail "S2: the daemon is gone: $(cat "$work/out")"
[ "$(snaps | wc -l)" -eq 1 ] || fail "S2: more than one snapshot: $(snaps)"
[ "$(grep -c '^serve: polling every' "$work/out")" -eq 1 ] || fail "S2: serve started more than once: $(cat "$work/out")"
[ "$(cat "$sd/serve.pid" 2>/dev/null)" = "$pid" ] || fail "S2: the pid file does not name the daemon: $(cat "$sd/serve.pid" 2>&1)"

# S3: the installed plugin rewritten during the run: the session launches with --plugin-dir on the snapshot, unchanged.
cp -a "$installed" "$work/orig"
echo 'if then fi (' >>"$installed/bin/lib/doctor.sh"
board 60
session 60-sonnet delivered pr
for _ in $(seq 200); do [ -f "$FIX/args-60" ] && break; sleep 0.1; done
[ -f "$FIX/args-60" ] || fail "S3: no session started: $(cat "$work/out")"
grep -q -- "--plugin-dir $sd/plugin/$id\$" "$FIX/args-60" || fail "S3: the session is not on the snapshot: $(cat "$FIX/args-60" 2>&1)"
diff -r "$sd/plugin/$id" "$work/orig" >/dev/null || fail "S3: the snapshot changed with the installed plugin"
stop
rm -rf "$installed" && cp -a "$work/orig" "$installed"

# S4: the same installed version restarted reuses its directory.
touch "$sd/plugin/$id/marker"
board
once || fail "S4: serve failed: $(cat "$work/out")"
[ "$(snaps)" = "$id" ] && [ -f "$sd/plugin/$id/marker" ] || fail "S4: the snapshot was not reused: $(snaps)"

# S5: a snapshot directory that cannot be written: serve does not start and says why.
fresh
mkdir -p "$sd"
: >"$sd/plugin"
once && fail "S5: serve started without a snapshot"
grep -q 'cannot write the plugin snapshot' "$work/out" || fail "S5: not said why: $(cat "$work/out")"
[ ! -e "$sd/serve.pid" ] || fail "S5: serve left a pid file"

[ "$failures" -eq 0 ] && echo "serve plugin: all cases pass"
exit "$failures"
