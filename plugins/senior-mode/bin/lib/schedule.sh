# shellcheck shell=bash
# Where `schedule` keeps things for this repository (ADR 0012). The name is the main checkout's folder.
schedule_paths() {
  local common
  common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || die "not inside a git repository"
  SCHED_ROOT=$(dirname "$common")
  SCHED_NAME=$(printf '%s' "$(basename "$SCHED_ROOT")" | tr -c 'A-Za-z0-9_.-' '-')
  SCHED_UNIT=senior-mode-run-$SCHED_NAME
  SCHED_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user
  SCHED_LOG=$common/senior-mode/schedule.log
  SCHED_TAG="# senior-mode-run:$SCHED_NAME"
}

# The pid of the `serve` running in this repository, empty when there is none (same test as `serve` itself).
schedule_serve_pid() {
  local pid
  pid=$(cat "$(dirname "$SCHED_LOG")/serve/serve.pid" 2>/dev/null) || return 0
  [[ $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null && [[ $(ps -o args= -p "$pid" 2>/dev/null) == *senior-mode* ]] && printf '%s' "$pid"
  return 0
}

# Stops unless the crontab is readable or empty: rewriting a table we could not read would erase it.
schedule_cron_check() {
  local out
  command -v crontab >/dev/null || return 0
  out=$(crontab -l 2>&1) || [[ $out == *"no crontab"* ]] || die "crontab -l failed, so the schedule is left untouched: $out"
}

# The crontab without this repository's tagged line, order kept.
schedule_cron_without() {
  local line
  crontab -l 2>/dev/null | while IFS= read -r line; do
    [[ $line == *"$SCHED_TAG" ]] || printf '%s\n' "$line"
  done || true
}

# This repository's tagged crontab line, if any.
schedule_cron_line() {
  local line
  command -v crontab >/dev/null || return 0
  crontab -l 2>/dev/null | while IFS= read -r line; do
    [[ $line != *"$SCHED_TAG" ]] || printf '%s\n' "$line"
  done || true
}

schedule_cron_remove() {
  local table
  command -v crontab >/dev/null && [ -n "$(schedule_cron_line)" ] || return 1
  table=$(schedule_cron_without)
  if [ -n "$table" ]; then printf '%s\n' "$table" | crontab -; else crontab -r 2>/dev/null || printf '' | crontab -; fi
}

# senior-mode schedule install [--at HH:MM] [--max N] | remove | status: the nightly batch, a daily `senior-mode run` on
# this machine, as a systemd user timer or, without a user systemd, a tagged crontab line (ADR 0012).
schedule() {
  local sub=${1:-} at="" max="" cmd table mech="" line m h ts props unit me pid
  [ $# -eq 0 ] || shift
  schedule_paths
  unit=$SCHED_UNIT
  case $sub in
    install)
      while [ $# -gt 0 ]; do
        case $1 in
          --at)
            [[ ${2:-} =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || die "schedule --at needs a time as HH:MM"
            at=$2
            shift
            ;;
          --max)
            [[ ${2:-} =~ ^[1-9][0-9]*$ ]] || die "schedule --max needs a positive number"
            max=$2
            shift
            ;;
          *) usage ;;
        esac
        shift
      done
      pid=$(schedule_serve_pid)
      [ -z "$pid" ] || die "serve already runs in this repository (pid $pid): a nightly batch is redundant; to schedule it anyway, stop the daemon with: senior-mode serve --uninstall"
      [ "$(id -u)" != 0 ] || die "schedule cannot work as root: run refuses to skip permission prompts for root; use a normal user"
      schedule_cron_check
      at=${at:-$(config_get autonomy.schedule)}
      [[ $at =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || die "autonomy.schedule must be a time as HH:MM, not $at"
      [[ $SCHED_ROOT$SELF != *[\'\"\\%\$\`]* ]] || die "schedule: a path holds a quote, a backslash, % or \$, which a unit cannot carry"
      # A login shell, so the agent.command CLI (claude by default) is on PATH; run also looks in ~/.local/bin.
      cmd="cd '$SCHED_ROOT' && '$SELF' run${max:+ --max $max}"
      me=${USER:-$(id -un)}
      if command -v systemctl >/dev/null && systemctl --user show-environment >/dev/null 2>&1; then
        mkdir -p "$SCHED_DIR"
        cat >"$SCHED_DIR/$unit.service" <<UNIT
[Unit]
Description=senior-mode run in $SCHED_ROOT

[Service]
Type=oneshot
ExecStart=/bin/bash -lc "$cmd"
UNIT
        cat >"$SCHED_DIR/$unit.timer" <<UNIT
[Unit]
Description=Daily senior-mode run in $SCHED_ROOT

[Timer]
OnCalendar=*-*-* $at:00
Persistent=true

[Install]
WantedBy=timers.target
UNIT
        schedule_cron_remove || true
        systemctl --user daemon-reload
        systemctl --user enable --now "$unit.timer" || die "systemctl --user could not enable $unit.timer"
        echo "scheduled: systemd user timer $unit.timer, every day at $at; logs: journalctl --user -u $unit"
        if ! loginctl show-user "$me" -p Linger 2>/dev/null | grep -qx 'Linger=yes'; then
          echo "warning: linger is off, so the timer only fires while you are logged in; run: sudo loginctl enable-linger $me" >&2
        fi
      else
        command -v crontab >/dev/null || die "neither systemctl --user nor crontab is available"
        mkdir -p "$(dirname "$SCHED_LOG")"
        table=$(schedule_cron_without)
        { [ -z "$table" ] || printf '%s\n' "$table"; printf '%s\n' "$((10#${at#*:})) $((10#${at%:*})) * * * /bin/bash -lc \"$cmd\" >>'$SCHED_LOG' 2>&1 $SCHED_TAG"; } | crontab -
        echo "scheduled: crontab line tagged \"$SCHED_TAG\", every day at $at; log: $SCHED_LOG"
      fi
      ;;
    remove)
      [ $# -eq 0 ] || usage
      schedule_cron_check
      if [ -e "$SCHED_DIR/$unit.timer" ] || [ -e "$SCHED_DIR/$unit.service" ]; then
        mech=systemd
        if command -v systemctl >/dev/null; then systemctl --user disable --now "$unit.timer" >/dev/null 2>&1 || true; fi
        rm -f "$SCHED_DIR/$unit.timer" "$SCHED_DIR/$unit.service"
        if command -v systemctl >/dev/null; then systemctl --user daemon-reload >/dev/null 2>&1 || true; fi
      fi
      if schedule_cron_remove; then mech=${mech:+$mech and }cron; fi
      if [ -n "$mech" ]; then echo "removed: the $mech schedule of $SCHED_NAME"; else echo "Nothing scheduled for $SCHED_NAME."; fi
      ;;
    status)
      [ $# -eq 0 ] || usage
      line=$(schedule_cron_line)
      if [ -e "$SCHED_DIR/$unit.timer" ]; then
        echo "scheduled: systemd user timer $unit.timer"
        ts=$(systemctl --user show "$unit.timer" -p NextElapseUSecRealtime 2>/dev/null | sed -n 's/^NextElapseUSecRealtime=//p')
        echo "next trigger: ${ts:-unknown}"
        props=$(systemctl --user show "$unit.service" -p Result -p ExecMainStatus -p ExecMainExitTimestamp 2>/dev/null || true)
        ts=$(sed -n 's/^ExecMainExitTimestamp=//p' <<<"$props")
        if [ -n "$ts" ]; then
          echo "last run: $ts, result $(sed -n 's/^Result=//p' <<<"$props") (exit $(sed -n 's/^ExecMainStatus=//p' <<<"$props"))"
          if command -v journalctl >/dev/null; then journalctl --user -u "$unit" -n 5 --no-pager -o cat 2>/dev/null | sed 's/^/  /' || true; fi
        else
          echo "last run: none yet"
        fi
      elif [ -n "$line" ]; then
        read -r m h _ <<<"$line"
        ts=$(date -d "$h:$m" +%s)
        [ "$ts" -gt "$(date +%s)" ] || ts=$(date -d "tomorrow $h:$m" +%s)
        echo "scheduled: cron line tagged \"$SCHED_TAG\""
        echo "next trigger: $(date -d "@$ts" '+%Y-%m-%d %H:%M')"
        if [ -s "$SCHED_LOG" ]; then
          echo "last run: $(date -r "$SCHED_LOG" '+%Y-%m-%d %H:%M'), end of $SCHED_LOG:"
          tail -n 5 "$SCHED_LOG" | sed 's/^/  /'
        else
          echo "last run: none yet"
        fi
      else
        echo "not scheduled; install it with: senior-mode schedule install [--at HH:MM] [--max N]"
      fi
      pid=$(schedule_serve_pid)
      if [ -n "$pid" ]; then echo "serve: runs in this repository (pid $pid)"; else echo "serve: does not run in this repository"; fi
      ;;
    *) usage ;;
  esac
}
