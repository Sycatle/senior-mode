#!/usr/bin/env bash
# Tests for the retry of GitHub calls in bin/senior-mode. Offline: gh is a stub that fails the first
# $GH_FAILS calls with $GH_ERROR, then succeeds; with $GH_HANG it sleeps that many seconds first (a dead connection).
set -u
cli=$(cd "$(dirname "$0")/.." && pwd)/senior-mode
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

mkdir -p "$work/stub"
cat >"$work/stub/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$GH_LOG"
calls=$(($(cat "$GH_COUNT" 2>/dev/null || echo 0) + 1))
echo "$calls" >"$GH_COUNT"
[ -z "${GH_HANG:-}" ] || sleep "$GH_HANG"
if [ "$calls" -le "$GH_FAILS" ]; then echo "$GH_ERROR" >&2; exit "${GH_EXIT:-1}"; fi
case "$*" in *item-add*) echo "ITEM_1" ;; esac
STUB
chmod +x "$work/stub/gh"
export PATH="$work/stub:$PATH" GH_LOG="$work/gh.log" GH_COUNT="$work/count" SENIOR_MODE_RETRY_DELAY=0

repo="$work/repo"
git init -q "$repo"
git -C "$repo" remote add origin https://github.com/acme/app.git
mkdir -p "$repo/.claude"
echo '{"project":{"owner":"acme","number":1,"id":"PVT_1","fields":{"Status":{"id":"F","options":{"Ready":"O"}}}}}' \
  >"$repo/.claude/senior-mode.json"

attempt() { # fails error [exit] -> runs item set, sets $status and $calls
  rm -f "$GH_COUNT" "$GH_LOG"
  (cd "$repo" && GH_FAILS=$1 GH_ERROR=$2 GH_EXIT=${3:-1} "$cli" item set 3 Status Ready) >/dev/null 2>"$work/err"
  status=$?
  calls=$(cat "$GH_COUNT" 2>/dev/null || echo 0)
}

attempt 1 "unknown owner type"
[ "$status" -eq 0 ] || fail "transient error once: exited $status ($(cat "$work/err"))"
[ "$calls" -eq 3 ] || fail "transient error once: $calls gh calls, wanted 3 (retry, then item-edit)"

attempt 3 "HTTP 502: Bad Gateway"
[ "$status" -eq 0 ] || fail "transient error three times: exited $status"

attempt 4 "unknown owner type"
[ "$status" -ne 0 ] || fail "transient error four times: succeeded"
[ "$calls" -eq 4 ] || fail "transient error four times: $calls gh calls, wanted 4 (1 + 3 retries)"
grep -q "unknown owner type" "$work/err" || fail "last error not shown: $(cat "$work/err")"

attempt 1 "HTTP 401: Bad credentials (https://api.github.com/graphql)"
[ "$status" -ne 0 ] && [ "$calls" -eq 1 ] || fail "permanent error retried: status $status, $calls calls"

attempt 1 "To get started with GitHub CLI, please run:  gh auth login" 4
[ "$status" -ne 0 ] && [ "$calls" -eq 1 ] || fail "missing auth retried: status $status, $calls calls"

# A gh call that does not answer in SENIOR_MODE_GH_TIMEOUT seconds is cut and is a transient failure (#382): retried,
# then it fails; a call that answers the second time succeeds. The cut ends the children of gh too.
rm -f "$GH_COUNT" "$GH_LOG"
start=$SECONDS
(cd "$repo" && GH_HANG=30 GH_FAILS=0 SENIOR_MODE_GH_TIMEOUT=1 "$cli" item set 3 Status Ready) >/dev/null 2>"$work/err"
status=$?
calls=$(cat "$GH_COUNT" 2>/dev/null || echo 0)
[ "$status" -ne 0 ] || fail "a gh call that hangs succeeded"
[ "$calls" -eq 4 ] || fail "a gh call that hangs: $calls attempts, wanted 4"
[ $((SECONDS - start)) -lt 20 ] || fail "a gh call that hangs was not cut: took $((SECONDS - start))s"
grep -q 'timed out' "$work/err" || fail "the cut is not said: $(cat "$work/err")"

[ "$failures" -eq 0 ] && echo "retry: all cases pass"
exit "$failures"
