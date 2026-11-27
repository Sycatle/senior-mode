# shellcheck shell=bash
# The time a usage limit lifts, read from the message of the session ($1) at time $2: "limit reached|<epoch>"
# or "resets 3pm (Europe/Paris)". Returns 1, printing nothing, when the message gives none.
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
  return 1
}

# The signals of a class of session end, as one extended regular expression, matched case-insensitively (spec 373,
# section 1). A new message is a one-line change here, with a fixture in the tests.
serve_patterns() {
  case $1 in
    limit) echo 'limit reached|hit your( [a-z-]+)? limit|usage limit' ;;
    disk) echo 'ENOSPC|no space left on device|disk quota exceeded' ;;
    gh-auth) echo 'gh auth login|HTTP 401|bad credentials|not logged in to (any )?github' ;;
    claude-auth) echo 'invalid api key|please run /login|oauth token[^.]*expired|authentication_error|invalid bearer token|API Error: 401|credit balance is too low' ;;
    deps) echo 'dependencies not installed|ERR_PNPM_(FETCH|NO_MATCHING|TARBALL)|npm (ERR!|error) code E(404|TARGET|RESOLVE|INTEGRITY)|No matching distribution found' ;;
    main-red) echo 'main is red|red on main|base branch is red|fails on a clean checkout of main' ;;
    startup) echo 'still loading your organization' ;;
    transient) echo 'EAI_AGAIN|ENOTFOUND|ECONNRESET|ECONNREFUSED|ETIMEDOUT|EHOSTUNREACH|ENETUNREACH|getaddrinfo|socket hang up|could not resolve host|temporary failure in name resolution|network is unreachable|unable to connect|connection error|fetch failed|error connecting to api\.|API Error: (429|5[0-9][0-9])|HTTP 5[0-9][0-9]|overloaded_error|\boverloaded\b|"type": ?"api_error"|internal server error|bad gateway|service unavailable|gateway time-?out|still loading your organization|cannot allocate memory|ENOMEM|(connection|request|operation|gh|git|API) (call )?timed out' ;;
  esac
}

# The delay before the $1-th transient end in a row is tried again: serve.backoffBase seconds doubled at each end in a
# row, serve.backoffMax at most, plus 0 to 20 % of jitter (SENIOR_MODE_BACKOFF_JITTER stands in for the percentage).
serve_backoff() {
  local k=$1 delay=$SERVE_BACKOFF_BASE i jit
  for ((i = 1; i < k && delay < SERVE_BACKOFF_MAX; i++)); do delay=$((delay * 2)); done
  [ "$delay" -le "$SERVE_BACKOFF_MAX" ] || delay=$SERVE_BACKOFF_MAX
  jit=${SENIOR_MODE_BACKOFF_JITTER:-$((RANDOM % 21))}
  echo $((delay + delay * jit / 100))
}

# RUN_ON_EXIT of serve (see run_reap): a session that ended on the subscription usage limit and said nothing
# of its ticket is not a failure. Nothing is launched until the reset time plus a minute (limit-until), and the ticket
# of a ticket or test-author session goes back to Ready, its worktree and branch kept, for the first poll after it.
# A message with no reset time waits 5, 10, 20, 40, then 60 minutes (limit-streak counts the ends in a row).
serve_limit() {
  local n=$1 text until now streak wait
  [ ! -s "$RUN_DIR/$n.outcome" ] || return 1
  text=$({
    head -c 20000 "$RUN_DIR/$n-${RUN_MODEL[$n]}.json" 2>/dev/null
    head -c 20000 "$RUN_DIR/$n-${RUN_MODEL[$n]}.log" 2>/dev/null
  } || true)
  grep -qiE "$(serve_patterns limit)" <<<"$text" || return 1
  now=$(serve_now)
  if until=$(serve_reset "$text" "$now"); then
    until=$((until + 60))
    rm -f "$SERVE_DIR/limit-streak"
  else
    streak=$(state_update state_counter_add "$SERVE_DIR/limit-streak") || streak=1
    wait=$((5 << (streak < 5 ? streak - 1 : 4)))
    [ "$wait" -le 60 ] || wait=60
    until=$((now + wait * 60))
  fi
  state_update state_keep_later "$SERVE_DIR/limit-until" "$until" || true
  echo "#$n: the session hit the usage limit; nothing is launched until $(date -d "@$until" '+%F %T' 2>/dev/null || echo "$until")" >&2
  # The ticket goes back to Ready: its start is not one against autonomy.ticketsPerHour (#355).
  [ "${RUN_ROLE[$n]:-ticket}" != ticket ] || serve_start_back "$n"
  serve_give_back "$n"
  return 0
}

# A session that ended without a verdict on its ticket, for a reason that is not the ticket's (a usage limit, a
# transient error, the environment): a reviewer, an integrator or a framer leaves no status, the pull request is looked at again
# at a later poll; the ticket of any other session goes back to Ready, its worktree and branch kept, for a later poll.
serve_give_back() {
  local n=$1 m
  case ${RUN_ROLE[$n]:-ticket} in
    reviewer | integrator | framer) [ -z "${RUN_CWD[$n]:-}" ] || git worktree remove --force "${RUN_CWD[$n]}" 2>/dev/null || true ;;
    *)
      for m in $(run_members "$n"); do
        (item_set "$m" Status Ready) >/dev/null || echo "#$m: could not set the Status back to Ready" >&2
      done
      ;;
  esac
}

# Why a session ended, the classes of spec 373 section 1, from its outcome, its exit code and the end of its output.
# Prints `class|cause|why`: `environment` (the machine, not the ticket: disk, gh or Claude auth, dependencies, main red;
# hold every launch), `transient` (network, API 5xx, memory, a startup error: resume on the same model with a backoff,
# nothing counted; the cause is `startup` for a session that died at once) or `ticket` (anything else: the retry,
# escalation and needs-human path). The session's own verdict (`delivered`, `outgrown`, `failed`) is a ticket's, but
# for `failed: environment:`, which is the session saying that the machine is the problem; a session that left no
# verdict and exited 0 is a ticket's too. Only an output that goes with a non-zero exit is read, so a retried request
# in the log of a session that went on is not a cause.
serve_classify() {
  local n=$1 outcome code text why cause="" life re c
  outcome=$(cat "$RUN_DIR/$n.outcome" 2>/dev/null) || outcome=""
  code=$(cat "$RUN_DIR/$n.exit" 2>/dev/null) || code=0
  if [ -n "$outcome" ]; then
    if ! grep -qiE '(^|^#[0-9]+ )failed: environment:' <<<"$outcome"; then
      echo "ticket||"
      return 0
    fi
    text=$outcome
    cause=unknown
  else
    if [ "$code" = 0 ]; then
      echo "ticket||"
      return 0
    fi
    text=$({
      tail -c 8000 "$RUN_DIR/$n-${RUN_MODEL[$n]}.json" 2>/dev/null
      tail -c 8000 "$RUN_DIR/$n-${RUN_MODEL[$n]}.log" 2>/dev/null
    } || true)
  fi
  for c in disk gh-auth claude-auth deps main-red; do
    re=$(serve_patterns "$c")
    if grep -qiE "$re" <<<"$text"; then
      why=$(grep -iE "$re" <<<"$text" | head -n 1 | cut -c1-200)
      echo "environment|$c|$why"
      return 0
    fi
  done
  if [ -n "$cause" ]; then
    why=$(grep -iE 'failed: environment:' <<<"$text" | head -n 1 | cut -c1-200)
    echo "environment|$cause|$why"
    return 0
  fi
  life=$((SECONDS - ${RUN_STARTED[$n]:-$SECONDS}))
  if [ "$code" = 1 ] && [ "$life" -lt "$SERVE_STARTUP" ] &&
    { grep -qiE "$(serve_patterns startup)" <<<"$text" || [ -z "$(tr -d '[:space:]' <<<"$text")" ]; }; then
    why=$(head -c 200 <<<"$text" | tr '\n' ' ')
    echo "transient|startup|${why:-the session died at startup with no output}"
    return 0
  fi
  re=$(serve_patterns transient)
  if grep -qiE "$re" <<<"$text"; then
    echo "transient||$(grep -iE "$re" <<<"$text" | head -n 1 | cut -c1-200)"
    return 0
  fi
  echo "ticket||"
}

# RUN_ON_EXIT of serve (see run_reap): a session that ended on the usage limit is serve_limit's. Any other end is
# classified (serve_classify): a transient one (#334, #377) is resumed on the same model after an exponential backoff,
# an environment one holds every launch (serve_hold_set); neither is a failure for the breaker, nor an escalation, nor,
# when the session died at once, a launch against autonomy.sessionsPerHour. A ticket's end goes on to RUN_FINISH, but
# first the cheap probes run (serve_probe_cheap): "diagnose before blame". An end with no verdict on which one is red
# is the environment's, not the ticket's; a session's own `failed:` verdict stands, the hold starts before the next
# launch. A ticket's end clears the backoffs. Returns 0 when it took care of the end.
serve_end() {
  local n=$1 class cause why diag
  serve_limit "$n" && return 0
  IFS='|' read -r class cause why < <(serve_classify "$n")
  case $class in
    environment)
      serve_environment "$n" "$cause" "#$n: ${why:-the session ended on an environment problem}"
      return 0
      ;;
    transient)
      serve_transient "$n" "$cause" "$why"
      return 0
      ;;
  esac
  serve_settled "$n"
  if diag=$(serve_probe_cheap); then
    IFS='|' read -r cause why <<<"$diag"
    if [ ! -s "$RUN_DIR/$n.outcome" ]; then
      serve_environment "$n" "$cause" "#$n ended with no verdict: $why"
      return 0
    fi
    serve_hold_set "$cause" "after #$n: $why"
  fi
  return 1
}

# A session of the ticket $1 that ended for the ticket's own reasons: its transient backoff, the streak of sessions that
# died at startup and the usage limit's streak are over. A ticket that was retried ten times in a row has recovered.
serve_settled() {
  local n=$1 count
  count=$(state_num "$SERVE_DIR/$n.transient")
  if [ "$count" -ge 10 ]; then
    echo "#$n: the API answers again after $count transient ends"
    notify recovered "" "#$n: the session ran again after $count transient ends in a row"
  fi
  rm -f "$SERVE_DIR/$n.transient" "$SERVE_DIR/$n.resumed" "$SERVE_DIR/$n.retry" "$SERVE_DIR/$n.model" "$SERVE_DIR/startup-streak" \
    "$SERVE_DIR/launch-backoff-until" "$SERVE_DIR/limit-streak" "$SERVE_DIR/$n.envfail" "$SERVE_DIR/$n.envhold"
}

# A session of the ticket $1 ended on a problem of the environment ($2 the cause, $3 the diagnosis): the ticket goes back
# to Ready, nothing is counted, and every launch is held (serve_hold_set) until a probe is green. A full disk is first
# cleaned (serve_disk_clean); once there is room again the end is only a transient one. A cause serve does not recognise
# (`unknown`, the session's own words) has nothing to probe: it is serve_unknown's.
serve_environment() {
  local n=$1 cause=$2 why=$3 detail
  if [ "$cause" = unknown ]; then
    serve_unknown "$n" "$why"
    return 0
  fi
  if [ "$cause" = disk ]; then
    serve_disk_clean
    if detail=$(serve_probe disk); then
      serve_transient "$n" "" "$why"
      return 0
    fi
    why="$why ($detail)"
  fi
  serve_give_back "$n"
  serve_hold_set "$cause" "$why"
}

# What a poll of the unknown environment problem compares: the plugin version and SHA, and the head of the default branch
# (fetched first). A change in it is the one thing that says a new attempt may end differently.
serve_fingerprint() {
  local v sha
  v=$(jq -r '.version // empty' "$(plugin_root)/.claude-plugin/plugin.json" 2>/dev/null) || v=""
  sha=$(git -C "$(plugin_root)" rev-parse -q --verify HEAD 2>/dev/null) || sha=""
  git_bound fetch -q origin 2>/dev/null || true
  printf '%s %s %s\n' "${v:-none}" "${sha:0:12}" "$(git rev-parse -q --verify "$RUN_BASE^{commit}" 2>/dev/null)"
}

# Run by state_update: counts the end of the ticket $2 on an unknown environment problem, in <n>.envfail (`count
# fingerprint`); a fingerprint that is not the one of the last end starts the count again. Prints the count.
serve_unknown_count() {
  local file=$1 fp=$2 line count=0 last=""
  if line=$(state_get "$file" '[0-9]+ .*'); then
    count=${line%% *}
    last=${line#* }
  fi
  [ "$last" = "$fp" ] || count=0
  count=$((count + 1))
  state_put "$file" "$count $fp" && echo "$count"
}

# A session of the ticket $1 ended on `failed: environment:` with a cause serve has no pattern, and so no probe, for ($2
# the session's words). Only that ticket waits (#630): <n>.envhold, `<retryAt> <fingerprint>`, keeps it from launching
# (serve_env_held) while the plugin and the head of the default branch are the same, since a change is the only thing that
# says a new attempt may end differently (a fix may have landed); else the owner's `serve --resume`. Without a change it
# retries after 1, 2, 4... minutes (serve.unknownBackoffMax minutes at most); the serve.unknownMaxAttempts-th end in a row
# stops the retries: the ticket is needs-human with the last output, and the wait lasts until a change or `--resume`, which
# also start the count again. One alert for the ticket (the first end), one decision (the last); a retry says nothing more.
serve_unknown() {
  local n=$1 why=$2 fp count now delay=0 retry=0 out=""
  fp=$(serve_fingerprint)
  count=$(state_update serve_unknown_count "$SERVE_DIR/$n.envfail" "$fp") || count=1
  now=$(serve_now)
  if [ "$count" -lt "$SERVE_UNKNOWN_MAX" ]; then
    delay=$((60 * (1 << (count - 1 < 20 ? count - 1 : 20))))
    [ "$delay" -le $((SERVE_UNKNOWN_CAP * 60)) ] || delay=$((SERVE_UNKNOWN_CAP * 60))
    retry=$((now + delay))
  fi
  state_put "$SERVE_DIR/$n.envhold" "$retry $fp"
  if [ "$count" -eq 1 ]; then
    notify environment "" "#$n: environment problem serve does not recognise ($why); only this ticket waits"
  fi
  if [ "$retry" -gt 0 ]; then
    echo "#$n: unknown environment failure $count of $SERVE_UNKNOWN_MAX ($why); the same ticket is not launched again before $(date -d "@$retry" '+%F %T' 2>/dev/null || echo "$retry"), or before the plugin or $RUN_BASE changes" >&2
    serve_give_back "$n"
    return 0
  fi
  out=$(tail -c 600 "$RUN_DIR/$n-${RUN_MODEL[$n]:-sonnet}.log" 2>/dev/null | tr -d '\000') || out=""
  echo "#$n: unknown environment failure $count of $SERVE_UNKNOWN_MAX ($why); not relaunched, needs-human" >&2
  case ${RUN_ROLE[$n]:-ticket} in reviewer | integrator | framer) serve_give_back "$n" ;; esac
  notify needs-human "$n" "the session ended on an environment failure serve does not recognise $count times in a row, and it was not relaunched again. Last error: $why${out:+
Last output of the session:
$out}
Fix the environment, then remove needs-human; serve launches it again after a new plugin version, a new commit on $RUN_BASE or senior-mode serve --resume."
}

# The board $1 without the tickets that must not launch (#630): those labelled needs-human, and those that wait on an
# environment problem of their own (serve_env_held). Taken out before the queue and its batches are made, so that a
# batch is not lost with its lead.
serve_unheld() {
  local f n held=" "
  for f in "$SERVE_DIR"/*.envhold; do
    [ -e "$f" ] || continue
    n=${f##*/}
    n=${n%.envhold}
    [[ $n =~ ^[0-9]+$ ]] || continue
    if serve_env_held "$n"; then held+="$n "; fi
  done
  jq -c --arg h "$held" '.items |= map(select((.labels | index("needs-human") | not) and (" \(.number) " as $k | $h | contains($k) | not)))' <<<"$1" ||
    printf '%s\n' "$1"
}

# Is the ticket $1 waiting on an unknown environment problem of its own (serve_unknown)? Not once its backoff is over, or
# when the plugin or the default branch changed since: the wait is then lifted (its file goes). A ticket whose attempts are
# used up waits for a change or `--resume`, and says so at each poll.
serve_env_held() {
  local n=$1 file=$SERVE_DIR/$1.envhold line retry fp
  [ -s "$file" ] || return 1
  line=$(state_get "$file" '[0-9]+ .*') || line=""
  retry=${line%% *}
  fp=${line#* }
  [ -n "$line" ] || {
    rm -f "$file"
    return 1
  }
  [ -n "${SERVE_FP:-}" ] || SERVE_FP=$(serve_fingerprint)
  if [ "$SERVE_FP" != "$fp" ] || { [ "$retry" -gt 0 ] && [ "$(serve_now)" -ge "$retry" ]; }; then
    rm -f "$file"
    echo "serve: #$n: the wait on its unknown environment failure is over, trying the ticket again" >&2
    return 1
  fi
  [ "$retry" -gt 0 ] || echo "serve: #$n: unknown environment failure, attempts used up; waiting for a new plugin version or commit on $RUN_BASE, or senior-mode serve --resume" >&2
  return 0
}

# A transient end of the session $1 (cause $2, `startup` for one that died at once; why $3): it goes back to Ready, its
# worktree kept, and is started again on the same model (<n>.model) once its backoff (<n>.retry) is over, serve_backoff
# seconds. Nothing else launches meanwhile (transient-until). A transient end never becomes a ticket's failure: after 10
# in a row one environment alert goes out and the retries go on at the longest delay. The third session in a row, across
# tickets, that died at startup holds every launch (launch-backoff-until: the time, then the streak).
serve_transient() {
  local n=$1 cause=$2 why=$3 count delay now until model=${RUN_MODEL[$1]} life streak
  count=$(state_update state_counter_add "$SERVE_DIR/$n.transient") || count=1
  delay=$(serve_backoff "$count")
  now=$(serve_now)
  until=$((now + delay))
  state_put "$SERVE_DIR/$n.retry" "$until"
  case ${RUN_ROLE[$n]:-ticket} in reviewer | integrator | framer) ;; *) state_put "$SERVE_DIR/$n.model" "$model" ;; esac
  state_update state_keep_later "$SERVE_DIR/transient-until" "$until" || true
  # A session that died at once (a startup error) is not a launch against autonomy.sessionsPerHour.
  life=$((SECONDS - ${RUN_STARTED[$n]:-$SECONDS}))
  if [ "$life" -lt 60 ] && [ -n "${RUN_LAUNCH_LOG:-}" ]; then
    state_update serve_launch_drop "$n" || true
  fi
  # Nor a ticket start against autonomy.ticketsPerHour (#355): its last start is taken back.
  [ "$life" -ge 60 ] || serve_start_back "$n"
  echo "#$n: the session ended on a transient error ($why); it resumes on $model in ${delay}s (end $count in a row), not counted as a failure" >&2
  if [ "$cause" = startup ]; then
    streak=$(state_update state_counter_add "$SERVE_DIR/startup-streak") || streak=1
    if [ "$streak" -ge 3 ]; then
      until=$((now + $(serve_backoff "$streak")))
      state_put "$SERVE_DIR/launch-backoff-until" "$until"
      echo "serve: $streak sessions in a row died at startup; not launching until $(date -d "@$until" '+%F %T' 2>/dev/null || echo "$until")" >&2
    fi
  fi
  if [ "$count" -eq 10 ]; then
    echo "serve: #$n: 10 transient ends in a row; retrying every ${SERVE_BACKOFF_MAX}s" >&2
    notify environment "" "#$n: the API or the network has been unreachable for about an hour ($why); retrying every ${SERVE_BACKOFF_MAX}s"
  fi
  serve_give_back "$n"
}

# The time before which the ticket $1 is not started again (its transient backoff), 0 when none.
serve_retry_at() {
  state_num "$SERVE_DIR/$1.retry"
}

# The model of the next session of ticket $1: the one a transient end interrupted, else Sonnet.
serve_model() {
  local m
  m=$(state_get "$SERVE_DIR/$1.model" 'sonnet|opus') || m=""
  echo "${m:-sonnet}"
}
