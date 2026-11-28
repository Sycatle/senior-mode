# shellcheck shell=bash
# Seconds since the epoch; SENIOR_MODE_NOW stands in for the clock in the tests.
serve_now() {
  echo "${SENIOR_MODE_NOW:-$(date +%s)}"
}

# A whole number from the config, at least $2: serve_int <key> <min>.
serve_int() {
  local v
  v=$(config_get "$1")
  [[ $v =~ ^[0-9]+$ ]] && [ "$v" -ge "$2" ] || die "$1 must be a whole number of at least $2, not $v"
  echo "$v"
}

# One poll: reads the sessions that ended, trips the breaker, then looks at the pull requests In review
# (reviewer sessions, the ticket sessions resumed with findings, at most one merge) and, unless held or at a
# ceiling, starts the Ready tickets in `pick` order while there is a free slot. A hold (breaker, usage limit)
# stops every launch, reviewers and integrator sessions included; a merge needs no session and goes on.
serve_poll() {
  local now reason data prs n size title batch begins capped ticket_wait="" started_before diag cause why reserved garden="" garden_said=false waiting
  local -a queue=()
  now=$(serve_now)
  RUN_STOP=""
  SERVE_HELD="" SERVE_GUARDS="" SERVE_WAIT="" SERVE_FP="" SERVE_PRS="[]"
  rm -f "$GH_DOWN_FILE"
  run_reap
  wd_orphans
  wd_locks
  serve_report
  serve_breaker
  if SERVE_HELD=$(serve_hold "$now"); then
    echo "serve: not launching: $SERVE_HELD"
  fi
  # The cheap probes at every poll, unless a hold or a pause is already on: a machine that went bad while nothing ran
  # (a full disk, gh signed out, a red main) holds the launches before a session fails on it.
  if [ -z "$SERVE_HELD" ] && diag=$(serve_probe_cheap); then
    IFS='|' read -r cause why <<<"$diag"
    if [ "$cause" = disk ]; then
      serve_disk_clean
      if why=$(serve_probe disk); then diag=""; fi
    fi
  fi
  if [ -z "$SERVE_HELD" ] && [ -n "${diag:-}" ]; then
    serve_hold_set "$cause" "$why"
    SERVE_HELD="held, environment problem ($cause): $why"
    echo "serve: not launching: $SERVE_HELD"
  fi
  # A hold on gh or Claude auth stops everything but the reading of the sessions that ended: no recovery, no merge, no
  # launch. Any other hold stops the launches only; the green pull requests still merge.
  if [ -s "$SERVE_DIR/held" ] && serve_held_auth; then
    serve_report
    return 0
  fi
  serve_recover
  serve_ready
  run_decisions
  if ! data=$(board_data false); then
    echo "serve: cannot read the board; trying again at the next poll" >&2
    return 0
  fi
  serve_queued
  if prs=$(gh_retry api "repos/$RUN_SLUG/pulls?state=open&per_page=100"); then
    SERVE_PRS=$prs
    serve_merged_done "$data" "$prs"
    serve_prs "$data" "$prs"
  else
    echo "serve: cannot read the open pull requests; trying again at the next poll" >&2
  fi
  serve_verify_main
  while IFS=$'\t' read -r n size title batch; do
    [ -n "$n" ] || continue
    [[ " ${running[*]} " != *" $n "* ]] || continue
    RUN_TITLE[$n]=$title
    SERVE_SIZE[$n]=$size
    # A ticket whose session ended on a transient error waits for its backoff (#377).
    [ "$(serve_retry_at "$n")" -le "$now" ] || continue
    # A batch is one queue entry, under its lead: one slot, one session.
    if [ -n "$batch" ]; then
      [ "${batch%% *}" = "$n" ] || continue
      RUN_BATCH[$n]=$batch
    else
      unset "RUN_BATCH[$n]"
    fi
    queue+=("$n")
  done < <(queue_lines "$(serve_unheld "$data")")
  # The maintenance budget (#351): the numbers of the open gardening tickets, only when a slot is reserved.
  reserved=$(maintenance_reserved "$SERVE_PARALLEL") || reserved=0
  if [ "$reserved" -gt 0 ]; then
    garden=" $(jq -r --arg l "$(workflow_label "" gardening)" '[.items[] | select(.open and (.labels | index($l))) | .number] | join(" ")' <<<"$data") "
  fi
  for n in "${queue[@]}"; do
    serve_can_launch || break
    if [ "$reserved" -gt 0 ] && serve_gardening_holds "$data" "$reserved" "$garden" "$n"; then
      [ "$garden_said" = true ] || echo "serve: the last free slot is kept for a gardening ticket (maintenance.share $(config_get maintenance.share))"
      garden_said=true
      continue
    fi
    # Its Paths overlap nothing running, and a ticket with no Paths runs alone (#152).
    [ -n "$(pick_free "$data" "$(run_busy)" "$(run_entry "$n")")" ] || continue
    # A ticket begins with its first session: not a transient resume, nor an M ticket's implementer after its tests.
    begins=true
    if [ -s "$SERVE_DIR/$n.model" ] || { [ "${SERVE_SIZE[$n]}" = M ] && [ -f "$SERVE_COMMON/senior-mode/runs/$n/red-tests" ]; }; then
      begins=false
    fi
    if [ "$begins" = true ] && capped=$(serve_ticket_cap); then
      [ -n "$ticket_wait" ] || echo "serve: waiting for the next poll: $capped"
      ticket_wait=$capped
      continue
    fi
    started_before=${#running[@]}
    if [ "${SERVE_SIZE[$n]}" = M ] && { [ ! -f "$SERVE_COMMON/senior-mode/runs/$n/red-tests" ] || [ -f "$RUN_DIR/$n.retest" ]; }; then
      # An M ticket: its red tests come first, from a session of their own (#191); again, with the implementer's
      # finding, when it reported one as wrong and the test-author did not finish revising it.
      RUN_ROLE[$n]="test-author"
      unset 'RUN_CWD[$n]'
      if run_open "$n"; then
        if [ -f "$RUN_DIR/$n.retest" ]; then
          serve_retest_prompt "$n" "${RUN_TITLE[$n]}" "${RUN_BRANCH[$n]}" "$(cat "$RUN_DIR/$n.wrong-test")" | state_write "$RUN_DIR/$n.prompt"
        else
          serve_tests_prompt "$n" "${RUN_TITLE[$n]}" "${RUN_BRANCH[$n]}" | state_write "$RUN_DIR/$n.prompt"
        fi
        if run_launch "$n" "$(serve_model "$n")"; then running+=("$n"); fi
      fi
    else
      RUN_ROLE[$n]=ticket
      unset 'RUN_CWD[$n]'
      if run_start "$n"; then running+=("$n"); fi
    fi
    if [ "$begins" = true ] && [ ${#running[@]} -gt "$started_before" ]; then
      echo "$(serve_now) $n" | state_append "$SERVE_DIR/ticket-starts"
    fi
  done
  # Framing comes last: only a Ready ticket that waits for nothing but a slot goes before it (#585).
  waiting=0
  for n in "${queue[@]}"; do serve_busy "$n" || waiting=$((waiting + 1)); done
  serve_frame "$data" "$waiting"
  serve_report
  serve_breaker
}

# Waits for the running sessions, reading them as they end. Once serve has been told to stop (SERVE_TERM) it
# retries nothing on Opus, and the sessions that outlive serve.grace seconds are killed and their tickets
# labelled needs-human.
serve_drain() {
  local term_at="" n
  while [ ${#running[@]} -gt 0 ]; do
    if [ "$SERVE_TERM" = true ]; then
      if [ -z "$term_at" ]; then
        term_at=$SECONDS
        RUN_ESCALATE=false
      fi
      if [ $((SECONDS - term_at)) -ge "$SERVE_GRACE" ]; then
        for n in "${running[@]}"; do
          run_kill "$n" "#$n"
          run_halt "$n" "serve was stopped and the session was still running after serve.grace ($SERVE_GRACE seconds)" \
            "$RUN_DIR/$n-${RUN_MODEL[$n]}.log" "An autonomous senior-mode serve stopped this ticket's session" "The session log is"
        done
        running=()
        break
      fi
    fi
    sleep "${SENIOR_MODE_POLL:-15}"
    run_reap
  done
  serve_report
  serve_breaker
}

# The steps of each turn of the loop: every function named serve_step_<NN>_<name>, whatever module defines it, in the
# order of <NN> (two digits). A new step is a function in its own module, the loop is not edited: its number says where
# it runs between the ones below.
serve_steps() {
  declare -F | awk '$3 ~ /^serve_step_[0-9][0-9]_/ { print $3 }' | LC_ALL=C sort
}
serve_step_10_poll() { serve_poll; }
serve_step_20_questions() { serve_questions; }
serve_step_30_digest() { serve_digest; }
serve_step_40_digest_at() { serve_digest_at; }
serve_step_50_deps() { serve_deps; }
serve_step_60_gardening() { serve_gardening; }
serve_step_70_debt() { debt_poll; }
serve_step_80_snapshot() { serve_snapshot; }

# The loop (ADR 0017): the shared part of `run` (run_prepare, run_start, run_reap, run_finish...) with a poll
# every serve.interval seconds instead of a batch. TERM and INT stop the launching and drain. State is under
# <git common dir>/senior-mode/serve/. SENIOR_MODE_SERVE_ONCE=1 polls once, waits for its sessions and exits.
serve_loop() {
  local interval old sleeper steps step size
  local -a running=() RUN_MERGED=() RUN_NOT_DONE=() RUN_REVIEWED=() RUN_NOT_REVIEW=() RUN_WAITING=() RUN_FAILED=() RUN_PRS=()
  local -A RUN_TITLE=() RUN_BRANCH=() RUN_WT=() RUN_MODEL=() RUN_ESCALATED=() RUN_REASON=() RUN_STARTED=() RUN_ROLE=() RUN_CWD=() RUN_BATCH=()
  local -A SERVE_PR=() SERVE_SHA=() SERVE_SIZE=() SERVE_NOTED=() WD_TICK=() WD_START=() WD_SIG=() WD_BASE=() WD_AT=()
  local RUN_WATCH=wd_watch SERVE_STALL SERVE_STARTUP_MIN
  local RUN_TOKEN RUN_SLUG RUN_BASE RUN_DIR RUN_ROOT RUN_STAMP="" RUN_CLAUDE RUN_MERGE RUN_ESCALATE RUN_MAXFAIL RUN_PROTECTION RUN_REQUIRED RUN_GLOBS RUN_ZONES_KNOWN RUN_TIMEOUT
  local RUN_FAILS=0 RUN_STOP="" RUN_ON_EXIT=serve_end RUN_ON_VANISH=serve_vanished RUN_FINISH=serve_finish RUN_PROMPT=serve_prompt RUN_PROMPT_BATCH=serve_prompt_batch RUN_LAUNCH_LOG RUN_RECONCILE=1
  local SERVE_DIR SERVE_COMMON SERVE_TERM=false SERVE_PARALLEL SERVE_PER_HOUR SERVE_TICKETS_PER_HOUR SERVE_MIN_MEM SERVE_COOLDOWN SERVE_GRACE
  local SERVE_BREAKER_MAX SERVE_BACKOFF_BASE SERVE_BACKOFF_MAX SERVE_MIN_DISK SERVE_STARTUP SERVE_UNKNOWN_MAX SERVE_UNKNOWN_CAP SERVE_PENDING_HOURS GH_CALL_TIMEOUT GH_DOWN_FILE
  local SERVE_HELD="" SERVE_GUARDS="" SERVE_WAIT=""
  local -A SERVE_TIMEOUT=()
  run_prepare serve
  # ADR 0018: under serve everything green merges, unless the repository sets autonomy.merge itself.
  jq -e '(.autonomy // {}) | has("merge")' "$(config_file)" >/dev/null || RUN_MERGE=true
  interval=$(serve_int serve.interval 1)
  SERVE_GRACE=$(serve_int serve.grace 0)
  SERVE_COOLDOWN=$(serve_int serve.breakerCooldown 0)
  SERVE_TICKETS_PER_HOUR=$(serve_int autonomy.ticketsPerHour 0)
  SERVE_BREAKER_MAX=$(serve_int serve.breakerMax 1)
  SERVE_BACKOFF_BASE=$(serve_int serve.backoffBase 1)
  SERVE_BACKOFF_MAX=$(serve_int serve.backoffMax 1)
  SERVE_MIN_DISK=$(serve_int autonomy.minDiskMB 0)
  SERVE_STARTUP=$(serve_int autonomy.startupSeconds 0)
  SERVE_UNKNOWN_MAX=$(serve_int serve.unknownMaxAttempts 1)
  SERVE_UNKNOWN_CAP=$(serve_int serve.unknownBackoffMax 1)
  SERVE_PENDING_HOURS=$(serve_int serve.pendingReviewHours 1)
  SERVE_STALL=$(serve_int autonomy.stallMinutes 1)
  SERVE_STARTUP_MIN=$(serve_int autonomy.startupMinutes 1)
  GH_CALL_TIMEOUT=$(serve_int serve.callTimeout 1)
  SERVE_PER_HOUR=$(serve_int autonomy.sessionsPerHour 0)
  SERVE_MIN_MEM=$(serve_int autonomy.minMemoryMB 0)
  SERVE_PARALLEL=$(serve_int autonomy.parallel 1)
  # The wall clock of a session follows its ticket's Size (session_timeout, ADR 0034); run's own timeout is the longest
  # of them, so the watchdog, which applies the Size's, always stops a session first.
  for size in S M L; do
    SERVE_TIMEOUT[$size]=$(session_timeout "$size")
    [[ ${SERVE_TIMEOUT[$size]} =~ ^[1-9][0-9]*$ ]] && [ "${SERVE_TIMEOUT[$size]}" -le 1440 ] ||
      die "autonomy.sessionTimeoutBySize.$size must be a whole number of minutes from 1 to 1440, not ${SERVE_TIMEOUT[$size]}"
    [ "${SERVE_TIMEOUT[$size]}" -le "$RUN_TIMEOUT" ] || RUN_TIMEOUT=${SERVE_TIMEOUT[$size]}
  done
  maintenance_reserved "$SERVE_PARALLEL" >/dev/null
  # A ticket costs several role sessions (#355): the safety cap is 6 per slot unless the repository sets one.
  [ "$SERVE_PER_HOUR" -gt 0 ] || SERVE_PER_HOUR=$((6 * SERVE_PARALLEL))
  SERVE_COMMON=$(git rev-parse --path-format=absolute --git-common-dir)
  SERVE_DIR=$SERVE_COMMON/senior-mode/serve
  RUN_DIR=$SERVE_DIR
  RUN_LAUNCH_LOG=$SERVE_DIR/launches
  GH_DOWN_FILE=$SERVE_DIR/gh-down
  export GH_CALL_TIMEOUT GH_DOWN_FILE
  mkdir -p "$SERVE_DIR"
  old=$(state_num "$SERVE_DIR/serve.pid")
  if [ "$old" -gt 0 ] && kill -0 "$old" 2>/dev/null && [[ $(ps -o args= -p "$old" 2>/dev/null) == *senior-mode* ]]; then
    die "serve already runs in this repository (pid $old)"
  fi
  state_sweep "$SERVE_DIR"
  state_put "$SERVE_DIR/serve.pid" "$$"
  # shellcheck disable=SC2064 # expand now: SERVE_DIR is local and gone when the trap runs
  trap "rm -f '$SERVE_DIR/serve.pid' '$SERVE_DIR/token' '$SERVE_DIR/gh-down'" EXIT
  trap 'SERVE_TERM=true' INT TERM
  run_token_new
  "$SELF" clean || echo "senior-mode: clean failed; serve goes on" >&2
  security_alerts || echo "senior-mode: could not check the security alerts; serve goes on" >&2
  echo "serve: polling every ${interval}s, $SERVE_PARALLEL session(s) at a time; sessions and state in $SERVE_DIR"
  steps=$(serve_steps)
  while [ "$SERVE_TERM" = false ]; do
    for step in $steps; do
      "$step"
    done
    [ -z "${SENIOR_MODE_SERVE_ONCE:-}" ] || break
    sleep "$interval" &
    sleeper=$!
    wait "$sleeper" || true
    kill "$sleeper" 2>/dev/null || true
  done
  serve_drain
  serve_questions
  echo "serve: stopped"
}

# senior-mode serve [--install | --uninstall | --resume]: without an option, the daemon loop of ADR 0017 in
# this repository. --install runs it as the systemd user unit senior-mode-serve.service (restarts on failure;
# TERM, which is what `systemctl --user stop` sends to the main process only, stops the launching and gives the
# sessions serve.grace seconds before they are killed), --uninstall removes the unit, --resume lifts the
# circuit breaker's pause.
serve() {
  local common dir unit=senior-mode-serve.service root grace file me other
  [ $# -le 1 ] || usage
  common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || die "not inside a git repository"
  dir=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user
  root=$(dirname "$common")
  file=$dir/$unit
  case ${1:-} in
    "")
      # The daemon reads the customization from the base branch, never from a pull request's head (config.sh).
      export SENIOR_MODE_CONFIG_SOURCE=base
      serve_loop
      ;;
    --resume)
      if [ -f "$common/senior-mode/serve/paused" ] || [ -f "$common/senior-mode/serve/held" ] || compgen -G "$common/senior-mode/serve/*.envhold" >/dev/null; then
        rm -f "$common/senior-mode/serve/paused" "$common/senior-mode/serve/held" "$common/senior-mode/serve/breaker" \
          "$common/senior-mode/serve/transient-until" "$common/senior-mode/serve/launch-backoff-until" \
          "$common/senior-mode/serve/startup-streak" "$common/senior-mode/serve/"*.envfail "$common/senior-mode/serve/"*.envhold
        echo "resumed: the circuit breaker's pause and the environment's hold are lifted"
      else
        echo "serve is not paused."
      fi
      ;;
    --install)
      [ "$(id -u)" != 0 ] || die "serve cannot work as root: run refuses to skip permission prompts for root; use a normal user"
      if ! { command -v systemctl >/dev/null && systemctl --user show-environment >/dev/null 2>&1; }; then
        die "serve --install needs systemd user services (systemctl --user); start senior-mode serve yourself otherwise"
      fi
      [[ $root$SELF != *[\'\"\\%\$\`]* ]] || die "serve: a path holds a quote, a backslash, % or \$, which a unit cannot carry"
      grace=$(serve_int serve.grace 0)
      other=$(sed -n 's/^WorkingDirectory=//p' "$file" 2>/dev/null) || other=""
      [ -z "$other" ] || [ "$other" = "$root" ] || die "$unit already serves $other; run senior-mode serve --uninstall there first"
      mkdir -p "$dir"
      # KillMode=mixed: stop sends TERM to the main process only, so the sessions it started can finish
      # within the grace; whatever is left after TimeoutStopSec is killed.
      cat >"$file" <<UNIT
[Unit]
Description=senior-mode serve in $root

[Service]
WorkingDirectory=$root
ExecStart=/bin/bash -lc "exec '$SELF' serve"
Restart=on-failure
RestartSec=60
KillMode=mixed
TimeoutStopSec=$((grace + 60))

[Install]
WantedBy=default.target
UNIT
      systemctl --user daemon-reload
      systemctl --user enable --now "$unit" || die "systemctl --user could not enable $unit"
      echo "installed: systemd user service $unit in $root; logs: journalctl --user -u $unit"
      me=${USER:-$(id -un)}
      if ! loginctl show-user "$me" -p Linger 2>/dev/null | grep -qx 'Linger=yes'; then
        echo "warning: linger is off, so the service stops when you log out; run: sudo loginctl enable-linger $me" >&2
      fi
      ;;
    --uninstall)
      if [ -e "$file" ]; then
        if command -v systemctl >/dev/null; then systemctl --user disable --now "$unit" >/dev/null 2>&1 || true; fi
        rm -f "$file"
        if command -v systemctl >/dev/null; then systemctl --user daemon-reload >/dev/null 2>&1 || true; fi
        echo "removed: the systemd user service $unit"
      else
        echo "Nothing installed: no $unit."
      fi
      ;;
    *) usage ;;
  esac
}
