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

# The last start of the ticket $1 is taken back from ticket-starts.
serve_start_back() {
  [ -s "$SERVE_DIR/ticket-starts" ] || return 0
  state_update serve_starts_drop "$1" || true
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
    "$SERVE_DIR/launch-backoff-until" "$SERVE_DIR/limit-streak" "$SERVE_DIR/$n.envfail"
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
# the session's words). The only probe is a change: the plugin version or SHA, or the head of the default branch (a fix
# may have landed), else the owner's `serve --resume`. The hold (cause `unknown`) retries without a change after 1, 2, 4...
# minutes (serve.unknownBackoffMax minutes at most); the serve.unknownMaxAttempts-th end in a row stops the retries: the
# ticket is needs-human with the last output, and the hold waits for a change or `--resume`, which also start the count again.
# One alert for the whole pause (the first end), one decision (the last); a retry or a lift by timer says nothing more.
serve_unknown() {
  local n=$1 why=$2 fp count now delay=0 retry=0 out="" quiet=true
  fp=$(serve_fingerprint)
  count=$(state_update serve_unknown_count "$SERVE_DIR/$n.envfail" "$fp") || count=1
  now=$(serve_now)
  if [ "$count" -lt "$SERVE_UNKNOWN_MAX" ]; then
    delay=$((60 * (1 << (count - 1 < 20 ? count - 1 : 20))))
    [ "$delay" -le $((SERVE_UNKNOWN_CAP * 60)) ] || delay=$((SERVE_UNKNOWN_CAP * 60))
    retry=$((now + delay))
  fi
  [ "$count" -gt 1 ] || quiet=false
  serve_hold_set unknown "$why" "$fp" "$retry" "$quiet"
  if [ "$retry" -gt 0 ]; then
    echo "#$n: unknown environment failure $count of $SERVE_UNKNOWN_MAX ($why); the same ticket is not launched again before $(date -d "@$retry" '+%F %T' 2>/dev/null || echo "$retry"), or before the plugin or $RUN_BASE changes" >&2
    serve_give_back "$n"
    return 0
  fi
  out=$(tail -c 600 "$RUN_DIR/$n-${RUN_MODEL[$n]:-sonnet}.log" 2>/dev/null | tr -d '\000') || out=""
  echo "#$n: unknown environment failure $count of $SERVE_UNKNOWN_MAX ($why); not relaunched, needs-human" >&2
  case ${RUN_ROLE[$n]:-ticket} in reviewer | integrator) serve_give_back "$n" ;; esac
  notify needs-human "$n" "the session ended on an environment failure serve does not recognise $count times in a row, and it was not relaunched again. Last error: $why${out:+
Last output of the session:
$out}
Fix the environment, then remove needs-human; serve launches again after a new plugin version, a new commit on $RUN_BASE or senior-mode serve --resume."
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
  case ${RUN_ROLE[$n]:-ticket} in reviewer | integrator) ;; *) state_put "$SERVE_DIR/$n.model" "$model" ;; esac
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

# Every launch is held, until the environment is healthy (#377): `held` in the serve dir is one JSON object, {cause, since,
# probe (cheap or expensive), nextProbe, detail}. The diagnosis $2 of the cause $1 is on stderr, in the webhook (event
# environment) and in a Project status update, once: the first diagnosis stands while the hold lasts. serve_hold probes
# again (cheap probes at every poll, expensive ones, the Claude ping and the dependencies, every 5 minutes, then every 15
# once the hold is an hour old) and lifts the hold on its own when the probe is green; `serve --resume` lifts it by hand.
serve_hold_set() {
  local cause=$1 detail=$2 fp=${3:-} retry=${4:-0} quiet=${5:-false} now kind=cheap next
  [ ! -s "$SERVE_DIR/held" ] || return 0
  now=$(serve_now)
  case $cause in claude-auth | deps) kind=expensive ;; esac
  next=$now
  [ "$kind" = cheap ] || next=$((now + 300))
  state_update serve_hold_write "$cause" "$detail" "$now" "$kind" "$next" "$fp" "$retry" || return 0
  echo "serve: holding all launches, environment problem ($cause): $detail; probing again, or senior-mode serve --resume" >&2
  # An unknown problem that came back after its backoff is the same pause: no second alert.
  [ "$quiet" = false ] || return 0
  notify environment "" "serve holds all launches, environment problem ($cause): $detail"
  project_post_update "senior-mode serve holds all launches: environment problem ($cause): $detail. It resumes by itself once the probe is green." AT_RISK >/dev/null 2>&1 ||
    echo "serve: could not post the hold as a Project status update" >&2
}

# Run by state_update: writes the hold, unless there is one.
serve_hold_write() {
  [ ! -s "$SERVE_DIR/held" ] || return 1
  jq -nc --arg c "$1" --arg d "$2" --argjson s "$3" --arg k "$4" --argjson x "$5" --arg f "${6:-}" --argjson r "${7:-0}" \
    '{cause: $c, since: $s, probe: $k, nextProbe: $x, detail: $d} + (if $f == "" then {} else {fingerprint: $f, retryAt: $r} end)' |
    state_write "$SERVE_DIR/held"
}

# A field of the hold, empty when there is none; a file that does not parse is set aside (state_json).
serve_held() {
  local j
  j=$(state_json "$SERVE_DIR/held") || return 0
  jq -r --arg k "$1" '.[$k] // empty' <<<"$j" 2>/dev/null || true
}

# Run by state_update: the next probe and the diagnosis of the hold.
serve_hold_next() {
  jq -c --argjson x "$1" --arg d "$2" '.nextProbe = $x | .detail = $d' "$SERVE_DIR/held" | state_write "$SERVE_DIR/held"
}

# Is the hold one that stops the board too (gh or Claude not signed in)? Any other hold stops launches only: a merge
# needs no session, and the pull request that fixes a red main has to land.
serve_held_auth() {
  case $(serve_held cause) in gh-auth | claude-auth) return 0 ;; esac
  return 1
}

# Free megabytes where $1 is (SENIOR_MODE_DISK_FREE_FILE, a file holding a number, and SENIOR_MODE_DISK_FREE_MB stand in
# for the tests).
serve_disk_free() {
  [ -z "${SENIOR_MODE_DISK_FREE_FILE:-}" ] || [ ! -s "$SENIOR_MODE_DISK_FREE_FILE" ] || {
    cat "$SENIOR_MODE_DISK_FREE_FILE"
    return 0
  }
  [ -z "${SENIOR_MODE_DISK_FREE_MB:-}" ] || {
    echo "$SENIOR_MODE_DISK_FREE_MB"
    return 0
  }
  df -Pk "$1" 2>/dev/null | awk 'NR == 2 { print int($4 / 1024) }'
}

# Makes room: `senior-mode clean`, the session logs and outputs over 7 days, dangling worktree registrations.
serve_disk_clean() {
  echo "serve: low on disk; cleaning merged branches and worktrees, session logs over 7 days" >&2
  "$SELF" clean >/dev/null 2>&1 || true
  find "$SERVE_DIR" -maxdepth 1 -type f \( -name '*.log' -o -name '*-*.json' \) -mtime +7 -delete 2>/dev/null || true
  git worktree prune 2>/dev/null || true
}

# Probe: room for the worktrees (the repository's file system) and for the temporary files.
serve_probe_disk() {
  local path free
  for path in "$RUN_ROOT" "${TMPDIR:-/tmp}"; do
    free=$(serve_disk_free "$path")
    [[ $free =~ ^[0-9]+$ ]] || continue
    if [ "$free" -lt "$SERVE_MIN_DISK" ]; then
      echo "disk full, $free MB free of autonomy.minDiskMB $SERVE_MIN_DISK on $(df -P "$path" 2>/dev/null | awk 'NR == 2 { print $6 }')"
      return 1
    fi
  done
}

# Probe: `senior-mode/ci` of the base head is not red (a missing or pending status is not).
serve_probe_main() {
  local sha ci
  git_bound fetch -q origin 2>/dev/null || true
  sha=$(git rev-parse -q --verify "$RUN_BASE^{commit}") || return 0
  ci=$(serve_states "$sha" | jq -r '.["senior-mode/ci"] // empty') || return 0
  case $ci in
    failure | error)
      echo "senior-mode/ci is $ci on $RUN_BASE (${sha:0:7})"
      return 1
      ;;
  esac
}

# Probe: the install command of the base branch passes on a detached worktree of it, as its sessions would find it.
serve_probe_deps() {
  local wt cmd rc=0
  git_bound fetch -q origin 2>/dev/null || true
  wt=$(worktree_path "$RUN_ROOT" "probe-env")
  git worktree remove --force "$wt" 2>/dev/null || true
  git worktree add -q --detach "$wt" "$RUN_BASE" 2>/dev/null || return 0
  cmd=$(install_command "$wt")
  if [ -n "$cmd" ] && ! (cd "$wt" && net_bound 900 bash -c "$cmd" </dev/null) >/dev/null 2>&1; then rc=1; fi
  git worktree remove --force "$wt" 2>/dev/null || true
  [ "$rc" -eq 0 ] || echo "the install command fails on $RUN_BASE"
  return "$rc"
}

# Probe: an unknown environment problem has nothing to test. It is over when the plugin or the default branch changed, or,
# while attempts are left, when its backoff is (retryAt, 0 once they are used up).
serve_probe_unknown() {
  local fp at
  serve_probe_disk || return 1
  serve_probe gh-auth || return 1
  fp=$(serve_held fingerprint)
  [ -n "$fp" ] || return 0
  [ "$(serve_fingerprint)" = "$fp" ] || return 0
  at=$(serve_held retryAt)
  if [[ $at =~ ^[0-9]+$ ]] && [ "$at" -gt 0 ]; then
    [ "$(serve_now)" -lt "$at" ] || return 0
    echo "unknown environment failure; retrying at $at, or when the plugin or $RUN_BASE changes"
  else
    echo "unknown environment failure, attempts used up; waiting for a new plugin version or commit on $RUN_BASE, or senior-mode serve --resume"
  fi
  return 1
}

# Is the environment healthy for the cause $1? Prints the diagnosis and returns 1 when it is not. disk: room again;
# gh-auth: gh answers; claude-auth: `claude auth status`, else a one-word haiku session answers; deps: the install
# command of the base branch passes; main-red: senior-mode/ci is not red on the base head; unknown: disk and gh, then
# a change since the hold (serve_fingerprint) or the end of its backoff (retryAt).
serve_probe() {
  local out
  case $1 in
    disk) serve_probe_disk ;;
    gh-auth) gh_bound auth status >/dev/null 2>&1 || {
      echo "gh is not signed in, or does not answer (gh auth status)"
      return 1
    } ;;
    claude-auth)
      net_bound 30 "$RUN_CLAUDE" auth status >/dev/null 2>&1 </dev/null && return 0
      out=$(cd "$RUN_ROOT" && net_bound 180 "$RUN_CLAUDE" -p --model haiku "Reply with the single word ok." 2>&1 </dev/null) &&
        ! grep -qiE "$(serve_patterns claude-auth)|/login" <<<"$out" || {
        echo "claude is not signed in, or does not answer"
        return 1
      }
      ;;
    deps) serve_probe_deps ;;
    main-red) serve_probe_main ;;
    unknown) serve_probe_unknown ;;
    *) serve_probe_disk && serve_probe gh-auth ;;
  esac
}

# The cheap probes (disk, gh, main): prints `cause|diagnosis` of the first that is red and returns 0; returns 1 when all
# are green. Run at each poll of a hold, and when a session ends with no verdict, before anyone is blamed.
serve_probe_cheap() {
  local c d
  for c in disk gh-auth main-red; do
    if ! d=$(serve_probe "$c"); then
      echo "$c|$d"
      return 0
    fi
  done
  return 1
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
  local n=$1 outcome reason="" red rc=0
  outcome=$(head -n 1 "$RUN_DIR/$n.outcome" 2>/dev/null) || outcome=""
  if [ "$outcome" = delivered ]; then
    red=$(cd "${RUN_WT[$n]}" && "$SELF" red-tests record "$n" 2>&1) || rc=$?
    printf '%s\n' "$red" | state_write "$RUN_DIR/$n.red"
    if [ "$rc" -eq 0 ]; then
      RUN_ROLE[$n]=ticket
      serve_prompt "$n" "${RUN_TITLE[$n]:-}" "${RUN_BRANCH[$n]}" | state_write "$RUN_DIR/$n.prompt"
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
  local n=$1 pr=${SERVE_PR[$1]} sha=${SERVE_SHA[$1]} review desc model=${RUN_MODEL[$1]}
  [ -z "${RUN_CWD[$n]:-}" ] || git worktree remove --force "${RUN_CWD[$n]}" 2>/dev/null || true
  review=$(serve_states "$sha" | jq -r '.["senior-mode/review"] // empty') || review=""
  if [ -n "$review" ]; then
    # The model that reviewed is in the description of the status (#304), whoever wrote it.
    desc=$(gh_retry api "repos/$RUN_SLUG/commits/$sha/status" --jq '[.statuses[] | select(.context == "senior-mode/review") | .description // ""][0] // ""') || desc=""
    case $desc in
      "reviewed on $model"*) ;;
      *) gh_retry api "repos/$RUN_SLUG/statuses/$sha" -f state="$review" -f context=senior-mode/review \
        -f description="reviewed on $model${desc:+: ${desc:0:100}}" >/dev/null || echo "#$n: could not record the reviewer model on ${sha:0:7}" >&2 ;;
    esac
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
  local now=$1 until cause diag since next now_diag retried
  if [ -f "$SERVE_DIR/paused" ]; then
    until=$(state_get "$SERVE_DIR/paused" '[0-9]+') || until=""
    if [[ $until =~ ^[0-9]+$ ]] && [ "$now" -lt "$until" ]; then
      echo "paused by the circuit breaker, $(sed -n 2p "$SERVE_DIR/paused"); resumes at $until or with senior-mode serve --resume"
      return 0
    fi
    if [ -e "$SERVE_DIR/paused" ]; then
      rm -f "$SERVE_DIR/paused"
      echo "serve: the breaker cooldown is over, launching again" >&2
    fi
  fi
  if [ -s "$SERVE_DIR/held" ]; then
    cause=$(serve_held cause)
    next=$(serve_held nextProbe)
    diag=$(serve_held detail)
    since=$(serve_held since)
    [ -n "$cause" ] && [[ $next =~ ^[0-9]+$ ]] && [[ $since =~ ^[0-9]+$ ]] || {
      state_quarantine "$SERVE_DIR/held"
      cause=""
    }
    if [ -n "$cause" ] && [ "$now" -ge "$next" ]; then
      if now_diag=$(serve_probe "$cause"); then
        retried=false
        [ "$cause" != unknown ] || [ "$(serve_fingerprint)" != "$(serve_held fingerprint)" ] || retried=true
        rm -f "$SERVE_DIR/held"
        if [ "$retried" = true ]; then
          echo "serve: the backoff of the unknown environment problem is over, trying the ticket again" >&2
        else
          echo "serve: the environment is healthy again (probe for $cause is green), launching again" >&2
          notify recovered "" "serve launches again: the probe for $cause is green"
          project_post_update "senior-mode serve resumed: the probe for $cause is green." ON_TRACK >/dev/null 2>&1 || true
        fi
        cause=""
      else
        case $(serve_held probe) in
          expensive) next=$((now + (now - since < 3600 ? 300 : 900))) ;;
          *) next=$now ;;
        esac
        state_update serve_hold_next "$next" "${now_diag:-$diag}" || true
        diag=${now_diag:-$diag}
        echo "serve: still holding all launches, environment problem ($cause): the probe is red" >&2
      fi
    fi
    if [ -n "$cause" ]; then
      echo "held, environment problem ($cause): $diag; next probe at $next"
      return 0
    fi
  fi
  until=$(state_get "$SERVE_DIR/launch-backoff-until" '[0-9]+') || until=""
  if [[ $until =~ ^[0-9]+$ ]] && [ "$now" -lt "$until" ]; then
    echo "sessions died at startup in a row, resumes at $until"
    return 0
  fi
  until=$(state_get "$SERVE_DIR/limit-until" '[0-9]+') || until=""
  if [[ $until =~ ^[0-9]+$ ]]; then
    if [ "$now" -lt "$until" ]; then
      echo "usage limit reached, resumes at $until"
      return 0
    fi
    rm -f "$SERVE_DIR/limit-until"
  fi
  until=$(state_get "$SERVE_DIR/transient-until" '[0-9]+') || until=""
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
# no failure, #377) the breaker pauses serve for min(serve.breakerMax, serve.breakerCooldown * 2^(trips-1)) seconds: 15,
# 30, 60, 120, then 240 minutes. `trips` is the first field of <serve dir>/breaker, the time of the last trip the
# second; a merged ticket (serve_done), 24 hours without a trip or `serve --resume` set it back to 0. It never exits. The
# count of failures starts again, so a resume gets a fresh chance. The pause is alerted once (no ticket to mention: the
# webhook and the line on stderr).
serve_breaker() {
  local now trips cooldown out
  [ "$RUN_FAILS" -ge "$RUN_MAXFAIL" ] || return 0
  RUN_FAILS=0
  RUN_STOP=""
  if [ ! -f "$SERVE_DIR/paused" ]; then
    now=$(serve_now)
    out=$(state_update serve_breaker_trip "$now") || return 0
    read -r trips cooldown <<<"$out"
    echo "serve: paused, $RUN_MAXFAIL failed tickets in a row; it resumes in $cooldown seconds (pause $trips since the last merge) or with: senior-mode serve --resume" >&2
    notify breaker "" "$RUN_MAXFAIL failed tickets in a row (autonomy.maxConsecutiveFailures)"
  fi
}

# Run by state_update: counts a trip of the breaker (`breaker`: trips, time of the last), writes the pause (`paused`: the
# time it ends, the reason) and prints `trips cooldown`.
serve_breaker_trip() {
  local now=$1 trips last cooldown i
  read -r trips last < <(state_get "$SERVE_DIR/breaker" '[0-9]+ [0-9]+') || true
  [[ ${trips:-} =~ ^[0-9]+$ ]] || trips=0
  [[ ${last:-} =~ ^[0-9]+$ ]] || last=0
  [ $((now - last)) -lt 86400 ] || trips=0
  trips=$((trips + 1))
  state_put "$SERVE_DIR/breaker" "$trips $now" || return 1
  cooldown=$SERVE_COOLDOWN
  for ((i = 1; i < trips && cooldown < SERVE_BREAKER_MAX; i++)); do cooldown=$((cooldown * 2)); done
  [ "$cooldown" -le "$SERVE_BREAKER_MAX" ] || cooldown=$SERVE_BREAKER_MAX
  printf '%s\n%s\n' "$((now + cooldown))" "$RUN_MAXFAIL failed tickets in a row (autonomy.maxConsecutiveFailures)" | state_write "$SERVE_DIR/paused" || return 1
  echo "$trips $cooldown"
}

# Run by state_update. `launches` holds one line `<epoch> <kind>` per session started (run_launch, kind `ticket` or the
# role). The lines of the last hour stay; a session that died at once takes back its own line (<n>.launched).
serve_launch_trim() {
  awk -v c="$1" '$1 > c' "$RUN_LAUNCH_LOG" | state_write "$RUN_LAUNCH_LOG"
}
serve_launch_drop() {
  local line
  line=$(state_get "$RUN_DIR/$1.launched" '[0-9]+ [a-z-]+') || return 0
  rm -f "$RUN_DIR/$1.launched"
  [ -f "$RUN_LAUNCH_LOG" ] || return 0
  awk -v l="$line" '$0 == l && !d { d = 1; next } { print }' "$RUN_LAUNCH_LOG" | state_write "$RUN_LAUNCH_LOG"
}

# Is a ceiling reached? Prints which and returns 0 when it is: launches in the last hour, the load average over
# the CPU count, available memory under autonomy.minMemoryMB. The launch waits for the next poll.
serve_ceiling() {
  local now count load cpus mem
  now=$(serve_now)
  if [ -f "$RUN_LAUNCH_LOG" ]; then
    state_update serve_launch_trim "$((now - 3600))" || true
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
  last=$(state_num "$SERVE_DIR/ready-last" "$now")
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
  [ "$ok" = false ] || state_put "$SERVE_DIR/ready-last" "$now"
}

# The tickets of the batch of the lead $1 (<n>.batch), the ticket alone when it has none.
serve_batch() {
  state_get "$SERVE_DIR/$1.batch" '[0-9]+( [0-9]+)*' || echo "$1"
}

# What became of the session of ticket $1 (its <n>.sh is in the serve dir), for serve_recover: `live` (its process group
# is alive and left no exit file), `ended` (it left an exit file and a verdict, or its group is gone with a verdict: the
# end can be read), `lost` (no verdict, nothing alive: its ticket is put back).
serve_orphan() {
  local n=$1 verdict=false
  [ -z "$(head -n 1 "$SERVE_DIR/$n.outcome" 2>/dev/null)" ] || verdict=true
  if [ -f "$SERVE_DIR/$n.exit" ]; then
    [ "$verdict" = true ] && echo ended || echo lost
  elif [ ! -f "$SERVE_DIR/$n.pgid" ]; then
    echo lost
  elif run_dead "$n"; then
    [ "$verdict" = true ] && echo ended || echo lost
  else
    echo live
  fi
}

# Whether a process runs inside the directory $1.
serve_wt_busy() {
  # One find and one awk, not a readlink per process: a busy host runs thousands of them. find may fail on a process
  # that ends meanwhile, and awk reads to the end, so that pipefail sees neither.
  # shellcheck disable=SC2016 # an awk program, not expanded here
  { find /proc -maxdepth 2 -path '/proc/[0-9]*/cwd' -printf '%l\n' 2>/dev/null || true; } |
    awk -v d="$1" '$0 == d || index($0, d "/") == 1 { found = 1 } END { exit !found }'
}

# The tickets of serve's sessions that the serve dir no longer knows (it was deleted): the worktrees of a ticket's branch
# that hold serve's marker (run_mark) and where no process runs, as `<lead> <ticket>...` lines.
serve_marked() {
  local path branch gd
  while IFS=$'\t' read -r path branch; do
    [[ $branch =~ ^refs/heads/[a-z]+/([0-9]+)(-|$) ]] || continue
    [ ! -e "$SERVE_DIR/${BASH_REMATCH[1]}.sh" ] || continue
    gd=$(git -C "$path" rev-parse --absolute-git-dir 2>/dev/null) || continue
    [ -f "$gd/senior-mode-session" ] || continue
    ! serve_wt_busy "$path" || continue
    printf '%s %s\n' "${BASH_REMATCH[1]}" "$(sed -n 1p "$gd/senior-mode-session")"
  done < <(git worktree list --porcelain | awk '$1 == "worktree" {p = substr($0, 10)} $1 == "branch" {print p "\t" $2}')
}

# Takes over the session of ticket $1 from a serve that died, from its <n>.meta: the arrays run keeps for a session are
# restored and the session is tracked like one this serve started. A session that ended is read like any end (run_reap).
serve_adopt() {
  local n=$1 meta m now
  local -a f
  meta=$(state_json "$SERVE_DIR/$n.meta") || return 1
  mapfile -t f < <(jq -r '(.role // "ticket"), (.model // "sonnet"), (.branch // ""), (.worktree // ""), (.cwd // ""), (.batch // ""),
    (.pr // ""), (.sha // ""), (.started // 0)' <<<"$meta")
  RUN_ROLE[$n]=${f[0]}
  RUN_MODEL[$n]=${f[1]}
  RUN_BRANCH[$n]=${f[2]}
  RUN_WT[$n]=${f[3]}
  if [ -n "${f[4]}" ]; then RUN_CWD[$n]=${f[4]}; else unset 'RUN_CWD[$n]'; fi
  if [ -n "${f[5]}" ]; then RUN_BATCH[$n]=${f[5]}; else unset 'RUN_BATCH[$n]'; fi
  if [ "${f[0]}" = reviewer ]; then
    SERVE_PR[$n]=${f[6]}
    SERVE_SHA[$n]=${f[7]}
  fi
  [ "${f[0]}" != ticket ] || [ "${f[1]}" != opus ] || RUN_ESCALATED[$n]=true
  now=$(serve_now)
  if [[ ! ${f[8]} =~ ^[0-9]+$ ]] || [ "${f[8]}" -gt "$now" ]; then f[8]=$now; fi
  RUN_STARTED[$n]=$((SECONDS - (now - f[8])))
  for m in $(run_members "$n"); do
    RUN_BRANCH[$m]=${f[2]}
    RUN_WT[$m]=${f[3]}
  done
  # The session ended with a verdict but its script died before the exit file: the exit code is not known.
  if [ ! -f "$SERVE_DIR/$n.exit" ] && run_dead "$n"; then state_put "$SERVE_DIR/$n.exit" 0; fi
  running+=("$n")
}

# After a crash or a restart (#272, spec 373 section 2): a ticket serve launched (its <n>.sh is in the serve dir) whose
# session is not one of this serve's. A session still alive, or ended with a verdict that nobody read (the end of a dead
# serve), is adopted (serve_adopt) and read at once like any other. One with no verdict and nothing alive, whose ticket
# is In progress, goes back to Ready, to be picked again (its worktree and branch are kept); once
# autonomy.maxConsecutiveFailures recoveries are used up it gets needs-human instead. The recoveries are counted in
# <n>.recovered. Left alone: a ticket whose end serve already read (its <n>.json is newer than its <n>.meta, else its
# <n>.sh), a ticket with needs-human. With the serve dir lost, the tickets In progress whose worktree holds serve's marker
# (serve_marked) and where nothing runs are put back the same way.
serve_recover() {
  local f n data count m base role want adopted=false
  local -a cand=() adopt=()
  local -A marked=()
  for f in "$SERVE_DIR"/*.sh; do
    [ -e "$f" ] || continue
    n=$(basename "$f" .sh)
    [[ $n =~ ^[0-9]+$ ]] || continue
    [[ " ${running[*]-} " != *" $n "* ]] || continue
    base=$f
    [ ! -f "$SERVE_DIR/$n.meta" ] || base=$SERVE_DIR/$n.meta
    if [ -f "$SERVE_DIR/$n.json" ] && [ "$SERVE_DIR/$n.json" -nt "$base" ]; then continue; fi
    role=$(jq -r '.role // "ticket"' "$SERVE_DIR/$n.meta" 2>/dev/null) || role=ticket
    case $(serve_orphan "$n") in
      live) [ ! -f "$SERVE_DIR/$n.meta" ] || adopt+=("$n") ;;
      ended)
        # A reviewer or an integrator ended: the pull request is looked at again, as it always was.
        if [ -f "$SERVE_DIR/$n.meta" ] && { [ "$role" = ticket ] || [ "$role" = test-author ]; }; then adopt+=("$n"); else cand+=("$n"); fi
        ;;
      lost) cand+=("$n") ;;
    esac
  done
  while read -r n m; do
    [ -n "$n" ] || continue
    marked[$n]=${m:-$n}
    cand+=("$n")
  done < <(serve_marked)
  [ $((${#cand[@]} + ${#adopt[@]})) -gt 0 ] || return 0
  if ! data=$(board_data false); then
    echo "serve: cannot read the board to recover tickets; trying again at the next poll" >&2
    return 0
  fi
  for n in "${adopt[@]}"; do
    role=$(jq -r '.role // "ticket"' "$SERVE_DIR/$n.meta" 2>/dev/null) || role=ticket
    want="In progress"
    case $role in reviewer | integrator) want="In review" ;; esac
    jq -e --argjson n "$n" --arg s "$want" '.items[] | select(.number == $n and .open and .status == $s and (.labels | index("needs-human") | not))' \
      <<<"$data" >/dev/null || continue
    serve_adopt "$n" || continue
    RUN_TITLE[$n]=$(jq -r --argjson n "$n" '.items[] | select(.number == $n) | .title' <<<"$data")
    echo "serve: #$n: taking over the $role session of a serve that stopped"
    adopted=true
  done
  for n in "${cand[@]}"; do
    jq -e --argjson n "$n" '.items[] | select(.number == $n and .open and .status == "In progress" and (.labels | index("needs-human") | not))' \
      <<<"$data" >/dev/null || continue
    count=$(state_update state_counter_add "$SERVE_DIR/$n.recovered") || continue
    if [ "$count" -ge "$RUN_MAXFAIL" ]; then
      echo "serve: #$n has lost its session $count times; needs-human"
      notify needs-human "$n" "serve found the ticket In progress with no live session $count times (autonomy.maxConsecutiveFailures); the session files are in $SERVE_DIR"
    else
      # A lost batch session puts every ticket of the batch back.
      for m in ${marked[$n]:-$(serve_batch "$n")}; do
        if (item_set "$m" Status Ready) >/dev/null; then
          echo "serve: #$m was In progress with no live session; back to Ready (recovery $count of $((RUN_MAXFAIL - 1)))"
        else
          echo "#$m: could not set the Status back to Ready" >&2
        fi
      done
    fi
  done
  [ "$adopted" = false ] || run_reap
}

# Says why a pull request waits, once: the line is repeated only when the reason changes. $1 names the pull
# request, $2 is the line.
serve_note() {
  [ "${SERVE_NOTED[$1]:-}" != "$2" ] || return 0
  SERVE_NOTED[$1]=$2
  RUN_WAITING+=("$2")
}

# Run by state_update: the starts older than the cutoff $1 go; the last start of the ticket $1 is taken back.
serve_starts_trim() {
  awk -v c="$1" '$1 > c' "$SERVE_DIR/ticket-starts" | state_write "$SERVE_DIR/ticket-starts"
}
serve_starts_drop() {
  awk -v n="$1" '{ l[NR] = $0; if ($2 == n) last = NR } END { for (i = 1; i <= NR; i++) if (i != last) print l[i] }' \
    "$SERVE_DIR/ticket-starts" | state_write "$SERVE_DIR/ticket-starts"
}

# Is autonomy.ticketsPerHour reached? Prints the reason and returns 0 when it is. It counts ticket starts, not the
# role sessions a ticket costs (#355): one line "<time> <ticket>" in ticket-starts per ticket begun.
serve_ticket_cap() {
  local now count f=$SERVE_DIR/ticket-starts
  [ -f "$f" ] || return 1
  now=$(serve_now)
  state_update serve_starts_trim "$((now - 3600))" || true
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
  jq -r --slurpfile d <(printf '%s' "$1") --argjson map "$(workflow_branch_map_json)" --arg re "${re:-^[a-z]+/(?<n>[0-9]+)(-|\$)}" '$d[0] as $d | [.[] | . as $p
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

# A merged pull request: counted, its ticket Done, and the breaker's trips start again at 0.
serve_done() {
  local t=$1 pr=$2 m
  rm -f "$SERVE_DIR/queued-$pr" "$SERVE_DIR/rounds-$t" "$SERVE_DIR/breaker"
  serve_backmerge "$t" "$pr"
  hotfix_release "$t" "$pr"
  # Every ticket of a batch is done with its one pull request (the lead's <n>.batch).
  for m in $(serve_batch "$t"); do
    RUN_MERGED+=("#$m ${RUN_TITLE[$m]:-} (pull request #$pr)")
    if (item_set "$m" Status Done) >/dev/null; then
      cycle_end "$m"
    else
      echo "#$m: merged, but could not set the Status Done" >&2
      RUN_NOT_DONE+=("#$m ${RUN_TITLE[$m]:-} (pull request #$pr)")
    fi
  done
  fault_point after-done
}

# A pull request that merged while serve was down, or died before it set the Status (spec 373, section 2): a ticket In
# review whose branch (or `Closes #<n>`) has a merged pull request and no open one is Done now, whether or not a queued-<pr>
# file remembers it, and its worktree is cleaned. $1 is the board, $2 the open pull requests. Read from GitHub at every poll.
# shellcheck disable=SC2016 # a jq program, not shell
serve_merged_done() {
  local data=$1 prs=$2 merged t pr moved=false d
  merged=$(gh_retry pr list --repo "$RUN_SLUG" --state merged --limit 50 --json number,headRefName,body) || return 0
  while IFS=$'\t' read -r t pr; do
    [ -n "$t" ] || continue
    # Done in this very poll (serve_queued): the board read above is older.
    for d in "${RUN_MERGED[@]}"; do [[ $d == "#$t "* ]] && continue 2; done
    serve_busy "$t" && continue
    serve_done "$t" "$pr"
    moved=true
  done < <(jq -r --slurpfile d <(printf '%s' "$data") --slurpfile o <(printf '%s' "$prs") '
      def ticket: try (capture("^[a-z]+/(?<n>[0-9]+)(-|$)") | .n | tonumber) catch null;
      $d[0] as $d | $o[0] as $o
      | ([$o[] | .head.ref | ticket] | map(select(. != null))) as $open
      | [.[] | . as $p
          | ([($p.headRefName | ticket)] + [($p.body // "" | scan("(?i)(?:closes|fixes|resolves) #([0-9]+)") | .[0] | tonumber)])
          | map(select(. != null))[] | {t: ., pr: $p.number}]
      | map(select(. as $x | ($open | index($x.t) | not)
          and any($d.items[]; .number == $x.t and .open and .status == "In review")))
      | unique_by(.t)[] | [.t, .pr] | @tsv' <<<"$merged")
  [ "$moved" = false ] || "$SELF" clean || echo "serve: clean failed; trying again later" >&2
}

# The pull requests queued for auto-merge (queued-<pr>: the head and the ticket): merged is read back, then
# Done; a closed one is forgotten. One whose head is no longer the queued one is a candidate again.
serve_queued() {
  local f pr sha t state
  for f in "$SERVE_DIR"/queued-*; do
    [ -e "$f" ] || continue
    case $f in *.corrupt-* | *.tmp.*) continue ;; esac
    pr=${f##*queued-}
    read -r sha t < <(state_get "$f" '[0-9a-f]+ [0-9]+') || continue
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
  fault_point before-merge
  if [ "$(serve_auto)" = true ] &&
    gh_bound pr merge "$pr" --auto "$method" --match-head-commit "$sha" -R "$RUN_SLUG" >/dev/null 2>"$err"; then
    queued=true
  elif ! gh_bound pr merge "$pr" "$method" --match-head-commit "$sha" -R "$RUN_SLUG" >/dev/null 2>"$err"; then
    serve_note "w$pr" "#$t ${RUN_TITLE[$t]:-}: pull request #$pr, the merge failed: $(head -n 1 "$err")"
    return 0
  fi
  fault_point after-merge
  state=$(gh_retry pr view "$pr" -R "$RUN_SLUG" --json state --jq .state) || state=""
  if [ "$state" = MERGED ]; then
    serve_done "$t" "$pr"
  elif [ "$queued" = true ]; then
    state_put "$SERVE_DIR/queued-$pr" "$sha $t"
    echo "#$t: pull request #$pr queued for auto-merge"
  else
    serve_note "w$pr" "#$t ${RUN_TITLE[$t]:-}: pull request #$pr, merged but GitHub says it is ${state:-unknown}"
  fi
}

# After a rebase of the pull request $2 (ticket $1) from head $3 to head $4 (branch $5): check and publish on
# the new head, then the review is carried over when `git range-diff` finds the same patches, or asked again
# when it finds any change (the head has no review status, so the next poll starts a reviewer).
serve_requalify() {
  local t=$1 pr=$2 old=$3 new=$4 ref=$5 wt log="$SERVE_DIR/$1.check.log" same=false cmd ob nb ci review rd
  git_bound fetch -q origin 2>/dev/null || true
  if git cat-file -e "$old^{commit}" 2>/dev/null && git cat-file -e "$new^{commit}" 2>/dev/null &&
    ob=$(git merge-base "$old" "$new") && nb=$(git merge-base "$RUN_BASE" "$new") &&
    rd=$(git range-diff --no-color "$ob..$old" "$nb..$new" 2>/dev/null) && [ -n "$rd" ] &&
    printf '%s\n' "$rd" | state_write "$SERVE_DIR/$t.range-diff" &&
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
  state_put "$SERVE_DIR/rebased-$pr" "$old"
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
  state_put "$RUN_DIR/$t.oldpr" "$pr"
  serve_integrator_prompt "$t" "${RUN_TITLE[$t]:-}" "$ref" "$pr" "$new" | state_write "$RUN_DIR/$t.prompt"
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
  if [[ $reason == "it is behind "* ]]; then
    # github.protection local (ADR 0032): GitHub has no up-to-date rule to report it, run_blocker does.
    state=behind
  elif [ -n "$reason" ]; then
    # Red tests missing (#306): the ticket session is resumed once to prove them; a second time is a person's.
    case $reason in "not ready: no red-tests record"*) serve_red_retry "$t" "$pr" "$ref" "$reason" && return 0 ;; esac
    serve_note "w$pr" "#$t ${RUN_TITLE[$t]:-}: pull request #$pr, $reason"
    serve_permanent "$reason" && serve_stuck "$t" "$pr" "$reason"
    return 1
  else
    state=$(jq -r '.mergeable_state // "unknown"' <<<"$pull")
  fi
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

# A pull request with no red-tests record for a feature or bug ticket $1 (#306, $4 says which): the ticket session
# resumes once on its branch to prove its tests (senior-mode red-tests verify). Returns 0 when it did, 1 when it
# already had its retry (or none can start): the caller then leaves the pull request to a person.
serve_red_retry() {
  local t=$1 pr=$2 reason=$4
  [ ! -f "$SERVE_DIR/red-retry-$t" ] || return 1
  serve_can_launch || return 1
  RUN_ROLE[$t]=ticket
  unset 'RUN_CWD[$t]'
  run_open "$t" || return 1
  : | state_write "$SERVE_DIR/red-retry-$t"
  serve_red_prompt "$t" "${RUN_TITLE[$t]:-}" "${RUN_BRANCH[$t]}" "$pr" "$reason" | state_write "$RUN_DIR/$t.prompt"
  echo "#$t: pull request #$pr has no red-tests record; the ticket session resumes once to prove its tests"
  if run_launch "$t" sonnet; then running+=("$t"); else return 1; fi
}

# Changes requested on the pull request $2 (branch $3) of ticket $1: the ticket session resumes on the same
# branch with the findings, twice at most; then a person.
serve_changes() {
  local t=$1 pr=$2 ref=$3 rounds
  rounds=$(state_num "$SERVE_DIR/rounds-$t")
  if [ "$rounds" -ge 2 ]; then
    serve_needs_human "$t" "$pr" "the reviewer still requests changes after $rounds fix rounds"
    return 0
  fi
  serve_can_launch || return 0
  RUN_ROLE[$t]=ticket
  unset 'RUN_CWD[$t]'
  run_open "$t" || return 0
  state_put "$SERVE_DIR/rounds-$t" "$((rounds + 1))"
  serve_fix_prompt "$t" "${RUN_TITLE[$t]:-}" "${RUN_BRANCH[$t]}" "$pr" $((rounds + 1)) | state_write "$RUN_DIR/$t.prompt"
  echo "#$t: the reviewer requested changes on pull request #$pr; the ticket session resumes (round $((rounds + 1)) of 2)"
  if run_launch "$t" sonnet; then running+=("$t"); fi
}

# The model of the reviewer session of ticket $1 (#304): Opus, unless review.crossModel is on and the ticket's last
# implementer session ran on Opus (escalated): then review.otherModel, so that the reviewer is never the model that
# wrote the code. The implementer is read from the ticket's outcome file; a ticket with none was not Opus's.
serve_review_model() {
  local impl
  [ "$(config_get review.crossModel)" = false ] && {
    echo opus
    return 0
  }
  impl=$(jq -r '.model // empty' "$RUN_DIR/$1.json" 2>/dev/null) || impl=""
  if [ "$impl" = opus ]; then config_get review.otherModel; else echo opus; fi
}

# A pull request In review whose head has senior-mode/ci and no review status: a reviewer session on another model
# than the implementer's (serve_review_model), in a detached worktree of that head (ADR 0017, 0019: no reviewer, no
# review; the status stays unset and the next poll after a usage limit's reset tries again).
serve_review() {
  local t=$1 pr=$2 sha=$3 ref=$4 wt model
  model=$(serve_review_model "$t")
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
  serve_review_prompt "$t" "${RUN_TITLE[$t]:-}" "$pr" "$sha" "$model" | state_write "$RUN_DIR/$t.prompt"
  echo "#$t: reviewing pull request #$pr on $model"
  if run_launch "$t" "$model"; then running+=("$t"); else git worktree remove --force "$wt" 2>/dev/null || true; fi
}

# Every pull request of a ticket In review, in `pick` order: its head decides. CI success and no review
# status: a reviewer session. Review failure: the ticket session resumes. Review success: merged (the integrator
# pass), at most one per poll.
serve_prs() {
  local data=$1 prs=$2 acted=false t pr sha ref title states review ci old gate
  # The independent review is a locked gate; a profile lifts it only with an accepted ADR (process.gates.review).
  gate=$(config_get process.gates.review) || gate=true
  while IFS=$'\t' read -r t pr sha ref title; do
    [ -n "$t" ] || continue
    [ "$SERVE_TERM" = false ] || break
    RUN_TITLE[$t]=$title
    serve_busy "$t" && continue
    if [ -f "$SERVE_DIR/queued-$pr" ] && [ "$(state_get "$SERVE_DIR/queued-$pr" '[0-9a-f]+ [0-9]+' | cut -d' ' -f1)" = "$sha" ]; then continue; fi
    # A rebase whose requalification was cut short (serve stopped, the new head came late): carry on.
    if [ -f "$SERVE_DIR/rebased-$pr" ] && old=$(state_get "$SERVE_DIR/rebased-$pr" '[0-9a-f]+') && [ "$old" != "$sha" ]; then
      if [ "$acted" = false ]; then
        serve_requalify "$t" "$pr" "$old" "$sha" "$ref"
        acted=true
      fi
      continue
    fi
    states=$(serve_states "$sha") || continue
    review=$(jq -r '.["senior-mode/review"] // empty' <<<"$states")
    ci=$(jq -r '.["senior-mode/ci"] // empty' <<<"$states")
    # The review of a hotfix (#322) is mandatory whatever the profile says.
    [ -n "$review" ] || [ "$gate" != false ] || [ "$ci" != success ] || hotfix_item "$data" "$t" || review=success
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
  local now reason data prs n size title batch begins capped ticket_wait="" started_before diag cause why
  local -a queue=()
  now=$(serve_now)
  RUN_STOP=""
  SERVE_HELD="" SERVE_GUARDS="" SERVE_WAIT=""
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
  if ! data=$(board_data false); then
    echo "serve: cannot read the board; trying again at the next poll" >&2
    return 0
  fi
  serve_queued
  if prs=$(gh_retry api "repos/$RUN_SLUG/pulls?state=open&per_page=100"); then
    serve_merged_done "$data" "$prs"
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
        serve_tests_prompt "$n" "${RUN_TITLE[$n]}" "${RUN_BRANCH[$n]}" | state_write "$RUN_DIR/$n.prompt"
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
  last=$(state_num "$SERVE_DIR/digest")
  [ $((now - last)) -ge 86400 ] || return 0
  state_put "$SERVE_DIR/digest" "$now"
  if body=$("$SELF" status --since 24h 2>/dev/null) && [ -n "$body" ] && project_post_update "$body"; then
    echo "serve: daily digest posted as a Project status update"
  else
    echo "serve: could not post the daily digest; trying again tomorrow" >&2
  fi
}

# Dependency freshness (#497, spec 471 section 8). Once a week, `npm outdated --json` of a project with a package.json
# gives the majors available; each becomes one `chore(deps): <package> <from> to <to>` ticket, unless an open issue
# has that title. The time of the pass is kept in <serve dir>/deps-at.
serve_deps() {
  local now last root out slug open line title body
  now=$(serve_now)
  last=$(cat "$SERVE_DIR/deps-at" 2>/dev/null || true)
  [[ $last =~ ^[0-9]+$ ]] && [ $((now - last)) -lt 604800 ] && return 0
  root=$(git rev-parse --show-toplevel 2>/dev/null) && [ -f "$root/package.json" ] || return 0
  state_put "$SERVE_DIR/deps-at" "$now"
  out=$(cd "$root" && npm outdated --json 2>/dev/null) || true
  slug=$(repo_slug)
  open=$(gh_retry issue list --repo "$slug" --state open --limit 500 --json title 2>/dev/null) || open='[]'
  while IFS= read -r title; do
    [ -n "$title" ] || continue
    jq -e --arg t "$title" 'any(.[]; .title == $t)' <<<"$open" >/dev/null && continue
    body=$(mktemp)
    printf '## Context\n\nA new major is available.\n\n## Acceptance criteria\n\n- Given the major is available, when the project is moved to it, then check passes.\n' >"$body"
    "$SELF" issue create --title "$title" --body-file "$body" --size S --priority "P2 later" --type chore </dev/null >/dev/null ||
      echo "serve: dependency ticket not filed: $title" >&2
    rm -f "$body"
  done < <(jq -r 'to_entries[] | select((.value.current // "") != "" and (.value.latest // "") != "" and
    ((.value.latest | split(".")[0]) != (.value.current | split(".")[0])))
    | "chore(deps): \(.key) \(.value.current) to \(.value.latest)"' <<<"${out:-{\}}" 2>/dev/null)
}

# The digest of the day through the webhook (#309). Once notify.digestAt (HH:MM, the local time of the daemon) has
# passed and none was sent today, one JSON POST {event: "digest", repo, number: null, url: null, reason: <text>,
# digest: {...}} to the notify webhook with, over the last 24 hours, the pull requests merged, the tickets that wait
# for a human, the tokens and their estimated cost (#299) and the board (work in progress, drift). Nothing is sent
# when nothing was merged or closed and no token was used, nor without a webhook. The day of the attempt is kept in
# <serve dir>/digest-at: a failure waits for tomorrow and a restart does not send twice.
# shellcheck disable=SC2016 # jq programs, not shell
serve_digest_at() {
  local at hook now day st usage digest text
  at=$(config_get notify.digestAt)
  hook=${SENIOR_MODE_NOTIFY_WEBHOOK:-$(config_get notify.webhook)}
  [ -n "$at" ] && [ -n "$hook" ] || return 0
  now=$(serve_now)
  [[ ! $(date -d "@$now" +%H:%M 2>/dev/null || date -r "$now" +%H:%M) < $at ]] || return 0
  day=$(date -d "@$now" +%F 2>/dev/null || date -r "$now" +%F)
  [ "$(cat "$SERVE_DIR/digest-at" 2>/dev/null)" != "$day" ] || return 0
  state_put "$SERVE_DIR/digest-at" "$day"
  if ! st=$("$SELF" status --json --since 24h 2>/dev/null) || ! usage=$(retro_usage "$SERVE_COMMON" "$(iso_time $((now - 86400)))" ""); then
    echo "serve: could not build the daily digest; trying again tomorrow" >&2
    return 0
  fi
  digest=$(jq -c --argjson u "$usage" '{merged: .mergedPullRequests, done: [.done[] | {number, title}],
    waiting: [.waiting[] | {kind, number, title, why}],
    tokens: ($u.total | {input, output, cacheRead, cacheWrite: (.cacheWrite5m + .cacheWrite1h), usd, unpriced}),
    board: {inProgress: (.inProgress | length), wip: .wip.limit, inReview: (.inReview | length), blocked: (.blocked | length),
      drift: [.drift[] | {number, title, why}]}}' <<<"$st") || {
    echo "serve: could not build the daily digest; trying again tomorrow" >&2
    return 0
  }
  jq -e '.merged > 0 or (.done | length) > 0 or (.tokens.input + .tokens.output + .tokens.cacheRead + .tokens.cacheWrite) > 0' <<<"$digest" >/dev/null ||
    return 0
  text=$(jq -r 'def l($a): if ($a | length) == 0 then "none" else ($a | map("#\(.number) \(.title)") | join(", ")) end;
    "Daily digest of senior-mode, last 24 hours",
    "Merged pull requests: \(.merged)" + (if (.done | length) > 0 then " · done: \(l(.done))" else "" end),
    "Needs a human: \(if (.waiting | length) == 0 then "nothing" else (.waiting | map("\(.kind) #\(.number) \(.title): \(.why)") | join("; ")) end)",
    "Token cost: \(if .tokens.usd == null then "no price" else "$\(.tokens.usd * 100 | round / 100)" end) (\(.tokens.input + .tokens.output + .tokens.cacheRead + .tokens.cacheWrite) tokens)",
    "Board: \(.board.inProgress) in progress (limit \(.board.wip)), \(.board.inReview) in review, \(.board.blocked) blocked, drift: \(l(.board.drift))"' <<<"$digest")
  curl -fsS -m 10 -X POST -H 'Content-Type: application/json' "$hook" -d "$(jq -nc --arg r "$RUN_SLUG" --arg t "$text" --argjson d "$digest" \
    '{event: "digest", repo: $r, number: null, url: null, reason: $t, digest: $d}')" >/dev/null ||
    echo "notify: the webhook did not answer (digest)" >&2
}

# Run by state_update: the questions of the file $1 as one JSON array, the file emptied (an alert added meanwhile is not lost).
serve_questions_take() {
  jq -sc 'map(.reason |= (gsub("[[:cntrl:]]"; " ") | .[:300]))' "$1" && state_write "$1" </dev/null
}

# The questions that serve queued (notify, #308) go out as one notification, once the oldest has waited
# notify.batchMinutes (default 60; 0 sends at each poll): at most one per window, whatever the number of questions. The
# text is plain, control characters stripped and 300 characters at most (a title can come from an outsider). The label and
# the comment of each question were already on GitHub; only the webhook waits. The queue is emptied even without a webhook.
serve_questions() {
  local file=$SERVE_DIR/questions now minutes first items count text
  [ -s "$file" ] || return 0
  now=$(serve_now)
  minutes=$(serve_int notify.batchMinutes 0)
  first=$(jq -rs 'map(.at) | min' "$file") || return 0
  [ $((now - first)) -ge $((minutes * 60)) ] || return 0
  items=$(state_update serve_questions_take "$file") || return 0
  count=$(jq 'length' <<<"$items")
  text=$(jq -r 'map("#\(.number) \(.reason)") | join("; ") | gsub("[[:cntrl:]]"; " ")' <<<"$items")
  text="$count decision$([ "$count" = 1 ] || echo s) wait for you: $text"
  notify_post decisions "" "" "${text:0:300}" "$(jq -nc --argjson i "$items" '{count: ($i | length), items: $i}')"
}

# The loop (ADR 0017): the shared part of `run` (run_prepare, run_start, run_reap, run_finish...) with a poll
# every serve.interval seconds instead of a batch. TERM and INT stop the launching and drain. State is under
# <git common dir>/senior-mode/serve/. SENIOR_MODE_SERVE_ONCE=1 polls once, waits for its sessions and exits.
serve_loop() {
  local interval old sleeper
  local -a running=() RUN_MERGED=() RUN_NOT_DONE=() RUN_REVIEWED=() RUN_NOT_REVIEW=() RUN_WAITING=() RUN_FAILED=() RUN_PRS=()
  local -A RUN_TITLE=() RUN_BRANCH=() RUN_WT=() RUN_MODEL=() RUN_ESCALATED=() RUN_REASON=() RUN_STARTED=() RUN_ROLE=() RUN_CWD=() RUN_BATCH=()
  local -A SERVE_PR=() SERVE_SHA=() SERVE_SIZE=() SERVE_NOTED=() WD_TICK=() WD_START=() WD_SIG=() WD_BASE=() WD_AT=()
  local RUN_WATCH=wd_watch SERVE_STALL SERVE_STARTUP_MIN
  local RUN_TOKEN RUN_SLUG RUN_BASE RUN_DIR RUN_ROOT RUN_STAMP="" RUN_CLAUDE RUN_MERGE RUN_ESCALATE RUN_MAXFAIL RUN_PROTECTION RUN_REQUIRED RUN_GLOBS RUN_ZONES_KNOWN RUN_TIMEOUT
  local RUN_FAILS=0 RUN_STOP="" RUN_ON_EXIT=serve_end RUN_FINISH=serve_finish RUN_PROMPT=serve_prompt RUN_PROMPT_BATCH=serve_prompt_batch RUN_LAUNCH_LOG RUN_RECONCILE=1
  local SERVE_DIR SERVE_COMMON SERVE_TERM=false SERVE_PARALLEL SERVE_PER_HOUR SERVE_TICKETS_PER_HOUR SERVE_MIN_MEM SERVE_COOLDOWN SERVE_GRACE
  local SERVE_BREAKER_MAX SERVE_BACKOFF_BASE SERVE_BACKOFF_MAX SERVE_MIN_DISK SERVE_STARTUP SERVE_UNKNOWN_MAX SERVE_UNKNOWN_CAP GH_CALL_TIMEOUT GH_DOWN_FILE
  local SERVE_HELD="" SERVE_GUARDS="" SERVE_WAIT=""
  run_prepare serve
  # ADR 0018: under serve everything green merges, unless the repository sets autonomy.merge itself.
  jq -e '(.autonomy // {}) | has("merge")' "$(config_file)" >/dev/null || RUN_MERGE=true
  interval=$(serve_int serve.interval 1)
  SERVE_GRACE=$(serve_int serve.grace 0)
  SERVE_COOLDOWN=$(serve_int serve.breakerCooldown 0)
  SERVE_TICKETS_PER_HOUR=$(serve_int autonomy.ticketsPerHour 1)
  SERVE_BREAKER_MAX=$(serve_int serve.breakerMax 1)
  SERVE_BACKOFF_BASE=$(serve_int serve.backoffBase 1)
  SERVE_BACKOFF_MAX=$(serve_int serve.backoffMax 1)
  SERVE_MIN_DISK=$(serve_int autonomy.minDiskMB 0)
  SERVE_STARTUP=$(serve_int autonomy.startupSeconds 0)
  SERVE_UNKNOWN_MAX=$(serve_int serve.unknownMaxAttempts 1)
  SERVE_UNKNOWN_CAP=$(serve_int serve.unknownBackoffMax 1)
  SERVE_STALL=$(serve_int autonomy.stallMinutes 1)
  SERVE_STARTUP_MIN=$(serve_int autonomy.startupMinutes 1)
  GH_CALL_TIMEOUT=$(serve_int serve.callTimeout 1)
  SERVE_PER_HOUR=$(serve_int autonomy.sessionsPerHour 0)
  SERVE_MIN_MEM=$(serve_int autonomy.minMemoryMB 0)
  SERVE_PARALLEL=$(serve_int autonomy.parallel 1)
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
  while [ "$SERVE_TERM" = false ]; do
    serve_poll
    serve_questions
    serve_digest
    serve_digest_at
    serve_deps
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
      if [ -f "$common/senior-mode/serve/paused" ] || [ -f "$common/senior-mode/serve/held" ]; then
        rm -f "$common/senior-mode/serve/paused" "$common/senior-mode/serve/held" "$common/senior-mode/serve/breaker" \
          "$common/senior-mode/serve/transient-until" "$common/senior-mode/serve/launch-backoff-until" \
          "$common/senior-mode/serve/startup-streak" "$common/senior-mode/serve/"*.envfail
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
