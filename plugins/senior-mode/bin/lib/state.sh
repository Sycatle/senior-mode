# shellcheck shell=bash
# State files of serve and run (spec 373, section 3): every state file is written whole and moved into place, a
# read-modify-write holds one lock, a reader takes what it can parse and sets aside what it cannot. Definitions only.
# The serve dir ($SERVE_DIR) holds the lock, `state.lock`; without it (run) a write is still atomic and nothing is locked.

# state_write <file>: the content is on stdin. It goes to <file>.tmp.$$ in the same directory, is synced when `sync` takes a
# file, then moved over <file>: a reader sees the old file or the new one, never half of one.
state_write() {
  local file=$1 tmp=$1.tmp.$$
  if cat >"$tmp"; then
    if command -v sync >/dev/null 2>&1; then sync "$tmp" 2>/dev/null || true; fi
    mv -f "$tmp" "$file" && return 0
  fi
  rm -f "$tmp"
  echo "senior-mode: cannot write $file" >&2
  return 1
}

# state_put <file> <text...>: one line of text.
state_put() {
  local file=$1
  shift
  printf '%s\n' "$*" | state_write "$file"
}

# state_update <command...>: runs the command (a function: it may read and write state files, and call state_write) with
# `flock -w 10` held on <serve dir>/state.lock. The kernel drops the lock with its holder, so none is ever stale. A lock
# that is not got in 10 seconds is said and the command does not run: the caller tries again at the next poll. A nested
# call runs at once. Without a serve dir or without flock the command runs unlocked.
state_update() {
  local rc=0
  if [ -n "${STATE_LOCKED:-}" ] || [ -z "${SERVE_DIR:-}" ] || ! command -v flock >/dev/null 2>&1; then
    "$@"
    return
  fi
  (
    flock -w "${SENIOR_MODE_LOCK_WAIT:-10}" 9 || {
      echo "senior-mode: the state lock is busy; trying again at the next poll" >&2
      exit 75
    }
    STATE_LOCKED=1
    "$@"
  ) 9>>"$SERVE_DIR/state.lock" || rc=$?
  return "$rc"
}

# state_append <file>: the line on stdin is added in one write (O_APPEND), under the lock so that a trim of the file does
# not take it back.
state_append() {
  state_update state_append_now "$1" "$(cat)"
}
state_append_now() {
  printf '%s\n' "$2" >>"$1"
}

# Run by state_update. state_counter_add <file>: adds 1 to the number in the file (0 when it is missing or was set aside)
# and prints the result. state_keep_later <file> <epoch>: writes the epoch unless the file holds a later one.
state_counter_add() {
  local n
  n=$(state_num "$1")
  n=$((n + 1))
  state_put "$1" "$n" && echo "$n"
}
state_keep_later() {
  [ "$(state_num "$1")" -ge "$2" ] || state_put "$1" "$2"
}

# state_quarantine <file>: sets a file that cannot be read aside as <file>.corrupt-<epoch>, said once; the default applies.
state_quarantine() {
  local file=$1 now
  now=$(serve_now 2>/dev/null) || now=$(date +%s)
  [ -e "$file" ] || return 0
  mv -f "$file" "$file.corrupt-$now" 2>/dev/null || rm -f "$file"
  echo "senior-mode: $file could not be read; kept as $file.corrupt-$now, the default applies" >&2
}

# state_get <file> <regex>: the first line of the file, when the whole line matches the extended regex. A missing file
# is not there (status 1, nothing said); one with another content is set aside (state_quarantine).
state_get() {
  local file=$1 re=$2 line
  [ -e "$file" ] || return 1
  line=$(head -n 1 "$file" 2>/dev/null) || line=""
  if [[ $line =~ ^($re)$ ]]; then
    printf '%s\n' "$line"
    return 0
  fi
  state_quarantine "$file"
  return 1
}

# state_num <file> [<default>]: a whole number, the default (0) when the file is not there or was set aside.
state_num() {
  state_get "$1" '[0-9]+' || echo "${2:-0}"
}

# state_json <file>: the file when it is a JSON object, set aside when it is not.
state_json() {
  [ -e "$1" ] || return 1
  if jq -e 'type == "object"' "$1" >/dev/null 2>&1; then
    cat "$1"
    return 0
  fi
  state_quarantine "$1"
  return 1
}

# state_sweep <dir>, at start: the temporary files of a write that a kill cut (<file>.tmp.<pid> of a process that is gone,
# or over an hour old) are removed, and the files set aside over 7 days ago.
state_sweep() {
  local f pid
  for f in "$1"/*.tmp.*; do
    [ -f "$f" ] || continue
    pid=${f##*.tmp.}
    if [[ ! $pid =~ ^[0-9]+$ ]] || ! kill -0 "$pid" 2>/dev/null || [ -n "$(find "$f" -mmin +60 2>/dev/null)" ]; then
      rm -f "$f"
    fi
  done
  find "$1" -maxdepth 1 -type f -name '*.corrupt-*' -mtime +7 -delete 2>/dev/null || true
}
