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

# The time a usage limit lifts, read from the message of the session ($1) at time $2: "limit reached|<epoch>"
# or "resets 3pm (Europe/Paris)"; one hour later when the message gives none.
serve_reset() {
  local text=$1 now=$2 re t h m zone day
  re='[Ll]imit reached\|([0-9]{9,11})'
  if [[ $text =~ $re ]] && [ "${BASH_REMATCH[1]}" -gt "$now" ]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi
  re='resets? (at )?([0-9]{1,2})(:([0-9]{2}))? ?([AaPp])[Mm]( \(([A-Za-z0-9_+/-]+)\))?'
  if [[ $text =~ $re ]]; then
    h=$((10#${BASH_REMATCH[2]}))
    m=${BASH_REMATCH[4]:-00}
    zone=${BASH_REMATCH[7]}
    case ${BASH_REMATCH[5]} in
      [Aa]) [ "$h" -ne 12 ] || h=0 ;;
      *) [ "$h" -eq 12 ] || h=$((h + 12)) ;;
    esac
    # The next such time of day after $now, in the zone the message names.
    if day=$(env ${zone:+TZ="$zone"} date -d "@$now" +%F 2>/dev/null) &&
      t=$(env ${zone:+TZ="$zone"} date -d "$day $(printf '%02d:%s' "$h" "$m")" +%s 2>/dev/null); then
      [ "$t" -gt "$now" ] || t=$((t + 86400))
      echo "$t"
      return 0
    fi
  fi
  echo $((now + 3600))
}

# RUN_ON_EXIT of serve (see run_reap): a session that ended on the subscription usage limit and said nothing
# of its ticket is not a failure. Nothing is launched until the reset time (limit-until), and the ticket of a
# ticket or test-author session goes back to Ready, its worktree and branch kept, for the first poll after it.
serve_limit() {
  local n=$1 text until now prev
  [ ! -s "$RUN_DIR/$n.outcome" ] || return 1
  text=$({
    head -c 20000 "$RUN_DIR/$n-${RUN_MODEL[$n]}.json" 2>/dev/null
    head -c 20000 "$RUN_DIR/$n-${RUN_MODEL[$n]}.log" 2>/dev/null
  } || true)
  grep -qiE 'limit reached|hit your( [a-z-]+)? limit|usage limit' <<<"$text" || return 1
  now=$(serve_now)
  until=$(serve_reset "$text" "$now")
  prev=$(cat "$SERVE_DIR/limit-until" 2>/dev/null) || prev=0
  [[ $prev =~ ^[0-9]+$ ]] || prev=0
  [ "$prev" -ge "$until" ] || echo "$until" >"$SERVE_DIR/limit-until"
  echo "#$n: the session hit the usage limit; nothing is launched until $(date -d "@$until" '+%F %T' 2>/dev/null || echo "$until")" >&2
  serve_give_back "$n"
  return 0
}

# A session that ended without a verdict on its ticket, for a reason that is not the ticket's (a usage limit, a
# transient error, the environment): a reviewer or an integrator leaves no status, the pull request is looked at again
# at a later poll; the ticket of any other session goes back to Ready, its worktree and branch kept, for a later poll.
serve_give_back() {
  local n=$1 m
  case ${RUN_ROLE[$n]:-ticket} in
    reviewer | integrator) [ -z "${RUN_CWD[$n]:-}" ] || git worktree remove --force "${RUN_CWD[$n]}" 2>/dev/null || true ;;
    *)
      for m in $(run_members "$n"); do
        (item_set "$m" Status Ready) >/dev/null || echo "#$m: could not set the Status back to Ready" >&2
      done
      ;;
  esac
}

# Why a session ended, the three classes of #377, from its outcome, its exit code and the end of its output. Prints
# `class|cause|why`: `environment` (the machine, not the ticket: disk, gh or Claude auth, dependencies, main red; pause
# everything), `transient` (network, API 5xx, a startup error: resume on the same model with a backoff, nothing counted)
# or `ticket` (anything else: the retry, escalation and needs-human path). A session that says `delivered` or
# `outgrown` is a ticket's; so is one that left no outcome and exited 0. Only a failure the session declares or an
# output that goes with a non-zero exit is read, so a retried request in the log of a session that went on is not a cause.
serve_classify() {
  local n=$1 outcome code text why
  outcome=$(cat "$RUN_DIR/$n.outcome" 2>/dev/null) || outcome=""
  code=$(cat "$RUN_DIR/$n.exit" 2>/dev/null) || code=0
  if [ -z "$outcome" ]; then
    if [ "$code" = 0 ]; then
      echo "ticket||"
      return 0
    fi
    text=$({
      tail -c 8000 "$RUN_DIR/$n-${RUN_MODEL[$n]}.json" 2>/dev/null
      tail -c 8000 "$RUN_DIR/$n-${RUN_MODEL[$n]}.log" 2>/dev/null
    } || true)
  elif grep -q 'failed:' <<<"$outcome"; then
    text=$outcome
  else
    echo "ticket||"
    return 0
  fi
  why=$(head -c 200 <<<"$text" | tr '\n' ' ')
  local cause=""
  if grep -qiE 'ENOSPC|no space left on device|disk quota exceeded' <<<"$text"; then
    cause=disk
  elif grep -qiE 'gh auth login|HTTP 401|bad credentials|not logged in to (any )?github' <<<"$text"; then
    cause=gh-auth
  elif grep -qiE 'invalid api key|please run /login|oauth token has expired|authentication_error|invalid bearer token|API Error: 401|credit balance is too low' <<<"$text"; then
    cause=claude-auth
  elif grep -qiE 'dependencies not installed|ERR_PNPM_(FETCH|NO_MATCHING|TARBALL)|npm (ERR!|error) code E(404|TARGET|RESOLVE|INTEGRITY)|No matching distribution found' <<<"$text"; then
    cause=deps
  elif grep -qiE 'main is red|red on main|base branch is red|fails on a clean checkout of main' <<<"$text"; then
    cause=main-red
  elif grep -qi 'failed: environment:' <<<"$text"; then
    cause=unknown
  fi
  if [ -n "$cause" ]; then
    why=$(grep -iE 'ENOSPC|no space left|disk quota|gh auth login|HTTP 401|bad credentials|not logged in|invalid api key|/login|oauth token|authentication_error|bearer token|API Error: 401|credit balance|dependencies not installed|ERR_PNPM|npm (ERR!|error)|No matching distribution|main is red|red on main|base branch is red|clean checkout of main|failed: environment:' <<<"$text" | head -n 1 | cut -c1-200)
    echo "environment|$cause|$why"
  elif grep -qiE 'EAI_AGAIN|ENOTFOUND|ECONNRESET|ECONNREFUSED|ETIMEDOUT|EHOSTUNREACH|ENETUNREACH|getaddrinfo|socket hang up|could not resolve host|temporary failure in name resolution|network is unreachable|unable to connect|connection error|fetch failed|error connecting to api\.|API Error: (5[0-9][0-9]|529)|overloaded_error|\boverloaded\b|"type": ?"api_error"|internal server error|bad gateway|service unavailable|gateway time-?out|still loading your organization|(connection|request|operation|gh|git|API) (call )?timed out' <<<"$text"; then
    why=$(grep -iE 'EAI_AGAIN|ENOTFOUND|ECONNRESET|ECONNREFUSED|ETIMEDOUT|EHOSTUNREACH|ENETUNREACH|getaddrinfo|socket hang up|could not resolve host|name resolution|unreachable|unable to connect|connection error|fetch failed|error connecting|API Error|overloaded|api_error|internal server error|bad gateway|service unavailable|gateway time|still loading|timed out' <<<"$text" | head -n 1 | cut -c1-200)
    echo "transient||$why"
  else
    echo "ticket||"
  fi
}

# RUN_ON_EXIT of serve (see run_reap): a session that ended on the usage limit is serve_limit's. Any other end is
# classified (serve_classify): a transient one (#334, #377) is resumed on the same model after an exponential backoff,
# an environment one pauses serve (serve_pause_env); neither is a failure for the breaker, nor an escalation, nor,
# when the session died at once, a launch against autonomy.sessionsPerHour. A ticket's end goes on to RUN_FINISH, and
# a delivery clears the backoffs. Returns 0 when it took care of the end.
serve_end() {
  local n=$1 class cause why
  serve_limit "$n" && return 0
  IFS='|' read -r class cause why < <(serve_classify "$n")
  case $class in
    environment)
      serve_give_back "$n"
      serve_pause_env "$cause" "#$n: ${why:-the session ended on an environment problem}"
      return 0
      ;;
    transient) serve_transient "$n" "$why" && return 0 ;;
  esac
  rm -f "$SERVE_DIR/$n.transient" "$SERVE_DIR/$n.retry" "$SERVE_DIR/$n.model"
  if grep -qE 'delivered|^reviewed:' "$RUN_DIR/$n.outcome" 2>/dev/null; then rm -f "$SERVE_DIR/trips"; fi
  return 1
}

# A transient end of the session $1 (why $2): it goes back to Ready, its worktree kept, and is started again on the
# same model (<n>.model) once its backoff (<n>.retry) is over: SENIOR_MODE_TRANSIENT_BACKOFF seconds (30) doubled at each
# transient end in a row, 15 minutes at most. Nothing else launches meanwhile (transient-until). The sixth end in a
# row is a ticket's (returns 1): a ticket whose own output looks like an outage must not loop for ever.
serve_transient() {
  local n=$1 why=$2 count delay now until prev model=${RUN_MODEL[$1]} life i
  count=$(cat "$SERVE_DIR/$n.transient" 2>/dev/null) || count=0
  [[ $count =~ ^[0-9]+$ ]] || count=0
  count=$((count + 1))
  if [ "$count" -gt 6 ]; then
    echo "#$n: $((count - 1)) transient ends in a row ($why); counted as a failure of the ticket" >&2
    return 1
  fi
  echo "$count" >"$SERVE_DIR/$n.transient"
  delay=${SENIOR_MODE_TRANSIENT_BACKOFF:-30}
  for ((i = 1; i < count && delay < 900; i++)); do delay=$((delay * 2)); done
  [ "$delay" -le 900 ] || delay=900
  now=$(serve_now)
  until=$((now + delay))
  echo "$until" >"$SERVE_DIR/$n.retry"
  case ${RUN_ROLE[$n]:-ticket} in reviewer | integrator) ;; *) echo "$model" >"$SERVE_DIR/$n.model" ;; esac
  prev=$(cat "$SERVE_DIR/transient-until" 2>/dev/null) || prev=0
  [[ $prev =~ ^[0-9]+$ ]] || prev=0
  [ "$prev" -ge "$until" ] || echo "$until" >"$SERVE_DIR/transient-until"
  # A session that died at once (a startup error) is not a launch against autonomy.sessionsPerHour.
  life=$((SECONDS - ${RUN_STARTED[$n]:-$SECONDS}))
  if [ "$life" -lt 60 ] && [ -s "${RUN_LAUNCH_LOG:-/nonexistent}" ]; then
    sed -i '$d' "$RUN_LAUNCH_LOG" 2>/dev/null || true
  fi
  # Nor a ticket start against autonomy.ticketsPerHour (#355): its last start is taken back.
  if [ "$life" -lt 60 ] && [ -s "$SERVE_DIR/ticket-starts" ]; then
    awk -v n="$n" '{ l[NR] = $0; if ($2 == n) last = NR } END { for (i = 1; i <= NR; i++) if (i != last) print l[i] }' \
      "$SERVE_DIR/ticket-starts" >"$SERVE_DIR/ticket-starts.tmp" && mv "$SERVE_DIR/ticket-starts.tmp" "$SERVE_DIR/ticket-starts"
  fi
  echo "#$n: the session ended on a transient error ($why); it resumes on $model in ${delay}s (end $count in a row), not counted as a failure" >&2
  if [ "$count" -ge 3 ]; then
    echo "serve: $count transient ends in a row on #$n; nothing is launched for ${delay}s" >&2
  fi
  serve_give_back "$n"
}

# The time before which the ticket $1 is not started again (its transient backoff), 0 when none.
serve_retry_at() {
  local at
  at=$(cat "$SERVE_DIR/$1.retry" 2>/dev/null) || at=0
  [[ $at =~ ^[0-9]+$ ]] || at=0
  echo "$at"
}

# The model of the next session of ticket $1: the one a transient end interrupted, else Sonnet.
serve_model() {
  local m
  m=$(cat "$SERVE_DIR/$1.model" 2>/dev/null) || m=""
  echo "${m:-sonnet}"
}

# serve stops launching, and polling anything else, until the environment is healthy (#377): the diagnosis $2 of the
# cause $1 is on stderr, in <serve dir>/environment (next probe, cause, diagnosis, probes so far), in the webhook and in
# a Project status update. serve_hold probes again, 60 seconds then twice as late each time (30 minutes at most), and
# lifts the pause on its own when the probe is green; `serve --resume` lifts it by hand. The first diagnosis stands.
serve_pause_env() {
  local cause=$1 diag=$2 now
  [ ! -f "$SERVE_DIR/environment" ] || return 0
  now=$(serve_now)
  printf '%s\n%s\n%s\n0\n' "$((now + 60))" "$cause" "$diag" >"$SERVE_DIR/environment"
  echo "serve: paused, environment problem ($cause): $diag; probing again every minute or later, or senior-mode serve --resume" >&2
  notify environment "" "serve is paused, environment problem ($cause): $diag"
  project_post_update "senior-mode serve is paused: environment problem ($cause): $diag. It resumes by itself once the probe is green." AT_RISK >/dev/null 2>&1 ||
    echo "serve: could not post the pause as a Project status update" >&2
}

# Free megabytes where the worktrees and the repository are (SENIOR_MODE_DISK_FREE_MB stands in for the tests).
serve_disk_free() {
  [ -z "${SENIOR_MODE_DISK_FREE_MB:-}" ] || {
    echo "$SENIOR_MODE_DISK_FREE_MB"
    return 0
  }
  df -Pk "$RUN_ROOT" 2>/dev/null | awk 'NR == 2 { print int($4 / 1024) }'
}

# Runs `install` or `check` on a detached worktree of the base branch, as its sessions would find it.
serve_probe_base() {
  local what=$1 wt cmd rc=0
  git_bound fetch -q origin 2>/dev/null || true
  wt=$(worktree_path "$RUN_ROOT" "probe-env")
  git worktree remove --force "$wt" 2>/dev/null || true
  git worktree add -q --detach "$wt" "$RUN_BASE" 2>/dev/null || return 1
  cmd=$(install_command "$wt")
  if [ -n "$cmd" ] && ! (cd "$wt" && net_bound 900 bash -c "$cmd" </dev/null) >/dev/null 2>&1; then rc=1; fi
  if [ "$rc" -eq 0 ] && [ "$what" = check ]; then (cd "$wt" && net_bound 1800 "$SELF" check) >/dev/null 2>&1 || rc=1; fi
  git worktree remove --force "$wt" 2>/dev/null || true
  return "$rc"
}

# Is the environment healthy for the cause $1? disk: room again; gh-auth: gh answers; claude-auth: a one-word haiku
# session answers; deps: the install command of the base branch passes; main-red: and so does `senior-mode check`;
# unknown: disk and gh.
serve_probe() {
  local out
  case $1 in
    disk) [ "$(serve_disk_free)" -ge 512 ] ;;
    gh-auth) gh_bound auth status >/dev/null 2>&1 ;;
    claude-auth)
      out=$(cd "$RUN_ROOT" && net_bound 180 "$RUN_CLAUDE" -p --model haiku "Reply with the single word ok." 2>&1 </dev/null) &&
        ! grep -qiE 'invalid api key|/login|oauth token|authentication_error|API Error: 401|credit balance' <<<"$out"
      ;;
    deps) serve_probe_base install ;;
    main-red) serve_probe_base check ;;
    *) [ "$(serve_disk_free)" -ge 512 ] && gh_bound auth status >/dev/null 2>&1 ;;
  esac
}

# RUN_FINISH of serve (see run_reap): reads how a finished session went, by its role. Returns 1 when the
# ticket goes on with another session.
serve_finish() {
  case ${RUN_ROLE[$1]:-ticket} in
    test-author) serve_finish_tests "$1" ;;
    reviewer) serve_finish_review "$1" ;;
    integrator) serve_finish_integrator "$1" ;;
    *) run_finish "$1" ;;
  esac
}

# The test-author session of an M ticket is over: its tests are recorded as the red tests (senior-mode red-tests
# record), then the ticket session starts on the same branch.
serve_finish_tests() {
  local n=$1 outcome reason=""
  outcome=$(head -n 1 "$RUN_DIR/$n.outcome" 2>/dev/null) || outcome=""
  if [ "$outcome" = delivered ]; then
    if (cd "${RUN_WT[$n]}" && "$SELF" red-tests record "$n") >"$RUN_DIR/$n.red" 2>&1; then
      RUN_ROLE[$n]=ticket
      serve_prompt "$n" "${RUN_TITLE[$n]:-}" "${RUN_BRANCH[$n]}" >"$RUN_DIR/$n.prompt"
      run_launch "$n" sonnet || return 0
      return 1
    fi
    reason="its tests could not be recorded: $(head -n 1 "$RUN_DIR/$n.red")"
  elif [ -n "$outcome" ]; then
    reason=${outcome#*: }
  else
    reason="the session ended without saying how it went (exit code $(cat "$RUN_DIR/$n.exit"), log in $RUN_DIR)"
  fi
  run_record "$n" failed "$reason"
  run_giveup "$n" "the test-author session wrote no red tests: $reason"
}

# A reviewer session is over: it must have left senior-mode/review on the head it reviewed; else the pull
# request is a person's (a reviewer that ends without a verdict would be started again at every poll).
serve_finish_review() {
  local n=$1 pr=${SERVE_PR[$1]} sha=${SERVE_SHA[$1]} review
  [ -z "${RUN_CWD[$n]:-}" ] || git worktree remove --force "${RUN_CWD[$n]}" 2>/dev/null || true
  review=$(serve_states "$sha" | jq -r '.["senior-mode/review"] // empty') || review=""
  if [ -n "$review" ]; then
    RUN_FAILS=0
    echo "#$n: pull request #$pr reviewed: senior-mode/review is $review"
    return 0
  fi
  gh_retry api "repos/$RUN_SLUG/issues/$pr/labels" -f 'labels[]=needs-human' >/dev/null || echo "#$n: could not label #$pr needs-human" >&2
  run_halt "$n" "the reviewer session of pull request #$pr ended without setting senior-mode/review" "$RUN_DIR/$n-${RUN_MODEL[$n]}.log" \
    "An autonomous senior-mode serve found this pull request's reviewer session over" "The session log is"
}

# An integrator session is over: the pull request it opened on the -rN branch supersedes the old one, which is
# closed (the new one is reviewed like any other); without one, the old pull request is a person's. The ticket
# is recorded as delivered and left In review, on the new pull request: serve_recover reads a ticket whose end
# was never recorded as a lost session (#285).
serve_finish_integrator() {
  local n=$1 old new outcome
  old=$(cat "$RUN_DIR/$n.oldpr" 2>/dev/null) || old=""
  outcome=$(head -n 1 "$RUN_DIR/$n.outcome" 2>/dev/null) || outcome=""
  new=$(gh_retry api "repos/$RUN_SLUG/pulls?head=${RUN_SLUG%%/*}:${RUN_BRANCH[$n]}&state=open" --jq '.[0].number // empty') || new=""
  if [ -n "$new" ] && [ "$outcome" = delivered ]; then
    RUN_FAILS=0
    run_record "$n" delivered ""
    run_review "$n"
    gh_bound api "repos/$RUN_SLUG/issues/$old/comments" -f body="Superseded by #$new, which resolves the conflicts with $RUN_BASE." >/dev/null || true
    gh_retry api "repos/$RUN_SLUG/pulls/$old" -X PATCH -f state=closed >/dev/null || echo "#$n: could not close pull request #$old" >&2
    echo "#$n: pull request #$new supersedes #$old"
    return 0
  fi
  RUN_FAILS=$((RUN_FAILS + 1))
  RUN_FAILED+=("#$n ${RUN_TITLE[$n]:-}: the integrator could not resolve pull request #$old (${outcome:-no outcome}; branch ${RUN_BRANCH[$n]} kept)")
  serve_needs_human "$n" "$old" "the integrator session could not resolve its conflicts with $RUN_BASE (${outcome:-no outcome})"
}

# Is serve held back (not an error)? Prints why and returns 0 when it is: the circuit breaker's pause (until its
# cooldown or `serve --resume`, which removes the file), an environment pause (until a probe is green), a usage limit
# (until its reset) or a transient backoff. A hold that is over is lifted here. $1 is the time.
serve_hold() {
  local now=$1 until cause diag tries next
  if [ -f "$SERVE_DIR/paused" ]; then
    until=$(sed -n 1p "$SERVE_DIR/paused")
    if [[ $until =~ ^[0-9]+$ ]] && [ "$now" -lt "$until" ]; then
      echo "paused by the circuit breaker, $(sed -n 2p "$SERVE_DIR/paused"); resumes at $until or with senior-mode serve --resume"
      return 0
    fi
    rm -f "$SERVE_DIR/paused"
    echo "serve: the breaker cooldown is over, launching again" >&2
  fi
  if [ -f "$SERVE_DIR/environment" ]; then
    next=$(sed -n 1p "$SERVE_DIR/environment")
    cause=$(sed -n 2p "$SERVE_DIR/environment")
    diag=$(sed -n 3p "$SERVE_DIR/environment")
    tries=$(sed -n 4p "$SERVE_DIR/environment")
    [[ $next =~ ^[0-9]+$ ]] || next=0
    [[ $tries =~ ^[0-9]+$ ]] || tries=0
    if [ "$now" -ge "$next" ]; then
      if serve_probe "$cause"; then
        rm -f "$SERVE_DIR/environment"
        echo "serve: the environment is healthy again (probe for $cause is green), launching again" >&2
        project_post_update "senior-mode serve resumed: the probe for $cause is green." ON_TRACK >/dev/null 2>&1 || true
      else
        tries=$((tries + 1))
        next=$((now + 60 * (1 << (tries < 5 ? tries : 5))))
        [ $((next - now)) -le 1800 ] || next=$((now + 1800))
        printf '%s\n%s\n%s\n%s\n' "$next" "$cause" "$diag" "$tries" >"$SERVE_DIR/environment"
        echo "serve: still paused, environment problem ($cause): the probe is red; next probe at $next" >&2
      fi
    fi
    if [ -f "$SERVE_DIR/environment" ]; then
      echo "paused, environment problem ($cause): $diag; next probe at $next"
      return 0
    fi
  fi
  until=$(cat "$SERVE_DIR/limit-until" 2>/dev/null) || until=""
  if [[ $until =~ ^[0-9]+$ ]]; then
    if [ "$now" -lt "$until" ]; then
      echo "usage limit reached, resumes at $until"
      return 0
    fi
    rm -f "$SERVE_DIR/limit-until"
  fi
  until=$(cat "$SERVE_DIR/transient-until" 2>/dev/null) || until=""
  if [[ $until =~ ^[0-9]+$ ]]; then
    if [ "$now" -lt "$until" ]; then
      echo "backing off after a transient error (network, API or startup), resumes at $until"
      return 0
    fi
    rm -f "$SERVE_DIR/transient-until"
  fi
  return 1
}

# After `autonomy.maxConsecutiveFailures` ticket failures in a row (only those: a transient or an environment end is
# no failure, #377) the breaker pauses serve for serve.breakerCooldown seconds, doubled at each pause that no delivery
# separates from the last (a day at most; the count is <serve dir>/trips); it never exits. The count of failures starts
# again, so a resume gets a fresh chance. The pause is alerted once (no ticket to mention: the webhook and the line on stderr).
serve_breaker() {
  local now trips cooldown i
  [ "$RUN_FAILS" -ge "$RUN_MAXFAIL" ] || return 0
  RUN_FAILS=0
  RUN_STOP=""
  if [ ! -f "$SERVE_DIR/paused" ]; then
    now=$(serve_now)
    trips=$(cat "$SERVE_DIR/trips" 2>/dev/null) || trips=0
    [[ $trips =~ ^[0-9]+$ ]] || trips=0
    trips=$((trips + 1))
    echo "$trips" >"$SERVE_DIR/trips"
    cooldown=$SERVE_COOLDOWN
    for ((i = 1; i < trips && cooldown < 86400; i++)); do cooldown=$((cooldown * 2)); done
    [ "$cooldown" -le 86400 ] || cooldown=86400
    printf '%s\n%s\n' "$((now + cooldown))" "$RUN_MAXFAIL failed tickets in a row (autonomy.maxConsecutiveFailures)" >"$SERVE_DIR/paused"
    echo "serve: paused, $RUN_MAXFAIL failed tickets in a row; it resumes in $cooldown seconds (pause $trips since the last delivery) or with: senior-mode serve --resume" >&2
    notify breaker "" "$RUN_MAXFAIL failed tickets in a row (autonomy.maxConsecutiveFailures)"
  fi
}

# Is a ceiling reached? Prints which and returns 0 when it is: launches in the last hour, the load average over
# the CPU count, available memory under autonomy.minMemoryMB. The launch waits for the next poll.
serve_ceiling() {
  local now count load cpus mem
  now=$(serve_now)
  if [ -f "$RUN_LAUNCH_LOG" ]; then
    awk -v c="$((now - 3600))" '$1 > c' "$RUN_LAUNCH_LOG" >"$RUN_LAUNCH_LOG.tmp" && mv "$RUN_LAUNCH_LOG.tmp" "$RUN_LAUNCH_LOG"
    count=$(awk 'END { print NR }' "$RUN_LAUNCH_LOG")
    if [ "$count" -ge "$SERVE_PER_HOUR" ]; then
      echo "$count sessions launched in the last hour (autonomy.sessionsPerHour $SERVE_PER_HOUR, the safety cap)"
      return 0
    fi
  fi
  cpus=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
  # SENIOR_MODE_LOADAVG: the 1-minute load average, for the tests.
  load=${SENIOR_MODE_LOADAVG:-$(cut -d' ' -f1 /proc/loadavg 2>/dev/null || uptime | sed -E 's/.*load averages?: *//; s/,.*//')}
  if awk -v l="${load:-0}" -v c="$cpus" 'BEGIN { exit !(l + 0 > c + 0) }'; then
    echo "load average $load is over the $cpus CPU(s)"
    return 0
  fi
  mem=$(awk '/^MemAvailable:/ { print int($2 / 1024) }' /proc/meminfo 2>/dev/null || true)
  if [ -n "$mem" ] && [ "$mem" -lt "$SERVE_MIN_MEM" ]; then
    echo "$mem MB of memory available, under autonomy.minMemoryMB $SERVE_MIN_MEM"
    return 0
  fi
  return 1
}

# What the sessions that ended since the last poll left to a person, once.
serve_report() {
  local t
  for t in "${RUN_MERGED[@]}"; do echo "Merged: $t"; done
  for t in "${RUN_NOT_DONE[@]}"; do echo "Status not set to Done: $t"; done
  for t in "${RUN_FAILED[@]}"; do echo "Failed: $t"; done
  for t in "${RUN_REVIEWED[@]}"; do echo "Status set to In review: $t"; done
  for t in "${RUN_NOT_REVIEW[@]}"; do echo "Status not set to In review: $t"; done
  for t in "${RUN_WAITING[@]}"; do echo "Waiting for a human: $t"; done
  RUN_FAILED=() RUN_WAITING=() RUN_MERGED=() RUN_NOT_DONE=() RUN_REVIEWED=() RUN_NOT_REVIEW=() RUN_PRS=()
}

# Ready by rule (#272), once a poll: `ready --pr <n>` for each framing pull request (branch docs/...) merged since
# the last poll, then `ready` for the tickets agents filed. The time of the last poll that went well is kept in
# <serve dir>/ready-last: a failure leaves it, so the pull requests are read again at the next poll, and a
# restart does not miss what merged while serve was down. The first poll only sets the mark.
serve_ready() {
  local now last prs pr ok=true
  now=$(serve_now)
  last=$(cat "$SERVE_DIR/ready-last" 2>/dev/null) || last=""
  [[ $last =~ ^[0-9]+$ ]] || last=$now
  if prs=$(gh_retry pr list --repo "$RUN_SLUG" --state merged --limit 50 --json number,headRefName,mergedAt); then
    while IFS= read -r pr; do
      [ -n "$pr" ] || continue
      "$SELF" ready --pr "$pr" || ok=false
    done < <(jq -r --argjson l "$last" '.[] | select((.headRefName | startswith("docs/")) and ((.mergedAt | fromdateiso8601) > $l)) | .number' <<<"$prs")
  else
    echo "serve: cannot list the merged pull requests; trying again at the next poll" >&2
    ok=false
  fi
  "$SELF" ready || ok=false
  [ "$ok" = false ] || echo "$now" >"$SERVE_DIR/ready-last"
}

# After a crash or a restart (#272): a ticket serve launched (its <n>.sh is in the serve dir) whose session is
# not one of this serve's, is still In progress and has no live session goes back to Ready, to be picked again
# (its worktree and branch are kept). Once autonomy.maxConsecutiveFailures recoveries are used up it gets
# needs-human instead. Left alone: a session still alive, a ticket whose end serve already read (its <n>.json is
# newer than its <n>.sh), a ticket with needs-human. The recoveries are counted in <n>.recovered.
serve_recover() {
  local f n data count m
  local -a cand=()
  for f in "$SERVE_DIR"/*.sh; do
    [ -e "$f" ] || continue
    n=$(basename "$f" .sh)
    [[ $n =~ ^[0-9]+$ ]] || continue
    [[ " ${running[*]-} " != *" $n "* ]] || continue
    if [ -f "$SERVE_DIR/$n.json" ] && [ "$SERVE_DIR/$n.json" -nt "$f" ]; then continue; fi
    if [ -f "$SERVE_DIR/$n.exit" ] || [ ! -f "$SERVE_DIR/$n.pgid" ] || run_dead "$n"; then cand+=("$n"); fi
  done
  [ ${#cand[@]} -gt 0 ] || return 0
  if ! data=$(board_data false); then
    echo "serve: cannot read the board to recover tickets; trying again at the next poll" >&2
    return 0
  fi
  for n in "${cand[@]}"; do
    jq -e --argjson n "$n" '.items[] | select(.number == $n and .open and .status == "In progress" and (.labels | index("needs-human") | not))' \
      <<<"$data" >/dev/null || continue
    count=$(cat "$SERVE_DIR/$n.recovered" 2>/dev/null) || count=0
    [[ $count =~ ^[0-9]+$ ]] || count=0
    count=$((count + 1))
    echo "$count" >"$SERVE_DIR/$n.recovered"
    if [ "$count" -ge "$RUN_MAXFAIL" ]; then
      echo "serve: #$n has lost its session $count times; needs-human"
      notify needs-human "$n" "serve found the ticket In progress with no live session $count times (autonomy.maxConsecutiveFailures); the session files are in $SERVE_DIR"
    else
      # A lost batch session puts every ticket of the batch back.
      for m in $(cat "$SERVE_DIR/$n.batch" 2>/dev/null || echo "$n"); do
        if (item_set "$m" Status Ready) >/dev/null; then
          echo "serve: #$m was In progress with no live session; back to Ready (recovery $count of $((RUN_MAXFAIL - 1)))"
        else
          echo "#$m: could not set the Status back to Ready" >&2
        fi
      done
    fi
  done
}

# Says why a pull request waits, once: the line is repeated only when the reason changes. $1 names the pull
# request, $2 is the line.
serve_note() {
  [ "${SERVE_NOTED[$1]:-}" != "$2" ] || return 0
  SERVE_NOTED[$1]=$2
  RUN_WAITING+=("$2")
}

# Is autonomy.ticketsPerHour reached? Prints the reason and returns 0 when it is. It counts ticket starts, not the
# role sessions a ticket costs (#355): one line "<time> <ticket>" in ticket-starts per ticket begun.
serve_ticket_cap() {
  local now count f=$SERVE_DIR/ticket-starts
  [ -f "$f" ] || return 1
  now=$(serve_now)
  awk -v c="$((now - 3600))" '$1 > c' "$f" >"$f.tmp" && mv "$f.tmp" "$f"
  count=$(awk 'END { print NR }' "$f")
  [ "$count" -ge "$SERVE_TICKETS_PER_HOUR" ] || return 1
  echo "$count tickets started in the last hour (autonomy.ticketsPerHour $SERVE_TICKETS_PER_HOUR)"
}

# A ticket's session is the only one it has: the numbers of the tickets with a session running.
serve_busy() {
  [[ " ${running[*]} " == *" $1 "* ]]
}

# May a session start now? Not when serve is stopping, held back (serve_hold), without a free slot or after the
# failures the breaker counts; then the guards (#117) are in place and no ceiling is reached. What it says, it
# says once per poll.
serve_can_launch() {
  [ "$SERVE_TERM" = false ] && [ -z "$SERVE_HELD" ] && [ ${#running[@]} -lt "$SERVE_PARALLEL" ] && [ "$RUN_FAILS" -lt "$RUN_MAXFAIL" ] || return 1
  if [ -z "$SERVE_GUARDS" ]; then
    if (run_guards "$SERVE_COMMON"); then
      SERVE_GUARDS=ok
    else
      SERVE_GUARDS=bad
      echo "serve: the guards are not in place; nothing launched, trying again at the next poll" >&2
    fi
  fi
  [ "$SERVE_GUARDS" = ok ] || return 1
  if [ -z "$SERVE_WAIT" ] && SERVE_WAIT=$(serve_ceiling); then
    echo "serve: waiting for the next poll: $SERVE_WAIT"
  fi
  [ -z "$SERVE_WAIT" ]
}

# The state of each status of a commit, {context: state}.
serve_states() {
  gh_retry api "repos/$RUN_SLUG/commits/$1/status" --jq '[.statuses[] | {key: .context, value: .state}] | from_entries'
}

# A pull request that needs a person: needs-human on it and on its ticket, and why on the pull request.
serve_needs_human() {
  local n=$1 pr=$2 reason=$3 t
  for t in "$pr" "$n"; do
    gh_retry api "repos/$RUN_SLUG/issues/$t/labels" -f 'labels[]=needs-human' >/dev/null || echo "#$n: could not label #$t needs-human" >&2
  done
  gh_bound api "repos/$RUN_SLUG/issues/$pr/comments" -f body="senior-mode serve: $reason

It is labelled needs-human: a person decides what happens next." >/dev/null || echo "#$n: could not comment on #$pr" >&2
  serve_note "nh$pr" "#$n ${RUN_TITLE[$n]:-}: pull request #$pr, $reason"
}

# Whether a run_blocker reason $1 is one no poll will lift: merging off, an external pull request, no server protection,
# a protected zone, a pull request that is not ready (a ticket without its commit, a diff over its size budget: needs-human
# with the numbers, #297, #303) or that departs from the project's workflow.
# A status not green yet, a mergeable state or an unreadable answer is transient: the next poll looks again.
serve_permanent() {
  case $1 in
    "merging is off"* | "it is external"* | "the server enforces no branch protection"* | "it touches a protected zone"* | "the protected zones could not be read"* | "not ready: "* | "it does not follow the project's workflow"*) ;;
    *) return 1 ;;
  esac
}

# A pull request that cannot merge on its own (#282): the alert of #155 on the pull request (label, comment with
# the reason, webhook), needs-human on its ticket too. Candidates skip needs-human, so the next poll leaves it be.
serve_stuck() {
  local t=$1 pr=$2 reason=$3
  notify needs-human "$pr" "pull request #$pr (ticket #$t) cannot merge on its own: $reason"
  gh_retry api "repos/$RUN_SLUG/issues/$t/labels" -f 'labels[]=needs-human' >/dev/null || echo "#$t: could not label it needs-human" >&2
}

# The pull requests of tickets In review, in `pick` order, as `ticket pr sha branch title` lines: open, not a draft,
# not needs-human, on a branch named <type>/<ticket>-... $1 is the board, $2 the open pull requests.
# shellcheck disable=SC2016 # a jq program, not shell
serve_candidates() {
  local re
  re=$(workflow_branch_re "$RUN_ROOT")
  jq -r --argjson d "$1" --argjson map "$(workflow_branch_map_json)" --arg re "${re:-^[a-z]+/(?<n>[0-9]+)(-|\$)}" '[.[] | . as $p
      | ((try ($p.head.ref | capture($re) | .n | tonumber) catch null) // $map[$p.head.ref]) as $t
      | select($t != null)
      | ($d.items[] | select(.number == $t and .open and .status == "In review")) as $i
      | select((($i.labels | index("needs-human")) // ([$p.labels[]?.name] | index("needs-human"))) | not)
      | select(.draft | not)
      | {t: $t, pr: $p.number, sha: $p.head.sha, ref: $p.head.ref, title: $i.title,
         k: ([($i.priority // "") | scan("^P([0-9]+)") | .[0] | tonumber] | first // 99)}]
    | sort_by([.k, .t])[] | [.t, .pr, .sha, .ref, .title] | @tsv' <<<"$2"
}

# A merged hotfix pull request (head matching workflow.release.hotfix, base other than the integration branch): the
# ticket `chore: back-merge <hotfix> into <integration>` that brings the fix back to the integration branch. Filed
# once per hotfix branch; a failure is said, never fatal.
serve_backmerge() {
  local pr=$2 hot integration info head base title file
  workflow_active "$RUN_ROOT" || return 0
  hot=$(workflow_get release.hotfix "$RUN_ROOT")
  integration=$(workflow_get integration "$RUN_ROOT")
  [ -n "$hot" ] && [ -n "$integration" ] || return 0
  info=$(gh_retry pr view "$pr" -R "$RUN_SLUG" --json headRefName,baseRefName --jq '[.headRefName, .baseRefName] | @tsv') || return 0
  IFS=$'\t' read -r head base <<<"$info"
  # shellcheck disable=SC2053 # a glob of workflow.release.hotfix
  [[ $head == $hot ]] && [ "$base" != "$integration" ] || return 0
  title="chore: back-merge $head into $integration"
  file=$(mktemp)
  printf '## Context\n\nThe hotfix pull request #%s merged into `%s`; `%s` lacks it.\n\n## Acceptance criteria\n\n- Given `%s` is merged, when `%s` is merged into `%s`, then `%s` holds the hotfix and its check is green.\n' \
    "$pr" "$base" "$integration" "$head" "$base" "$integration" "$integration" >"$file"
  (issue_create --title "$title" --body-file "$file" --size S --priority P1 --type chore --paths '**' --status Ready) >/dev/null ||
    echo "pull request #$pr: could not file $title" >&2
  rm -f "$file"
}

# A merged pull request: counted, its ticket Done.
serve_done() {
  local t=$1 pr=$2 m
  rm -f "$SERVE_DIR/queued-$pr" "$SERVE_DIR/rounds-$t"
  serve_backmerge "$t" "$pr"
  # Every ticket of a batch is done with its one pull request (the lead's <n>.batch).
  for m in $(cat "$SERVE_DIR/$t.batch" 2>/dev/null || echo "$t"); do
    RUN_MERGED+=("#$m ${RUN_TITLE[$m]:-} (pull request #$pr)")
    if (item_set "$m" Status Done) >/dev/null; then
      cycle_end "$m"
    else
      echo "#$m: merged, but could not set the Status Done" >&2
      RUN_NOT_DONE+=("#$m ${RUN_TITLE[$m]:-} (pull request #$pr)")
    fi
  done
}

# The pull requests queued for auto-merge (queued-<pr>: the head and the ticket): merged is read back, then
# Done; a closed one is forgotten. One whose head is no longer the queued one is a candidate again.
serve_queued() {
  local f pr sha t state
  for f in "$SERVE_DIR"/queued-*; do
    [ -e "$f" ] || continue
    pr=${f##*queued-}
    read -r sha t <"$f" || continue
    state=$(gh_retry pr view "$pr" -R "$RUN_SLUG" --json state --jq .state) || continue
    case $state in
      MERGED) serve_done "$t" "$pr" ;;
      CLOSED) rm -f "$f" ;;
    esac
  done
}

# Does the repository allow auto-merge (#173)?
serve_auto() {
  gh_retry api "repos/$RUN_SLUG" --jq '.allow_auto_merge // false' 2>/dev/null || echo false
}

# Merges the pull request $2 of ticket $1 at head $3: queued with auto-merge when the repository allows it
# (else, or when GitHub refuses, merged now), --match-head-commit in both. Merged means the state read back is
# MERGED; only then the ticket is Done.
serve_do_merge() {
  local t=$1 pr=$2 sha=$3 err="$SERVE_DIR/$1.merge" queued=false state method
  : >"$err"
  method=$(workflow_merge_flag "$RUN_ROOT")
  if [ "$(serve_auto)" = true ] &&
    gh_bound pr merge "$pr" --auto "$method" --match-head-commit "$sha" -R "$RUN_SLUG" >/dev/null 2>"$err"; then
    queued=true
  elif ! gh_bound pr merge "$pr" "$method" --match-head-commit "$sha" -R "$RUN_SLUG" >/dev/null 2>"$err"; then
    serve_note "w$pr" "#$t ${RUN_TITLE[$t]:-}: pull request #$pr, the merge failed: $(head -n 1 "$err")"
    return 0
  fi
  state=$(gh_retry pr view "$pr" -R "$RUN_SLUG" --json state --jq .state) || state=""
  if [ "$state" = MERGED ]; then
    serve_done "$t" "$pr"
  elif [ "$queued" = true ]; then
    echo "$sha $t" >"$SERVE_DIR/queued-$pr"
    echo "#$t: pull request #$pr queued for auto-merge"
  else
    serve_note "w$pr" "#$t ${RUN_TITLE[$t]:-}: pull request #$pr, merged but GitHub says it is ${state:-unknown}"
  fi
}

# After a rebase of the pull request $2 (ticket $1) from head $3 to head $4 (branch $5): check and publish on
# the new head, then the review is carried over when `git range-diff` finds the same patches, or asked again
# when it finds any change (the head has no review status, so the next poll starts a reviewer).
serve_requalify() {
  local t=$1 pr=$2 old=$3 new=$4 ref=$5 wt log="$SERVE_DIR/$1.check.log" same=false cmd ob nb ci review
  git_bound fetch -q origin 2>/dev/null || true
  if git cat-file -e "$old^{commit}" 2>/dev/null && git cat-file -e "$new^{commit}" 2>/dev/null &&
    ob=$(git merge-base "$old" "$new") && nb=$(git merge-base "$RUN_BASE" "$new") &&
    git range-diff --no-color "$ob..$old" "$nb..$new" >"$SERVE_DIR/$t.range-diff" 2>/dev/null &&
    awk 'NF && $3 != "=" { bad = 1 } END { exit (bad || NR == 0) }' "$SERVE_DIR/$t.range-diff"; then
    same=true
  fi
  wt=$(worktree_path "$RUN_ROOT" "integrate-$t")
  git worktree remove --force "$wt" 2>/dev/null || true
  if ! git worktree add -q --detach "$wt" "$new" 2>/dev/null; then
    serve_needs_human "$t" "$pr" "it was rebased on $RUN_BASE but a worktree of the new head could not be opened to check it"
    return 0
  fi
  cmd=$(install_command "$wt")
  [ -z "$cmd" ] || (cd "$wt" && bash -c "$cmd" </dev/null) >"$log" 2>&1 || true
  (cd "$wt" && "$SELF" check) >>"$log" 2>&1 || true
  if ! (cd "$wt" && "$SELF" publish) >>"$log" 2>&1; then
    git worktree remove --force "$wt" 2>/dev/null || true
    serve_needs_human "$t" "$pr" "it was rebased on $RUN_BASE but its check result could not be published (log $log)"
    return 0
  fi
  git worktree remove --force "$wt" 2>/dev/null || true
  rm -f "$SERVE_DIR/rebased-$pr"
  ci=$(serve_states "$new" | jq -r '.["senior-mode/ci"] // empty') || ci=""
  if [ "$ci" != success ]; then
    serve_needs_human "$t" "$pr" "it was rebased on $RUN_BASE and its check is $ci now (log $log)"
    return 0
  fi
  review=$(serve_states "$old" | jq -r '.["senior-mode/review"] // empty') || review=""
  if [ "$same" = true ] && [ "$review" = success ]; then
    gh_retry api "repos/$RUN_SLUG/statuses/$new" -f state=success -f context=senior-mode/review \
      -f description="carried over from ${old:0:7}: git range-diff shows the same patches" >/dev/null ||
      echo "#$t: could not carry the review over to ${new:0:7}" >&2
    gh_bound api "repos/$RUN_SLUG/issues/$pr/comments" -f body="senior-mode serve rebased this pull request on $RUN_BASE (\`${old:0:7}\` to \`${new:0:7}\`): \`git range-diff\` shows the same patches, so the review of \`${old:0:7}\` is carried over; check and publish ran again." >/dev/null || true
  else
    gh_bound api "repos/$RUN_SLUG/issues/$pr/comments" -f body="senior-mode serve rebased this pull request on $RUN_BASE (\`${old:0:7}\` to \`${new:0:7}\`): \`git range-diff\` shows changes, so check and publish ran again and a new review is requested." >/dev/null || true
  fi
}

# The pull request $2 of ticket $1 (head $3, branch $4) is behind its base: rebased on the server
# (`gh pr update-branch --rebase`), then requalified. Returns 0 when the head moved (new head in SERVE_HEAD),
# 1 when not, 2 for a conflict.
serve_rebase() {
  local t=$1 pr=$2 old=$3 ref=$4 new="" i err="$SERVE_DIR/$1.rebase"
  git_bound fetch -q origin "$ref" 2>/dev/null || true
  printf '%s\n' "$old" >"$SERVE_DIR/rebased-$pr"
  if ! gh_bound pr update-branch "$pr" --rebase -R "$RUN_SLUG" >/dev/null 2>"$err"; then
    rm -f "$SERVE_DIR/rebased-$pr"
    if grep -qi conflict "$err"; then return 2; fi
    serve_note "w$pr" "#$t ${RUN_TITLE[$t]:-}: pull request #$pr, it is behind $RUN_BASE and could not be updated: $(head -n 1 "$err")"
    return 1
  fi
  for ((i = 0; i < 6; i++)); do
    new=$(gh_retry api "repos/$RUN_SLUG/pulls/$pr" --jq .head.sha) || new=""
    { [ -n "$new" ] && [ "$new" != "$old" ]; } && break
    sleep "${SENIOR_MODE_POLL:-15}"
  done
  if [ -z "$new" ] || [ "$new" = "$old" ]; then
    echo "#$t: pull request #$pr is being rebased; looking again at the next poll" >&2
    return 1
  fi
  serve_requalify "$t" "$pr" "$old" "$new" "$ref"
}

# The pull request $2 of ticket $1 (branch $3) conflicts with its base: an Opus integrator session resolves it
# on the branch <branch>-r2 (-r3 the second time), in a worktree of its own, and opens a pull request that says
# "Supersedes #<old>". A resolution that was tried twice is a person's. Returns 0 when a session started.
serve_conflict() {
  local t=$1 pr=$2 ref=$3 base=$3 k=2 new wt
  if [[ $ref =~ ^(.*)-r([0-9]+)$ ]]; then
    base=${BASH_REMATCH[1]}
    k=$((BASH_REMATCH[2] + 1))
  fi
  if [ "$k" -gt 3 ]; then
    serve_needs_human "$t" "$pr" "it conflicts with $RUN_BASE again after the integrator resolved it twice"
    return 1
  fi
  serve_can_launch || return 1
  new=$base-r$k
  git_bound fetch -q origin 2>/dev/null || true
  wt=$(worktree_path "$RUN_ROOT" "$t-r$k")
  git worktree remove --force "$wt" 2>/dev/null || true
  git branch -D -q "$new" 2>/dev/null || true
  if ! git worktree add -q --no-track -b "$new" "$wt" "origin/$ref" 2>/dev/null; then
    serve_needs_human "$t" "$pr" "it conflicts with $RUN_BASE and a worktree for the integrator could not be opened on $new"
    return 1
  fi
  RUN_ROLE[$t]=integrator
  unset 'RUN_CWD[$t]'
  RUN_WT[$t]=$wt
  RUN_BRANCH[$t]=$new
  echo "$pr" >"$RUN_DIR/$t.oldpr"
  serve_integrator_prompt "$t" "${RUN_TITLE[$t]:-}" "$ref" "$pr" "$new" >"$RUN_DIR/$t.prompt"
  echo "#$t: pull request #$pr conflicts with $RUN_BASE; the integrator resolves it on $new"
  if run_launch "$t" opus; then running+=("$t"); fi
}

# The review of an approved pull request $2 (ticket $1, head $3, branch $4): merged by the integrator pass. Returns
# 0 when it acted (merged, queued, rebased, a conflict session started), so that a poll merges at most one.
serve_merge() {
  local t=$1 pr=$2 ref=$4 pull sha reason state rc=0
  pull=$(gh_retry api "repos/$RUN_SLUG/pulls/$pr") || return 1
  sha=$(jq -r '.head.sha' <<<"$pull")
  reason=$(run_blocker "$pr" "$sha" "$pull")
  if [ -n "$reason" ]; then
    serve_note "w$pr" "#$t ${RUN_TITLE[$t]:-}: pull request #$pr, $reason"
    serve_permanent "$reason" && serve_stuck "$t" "$pr" "$reason"
    return 1
  fi
  state=$(jq -r '.mergeable_state // "unknown"' <<<"$pull")
  case $state in
    unknown) return 1 ;;
    dirty)
      serve_conflict "$t" "$pr" "$ref"
      return
      ;;
    behind)
      serve_rebase "$t" "$pr" "$sha" "$ref" || rc=$?
      [ "$rc" -ne 2 ] || {
        serve_conflict "$t" "$pr" "$ref"
        return
      }
      [ "$rc" -eq 0 ] || return 1
      pull=$(gh_retry api "repos/$RUN_SLUG/pulls/$pr") || return 0
      sha=$(jq -r '.head.sha' <<<"$pull")
      # A rebase that changed the patches has no review on its new head: the next poll starts a reviewer.
      [ -z "$(run_blocker "$pr" "$sha" "$pull")" ] || return 0
      ;;
  esac
  serve_do_merge "$t" "$pr" "$sha"
}

# Changes requested on the pull request $2 (branch $3) of ticket $1: the ticket session resumes on the same
# branch with the findings, twice at most; then a person.
serve_changes() {
  local t=$1 pr=$2 ref=$3 rounds
  rounds=$(cat "$SERVE_DIR/rounds-$t" 2>/dev/null) || rounds=0
  [[ $rounds =~ ^[0-9]+$ ]] || rounds=0
  if [ "$rounds" -ge 2 ]; then
    serve_needs_human "$t" "$pr" "the reviewer still requests changes after $rounds fix rounds"
    return 0
  fi
  serve_can_launch || return 0
  RUN_ROLE[$t]=ticket
  unset 'RUN_CWD[$t]'
  run_open "$t" || return 0
  echo $((rounds + 1)) >"$SERVE_DIR/rounds-$t"
  serve_fix_prompt "$t" "${RUN_TITLE[$t]:-}" "${RUN_BRANCH[$t]}" "$pr" $((rounds + 1)) >"$RUN_DIR/$t.prompt"
  echo "#$t: the reviewer requested changes on pull request #$pr; the ticket session resumes (round $((rounds + 1)) of 2)"
  if run_launch "$t" sonnet; then running+=("$t"); fi
}

# A pull request In review whose head has senior-mode/ci and no review status: a reviewer session on Opus, in a
# detached worktree of that head (ADR 0017, 0019: no reviewer, no review; the status stays unset and the next
# poll after a usage limit's reset tries again).
serve_review() {
  local t=$1 pr=$2 sha=$3 ref=$4 wt
  serve_can_launch || return 0
  git_bound fetch -q origin "$ref" 2>/dev/null || true
  wt=$(worktree_path "$RUN_ROOT" "review-$t")
  git worktree remove --force "$wt" 2>/dev/null || true
  if ! git worktree add -q --detach "$wt" "$sha" 2>/dev/null; then
    echo "#$t: could not open a worktree to review pull request #$pr; trying again at the next poll" >&2
    return 0
  fi
  RUN_ROLE[$t]=reviewer
  RUN_CWD[$t]=$wt
  RUN_WT[$t]=$wt
  RUN_BRANCH[$t]=$ref
  SERVE_PR[$t]=$pr
  SERVE_SHA[$t]=$sha
  serve_review_prompt "$t" "${RUN_TITLE[$t]:-}" "$pr" "$sha" >"$RUN_DIR/$t.prompt"
  echo "#$t: reviewing pull request #$pr"
  if run_launch "$t" opus; then running+=("$t"); else git worktree remove --force "$wt" 2>/dev/null || true; fi
}

# Every pull request of a ticket In review, in `pick` order: its head decides. CI success and no review
# status: a reviewer session. Review failure: the ticket session resumes. Review success: merged (the integrator
# pass), at most one per poll.
serve_prs() {
  local data=$1 prs=$2 acted=false t pr sha ref title states review ci old
  while IFS=$'\t' read -r t pr sha ref title; do
    [ -n "$t" ] || continue
    [ "$SERVE_TERM" = false ] || break
    RUN_TITLE[$t]=$title
    serve_busy "$t" && continue
    if [ -f "$SERVE_DIR/queued-$pr" ] && [ "$(cut -d' ' -f1 "$SERVE_DIR/queued-$pr")" = "$sha" ]; then continue; fi
    # A rebase whose requalification was cut short (serve stopped, the new head came late): carry on.
    if [ -f "$SERVE_DIR/rebased-$pr" ] && old=$(cat "$SERVE_DIR/rebased-$pr") && [ "$old" != "$sha" ]; then
      if [ "$acted" = false ]; then
        serve_requalify "$t" "$pr" "$old" "$sha" "$ref"
        acted=true
      fi
      continue
    fi
    states=$(serve_states "$sha") || continue
    review=$(jq -r '.["senior-mode/review"] // empty' <<<"$states")
    ci=$(jq -r '.["senior-mode/ci"] // empty' <<<"$states")
    case $review in
      "") [ "$ci" != success ] || serve_review "$t" "$pr" "$sha" "$ref" ;;
      failure | error) serve_changes "$t" "$pr" "$ref" ;;
      success)
        if [ "$acted" = false ] && serve_merge "$t" "$pr" "$sha" "$ref"; then acted=true; fi
        ;;
    esac
  done < <(serve_candidates "$data" "$prs")
}

# One poll: reads the sessions that ended, trips the breaker, then looks at the pull requests In review
# (reviewer sessions, the ticket sessions resumed with findings, at most one merge) and, unless held or at a
# ceiling, starts the Ready tickets in `pick` order while there is a free slot. A hold (breaker, usage limit)
# stops every launch, reviewers and integrator sessions included; a merge needs no session and goes on.
serve_poll() {
  local now reason data prs n size title batch begins capped ticket_wait="" started_before
  local -a queue=()
  now=$(serve_now)
  RUN_STOP=""
  SERVE_HELD="" SERVE_GUARDS="" SERVE_WAIT=""
  run_reap
  serve_report
  serve_breaker
  if SERVE_HELD=$(serve_hold "$now"); then
    echo "serve: not launching: $SERVE_HELD"
  fi
  # An environment pause stops everything but the reading of the sessions that ended: no recovery, no merge, no launch.
  if [ -f "$SERVE_DIR/environment" ]; then
    serve_report
    return 0
  fi
  serve_recover
  serve_ready
  if ! data=$(board_data false); then
    echo "serve: cannot read the board; trying again at the next poll" >&2
    return 0
  fi
  serve_queued
  if prs=$(gh_retry api "repos/$RUN_SLUG/pulls?state=open&per_page=100"); then
    serve_prs "$data" "$prs"
  else
    echo "serve: cannot read the open pull requests; trying again at the next poll" >&2
  fi
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
  done < <(queue_lines "$data")
  for n in "${queue[@]}"; do
    serve_can_launch || break
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
    if [ "${SERVE_SIZE[$n]}" = M ] && [ ! -f "$SERVE_COMMON/senior-mode/runs/$n/red-tests" ]; then
      # An M ticket: its red tests come first, from a session of their own (#191).
      RUN_ROLE[$n]="test-author"
      unset 'RUN_CWD[$n]'
      if run_open "$n"; then
        serve_tests_prompt "$n" "${RUN_TITLE[$n]}" "${RUN_BRANCH[$n]}" >"$RUN_DIR/$n.prompt"
        if run_launch "$n" "$(serve_model "$n")"; then running+=("$n"); fi
      fi
    else
      RUN_ROLE[$n]=ticket
      unset 'RUN_CWD[$n]'
      if run_start "$n"; then running+=("$n"); fi
    fi
    if [ "$begins" = true ] && [ ${#running[@]} -gt "$started_before" ]; then
      echo "$(serve_now) $n" >>"$SERVE_DIR/ticket-starts"
    fi
  done
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

# Once a day (notify.digest, default true) `status --since 24h` is posted as a Project status update (#155). The
# time of the attempt is kept in <serve dir>/digest, so a failure waits for the next day and a restart does not
# post twice.
serve_digest() {
  local now last body
  [ "$(config_get notify.digest)" = true ] || return 0
  now=$(serve_now)
  last=$(cat "$SERVE_DIR/digest" 2>/dev/null) || last=0
  [[ $last =~ ^[0-9]+$ ]] || last=0
  [ $((now - last)) -ge 86400 ] || return 0
  echo "$now" >"$SERVE_DIR/digest"
  if body=$("$SELF" status --since 24h 2>/dev/null) && [ -n "$body" ] && project_post_update "$body"; then
    echo "serve: daily digest posted as a Project status update"
  else
    echo "serve: could not post the daily digest; trying again tomorrow" >&2
  fi
}

# The loop (ADR 0017): the shared part of `run` (run_prepare, run_start, run_reap, run_finish...) with a poll
# every serve.interval seconds instead of a batch. TERM and INT stop the launching and drain. State is under
# <git common dir>/senior-mode/serve/. SENIOR_MODE_SERVE_ONCE=1 polls once, waits for its sessions and exits.
serve_loop() {
  local interval old sleeper
  local -a running=() RUN_MERGED=() RUN_NOT_DONE=() RUN_REVIEWED=() RUN_NOT_REVIEW=() RUN_WAITING=() RUN_FAILED=() RUN_PRS=()
  local -A RUN_TITLE=() RUN_BRANCH=() RUN_WT=() RUN_MODEL=() RUN_ESCALATED=() RUN_REASON=() RUN_STARTED=() RUN_ROLE=() RUN_CWD=() RUN_BATCH=()
  local -A SERVE_PR=() SERVE_SHA=() SERVE_SIZE=() SERVE_NOTED=()
  local RUN_TOKEN RUN_SLUG RUN_BASE RUN_DIR RUN_ROOT RUN_STAMP="" RUN_CLAUDE RUN_MERGE RUN_ESCALATE RUN_MAXFAIL RUN_PROTECTION RUN_REQUIRED RUN_GLOBS RUN_ZONES_KNOWN RUN_TIMEOUT
  local RUN_FAILS=0 RUN_STOP="" RUN_ON_EXIT=serve_end RUN_FINISH=serve_finish RUN_PROMPT=serve_prompt RUN_PROMPT_BATCH=serve_prompt_batch RUN_LAUNCH_LOG
  local SERVE_DIR SERVE_COMMON SERVE_TERM=false SERVE_PARALLEL SERVE_PER_HOUR SERVE_TICKETS_PER_HOUR SERVE_MIN_MEM SERVE_COOLDOWN SERVE_GRACE
  local SERVE_HELD="" SERVE_GUARDS="" SERVE_WAIT=""
  run_prepare serve
  # ADR 0018: under serve everything green merges, unless the repository sets autonomy.merge itself.
  jq -e '(.autonomy // {}) | has("merge")' "$(config_file)" >/dev/null || RUN_MERGE=true
  interval=$(serve_int serve.interval 1)
  SERVE_GRACE=$(serve_int serve.grace 0)
  SERVE_COOLDOWN=$(serve_int serve.breakerCooldown 0)
  SERVE_TICKETS_PER_HOUR=$(serve_int autonomy.ticketsPerHour 1)
  SERVE_PER_HOUR=$(serve_int autonomy.sessionsPerHour 0)
  SERVE_MIN_MEM=$(serve_int autonomy.minMemoryMB 0)
  SERVE_PARALLEL=$(serve_int autonomy.parallel 1)
  # A ticket costs several role sessions (#355): the safety cap is 6 per slot unless the repository sets one.
  [ "$SERVE_PER_HOUR" -gt 0 ] || SERVE_PER_HOUR=$((6 * SERVE_PARALLEL))
  SERVE_COMMON=$(git rev-parse --path-format=absolute --git-common-dir)
  SERVE_DIR=$SERVE_COMMON/senior-mode/serve
  RUN_DIR=$SERVE_DIR
  RUN_LAUNCH_LOG=$SERVE_DIR/launches
  mkdir -p "$SERVE_DIR"
  old=$(cat "$SERVE_DIR/serve.pid" 2>/dev/null) || old=""
  if [[ $old =~ ^[0-9]+$ ]] && kill -0 "$old" 2>/dev/null && [[ $(ps -o args= -p "$old" 2>/dev/null) == *senior-mode* ]]; then
    die "serve already runs in this repository (pid $old)"
  fi
  echo $$ >"$SERVE_DIR/serve.pid"
  # shellcheck disable=SC2064 # expand now: SERVE_DIR is local and gone when the trap runs
  trap "rm -f '$SERVE_DIR/serve.pid' '$SERVE_DIR/token'" EXIT
  trap 'SERVE_TERM=true' INT TERM
  run_token_new
  "$SELF" clean || echo "senior-mode: clean failed; serve goes on" >&2
  security_alerts || echo "senior-mode: could not check the security alerts; serve goes on" >&2
  echo "serve: polling every ${interval}s, $SERVE_PARALLEL session(s) at a time; sessions and state in $SERVE_DIR"
  while [ "$SERVE_TERM" = false ]; do
    serve_poll
    serve_digest
    [ -z "${SENIOR_MODE_SERVE_ONCE:-}" ] || break
    sleep "$interval" &
    sleeper=$!
    wait "$sleeper" || true
    kill "$sleeper" 2>/dev/null || true
  done
  serve_drain
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
    "") serve_loop ;;
    --resume)
      if [ -f "$common/senior-mode/serve/paused" ] || [ -f "$common/senior-mode/serve/environment" ]; then
        rm -f "$common/senior-mode/serve/paused" "$common/senior-mode/serve/environment" "$common/senior-mode/serve/trips" \
          "$common/senior-mode/serve/transient-until"
        echo "resumed: the circuit breaker's and the environment's pause are lifted"
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
