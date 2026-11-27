#!/usr/bin/env bash
# Tests for the ratchet of lint and coverage (#420, spec 409 §5): `senior-mode ratchet`, the `ratchet` step of `check`
# and `check --update-baseline`. Offline: the lint output is a file the lint command prints.
set -u
cli=$(cd "$(dirname "$0")/.." && pwd)/senior-mode
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }
g() { git -C "$repo" -c user.name=t -c user.email=t@t "$@"; }
run() { (cd "$repo" && "$cli" "$@") >"$work/out" 2>&1; }
out() { cat "$work/out"; }

export LINT_OUT=$work/lint.json
# lint <file> <rule> <line>...: the findings the lint command prints, in the common format; lint_add appends.
lint() { local f=$1 r=$2; shift 2; jq -nc --arg f "$f" --arg r "$r" '[$ARGS.positional[] | {file: $f, rule: $r, line: (. | tonumber)}]' --args "$@" >"$LINT_OUT"; }
lint_add() { local f=$1 r=$2; shift 2; jq -c --arg f "$f" --arg r "$r" '. + [$ARGS.positional[] | {file: $f, rule: $r, line: (. | tonumber)}]' "$LINT_OUT" --args "$@" >"$LINT_OUT.n" && mv "$LINT_OUT.n" "$LINT_OUT"; }
# lcov <file> <lines> <hit>...: pairs of file, lines found, lines hit.
lcov() { : >"$repo/coverage/lcov.info"; while [ $# -ge 3 ]; do printf 'SF:%s\nLF:%s\nLH:%s\nend_of_record\n' "$1" "$2" "$3" >>"$repo/coverage/lcov.info"; shift 3; done; }
reset() { g checkout -q -- . && g clean -fdq && g checkout -q main; }

repo=$work/repo
git init -q -b main "$repo"
mkdir -p "$repo/.claude" "$repo/src" "$repo/coverage"
seq 1 30 | sed 's/^/const x/; s/$/ = 1;/' >"$repo/src/a.ts"
seq 1 10 | sed 's/^/const y/; s/$/ = 1;/' >"$repo/src/other.ts"
printf 'coverage/\n' >"$repo/.gitignore"
cat >"$repo/.claude/senior-mode.json" <<'JSON'
{"audit": false, "checks": [{"name": "lint", "run": "true"}],
 "ratchet": {"lint": {"command": "cat \"$LINT_OUT\""}, "coverage": {"report": "coverage/lcov.info"}}}
JSON
cat >"$repo/.claude/ratchet-baseline.json" <<'JSON'
{"version": 1, "createdAt": "2026-11-23",
 "lint": {"total": 7, "files": {"src/a.ts": {"no-explicit-any": 7}}},
 "coverage": {"total": 50.0, "files": {"src/a.ts": 40.0}}}
JSON
g add -A
g commit -q -m "chore: base"
base_lint() { lint src/a.ts no-explicit-any 2 4 6 8 10 12 14; }
base_lint
lcov src/a.ts 10 4

# Untouched code: nothing changed, findings of files nobody touched do not fail anyone.
run ratchet-check || fail "a clean tree fails: $(out)"
lint_add src/other.ts semi 1 2 3
run ratchet-check || fail "an untouched file with findings fails: $(out)"
base_lint

# 7 findings in the baseline: a change to another function that adds none passes; an eighth fails naming file, rule, line.
sed -i '25s/1/2/' "$repo/src/a.ts"
run ratchet-check || fail "a change that adds no finding fails: $(out)"
lint_add src/a.ts no-explicit-any 25
run ratchet-check && fail "an eighth finding passes"
grep -q "src/a.ts:25: no-explicit-any" "$work/out" || fail "file, rule and line not named: $(out)"
reset
base_lint
lint_add src/a.ts no-explicit-any 20
sed -i '25s/1/2/' "$repo/src/a.ts"
run ratchet-check && fail "an eighth finding away from the diff passes"
grep -q "src/a.ts:20: no-explicit-any: 8 findings in the file, the baseline allows 7" "$work/out" || fail "the surplus finding is not named: $(out)"
reset

# A finding on a changed line fails even when the count is within the baseline (one fixed, one added).
lint src/a.ts no-explicit-any 2 4 6 8 10 12 25
sed -i '25s/1/2/' "$repo/src/a.ts"
run ratchet-check && fail "a finding on a changed line passes"
grep -q "src/a.ts:25: no-explicit-any: a finding on a line the branch changes" "$work/out" || fail "changed line not named: $(out)"
reset

# Fixing 3 of the 7: stale until --update-baseline lowers it to 4; a worse file is refused.
base_lint
lint src/a.ts no-explicit-any 2 4 6 8
sed -i '25s/1/2/' "$repo/src/a.ts"
run ratchet-check && fail "a better file passes without updating the baseline"
grep -q "baseline stale: run senior-mode check --update-baseline" "$work/out" || fail "stale not said: $(out)"
run check --update-baseline || fail "update-baseline fails: $(out)"
[ "$(jq -c '[.lint.files["src/a.ts"]["no-explicit-any"], .lint.total]' "$repo/.claude/ratchet-baseline.json")" = "[4,4]" ] || fail "baseline not lowered to 4: $(cat "$repo/.claude/ratchet-baseline.json")"
run ratchet-check || fail "the lowered baseline fails: $(out)"
reset
lint src/a.ts no-explicit-any 2 4 6 8
sed -i '25s/1/2/' "$repo/src/a.ts"
run check --update-baseline
lint_add src/a.ts no-explicit-any 3 5 7 9 11
cp "$repo/.claude/ratchet-baseline.json" "$work/before.json"
run check --update-baseline && fail "update-baseline accepts a worse file"
cmp -s "$work/before.json" "$repo/.claude/ratchet-baseline.json" || fail "a refused update wrote the baseline"
reset
# Fixing all of them deletes the entry.
lint src/other.ts semi
sed -i '25s/1/2/' "$repo/src/a.ts"
run check --update-baseline || fail "update-baseline at zero fails: $(out)"
[ "$(jq -c '.lint' "$repo/.claude/ratchet-baseline.json")" = '{"total":0,"files":{}}' ] || fail "entry not deleted at zero: $(cat "$repo/.claude/ratchet-baseline.json")"
reset

# A new file: one finding fails whatever the baseline says; coverage under patchCoverage fails.
base_lint
printf 'const z = 1;\n' >"$repo/src/new.ts"
lint_add src/new.ts semi 1
run ratchet-check && fail "a new file with a finding passes"
grep -q "src/new.ts:1: semi: a new file has no finding" "$work/out" || fail "new file not named: $(out)"
base_lint
lcov src/a.ts 10 4 src/new.ts 10 7
run ratchet-check && fail "a new file under 80% passes"
grep -q "src/new.ts: coverage 70.0% of a new file, 80% required" "$work/out" || fail "patch coverage not named: $(out)"
lcov src/a.ts 10 4 src/new.ts 10 8
run ratchet-check || fail "a new file at 80% fails: $(out)"
jq '.ratchet.patchCoverage = 90' "$repo/.claude/senior-mode.json" >"$work/c.json" && cp "$work/c.json" "$repo/.claude/senior-mode.json"
run ratchet-check && fail "ratchet.patchCoverage 90 is not read"
reset
lcov src/a.ts 10 4

# A touched file whose coverage drops fails; one that improves is stale.
sed -i '25s/1/2/' "$repo/src/a.ts"
lcov src/a.ts 10 3
run ratchet-check && fail "a coverage drop passes"
grep -q "src/a.ts: coverage 30.0% below the baseline 40.0%" "$work/out" || fail "coverage drop not named: $(out)"
lcov src/a.ts 10 5
run ratchet-check && fail "a coverage gain passes without updating the baseline"
grep -q "baseline stale" "$work/out" || fail "coverage gain not stale: $(out)"
run check --update-baseline || fail "update-baseline fails: $(out)"
jq -e '.coverage.files["src/a.ts"] == 50' "$repo/.claude/ratchet-baseline.json" >/dev/null || fail "coverage floor not raised: $(cat "$repo/.claude/ratchet-baseline.json")"
reset
lcov src/a.ts 10 4

# A hand edit of the baseline is compared with the base branch's.
edit() { jq "$1" "$repo/.claude/ratchet-baseline.json" >"$work/b.json" && cp "$work/b.json" "$repo/.claude/ratchet-baseline.json"; }
for e in '.lint.files["src/a.ts"]["no-explicit-any"] = 9 | .lint.total = 9' '.lint.total = 8' '.lint.files["src/other.ts"] = {"semi": 1} | .lint.total = 8' \
  '.lint.files["src/a.ts"].semi = 1' '.coverage.total = 40.0' '.coverage.files["src/a.ts"] = 30.0' '.coverage.files["src/other.ts"] = 10.0'; do
  edit "$e"
  run ratchet-check && fail "a hand edit passes: $e"
  grep -q "ratchet baseline worse than on main" "$work/out" || fail "hand edit not named: $e: $(out)"
  reset
done
edit '.coverage.total = 60.0 | .coverage.files["src/a.ts"] = 45.0'
run ratchet-check || fail "raising a coverage floor by hand fails: $(out)"
reset
# Not measured, never guessed.
jq '.ratchet.lint.command = "echo hello"' "$repo/.claude/senior-mode.json" >"$work/c.json" && cp "$work/c.json" "$repo/.claude/senior-mode.json"
g commit -q -a -m "chore: no machine format"
run ratchet || fail "ratchet fails: $(out)"
grep -q "^lint: not measured: .*set ratchet.lint.command" "$work/out" || fail "lint not measured is not said with its key: $(out)"
grep -q "^coverage: 50.0% in the baseline, 40.0% measured" "$work/out" || fail "coverage not shown: $(out)"
run ratchet-check || fail "a lint command with no machine format fails the check: $(out)"
grep -q "warning: ratchet: lint: not measured" "$work/out" || fail "check does not warn: $(out)"
g revert --no-edit HEAD >/dev/null
rm -f "$repo/coverage/lcov.info"
run ratchet || fail "ratchet fails: $(out)"
grep -q "^coverage: not measured: no coverage report\|^coverage: not measured: the coverage report coverage/lcov.info does not exist" "$work/out" || fail "missing report not said: $(out)"
lcov src/a.ts 10 4

# The formats of the linters.
fmt() { # label expected-count: the lint output is in $LINT_OUT
  run ratchet || fail "$1: $(out)"
  grep -q "$2 measured" "$work/out" || fail "$1: $2 findings expected: $(out)"
}
cat >"$LINT_OUT" <<JSON
[{"filePath": "$repo/src/a.ts", "messages": [{"ruleId": "no-explicit-any", "line": 3}, {"ruleId": null, "line": 4}]}, {"filePath": "$repo/src/other.ts", "messages": []}]
JSON
fmt eslint 2
cat >"$LINT_OUT" <<JSON
[{"code": "E501", "filename": "$repo/src/a.ts", "location": {"row": 3, "column": 1}}, {"code": "F401", "filename": "$repo/src/a.ts", "location": {"row": 5, "column": 1}}, {"code": "F401", "filename": "$repo/src/other.ts", "location": {"row": 5, "column": 1}}]
JSON
fmt ruff 3
printf '{"Issues": [{"FromLinter": "errcheck", "Pos": {"Filename": "src/a.ts", "Line": 3}}]}\n' >"$LINT_OUT"
fmt golangci-lint 1
printf '{"Issues": null}\n' >"$LINT_OUT"
fmt "golangci-lint clean" 0
{
  echo '{"reason": "compiler-artifact", "target": {"name": "x"}}'
  echo '{"reason": "compiler-message", "message": {"code": {"code": "clippy::needless_return"}, "spans": [{"file_name": "src/a.ts", "line_start": 9, "is_primary": true}]}}'
  echo '{"reason": "compiler-message", "message": {"code": null, "spans": []}}'
  echo '{"reason": "build-finished", "success": true}'
} >"$LINT_OUT"
fmt clippy 1
echo 'not json' >"$LINT_OUT"
run ratchet
grep -q "^lint: not measured: .*set ratchet.lint.command" "$work/out" || fail "an unknown format is not said: $(out)"
base_lint

# Cobertura.
cat >"$repo/coverage/lcov.info" <<XML
<?xml version="1.0"?><coverage line-rate="0.5" branch-rate="0"><packages><package name="src"><classes>
<class name="a" filename="$repo/src/a.ts" line-rate="0.4"><lines/></class></classes></package></packages></coverage>
XML
run ratchet || fail "cobertura: $(out)"
grep -q "^coverage: 50.0% in the baseline, 50.0% measured" "$work/out" || fail "cobertura total not read: $(out)"
sed -i '25s/1/2/' "$repo/src/a.ts"
run ratchet-check || fail "cobertura: a touched file at its floor fails: $(out)"
reset
lcov src/a.ts 10 4

# Accessibility (#496): the baseline counts the serious axe violations per journey and rule, from the reports of the axe
# helper (test-results/a11y/<journey>.json). --update-baseline only lowers it; a violation that is not in it is refused.
printf 'test-results/\n' >>"$repo/.gitignore"
edit '.a11y = {total: 3, journeys: {checkout: {label: 3}}}'
g commit -q -a -m "chore: a11y baseline"
# a11y_report <journey> <impact> <rule> <count>...: the serious and other violations the journey measured.
a11y_report() {
  local j=$1; shift; mkdir -p "$repo/test-results/a11y"
  jq -nc --arg j "$j" '[$ARGS.positional as $p | range(0; $p | length; 3) | {journey: $j, page: "/p", impact: $p[.], rule: $p[. + 1], selector: "#x", n: ($p[. + 2] | tonumber)}
    | . as $f | range(0; .n) | $f | del(.n)]' --args "$@" >"$repo/test-results/a11y/$j.json"
}
a11y_report checkout serious label 2
run ratchet || fail "ratchet with an a11y baseline fails: $(out)"
grep -q "^a11y: 3 serious violations in the baseline, 2 measured" "$work/out" || fail "a11y not shown: $(out)"
run check --update-baseline || fail "update-baseline fails on a lowered a11y count: $(out)"
jq -e '.a11y == {total: 2, journeys: {checkout: {label: 2}}}' "$repo/.claude/ratchet-baseline.json" >/dev/null || fail "a11y count not lowered: $(cat "$repo/.claude/ratchet-baseline.json")"
reset
a11y_report checkout serious label 1 moderate color-contrast 4
run check --update-baseline || fail "a moderate violation blocks the update: $(out)"
jq -e '.a11y.journeys.checkout == {label: 1}' "$repo/.claude/ratchet-baseline.json" >/dev/null || fail "moderate violations enter the baseline: $(cat "$repo/.claude/ratchet-baseline.json")"
reset
a11y_report checkout critical label 3
a11y_report login serious label 0
run check --update-baseline || fail "update-baseline fails with a journey at zero: $(out)"
jq -e '.a11y == {total: 3, journeys: {checkout: {label: 3}}}' "$repo/.claude/ratchet-baseline.json" >/dev/null || fail "a journey at zero changes the baseline: $(cat "$repo/.claude/ratchet-baseline.json")"
reset
a11y_report checkout serious label 3 serious color-contrast 1
cp "$repo/.claude/ratchet-baseline.json" "$work/before.json"
run check --update-baseline && fail "update-baseline adds a serious violation"
grep -q "checkout: color-contrast has 1 serious violations, the baseline allows 0" "$work/out" || fail "new violation not named: $(out)"
cmp -s "$work/before.json" "$repo/.claude/ratchet-baseline.json" || fail "a refused update writes the baseline"
reset
a11y_report checkout serious label 4
run check --update-baseline && fail "update-baseline raises a count"
grep -q "checkout: label has 4 serious violations, the baseline allows 3" "$work/out" || fail "raised count not named: $(out)"
reset
a11y_report checkout serious label 3
rm -rf "$repo/test-results"
run ratchet || fail "ratchet without an a11y report fails: $(out)"
grep -q "^a11y: not measured: no a11y report in test-results/a11y" "$work/out" || fail "missing a11y report not said: $(out)"
for e in '.a11y.journeys.checkout.label = 4 | .a11y.total = 4' '.a11y.total = 4' '.a11y.journeys.login = {label: 1} | .a11y.total = 4' '.a11y.journeys.checkout["color-contrast"] = 1'; do
  edit "$e"
  run ratchet-check && fail "an a11y hand edit passes: $e"
  grep -q "ratchet baseline worse than on main" "$work/out" || fail "a11y hand edit not named: $e: $(out)"
  reset
done
edit '.a11y.journeys.checkout.label = 2 | .a11y.total = 2'
run ratchet-check || fail "lowering an a11y count by hand fails: $(out)"
reset
rm "$repo/.claude/ratchet-baseline.json"
a11y_report checkout serious label 2 moderate color-contrast 1
run ratchet --init || fail "ratchet --init with an a11y report fails: $(out)"
jq -e '.a11y == {total: 2, journeys: {checkout: {label: 2}}}' "$repo/.claude/ratchet-baseline.json" >/dev/null || fail "a11y not frozen from the reports: $(cat "$repo/.claude/ratchet-baseline.json")"
reset

# The axe helper on fixture results, no browser: a serious violation fails with rule, selector and page; a moderate one
# is reported; a baselined one passes up to its count.
if command -v node >/dev/null && [ "$(node -p 'process.versions.node.split(".")[0]')" -ge 22 ]; then
  mkdir -p "$work/axe" && cp "$(dirname "$cli")/../presets/node/e2e/axe.ts" "$work/axe/axe.ts"
  cat >"$work/axe/check.mjs" <<'JS'
import assert from 'node:assert/strict'
import { findings, judge } from './axe.ts'

const result = (...v) => ({ violations: v.map(([id, impact, ...targets]) => ({ id, impact, nodes: targets.map((t) => ({ target: [t] })) })) })
const run = (r, baseline = {}) => judge(findings('signup', '/signup', r), baseline)

let r = run(result(['label', 'critical', '#email']))
assert.deepEqual(r.failures, ['label (critical) #email on /signup'])
r = run(result(['color-contrast', 'moderate', '.hint']))
assert.deepEqual(r.failures, [])
assert.deepEqual(r.reports, ['color-contrast (moderate) .hint on /signup'])
const baseline = { a11y: { journeys: { signup: { label: 1 } } } }
r = run(result(['label', 'serious', '#email']), baseline)
assert.deepEqual(r.failures, [])
assert.deepEqual(r.reports, ['label (serious) #email on /signup'])
r = run(result(['label', 'serious', '#email', '#name']), baseline)
assert.equal(r.failures.length, 2)
r = run(result(['label', 'serious', '#email'], ['image-alt', 'serious', 'img']), baseline)
assert.deepEqual(r.failures, ['image-alt (serious) img on /signup'])
JS
  (cd "$work/axe" && node check.mjs) >"$work/out" 2>&1 || fail "axe helper: $(tail -8 "$work/out")"
else echo "skip: axe helper: node 22 or later is needed to run TypeScript"; fi

# No baseline: the full bar, and no ratchet step.
git init -q -b main "$work/plain"
mkdir "$work/plain/.claude"
echo '{"audit": false, "checks": [{"name": "lint", "run": "true"}]}' >"$work/plain/.claude/senior-mode.json"
git -C "$work/plain" add -A && git -C "$work/plain" -c user.name=t -c user.email=t@t commit -q -m "chore: base"
(cd "$work/plain" && "$cli" ratchet) >"$work/out" 2>&1 || fail "ratchet without a baseline fails: $(out)"
grep -q "^no baseline: full bar" "$work/out" || fail "full bar not said: $(out)"
(cd "$work/plain" && "$cli" check) >"$work/out" 2>&1 || fail "check fails without a baseline: $(out)"
grep -q "ratchet" "$work/out" && fail "a ratchet step runs without a baseline: $(out)"

# A baseline the base branch does not have yet is the first freeze, and is accepted.
jq -n '{audit: false, checks: [{name: "lint", run: "true"}], ratchet: {lint: {command: "cat \"$LINT_OUT\""}}}' >"$work/plain/.claude/senior-mode.json"
git -C "$work/plain" -c user.name=t -c user.email=t@t commit -q -a -m "chore: ratchet config"
echo '{"version": 1, "lint": {"total": 1, "files": {"src/a.ts": {"semi": 1}}}}' >"$work/plain/.claude/ratchet-baseline.json"
lint src/a.ts semi 1
(cd "$work/plain" && "$cli" ratchet-check) >"$work/out" 2>&1 || fail "the first baseline fails: $(out)"

# --init freezes the tree once.
lint src/a.ts no-explicit-any 1 2 3
lint_add src/other.ts semi 4
cp "$repo/.claude/ratchet-baseline.json" "$work/old.json"
rm "$repo/.claude/ratchet-baseline.json"
lcov src/a.ts 4 3 src/other.ts 4 1
run ratchet --init || fail "ratchet --init fails: $(out)"
jq -e '[.version, .lint.total, .lint.files["src/a.ts"]["no-explicit-any"], .lint.files["src/other.ts"].semi, .coverage.total, .coverage.files["src/a.ts"]] == [1,4,3,1,50,75]' "$repo/.claude/ratchet-baseline.json" >/dev/null ||
  fail "baseline not frozen from the tree: $(cat "$repo/.claude/ratchet-baseline.json")"
run ratchet --init && fail "ratchet --init overwrites the baseline"
reset

# The step of check: it runs when the baseline exists, and a failure names the step.
base_lint
lcov src/a.ts 10 4
sed -i '25s/1/2/' "$repo/src/a.ts"
run check || fail "check fails on a change that adds no finding: $(out)"
grep -q "^ok    ratchet (" "$work/out" || fail "the ratchet step is not shown: $(out)"
lint_add src/a.ts no-explicit-any 25
run check && fail "check passes with an eighth finding"
grep -q "^FAIL  ratchet (" "$work/out" || fail "the ratchet failure is not named: $(out)"
reset

[ "$failures" -eq 0 ] && echo "ratchet: all cases pass"
exit "$failures"
