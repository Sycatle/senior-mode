#!/usr/bin/env bash
# Tests for the capture of knowledge notes by the implementer (#336, spec 325 §4): the instructions are
# wired and bounded, and the eval grader (evals/knowledge/grade.sh) accepts a good session and refuses the
# bad ones. Offline: no model is run, the sessions' results are written by hand.
set -u
root=$(cd "$(dirname "$0")/../../../.." && pwd)
plugin=$root/plugins/senior-mode
grade=$root/evals/knowledge/grade.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }
note() { # <file> <origin> [kind]: a valid note
  mkdir -p "$(dirname "$1")"
  printf -- '---\npaths: ["src/invoice.js"]\nverified: 2026-11-24\norigin: "%s"\nkind: %s\n---\n\n# Import order\n\nmoney.js reads the locale when imported.\n' "$2" "${3:-pitfall}" >"$1"
}
new_repo() { # <name>: a git repository with the fixture
  repo=$work/$1
  mkdir -p "$repo"
  cp -r "$root/evals/knowledge/pitfall/repo/." "$repo"
  git init -q -b main "$repo"
}
expect() { # <wanted status> <label> <args...>
  local want=$1 label=$2 status out
  shift 2
  out=$("$grade" "$@" 2>&1)
  status=$?
  [ "$status" -eq "$want" ] || fail "$label: exit $status, wanted $want ($out)"
}

# The instructions point to the reference, which names the bounds of the spec.
grep -q 'knowledge.md' "$plugin/skills/tdd/SKILL.md" || fail "skill tdd does not point to knowledge.md"
grep -q 'knowledge' "$plugin/agents/implementer.md" || fail "the implementer agent does not mention knowledge notes"
ref=$plugin/skills/tdd/knowledge.md
grep -q 'twice' "$ref" || fail "knowledge.md: no trigger of two retries"
grep -q 'never more than 2' "$ref" || fail "knowledge.md: no bound of 2 notes"
# shellcheck disable=SC2016 # backquotes are Markdown
grep -q 'same `paths` and the same `kind`' "$ref" || fail "knowledge.md: no rule to edit an existing note"
grep -q 'verified' "$ref" || fail "knowledge.md: no re-verification"
[ "$(wc -c <"$plugin/skills/tdd/SKILL.md")" -le 3072 ] || fail "skill tdd is over 3072 bytes"

# A session that hit the pitfall: one valid note whose origin is its ticket.
new_repo pitfall
note "$repo/docs/knowledge/import-order-invoice.md" '#900'
expect 0 "one valid note" "$repo" '#900'
note "$repo/docs/knowledge/second-fact.md" '#900'
expect 0 "two notes" "$repo" '#900'
note "$repo/docs/knowledge/third-fact.md" '#900'
expect 1 "three notes" "$repo" '#900'

new_repo wrong-origin
note "$repo/docs/knowledge/import-order-invoice.md" '#12'
expect 1 "origin of another ticket" "$repo" '#900'

new_repo invalid
note "$repo/docs/knowledge/Import_Order.md" '#900'
expect 1 "note that check refuses" "$repo" '#900'

new_repo missing
expect 1 "no note after a pitfall" "$repo" '#900'

# A session with no pitfall adds none.
new_repo clean
expect 0 "no pitfall, no note" "$repo" '#900' none
note "$repo/docs/knowledge/import-order-invoice.md" '#900'
expect 1 "note with no pitfall" "$repo" '#900' none

# The fixture reproduces the pitfall: the sorted imports break the test, `keep-order` fixes lint.
new_repo fixture
# shellcheck disable=SC2016 # the template literal is JavaScript
printf 'import { ready } from "./locale.js";\nimport { euros } from "./money.js";\n\nexport const totalLabel = (cents) => (ready ? `${euros(cents)} EUR` : "");\n' >"$repo/src/invoice.js"
(cd "$repo" && npm run --silent lint >/dev/null 2>&1) && fail "fixture: lint accepts unsorted imports"
(cd "$repo" && npm run --silent fix >/dev/null 2>&1 && npm test >/dev/null 2>&1) && fail "fixture: sorted imports still pass the test"

[ "$failures" -eq 0 ] && echo "ok test-knowledge-capture" || exit 1
