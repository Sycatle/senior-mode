#!/usr/bin/env bash
# Tests for the capture of knowledge notes (spec 325 §4). Implementer (#336): the instructions are wired
# and bounded, and the eval grader (evals/knowledge/grade.sh) accepts a good session and refuses the bad
# ones. Reviewer (#359): the finding marker grader and the note a review opens for a finding seen twice.
# Offline: no model is run, the sessions' results are written by hand.
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

# Reviewer (#359): the instructions are wired.
rev=$plugin/skills/review
grep -q 'knowledge.md' "$rev/SKILL.md" || fail "skill review does not point to knowledge.md"
grep -q 'finding: <slug>' "$rev/SKILL.md" || fail "skill review does not name the finding marker"
[ "$(wc -c <"$rev/SKILL.md")" -le 3072 ] || fail "skill review is over 3072 bytes"
# Review sections (#487, spec 471 section 7): the two checklists are read when the diff calls for them, and carry the blocking cases.
grep -q 'reliability.md' "$rev/SKILL.md" || fail "skill review does not load reliability.md"
grep -q 'compatibility.md' "$rev/SKILL.md" || fail "skill review does not load compatibility.md"
grep -q 'handlers, routes' "$rev/SKILL.md" || fail "skill review does not say a route handler calls for reliability.md"
grep -qi 'sections applied\|section applied' "$rev/SKILL.md" || fail "skill review does not name the sections applied under the verdict"
grep -q 'New shared code' "$rev/SKILL.md" || fail "skill review does not check the New shared code section"
grep -qi 'extract at the third' "$rev/SKILL.md" || fail "skill review design axis lacks the rule of three"
grep -qi '^## Blocking' "$rev/reliability.md" || fail "reliability.md has no blocking list"
grep -qi 'personal data.*log' "$rev/reliability.md" || fail "reliability.md does not name personal data in a log"
grep -qi 'expand' "$rev/compatibility.md" || fail "compatibility.md does not give expand then contract"
grep -qi 'renamed' "$rev/compatibility.md" || fail "compatibility.md does not block a rename in one step"
# Performance section (#498, spec 472): read when the diff touches application code, with its blocking cases.
grep -q 'performance.md' "$rev/SKILL.md" || fail "skill review does not load performance.md"
grep -q 'performance' "$plugin/agents/reviewer.md" || fail "the reviewer agent does not list the performance section"
grep -q 'application code' "$rev/SKILL.md" || fail "skill review does not tie performance.md to application code"
grep -q 'application code' "$rev/performance.md" || fail "performance.md does not say when it is read"
for want in 'complexity' 'cache' 'life of a process' 'payloads' 'query-count assertion' 'no index' '\.all()' 'expand then' 'declares the table small'; do
  grep -qi "$want" "$rev/performance.md" || fail "performance.md lacks: $want"
done
grep -q 'Blocking: a list endpoint or a journey with no query-count assertion' "$rev/performance.md" || fail "performance.md: a list endpoint with no query-count assertion is not blocking"
grep -q 'Blocking: a query filtering' "$rev/performance.md" || fail "performance.md: an unindexed filter or sort is not blocking"
grep -q 'Blocking: a rename or a drop' "$rev/performance.md" || fail "performance.md: a rename or a drop in one step is not blocking"
grep -q 'compatibility' "$plugin/agents/reviewer.md" || fail "the reviewer agent does not list the new sections"
grep -q 'finding: <slug>' "$plugin/agents/reviewer.md" || fail "the reviewer agent does not name the finding marker"
grep -q 'docs(knowledge): <slug>' "$rev/knowledge.md" || fail "review knowledge.md: no title of the pull request"
grep -q 'kind: pitfall' "$rev/knowledge.md" || fail "review knowledge.md: no pitfall kind"
grep -q 'covered by' "$rev/knowledge.md" || fail "review knowledge.md: no citation of a covering note"
grep -q 'untouched' "$rev/knowledge.md" || fail "review knowledge.md: the reviewed branch is not left untouched"

# The marker: every finding ends with it, slug in kebab-case.
grade_review=$root/evals/knowledge/grade-review.sh
cat >"$work/good.md" <<'MD'
**Verdict:** changes requested

Spec axis:
- `src/billing/invoice.js:12` the total is not rounded, add a test and `Math.round`. <!-- finding: missing-test-billing -->
- `src/auth/login.js:40` the error is swallowed; rethrow it at the boundary.
  Log it first. <!-- finding: swallowed-error-auth -->

Not verified: the migration, read only.
MD
"$grade_review" "$work/good.md" >/dev/null 2>&1 || fail "review with every marker refused"
# shellcheck disable=SC2016 # backquotes are Markdown
printf -- '- `src/a.js:3` bad input <!-- finding: unchecked-input-a -->
- `src/b.js:9` no marker here
' >"$work/missing.md"
"$grade_review" "$work/missing.md" >/dev/null 2>&1 && fail "finding with no marker accepted"
# shellcheck disable=SC2016 # backquotes are Markdown
printf -- '- `src/a.js:3` bad input <!-- finding: Unchecked_Input --> and more
' >"$work/bad-slug.md"
"$grade_review" "$work/bad-slug.md" >/dev/null 2>&1 && fail "finding with a bad slug accepted"
printf -- '- Verdict: approve, nothing to fix.
- Not verified: the deploy.
' >"$work/no-finding.md"
"$grade_review" "$work/no-finding.md" >/dev/null 2>&1 || fail "review with no finding refused"

# The note of a finding seen twice: origin lists both pull requests, kind pitfall, and check passes.
new_repo seen-twice
note "$repo/docs/knowledge/missing-test-billing.md" '#41, #57'
(cd "$repo" && "$plugin/bin/senior-mode" knowledge-check >/dev/null 2>&1) || fail "origin listing two pull requests refused"
note "$repo/docs/knowledge/missing-test-billing.md" '#41, retro'
(cd "$repo" && "$plugin/bin/senior-mode" knowledge-check >/dev/null 2>&1) && fail "origin mixing a pull request and retro accepted"

[ "$failures" -eq 0 ] && echo "ok test-knowledge-capture" || exit 1
