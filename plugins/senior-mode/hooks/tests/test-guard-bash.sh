#!/usr/bin/env bash
# Tests for guard-bash.sh (PreToolUse on Bash): JSON in, decision out.
# shellcheck disable=SC2016 # test commands hold literal $VARIABLES, not shell expansions
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
expect deny 'gh pr --repo a/b merge 3 --admin'
expect deny $'gh pr merge 3 \\\n  --rebase \\\n  --admin'
expect deny $'git push \\\n  --force'
expect deny 'gh api -X PUT repos/a/b/pulls/3/merge -f merge_method=rebase'
expect deny 'gh api --method=PUT repos/a/b/pulls/3/merge'
expect deny 'gh api -X PUT "repos/a/b/pulls/3/merge"'
expect deny "gh pr merge 3 '--admin'"
expect allow 'gh api repos/a/b/pulls/3/merge'
# #116: hooks cannot be switched off through git config, and a variable does not hide the merge endpoint.
expect deny 'git config core.hooksPath /dev/null'
expect deny 'git config --local core.hooksPath .nohooks'
expect deny 'git -C . config --global core.hooksPath x'
expect deny 'git config --unset core.hooksPath'
expect deny 'git config --replace-all core.hookspath x'
expect deny 'gh api -X PUT repos/a/b/pulls/$PR/merge'
expect deny 'gh api -X PUT "repos/$R/pulls/$PR/merge" -f merge_method=rebase'
expect deny 'gh api --method put repos/a/b/pulls/3/merge'
# #194: an empty value, the environment form of the same setting and an alias do not get around it.
expect deny 'git config core.hooksPath ""'
expect deny "git config core.hooksPath ''"
expect deny 'git config --local core.hooksPath ""'
expect deny 'git config --worktree core.hooksPath .nohooks'
expect deny 'git -c core.hookspath=/dev/null commit -m x'
expect deny 'git --config-env=core.hooksPath=NOHOOKS commit -m x'
expect deny 'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null git commit -m x'
expect deny 'GIT_CONFIG_KEY_0=core.hookspath git commit -m x'
expect deny 'GIT_CONFIG_KEY_12="core.hooksPath" git push'
expect deny 'export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null'
expect deny 'env GIT_CONFIG_KEY_0=core.hooksPath git commit -m x'
expect deny 'gh alias set pm "pr merge --admin"'
expect deny 'gh alias set --shell force "!git push --force"'
expect deny 'gh alias import aliases.yml'
expect deny 'sudo gh pr merge 3 --admin'
expect deny 'env gh pr merge 3 --admin'
expect deny 'env -u FOO gh pr merge 3 --admin'
expect deny 'echo 3 | xargs gh pr merge --admin'
expect deny 'xargs -n1 git push --force'
expect deny 'sudo -u nobody git push --force'
expect allow 'GIT_CONFIG_KEY_0=user.name GIT_CONFIG_VALUE_0=t git commit -m x'
expect allow 'GIT_CONFIG_COUNT=0 git status'
expect allow 'git config user.name ""'
expect allow 'git config --get core.hooksPath'
expect allow 'git -c user.name=t commit -m x'
expect allow 'gh alias list'
expect allow 'env FOO=1 git status'
expect allow 'sudo apt install git gh'
expect allow 'echo 3 | xargs gh pr view'
expect allow 'gh api -X PUT repos/a/b/issues/3/comments -f body="see pulls/3/merge"'
expect allow 'git config core.hooksPath'
expect allow 'git config user.name t'
expect allow 'gh api -X PUT repos/a/b/rulesets/1 --input r.json'

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

# In a run session nothing merges: senior-mode run merges after its own checks.
export SENIOR_MODE_RUN=1
expect deny 'gh pr merge 5 --rebase'
expect deny 'gh pr merge 5 --squash --auto'
expect deny 'gh -R a/b pr merge 5'
expect deny 'gh api repos/a/b/pulls/5/merge -X PUT'
expect deny 'gh api repos/a/b/merges -f base=main -f head=feat/x'
expect deny "gh api graphql -f query='mutation { mergePullRequest(input: {pullRequestId: \"x\"}) { clientMutationId } }'"
expect deny "gh api graphql -f query='mutation { enablePullRequestAutoMerge(input: {pullRequestId: \"x\"}) { clientMutationId } }'"
expect deny 'env gh pr merge 5 --rebase'
expect deny 'sudo gh pr merge 5'
expect deny 'echo 5 | xargs gh pr merge --rebase'
expect deny 'xargs -I{} gh pr merge {} --squash'
expect deny 'env -i PATH=$PATH gh pr merge 5'
expect allow 'echo 5 | xargs gh pr view'
expect allow 'gh pr view 5 --json mergeable'
expect allow 'gh pr create --title "fix: merge sort" --body x'
expect allow 'gh api repos/a/b/pulls/5'
# #116: a run session cannot rewrite the rules that bound it; only `gh pr merge` is a merge.
expect deny 'gh api -X PUT repos/a/b/pulls/$PR/merge'
expect deny 'gh api -X PUT repos/a/b/rulesets/1 --input r.json'
expect deny 'gh api repos/a/b/rulesets -f name=x'
expect deny 'gh api --method PATCH "repos/$R/rulesets/$ID" -F enforcement=disabled'
expect deny 'gh api -X DELETE repos/a/b/branches/main/protection'
expect deny 'gh api repos/a/b/branches/main/protection/required_status_checks -X PATCH --input c.json'
expect deny 'gh api -X put repos/a/b/pulls/5/merge'
expect deny "gh api graphql -f query='mutation { updateRepositoryRuleset(input: {}) { clientMutationId } }'"
expect deny "gh api graphql -f query='mutation { deleteBranchProtectionRule(input: {}) { clientMutationId } }'"
# #194: only the endpoint decides, not the text of a body, a header or a jq filter.
expect deny 'gh api -f name=x -X POST repos/a/b/rulesets'
expect deny 'gh api -X PUT "repos/$R/rulesets/$ID" -f body="ok"'
expect deny 'gh api -H "X-Y: z" --method=PATCH repos/a/b/rulesets/1 --input r.json'
expect deny "gh api -X DELETE 'repos/a/b/branches/main/protection' -f note='x'"
expect allow 'gh api repos/a/b/issues/5/comments -f body="a note on /rulesets/ and /branches/main/protection"'
expect allow 'gh api -X POST repos/a/b/issues/5/comments -f body="do not touch /rulesets/1 here" -F n=1'
expect allow "gh api -X POST repos/a/b/issues -f body='fix /rulesets/' -f title=x"
expect allow 'gh api -X PATCH repos/a/b/issues/5 --field body="/rulesets/"'
expect allow 'gh api -X POST repos/a/b/issues/5/comments --raw-field body="pulls/3/merge"'
expect allow 'gh api -X POST repos/a/b/issues/5/comments --input rulesets/body.json'
expect allow 'gh api repos/a/b/rulesets'
expect allow 'gh api repos/a/b/branches/main/protection'
expect allow 'gh pr list --search merge'
expect allow 'gh pr list --search "is:open merge" --json number'
unset SENIOR_MODE_RUN

git -C "$repo" switch -q feat/2-local
reason=$(jq -r '.hookSpecificOutput.permissionDecisionReason' \
  <<<"$(jq -nc --arg d "$repo" '{tool_input: {command: "git push --force"}, cwd: $d}' | "$hook")")
grep -qi force <<<"$reason" || fail "deny reason does not name the rule: $reason"
reason=$(jq -r '.hookSpecificOutput.permissionDecisionReason' \
  <<<"$(jq -nc --arg d "$repo" '{tool_input: {command: "gh pr merge 3 --admin"}, cwd: $d}' | "$hook")")
grep -qi human <<<"$reason" || fail "admin merge reason does not say a human must do it: $reason"

[ "$failures" -eq 0 ] && echo "guard-bash: all cases pass"
exit "$failures"
