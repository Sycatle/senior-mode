#!/usr/bin/env bash
# Tests for guard-bash.sh (PreToolUse on Bash): JSON in, decision out.
set -u
hook=$(cd "$(dirname "$0")/.." && pwd)/guard-bash.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

g() { git -C "$repo" -c user.name=t -c user.email=t@t "$@" >/dev/null 2>&1 || echo "setup failed: git $*"; }
repo="$work/repo"
git init -q --bare "$work/origin.git"
git init -q -b main "$repo"
g remote add origin "$work/origin.git"
g commit --allow-empty -m "chore: start"
g push origin main
git -C "$repo" remote set-head origin main
g switch -c feat/1-shared && g push -u origin feat/1-shared
g switch -c feat/2-local

decide() { # command [cwd] -> deny or allow
  out=$(jq -nc --arg c "$1" --arg d "${2:-$repo}" \
    '{hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: $c}, cwd: $d}' | "$hook")
  if [ "$(jq -r '.hookSpecificOutput.permissionDecision // empty' <<<"$out" 2>/dev/null)" = deny ]; then
    echo deny
  else
    echo allow
  fi
}
expect() { # decision command [branch] [cwd]
  [ -n "${3:-}" ] && git -C "$repo" switch -q "$3"
  got=$(decide "$2" "${4:-}")
  [ "$got" = "$1" ] || fail "$2 (on ${3:-feat/2-local}): expected $1, got $got"
}

expect deny 'git commit --no-verify -m "feat: x"'
expect deny 'git commit -nm "feat: x"'
expect deny 'git push --no-verify -u origin feat/2-local'
expect deny 'git -c core.hooksPath=/dev/null commit -m "feat: x"'
expect deny 'git push --force origin feat/1-shared'
expect deny 'git push -f'
expect deny 'git push --force-with-lease'
expect deny 'git push origin +feat/1-shared'
expect deny 'git push origin main'
expect deny 'git push -u origin HEAD:refs/heads/main'
expect deny 'git push origin --delete main'
expect deny 'git push --all origin'
expect deny 'git push' main
expect deny 'git push origin HEAD' main
expect deny 'git reset --hard origin/main' main
expect deny 'git reset --hard HEAD~1' feat/1-shared
expect deny 'npm test && FOO=1 git push --force; echo done'
expect deny "git -C $repo push origin main" feat/2-local "$work"
expect deny 'gh pr merge 3 --rebase --admin'
expect deny 'gh pr merge --admin 3 --rebase'
expect deny 'GH_REPO=a/b gh -R a/b pr merge 3 --admin; echo done'
expect deny '/usr/bin/gh pr merge 3 --admin=true'

expect allow 'git status' feat/2-local
expect allow 'git push -u origin feat/2-local'
expect allow 'git push' feat/1-shared
expect allow 'git commit -m "docs: explain why --no-verify and -n are denied"'
expect allow 'git log -n 5 --format=%s'
expect allow 'git reset --hard HEAD~1' feat/2-local
expect allow 'git reset --soft HEAD~1' main
expect allow 'echo git push --force'
expect allow 'gh pr merge 3 --rebase --delete-branch'
expect allow 'gh pr comment 3 --body "merge with --admin is for humans"'
expect allow 'gh pr view 3 --admin'

git -C "$repo" switch -q feat/2-local
reason=$(jq -r '.hookSpecificOutput.permissionDecisionReason' \
  <<<"$(jq -nc --arg d "$repo" '{tool_input: {command: "git push --force"}, cwd: $d}' | "$hook")")
grep -qi force <<<"$reason" || fail "deny reason does not name the rule: $reason"
reason=$(jq -r '.hookSpecificOutput.permissionDecisionReason' \
  <<<"$(jq -nc --arg d "$repo" '{tool_input: {command: "gh pr merge 3 --admin"}, cwd: $d}' | "$hook")")
grep -qi human <<<"$reason" || fail "admin merge reason does not say a human must do it: $reason"

[ "$failures" -eq 0 ] && echo "guard-bash: all cases pass"
exit "$failures"
