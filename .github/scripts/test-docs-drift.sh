#!/usr/bin/env bash
# Tests for docs-drift.sh on a small fake repository: in sync passes, each kind of drift fails naming it.
# shellcheck disable=SC2016 # backquotes in fixtures are Markdown, not shell
set -u
script=$(cd "$(dirname "$0")" && pwd)/docs-drift.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }
reset() {
  rm -rf "$work/r"
  mkdir -p "$work/r/plugins/senior-mode/skills/tdd" "$work/r/plugins/senior-mode/skills/run" \
    "$work/r/plugins/senior-mode/agents" "$work/r/plugins/senior-mode/bin" "$work/r/docs/guide"
  cd "$work/r" || exit 1
  : >plugins/senior-mode/skills/tdd/SKILL.md
  : >plugins/senior-mode/skills/run/SKILL.md
  : >plugins/senior-mode/agents/scout.md
  echo '  die "usage: senior-mode config get <key> | run [--max N] | check"' >plugins/senior-mode/bin/senior-mode
  printf '## `tdd`\n' >docs/guide/skills.md
  printf '## `scout`\n' >docs/guide/agents.md
  printf '| `/senior-mode:run` | Runs | Available |\n## `run`\n| `senior-mode config get <key>` | x |\n| `senior-mode run [--max N]` | x |\n| `senior-mode check` | x |\n' >docs/guide/commands.md
  printf '# x\n## A\n| `/senior-mode:run` | Runs | Available |\n' >README.md
  printf '# x\n## A\n| `/senior-mode:run` | Lance | Disponible |\n' >README.fr.md
}
expect_fail() { # what pattern
  out=$("$script" 2>&1) && fail "$1: passes"
  grep -q "$2" <<<"$out" || fail "$1: not named: $out"
}

reset
"$script" >/dev/null 2>&1 || fail "in sync but fails: $("$script" 2>&1)"

reset; mkdir plugins/senior-mode/skills/retro; : >plugins/senior-mode/skills/retro/SKILL.md
expect_fail "skill without a section" "skill retro"
reset; : >plugins/senior-mode/agents/ops.md
expect_fail "agent without a section" "agent ops"
reset; sed -i 's/| check"/| check | schedule install [--at HH:MM]"/' plugins/senior-mode/bin/senior-mode
expect_fail "script command without a row" "schedule install"
reset; printf '| `/senior-mode:ship` | Ships | Available |\n' >>README.md; printf '## B\n' >>README.fr.md; printf '## B\n' >>README.md
expect_fail "available command without a skill" "senior-mode:ship"
reset; printf '| `/senior-mode:ship` | Ships | Coming in v0.4 |\n' >>README.md
"$script" >/dev/null 2>&1 || fail "a coming command counts as available"
reset; printf '## B\n' >>README.md
expect_fail "READMEs out of sync" "README.fr.md 1"

[ "$failures" -eq 0 ] && echo "docs-drift: all cases pass"
exit "$failures"
