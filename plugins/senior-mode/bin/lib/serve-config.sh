# shellcheck shell=bash
# serve reads its config of the base branch again at every poll (#681), without a restart: the step serve_step_05_config_reload
# (the loop runs it before the poll) sets the variables serve_loop read at its start, so a merged change of
# autonomy.parallel, the hourly limits, the breaker or the protected list is in force at the next poll. The sessions that run are
# not touched: a lower autonomy.parallel only holds back the launches until fewer sessions run (serve_can_launch). SIGHUP wakes the
# loop at once. Only a config that validates is applied: an invalid one is #444's (config_effective keeps the last valid snapshot
# and alerts once), so the settings stand. What serve runs with is kept in <serve dir>/config.running, for `status`.

# The keys read at every poll: <key>:<variable>:<minimum whole number>. The variables are serve_loop's own (dynamic scope).
SERVE_CONFIG_INTS=(
  serve.interval:interval:1
  serve.grace:SERVE_GRACE:0
  serve.breakerCooldown:SERVE_COOLDOWN:0
  autonomy.ticketsPerHour:SERVE_TICKETS_PER_HOUR:1
  serve.breakerMax:SERVE_BREAKER_MAX:1
  serve.backoffBase:SERVE_BACKOFF_BASE:1
  serve.backoffMax:SERVE_BACKOFF_MAX:1
  autonomy.minDiskMB:SERVE_MIN_DISK:0
  autonomy.startupSeconds:SERVE_STARTUP:0
  serve.unknownMaxAttempts:SERVE_UNKNOWN_MAX:1
  serve.unknownBackoffMax:SERVE_UNKNOWN_CAP:1
  serve.pendingReviewHours:SERVE_PENDING_HOURS:1
  autonomy.stallMinutes:SERVE_STALL:1
  autonomy.startupMinutes:SERVE_STARTUP_MIN:1
  serve.callTimeout:GH_CALL_TIMEOUT:1
  autonomy.sessionsPerHour:SERVE_PER_HOUR:0
  autonomy.minMemoryMB:SERVE_MIN_MEM:0
  autonomy.parallel:SERVE_PARALLEL:1
  autonomy.maxConsecutiveFailures:RUN_MAXFAIL:1
  autonomy.sessionTimeout:RUN_TIMEOUT:1
)

# The settings of the base branch's config as one JSON object {key: string}: the keys above, autonomy.escalate, autonomy.merge
# (true under serve unless the repository sets it itself, ADR 0018) and protected (the globs of the base branch, as the zones of
# run_prepare). Fails, with nothing printed, when the config is invalid (#444: the settings stand). Read from the base branch
# whatever the caller's SENIOR_MODE_CONFIG_SOURCE.
# shellcheck disable=SC2016 # a jq program, not shell
serve_config_values() {
  local merged common raw="" keys="" e
  export SENIOR_MODE_CONFIG_SOURCE=base
  common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  merged=$(config_effective) || return 1
  [ ! -f "$common/senior-mode/config.invalid" ] || return 1
  raw=$(repo_read .claude/senior-mode.json 2>/dev/null) || raw='{}'
  for e in "${SERVE_CONFIG_INTS[@]}"; do keys+="${keys:+,}\"${e%%:*}\""; done
  jq -nc --argjson m "$merged" --argjson keys "[$keys,\"autonomy.escalate\"]" --argjson raw "$(jq -c . <<<"$raw" 2>/dev/null || echo '{}')" '
    ($keys | map(. as $k | {key: $k, value: ($m | getpath($k | split(".")) | if . == null then "" else tostring end)}) | from_entries) as $v
    | $v + {"autonomy.merge": (if (($raw.autonomy // {}) | has("merge")) then ($m.autonomy.merge | tostring) else "true" end),
            protected: (($raw.protected // []) | tojson)}' 2>/dev/null
}

# serve_config_apply <key> <value>: the variable of serve_loop that holds the key.
serve_config_apply() {
  local e k var
  case $1 in
    autonomy.escalate) RUN_ESCALATE=$2 ;;
    autonomy.merge) RUN_MERGE=$2 ;;
    protected) RUN_GLOBS=$2 ;;
    *)
      for e in "${SERVE_CONFIG_INTS[@]}"; do
        k=${e%%:*}
        var=${e#*:}
        [ "$k" = "$1" ] || continue
        printf -v "${var%%:*}" '%s' "$2"
      done
      ;;
  esac
}

# Whether the value $2 of key $1 can be applied: a whole number of at least the minimum, a sessionTimeout of at most 1440, an
# array of strings for protected.
serve_config_ok() {
  local e min
  case $1 in
    autonomy.escalate | autonomy.merge) [[ $2 == true || $2 == false ]] ;;
    protected) jq -e 'type == "array" and all(type == "string")' <<<"$2" >/dev/null 2>&1 ;;
    *)
      for e in "${SERVE_CONFIG_INTS[@]}"; do
        [ "${e%%:*}" = "$1" ] || continue
        min=${e##*:}
        [[ $2 =~ ^[0-9]+$ ]] && [ "$2" -ge "$min" ] && { [ "$1" != autonomy.sessionTimeout ] || [ "$2" -le 1440 ]; }
        return
      done
      return 1
      ;;
  esac
}

# SIGHUP: the loop's sleep ends and the next turn reloads at once.
serve_config_hup() {
  SERVE_HUP=true
}

# The step: reads the base branch's settings, applies each one that changed and says so (the key, the old and the new value), and
# records what serve now runs with. The first turn only records: serve_loop has just read the same config. It also takes SIGHUP.
serve_step_05_config_reload() {
  local values k v why="" first=false lines=""
  [ "$SERVE_TERM" = false ] || return 0
  if [ -z "${SERVE_CONFIG_TRAP:-}" ]; then
    SERVE_CONFIG_TRAP=1
    first=true
    declare -gA SERVE_CFG=() SERVE_CFG_BAD=()
    trap 'serve_config_hup' HUP
  fi
  if [ "${SERVE_HUP:-}" = true ]; then
    why=" (SIGHUP)"
    SERVE_HUP=false
  fi
  # An invalid config: the settings stand, and #444 said why once. Nothing is reloaded.
  values=$(serve_config_values) || return 0
  while IFS=$'\t' read -r k v; do
    [ "${SERVE_CFG[$k]-}" != "$v" ] || continue
    if [ "$first" = true ]; then
      SERVE_CFG[$k]=$v
      continue
    fi
    if ! serve_config_ok "$k" "$v"; then
      if [ "${SERVE_CFG_BAD[$k]-}" != "$v" ]; then
        SERVE_CFG_BAD[$k]=$v
        echo "serve: config: $k is $v, which cannot be applied; keeping ${SERVE_CFG[$k]-the value it has}" >&2
      fi
      continue
    fi
    serve_config_apply "$k" "$v"
    [ -z "${SERVE_CFG[$k]+x}" ] || echo "serve: config reloaded$why: $k ${SERVE_CFG[$k]} -> $v"
    SERVE_CFG[$k]=$v
  done < <(jq -r 'to_entries[] | [.key, .value] | @tsv' <<<"$values")
  # A ticket costs several role sessions: the cap is 6 per slot unless the repository sets one.
  [ "$first" = true ] || [ "${SERVE_CFG[autonomy.sessionsPerHour]:-0}" -gt 0 ] || SERVE_PER_HOUR=$((6 * SERVE_PARALLEL))
  for k in "${!SERVE_CFG[@]}"; do lines+=$k$'\t'${SERVE_CFG[$k]}$'\n'; done
  printf '%s' "$lines" | jq -Rsc 'split("\n") | map(select(. != "") | split("\t") | {key: .[0], value: (.[1] // "")}) | from_entries' |
    state_write "$SERVE_DIR/config.running"
}
