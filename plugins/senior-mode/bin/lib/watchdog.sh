#!/usr/bin/env bash
# The watchdog of serve's sessions (#384, spec 373 section 4): a session that is hung is stopped and resumed once, the
# processes a session left behind and the git locks of a dead process are removed. Definitions only.
# The minutes of autonomy.startupMinutes, autonomy.stallMinutes and autonomy.sessionTimeout are SENIOR_MODE_TIMEOUT_UNIT
# seconds long (60; the tests set 1). Time is the shell's own clock (SECONDS): the timers of a restarted serve start again.

# The cumulative CPU time, in seconds, of the processes of the group $1 and the pids of those that are not a wrapper
# (the shell of the script, claude, slot and flock): `<cpu> <pid>...`, a child that came or went changes it.
wd_group() {
  ps -A -o pid=,pgid=,cputime=,comm=,stat= 2>/dev/null | awk -v g="$1" '
    $2 == g && $5 !~ /^Z/ {
      split($3, a, /[-:]/)
      t = (split($3, a, /[-:]/) == 4) ? a[1] * 86400 + a[2] * 3600 + a[3] * 60 + a[4] : a[1] * 3600 + a[2] * 60 + a[3]
      cpu += t
      if ($4 !~ /^(bash|sh|claude|node|slot|flock|timeout|setsid|tmux)$/) pids = pids " " $1
    }
    END { print cpu + 0 pids }'
}

# The signals of the activity of session $1, three lines: the worktree (HEAD, the state of the files, the newest
# modification), its process group, its log. `.git` and node_modules are not looked at for the modifications.
wd_signals() {
  local n=$1 wt=${RUN_CWD[$1]:-${RUN_WT[$1]:-}} pgid log
  if [ -d "$wt" ]; then
    {
      git -C "$wt" rev-parse HEAD 2>/dev/null
      git -C "$wt" status --porcelain 2>/dev/null
      find "$wt" \( -name .git -o -name node_modules \) -prune -o -type f -printf '%T@\n' 2>/dev/null | sort -n | tail -n 1
    } | cksum
  else
    echo none
  fi
  pgid=$(cat "$RUN_DIR/$n.pgid" 2>/dev/null) || pgid=0
  [[ $pgid =~ ^[0-9]+$ ]] || pgid=0
  wd_group "$pgid"
  log="$RUN_DIR/$n-${RUN_MODEL[$n]:-sonnet}.log"
  stat -c %s "$log" 2>/dev/null || echo 0
}

# RUN_WATCH of serve (see run_reap), for a session that has not ended: its activity is looked at (at most once a second),
# and one that did nothing for autonomy.startupMinutes since its launch, or wrote no output and changed no file of its
# worktree for autonomy.stallMinutes (a process that only burns CPU is stalled), or that ran longer than the timeout of
# its ticket's Size (SERVE_TIMEOUT, ADR 0034), is stopped (wd_react). Returns 0 when it stopped the session.
wd_watch() {
  local n=$1 now=$SECONDS i unit=${SENIOR_MODE_TIMEOUT_UNIT:-60} why="" quiet="" last=0 base=true limit
  local -a cur=()
  [ "${WD_TICK[$n]:-}" != "$now" ] || return 1
  WD_TICK[$n]=$now
  mapfile -t cur < <(wd_signals "$n")
  if [ "${WD_START[$n]:-}" != "${RUN_STARTED[$n]}" ]; then
    # A session that is new for the watchdog (launched, or taken over): nothing is known of it yet.
    WD_START[$n]=${RUN_STARTED[$n]}
    for i in 0 1 2; do
      WD_SIG[$n.$i]=${cur[$i]}
      WD_BASE[$n.$i]=${cur[$i]}
      WD_AT[$n.$i]=$now
    done
    return 1
  fi
  local -a name=(worktree "process group" log)
  for i in 0 1 2; do
    if [ "${WD_SIG[$n.$i]}" != "${cur[$i]}" ]; then
      WD_SIG[$n.$i]=${cur[$i]}
      WD_AT[$n.$i]=$now
    fi
    [ "${WD_SIG[$n.$i]}" = "${WD_BASE[$n.$i]}" ] || base=false
    # The process group shows life at startup, not progress: `last` is the newest change of the worktree or the log.
    [ "$i" = 1 ] && continue
    [ "${WD_AT[$n.$i]}" -le "$last" ] || last=${WD_AT[$n.$i]}
    [ $((now - ${WD_AT[$n.$i]})) -lt $((SERVE_STALL * unit)) ] || quiet+="${quiet:+, }${name[$i]}"
  done
  limit=${SERVE_TIMEOUT[${SERVE_SIZE[$n]:-M}]:-${SERVE_TIMEOUT[M]:-$RUN_TIMEOUT}}
  if [ $((now - RUN_STARTED[$n])) -ge $((limit * unit)) ]; then
    why="timed out after $limit minute$([ "$limit" -eq 1 ] || echo s) (autonomy.sessionTimeout, Size ${SERVE_SIZE[$n]:-M})"
  elif [ "$base" = true ] && [ $((now - RUN_STARTED[$n])) -ge $((SERVE_STARTUP_MIN * unit)) ]; then
    why="hung at startup: no sign of life in $SERVE_STARTUP_MIN minute$([ "$SERVE_STARTUP_MIN" -eq 1 ] || echo s) (autonomy.startupMinutes)"
  elif [ $((now - last)) -ge $((SERVE_STALL * unit)) ]; then
    why="hung: nothing moved for $SERVE_STALL minute$([ "$SERVE_STALL" -eq 1 ] || echo s) (autonomy.stallMinutes); quiet: ${quiet:-none}"
  fi
  [ -n "$why" ] || return 1
  wd_react "$n" "$why"
}

# The session $1 is stopped, its group first with TERM, then with KILL (run_kill). The first stop of a ticket's session
# is an interruption, not a failure: the ticket goes back to Ready and its session resumes, with a fresh timer, from its
# worktree and its pull request (serve_transient; `<n>.resumed` counts the stops). The second stop is the ticket's:
# needs-human with the log, counted for the breaker.
wd_react() {
  local n=$1 why=$2 count
  echo "#$n: the session is stopped, $why" >&2
  run_kill "$n" "#$n"
  unset "WD_START[$n]"
  count=$(state_update state_counter_add "$SERVE_DIR/$n.resumed") || count=2
  if [ "$count" -le 1 ]; then
    printf '\nThe previous session of this ticket was stopped (%s). Its work is in this worktree and on its branch: continue from there, and from the pull request if one exists, do not start over.\n' \
      "$why" | state_append "$RUN_DIR/$n.prompt"
    serve_transient "$n" interrupted "$why"
  else
    run_halt "$n" "$why" "$RUN_DIR/$n-${RUN_MODEL[$n]}.log" \
      "An autonomous senior-mode serve stopped this ticket's session a second time" "The session log is"
  fi
  return 0
}

# The processes that a session left behind (its group, after its exit file): killed when every one of them runs inside
# the session's worktree, so that a reused group number is never signalled. Run at every poll, for the sessions serve
# does not track any more.
wd_orphans() {
  local f n pgid wt p live others
  for f in "$SERVE_DIR"/*.exit; do
    [ -e "$f" ] || continue
    n=$(basename "$f" .exit)
    [[ $n =~ ^[0-9]+$ ]] || continue
    [[ " ${running[*]-} " != *" $n "* ]] || continue
    pgid=$(cat "$SERVE_DIR/$n.pgid" 2>/dev/null) || continue
    [[ $pgid =~ ^([2-9]|[1-9][0-9]+)$ ]] || continue
    [ "$pgid" != "$(ps -o pgid= -p $$ | tr -d ' ')" ] || continue
    wt=$(jq -r '.cwd // "" | if . == "" then empty else . end' "$SERVE_DIR/$n.meta" 2>/dev/null) ||
      wt=""
    [ -n "$wt" ] || wt=$(jq -r '.worktree // ""' "$SERVE_DIR/$n.meta" 2>/dev/null) || continue
    [ -n "$wt" ] || continue
    live=$(ps -A -o pid=,pgid=,stat= 2>/dev/null | awk -v g="$pgid" '$2 == g && $3 !~ /^Z/ {print $1}')
    [ -n "$live" ] || continue
    others=false
    for p in $live; do
      case $(readlink "/proc/$p/cwd" 2>/dev/null) in
        "$wt" | "$wt"/*) ;;
        *) others=true ;;
      esac
    done
    [ "$others" = false ] || continue
    echo "serve: #$n: killing $(wc -w <<<"$live") process(es) its session left behind"
    # shellcheck disable=SC2086 # pids
    kill -TERM $live 2>/dev/null || true
    sleep 0.2
    # shellcheck disable=SC2086
    kill -KILL $live 2>/dev/null || true
  done
}

# The index.lock of a git directory (the main one, the worktrees) older than 10 minutes with no git process running in
# its repository: its writer died, it is removed (spec 373 section 3, rule 6).
wd_locks() {
  local path gd p busy
  while IFS= read -r path; do
    gd=$(git -C "$path" rev-parse --absolute-git-dir 2>/dev/null) || continue
    [ -f "$gd/index.lock" ] || continue
    [ -n "$(find "$gd/index.lock" -mmin +10 2>/dev/null)" ] || continue
    busy=false
    for p in $(ps -A -o pid=,comm= 2>/dev/null | awk '$2 == "git" {print $1}'); do
      case $(readlink "/proc/$p/cwd" 2>/dev/null) in
        "$path" | "$path"/*) busy=true ;;
      esac
    done
    [ "$busy" = false ] || continue
    if rm -f "$gd/index.lock"; then echo "serve: removed the stale $gd/index.lock"; fi
  done < <(git worktree list --porcelain | sed -n 's/^worktree //p')
}
