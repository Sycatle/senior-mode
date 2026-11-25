#!/usr/bin/env bash
# #579: the timing cases of test-serve.sh (G, AG) and test-run.sh (T) must not fail under load. They wait on an event
# or a bounded poll, never on a wall-clock budget ($SECONDS or date +%s compared to a number) or a fixed sleep of the
# claude stub, and they say in a note which time unit they use. This test reads those cases and checks that.
set -u
here=$(cd "$(dirname "$0")" && pwd)
failures=0
fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

block() { # <file> <start regex> <end regex>: the lines of a case, start line included, end line excluded
  awk -v s="$2" -v e="$3" '!on && $0 ~ s {on=1} on && NR > start_nr && started && $0 ~ e {exit} on {started=1; print}' "$1"
}

check_case() { # <name> <file> <start regex> <end regex>
  local name=$1 text
  text=$(block "$2" "$3" "$4")
  [ -n "$text" ] || { fail "$name: case not found in $2"; return; }
  # shellcheck disable=SC2016 # the pattern looks for a literal $((...))
  if grep -Eq '\$\(\(\s*(\$?SECONDS|\$\(date \+%s\))[^)]*\)\)\s*-(lt|le|gt|ge)|"\$SECONDS"\s*-(lt|le)|\$\(date \+%s\)\)' <<<"$text"; then
    fail "$name: waits on a wall-clock budget: $(grep -En 'SECONDS|date \+%s' <<<"$text" | head -3 | tr '\n' ';')"
  fi
  grep -Eqi 'time unit|unit of time|minutes are seconds' <<<"$(grep -E '^\s*#' <<<"$text")" ||
    fail "$name: no note explains the time unit"
}

check_case "serve G" "$here/test-serve.sh" '^# G: TERM stops' '^# J: alerts'
check_case "serve AG" "$here/test-serve.sh" '^# AG: the watchdog' '^unset SENIOR_MODE_TIMEOUT_UNIT'
check_case "run T" "$here/test-run.sh" '^# T: a ticket session script' '^# U: tickets whose Paths'

# The "slow" session of serve G ends on an event, not after a fixed sleep.
grep -Eq '^\s*slow\) sleep [0-9.]+ ;;' "$here/test-serve.sh" &&
  fail "serve G: the slow session ends after a fixed sleep"

[ "$failures" -eq 0 ] || exit 1
echo "ok"
