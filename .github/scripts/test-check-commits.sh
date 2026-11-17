#!/usr/bin/env bash
# Tests for check-commits.sh: each case feeds commit subjects on stdin and expects an exit status.
set -u
here=$(dirname "$0")
failures=0

expect() {
  local want=$1 subjects=$2 got
  printf '%s\n' "$subjects" | "$here/check-commits.sh" >/dev/null 2>&1
  got=$?
  if [ "$got" -ne "$want" ]; then
    echo "FAIL (want $want, got $got): $subjects"
    failures=$((failures + 1))
  fi
}

expect 0 "feat: add plugin manifest"
expect 0 "fix(hooks): deny force-push"
expect 0 "feat(api)!: drop v1 config"
expect 0 "docs(adr): record founding decisions 0001-0005"
expect 0 "$(printf 'chore: one\nci: two')"
expect 1 "Add plugin manifest"
expect 1 "feat:missing space"
expect 1 "feature: unknown type"
expect 1 "feat(): empty scope"
expect 1 "$(printf 'feat: fine\nwip')"

[ "$failures" -eq 0 ] && echo "check-commits: all cases pass"
exit "$failures"
