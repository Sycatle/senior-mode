# shellcheck shell=bash
# The last start of the ticket $1 is taken back from ticket-starts.
serve_start_back() {
  [ -s "$SERVE_DIR/ticket-starts" ] || return 0
  state_update serve_starts_drop "$1" || true
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
# failures the breaker counts, nor a ticket $1 that waits on an environment problem of its own; then the guards (#117) are in place and no ceiling is reached. What it says, it
# says once per poll.
serve_can_launch() {
  [ -z "${1:-}" ] || ! serve_env_held "$1" || return 1
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

# Is the free slot kept for gardening (#351)? Of the slots of `maintenance.share`, those not taken by a session of a
# gardening ticket (`$garden`, the numbers of the open gardening tickets, space-padded) are held back while a Ready gardening
# ticket could start: the feature ticket $4 cannot take the last of them. Without such a ticket the slot goes to features.
serve_gardening_holds() {
  local data=$1 reserved=$2 garden=$3 n=$4 g=0 r q keep
  [[ $garden != *" $n "* ]] || return 1
  for r in "${running[@]}"; do
    [[ $garden != *" $r "* ]] || g=$((g + 1))
  done
  keep=$((reserved - g))
  [ "$keep" -gt 0 ] && [ $((SERVE_PARALLEL - ${#running[@]} - 1)) -lt "$keep" ] || return 1
  for q in "${queue[@]}"; do
    [[ $garden == *" $q "* && " ${running[*]} " != *" $q "* ]] && [ -n "$(pick_free "$data" "$(run_busy)" "$(run_entry "$q")")" ] && return 0
  done
  return 1
}
