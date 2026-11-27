#!/usr/bin/env bash
# Tests for the `journeys` step of `senior-mode check` (spec 328 section 5.1 and 5.2, #795). Offline.
set -u
cli=$(cd "$(dirname "$0")/.." && pwd)/senior-mode
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

repo="$work/repo"
git init -q -b main "$repo"
mkdir -p "$repo/.claude" "$repo/docs/specs" "$repo/src"
git_() { git -C "$repo" -c user.name=t -c user.email=t@t "$@"; }
commit() {
  git_ add -A
  git_ commit -q --allow-empty -m "$1"
}
run() { (cd "$repo" && "$cli" "$@") >"$work/out" 2>&1; }
spec() { # <status> <journeys lines>
  printf -- '---\nid: 328\ntitle: pay\nstatus: %s\nsize: L\npaths: ["src/**"]\n%s---\n\n# pay\n' "$1" "$2" >"$repo/docs/specs/328-pay.md"
}
journeys='journeys:
  - { id: J1, name: "A buyer pays an invoice", test: "e2e/pay.spec.ts" }
  - { id: J2, name: "A buyer, then refunds", test: "e2e/refund.spec.ts" }
'
branch() {
  git_ checkout -q main && git_ checkout -q -B "$1"
  mkdir -p "$repo/src" "$repo/docs/specs"
}

echo '{"checks":[{"name":"lint","run":"true"}]}' >"$repo/.claude/senior-mode.json"
spec accepted "$journeys"
echo base >"$repo/README.md"
commit "chore: base"

# A diff in the paths of the spec selects its journeys; none has its test yet.
branch feat-a
echo 1 >"$repo/src/a.ts"
commit "feat: a"
run journeys-check && fail "A: a diff in the paths passes with no test: $(cat "$work/out")"
grep -qx 'journey J1 of spec 328 has no test at e2e/pay.spec.ts' "$work/out" || fail "A: J1 not named: $(cat "$work/out")"
grep -qx 'journey J2 of spec 328 has no test at e2e/refund.spec.ts' "$work/out" || fail "A: J2 not named: $(cat "$work/out")"

# The step of check fails the same way, and the summary names it.
run check && fail "A: check passes with a journey without test"
grep -q '^FAIL  journeys' "$work/out" || fail "A: no journeys step in check: $(cat "$work/out")"
grep -q 'journey J1 of spec 328 has no test' "$work/out" || fail "A: check does not show the journey: $(cat "$work/out")"

# A test file without the id in it is no test; with the ids in titles it passes.
mkdir -p "$repo/e2e"
printf 'test("buyer pays", () => {});\n' >"$repo/e2e/pay.spec.ts"
printf 'test("J2 buyer refunds", () => {});\n' >"$repo/e2e/refund.spec.ts"
run journeys-check && fail "B: a test file with no id passes"
grep -qx 'journey J1 of spec 328 has no test at e2e/pay.spec.ts' "$work/out" || fail "B: J1 not named: $(cat "$work/out")"
grep -q 'J2' "$work/out" && fail "B: J2 has its id and is reported: $(cat "$work/out")"
printf 'test("J1 buyer pays", () => {});\n' >"$repo/e2e/pay.spec.ts"
run journeys-check || fail "B: both tests have their id and the step fails: $(cat "$work/out")"
printf 'test("J10 buyer pays", () => {});\n' >"$repo/e2e/pay.spec.ts"
run journeys-check && fail "B: J10 counts as J1"
rm -rf "$repo/e2e"

# A diff elsewhere selects nothing.
branch feat-c
echo 2 >"$repo/README.md"
commit "docs: readme"
run journeys-check || fail "C: a diff elsewhere fails: $(cat "$work/out")"
grep -qx 'skipped: no journey on the touched paths' "$work/out" || fail "C: no skip line: $(cat "$work/out")"
run check || fail "C: check fails on a skipped step: $(cat "$work/out")"
grep -q '^skip  journeys: no journey on the touched paths' "$work/out" || fail "C: check does not say skip: $(cat "$work/out")"

# check --all selects every journey; journeys.required false makes the missing test a warning.
run journeys-check --all && fail "D: --all passes with no test"
grep -q 'journey J1 of spec 328' "$work/out" && grep -q 'journey J2 of spec 328' "$work/out" || fail "D: --all did not select both: $(cat "$work/out")"
echo '{"checks":[{"name":"lint","run":"true"}],"journeys":{"required":false}}' >"$repo/.claude/senior-mode.json"
run journeys-check --all || fail "D: required false fails: $(cat "$work/out")"
grep -qx 'warning: journey J1 of spec 328 has no test at e2e/pay.spec.ts' "$work/out" || fail "D: no warning: $(cat "$work/out")"
echo '{"checks":[{"name":"lint","run":"true"}]}' >"$repo/.claude/senior-mode.json"
git_ checkout -q -- .claude

# A pull request that only adds a spec with journeys whose tests do not exist yet passes.
git_ checkout -q main
git_ rm -q --cached docs/specs/328-pay.md && rm "$repo/docs/specs/328-pay.md"
commit "chore: no spec"
branch feat-e
spec accepted "$journeys"
commit "docs: add the spec"
run journeys-check || fail "E: a docs-only spec pull request fails: $(cat "$work/out")"
grep -q '^skipped: no journey' "$work/out" || fail "E: not skipped: $(cat "$work/out")"
run check || fail "E: check fails on a docs-only spec pull request: $(cat "$work/out")"

# A test file in the diff selects its journey, and only that one.
git_ checkout -q -B feat-f
mkdir -p "$repo/e2e"
printf 'test("buyer pays", () => {});\n' >"$repo/e2e/pay.spec.ts"
commit "test: pay"
run journeys-check && fail "F: a changed test without the id passes"
grep -q 'J1' "$work/out" && ! grep -q 'J2' "$work/out" || fail "F: not only J1: $(cat "$work/out")"

# Declaration errors fail naming the spec, in an accepted spec only.
declare_bad() { # <label> <journeys lines> <expected message>
  spec accepted "$2"
  commit "docs: $1"
  run journeys-check && fail "G: $1 passes"
  grep -qF "spec 328: $3" "$work/out" || fail "G: $1 does not name the spec: $(cat "$work/out")"
}
git_ checkout -q feat-e && git_ checkout -q -B feat-g
declare_bad "duplicate id" 'journeys:
  - { id: J1, name: "a", test: "e2e/a.spec.ts" }
  - { id: J1, name: "b", test: "e2e/b.spec.ts" }
' "journey J1 is declared twice"
declare_bad "dotdot" 'journeys:
  - { id: J1, name: "a", test: "../a.spec.ts" }
' 'journey J1 test "../a.spec.ts" must be a relative path with no ..'
declare_bad "absolute" 'journeys:
  - { id: J1, name: "a", test: "/etc/a.spec.ts" }
' 'journey J1 test "/etc/a.spec.ts" must be a relative path with no ..'
spec draft 'journeys:
  - { id: J1, name: "a", test: "../a.spec.ts" }
  - { id: J1, name: "b", test: "e2e/b.spec.ts" }
'
echo 3 >"$repo/src/b.ts"
commit "feat: draft spec"
run journeys-check --all || fail "H: a draft spec is not ignored: $(cat "$work/out")"
run check --all >/dev/null 2>&1
grep -q 'journeys' "$work/out" && fail "H: a draft spec adds a journeys step"

# The spec template shows the front matter.
grep -q '^journeys:$' "$(dirname "$cli")/../skills/spec/template.md" || fail "I: the spec template has no journeys front matter"

[ "$failures" -eq 0 ] && echo "ok: journeys tests passed" || exit 1
