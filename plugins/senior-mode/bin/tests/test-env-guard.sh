#!/usr/bin/env bash
# Tests for the environment guard: the script that fails when a forbidden pattern (config key
# envGuard.forbidden) appears in a .env* file or in the environment, and its wiring by
# `senior-mode setup repo`. Offline.
set -u
bin=$(cd "$(dirname "$0")/.." && pwd)
cli=$bin/senior-mode
script=$(cd "$bin/../templates/githooks" && pwd)/env-guard.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0
host=db.prod-internal.example.com
account=123456789012
value=hunter2-very-secret

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }
repo() { # name config: a git repository with this config
  local dir="$work/$1"
  git init -q -b main "$dir"
  mkdir -p "$dir/.claude"
  printf '%s\n' "$2" >"$dir/.claude/senior-mode.json"
  echo "$dir"
}
run() { (cd "$1" && shift && env "$@" "$script") >"$work/out" 2>&1; }
leaks() { grep -qF -e "$host" -e "$account" -e "$value" -e "prod-internal" "$work/out"; }
guard='{"envGuard":{"forbidden":["db.prod-internal.example.com","123456789012"]}}'

# Key not set, or an empty list: nothing to compare with, skipped with a reason.
for cfg in '{}' '{"envGuard":{"forbidden":[]}}'; do
  d=$(repo unset "$cfg")
  echo "DATABASE_URL=postgres://$host/app" >"$d/.env"
  run "$d" || fail "fails without patterns ($cfg): $(cat "$work/out")"
  [[ $(head -n 1 "$work/out") == "skipped: "* ]] || fail "no skip line without patterns: $(cat "$work/out")"
  rm -rf "$d"
done

# A worktree with only development values: passes.
d=$(repo clean "$guard")
printf 'DATABASE_URL=postgres://localhost:5432/app\nAPI_KEY=%s\n' "$value" >"$d/.env.local"
run "$d" DEV_HOST=localhost || fail "fails on a clean worktree: $(cat "$work/out")"
leaks && fail "clean run leaks: $(cat "$work/out")"

# An untracked, git-ignored .env.local: file and variable named, value never shown.
d=$(repo ignored "$guard")
echo '.env.local' >"$d/.gitignore"
printf 'FOO=1\nDATABASE_URL=postgres://u:%s@%s/app\n' "$value" "$host" >"$d/.env.local"
run "$d" && fail "passes with a forbidden host in an ignored .env.local"
grep -q '^  \.env\.local: DATABASE_URL$' "$work/out" || fail "file and variable not named: $(cat "$work/out")"
leaks && fail "output shows a value or a pattern: $(cat "$work/out")"

# Tracked and nested files, the export form, a line that is not VAR=value, a second pattern.
d=$(repo nested "$guard")
mkdir -p "$d/apps/web" "$d/node_modules/x"
printf 'export AWS_ACCOUNT=%s\n# prod %s\n' "$account" "$host" >"$d/apps/web/.env.production"
echo "URL=https://$host" >"$d/node_modules/x/.env"
echo "SAFE=1" >"$d/.env.example"
git -C "$d" add -A && git -C "$d" -c user.name=t -c user.email=t@t commit -q -m "chore: env"
run "$d" && fail "passes with forbidden values in a tracked nested file"
grep -q '^  apps/web/\.env\.production: AWS_ACCOUNT, line 2$' "$work/out" || fail "nested file not reported as expected: $(cat "$work/out")"
grep -q node_modules "$work/out" && fail "node_modules scanned: $(cat "$work/out")"
grep -q '\.env\.example' "$work/out" && fail "clean file reported: $(cat "$work/out")"
leaks && fail "output shows a value or a pattern: $(cat "$work/out")"

# The environment: variable name only.
d=$(repo environment "$guard")
run "$d" PROD_DATABASE_URL="postgres://$host/app" OTHER=1 && fail "passes with a forbidden host in the environment"
grep -q '^  environment: PROD_DATABASE_URL$' "$work/out" || fail "variable not named: $(cat "$work/out")"
grep -q OTHER "$work/out" && fail "clean variable reported: $(cat "$work/out")"
leaks && fail "output shows a value or a pattern: $(cat "$work/out")"

# A string is literal ("." is a dot); a /pattern/ is an extended regular expression.
d=$(repo literal '{"envGuard":{"forbidden":["db.prod.example.com","/acct-[0-9]{6}/"]}}')
echo "A=dbXprodXexample.com" >"$d/.env"
run "$d" || fail "a dot in a literal matched any character: $(cat "$work/out")"
printf 'B=acct-12345\nC=db.prod.example.com\n' >"$d/.env"
run "$d" && fail "literal not matched"
grep -q '^  \.env: C$' "$work/out" || fail "literal hit or regex miss wrong: $(cat "$work/out")"
echo "D=x-acct-654321" >"$d/.env"
run "$d" && fail "regex not matched"
grep -q '^  \.env: D$' "$work/out" || fail "regex hit not reported: $(cat "$work/out")"

# A pattern that is not a valid regex, or a key of the wrong type: an error that names the entry, not it.
d=$(repo badre '{"envGuard":{"forbidden":["fine","/prod-[/"]}}')
run "$d" && fail "an invalid regex passes"
grep -q "entry 2" "$work/out" || fail "invalid entry not named: $(cat "$work/out")"
grep -q 'prod-\[' "$work/out" && fail "invalid pattern echoed: $(cat "$work/out")"
d=$(repo badtype '{"envGuard":{"forbidden":"db.example.com"}}')
run "$d" && fail "a string instead of a list passes"
grep -q "list" "$work/out" || fail "no hint about the expected type: $(cat "$work/out")"

# Wiring: setup adds the check and the script only when the key lists something.
setup() { (cd "$1" && "$cli" setup repo) >"$work/out" 2>"$work/err" || fail "setup exited non-zero: $(cat "$work/err")"; }
cfg() { jq -r "$2" "$1/.claude/senior-mode.json"; }
d=$(repo off '{}')
setup "$d"
[ "$(cfg "$d" '[.checks[].name] | index("env guard")')" = null ] || fail "env guard added without the key: $(cfg "$d" '[.checks[].name]')"
[ ! -e "$d/.githooks/env-guard.sh" ] || fail "script installed without the key"

d=$(repo on "$guard")
setup "$d"
[ "$(cfg "$d" '.checks[] | select(.name == "env guard") | .run')" = ".githooks/env-guard.sh" ] ||
  fail "env guard check not wired: $(cfg "$d" '.checks')"
[ -x "$d/.githooks/env-guard.sh" ] || fail "script not installed executable"
[ "$(sed -n 2p "$d/.githooks/env-guard.sh" | cut -c1-14)" = "# senior-mode:" ] || fail "script not marked as senior-mode's"
grep -q "env-guard.sh: installed" "$work/out" || fail "install not reported: $(cat "$work/out")"
cp "$d/.claude/senior-mode.json" "$work/before"
setup "$d"
cmp -s "$work/before" "$d/.claude/senior-mode.json" || fail "second setup changed the config"
[ "$(cfg "$d" '[.checks[] | select(.name == "env guard")] | length')" = 1 ] || fail "env guard check duplicated"

# A script of the project's own with that name is kept.
d=$(repo own "$guard")
mkdir -p "$d/.githooks"
printf '#!/bin/sh\necho mine\n' >"$d/.githooks/env-guard.sh"
setup "$d"
grep -q "mine" "$d/.githooks/env-guard.sh" || fail "a project's own env-guard.sh was replaced"
grep -q "env-guard.sh: yours kept" "$work/out" || fail "kept script not reported: $(cat "$work/out")"

# A config key of the wrong type stops setup instead of being ignored.
d=$(repo wrongtype '{"envGuard":{"forbidden":"x"}}')
(cd "$d" && "$cli" setup repo) >"$work/out" 2>&1 && fail "setup accepts envGuard.forbidden as a string"
grep -q "envGuard.forbidden" "$work/out" || fail "wrong type not explained: $(cat "$work/out")"

# End to end: `senior-mode check` fails on a leak, shows skip once the key is removed, never a value.
d=$(repo e2e "$guard")
setup "$d"
jq '.checks |= map(select(.name == "env guard"))' "$d/.claude/senior-mode.json" >"$work/c" && mv "$work/c" "$d/.claude/senior-mode.json"
printf 'DATABASE_URL=postgres://u:%s@%s/app\n' "$value" "$host" >"$d/.env.local"
(cd "$d" && "$cli" check) >"$work/out" 2>&1 && fail "check passes with a forbidden host in .env.local"
grep -q "^FAIL  env guard" "$work/out" || fail "env guard failure not shown: $(cat "$work/out")"
grep -q 'DATABASE_URL' "$work/out" || fail "variable not shown by check: $(cat "$work/out")"
leaks && fail "check output shows a value or a pattern: $(cat "$work/out")"
jq 'del(.envGuard)' "$d/.claude/senior-mode.json" >"$work/c" && mv "$work/c" "$d/.claude/senior-mode.json"
(cd "$d" && "$cli" check) >"$work/out" 2>&1 || fail "check fails after the key was removed: $(cat "$work/out")"
grep -q "^skip  env guard: " "$work/out" || fail "removed key not shown as skip: $(cat "$work/out")"

[ "$failures" -eq 0 ] && echo "env-guard: all cases pass"
exit "$failures"
