#!/usr/bin/env bash
# Tests for `senior-mode protected [--base <ref>]`: changed files of the branch that match the
# `protected` globs of the config (spec 0001 §10). Offline: only local git repositories.
set -u
cli=$(cd "$(dirname "$0")/.." && pwd)/senior-mode
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }
g() { git -C "$repo" -c user.name=t -c user.email=t@t "$@" >/dev/null 2>&1 || echo "setup failed: git $*"; }
config() { printf '%s\n' "$1" >"$repo/.claude/senior-mode.json"; }
touch_files() { # path...: creates or appends, then commits on the current branch
  local f
  for f in "$@"; do
    mkdir -p "$repo/$(dirname "$f")"
    echo x >>"$repo/$f"
  done
  g add -A
  g commit -m "chore: change $1"
}
# expect <wanted status> <wanted stdout, newline separated, "" for none> <args...>
expect() {
  local want=$1 out=$2 got status
  shift 2
  got=$(cd "$repo" && "$cli" protected "$@" 2>"$work/err")
  status=$?
  [ "$status" -eq "$want" ] || fail "protected $* exited $status, wanted $want ($(cat "$work/err"))"
  [ "$got" = "$out" ] || fail "protected $* printed '$got', wanted '$out'"
}

repo="$work/repo"
git init -q -b main "$repo"
mkdir -p "$repo/.claude"
config '{"protected": ["**/migrations/**", ".github/workflows/**", "Dockerfile*", ".env*", "src/auth/*.ts", "docs/**/secret.md", "payments/?.ts"]}'
echo .claude/ >>"$repo/.git/info/exclude"
g commit --allow-empty -m "chore: start"

# Nothing changed yet: no match, exit 1, quietly.
expect 1 ""

g switch -c feat/1-login
touch_files src/app.ts docs/guide.md
expect 1 ""

touch_files supabase/migrations/0001_init.sql migrations/0002.sql .github/workflows/ci.yml
expect 0 $'.github/workflows/ci.yml\nmigrations/0002.sql\nsupabase/migrations/0001_init.sql'

# A glob without a slash matches at any depth; with a slash it is anchored at the root.
touch_files Dockerfile services/api/Dockerfile.prod web/.env.local
expect 0 $'.github/workflows/ci.yml\nDockerfile\nmigrations/0002.sql\nservices/api/Dockerfile.prod\nsupabase/migrations/0001_init.sql\nweb/.env.local'

# `*` stays inside one path segment, `**/` spans any number (even none), `?` is one character.
g switch -q main
g switch -c feat/2-globs
touch_files src/auth/session.ts src/auth/deep/token.ts src/authx.ts docs/a/b/secret.md docs/secret.md payments/a.ts payments/ab.ts
expect 0 $'docs/a/b/secret.md\ndocs/secret.md\npayments/a.ts\nsrc/auth/session.ts'

# Characters that are special in a regex are literal in a glob.
g switch -q main
g switch -c feat/3-literal
config '{"protected": ["config/app.json", "a+b/**", "(x)/*"]}'
touch_files config/appXjson config/app.json "a+b/f" "(x)/y"
expect 0 $'(x)/y\na+b/f\nconfig/app.json'

# Moving a file out of a protected zone is still a change of that zone.
config '{"protected": ["migrations/**"]}'
g switch -q main
touch_files migrations/0001.sql
g switch -c feat/4-move
mkdir -p "$repo/src"
g mv migrations/0001.sql src/0001.sql
g commit -m "refactor: move the migration"
expect 0 "migrations/0001.sql"

# --base: compared with another ref than the default branch.
g switch -q main
g switch -c feat/5-stack
touch_files migrations/0003.sql
g switch -c feat/6-on-top
touch_files src/more.ts
expect 0 "migrations/0003.sql"
expect 1 "" --base feat/5-stack
expect 0 "migrations/0003.sql" --base main
expect 1 "" --base no-such-ref
grep -q "unknown ref" "$work/err" || fail "unknown base not explained: $(cat "$work/err")"

# The base is the merge-base: commits that reached the default branch later are not ours.
g switch -q main
touch_files migrations/0004.sql
g switch -q feat/6-on-top
expect 0 "migrations/0003.sql"

# The default branch comes from origin/HEAD when there is one, even if the local main is stale.
git init -q --bare "$work/origin.git"
g remote add origin "$work/origin.git"
g push -q origin main
git -C "$repo" remote set-head origin main
g switch -q main
touch_files migrations/0005.sql
g push -q origin main
g reset -q --hard HEAD~1
g switch -q feat/6-on-top
expect 0 "migrations/0003.sql"

# A repository whose default branch is master, no remote.
other="$work/other"
git init -q -b master "$other"
mkdir -p "$other/.claude"
echo '{"protected": ["migrations/**"]}' >"$other/.claude/senior-mode.json"
git -C "$other" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "chore: start"
git -C "$other" switch -q -c feat/1-x
mkdir -p "$other/migrations" && echo x >"$other/migrations/1.sql"
git -C "$other" add -A && git -C "$other" -c user.name=t -c user.email=t@t commit -q -m "feat: x"
[ "$(cd "$other" && "$cli" protected)" = migrations/1.sql ] || fail "master not found as the default branch"

# The levers directory of the base branch's list (#739): a branch that edits a file under it changes a protected zone.
zone="$work/zone"
git init -q -b main "$zone"
mkdir -p "$zone/.claude"
echo '{"protected": [".claude/senior-mode.json", ".claude/senior-mode/**"]}' >"$zone/.claude/senior-mode.json"
git -C "$zone" add -A && git -C "$zone" -c user.name=t -c user.email=t@t commit -q -m "chore: start"
git -C "$zone" switch -q -c feat/1-lever
mkdir -p "$zone/.claude/senior-mode/hooks" "$zone/.claude/senior-mode/roles"
echo x >"$zone/.claude/senior-mode/hooks/x.sh"
echo x >"$zone/.claude/senior-mode/roles/y.md"
echo x >"$zone/src.ts"
git -C "$zone" add -A && git -C "$zone" -c user.name=t -c user.email=t@t commit -q -m "feat: levers"
[ "$(cd "$zone" && "$cli" protected)" = $'.claude/senior-mode/hooks/x.sh\n.claude/senior-mode/roles/y.md' ] ||
  fail "files under .claude/senior-mode/ not reported as a protected zone: $(cd "$zone" && "$cli" protected 2>&1)"

# No key, empty list: nothing is protected.
config '{}'
expect 1 ""
config '{"protected": []}'
expect 1 ""

# A malformed key or config, and no config at all, are errors, not silence.
config '{"protected": "migrations/**"}'
expect 1 ""
grep -q "array of globs" "$work/err" || fail "string key not refused: $(cat "$work/err")"
config '{not json'
expect 1 ""
grep -q setup "$work/err" || fail "invalid config message does not mention setup: $(cat "$work/err")"
rm "$repo/.claude/senior-mode.json"
expect 1 ""
grep -q setup "$work/err" || fail "missing config message does not mention setup: $(cat "$work/err")"
config '{"protected": ["migrations/**"]}'
expect 1 "" --bogus
expect 1 "" --base

(cd "$work" && "$cli" protected 2>/dev/null) && fail "works outside a git repository"

[ "$failures" -eq 0 ] && echo "protected: all cases pass"
exit "$failures"
