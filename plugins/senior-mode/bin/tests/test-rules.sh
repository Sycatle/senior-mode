#!/usr/bin/env bash
# Tests for the code rules engine (#720, spec 471 §1): `senior-mode rules-check` and the `code rules` step of `check`.
# Offline: git fixture repositories and fixture pack files (SENIOR_MODE_RULES_DIR).
set -u
cli=$(cd "$(dirname "$0")/.." && pwd)/senior-mode
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }
g() { git -C "$repo" -c user.name=t -c user.email=t@t "$@"; }
run() { (cd "$repo" && "$cli" "$@") >"$work/out" 2>&1; }
out() { cat "$work/out"; }
# config <json>: the project configuration, committed with the tree it describes.
config() { printf '%s\n' "$1" >"$repo/.claude/senior-mode.json"; }
reset() { g reset -q --hard && g clean -fdq && g checkout -q main && g branch -qD feat 2>/dev/null; g checkout -q -b feat; }
has() { grep -qF -- "$1" "$work/out" || fail "$2: '$1' not in: $(out)"; }
lacks() { ! grep -qF -- "$1" "$work/out" || fail "$2: '$1' in: $(out)"; }

export SENIOR_MODE_RULES_DIR=$work/rules
mkdir -p "$SENIOR_MODE_RULES_DIR"
cat >"$SENIOR_MODE_RULES_DIR/t.json" <<'JSON'
{ "rules": [
  { "id": "no-foo", "tier": 2, "kind": "pattern", "ext": ["ts"], "pattern": "foo\\(", "fix": "call bar" },
  { "id": "no-print", "tier": 2, "kind": "pattern", "prodOnly": true, "pattern": "console\\.log", "fix": "use the logger" }
] }
JSON
cat >"$SENIOR_MODE_RULES_DIR/tool.json" <<'JSON'
{ "rules": [
  { "id": "dup", "tier": 2, "kind": "tool", "run": "nosuchtool-xyz --report", "format": "jscpd", "install": "npm i -g nosuchtool-xyz", "fix": "extract it" }
] }
JSON

repo=$work/repo
git init -q -b main "$repo"
mkdir -p "$repo/.claude" "$repo/src"
printf 'const a = foo(1);\nconst b = 2;\n' >"$repo/src/a.ts"
printf 'console.log(1);\n' >"$repo/src/a.test.ts"
config '{"audit": false, "checks": [{"name": "lint", "run": "true"}], "rules": {"packs": ["t"]}}'
g add -A
g commit -q -m "chore: base"
g checkout -q -b feat

# A match on a line the diff did not add or change passes.
run rules-check || fail "an old match fails: $(out)"

# The same match on an added line fails with file:line rule-id: message (fix: ...).
printf 'const c = foo(2);\n' >>"$repo/src/a.ts"
run rules-check && fail "a match on an added line passes"
has "src/a.ts:3: no-foo: no-foo (fix: call bar)" "added line"
lacks "src/a.ts:1:" "an old line is not reported"

# A rule restricted to `ext` does not read another extension.
reset
printf 'foo(1)\n' >"$repo/src/b.js"
run rules-check || fail "an ext-restricted rule reads a .js file: $(out)"

# prodOnly: a match in a test file is not reported, in production code it is.
reset
printf 'console.log(2);\n' >>"$repo/src/a.test.ts"
run rules-check || fail "a prodOnly rule reports a test file: $(out)"
printf 'console.log(3);\n' >>"$repo/src/a.ts"
run rules-check && fail "a prodOnly rule passes in production code"
has "src/a.ts:3: no-print" "prodOnly in production"

# A pack entry without id, tier or fix, or with an unknown kind, is a configuration error naming the pack and the entry.
cp "$SENIOR_MODE_RULES_DIR/t.json" "$work/t.json.keep"
for bad in '{"tier": 2, "kind": "pattern", "pattern": "x", "fix": "f"}' '{"id": "r", "kind": "pattern", "pattern": "x", "fix": "f"}' \
  '{"id": "r", "tier": 2, "kind": "pattern", "pattern": "x"}' '{"id": "r", "tier": 2, "kind": "magic", "fix": "f"}'; do
  jq --argjson r "$bad" '.rules += [$r]' "$work/t.json.keep" >"$SENIOR_MODE_RULES_DIR/t.json"
  run rules-check && fail "a bad entry passes: $bad"
  has "configuration error" "bad entry $bad"
  has "pack t, entry 3" "bad entry $bad"
done
cp "$work/t.json.keep" "$SENIOR_MODE_RULES_DIR/t.json"

# rules.off without why is a configuration error; with why and paths the rule is skipped only under them, and `off` is printed.
reset
printf 'const c = foo(2);\n' >>"$repo/src/a.ts"
mkdir -p "$repo/src/legacy"
printf 'foo(1);\n' >"$repo/src/legacy/x.ts"
config '{"audit": false, "checks": [{"name": "lint", "run": "true"}], "rules": {"packs": ["t"], "off": {"no-foo": {"paths": ["src/legacy/**"]}}}}'
run rules-check && fail "rules.off without why passes"
has "rules.off.no-foo: why is missing" "off without why"
config '{"audit": false, "checks": [{"name": "lint", "run": "true"}], "rules": {"packs": ["t"], "off": {"no-foo": {"why": "legacy code", "paths": ["src/legacy/**"]}}}}'
run rules-check && fail "an off rule with paths skips the whole tree"
has "off  no-foo: legacy code" "off line"
has "src/a.ts:3: no-foo" "off under paths only: outside the paths"
lacks "src/legacy/x.ts" "off under paths only: inside the paths"
config '{"audit": false, "checks": [{"name": "lint", "run": "true"}], "rules": {"packs": ["t"], "off": {"no-foo": {"why": "not used here"}}}}'
run rules-check || fail "an off rule without paths still fails: $(out)"
has "off  no-foo: not used here" "off line without paths"

# A tool rule whose tool is not installed fails with the tool, the install command and the rules.off key.
reset
config '{"audit": false, "checks": [{"name": "lint", "run": "true"}], "rules": {"packs": ["tool"]}}'
printf 'const d = 1;\n' >>"$repo/src/a.ts"
run rules-check && fail "a missing tool passes"
has "tool missing: nosuchtool-xyz" "tool missing"
has "npm i -g nosuchtool-xyz" "install command"
has "rules.off.dup" "off key"

# No pack: skipped. The packs of the preset are read when rules.packs is empty.
config '{"audit": false, "checks": [{"name": "lint", "run": "true"}]}'
run rules-check || fail "no pack fails: $(out)"
has "skipped: no rule packs" "no pack"

# `check` runs the step and fails with the finding.
reset
config '{"audit": false, "checks": [{"name": "lint", "run": "true"}], "rules": {"packs": ["t"]}}'
printf 'const c = foo(2);\n' >>"$repo/src/a.ts"
g add -A
run check && fail "check passes with a rule finding"
has "FAIL  code rules" "check step"
has "src/a.ts:3 code rules" "check finding line"

# Suppressions (#722, spec 471 §2): the `suppression` entry of the common pack, with a gh stub for the issues.
mkdir -p "$work/bin"
cat >"$work/bin/gh" <<'SH'
#!/usr/bin/env bash
# gh issue view <n> --json number: #123 exists, #999 does not, anything else cannot be reached.
[ "$STUB_GH" != down ] || { echo "error connecting to api.github.com" >&2; exit 1; }
case $3 in
  123) echo '{"number":123}' ;;
  999) echo "GraphQL: Could not resolve to an Issue with the number of 999. (repository.issue)" >&2; exit 1 ;;
  *) echo "error connecting to api.github.com" >&2; exit 1 ;;
esac
SH
chmod +x "$work/bin/gh"
export PATH=$work/bin:$PATH
real_rules=$(cd "$(dirname "$0")/.." && pwd)/../rules
cp "$real_rules/common.json" "$SENIOR_MODE_RULES_DIR/common.json"
cat >"$SENIOR_MODE_RULES_DIR/dp.json" <<'JSON'
{ "rules": [ { "id": "debug-print", "tier": 2, "kind": "pattern", "pattern": "console\\.log", "fix": "use the logger" } ] }
JSON
sup() { reset; config '{"audit": false, "checks": [{"name": "lint", "run": "true"}], "rules": {"packs": ["common", "dp"]}}'; printf '%s\n' "$@" >>"$repo/src/a.ts"; }

sup '// eslint-disable-next-line no-explicit-any'
run rules-check && fail "a suppression with no reference passes"
has "src/a.ts:3: suppression" "no reference"

sup '// eslint-disable-next-line no-explicit-any -- #123: SDK types are wrong'
run rules-check || fail "a suppression with #123 on its line fails: $(out)"
sup '// -- #123: the SDK types are wrong' '// eslint-disable-next-line no-explicit-any'
run rules-check || fail "a suppression with #123 on the line above fails: $(out)"

sup '// eslint-disable-next-line no-explicit-any -- #999: gone'
run rules-check && fail "a suppression naming a missing issue passes"
has "suppression: #999 not found" "missing issue"

sup '// eslint-disable-next-line no-explicit-any -- #123: SDK types are wrong'
STUB_GH=down run rules-check || fail "an unreachable gh fails the format: $(out)"
has "suppression: #123 not verified" "gh down"

sup 'describe.only("a", () => {});  // -- #123: debugging'
run rules-check && fail "a .only passes with a comment"
has "src/a.ts:3: suppression" ".only"

sup '// senior-mode: allow debug-print -- #123: progress bar' 'console.log("50%");'
run rules-check || fail "an allowed debug-print fails: $(out)"
has "src/a.ts:4: debug-print lifted by senior-mode: allow (#123: progress bar)" "lifted finding"
sup '// senior-mode: allow debug-print' 'console.log("50%");'
run rules-check && fail "an allow with no reference passes"
has "src/a.ts:3: suppression" "allow without reference"
sup 'console.log("50%");' '// senior-mode: allow debug-print -- #123: progress bar'
run rules-check && fail "an allow lifts the line above"
has "src/a.ts:3: debug-print" "allow lifts the next line only"

# Detections of the language packs (#489, spec 471 §3), on the packs the plugin ships.
export SENIOR_MODE_RULES_DIR=$real_rules
lang() { config '{"audit": false, "preset": "'"$1"'", "checks": [{"name": "lint", "run": "true"}], "rules": {"packs": ["common", "'"$1"'"]}}'; }
# put <preset> <file> <content>: the file of the branch, alone in its diff.
put() { reset; lang "$1"; mkdir -p "$repo/$(dirname "$2")"; printf '%s\n' "$3" >"$repo/$2"; }
bad() { put "$1" "$2" "$3"; run rules-check && fail "$2: '$3' passes"; has "$2:1: $4" "$2 '$3'"; }
good() { put "$1" "$2" "$3"; run rules-check || fail "$2: '$3' fails: $(out)"; }

bad node src/a.ts '} catch (e) {}' swallowed-error
bad node src/a.ts 'p.catch(() => {});' swallowed-error
bad python app/a.py 'except: pass' swallowed-error
bad python app/a.py 'except Exception: pass' swallowed-error
bad go a.go '_ = err' swallowed-error
bad go a.go 'if err != nil {}' swallowed-error
bad rust src/lib.rs 'let _ = send(x);' swallowed-error
bad rust src/lib.rs 'tx.send(x).ok();' swallowed-error
good node src/a.ts '} catch (e) { log(e); }'
good rust src/lib.rs 'let v = tx.send(x).ok();'

bad node src/a.ts 'console.log(x);' debug-print
bad python app/a.py 'print(x)' debug-print
bad go a.go 'fmt.Println(x)' debug-print
bad rust src/lib.rs 'dbg!(x);' debug-print
good node src/a.test.ts 'console.log(x);'
good python app/test_a.py 'print(x)'
good go a_test.go 'fmt.Println(x)'
good rust tests/x.rs 'println!("x");'
good go a.go 'fmt.Fprintln(w, x)'

good node src/a.ts '// TODO(#42): split'
bad node src/a.ts '// TODO later' todo-without-issue
bad python app/a.py '# FIXME later' todo-without-issue
good python app/a.py 'TODOS = []'

# The same patterns on lines the diff did not add: nothing is reported.
reset
git -C "$repo" checkout -q main
printf '} catch (e) {}\nconsole.log(1);\n// TODO later\n' >"$repo/src/old.ts"
printf 'except: pass\nprint(1)\n' >"$repo/src/old.py"
g add -A && g commit -q -m "chore: old code"
reset
lang node
run rules-check || fail "old patterns fail: $(out)"
printf 'const k = 1;\n' >>"$repo/src/old.ts"
run rules-check || fail "a change next to old patterns fails: $(out)"

# commented-code, outbound-no-timeout and scattered-env (#490, spec 471 §3).
bad node src/a.ts $'// const x = 1;\n// return x;\n// }' commented-code
bad python app/a.py $'# x = compute()\n# return x' commented-code
bad go a.go $'// if err != nil {\n// return err' commented-code
bad rust src/lib.rs $'// let x = 1;\n// foo(x);' commented-code
good node src/a.ts $'/**\n * const x = 1;\n * return x;\n */'
good rust src/lib.rs $'/// let x = 1;\n/// foo(x);'
good node src/a.ts '// const x = 1;'
good node src/a.ts $'// the user is created here\n// then we send the mail'

bad node src/a.ts 'const r = await fetch(url);' outbound-no-timeout
good node src/a.ts 'const r = await fetch(url, { signal: AbortSignal.timeout(5000) });'
good node src/a.ts $'const r = await fetch(url, {\n  method: "POST",\n  signal: AbortSignal.timeout(5000),\n});'
bad node src/a.ts $'const r = await fetch(url, {\n  method: "POST",\n});' outbound-no-timeout
good node src/a.test.ts 'await fetch(url);'
bad python app/a.py 'r = requests.get(url)' outbound-no-timeout
good python app/a.py 'r = requests.get(url, timeout=5)'
bad go a.go 'resp, err := http.Get(url)' outbound-no-timeout
bad go a.go 'c := &http.Client{}' outbound-no-timeout
good go a.go 'c := &http.Client{Timeout: 5 * time.Second}'
bad rust src/lib.rs 'let r = reqwest::get(url).await?;' outbound-no-timeout

bad node src/billing/charge.ts 'const k = process.env.STRIPE_KEY;' scattered-env
has "rules.envModule" "scattered-env names the key"
good node src/config/env.ts 'export const k = process.env.STRIPE_KEY;'
good node vite.config.ts 'export default { base: process.env.BASE };'
good node src/billing/charge.test.ts 'const k = process.env.STRIPE_KEY;'
bad python app/a.py 'k = os.environ["KEY"]' scattered-env
good python app/settings.py 'k = os.environ["KEY"]'
bad go a.go 'k := os.Getenv("KEY")' scattered-env
bad rust src/lib.rs 'let k = std::env::var("KEY");' scattered-env
# rules.envModule replaces the preset's default globs.
put node src/config/env.ts 'export const k = process.env.STRIPE_KEY;'
config '{"audit": false, "preset": "node", "checks": [{"name": "lint", "run": "true"}], "rules": {"packs": ["common", "node"], "envModule": ["src/settings/**"]}}'
run rules-check && fail "a file outside rules.envModule passes"
has "src/config/env.ts:1: scattered-env" "envModule replaces the default"
mkdir -p "$repo/src/settings" && git -C "$repo" mv -f src/config/env.ts src/settings/env.ts 2>/dev/null || mv "$repo/src/config/env.ts" "$repo/src/settings/env.ts"
run rules-check || fail "a file under rules.envModule fails: $(out)"

[ "$failures" -eq 0 ] && echo "ok: rules" || exit 1
