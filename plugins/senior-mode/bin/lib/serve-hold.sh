# shellcheck shell=bash
# Every launch is held, until the environment is healthy (#377): `held` in the serve dir is one JSON object, {cause, since,
# probe (cheap or expensive), nextProbe, detail}. The diagnosis $2 of the cause $1 is on stderr, in the webhook (event
# environment) and in a Project status update, once: the first diagnosis stands while the hold lasts. serve_hold probes
# again (cheap probes at every poll, expensive ones, the Claude ping and the dependencies, every 5 minutes, then every 15
# once the hold is an hour old) and lifts the hold on its own when the probe is green; `serve --resume` lifts it by hand.
serve_hold_set() {
  local cause=$1 detail=$2 now kind=cheap next
  [ ! -s "$SERVE_DIR/held" ] || return 0
  now=$(serve_now)
  case $cause in claude-auth | deps) kind=expensive ;; esac
  next=$now
  [ "$kind" = cheap ] || next=$((now + 300))
  state_update serve_hold_write "$cause" "$detail" "$now" "$kind" "$next" || return 0
  echo "serve: holding all launches, environment problem ($cause): $detail; probing again, or senior-mode serve --resume" >&2
  notify environment "" "serve holds all launches, environment problem ($cause): $detail"
  project_post_update "senior-mode serve holds all launches: environment problem ($cause): $detail. It resumes by itself once the probe is green." AT_RISK >/dev/null 2>&1 ||
    echo "serve: could not post the hold as a Project status update" >&2
}

# Run by state_update: writes the hold, unless there is one.
serve_hold_write() {
  [ ! -s "$SERVE_DIR/held" ] || return 1
  jq -nc --arg c "$1" --arg d "$2" --argjson s "$3" --arg k "$4" --argjson x "$5" \
    '{cause: $c, since: $s, probe: $k, nextProbe: $x, detail: $d}' |
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

# The install plan of the worktree $1, as `start` runs it (#323, #554): the root's command, then one per Go module, each in
# its directory. Runs them all; returns 1 when one fails.
serve_install() {
  local dir cmd rc=0
  while IFS=$'\t' read -r dir cmd; do
    (cd "$1/$dir" && net_bound 900 bash -c "$cmd" </dev/null) || rc=1
  done < <(install_plan "$1")
  return "$rc"
}

# Probe: the install command of the base branch passes on a detached worktree of it, as its sessions would find it.
serve_probe_deps() {
  local wt rc=0
  git_bound fetch -q origin 2>/dev/null || true
  wt=$(worktree_path "$RUN_ROOT" "probe-env")
  git worktree remove --force "$wt" 2>/dev/null || true
  git worktree add -q --detach "$wt" "$RUN_BASE" 2>/dev/null || return 0
  serve_install "$wt" >/dev/null 2>&1 || rc=1
  git worktree remove --force "$wt" 2>/dev/null || true
  [ "$rc" -eq 0 ] || echo "the install command fails on $RUN_BASE"
  return "$rc"
}

# Is the environment healthy for the cause $1? Prints the diagnosis and returns 1 when it is not. disk: room again;
# gh-auth: gh answers; claude-auth: `claude auth status`, else a one-word haiku session answers; deps: the install
# command of the base branch passes; main-red: senior-mode/ci is not red on the base head.
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

# Is serve held back (not an error)? Prints why and returns 0 when it is: the circuit breaker's pause (until its
# cooldown or `serve --resume`, which removes the file), an environment pause (until a probe is green), a usage limit
# (until its reset) or a transient backoff. A hold that is over is lifted here. $1 is the time.
serve_hold() {
  local now=$1 until cause diag since next now_diag
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
        rm -f "$SERVE_DIR/held"
        echo "serve: the environment is healthy again (probe for $cause is green), launching again" >&2
        notify recovered "" "serve launches again: the probe for $cause is green"
        project_post_update "senior-mode serve resumed: the probe for $cause is green." ON_TRACK >/dev/null 2>&1 || true
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
