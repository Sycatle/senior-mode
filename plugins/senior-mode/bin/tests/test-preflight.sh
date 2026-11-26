#!/usr/bin/env bash
# Tests for `senior-mode preflight <issue>...` (#632): gh, push and declared tools, checked before a session works.
# Offline: gh is a stub; origin is a local bare repository reached through an insteadOf rewrite of the GitHub URL.
set -u
cli=$(cd "$(dirname "$0")/.." && pwd)/senior-mode
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

mkdir -p "$work/stub"
cat >"$work/stub/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "auth status") [ -z "${GH_AUTH_FAIL:-}" ] || { echo "You are not logged into any GitHub hosts. To log in, run: gh auth login" >&2; exit 1; }
    echo "Logged in" ;;
  "issue view "*) echo "${GH_BODY:-}" ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$work/stub/gh"
export PATH="$work/stub:$PATH" SENIOR_MODE_RETRY_DELAY=0
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

git init -q --bare -b main "$work/origin.git"
repo="$work/app"
git init -q -b main "$repo"
git -C "$repo" remote add origin git@github.com:acme/app.git
git -C "$repo" config url."$work/origin.git".insteadOf git@github.com:acme/app.git
git -C "$repo" commit -q --allow-empty -m "chore: start"
git -C "$repo" push -q origin main
git -C "$repo" switch -q -c feat/7-thing
out="$work/outcome"

pre() {
  rm -f "$out"
  (cd "$repo" && SENIOR_MODE_RUN_OUTCOME=$out "$cli" preflight "$@") >"$work/out" 2>"$work/err"
}

# A: everything is there.
GH_BODY=$'## Acceptance criteria\n\n- Given a\n\nNeeds: sh, git\n' pre 7 || fail "A: a healthy environment fails: $(cat "$work/out" "$work/err")"
grep -qx 'preflight ok' "$work/out" || fail "A: no ok: $(cat "$work/out")"
[ ! -e "$out" ] || fail "A: an outcome was written on success"

# B: gh cannot authenticate: the outcome says so, at once.
GH_AUTH_FAIL=1 pre 7 && fail "B: preflight passed without gh"
grep -qx 'failed: environment: gh cannot authenticate: You are not logged into any GitHub hosts.*' "$out" || fail "B: outcome: $(cat "$out" 2>&1)"
grep -q '^failed: environment: gh cannot authenticate' "$work/out" || fail "B: not printed: $(cat "$work/out")"

# C: the push is refused.
git -C "$repo" config url."$work/missing.git".insteadOf git@github.com:acme/app.git
git -C "$repo" config --unset url."$work/origin.git".insteadOf
pre 7 && fail "C: preflight passed with an unreachable origin"
grep -q '^failed: environment: git push to origin is refused for feat/7-thing' "$out" || fail "C: outcome: $(cat "$out" 2>&1)"
git -C "$repo" config --unset url."$work/missing.git".insteadOf
git -C "$repo" config url."$work/origin.git".insteadOf git@github.com:acme/app.git

# D: a declared tool is missing.
GH_BODY=$'Needs: git-filter-repo-632, sh\n' pre 7 && fail "D: preflight passed with a missing tool"
grep -qx 'failed: environment: the tool git-filter-repo-632, declared by #7 (Needs:), is not installed' "$out" || fail "D: outcome: $(cat "$out" 2>&1)"

# E: a batch gets a line per ticket.
GH_BODY=$'Needs: nope-632\n' pre 7 8 && fail "E: batch passed with a missing tool"
[ "$(grep -c '^#[78] failed: environment: the tool nope-632' "$out")" -eq 2 ] || fail "E: batch outcome: $(cat "$out" 2>&1)"

# F: an issue number is required.
pre && fail "F: no issue accepted"
pre abc && fail "F: abc accepted"

[ "$failures" -eq 0 ] && echo "preflight: all cases pass"
exit "$((failures > 0))"
