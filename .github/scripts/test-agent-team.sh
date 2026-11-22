#!/usr/bin/env bash
# Tests for agent-team.sh: the team of ADR 0004 passes, a missing role, a wrong pin, a reviewer
# cheaper than the implementer, a security agent off Opus, ops loading CLAUDE.md or an unknown preloaded skill fail.
set -u
script=$(cd "$(dirname "$0")" && pwd)/agent-team.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

agent() { # name model effort [extra frontmatter line]
  printf -- '---\nname: %s\ndescription: d\nmodel: %s\neffort: %s\nmaxTurns: 10\n%s\n---\n\nBody.\n' \
    "$1" "$2" "$3" "${4:-}" >"$work/p/agents/$1.md"
}
team() {
  rm -rf "$work/p" && mkdir -p "$work/p/agents" "$work/p/skills/tdd"
  touch "$work/p/skills/tdd/SKILL.md"
  agent scout haiku low
  agent researcher sonnet medium
  agent architect opus high
  agent test-author sonnet medium "skills: [tdd]"
  agent implementer sonnet medium
  agent reviewer opus high
  agent security opus high
  agent ops haiku low "omitClaudeMd: true"
}
expect_fail() { # reason, then the output must name the file
  out=$("$script" "$work/p" 2>&1) && fail "passes with $1"
  grep -q "$2" <<<"$out" || fail "$1: $2 not named in: $out"
}

team
"$script" "$work/p" >/dev/null 2>&1 || fail "fails on the team of ADR 0004: $("$script" "$work/p" 2>&1)"

team && rm "$work/p/agents/scout.md"
expect_fail "a missing role" scout.md

team && agent researcher opus medium
expect_fail "a model other than its pin" researcher.md

team && agent architect opus low
expect_fail "an effort other than its pin" architect.md

team && sed -i '/^maxTurns/d' "$work/p/agents/implementer.md"
expect_fail "no maxTurns" implementer.md

team && agent reviewer haiku high
expect_fail "a reviewer cheaper than the implementer" reviewer.md

team && agent security sonnet high
expect_fail "a security agent cheaper than Opus" security.md

team && rm "$work/p/agents/security.md"
expect_fail "a missing security agent" security.md

team && agent ops haiku low
expect_fail "ops loading CLAUDE.md" ops.md

team && agent test-author sonnet medium "skills: [tdd, nope]"
expect_fail "an unknown preloaded skill" test-author.md

[ "$failures" -eq 0 ] && echo "agent-team: all cases pass"
exit "$failures"
