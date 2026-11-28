#!/usr/bin/env bash
# Tests for serve's config reload (lib/serve-config.sh, #681): the step serve_step_05_config_reload and the status section
# serveconfig. Offline: a repository whose main branch carries .claude/senior-mode.json, the step called as serve_loop calls it.
# shellcheck disable=SC1090,SC2034 # the modules are sourced by name, and the variables are read by the step, as serve_loop's locals
set -u
here=$(cd "$(dirname "$0")" && pwd)
LIB=$here/../lib
SELF=$here/../senior-mode
work=$(mktemp -d)
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$work"' EXIT
failures=0

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

set -e
for m in common config workflow state serve serve-launch serve-config; do . "$LIB/$m.sh"; done
set +e
# shellcheck disable=SC1091
. "$LIB/status.d/serveconfig.sh"

repo=$work/repo
mkdir -p "$repo/.claude"
cd "$repo" || exit 1
export HOME=$work SENIOR_MODE_CONFIG_SOURCE=base
git init -q -b main . && git config user.email t@t && git config user.name t
setcfg() { printf '%s\n' "$1" >.claude/senior-mode.json && git add -A && git commit -qm "$2"; }
setcfg '{"autonomy": {"parallel": 4, "maxConsecutiveFailures": 3}, "serve": {"interval": 60}}' base
common=$(git rev-parse --path-format=absolute --git-common-dir)
SERVE_DIR=$common/senior-mode/serve
mkdir -p "$SERVE_DIR"

# What serve_loop holds, as the step sees it.
SERVE_TERM=false
RUN_MAXFAIL=3 SERVE_PARALLEL=4 SERVE_PER_HOUR=24 interval=60 RUN_FAILS=0 SERVE_HELD="" RUN_ESCALATE=true RUN_MERGE=true RUN_GLOBS='[]'
running=()

# The first turn only records what serve runs with, and says nothing.
out=$(serve_step_05_config_reload 2>&1)
[ -z "$out" ] || fail "first turn: said $out"
serve_step_05_config_reload >/dev/null 2>&1 # the first turn must run in this shell: the trap and the table live here
[ "$(jq -r '.["autonomy.parallel"]' "$SERVE_DIR/config.running")" = 4 ] || fail "first turn: config.running holds $(cat "$SERVE_DIR/config.running")"

# A merged change of maxConsecutiveFailures is in force at the next poll, and the log names the key, the old and the new value.
setcfg '{"autonomy": {"parallel": 4, "maxConsecutiveFailures": 5}, "serve": {"interval": 60}}' failures
serve_step_05_config_reload >"$work/out" 2>&1
[ "$RUN_MAXFAIL" = 5 ] || fail "reload: RUN_MAXFAIL is $RUN_MAXFAIL"
grep -qx 'serve: config reloaded: autonomy.maxConsecutiveFailures 3 -> 5' "$work/out" || fail "reload: log is $(cat "$work/out")"
[ "$(wc -l <"$work/out")" -eq 1 ] || fail "reload: more than the one key logged: $(cat "$work/out")"
serve_step_05_config_reload >"$work/out" 2>&1
[ ! -s "$work/out" ] || fail "no change: said $(cat "$work/out")"

# parallel 4 -> 2 with 3 sessions running: they are left alone, and nothing starts until fewer than 2 run.
running=(11 12 13)
setcfg '{"autonomy": {"parallel": 2, "maxConsecutiveFailures": 5}, "serve": {"interval": 60}}' parallel
serve_step_05_config_reload >"$work/out" 2>&1
[ "$SERVE_PARALLEL" = 2 ] || fail "parallel: SERVE_PARALLEL is $SERVE_PARALLEL"
[ "${#running[@]}" -eq 3 ] || fail "parallel: the running sessions changed"
serve_can_launch 2>/dev/null && fail "parallel: a session may start with 3 running of 2"
running=(11 12)
serve_can_launch 2>/dev/null && fail "parallel: a session may start with 2 running of 2"
# A key that applies at the next sleep: the interval.
setcfg '{"autonomy": {"parallel": 2, "maxConsecutiveFailures": 5}, "serve": {"interval": 30}}' interval
serve_step_05_config_reload >"$work/out" 2>&1
[ "$interval" = 30 ] || fail "interval: $interval"

# SIGHUP ends the sleep at once, and the reload says why.
SECONDS=0
sleep 30 &
sleeper=$!
(sleep 1; kill -HUP $$) &
wait "$sleeper"
kill "$sleeper" 2>/dev/null
[ "$SECONDS" -lt 10 ] || fail "SIGHUP: the sleep went on for $SECONDS s"
[ "$SERVE_HUP" = true ] || fail "SIGHUP: not noted"
setcfg '{"autonomy": {"parallel": 2, "maxConsecutiveFailures": 6}, "serve": {"interval": 30}}' hup
serve_step_05_config_reload >"$work/out" 2>&1
grep -qx 'serve: config reloaded (SIGHUP): autonomy.maxConsecutiveFailures 5 -> 6' "$work/out" || fail "SIGHUP: log is $(cat "$work/out")"
[ "$SERVE_HUP" = false ] || fail "SIGHUP: still noted after the reload"

# status: the running settings against the default branch's. Nothing differs, then a merged change not yet read.
bash -c 'exec -a senior-mode-serve-stub sleep 60' &
printf '%s\n' "$!" >"$SERVE_DIR/serve.pid"
sleep 0.2
res=$(status_section_serveconfig_json)
[ "$(jq -c .serveConfig <<<"$res")" = '{"differs":false,"keys":[]}' ] || fail "status: differs with nothing changed: $res"
setcfg '{"autonomy": {"parallel": 3, "maxConsecutiveFailures": 6}, "serve": {"interval": 20}}' later
res=$(status_section_serveconfig_json)
[ "$(jq -c .serveConfig <<<"$res")" = '{"differs":true,"keys":["autonomy.parallel","serve.interval"]}' ] || fail "status: $res"

# An invalid config: the settings stand, nothing is said as reloaded, status says nothing.
setcfg '{"autonomy": {"parallel": "many"}}' invalid
serve_step_05_config_reload >"$work/out" 2>&1
grep -q 'config reloaded' "$work/out" && fail "invalid: reloaded: $(cat "$work/out")"
[ "$SERVE_PARALLEL" = 2 ] && [ "$RUN_MAXFAIL" = 6 ] || fail "invalid: the settings moved: $SERVE_PARALLEL $RUN_MAXFAIL"
res=$(status_section_serveconfig_json 2>/dev/null)
[ "$(jq -c .serveConfig.differs <<<"$res")" = false ] || fail "status: differs on an invalid config: $res"

[ "$failures" -eq 0 ] && echo "ok: serve config" || exit 1
