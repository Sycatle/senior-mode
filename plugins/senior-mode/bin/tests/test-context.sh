#!/usr/bin/env bash
# Tests for `senior-mode context` (SessionStart). Offline: gh is a stub answering from $GH_ISSUE.
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
[ -z "${GH_FAIL:-}" ] || exit 1
case "$*" in *"issue view"*) printf '%s\n' "$GH_ISSUE" ;; esac
STUB
chmod +x "$work/stub/gh"
export PATH="$work/stub:$PATH" GH_LOG="$work/gh.log"
# shellcheck disable=SC2016 # backticks are Markdown in the issue body
export GH_ISSUE='{"number":12,"title":"Let people log in","state":"OPEN","projectItems":[{"status":{"name":"In progress"}}],"body":"## What this gives\nLogin.\n\nSpec: `docs/specs/0003-login.md` §2.\n\n## Acceptance criteria\n- Given a user with an account, when they log in, then they see their dashboard.\n- Given a wrong password, when they log in, then they see an error.\n\n## Technical detail\nSessions."}'

repo="$work/repo"
git init -q -b main "$repo"
mkdir -p "$repo/.claude" "$repo/docs/specs"
printf -- '---\nid: 0003\nstatus: accepted\n---\n' >"$repo/docs/specs/0003-login.md"
git -C "$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "chore: start"

context() { # dir -> $out; fails the test on a non-zero exit
  (cd "$1" && "$cli" context) >"$work/out" 2>"$work/err" || fail "context exited non-zero in $1: $(cat "$work/err")"
  out=$(cat "$work/out")
}

context "$work"
grep -q "senior-mode" <<<"$out" || fail "no router outside a repository: $out"
grep -q "Current ticket" <<<"$out" && fail "ticket outside a repository"

git -C "$repo" switch -q -c feat/12-login
context "$repo"
grep -q "/senior-mode:setup" <<<"$out" || fail "no setup hint without config: $out"
grep -q "Current ticket" <<<"$out" && fail "ticket without config: $out"

echo '{}' >"$repo/.claude/senior-mode.json"
git -C "$repo" switch -q main
: >"$GH_LOG"
context "$repo"
grep -q "Current ticket" <<<"$out" && fail "ticket on the default branch: $out"
[ -s "$GH_LOG" ] && fail "calls GitHub on the default branch"

git -C "$repo" switch -q feat/12-login
context "$repo"
for want in "#12 Let people log in" "In progress" "docs/specs/0003-login.md (accepted)" \
  "Given a user with an account" "Given a wrong password" "feat/12-login"; do
  grep -qF "$want" <<<"$out" || fail "missing '$want' in: $out"
done
grep -q "setup" <<<"$out" && fail "setup hint with a config: $out"
[ "$(wc -l <<<"$out")" -le 16 ] || fail "more than 16 lines: $(wc -l <<<"$out")"

GH_FAIL=1 context "$repo"
if ! grep -q "#12" <<<"$out" || ! grep -qi "not loaded" <<<"$out"; then fail "GitHub down: $out"; fi

git -C "$repo" switch -q -c spike-oauth
context "$repo"
grep -q "Current ticket" <<<"$out" && fail "ticket on a branch without an issue number: $out"

# A run session has no human: the router says what to do instead of asking.
grep -qi "nobody answers" <<<"$out" && fail "unattended rule outside a run: $out"
SENIOR_MODE_RUN=1 context "$work"
for want in "nobody answers" "recommended option" "needs-human"; do
  grep -qF "$want" <<<"$out" || fail "run session router lacks '$want': $out"
done
SENIOR_MODE_RUN=1 context "$repo"
grep -qF "nobody answers" <<<"$out" || fail "run session rule lost on a ticket branch: $out"

[ "$failures" -eq 0 ] && echo "context: all cases pass"
exit "$failures"
