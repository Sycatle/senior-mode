#!/usr/bin/env bash
# Tests for `senior-mode schedule`. Offline: systemctl, crontab, loginctl, journalctl and id are stubs
# on PATH. systemctl logs its calls to $SYS_LOG and fails `--user show-environment` when
# $FIX/no-systemd exists; crontab keeps its table in $FIX/crontab (and fails `-l` with a real error while
# $FIX/cron-broken exists, logging any write to $FIX/cron-writes); loginctl answers from $FIX/linger.
# shellcheck disable=SC2016 # stub bodies, not expanded here
set -u
cli=$(cd "$(dirname "$0")/.." && pwd)/senior-mode
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

mkdir -p "$work/stub" "$work/fix" "$work/home"
cat >"$work/stub/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$SYS_LOG"
case "$*" in
  "--user show-environment") [ ! -f "$FIX/no-systemd" ] ;;
  *"show "*NextElapse*) echo "NextElapseUSecRealtime=Sun 2026-11-22 03:30:00 UTC" ;;
  *"show "*)
    echo "Result=success"
    echo "ExecMainStatus=0"
    echo "ExecMainExitTimestamp=Sat 2026-11-21 03:41:10 UTC" ;;
esac
STUB
cat >"$work/stub/crontab" <<'STUB'
#!/usr/bin/env bash
[ "$1" = -l ] || [ ! -f "$FIX/cron-broken" ] || echo "$1" >>"$FIX/cron-writes"
case $1 in
  -l) [ ! -f "$FIX/cron-broken" ] || { echo "crontab: cannot read the spool: Permission denied" >&2; exit 1; }
    [ -f "$FIX/crontab" ] && cat "$FIX/crontab" || { echo "no crontab for $USER" >&2; exit 1; } ;;
  -) cat >"$FIX/crontab" ;;
esac
STUB
cat >"$work/stub/loginctl" <<'STUB'
#!/usr/bin/env bash
echo "Linger=$(cat "$FIX/linger")"
STUB
cat >"$work/stub/journalctl" <<'STUB'
#!/usr/bin/env bash
echo "Merged: #7 Ticket seven"
STUB
cat >"$work/stub/id" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = -u ] && [ -f "$FIX/as-root" ]; then echo 0; else exec /usr/bin/id "$@"; fi
STUB
chmod +x "$work/stub/"*
export PATH="$work/stub:$PATH" FIX="$work/fix" SYS_LOG="$work/sys.log" HOME="$work/home" USER=tester
unset XDG_CONFIG_HOME
echo no >"$FIX/linger"

repo="$work/my app"
git init -q -b main "$repo"
mkdir -p "$repo/.claude"
config() { echo "${1:-{\}}" >"$repo/.claude/senior-mode.json"; }
sched() { : >"$SYS_LOG"; (cd "$repo" && "$cli" schedule "$@") >"$work/out" 2>&1; }
units="$HOME/.config/systemd/user"
timer="$units/senior-mode-run-my-app.timer"
service="$units/senior-mode-run-my-app.service"

# A: install with systemd.
config '{}'
sched install --at 03:30 --max 2 || fail "A: install failed: $(cat "$work/out")"
[ -f "$timer" ] && [ -f "$service" ] || fail "A: unit files missing in $units"
grep -qx 'OnCalendar=\*-\*-\* 03:30:00' "$timer" || fail "A: OnCalendar wrong: $(cat "$timer" 2>&1)"
grep -qx 'Persistent=true' "$timer" || fail "A: timer is not persistent"
grep -qx 'WantedBy=timers.target' "$timer" || fail "A: timer has no [Install] target"
grep -q '^ExecStart=/bin/bash -lc ".*bin/senior-mode'"'"' run --max 2"$' "$service" || fail "A: ExecStart wrong: $(cat "$service" 2>&1)"
grep -q "cd '$repo' &&" "$service" || fail "A: the unit does not start in the repository"
grep -qx -- '--user daemon-reload' "$SYS_LOG" || fail "A: no daemon-reload: $(cat "$SYS_LOG")"
grep -qx -- '--user enable --now senior-mode-run-my-app.timer' "$SYS_LOG" || fail "A: timer not enabled: $(cat "$SYS_LOG")"
grep -q 'sudo loginctl enable-linger tester' "$work/out" || fail "A: no linger warning: $(cat "$work/out")"
cp "$timer" "$work/timer.1"
echo yes >"$FIX/linger"
sched install --at 03:30 --max 2 || fail "A: second install failed"
cmp -s "$timer" "$work/timer.1" || fail "A: reinstalling changed the timer"
grep -q 'enable-linger' "$work/out" && fail "A: linger warning although linger is on"

# B: defaults: 02:00 without config key, autonomy.schedule when set, no --max when not given.
sched install || fail "B: install failed: $(cat "$work/out")"
grep -qx 'OnCalendar=\*-\*-\* 02:00:00' "$timer" || fail "B: default time is not 02:00"
grep -q -- '--max' "$service" && fail "B: --max written although not given"
config '{"autonomy": {"schedule": "04:15"}}'
sched install || fail "B: install failed with a configured time"
grep -qx 'OnCalendar=\*-\*-\* 04:15:00' "$timer" || fail "B: autonomy.schedule ignored"
sched install --at 05:00 || fail "B: install failed"
grep -qx 'OnCalendar=\*-\*-\* 05:00:00' "$timer" || fail "B: --at does not win over the config"

# C: status with systemd.
sched status || fail "C: status failed: $(cat "$work/out")"
grep -q 'next.*2026-11-22 03:30:00' "$work/out" || fail "C: next trigger missing: $(cat "$work/out")"
grep -q 'last.*2026-11-21 03:41:10.*success' "$work/out" || fail "C: last result missing: $(cat "$work/out")"
grep -q 'Merged: #7' "$work/out" || fail "C: journal tail missing: $(cat "$work/out")"

# D: remove, twice.
sched remove || fail "D: remove failed: $(cat "$work/out")"
[ ! -e "$timer" ] && [ ! -e "$service" ] || fail "D: unit files still there"
grep -qx -- '--user disable --now senior-mode-run-my-app.timer' "$SYS_LOG" || fail "D: timer not disabled: $(cat "$SYS_LOG")"
sched remove || fail "D: second remove failed: $(cat "$work/out")"
grep -q 'Nothing scheduled' "$work/out" || fail "D: second remove did not say so: $(cat "$work/out")"
sched status || fail "D: status failed when nothing is scheduled"
grep -q 'not scheduled' "$work/out" || fail "D: status does not say it is not scheduled: $(cat "$work/out")"

# E: cron fallback, tagged and idempotent; other entries are kept.
touch "$FIX/no-systemd"
printf '0 5 * * * echo other\n' >"$FIX/crontab"
config '{}'
sched install --at 03:30 --max 2 || fail "E: install failed: $(cat "$work/out")"
sched install --at 03:30 --max 2 || fail "E: second install failed"
[ "$(grep -c '# senior-mode-run:my-app$' "$FIX/crontab")" = 1 ] || fail "E: expected one tagged line: $(cat "$FIX/crontab")"
grep -q '^30 3 \* \* \* /bin/bash -lc ".*run --max 2" >>.*schedule.log'"'"' 2>&1 # senior-mode-run:my-app$' "$FIX/crontab" ||
  fail "E: cron line wrong: $(cat "$FIX/crontab")"
grep -qx '0 5 \* \* \* echo other' "$FIX/crontab" || fail "E: the other cron entry was lost"
[ ! -e "$timer" ] || fail "E: a systemd unit was written while systemd is unavailable"
grep -q 'enable-linger' "$work/out" && fail "E: linger warning for cron"
mkdir -p "$repo/.git/senior-mode"
printf 'run: 1 ticket(s)\nMerged: #9 Ticket nine\n' >"$repo/.git/senior-mode/schedule.log"
sched status || fail "E: status failed: $(cat "$work/out")"
{ grep -q 'cron' "$work/out" && grep -q 'next.*03:30' "$work/out"; } || fail "E: cron next trigger missing: $(cat "$work/out")"
grep -q 'Merged: #9' "$work/out" || fail "E: cron last result missing: $(cat "$work/out")"
sched remove || fail "E: remove failed: $(cat "$work/out")"
grep -q 'senior-mode-run' "$FIX/crontab" && fail "E: tagged line survived remove"
grep -qx '0 5 \* \* \* echo other' "$FIX/crontab" || fail "E: remove dropped the other cron entry"
sched remove || fail "E: second remove failed"
grep -q 'Nothing scheduled' "$work/out" || fail "E: second cron remove did not say so"
rm -f "$FIX/no-systemd"

# G: crontab -l failing for a real reason: install and remove stop and change nothing.
sched install --at 03:30 || fail "G: setup install failed"
cp "$timer" "$work/timer.g"
touch "$FIX/no-systemd"
printf '0 5 * * * echo other\n' >"$FIX/crontab"
cp "$FIX/crontab" "$work/crontab.g"
touch "$FIX/cron-broken"
sched install --at 03:30 && fail "G: cron install accepted a failing crontab -l"
grep -q 'crontab' "$work/out" || fail "G: cron install did not explain: $(cat "$work/out")"
rm -f "$FIX/no-systemd"
sched install --at 06:00 && fail "G: systemd install accepted a failing crontab -l"
cmp -s "$timer" "$work/timer.g" || fail "G: a refused install changed the timer"
sched remove && fail "G: remove accepted a failing crontab -l"
grep -q 'crontab' "$work/out" || fail "G: remove did not explain: $(cat "$work/out")"
[ -f "$timer" ] && [ -f "$service" ] || fail "G: a refused remove deleted the units"
[ ! -e "$FIX/cron-writes" ] || fail "G: crontab was written: $(cat "$FIX/cron-writes")"
cmp -s "$FIX/crontab" "$work/crontab.g" || fail "G: the crontab changed"
rm -f "$FIX/cron-broken"
sched remove || fail "G: cleanup remove failed"

# F: refusals.
sched install --at 25:00 && fail "F: --at 25:00 accepted"
sched install --at 3h && fail "F: --at 3h accepted"
sched install --max 0 && fail "F: --max 0 accepted"
sched bogus && fail "F: unknown subcommand accepted"
sched && fail "F: no subcommand accepted"
touch "$FIX/as-root"
sched install && fail "F: install accepted as root"
grep -q 'root' "$work/out" || fail "F: root refusal not explained: $(cat "$work/out")"
rm -f "$FIX/as-root"
[ -e "$timer" ] && fail "F: a refused install wrote a unit"

# H: a live serve in this repository: install refuses, status says serve runs; without one, install works.
sched install --at 03:30 || fail "H: setup install failed"
cp "$timer" "$work/timer.h"
(exec -a senior-mode-serve sleep 60) &
serve_pid=$!
mkdir -p "$repo/.git/senior-mode/serve"
echo "$serve_pid" >"$repo/.git/senior-mode/serve/serve.pid"
sched status || fail "H: status failed: $(cat "$work/out")"
grep -q "serve: runs in this repository (pid $serve_pid)" "$work/out" || fail "H: status does not say serve runs: $(cat "$work/out")"
sched remove || fail "H: remove failed with serve running"
sched install --at 06:00 && fail "H: install accepted while serve runs"
grep -q 'serve already runs' "$work/out" || fail "H: refusal does not say serve runs: $(cat "$work/out")"
grep -q 'redundant' "$work/out" || fail "H: refusal does not say the batch is redundant: $(cat "$work/out")"
grep -q 'serve --uninstall' "$work/out" || fail "H: refusal does not name serve --uninstall: $(cat "$work/out")"
[ ! -e "$timer" ] && [ ! -s "$SYS_LOG" ] || fail "H: a refused install wrote a unit or called systemctl"
kill "$serve_pid" 2>/dev/null
wait "$serve_pid" 2>/dev/null
sched install --at 03:30 || fail "H: install failed once serve is gone: $(cat "$work/out")"
cmp -s "$timer" "$work/timer.h" || fail "H: install without serve differs from before"
sched status || fail "H: status failed"
grep -q 'serve: does not run' "$work/out" || fail "H: status does not say serve is absent: $(cat "$work/out")"
sched remove

[ "$failures" -eq 0 ] && echo "schedule: all cases pass"
exit "$((failures > 0))"
