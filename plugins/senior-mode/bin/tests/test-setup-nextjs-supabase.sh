#!/usr/bin/env bash
# Tests for the nextjs-supabase preset of `senior-mode setup repo`: detection, checks, scripts,
# protected globs and the CLAUDE.md note. Offline: the Supabase CLI is a stub.
set -u
here=$(cd "$(dirname "$0")" && pwd)
cli=$here/../senior-mode
preset=$here/../../presets/nextjs-supabase/preset.json
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }
project() { # name package.json [file...]
  local dir="$work/$1"
  git init -q -b main "$dir"
  printf '%s\n' "$2" >"$dir/package.json"
  shift 2
  for f in "$@"; do mkdir -p "$dir/$(dirname "$f")"; : >"$dir/$f"; done
  echo "$dir"
}
setup() { # dir [args...]
  local dir=$1
  shift
  (cd "$dir" && "$cli" setup repo "$@") >"$work/out" 2>"$work/err" || fail "setup exited non-zero: $(cat "$work/err")"
}
cfg() { jq -r "$2" "$1/.claude/senior-mode.json"; }
check_run() { jq -r --arg n "$2" '.checks[] | select(.name == $n) | .run' "$1/.claude/senior-mode.json"; }
preset_of() { setup "$1"; cfg "$1" .preset; }

next='"next": "16"'
scripts='"scripts": {"lint": "eslint .", "typecheck": "tsc --noEmit", "test": "vitest run", "build": "next build", "test:e2e": "playwright test"}'

# Detection: next with a Supabase client library, or with supabase/config.toml.
d=$(project ssr "{$scripts, \"dependencies\": {$next, \"@supabase/ssr\": \"0.6\"}}" package-lock.json)
[ "$(preset_of "$d")" = nextjs-supabase ] || fail "next + @supabase/ssr is not nextjs-supabase: $(cfg "$d" .preset)"
grep -q "^preset: nextjs-supabase (JavaScript, next)$" "$work/out" || fail "preset not reported: $(cat "$work/out")"
d=$(project js "{\"dependencies\": {$next}, \"devDependencies\": {\"@supabase/supabase-js\": \"2\"}}")
[ "$(preset_of "$d")" = nextjs-supabase ] || fail "next + @supabase/supabase-js is not nextjs-supabase: $(cfg "$d" .preset)"
d=$(project toml "{\"dependencies\": {$next}}" supabase/config.toml)
[ "$(preset_of "$d")" = nextjs-supabase ] || fail "next + supabase/config.toml is not nextjs-supabase: $(cfg "$d" .preset)"

# Not enough: next alone, Supabase without next, config.toml without next.
d=$(project nextonly "{\"dependencies\": {$next}}")
[ "$(preset_of "$d")" = node ] || fail "next alone is not node: $(cfg "$d" .preset)"
d=$(project sbonly '{"dependencies": {"@supabase/supabase-js": "2"}}')
[ "$(preset_of "$d")" = node ] || fail "Supabase without next is not node: $(cfg "$d" .preset)"
d=$(project tomlonly '{"dependencies": {"react": "19"}}' supabase/config.toml)
[ "$(preset_of "$d")" = node ] || fail "config.toml without next is not node: $(cfg "$d" .preset)"

# A stored preset wins, both ways.
d=$(project storednode "{\"dependencies\": {$next, \"@supabase/ssr\": \"0.6\"}}")
mkdir -p "$d/.claude" && echo '{"preset": "node"}' >"$d/.claude/senior-mode.json"
[ "$(preset_of "$d")" = node ] || fail "stored node replaced by detection: $(cfg "$d" .preset)"
d=$(project storedsb "{\"dependencies\": {\"react\": \"19\"}}")
mkdir -p "$d/.claude" && echo '{"preset": "nextjs-supabase"}' >"$d/.claude/senior-mode.json"
[ "$(preset_of "$d")" = nextjs-supabase ] || fail "stored nextjs-supabase replaced by detection: $(cfg "$d" .preset)"

# Node's detection is reused: scripts, package manager, e2e, framework, release type.
d=$(project cmds "{$scripts, \"dependencies\": {$next, \"@supabase/ssr\": \"0.6\"}, \"devDependencies\": {\"typescript\": \"5\"}}" pnpm-lock.yaml)
setup "$d"
grep -qx "check script supabase-prod-ref.sh: installed" "$work/out" || fail "install not reported: $(cat "$work/out")"
[ "$(check_run "$d" lint)" = "pnpm run lint" ] || fail "lint script not used: $(check_run "$d" lint)"
[ "$(check_run "$d" e2e)" = "pnpm run test:e2e" ] || fail "e2e script not used: $(check_run "$d" e2e)"
[ "$(cfg "$d" .framework)" = next ] || fail "Next.js not recorded"
[ "$(jq -r '.packages["."]["release-type"]' "$d/release-please-config.json")" = node ] || fail "release type is not node"
(cd "$d" && "$cli" setup repo --command e2e="make e2e") >/dev/null 2>&1 || fail "e2e not accepted as a command"

# Checks and scripts: migration lint, prod ref guard, copied into .githooks, refreshed, never replacing yours.
[ "$(jq -r '[.checks[].name] | join(",")' "$d/.claude/senior-mode.json")" = \
  "lint,typecheck,test,build,e2e,commit subjects,supabase migration lint,supabase prod ref" ] ||
  fail "unexpected checks: $(cfg "$d" '[.checks[].name] | join(",")')"
[ "$(check_run "$d" "supabase prod ref")" = ".githooks/supabase-prod-ref.sh" ] || fail "prod ref check not wired"
[ -x "$d/.githooks/supabase-prod-ref.sh" ] || fail "prod ref script not installed executable"
echo "# stale" >>"$d/.githooks/supabase-prod-ref.sh"
setup "$d"
cmp -s "$d/.githooks/supabase-prod-ref.sh" "$here/../../presets/nextjs-supabase/scripts/supabase-prod-ref.sh" ||
  fail "outdated script not refreshed"
printf '#!/bin/sh\nexit 0\n' >"$d/.githooks/supabase-prod-ref.sh"
setup "$d"
grep -q 'exit 0' "$d/.githooks/supabase-prod-ref.sh" || fail "a script of your own was replaced"
cp "$d/.claude/senior-mode.json" "$work/before"
setup "$d"
cmp -s "$work/before" "$d/.claude/senior-mode.json" || fail "second run changed the config"
n=$(project plainnode '{"scripts": {"test": "vitest run"}}')
setup "$n"
[ -z "$(check_run "$n" "supabase prod ref")" ] && [ ! -e "$n/.githooks/supabase-prod-ref.sh" ] ||
  fail "node preset got the Supabase checks"

# The prod ref check, end to end through the installed script.
d=$(project guard "{\"dependencies\": {$next, \"@supabase/ssr\": \"0.6\"}}")
setup "$d"
echo 'NEXT_PUBLIC_SUPABASE_URL=https://abcdefghijklmnopqrst.supabase.co' >"$d/.env.local"
jq '.supabase.prodProjectRef = "abcdefghijklmnopqrst"' "$d/.claude/senior-mode.json" >"$work/c" && mv "$work/c" "$d/.claude/senior-mode.json"
(cd "$d" && bash -c "$(check_run "$d" "supabase prod ref")") >"$work/out" 2>&1 && fail "guard passes with the prod ref in .env.local"
grep -q 'abcdefghijklmnopqrst' "$work/out" && fail "guard prints the ref"

# The migration lint: the Supabase CLI's `db lint`, skipped without migrations, CLI or local stack.
lint=$(jq -r '.checks[] | select(.name == "supabase migration lint") | .run' "$preset")
[ "$(check_run "$d" "supabase migration lint")" = "$lint" ] || fail "migration lint not wired from the preset"
mkdir -p "$work/stub" "$work/nopath"
cat >"$work/stub/supabase" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$SB_LOG"
[ "$1" != status ] || exit "${SB_STATUS:-0}"
[ "$1 $2" != "db lint" ] || exit "${SB_LINT:-0}"
STUB
chmod +x "$work/stub/supabase"
bash=$(command -v bash)
lintrun() { # dir path env...
  local dir=$1 path=$2
  shift 2
  : >"$work/sb.log"
  (cd "$dir" && env PATH="$path" SB_LOG="$work/sb.log" "$@" "$bash" -c "$lint") >"$work/out" 2>&1
}
d="$work/lint" && git init -q -b main "$d"
lintrun "$d" "$work/stub:/usr/bin:/bin" || fail "fails without supabase/migrations: $(cat "$work/out")"
grep -q '^skipped: .*migrations' "$work/out" || fail "no migrations not said: $(cat "$work/out")"
mkdir -p "$d/supabase/migrations"
lintrun "$d" "$work/nopath" || fail "fails without the CLI: $(cat "$work/out")"
grep -q '^skipped: .*CLI' "$work/out" || fail "missing CLI not said: $(cat "$work/out")"
lintrun "$d" "$work/stub:/usr/bin:/bin" SB_STATUS=1 || fail "fails when the local stack is down: $(cat "$work/out")"
grep -q '^skipped: .*supabase start' "$work/out" || fail "stack down not said: $(cat "$work/out")"
grep -q 'db lint' "$work/sb.log" && fail "lint ran with the stack down"
lintrun "$d" "$work/stub:/usr/bin:/bin" || fail "fails with a clean lint: $(cat "$work/out")"
grep -qx 'db lint --level warning --fail-on error' "$work/sb.log" || fail "wrong lint command: $(cat "$work/sb.log")"
lintrun "$d" "$work/stub:/usr/bin:/bin" SB_LINT=1 && fail "passes although the lint fails"

# Protected globs declared by the preset.
want='["supabase/migrations/**","supabase/**/*.sql","middleware.ts","src/middleware.ts","**/auth/**","**/rls/**",".github/workflows/**",".env*"]'
[ "$(jq -c .protected "$preset")" = "$want" ] || fail "protected globs: $(jq -c .protected "$preset")"

# CLAUDE.md: one note about the dev project and e2e slots, refreshed in place, in both languages.
d=$(project note "{\"dependencies\": {$next, \"@supabase/ssr\": \"0.6\"}}")
setup "$d"
grep -q 'senior-mode:nextjs-supabase' "$d/CLAUDE.md" || fail "no Supabase note in CLAUDE.md"
grep -q 'dev project' "$d/CLAUDE.md" || fail "note lacks the dev project"
grep -q 'e2e.slots' "$d/CLAUDE.md" || fail "note lacks e2e.slots"
sed -i 's/e2e.slots/old/' "$d/CLAUDE.md"
setup "$d"
[ "$(grep -c '^<!-- senior-mode:nextjs-supabase' "$d/CLAUDE.md")" = 1 ] || fail "note duplicated"
grep -q 'e2e.slots' "$d/CLAUDE.md" || fail "outdated note not refreshed"
[ "$(wc -l <"$d/CLAUDE.md")" -le 80 ] || fail "CLAUDE.md over 80 lines"
grep -q "over 80" "$work/out" && fail "length warning on a fresh CLAUDE.md"
d=$(project notefr "{\"dependencies\": {$next, \"@supabase/ssr\": \"0.6\"}}")
mkdir -p "$d/.claude" && echo '{"language": "fr"}' >"$d/.claude/senior-mode.json"
setup "$d"
grep -q "projet Supabase de dev" "$d/CLAUDE.md" || fail "French note missing"
grep -q 'senior-mode:nextjs-supabase' "$n/CLAUDE.md" && fail "node preset got the Supabase note"

[ "$failures" -eq 0 ] && echo "setup-nextjs-supabase: all cases pass"
exit "$failures"
