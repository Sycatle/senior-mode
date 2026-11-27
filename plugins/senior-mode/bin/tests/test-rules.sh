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

# jscpd stubbed (the common pack runs it) by a script that prints its JSON report.
mkdir -p "$work/jbin"
cat >"$work/jbin/jscpd" <<'SH'
#!/usr/bin/env bash
cat "$JSCPD_REPORT"
SH
chmod +x "$work/jbin/jscpd"
export JSCPD_REPORT=$work/jscpd.json
# clone <file> <start> <end> <file> <start> <end>...: a report of the pairs given three numbers by two.
clone() {
  local items=()
  while [ $# -ge 6 ]; do
    items+=("$(jq -nc --arg a "$1" --argjson as "$2" --argjson ae "$3" --arg b "$4" --argjson bs "$5" --argjson be "$6" \
      '{format: "typescript", lines: 12, firstFile: {name: $a, start: $as, end: $ae}, secondFile: {name: $b, start: $bs, end: $be}}')")
    shift 6
  done
  printf '%s\n' "${items[@]}" | jq -sc '{duplicates: .}' >"$JSCPD_REPORT"
}
echo '{"duplicates": []}' >"$JSCPD_REPORT"
export PATH=$work/jbin:$PATH

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
mkdir -p "$repo/src/settings"
mv "$repo/src/config/env.ts" "$repo/src/settings/env.ts"
run rules-check || fail "a file under rules.envModule fails: $(out)"

# Duplication and the rule of three (#736, spec 471 §4): the stub of jscpd is set up above.
dup() { # <config extras>: a 12-line new file src/b.ts, the duplication pack on
  put node src/b.ts "$(seq 1 12 | sed 's/^/const v/; s/$/ = 1;/')"
  config '{"audit": false, "preset": "node", "checks": [{"name": "lint", "run": "true"}], "rules": {"packs": ["common", "node", "duplication"]'"${1:+, $1}"'}}'
}
mkdir -p "$repo/src/lib" && git -C "$repo" checkout -q main
seq 1 12 | sed 's/^/const w/; s/$/ = 1;/' >"$repo/src/a.ts"
seq 1 12 | sed 's/^/const w/; s/$/ = 1;/' >"$repo/src/c.ts"
g add -A && g commit -q -m "chore: two old files"
dup ""
clone src/a.ts 1 12 src/b.ts 1 12
run rules-check || fail "a second copy fails: $(out)"
has "warning: src/b.ts:1: duplication: 2nd copy of src/a.ts:1" "second copy warns"

dup '"shared": ["src/lib/**"]'
clone src/a.ts 1 12 src/b.ts 1 12 src/c.ts 1 12 src/b.ts 1 12 src/a.ts 1 12 src/c.ts 1 12
run rules-check && fail "a third copy passes"
has "src/b.ts:1: duplication: copy of a block already at src/a.ts:1 and src/c.ts:1; extract it into src/lib" "third copy fails naming both places and the shared folder"

dup ""
clone src/a.ts 1 12 src/c.ts 1 12
run rules-check || fail "a duplicate that existed before the diff fails: $(out)"
lacks "duplication" "an old duplicate is not reported"

dup ""
clone src/b.ts 1 6 src/b.ts 7 12
run rules-check || fail "a clone inside the new file alone fails: $(out)"

# Not installed: tool missing with the install command and the rules.off key.
dup ""
PATH=/usr/bin:/bin run rules-check && fail "a missing jscpd passes"
has "tool missing: jscpd" "missing tool"
has "npm install -g jscpd" "install command"
has "rules.off.duplication" "off key"

# Dead code, unused dependencies (#741) and import cycles (#742, spec 471 §4): the tools are stubbed by scripts that print
# the report set with `rep <tool> <content>`.
for t in knip vulture deptry staticcheck go cargo cargo-udeps depcruise lint-imports; do
  cat >"$work/jbin/$t" <<'SH'
#!/usr/bin/env bash
name=$(basename "$0")
case "$name $*" in
  "cargo "*udeps*) name=cargo-udeps ;;
  "deptry "*) args=$*; cat "$(dirname "$0")/../rep-deptry" >"${args#*--json-output }"; exit 0 ;;
esac
cat "$(dirname "$0")/../rep-$name"
SH
  chmod +x "$work/jbin/$t"
done
rep() { printf '%s\n' "$2" >"$work/rep-$1"; }
# pack <preset> <pack>...: the packs of the project, the shipped ones.
pack() {
  local p=$1 packs
  shift
  packs=$(printf '"%s",' "$@")
  config '{"audit": false, "preset": "'"$p"'", "checks": [{"name": "lint", "run": "true"}], "rules": {"packs": ['"${packs%,}"']}}'
}
g checkout -q main
printf 'export function old() {}\n' >"$repo/src/old.ts"
printf '{\n  "dependencies": {\n    "left-pad": "1"\n  }\n}\n' >"$repo/package.json"
printf 'import { p } from "./p";\nexport const q = 1;\n' >"$repo/src/q.ts"
printf 'import { q } from "./q";\nexport const p = 1;\n' >"$repo/src/p.ts"
printf 'export const d1 = 1;\n' >"$repo/src/d1.ts"
printf 'import { d1 } from "./d1";\nexport const c1 = 1;\n' >"$repo/src/c1.ts"
printf 'dependencies = [\n  "requests",\n]\n' >"$repo/pyproject.toml"
printf 'module m\n\ngo 1.23\n\nrequire github.com/old/dep v1.0.0\n' >"$repo/go.mod"
printf '[dependencies]\nserde = "1"\n' >"$repo/Cargo.toml"
mkdir -p "$repo/pkg"
: >"$repo/pkg/__init__.py"
printf 'from pkg import a\n' >"$repo/pkg/b.py"
printf 'x = 1\n' >"$repo/pkg/a.py"
g add -A && g commit -q -m "chore: files for dead code and cycles"

# An exported function that the diff adds and nothing imports fails dead-code with file:line; one that existed passes.
reset
pack node dead-code
printf 'export function fresh() {}\n' >>"$repo/src/old.ts"
rep knip '{"files": [], "issues": [{"file": "src/old.ts", "exports": [{"name": "old", "line": 1}, {"name": "fresh", "line": 2}]}]}'
run rules-check && fail "a new unused export passes"
has "src/old.ts:2: dead-code: unused export fresh" "dead-code names file:line"
lacks "src/old.ts:1" "the old export is not reported"
reset
pack node dead-code
printf 'const z = 1;\n' >>"$repo/src/a.ts"
rep knip '{"files": [], "issues": [{"file": "src/old.ts", "exports": [{"name": "old", "line": 1}]}]}'
run rules-check || fail "an unused export that existed before fails: $(out)"
reset
pack node dead-code
printf 'export const lone = 1;\n' >"$repo/src/lone.ts"
rep knip '{"files": ["src/lone.ts"], "issues": []}'
run rules-check && fail "a new unused file passes"
has "src/lone.ts:1: dead-code: unused file" "an unused file"

# A dependency that the diff adds to the manifest and no file imports fails unused-dependency naming the package.
reset
pack node dead-code
sed -i 's/"left-pad": "1"/"left-pad": "1",\n    "lodash": "4"/' "$repo/package.json"
rep knip '{"issues": [{"file": "package.json", "dependencies": [{"name": "left-pad"}, {"name": "lodash"}]}]}'
run rules-check && fail "a new unused dependency passes"
has "package.json:4: unused-dependency: package lodash" "unused-dependency names the package"
lacks "package left-pad" "the old dependency is not reported"
reset
pack python dead-code
sed -i 's/"requests",/"requests",\n  "flask",/' "$repo/pyproject.toml"
rep deptry '[{"error": {"code": "DEP002"}, "module": "requests", "location": {"file": "pyproject.toml", "line": 2}}, {"error": {"code": "DEP002"}, "module": "flask", "location": {"file": "pyproject.toml", "line": 3}}]'
run rules-check && fail "a new unused python dependency passes"
has "pyproject.toml:3: unused-dependency: package flask" "deptry names the package"
lacks "package requests" "the old python dependency is not reported"
reset
pack go dead-code
sed -i 's|^require github.com/old/dep v1.0.0|&\nrequire github.com/x/y v1.2.3|' "$repo/go.mod"
rep go "$(printf -- '--- a/go.mod\n+++ b/go.mod\n@@ -3,5 +3,3 @@\n-\tgithub.com/old/dep v1.0.0\n-\tgithub.com/x/y v1.2.3\n')"
run rules-check && fail "a new unused go module passes"
has "go.mod:6: unused-dependency: module github.com/x/y" "go mod tidy names the module"
lacks "github.com/old/dep" "the old module is not reported"
reset
pack rust dead-code
printf 'rand = "0.8"\n' >>"$repo/Cargo.toml"
rep cargo-udeps '{"success": false, "unused_deps": {"m 0.1.0": {"manifest_path": "'"$repo"'/Cargo.toml", "normal": ["serde", "rand"], "development": [], "build": []}}}'
run rules-check && fail "a new unused crate passes"
has "Cargo.toml:3: unused-dependency: crate rand" "udeps names the crate"
lacks "crate serde" "the old crate is not reported"

# The other languages: vulture, staticcheck U1000 and the dead_code warning of cargo.
reset
pack python dead-code
printf 'x = 1\n\ndef fresh():\n    pass\n' >"$repo/app.py"
rep vulture "$(printf "./app.py:3: unused function 'fresh' (60%% confidence)\npkg/a.py:1: unused variable 'x' (60%% confidence)")"
run rules-check && fail "a new unused python function passes"
has "app.py:3: dead-code: unused function 'fresh'" "vulture"
lacks "pkg/a.py" "an old unused python name is not reported"
reset
pack go dead-code
printf 'package m\n\nfunc fresh() {}\n' >"$repo/a.go"
rep staticcheck '{"code": "U1000", "location": {"file": "'"$repo"'/a.go", "line": 3, "column": 6}, "message": "func fresh is unused"}'
run rules-check && fail "a new unused go func passes"
has "a.go:3: dead-code: func fresh is unused" "staticcheck U1000"
reset
pack rust dead-code
printf 'fn fresh() {}\n' >"$repo/lib.rs"
# shellcheck disable=SC2016 # cargo's own JSON, the backticks are literal
rep cargo '{"reason": "compiler-message", "message": {"message": "function `fresh` is never used", "code": {"code": "dead_code"}, "spans": [{"file_name": "lib.rs", "line_start": 1, "is_primary": true}]}}
{"reason": "build-finished", "success": true}'
run rules-check && fail "a new unused rust fn passes"
has "lib.rs:1: dead-code: function \`fresh\` is never used" "dead_code"

# A tool that is not installed fails with its name and the install command.
miss() { # <preset> <pack> <changed file> <tool> <install>
  reset
  pack "$1" "$2"
  printf '# x\n' >>"$repo/$3"
  PATH=/usr/bin:/bin run rules-check && fail "a missing $4 passes"
  has "tool missing: $4" "missing $4"
  has "$5" "install command of $4"
}
miss node dead-code src/old.ts knip "npm install -g knip"
miss python dead-code app.py vulture "pip install vulture"
miss python dead-code pyproject.toml deptry "pip install deptry"
miss go dead-code a.go staticcheck "go install honnef.co/go/tools/cmd/staticcheck@latest"
miss rust dead-code Cargo.toml cargo-udeps "cargo install cargo-udeps --locked"

[ "$failures" -eq 0 ] && echo "ok: rules" || exit 1
