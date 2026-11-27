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
echo '{"checks":[{"name":"lint","run":"true"}],"commands":{"e2e":"true"}}' >"$repo/.claude/senior-mode.json"
run journeys-check || fail "B: both tests have their id and the step fails: $(cat "$work/out")"
printf 'test("J10 buyer pays", () => {});\n' >"$repo/e2e/pay.spec.ts"
run journeys-check && fail "B: J10 counts as J1"
rm -rf "$repo/e2e"
git_ checkout -q -- .claude

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
[ "$(grep -c 'journey J[12] of spec 328' "$work/out")" -eq 2 ] || fail "D: --all did not select both: $(cat "$work/out")"
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
grep -q 'J1' "$work/out" || fail "F: J1 not selected: $(cat "$work/out")"
grep -q 'J2' "$work/out" && fail "F: J2 selected too: $(cat "$work/out")"

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

# The selected journey tests run through commands.e2e under the e2e lock (#796). The stub logs its arguments and the slot, and
# its mode file says whether it passes, fails once (flaky) or always fails.
export XDG_RUNTIME_DIR="$work/runtime" SENIOR_MODE_LOCK_POLL=0.05
mkdir -p "$XDG_RUNTIME_DIR"
cat >"$work/e2e-stub.sh" <<STUB
#!/usr/bin/env bash
echo "args:\$* slot:\${SENIOR_MODE_E2E_SLOT:-}" >>"$work/e2e.log"
n=\$((\$(cat "$work/e2e.count" 2>/dev/null || echo 0) + 1))
echo "\$n" >"$work/e2e.count"
case \$(cat "$work/e2e.mode") in
  pass) exit 0 ;;
  flaky) [ "\$n" -ge 2 ] ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$work/e2e-stub.sh"
stub() { # <mode>: a fresh log and counter
  : >"$work/e2e.log"
  echo 0 >"$work/e2e.count"
  echo "$1" >"$work/e2e.mode"
}
e2e_config() { printf '{"checks":[{"name":"lint","run":"true"}]%s}\n' "${1:+,$1}" >"$repo/.claude/senior-mode.json"; }

git_ checkout -q main
mkdir -p "$repo/e2e" "$repo/docs/specs"
spec accepted "$journeys"
printf 'test("J1 buyer pays", () => {});\n' >"$repo/e2e/pay.spec.ts"
printf 'test("J2 buyer refunds", () => {});\n' >"$repo/e2e/refund.spec.ts"
e2e_config ""
commit "chore: spec, tests and config"
git_ checkout -q -B feat-j
echo '// more' >>"$repo/e2e/pay.spec.ts"
commit "test: pay"

# J: only J1 is selected (its test changed, the paths did not): the stub runs once with J1's file, under a slot.
e2e_config "\"commands\":{\"e2e\":\"$work/e2e-stub.sh {files}\"}"
stub pass
run journeys-check || fail "J: a passing journey fails: $(cat "$work/out")"
[ "$(wc -l <"$work/e2e.log")" -eq 1 ] || fail "J: the stub did not run once: $(cat "$work/e2e.log")"
grep -q '^args:e2e/pay.spec.ts slot:[0-9]' "$work/e2e.log" || fail "J: not J1's file only, under the lock: $(cat "$work/e2e.log")"
grep -q 'refund' "$work/e2e.log" && fail "J: J2's file ran"

# K: no {files} in the command: the whole suite runs once.
e2e_config "\"commands\":{\"e2e\":\"$work/e2e-stub.sh --all\"}"
stub pass
run journeys-check || fail "K: fails: $(cat "$work/out")"
[ "$(wc -l <"$work/e2e.log")" -eq 1 ] || fail "K: the suite did not run once: $(cat "$work/e2e.log")"
grep -q '^args:--all ' "$work/e2e.log" || fail "K: the suite ran with other arguments: $(cat "$work/e2e.log")"

# L: a test that fails once and passes on rerun: check passes and its summary says flaky: J1.
e2e_config "\"commands\":{\"e2e\":\"$work/e2e-stub.sh {files}\"}"
stub flaky
run check || fail "L: a flaky journey fails the check: $(cat "$work/out")"
tail -n 1 "$work/out" | grep -q 'flaky: J1' || fail "L: no flaky: J1 in the summary: $(cat "$work/out")"
[ "$(wc -l <"$work/e2e.log")" -eq 2 ] || fail "L: not run twice: $(cat "$work/e2e.log")"

# M: a test that fails twice fails the check and names J1.
stub fail
run check && fail "M: a journey that fails twice passes"
grep -q 'journey J1 failed: e2e/pay.spec.ts' "$work/out" || fail "M: J1 not named: $(cat "$work/out")"

# N: journeys selected and no e2e command.
e2e_config ""
stub pass
run journeys-check && fail "N: no e2e command passes"
grep -qx 'journeys declared and no e2e command: senior-mode setup repo --command e2e=...' "$work/out" || fail "N: message: $(cat "$work/out")"

# O: no journey selected: the e2e command does not run.
git_ checkout -q main && git_ checkout -q -B feat-o
echo 5 >"$repo/README.md"
commit "docs: readme"
e2e_config "\"commands\":{\"e2e\":\"$work/e2e-stub.sh {files}\"}"
stub pass
run journeys-check || fail "O: fails: $(cat "$work/out")"
[ ! -s "$work/e2e.log" ] || fail "O: the e2e command ran with no journey selected: $(cat "$work/e2e.log")"

# shellcheck disable=SC2016 # the harness is a script written out, not expanded here
# Q: what `status` and `retro` say (#798). A harness loads the modules of the CLI and calls a function in the repository.
{
  echo 'eval "$(sed -e "s|^SELF=.*|SELF='"$cli"'|" -e "/^case /,\$d" "'"$cli"'")"'
  echo 'jq_text() { jq -r "$STATUS_TEXT_DEF$STATUS_SECTION_JOURNEYS_TEXT_JQ"; }'
  echo 'retro_text() { jq -r "$RETRO_JOURNEYS_TEXT_JQ"; }'
  echo '"$@"'
} >"$work/harness.sh"
h() { (cd "$repo" && bash "$work/harness.sh" "$@"); }
text() { h jq_text <<<"$1"; }

git_ checkout -q main
mkdir -p "$repo/src"
[ "$(h status_section_journeys_json "" '{}' "$repo" 0 | jq -c '.journeys | [.declared, .withTest, (.missingTests | length), (.noPaths | length), (.orphans | length)]')" = '[2,2,0,2,0]' ] ||
  fail "Q: the clean state of the journeys, with paths matching no file: $(h status_section_journeys_json "" '{}' "$repo" 0)"
text "$(h status_section_journeys_json "" '{}' "$repo" 0)" | grep -qx '  journey J1 of spec 328: the paths of the spec match no file' || fail "Q: no-path journey not listed in the text"
echo 1 >"$repo/src/app.ts"
commit "feat: app"
[ "$(h status_section_journeys_json "" '{}' "$repo" 0 | jq -c '.journeys.noPaths')" = '[]' ] || fail "Q: noPaths with a file under the paths"
text "$(h status_section_journeys_json "" '{}' "$repo" 0)" | grep -q . && fail "Q: a clean state prints lines"

# A journey whose test file is not on the base branch; a test title with an id no spec declares.
git_ rm -q e2e/refund.spec.ts
printf 'test("J9 an undeclared journey", () => {});\ntest("a plain test", () => {});\n' >"$repo/e2e/other.spec.ts"
commit "test: drop refund, add other"
out=$(h status_section_journeys_json "" '{}' "$repo" 0)
[ "$(jq -c '.journeys.missingTests' <<<"$out")" = '[{"spec":"328","id":"J2","test":"e2e/refund.spec.ts"}]' ] || fail "Q: missing test not listed: $out"
[ "$(jq -c '.journeys.orphans' <<<"$out")" = '[{"id":"J9","file":"e2e/other.spec.ts"}]' ] || fail "Q: orphan not listed: $out"
text "$out" | grep -qx '  journey J2 of spec 328: no test at e2e/refund.spec.ts' || fail "Q: missing test not in the text: $(text "$out")"
text "$out" | grep -q 'warning: a test title of e2e/other.spec.ts carries journey J9, which no spec declares' || fail "Q: orphan not in the text: $(text "$out")"

# retro: the counts, with the flaky runs `check` recorded (case L) in the period.
grep -q '"journey":"J1"' "$repo/.git/senior-mode/journeys-flaky.jsonl" || fail "Q: the flaky run was not recorded"
r=$(h retro_journeys '{"done":[]}' "$repo/.git" 1970-01-01T00:00:00Z "")
[ "$(jq -c '.journeys' <<<"$r")" = '{"declared":2,"withTest":1,"flaky":1}' ] || fail "Q: retro counts: $r"
[ "$(h retro_journeys '{}' "$repo/.git" 2999-01-01T00:00:00Z "" | jq -c '.journeys.flaky')" = 0 ] || fail "Q: a flaky run outside the period counted"
[ "$(h retro_text <<<"$r")" = 'Journeys: 2 declared, 1 with a test, 1 flaky in the period' ] || fail "Q: retro text"

# A project with no spec and no journey reports nothing.
plain="$work/plain"
git init -q -b main "$plain"
mkdir -p "$plain/e2e" "$plain/.claude"
echo '{"checks":[]}' >"$plain/.claude/senior-mode.json"
printf 'test("J9 anything", () => {});\n' >"$plain/e2e/a.spec.ts"
git -C "$plain" add -A && git -C "$plain" -c user.name=t -c user.email=t@t commit -q -m "chore: base"
[ "$(cd "$plain" && bash "$work/harness.sh" status_section_journeys_json "" '{}' "$plain" 0)" = '{}' ] || fail "Q: a project with no journey has a journeys section"
[ "$(cd "$plain" && bash "$work/harness.sh" retro_journeys '{"done":[]}' "$plain/.git" 1970-01-01T00:00:00Z "")" = '{"done":[]}' ] || fail "Q: retro reports journeys for a project with none"

# The spec template shows the front matter.
grep -q '^journeys:$' "$(dirname "$cli")/../skills/spec/template.md" || fail "I: the spec template has no journeys front matter"

[ "$failures" -eq 0 ] && echo "ok: journeys tests passed" || exit 1
