#!/usr/bin/env bash
# Tests for the nextjs-supabase check that keeps the production Supabase project out of the
# worktree (supabase.prodProjectRef in .env* files and Supabase URL variables). Offline.
set -u
script=$(cd "$(dirname "$0")/../../presets/nextjs-supabase/scripts" && pwd)/supabase-prod-ref.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0
prod=abcdefghijklmnopqrst
dev=zyxwvutsrqponmlkjihg

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }
repo() { # name [config]: a git repository with the config key set, or without it
  local dir="$work/$1"
  git init -q -b main "$dir"
  mkdir -p "$dir/.claude"
  if [ $# -ge 2 ]; then printf '%s\n' "$2"; else printf '{"supabase":{"prodProjectRef":"%s"}}\n' "$prod"; fi \
    >"$dir/.claude/senior-mode.json"
  echo "$dir"
}
run() { (cd "$1" && shift && env "$@" "$script") >"$work/out" 2>&1; }
leaks() { grep -qE "$prod|secretvalue|supabase\.co" "$work/out"; }

# Key not set: nothing to compare with, skipped with a message.
d=$(repo unset '{}')
echo "NEXT_PUBLIC_SUPABASE_URL=https://$prod.supabase.co" >"$d/.env"
run "$d" || fail "fails without supabase.prodProjectRef: $(cat "$work/out")"
grep -q '^skipped: supabase.prodProjectRef' "$work/out" || fail "no skip message: $(cat "$work/out")"

# Clean worktree: dev project in env files and in the environment.
d=$(repo clean)
printf 'NEXT_PUBLIC_SUPABASE_URL=https://%s.supabase.co\nSUPABASE_SERVICE_ROLE_KEY=secretvalue\n' "$dev" >"$d/.env.local"
run "$d" SUPABASE_URL="https://$dev.supabase.co" || fail "fails on the dev project: $(cat "$work/out")"
leaks && fail "output shows a value: $(cat "$work/out")"

# An untracked, git-ignored .env.local naming the prod project fails; names only.
d=$(repo ignored)
echo '.env.local' >"$d/.gitignore"
printf 'FOO=1\nNEXT_PUBLIC_SUPABASE_URL=https://%s.supabase.co\nKEY=secretvalue\n' "$prod" >"$d/.env.local"
run "$d" && fail "passes with the prod ref in an ignored .env.local"
grep -q '\.env\.local.*NEXT_PUBLIC_SUPABASE_URL' "$work/out" || fail "file and variable not named: $(cat "$work/out")"
leaks && fail "output shows a value: $(cat "$work/out")"
grep -q 'FOO\|KEY' "$work/out" && fail "an unrelated variable is reported: $(cat "$work/out")"

# A tracked file, another variable, export and quotes; a nested app; node_modules is skipped.
d=$(repo tracked)
mkdir -p "$d/apps/web" "$d/node_modules/pkg"
printf 'export DATABASE_URL="postgres://postgres:secretvalue@db.%s.supabase.co:5432/postgres"\n' "$prod" >"$d/apps/web/.env.production"
printf 'SUPABASE_URL=https://%s.supabase.co\n' "$prod" >"$d/node_modules/pkg/.env"
git -C "$d" add -A
run "$d" && fail "passes with the prod ref in a tracked nested .env.production"
grep -q 'apps/web/\.env\.production.*DATABASE_URL' "$work/out" || fail "nested file or variable not named: $(cat "$work/out")"
grep -q node_modules "$work/out" && fail "node_modules scanned: $(cat "$work/out")"
leaks && fail "output shows a value: $(cat "$work/out")"

# A line that is not VAR=value (comment, bare URL) is reported by its number.
d=$(repo comment)
printf '# prod: https://%s.supabase.co\nOK=1\n' "$prod" >"$d/.env.example"
run "$d" && fail "passes with the prod ref in a comment"
grep -q '\.env\.example.*line 1' "$work/out" || fail "line number not given: $(cat "$work/out")"
leaks && fail "output shows a value: $(cat "$work/out")"

# The environment: the two URL variables fail, others do not.
d=$(repo env)
for v in NEXT_PUBLIC_SUPABASE_URL SUPABASE_URL; do
  run "$d" "$v=https://$prod.supabase.co" && fail "passes with the prod ref in $v"
  grep -q "$v" "$work/out" || fail "$v not named: $(cat "$work/out")"
  leaks && fail "output shows a value: $(cat "$work/out")"
done
run "$d" OTHER_URL="https://$prod.supabase.co" || fail "fails on a variable it does not own: $(cat "$work/out")"

[ "$failures" -eq 0 ] && echo "supabase-prod-ref: all cases pass"
exit "$failures"
