#!/usr/bin/env bash
# Tests for the performance rules of the `perf` pack (#757, spec 472): a database, HTTP or file call inside a loop, through
# `senior-mode rules-check` on git fixture repositories.
set -u
cli=$(cd "$(dirname "$0")/.." && pwd)/senior-mode
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0
# After the warning period of the shipped packs (since 2026-11-28, #872): their findings block, as these cases expect.
export SENIOR_MODE_NOW=1799971200

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }
g() { git -C "$repo" -c user.name=t -c user.email=t@t "$@"; }
run() { (cd "$repo" && "$cli" "$@") >"$work/out" 2>&1; }
out() { cat "$work/out"; }
has() { grep -qF -- "$1" "$work/out" || fail "$2: '$1' not in: $(out)"; }
# put <preset> <file> <content>: the file of the branch, alone in its diff, with the perf pack on.
put() {
  g reset -q --hard && g clean -fdq
  printf '{"audit": false, "preset": "%s", "checks": [{"name": "lint", "run": "true"}], "rules": {"packs": ["perf"]}}\n' "$1" >"$repo/.claude/senior-mode.json"
  mkdir -p "$repo/$(dirname "$2")"
  printf '%s\n' "$3" >"$repo/$2"
}
bad() { put "$1" "$2" "$3"; run rules-check && fail "$2: '$3' passes"; has "$2:$4: io-in-loop" "$2"; has "batch it or use a set-based query" "fix line"; }
good() { put "$1" "$2" "$3"; run rules-check || fail "$2: '$3' fails: $(out)"; }

repo=$work/repo
git init -q -b main "$repo"
mkdir -p "$repo/.claude"
echo '{}' >"$repo/.claude/senior-mode.json"
g add -A && g commit -q -m "chore: base"
g checkout -q -b feat

# A call in a loop body, in each preset language: for, while, forEach, map, a list comprehension.
bad node src/a.ts $'for (const id of ids) {\n  const u = await prisma.user.findUnique({ where: { id } });\n}' 2
bad node src/a.ts $'while (more) {\n  const r = await fetch(url);\n}' 2
bad node src/a.ts $'ids.forEach(async (id) => {\n  await db.query("select 1");\n});' 2
bad node src/a.ts $'const all = await Promise.all(ids.map((id) => db.user.findFirst({ where: { id } })));' 1
bad node src/a.ts $'for (const f of files) {\n  const s = fs.readFileSync(f);\n}' 2
bad python app/a.py $'for i in ids:\n    row = cursor.execute("select 1")' 2
bad python app/a.py $'rows = [session.get(User, i) for i in ids]' 1
bad go a.go $'for _, id := range ids {\n\trow := db.QueryRow("select 1")\n}' 2
bad rust src/lib.rs $'for id in ids {\n    let r = sqlx::query("select 1").fetch_one(&pool).await?;\n}' 2

# Outside a loop, or a loop that only computes in memory: nothing.
good node src/a.ts 'const u = await prisma.user.findUnique({ where: { id } });'
good node src/a.ts $'for (const id of ids) {\n  total += id * 2;\n}'
good node src/a.ts $'const rows = await db.query("select 1");\nfor (const r of rows) {\n  total += r.n;\n}'
good node src/a.ts $'for (const id of await db.ids()) {\n  total += id;\n}'
good node src/a.ts $'const doubled = ids.map((id) => id * 2);'
good python app/a.py $'row = cursor.execute("select 1")\nfor r in row:\n    total += r'
good go a.go $'row := db.QueryRow("select 1")\nfor i := 0; i < 3; i++ {\n\ttotal += i\n}'

# The suppression syntax of #471 on the call, or senior-mode: allow on the line above.
good node src/a.ts $'for (const id of ids) {\n  await db.query("select 1"); // -- #123: ids is at most 3\n}'
good node src/a.ts $'for (const id of ids) {\n  // senior-mode: allow io-in-loop -- #123: ids is at most 3\n  await db.query("select 1");\n}'

# A migration, a seed or a test is left alone.
body=$'for (const id of ids) {\n  await db.query("select 1");\n}'
good node db/migrations/001_users.ts "$body"
good node db/seeds/users.ts "$body"
good node src/a.test.ts "$body"

# The same loop on a line the diff did not add.
g reset -q --hard && g checkout -q main
mkdir -p "$repo/src"
printf '%s\n' $'for (const id of ids) {\n  await db.query("select 1");\n}' >"$repo/src/old.ts"
g add -A && g commit -q -m "chore: old code"
g checkout -q -b feat2
put node src/new.ts 'const n = 1;'
run rules-check || fail "an old loop fails: $(out)"

[ "$failures" -eq 0 ] && echo "ok: perf" || exit 1
