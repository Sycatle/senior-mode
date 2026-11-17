#!/usr/bin/env bash
# Tests for `senior-mode release`. Offline: gh and npx are stubs logging their arguments.
set -u
cli=$(cd "$(dirname "$0")/.." && pwd)/senior-mode
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

mkdir -p "$work/stub"
cat >"$work/stub/gh" <<'STUB'
#!/usr/bin/env bash
[ "$*" = "auth token" ] || { echo "unexpected: gh $*" >&2; exit 1; }
[ -z "${NO_AUTH:-}" ] || { echo "not logged in" >&2; exit 1; }
echo ghs_secret
STUB
cat >"$work/stub/npx" <<'STUB'
#!/usr/bin/env bash
echo "npx $* (in $PWD)" >>"$LOG"
prev=""
for a in "$@"; do [ "$prev" = --token ] && { echo "token file: $a" >>"$LOG"; cat "$a" >>"$LOG"; }; prev=$a; done
case "$*" in *"$FAIL_ON"*) echo "release-please failed" >&2; exit 1 ;; esac
STUB
chmod +x "$work/stub/gh" "$work/stub/npx"
export PATH="$work/stub:$PATH" LOG="$work/log" FAIL_ON="never"

repo="$work/repo"
git init -q "$repo"
git -C "$repo" remote add origin https://github.com/acme/app.git
mkdir -p "$repo/sub"
echo '{}' >"$repo/release-please-config.json"

release() {
  : >"$LOG"
  (cd "$repo/sub" && "$cli" release "$@") >"$work/out" 2>"$work/err"
}
logged() { grep -qF -- "$1" "$LOG"; }

release || fail "release exited non-zero: $(cat "$work/err")"
sed -n 1p "$LOG" | grep -q "^npx --yes release-please@[0-9.]* github-release .*--repo-url acme/app (in $repo)$" ||
  fail "github-release not run first from the root: $(cat "$LOG")"
grep '^npx' "$LOG" | sed -n 2p | grep -q "release-pr .*--repo-url acme/app" ||
  fail "release-pr not run second: $(cat "$LOG")"
grep '^npx' "$LOG" | grep -q ghs_secret && fail "token on the command line"
grep -qx ghs_secret "$LOG" || fail "token file did not hold the token"
file=$(sed -n 's/^token file: //p' "$LOG" | head -1)
[ -n "$file" ] && [ ! -e "$file" ] || fail "token file left behind: $file"
grep -q ghs_secret "$work/out" "$work/err" && fail "token printed"

release --dry-run || fail "dry run exited non-zero"
[ "$(grep -c -- '--dry-run' "$LOG")" -eq 2 ] || fail "--dry-run not passed to both steps"

FAIL_ON=github-release release && fail "a failed github-release exits zero"
logged "release-pr" && fail "release-pr runs after github-release failed"
file=$(sed -n 's/^token file: //p' "$LOG" | head -1)
[ ! -e "$file" ] || fail "token file left behind after a failure"

NO_AUTH=1 release && fail "runs without a gh login"
[ -s "$LOG" ] && fail "npx called without a token"

release --now && fail "unknown option accepted"

rm "$repo/release-please-config.json"
release && fail "runs without release-please-config.json"
grep -q "setup repo" "$work/err" || fail "missing config not explained: $(cat "$work/err")"

[ "$failures" -eq 0 ] && echo "release: all cases pass"
exit "$failures"
