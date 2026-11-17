#!/usr/bin/env bash
# Tests for skill-size.sh: SKILL.md files above the budget fail, sibling reference files do not count.
set -u
script=$(cd "$(dirname "$0")" && pwd)/skill-size.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

mkdir -p "$work/plugins/p/skills/small" "$work/plugins/p/skills/big"
head -c 3000 /dev/zero | tr '\0' a >"$work/plugins/p/skills/small/SKILL.md"
head -c 9000 /dev/zero | tr '\0' a >"$work/plugins/p/skills/small/reference.md"
(cd "$work" && "$script" >/dev/null 2>&1) || fail "fails although every SKILL.md is within budget"

head -c 3100 /dev/zero | tr '\0' a >"$work/plugins/p/skills/big/SKILL.md"
out=$(cd "$work" && "$script" 2>&1) && fail "passes with a SKILL.md over budget"
grep -q "skills/big/SKILL.md" <<<"$out" || fail "oversized file not named: $out"

[ "$failures" -eq 0 ] && echo "skill-size: all cases pass"
exit "$failures"
