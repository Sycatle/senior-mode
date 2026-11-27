#!/usr/bin/env bash
# Tests for edit-fix.sh (PostToolUse, tier 1): JSON in, fixed file and findings out.
set -u
hook=$(cd "$(dirname "$0")/.." && pwd)/edit-fix.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

repo="$work/repo"
git init -q -b main "$repo"
mkdir -p "$repo/.claude" "$repo/src" "$work/out"
echo 'ignored/' >"$repo/.gitignore"
mkdir -p "$repo/ignored"
printf 'const   a=1\n' >"$repo/src/a.ts"
printf 'const   a=1\n' >"$repo/ignored/b.ts"
printf 'const   a=1\n' >"$work/out/c.ts"
config() { jq -nc '{check: {edit: $ARGS.positional}}' --args "$@" >"$repo/.claude/senior-mode.json"; }
fmt='sed -i "s/  */ /g;s/=/ = /" {file}'
send() { # file -> hook stdout
  jq -nc --arg f "$1" --arg d "$repo" '{hook_event_name: "PostToolUse", session_id: "s", cwd: $d, tool_name: "Edit", tool_input: {file_path: $f}}' | "$hook"
}

config "$fmt"
out=$(send "$repo/src/a.ts"); rc=$?
[ "$rc" -eq 0 ] || fail "formatter: hook exits $rc"
[ "$(cat "$repo/src/a.ts")" = "const a = 1" ] || fail "formatter: file not formatted: $(cat "$repo/src/a.ts")"
[ -z "$out" ] || fail "formatter: unexpected output: $out"

printf 'const   a=1\n' >"$repo/src/a.ts"
out=$(send "src/a.ts")
[ "$(cat "$repo/src/a.ts")" = "const a = 1" ] || fail "relative path: file not formatted"

cat >"$work/lint.sh" <<'LINT'
#!/usr/bin/env bash
for i in $(seq 1 14); do echo "$2/src/a.ts:$i:3: no-unused-vars 'x$i' is unused"; done
echo "not a finding"
LINT
chmod +x "$work/lint.sh"
config "$work/lint.sh {file} $repo"
out=$(send "$repo/src/a.ts"); rc=$?
[ "$rc" -eq 0 ] || fail "findings: hook exits $rc"
ctx=$(jq -r '.hookSpecificOutput.additionalContext' <<<"$out")
[ "$(wc -l <<<"$ctx")" -eq 10 ] || fail "findings: expected 10 lines, got: $ctx"
[ "$(head -n1 <<<"$ctx")" = "src/a.ts:1 no-unused-vars 'x1' is unused" ] || fail "findings: bad first line: $ctx"
[ -f "$repo/src/a.ts" ] || fail "findings: the edit is not kept"

config 'sleep 20 # {file}'
start=$SECONDS
out=$(send "$repo/src/a.ts"); rc=$?
[ "$rc" -eq 0 ] || fail "timeout: hook exits $rc"
[ $((SECONDS - start)) -lt 15 ] || fail "timeout: fixer not killed after 10 seconds"
grep -q 'edit-fix: sleep 20 # {file} timed out' <<<"$out" || fail "timeout: message missing: $out"

config "touch $work/ran; $fmt"
send "$repo/ignored/b.ts" >/dev/null
send "$work/out/c.ts" >/dev/null
[ ! -e "$work/ran" ] || fail "a fixer ran on an ignored file or one outside the repository"
[ "$(cat "$repo/ignored/b.ts")" = "const   a=1" ] || fail "ignored file was changed"

rm "$repo/.claude/senior-mode.json"
out=$(send "$repo/src/a.ts"); rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] || fail "no config: hook did something ($rc): $out"
echo '{"check": {}}' >"$repo/.claude/senior-mode.json"
printf 'const   a=1\n' >"$repo/src/a.ts"
out=$(send "$repo/src/a.ts"); rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && [ "$(cat "$repo/src/a.ts")" = "const   a=1" ] || fail "no check.edit: hook did something ($rc): $out"

[ "$failures" -eq 0 ] && echo "edit-fix: all cases pass"
exit "$failures"
