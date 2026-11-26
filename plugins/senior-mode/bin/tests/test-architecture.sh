#!/usr/bin/env bash
# Tests for `senior-mode architecture` (#347, spec 325 §6.4): the generated map, its block in docs/architecture.md and
# the drift warning of `check`. Offline.
# shellcheck disable=SC2016 # backticks in the expected Markdown, not command substitutions
set -u
cli=$(cd "$(dirname "$0")/.." && pwd)/senior-mode
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

mkdir -p "$work/stub"
printf '#!/usr/bin/env bash\nexit 1\n' >"$work/stub/gh"
chmod +x "$work/stub/gh"
export PATH="$work/stub:$PATH"

repo="$work/repo"
git init -q "$repo"
git -C "$repo" remote add origin https://github.com/acme/app.git
mkdir -p "$repo/.claude" "$repo/src/api" "$repo/src/web/ui/deep" "$repo/docs/specs" "$repo/docs/adr" "$repo/docs/knowledge"
commit() {
  git -C "$repo" add -A
  git -C "$repo" -c user.name=t -c user.email=t@t commit -q -m "chore: $1" --allow-empty
}
config() { printf '%s\n' "$1" >"$repo/.claude/senior-mode.json"; }
run() { (cd "$repo" && "$cli" "$@") >"$work/out" 2>&1; }
cfg() { config "{\"audit\":false,\"checks\":[{\"name\":\"lint\",\"run\":\"true\"}],\"architecture\":{\"rules\":[$1]}}"; }
RULE1='{"id":"no-ui-in-api","forbidImport":{"from":"src/api/**","to":"src/web/**"},"why":"api stays headless"}'

printf '# API layer\n\nHandlers.\n' >"$repo/src/api/README.md"
echo x >"$repo/src/api/a.ts"
echo x >"$repo/src/web/w.ts"
echo x >"$repo/src/web/ui/u.ts"
echo x >"$repo/src/web/ui/deep/d.ts"
printf -- '---\nid: 10\ntitle: The web client renders the board\nstatus: accepted\npaths: ["src/web/**"]\n---\n\n# The web client\n' >"$repo/docs/specs/10-web.md"
printf -- '---\nid: 0001\ntitle: Use one queue\nstatus: accepted\n---\n\n## Context\n' >"$repo/docs/adr/0001-queue.md"
printf -- '---\npaths: ["src/**"]\nverified: 2026-11-01\norigin: retro\nkind: context\n---\nnote\n' >"$repo/docs/knowledge/a-note.md"
printf -- '---\npaths: ["src/**"]\nverified: 2026-11-01\norigin: retro\nkind: context\n---\nnote\n' >"$repo/docs/knowledge/b-note.md"
cfg "$RULE1"
commit base

# 1. Printed: depth 2, purposes, rules, ADR index, notes; deterministic.
run architecture || fail "architecture fails: $(cat "$work/out")"
cp "$work/out" "$work/first"
grep -qE '^<!-- senior-mode:architecture sha=[0-9a-f]+ -->$' "$work/out" || fail "opening marker with a hash missing: $(cat "$work/out")"
grep -q '^<!-- /senior-mode:architecture -->$' "$work/out" || fail "closing marker missing: $(cat "$work/out")"
grep -q '^- `src/api/`: API layer$' "$work/out" || fail "README first line not the purpose of src/api: $(cat "$work/out")"
grep -q '^- `src/web/`: The web client renders the board$' "$work/out" || fail "spec title not the purpose of src/web: $(cat "$work/out")"
grep -q '^- `src/`$' "$work/out" || fail "a directory with no purpose not listed bare: $(cat "$work/out")"
grep -q 'src/web/ui/' "$work/out" && fail "a directory of depth 3 listed: $(cat "$work/out")"
grep -q 'no-ui-in-api' "$work/out" || fail "rule not listed: $(cat "$work/out")"
grep -q 'api stays headless' "$work/out" || fail "rule reason not listed: $(cat "$work/out")"
grep -q '^- \[0001\](adr/0001-queue.md): Use one queue$' "$work/out" || fail "ADR not indexed: $(cat "$work/out")"
grep -q 'Knowledge notes: 2' "$work/out" || fail "notes not counted: $(cat "$work/out")"
run architecture
cmp -s "$work/out" "$work/first" || fail "the output is not deterministic"

# 2. --write replaces only the block; text outside is untouched; a file with no block gets one at its end.
printf '# Architecture\n\nMy overview.\n' >"$repo/docs/architecture.md"
commit doc
run architecture --write || fail "architecture --write fails: $(cat "$work/out")"
head -n 3 "$repo/docs/architecture.md" | cmp -s - <(printf '# Architecture\n\nMy overview.\n') || fail "text before the block changed: $(cat "$repo/docs/architecture.md")"
[ "$(grep -c 'senior-mode:architecture' "$repo/docs/architecture.md")" -eq 2 ] || fail "block not written once: $(cat "$repo/docs/architecture.md")"
sed -i 's/^My overview\.$/My overview, edited./' "$repo/docs/architecture.md"
printf '\n## Notes\nAfter the block.\n' >>"$repo/docs/architecture.md"
cp "$repo/docs/architecture.md" "$work/before"
run architecture --write || fail "second --write fails"
cmp -s "$repo/docs/architecture.md" "$work/before" || fail "--write on an up-to-date block changed the file"
mkdir -p "$repo/src/new"
echo x >"$repo/src/new/n.ts"
run architecture --write || fail "--write after a change fails"
grep -q 'src/new/' "$repo/docs/architecture.md" || fail "new directory not written"
grep -q '^My overview, edited\.$' "$repo/docs/architecture.md" || fail "text before the block lost"
grep -q '^After the block\.$' "$repo/docs/architecture.md" || fail "text after the block lost"
[ "$(grep -c 'senior-mode:architecture' "$repo/docs/architecture.md")" -eq 2 ] || fail "block duplicated"
commit written

# 3. check: current block, no warning; tree, rules or ADR list differ, warning; --write clears it.
run check || fail "check fails: $(cat "$work/out")"
grep -q 'out of date' "$work/out" && fail "warning with a current block: $(cat "$work/out")"
mkdir -p "$repo/lib2"
echo x >"$repo/lib2/l.ts"
commit tree
run check || fail "a drift fails check, it only warns: $(cat "$work/out")"
grep -q 'warning: architecture.md out of date' "$work/out" || fail "tree drift not warned: $(cat "$work/out")"
run architecture --write
commit sync
run check
grep -q 'out of date' "$work/out" && fail "still warned after --write: $(cat "$work/out")"
cfg "$RULE1,{\"id\":\"cap\",\"maxLines\":900,\"paths\":[\"src/**\"]}"
commit rules
run check
grep -q 'warning: architecture.md out of date' "$work/out" || fail "rules drift not warned: $(cat "$work/out")"
run architecture --write
commit sync2
printf -- '---\nid: 0002\ntitle: Drop the queue\nstatus: accepted\n---\n' >"$repo/docs/adr/0002-drop.md"
commit adr
run check
grep -q 'warning: architecture.md out of date' "$work/out" || fail "ADR drift not warned: $(cat "$work/out")"

# 4. No docs/architecture.md, or no block in it: no warning.
rm "$repo/docs/architecture.md"
commit gone
run check
grep -q 'out of date' "$work/out" && fail "warning with no docs/architecture.md: $(cat "$work/out")"
printf '# Architecture\n' >"$repo/docs/architecture.md"
commit plain
run check
grep -q 'out of date' "$work/out" && fail "warning with no block recorded: $(cat "$work/out")"

run architecture --bogus && fail "an unknown option is accepted"

[ "$failures" -eq 0 ] && echo "architecture: all cases pass"
exit "$failures"
