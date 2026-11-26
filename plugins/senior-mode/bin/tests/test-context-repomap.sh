#!/usr/bin/env bash
# Tests for the repo map of `senior-mode context` (#362). Offline: gh is a stub answering from $GH_ISSUE and $GH_PATHS;
# ctags is a stub too (the real one is not needed, and a real one must not leak into the fallback cases).
set -u
cli=$(cd "$(dirname "$0")/.." && pwd)/senior-mode
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

mkdir -p "$work/stub" "$work/ctags"
cat >"$work/stub/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"issue view"*) printf '%s\n' "$GH_ISSUE" ;;
  *"pr list"*) echo '[]' ;;
  *"api graphql"*) printf '%s\n' "$GH_PATHS" ;;
esac
STUB
# Without a usable ctags: one that fails (a machine with a real one must still take the fallback).
cat >"$work/stub/ctags" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
# With ctags: Universal Ctags answers --version and prints the tags of its own choice.
cat >"$work/ctags/ctags" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *--version*) echo "Universal Ctags 6.1.0, Copyright (C) 2015-2023 Universal Ctags Team"; exit 0 ;;
esac
echo "ctags $*" >>"$CTAGS_LOG"
cat >/dev/null
printf 'CtagsOnly\tsrc/util/crypto.ts\t/^export function CtagsOnly(x: number): void {$/;"\tf\tline:3\tsignature:(x: number)\n'
printf 'inner\tsrc/util/crypto.ts\t/^  const inner = 1;$/;"\tv\tline:4\tfunction:CtagsOnly\n'
STUB
chmod +x "$work/stub/gh" "$work/stub/ctags" "$work/ctags/ctags"
export PATH="$work/stub:$PATH" CTAGS_LOG="$work/ctags.log"
export GH_ISSUE='{"number":12,"title":"Let people log in","state":"OPEN","projectItems":[{"status":{"name":"In progress"}}],"body":"## Acceptance criteria\n- Given a user, when they log in, then they see their dashboard."}'
paths() { # globs -> $GH_PATHS, the board field Paths of the ticket
  GH_PATHS=$(jq -nc --arg t "$1" '{data: {repository: {issue: {projectItems: {nodes: [{project: {id: "P"}, fieldValueByName: {text: $t}}]}}}}}')
  export GH_PATHS
}

repo="$work/repo"
git init -q -b main "$repo"
mkdir -p "$repo/.claude" "$repo/src/auth/deep" "$repo/src/util" "$repo/src/other" "$repo/poly/py" "$repo/poly/go" "$repo/poly/rs/src" "$repo/poly/sh"
echo '{"project":{"id":"P"}}' >"$repo/.claude/senior-mode.json"
cat >"$repo/src/auth/login.ts" <<'F'
import { hash } from '../util/crypto';
import { notThere } from '../util/missing';

export function login(user: string): Session {
  const inner = hash(user);
  return new Session(inner);
}

export class Session {
  start(): void {}
}

export const LIMIT = 3;
F
printf 'export function plainA(): void {\n}\n' >"$repo/src/auth/a.ts"
printf 'export function plainDeep(): void {\n}\n' >"$repo/src/auth/deep/d.ts"
cat >"$repo/src/util/crypto.ts" <<'F'
export function hash(s: string): string {
  return s;
}
export function unused(): void {}
F
printf "import { hash } from '../util/crypto';\nimport { login } from '../auth/login';\nhash(login('a'));\n" >"$repo/src/other/a.ts"
printf "import { hash } from '../util/crypto.js';\nhash('b');\n" >"$repo/src/other/b.ts"
printf "const x = require('../util/crypto');\nx.hash('c');\n" >"$repo/src/other/c.ts"
printf 'export function ignored(): void {}\n' >"$repo/src/util/skipped.md"
cat >"$repo/poly/py/app.py" <<'F'
from .helpers import helper_fn


async def serve(port):
    return helper_fn(port)


class Handler:
    def method(self):
        pass


def _private():
    pass
F
printf 'def helper_fn(x):\n    return x\n' >"$repo/poly/py/helpers.py"
cat >"$repo/poly/go/main.go" <<'F'
package main

import (
	"fmt"
	"example.com/proj/poly/go/util"
)

type Server struct {
	port int
}

func (s *Server) Start() error {
	return util.Check(fmt.Sprint(s.port))
}

func Run(addr string) error {
	return nil
}
F
mkdir -p "$repo/poly/go/util"
printf 'package util\n\nfunc Check(s string) error {\n\treturn nil\n}\n' >"$repo/poly/go/util/check.go"
printf 'mod engine;\n\npub struct Config {\n    pub n: u32,\n}\n\npub async fn boot(c: Config) -> u32 {\n    engine::spin(c.n)\n}\n\nimpl Config {\n    fn hidden(&self) {}\n}\n' >"$repo/poly/rs/src/lib.rs"
printf 'pub fn spin(n: u32) -> u32 {\n    n\n}\n' >"$repo/poly/rs/src/engine.rs"
cat >"$repo/poly/sh/run.sh" <<'F'
#!/usr/bin/env bash
# shellcheck source=lib/tools.sh
. "$LIB/tools.sh"

run_all() {
  tool_one
}
function build_it {
  :
}
F
mkdir -p "$repo/poly/sh/lib"
printf 'tool_one() {\n  :\n}\n' >"$repo/poly/sh/lib/tools.sh"
git -C "$repo" add -A
git -C "$repo" -c user.name=t -c user.email=t@t commit -q -m "chore: sources"
git -C "$repo" remote add origin https://github.com/o/r.git
git -C "$repo" switch -q -c feat/12-login

context() { # dir -> $out, $map (the Repo map section lines)
  (cd "$1" && "$cli" context) >"$work/out" 2>"$work/err" || fail "context exited non-zero in $1: $(cat "$work/err")"
  out=$(cat "$work/out")
  map=$(awk '/^Repo map/ { on = 1; next } on && /^- / { print; next } on { exit }' <<<"$out")
}
want_in() { grep -qF -- "$1" <<<"$map" || fail "$2: missing '$1' in: $map"; }
not_in() { grep -qF -- "$1" <<<"$map" && fail "$2: '$1' should not be in: $map"; }

# The Paths' files and what they import; most referenced first, then the more specific Paths overlap.
paths 'src/auth/**, src/auth/deep/**'
context "$repo"
grep -q '^Repo map' <<<"$out" || fail "no Repo map section: $out"
want_in "- src/util/crypto.ts: export function hash(s: string): string" "imported file"
want_in "- src/auth/login.ts: export function login(user: string): Session" "signature of a Paths file"
want_in "- src/auth/login.ts: export class Session" "a class"
want_in "- src/auth/login.ts: export const LIMIT = 3;" "a constant"
want_in "- src/util/crypto.ts: export function unused(): void {}" "a one-line body keeps its text"
not_in "start()" "a method is not top level"
not_in "inner" "a local is not top level"
not_in "ignored" "an unrelated language file"
not_in "src/other/" "a file that only references the Paths"
[ "$(head -n 1 <<<"$map")" = "- src/util/crypto.ts: export function hash(s: string): string" ] || fail "hash (3 referencing files) is not first: $map"
[ "$(sed -n 2p <<<"$map")" = "- src/auth/login.ts: export function login(user: string): Session" ] || fail "login (1 referencing file) is not second: $map"
# Equal references: the deeper Paths overlap first, a file of the Paths before an imported one.
deep=$(grep -nF "plainDeep" <<<"$map" | cut -d: -f1) a=$(grep -nF "plainA" <<<"$map" | cut -d: -f1) un=$(grep -nF "unused" <<<"$map" | cut -d: -f1)
[ -n "$deep" ] && [ -n "$a" ] && [ "$deep" -lt "$a" ] || fail "the more specific overlap does not win: $map"
[ "$a" -lt "$un" ] || fail "a Paths file does not beat an imported one: $map"
# Where it sits: after the ADRs and notes, before the ticket, inside the budget.
[ "$(grep -n '^Repo map' <<<"$out" | cut -d: -f1)" -lt "$(grep -n '^Current ticket' <<<"$out" | cut -d: -f1)" ] || fail "the Repo map is not before the ticket: $out"
first=$out
context "$repo"
[ "$out" = "$first" ] || fail "two runs differ"

# The cache: one file named after the tree, read instead of parsing again.
tree=$(git -C "$repo" rev-parse 'HEAD^{tree}')
cache=$repo/.git/senior-mode/repomap/$tree
[ -f "$cache" ] || fail "no cache at $cache"
printf 'S\tsrc/auth/login.ts\t99\tfromCache\texport function fromCache(): void\n' >>"$cache"
context "$repo"
want_in "fromCache" "second run on the same tree reads the cache"
git -C "$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "chore: same tree"
context "$repo"
want_in "fromCache" "an empty commit keeps the tree sha, so the cache"
echo '// new' >>"$repo/src/auth/a.ts"
git -C "$repo" -c user.name=t -c user.email=t@t commit -q -am "chore: new tree"
context "$repo"
not_in "fromCache" "a changed tree is parsed again"
[ "$(find "$repo/.git/senior-mode/repomap" -type f | wc -l)" -eq 2 ] || fail "one cache file per tree: $(ls "$repo/.git/senior-mode/repomap")"

# The bound: context.repoMapTokens (default 400) bytes / 4, header included, and it stays inside context.budget.
bytes() { awk '/^Repo map/ { on = 1 } on && /^$/ { exit } on' <<<"$out" | wc -c; }
context "$repo"
[ "$(bytes)" -le 1600 ] || fail "over the default 400 tokens: $(bytes)"
echo '{"project":{"id":"P"},"context":{"repoMapTokens":45}}' >"$repo/.claude/senior-mode.json"
context "$repo"
[ "$(bytes)" -le 180 ] || fail "over repoMapTokens=45: $(bytes) bytes: $out"
[ "$(wc -l <<<"$map")" -ge 1 ] && [ "$(wc -l <<<"$map")" -lt 4 ] || fail "repoMapTokens=45 keeps too many or no lines: $map"
want_in "src/util/crypto.ts: export function hash" "the best ranked symbol survives the cut"
grep -q 'to fit context.budget' <<<"$out" && fail "the repoMapTokens cut is not a context.budget omission: $out"
echo '{"project":{"id":"P"},"context":{"repoMapTokens":"x"}}' >"$repo/.claude/senior-mode.json"
context "$repo"
want_in "src/auth/login.ts" "an invalid repoMapTokens falls back to 400"
echo '{"project":{"id":"P"}}' >"$repo/.claude/senior-mode.json"
context "$repo"
full=$(wc -c <<<"$out")
echo "{\"project\":{\"id\":\"P\"},\"context\":{\"budget\":$(((full - 90) / 4))}}" >"$repo/.claude/senior-mode.json"
context "$repo"
[ "$(wc -c <<<"$out")" -le "$(((full - 90) / 4 * 4))" ] || fail "the briefing is over context.budget: $(wc -c <<<"$out") bytes: $out"
tail -n 1 <<<"$out" | grep -Eq '^[0-9]+ items? omitted .*the scout agent has the rest\.$' || fail "no omission line under a short budget: $out"
grep -qF "Given a user, when they log in" <<<"$out" || fail "the ticket was dropped: $out"
want_in "src/util/crypto.ts: export function hash" "the best ranked symbol is the last one cut"
echo '{"project":{"id":"P"}}' >"$repo/.claude/senior-mode.json"

# No Paths, no map.
paths ''
context "$repo"
grep -q '^Repo map' <<<"$out" && fail "a Repo map with no Paths: $out"

# The languages of the presets, without ctags.
paths 'poly/**'
context "$repo"
for w in "- poly/py/app.py: async def serve(port)" "- poly/py/app.py: class Handler" "- poly/py/helpers.py: def helper_fn(x)" \
  "- poly/go/main.go: func Run(addr string) error" "- poly/go/main.go: func (s *Server) Start() error" "- poly/go/main.go: type Server struct" \
  "- poly/go/util/check.go: func Check(s string) error" "- poly/rs/src/lib.rs: pub async fn boot(c: Config) -> u32" "- poly/rs/src/lib.rs: pub struct Config" \
  "- poly/rs/src/engine.rs: pub fn spin(n: u32) -> u32" "- poly/sh/run.sh: run_all()" "- poly/sh/run.sh: function build_it" "- poly/sh/lib/tools.sh: tool_one()"; do
  want_in "$w" "fallback"
done
not_in "_private" "a private Python name"
not_in "hidden" "a method of an impl block"
# What a Paths file imports comes first when referenced: helper_fn, spin, Check, tool_one each have one referencing file.
paths 'poly/py/app.py'
context "$repo"
want_in "- poly/py/helpers.py: def helper_fn(x)" "a relative Python import"
paths 'poly/go/main.go'
context "$repo"
want_in "- poly/go/util/check.go: func Check(s string) error" "a Go import resolved to a directory of the repository"
paths 'poly/rs/src/lib.rs'
context "$repo"
want_in "- poly/rs/src/engine.rs: pub fn spin" "a Rust mod"
paths 'poly/sh/run.sh'
context "$repo"
want_in "- poly/sh/lib/tools.sh: tool_one()" "a sourced bash file"
paths 'src/other/a.ts'
context "$repo"
want_in "- src/util/crypto.ts: export function hash" "a TypeScript import"
want_in "- src/auth/login.ts: export function login" "a second TypeScript import"
paths 'src/other/b.ts'
context "$repo"
want_in "- src/util/crypto.ts: export function hash" "an import written with .js resolves to the .ts file"
paths 'src/other/c.ts'
context "$repo"
want_in "- src/util/crypto.ts: export function hash" "a require"

# With ctags (Universal): its tags, top level only; a new tree so the cache is not read.
paths 'src/util/**'
: >"$CTAGS_LOG"
git -C "$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "chore: no change"
echo '// ctags' >>"$repo/src/util/crypto.ts"
git -C "$repo" -c user.name=t -c user.email=t@t commit -q -am "chore: crypto"
PATH="$work/ctags:$PATH" context "$repo"
[ -s "$CTAGS_LOG" ] || fail "ctags was not used"
want_in "- src/util/crypto.ts: export function CtagsOnly(x: number): void" "a ctags symbol and its signature"
not_in "inner" "a ctags symbol with a scope is not top level"
not_in "hash" "the regex fallback is not mixed with ctags"
first=$out
PATH="$work/ctags:$PATH" context "$repo"
[ "$out" = "$first" ] || fail "ctags: two runs differ"
[ "$(wc -l <"$CTAGS_LOG")" -eq 1 ] || fail "ctags ran again on an unchanged tree: $(cat "$CTAGS_LOG")"

[ "$failures" -eq 0 ] && echo "context repomap: all cases pass"
exit "$failures"
