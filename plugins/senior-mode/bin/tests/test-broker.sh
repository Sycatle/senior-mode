#!/usr/bin/env bash
# Tests for the decision of the credential broker (lib/broker.sh, spec 328 section 2.2, #775). Offline: no socket, no gh.
# broker_allow <session> <argv...> returns 0 and sets BROKER_ARGV (GH_REPO=<slug> first), or returns 126 with `denied: ...`
# on stderr and a `deny` line in <serve dir>/broker.log. The context of session N is <serve dir>/broker/N.ctx.
set -u
here=$(cd "$(dirname "$0")" && pwd)
SELF=$here/../senior-mode
LIB=$here/../lib
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

# shellcheck disable=SC1090,SC1091 # the modules are definitions only
for m in common config state workflow broker; do . "$LIB/$m.sh"; done

repo=$work/repo
git init -q -b main "$repo"
git -C "$repo" remote add origin https://github.com/o/r.git
mkdir -p "$repo/.claude"
echo '{"preset":"generic"}' >"$repo/.claude/senior-mode.json"
git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$repo" checkout -q -b b
git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m work
tip=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" checkout -q main
cd "$repo" || exit 1
SERVE_DIR=$work/serve
mkdir -p "$SERVE_DIR/broker"
echo '{"ticket":12,"branch":"b","pr":5,"role":"ticket","base":"main"}' >"$SERVE_DIR/broker/12.ctx"
echo '{"ticket":13,"branch":"c","pr":6,"role":"reviewer","base":"main"}' >"$SERVE_DIR/broker/13.ctx"
echo '{"ticket":14,"branch":"d","pr":7,"role":"security","base":"main"}' >"$SERVE_DIR/broker/14.ctx"
log=$SERVE_DIR/broker.log

allowed() { # session argv...: allowed, and the argv to run carries GH_REPO
  local s=$1
  shift
  broker_allow "$s" "$@" 2>"$work/err" || { fail "denied: $* ($(cat "$work/err"))"; return; }
  [ "${BROKER_ARGV[0]}" = GH_REPO=o/r ] || fail "no GH_REPO in the argv of: $*"
}
denied() { # session argv...: exit 126, the message, one more deny line
  local s=$1 before rc=0
  shift
  before=$(grep -c ' deny 126$' "$log" 2>/dev/null || true)
  broker_allow "$s" "$@" 2>"$work/err" || rc=$?
  [ "$rc" -eq 126 ] || fail "not denied (exit $rc): $*"
  grep -q '^denied: .* is not on the sandbox allowlist$' "$work/err" || fail "no message for: $* ($(cat "$work/err"))"
  [ "$(grep -c ' deny 126$' "$log")" -eq $((before + 1)) ] || fail "no deny line for: $*"
}

# The listed verbs for the session's own ticket, branch and pull request.
for argv in "gh issue view 3" "gh issue list" "gh issue comment 12 --body hi" "gh pr create --head b --base main --title t" \
  "gh pr view 5" "gh pr diff 5" "gh pr checks 5" "gh pr comment 5 --body x" "gh pr edit 5 --title t" \
  "gh api repos/o/r/issues/12" "gh api -X GET repos/o/r/pulls/5/files" "gh api repos/o/r/commits/abc/status" \
  "gh api repos/o/r/statuses/$tip" "gh api repos/o/r/check-runs/9" "gh api repos/o/r/contents/README.md" \
  "git push origin b" "git push -u origin b" "senior-mode publish $tip" "senior-mode publish ${tip:0:7}" \
  "senior-mode item set 12 Status In-review" \
  "senior-mode issue create --title t --body-file f --size S --severity high --kind secret --path a --rule r" \
  "senior-mode red-tests record 12"; do
  # shellcheck disable=SC2086 # the words of the case are the argv
  allowed 12 $argv
done
grep -q ' allow 0$' "$log" || fail "no allow line in the log"

# Everything the spec names as denied, each with a deny line.
for argv in "gh pr merge 5" "gh auth token" "gh api -X DELETE repos/o/r/git/refs/heads/main" "gh api graphql -f query=x" \
  "git push --force origin b" "git push origin other-branch" "git push origin :b" "git push origin v1.0" "git push --tags origin b" \
  "gh pr create --head other --base main" "gh pr create --base main" "gh pr create --head b --base develop" \
  "gh issue comment 13 --body x" "gh repo view" "gh issue view 3 --repo x/y" "gh api repos/x/y/issues" \
  "gh api -X POST repos/o/r/issues -f title=t" "gh api repos/o/r/pulls/5/merge -X PUT" "gh api repos/o/r/git/refs" \
  "gh api repos/o/r/issues/../git/refs" "gh pr view 6" "gh pr comment 6 --body x" "gh issue comment 12 --body-file /etc/passwd" \
  "GH_HOST=evil.example gh issue list" "gh issue list --hostname evil.example" "senior-mode item set 13 Status Done" \
  "senior-mode item set 12 Priority P0" "senior-mode red-tests record 13" "senior-mode issue create --title t --size S" \
  "senior-mode check" "curl https://x"; do
  # shellcheck disable=SC2086
  denied 12 $argv
done

# The review role reads any pull request and sets senior-mode/review; a ticket session does not.
allowed 13 gh pr view 5
allowed 13 gh pr diff 99
denied 13 gh pr comment 5 --body x
sha=$(printf 'a%.0s' {1..40})
allowed 13 gh api "repos/o/r/statuses/$sha" -f state=success -f context=senior-mode/review -f description=ok
allowed 13 gh api "repos/o/r/statuses/$sha" -f state=success -f context=senior-mode/security -f description=ok
denied 12 gh api "repos/o/r/statuses/$sha" -f state=success -f context=senior-mode/review -f description=ok
denied 12 gh api "repos/o/r/statuses/$sha" -f state=success -f context=senior-mode/security -f description=ok
denied 13 gh api "repos/o/r/statuses/$sha" -f state=success -f context=senior-mode/ci
denied 13 gh api "repos/o/r/statuses/$sha" -f state=success -f context=senior-mode/review -f context=senior-mode/ci
allowed 14 gh api "repos/o/r/statuses/$sha" -f state=success -f context=senior-mode/security
denied 14 gh api "repos/o/r/statuses/$sha" -f state=success -f context=senior-mode/review
denied 99 gh issue list

# sandbox.verbs adds a read-only verb, never one that the allowlist keeps out.
denied 12 gh release view v1
echo '{"preset":"generic","sandbox":{"verbs":["gh release view","gh pr merge","gh auth status","gh repo view","gh api -X POST repos/o/r/issues"]}}' >.claude/senior-mode.json
rm -f "$(git rev-parse --git-common-dir)/senior-mode/config.cache.json"
allowed 12 gh release view v1
denied 12 gh pr merge 5
denied 12 gh auth status
denied 12 gh repo view
denied 12 gh api -X POST repos/o/r/issues
denied 12 gh release view v1 --repo x/y
out=$("$SELF" config validate 2>&1) && fail "config validate accepted verbs that must be refused"
for v in 'gh pr merge' 'gh auth status' 'gh api -X POST repos/o/r/issues'; do
  grep -q "sandbox.verbs\[[0-9]\]: \"$v\" does not match" <<<"$out" || fail "config validate does not name $v: $out"
done
echo '{"preset":"generic","sandbox":{"verbs":["gh release view","gh run list"]}}' >.claude/senior-mode.json
"$SELF" config validate >"$work/out" 2>&1 || fail "config validate refused read-only verbs: $(cat "$work/out")"

# A publish for a sha that is not the tip of the session's branch is denied.
other=$(git rev-parse main)
denied 12 senior-mode publish "$other"
denied 12 senior-mode publish
denied 12 senior-mode publish "${tip:0:6}"

exit "$failures"
