#!/usr/bin/env bash
# Tests for guard-bash.sh (PreToolUse on Bash): JSON in, decision out.
# shellcheck disable=SC2016,SC1003 # test commands hold literal $VARIABLES and backslash-quotes, not shell expansions
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
# Review of #218: an empty pair inside a word is removed, as before; alone it stays an argument.
expect deny 'git commit --no""-verify -m x'
expect deny "git commit --no''-verify -m x"
expect deny 'git push --for""ce'
expect deny 'git pu""sh --force'
expect deny 'git push origin ma""in'
expect deny 'git config core.hooks""Path x'
expect deny 'git -c core.hooks""Path=x commit -m x'
expect deny 'GIT_CONFIG_KEY_0=core.hooks""Path git commit -m x'
expect deny 'gh pr merge 3 --ad""min'
expect allow 'git commit --allow-empty-message -m ""'
expect allow 'git config user.name ""'
expect allow 'git commit -m "docs: a" -m ""'
# Review of #218: more forms of the same switches.
expect deny 'git --config-env core.hooksPath=NOHOOKS commit -m x'
expect deny 'git --config-env core.hookspath=NOHOOKS commit -m x'
expect deny 'declare -x GIT_CONFIG_KEY_0=core.hooksPath'
expect deny 'typeset -x GIT_CONFIG_KEY_0=core.hooksPath'
expect deny 'GIT_CONFIG_PARAMETERS="'"'"'core.hookspath=/dev/null'"'"'" git commit -m x'
expect deny "export GIT_CONFIG_PARAMETERS=\"'core.hooksPath'='/dev/null'\""
expect deny "env GIT_CONFIG_PARAMETERS=\"'core.hooksPath'='x'\" git push"
expect allow 'git --config-env user.name=NAME commit -m x'
expect allow "GIT_CONFIG_PARAMETERS=\"'user.name=t'\" git status"
expect allow 'declare -x FOO=1'
expect allow 'command -v git'
# An escaped quote or $'..' in a value can hide the endpoint from the value stripper: whole command read.
expect deny 'gh api -f body=it\'"'"'s -X PUT repos/a/b/pulls/5/merge'
expect deny "gh api -f body=\$'a\\'b' -X PUT repos/a/b/pulls/5/merge"
expect deny "gh api -f body=\$'x\\'y' -X PUT repos/a/b/pulls/5/merge -F z='a'"
expect deny 'gh api -f body=a\"b -X PUT repos/a/b/pulls/5/merge -f z="c"'
# Review of d7cb41a: an unquoted backslash does not hide a word of the endpoint outside a run either.
expect deny 'gh api -X PUT repos/o/r/pulls/5/me\rge'
expect deny 'gh api -X PUT repos/o/r/pu\lls/5/merge'
expect deny 'gh api repos/o/r/pulls/5/me\rge -X PUT -f merge_method=rebase'
expect allow 'gh api repos/o/r/pu\lls/5'
# Second review of #218: with odd quoting earlier on the line, a quoted or computed method is not lost.
expect deny 'gh api -f body=a\"b -X "PUT" repos/a/b/pulls/5/merge -f z="c"'
expect deny "gh api -f body=a\\\"b -X 'PUT' repos/a/b/pulls/5/merge -f z=c"
expect deny 'gh api -f body=a\"b --method "PUT" repos/a/b/pulls/5/merge -f z="c"'
expect deny 'gh api -f body=a\"b --method="PUT" repos/a/b/pulls/5/merge -f z="c"'
expect deny 'gh api -f body=a\"b -X P"UT" repos/a/b/pulls/5/merge -f z="c"'
expect deny 'gh api -f body=a\"b -X $M repos/a/b/pulls/5/merge -f z="c"'
expect deny 'gh api -f body=a\"b -X GET -X PUT repos/a/b/pulls/5/merge -f z="c"'
expect allow 'gh api -f body=a\"b -X GET repos/a/b/pulls/5/merge -f z="c"'
expect allow 'gh api -X PUT repos/a/b/issues/3/comments -f body="a note"'
# GIT_CONFIG_PARAMETERS is read normalised, and a value that is not a literal is refused.
expect deny 'GIT_CONFIG_PARAMETERS="'"'"'core.hooks""Path=/dev/null'"'"'" git commit -m x'
expect deny 'GIT_CONFIG_PARAMETERS=$X git commit -m x'
expect deny 'GIT_CONFIG_PARAMETERS="$X" git status'
expect deny 'GIT_CONFIG_PARAMETERS=$(cat p) git commit -m x'
expect deny 'export GIT_CONFIG_PARAMETERS=`cat p`'
expect deny "env GIT_CONFIG_PARAMETERS='core.hooks\\Path=x' git push"
expect allow "GIT_CONFIG_PARAMETERS=\"'user.name=t' 'user.email=t@t'\" git status"
# A backslash before an ordinary letter outside quotes is dropped by the shell: so is it here.
expect deny 'git config core.hooks\Path x'
expect deny 'git push --for\ce'
expect deny 'git commit --no-ver\ify -m x'
expect deny 'g\it push --force'
expect deny 'git pu\sh --force'
expect deny 'git -c core.hooks\Path=x commit -m x'
expect deny 'GIT_CONFIG_KEY_0=core.hooks\Path git commit -m x'
expect deny 'gh pr merge 3 --ad\min'
expect deny 'g\h alias set x y'
# Dogfooding of #218: the shell drops an unquoted backslash before any character, `=` and `+` included.
expect deny 'git -c core.hooksPath\=/dev/null commit --allow-empty -m x'
expect deny 'git -c core.hooks\Path\=/x commit -m x'
expect deny 'git c\onfig core.hooksPath /x'
expect deny 'git push origin \+main'
expect deny 'git push origin \+feat/1-shared'
expect deny 'git push --force\-with-lease'
expect deny 'git push origin ma\in'
# A value made only of escaped characters is still an argument, not nothing.
expect deny 'git config core.hooksPath \ '
expect deny 'git config core.hooksPath \"\"'
expect deny "git config core.hooksPath \\'\\'"
expect deny 'git config core.hooksPath \"'
expect deny 'git config --local core.hooksPath \ \ '
expect deny 'git -c core.hooksPath=\  commit -m x'
expect allow 'git config user.name \ '
expect allow 'git commit -m x --no-verify\ '
expect allow 'git -c\ core.hooksPath=/x commit -m x'
expect deny 'git commit -m x\" --no-verify'
expect deny 'git commit -m \"a b\" --no-verify'
expect deny "git commit -m x\\' --no-verify"
expect deny 'GIT_CONFIG_KEY_0\=core.hooksPath git commit -m x'
expect deny 'GIT_CONFIG_KEY_0=core.hooksPath\ git commit -m x'
expect deny 'gh pr merge 3 \--admin'
expect deny 'gh pr merge 3 --admin\='
expect allow 'git add my\ file'
expect allow 'git commit -m "a\\" -m "b"'
expect allow 'git commit -m "say \"hi\" --no-verify"'
expect allow "grep 'a\\.b' x"
expect allow "sed 's/\\//x/' f"
expect allow "jq '.a\\\\.b' f.json"
expect allow 'echo a\ b'
expect allow 'find . -name x -exec echo {} \;'
expect allow 'git config user.name my\ name'
expect allow 'git commit -m "a\nb"'
expect allow 'git log --format=%s\n'
expect allow 'echo a\nb'
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

# #228: git config indirections (another config file, an editor, include, alias) do not get around the switches.
expect deny 'GIT_CONFIG_GLOBAL=/tmp/g git commit -m x'
expect deny 'GIT_CONFIG_SYSTEM=/tmp/s git commit -m x'
expect deny 'GIT_CONFIG_GLOBAL=/dev/null git commit -m x'
expect deny 'export GIT_CONFIG_GLOBAL=/tmp/g'
expect deny 'declare -x GIT_CONFIG_SYSTEM=/tmp/s'
expect deny 'env GIT_CONFIG_GLOBAL=/tmp/g git commit -m x'
expect deny 'GIT_CONFIG_GLOBA\L=/tmp/g git commit -m x'
expect deny 'GIT_CONFIG_GLOBAL=/tmp/g gh pr view 3'
expect allow 'GIT_AUTHOR_NAME=t git commit -m x'
expect allow 'echo GIT_CONFIG_GLOBAL'
expect deny 'git config --edit'
expect deny 'git config -e'
expect deny 'git config --global --edit'
expect deny 'git config --local -e'
expect deny 'GIT_EDITOR="sed -i s/a/b/" git config --edit'
expect deny 'git config --file /tmp/c core.hooksPath /x'
expect deny 'git config -f /tmp/c core.hooksPath /x'
expect deny 'git config --file=/tmp/c core.hooksPath /x'
expect deny 'git config --file /tmp/c --add core.hooksPath /x'
expect deny 'git config --file /tmp/c include.path /x'
expect allow 'git config --file .gitmodules submodule.x.url y'
expect allow 'git config -f /tmp/c user.name t'
expect allow 'git config --list --show-origin'
expect deny 'git config include.path /tmp/x'
expect deny 'git config --local include.path ../x'
expect deny 'git config --add include.path x'
expect deny 'git config --global include.path x'
expect deny 'git config includeIf.gitdir:/w/.path /tmp/x'
expect deny 'git config "includeIf.gitdir:/w/.path" /tmp/x'
expect deny 'git config includeif.onbranch:main.path x'
expect deny 'git -c include.path=/tmp/x commit -m x'
expect deny 'git -c includeIf.gitdir:/w/.path=/tmp/x commit -m x'
expect deny 'git --config-env include.path=INC commit -m x'
expect deny 'GIT_CONFIG_KEY_0=include.path git status'
expect deny 'git config inc\lude.path /tmp/x'
expect allow 'git config include.path'
expect allow 'git config --get include.path'
expect allow 'git config --get-all include.path'
expect allow 'git config includeIf.gitdir:/w/.path'
expect deny 'git config alias.ci "commit --no-verify"'
expect deny 'git config alias.pf "push --force"'
expect deny 'git config alias.pf "push --force-with-lease"'
expect deny "git config alias.x '!git push --force'"
expect deny 'git config alias.h "config core.hooksPath /x"'
expect deny 'git config --global alias.ci "commit --no-verify"'
expect deny 'git config --add alias.ci "commit --no-verify"'
expect deny 'git -c alias.ci="commit --no-verify" ci -m x'
expect deny 'git -c alias.pf="push --force" pf'
expect deny 'GIT_CONFIG_KEY_0=alias.ci GIT_CONFIG_VALUE_0="commit --no-verify" git ci -m x'
expect allow 'git config alias.co checkout'
expect allow 'git config alias.st "status -sb"'
expect allow 'git config --global alias.lg "log --oneline --graph"'
expect allow 'git config alias.ci'
expect allow 'git config --get alias.ci'
expect allow 'git -c alias.st=status st'
expect allow 'git config user.name "a b"'
# #228: a word split by a variable, and a gh api endpoint that is only a variable.
expect deny 'git push --for${x}ce'
expect deny 'git push --for"$x"ce'
expect deny 'git commit --no${x}-verify -m x'
expect deny 'git commit --no"$x"-verify -m x'
expect deny 'git pu${x}sh origin main'
expect deny 'git pu"$x"sh origin main'
expect deny 'git -c core.hooksPath=/dev/null co${x}mmit -m x'
expect deny 'git push --force-with${x}-lease'
expect deny 'gh pr merge 3 --ad${x}min'
expect deny 'gh pr merge 3 --ad"$x"min'
expect allow 'git log --since=$D'
expect allow 'git commit -m "$msg"'
expect allow 'git commit --author=$A -m x'
expect allow 'git checkout -b feat/$n'
expect allow 'git log --format="%h $x"'
expect allow 'git push origin HEAD:$BRANCH'
expect allow 'git log -S"a b" --oneline'
expect allow 'git commit --message="a b"'
expect allow 'git diff --stat=$w'
expect allow 'git log --grep="a b" -n$N'
expect allow 'git $sub'
expect allow 'gh pr view $N --json "title"'
expect allow 'gh pr merge $N --rebase'
expect deny 'gh api -X PUT $EP'
expect deny 'gh api -X PUT "$EP"'
expect deny 'gh api -X PUT ${EP} -f merge_method=rebase'
expect deny 'gh api $EP -f merge_method=rebase'
expect deny 'gh api -X POST "$EP" --input r.json'
expect deny 'gh api -H "Accept: x" -X PUT $EP'
expect deny 'gh api --method PATCH "${EP}"'
expect deny 'gh api -X PUT $A$B'
expect deny 'cd x && gh api -X PUT "$EP"; echo done'
expect allow 'gh api $EP'
expect allow 'gh api "$EP" --jq .name'
expect allow 'gh api -X GET $EP'
expect allow 'gh api -X POST repos/$R/issues/5/comments -f body=x'
expect allow 'gh api -X POST "repos/$R/issues/$N/comments" -f body="x"'
expect allow 'gh api -X PATCH repos/a/b/issues/5 -f state=closed -H "X-Y: $Z"'
expect allow 'gh api repos/$REPO/pulls --jq .'
expect allow 'gh api repos/${REPO}/pulls'
expect allow 'gh api orgs/$ORG/repos --paginate'
expect allow 'gh api repos/o/r/pulls/$N'
expect allow 'gh api repos/o/r/commits/$SHA/status'
expect allow 'gh api repos/$R/statuses/$SHA -f state=success -f context=senior-mode/review -f description=ok'
expect allow 'gh api repos/$R/issues/5/comments -X POST -f body=x'
expect allow 'gh api -X POST repos/$R/issues/5/comments -f body=x'
expect allow 'gh api --method POST repos/$R/issues/5/comments -f body=x'
expect allow 'gh api --method=POST repos/$R/issues/5/comments -f body=x'
expect allow 'gh api -H "Accept: x" -X PATCH repos/$R/issues/$N -f state=closed'
expect allow 'gh api repos/$R/issues/$N/labels --input l.json'
expect allow 'gh pr view $N --json title'
expect allow 'gh api repos/a/b/issues -f title=x --jq ".[]"; echo $x'
expect allow 'gh api -X PUT repos/a/b/issues/5/lock -f lock_reason=$R'
# #228: a `;`, a `|`, a `)` or a redirection right after `merge` does not hide the merge endpoint.
expect deny 'gh api -X PUT repos/o/r/pulls/5/merge;'
expect deny 'gh api -X PUT repos/o/r/pulls/5/merge; echo done'
expect deny 'gh api -X PUT repos/o/r/pulls/5/merge|cat'
expect deny '(gh api -X PUT repos/o/r/pulls/5/merge)'
expect deny 'gh api -X PUT repos/o/r/pulls/5/merge\;'
expect deny 'gh api -X PUT repos/o/r/pulls/5/merge&& echo ok'
expect deny 'gh api -X PUT repos/o/r/pulls/5/merge>out'
expect allow 'gh api -X PUT repos/o/r/pulls/5/mergeable'
expect allow 'gh api repos/o/r/pulls/5/merge;'
# #228: GIT_CONFIG_PARAMETERS holding a space followed by something that cannot be read.
expect deny "GIT_CONFIG_PARAMETERS=\"'user.name=a b' \$X\" git status"
expect deny "GIT_CONFIG_PARAMETERS=\"'user.name=a b' \$(cat p)\" git commit -m x"
expect deny "GIT_CONFIG_PARAMETERS='user.name=a b'\$X git status"
expect deny "export GIT_CONFIG_PARAMETERS=\"'a=b c' \\\$X\""
expect allow "GIT_CONFIG_PARAMETERS=\"'user.name=a b' 'user.email=t@t'\" git status"
expect deny "GIT_CONFIG_PARAMETERS=\"'alias.x=commit --no-verify'\" git x"
expect deny "GIT_CONFIG_PARAMETERS=\"'alias.pf=push --force'\" git pf"
expect deny "GIT_CONFIG_PARAMETERS=\"'alias.x=!git push --force'\" git x"
expect deny "GIT_CONFIG_PARAMETERS=\"'alias.h=config core.hooksPath /x'\" git h"
expect deny "export GIT_CONFIG_PARAMETERS=\"'alias.x=commit --no-verify'\""
expect deny "env GIT_CONFIG_PARAMETERS=\"'user.name=a' 'alias.x=commit --no-verify'\" git x"
expect allow "GIT_CONFIG_PARAMETERS=\"'alias.co=checkout'\" git co main"
expect allow "GIT_CONFIG_PARAMETERS=\"'alias.st=status -sb'\" git st"

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
# Review of d7cb41a: an unquoted backslash does not hide a word of the endpoint or a mutation name.
expect deny 'gh api repos/o/r/pulls/5/me\rge -X PUT'
expect deny 'gh api -X PUT repos/o/r/pu\lls/5/merge'
expect deny 'gh api -X PUT repos/o/r/rule\sets/1 -f enforcement=disabled'
expect deny 'gh api repos/o/r/rul\esets -f name=x'
expect deny 'gh api -X DELETE repos/o/r/branches/main/prot\ection'
expect deny 'gh api graphql -f query=merge\PullRequest'
expect deny 'gh api graphql -f query=enable\PullRequestAutoMerge'
expect deny 'gh api graphql -f query=createRepository\Ruleset'
expect deny 'gh api graphql -f query=deleteBranch\ProtectionRule'
expect allow 'gh api repos/o/r/pu\lls/5'
expect allow 'gh api -X GET repos/o/r/rule\sets'
# Second review of #218: an odd quoting plus a quoted or computed method is still a write.
expect deny 'gh api -f body=a\"b --method "POST" repos/a/b/rulesets -f z="c"'
expect deny 'gh api -f body=a\"b -X $M repos/a/b/rulesets/1 -f z="c"'
expect allow 'gh api -f body=a\"b --method GET repos/a/b/rulesets'
# Review of #218: the stripped copy only excuses plain quoting; a backslash or $'..' makes the whole
# command count (a false positive beats a bypass), and so does a command substitution that names the path.
expect deny "gh api -f body=\$'x\\'y' repos/a/b/rulesets -X POST -f z='a'"
expect deny 'gh api -f body=a\"b repos/a/b/rulesets -X POST -f z="c"'
expect deny "gh api -f body=\$'x\\'y' repos/a/b/pulls/5/merge -X PUT -f z='a'"
expect deny 'gh api -f body=a\"b repos/a/b/pulls/5/merge -X PUT -f z="c"'
expect deny 'gh api -f body="a \" b" repos/a/b/rulesets -X POST'
expect deny 'gh api -f body="x \" y" -F z="/rulesets/" -X POST repos/a/b/rulesets'
expect deny "gh api -f body=\$'a\\'b' -X PUT repos/a/b/rulesets/1"
expect deny 'gh api -f body=it\'"'"'s -X PUT repos/a/b/rulesets/1'
expect deny 'gh api -f body=it\'"'"'s -X PUT repos/a/b/pulls/5/merge'
expect deny 'gh api -f body="$(cat n.md)" -X PUT repos/a/b/rulesets/1'
expect deny "gh api -f body=\$'it\\'s' repos/a/b/merges -f base=main"
expect deny 'gh api -f body="$(echo /rulesets/)" -X POST repos/a/b/rulesets'
expect allow 'gh api repos/a/b/issues/5/comments -f body="$(cat n.md)"'
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
# #228: a variable endpoint is a write in a run too; a read with a backslash in a filter is a read.
expect deny 'gh api -X PUT $EP'
expect deny 'gh api -X PATCH "$EP" -f enforcement=disabled'
expect deny 'gh api -X PUT repos/o/r/pulls/5/merge;'
expect deny 'gh api -X DELETE repos/o/r/rulesets/1;'
expect deny 'gh api -X POST repos/o/r/rulesets;'
expect deny 'gh api -X POST repos/o/r/rulesets|cat'
expect allow 'gh api repos/o/r/rulesets;'
expect deny 'gh api repos/o/r/rulesets --jq x\.y -f name=x'
expect deny 'gh api repos/o/r/rulesets --jq x\.y -X POST'
expect deny 'gh api repos/o/r/rulesets --jq x\.y --input r.json'
expect allow 'gh api repos/o/r/rulesets --jq '"'"'.[].name | test("a\\.b")'"'"
expect allow 'gh api repos/o/r/branches/main/protection --jq '"'"'.url | sub("\\.";"")'"'"
expect allow 'gh api repos/o/r/rulesets --jq x\.y -X GET'
expect allow 'gh api $EP'
expect allow 'gh api repos/$REPO/pulls --jq .'
expect allow 'gh api repos/${REPO}/pulls'
expect allow 'gh api orgs/$ORG/repos --paginate'
expect allow 'gh api repos/o/r/pulls/$N'
expect allow 'gh api repos/o/r/commits/$SHA/status'
expect allow 'gh api repos/$R/statuses/$SHA -f state=success -f context=senior-mode/review -f description=ok'
expect allow 'gh api repos/$R/issues/5/comments -X POST -f body=x'
expect allow 'gh api -X POST repos/$R/issues/5/comments -f body=x'
expect allow 'gh api --method POST repos/$R/issues/5/comments -f body=x'
expect allow 'gh api --method=POST repos/$R/issues/5/comments -f body=x'
expect allow 'gh api -H "Accept: x" -X PATCH repos/$R/issues/$N -f state=closed'
expect allow 'gh api repos/$R/issues/$N/labels --input l.json'
expect allow 'gh pr view $N --json title'
unset SENIOR_MODE_RUN

git -C "$repo" switch -q feat/2-local

# #235: git accepts an unambiguous abbreviation of a long option, so a prefix of a denied option is denied.
# (gh does not: `gh pr merge --admi` is "unknown flag", so a prefix of --admin is left alone.)
for o in --no-v --no-ve --no-ver --no-veri --no-verif; do
  expect deny "git commit $o -m x"
  expect deny "git push $o origin feat/2-local"
  expect deny "git rebase $o main"
  expect deny "git merge $o feat/1-shared"
  expect deny "git am $o p.mbox"
done
for o in --for --forc --force-w --force-wi --force-with --force-with-lea --force-with-lease=x --force-i --force-if --force-if-incl --force-if-include; do
  expect deny "git push $o"
  expect deny "git push origin $o feat/2-local"
done
for o in --al --all --mir --mirr --mirror --b --bra --branches; do
  expect deny "git push $o origin"
done
for o in --h --ha --har; do
  expect deny "git reset $o origin/main" main
  expect deny "git reset $o HEAD~1" feat/1-shared
  expect allow "git reset $o HEAD~1" feat/2-local
done
expect deny 'git config --ed'
expect deny 'git config --edi'
expect deny 'git config --unset-a core.hooksPath'
expect deny 'git config --unset-al core.hooksPath'
expect deny 'git config --rep core.hooksPath x'
expect deny 'git config --replace-a core.hooksPath x'
expect deny 'git config --a core.hooksPath x'
expect deny 'git config --ad core.hooksPath x'
expect deny 'git config alias.ci "commit --no-verif"'
expect deny 'git config alias.pf "push --forc"'
expect deny 'git config alias.pf "push --force-w"'
expect deny 'git -c alias.ci="commit --no-ver" ci -m x'
expect deny "GIT_CONFIG_PARAMETERS=\"'alias.pf=push --force-with'\" git pf"
expect deny 'git push --forc=x'
expect deny 'git push --for""c'
expect deny 'git push --f""orc'
expect allow 'git log --no-merges'
expect allow 'git log --no-merges --oneline -3'
expect allow 'git commit --no-edit --amend'
expect allow 'git commit --no-post-rewrite -m x'
expect allow 'git push --follow-tags'
expect allow 'git push --follow-tags origin feat/2-local'
expect allow 'git fetch --no-tags'
expect allow 'git fetch --no-recurse-submodules --no-tags origin'
expect allow 'git rebase --no-autosquash main'
expect allow 'git rebase --no-rebase-merges main'
expect allow 'git merge --no-verify-signatures feat/1-shared'
expect allow 'git pull --no-verify-signatures'
expect allow 'git merge --no-commit --no-ff feat/1-shared'
expect allow 'git push --no-thin'
expect allow 'git push --atomic origin feat/2-local'
expect allow 'git push --tags'
expect allow 'git push --set-upstream origin feat/2-local'
expect allow 'git push --delete origin feat/9-x'
expect allow 'git push --dry-run --verbose origin feat/2-local'
expect allow 'git push --prune --porcelain origin'
expect allow 'git branch --force feat/3 HEAD'
expect allow 'git worktree remove --force ../w'
expect allow 'git checkout --force feat/2-local'
expect allow 'git log --format=%s --for-each-ref'
expect allow 'git diff --formatx'
expect allow 'git reset --soft HEAD~1'
expect allow 'git reset --mixed HEAD~1'
expect allow 'git reset --keep HEAD~1'
expect allow 'git reset --merge'
expect allow 'git config --get-all user.name'
expect allow 'git config --list'
expect allow 'git config --global --unset user.name'
expect allow 'git config --add user.x y'
expect allow 'git config --unset-all user.x'
expect allow 'git config --replace-all user.x y'
expect allow 'git config --get-regexp "alias.*"'
expect allow 'git config alias.nm "log --no-merges"'
expect allow 'git config alias.ft "fetch --no-tags"'
expect allow 'git config alias.fmt "log --format=%s"'
expect allow 'git config alias.ft "push --follow-tags"'
expect allow 'gh pr merge 3 --squash --delete-branch'
expect allow 'gh pr merge 3 --admi'
expect allow 'gh pr create --draf'
# #235: a variable that splits a guarded config key hides it; a variable that is a whole key part is a value the
# guard does not follow, as before.
expect deny 'git config core.hooks${x}Path /dev/null'
expect deny 'git config core.hooks$xPath /dev/null'
expect deny 'git config core.hooks"$x"Path /dev/null'
expect deny 'git config "core.hooks${x}Path" /dev/null'
expect deny 'git config co${x}re.hooksPath /dev/null'
expect deny 'git config --local core.h${x}ooksPath .nohooks'
expect deny 'git config --unset core.hooks${x}Path'
expect deny 'git config include${x}.path /tmp/x'
expect deny 'git -c core.hooks${x}Path=/dev/null commit -m x'
expect deny 'git -c "core.hooks${x}Path=/dev/null" commit -m x'
expect deny 'git --config-env core.hooks${x}Path=V commit -m x'
expect deny 'git --config-env=core.hooks${x}Path=V commit -m x'
expect deny 'GIT_CONFIG_KEY_0=core.hooks${x}Path git commit -m x'
expect deny 'GIT_CONFIG_KEY_0="core.hooks${x}Path" git commit -m x'
expect deny 'export GIT_CONFIG_KEY_0=core.hooks${x}Path'
expect allow 'git config core.hooks${x}Path'
expect allow 'git config --get core.hooks${x}Path'
expect allow 'git config core.$k v'
expect allow 'git config $s.hooksPath v'
expect allow 'git config "$key" v'
expect allow 'git config user.na${m}e x'
expect allow 'git config include.$x y'
expect allow 'git -c user.${f}=x commit -m x'
expect allow 'git -c "user.$f=x" commit -m x'
expect allow 'git --config-env user.${f}=V commit -m x'
expect allow 'GIT_CONFIG_KEY_0=user.${f} git status'
expect allow 'git commit -m "fix $x"'
expect allow 'git commit -m "feat/$n-x" --allow-empty'
expect allow 'git checkout -b "feat/$n-x"'
expect allow 'git log --grep="a$x"'

reason=$(jq -r '.hookSpecificOutput.permissionDecisionReason' \
  <<<"$(jq -nc --arg d "$repo" '{tool_input: {command: "git push --force"}, cwd: $d}' | "$hook")")
grep -qi force <<<"$reason" || fail "deny reason does not name the rule: $reason"
reason=$(jq -r '.hookSpecificOutput.permissionDecisionReason' \
  <<<"$(jq -nc --arg d "$repo" '{tool_input: {command: "gh pr merge 3 --admin"}, cwd: $d}' | "$hook")")
grep -qi human <<<"$reason" || fail "admin merge reason does not say a human must do it: $reason"

[ "$failures" -eq 0 ] && echo "guard-bash: all cases pass"
exit "$failures"
