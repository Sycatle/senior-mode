#!/usr/bin/env bash
# Tests for self-protect.sh (PreToolUse on Edit, Write, MultiEdit, NotebookEdit and Bash): JSON in,
# decision out. It only acts when SENIOR_MODE_RUN=1.
# shellcheck disable=SC2016 # jq programs and test inputs in single quotes, not shell
set -u
hook=$(cd "$(dirname "$0")/.." && pwd)/self-protect.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

repo="$work/repo"
git init -q -b main "$repo"
git -C "$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "chore: start"
mkdir -p "$repo/web"
git -C "$repo" worktree add -q "$work/wt" -b feat/1-x
link=$work/link
ln -s "$repo" "$link"
bare="$work/bare"
mkdir -p "$bare"

# decide <jq filter merged into the input> [jq args] -> $verdict (allow or deny) and $reason.
decide() {
  local filter=$1 out
  shift
  out=$(jq -nc --arg d "${dir:-$repo}" "$@" "{hook_event_name: \"PreToolUse\", session_id: \"s\", cwd: \$d} $filter" |
    env -u SENIOR_MODE_RUN ${run+SENIOR_MODE_RUN="$run"} "$hook")
  reason=$(jq -r '.hookSpecificOutput.permissionDecisionReason // empty' <<<"$out" 2>/dev/null)
  verdict=allow
  [ "$(jq -r '.hookSpecificOutput.permissionDecision // empty' <<<"$out" 2>/dev/null)" = deny ] && verdict=deny
  return 0
}
edit() { # expected path [tool] [extra] [label]
  decide "+ {tool_name: \"${3:-Edit}\", tool_input: {file_path: \$p, notebook_path: \$p}} ${4:-}" --arg p "$2"
  [ "$verdict" = "$1" ] || fail "${5:-${3:-Edit} $2}: expected $1, got $verdict"
}
bash_() { # expected command [cwd]
  dir=${3:-${dir:-}} decide '+ {tool_name: "Bash", tool_input: {command: $c}}' --arg c "$2"
  [ "$verdict" = "$1" ] || fail "bash '$2'${3:+ in $3}: expected $1, got $verdict"
}

run=1

# --- Edit, Write, MultiEdit, NotebookEdit ---
edit deny "$repo/.github/workflows/ci.yml" Edit
edit deny "$repo/.github/workflows/new.yml" Write
edit deny "$repo/.claude/settings.json" MultiEdit
edit deny "$repo/.claude/senior-mode.json" Edit
# Project memory of the reviewer and architect agents is theirs to write, run or not.
edit allow "$repo/.claude/agent-memory/reviewer/MEMORY.md" Write
edit allow "$repo/.claude/agent-memory/x/notes.md" Edit
bash_ allow "echo finding >> .claude/agent-memory/reviewer/MEMORY.md"
edit deny "$repo/.claude/agent-memory/../settings.json" Write
edit deny "$repo/.claude/agent-memoryx/MEMORY.md" Write
edit deny "$repo/.githooks/pre-push" Edit
edit deny "$repo/.claude/n.ipynb" NotebookEdit
edit deny ".github/workflows/ci.yml" Edit "" "relative path from the repository root"
edit deny "$repo/src/../.claude/settings.json" Edit "" "a .. segment does not hide the target"
edit deny "$repo/./.githooks/./pre-push" Edit "" "a . segment does not hide the target"
edit deny "$repo/.github/workflows/ci.yml" Edit '+ {agent_id: "a1", agent_type: "senior-mode:implementer"}' "subagent edit"
dir=$repo/web edit deny "../.claude/settings.json" Edit "" "relative path taken from a subdirectory"
dir=$link edit deny "$link/.github/workflows/ci.yml" Edit "" "reached through a symlink"
dir=$work/wt edit deny "$work/wt/.githooks/pre-push" Edit "" "inside a linked worktree"
dir=$work/wt edit deny ".claude/settings.json" Edit "" "relative path inside a linked worktree"
# #116: the git hooks and the git config (core.hooksPath) guard the run too, worktrees included.
edit deny "$repo/.git/hooks/pre-push" Write
edit deny ".git/hooks/pre-commit" Edit "" "relative path to the git hooks"
edit deny "$repo/.git/config" Edit
dir=$work/wt edit deny "$repo/.git/hooks/pre-push" Write "" "the hooks of a linked worktree live in the common dir"
dir=$work/wt bash_ deny "cp /tmp/x $repo/.git/hooks/pre-push"
# #194: the hooks can also be switched off by their mode, by removing or filling .git, or by the
# per-worktree config (core.hooksPath under extensions.worktreeConfig).
git -C "$repo" config extensions.worktreeConfig true
edit deny "$repo/.git/config.worktree" Write "" "per-worktree config of the main checkout"
edit deny "$repo/.git/worktrees/wt/config.worktree" Write "" "per-worktree config of a linked worktree"
dir=$work/wt edit deny "$repo/.git/worktrees/wt/config.worktree" Edit "" "from inside the linked worktree"
bash_ deny "echo x > $repo/.git/config.worktree"
bash_ deny "git config --worktree core.hooksPath x > $repo/.git/worktrees/wt/config.worktree"
bash_ deny "echo exit 0 > .git/hooks/pre-push"
bash_ deny "rm .git/hooks/pre-push"
edit allow "$repo/.git-notes.md" Write "" "a name that only starts like .git"
dir=$work/wt edit deny ".claude/settings.json" Edit
grep -q "\.claude/settings.json" <<<"$reason" || fail "deny reason does not name the path: $reason"
grep -qi "human" <<<"$reason" || fail "deny reason gives no way forward: $reason"

edit allow "$repo/src/app.ts" Edit
edit allow "$repo/README.md" Write
edit allow "$repo/docs/specs/0002-login.md" Write
edit allow "$repo/.github/ISSUE_TEMPLATE/bug.yml" Edit "" "other files of .github"
edit allow "$repo/.github/pull_request_template.md" Edit
edit allow "$repo/.github/workflows-notes.md" Edit "" "a name that only starts like a protected one"
edit allow "$repo/.claudeignore" Edit
edit allow "$repo/.githooks-old/x" Edit
edit allow "$repo/web/.claude/x" Edit "" "only the root's .claude is protected"
edit allow "$work/elsewhere/.claude/x" Edit "" "outside the repository"
edit allow "../../outside/.github/workflows/x.yml" Edit "" "relative path leaving the repository"
dir=$bare edit allow "$bare/.claude/x" Edit "" "not a git repository"

# --- Bash ---
for c in \
  'echo x > .github/workflows/ci.yml' \
  'echo x >> .claude/settings.json' \
  'echo x>.claude/settings.json' \
  'echo x > ./.githooks/pre-push' \
  'echo x 2> .claude/log' \
  'echo x &> .claude/log' \
  'cat a >| .githooks/pre-push' \
  "echo x > \"$repo/.github/workflows/ci.yml\"" \
  "echo x > '.claude/settings.json'" \
  'cat <<EOF > .githooks/pre-push' \
  'echo x | tee .claude/settings.json' \
  'echo x | tee -a .github/workflows/ci.yml' \
  'cp evil.yml .github/workflows/ci.yml' \
  'cp -f evil.yml .github/workflows/' \
  'cp -t .githooks evil' \
  'mv ci.yml .github/workflows/' \
  'mv .githooks/pre-push /tmp/pre-push' \
  'rm -rf .claude' \
  'rm .githooks/pre-push' \
  'rm -rf .github' \
  'chmod -x .git/hooks/*' \
  'chmod -R a-x .git/hooks' \
  'chown nobody .git/hooks/pre-push' \
  'rm -rf .git' \
  'rm -rf .git/' \
  'rm -rf ./.git' \
  'mv .git /tmp/git-gone' \
  'cp -r x .git/' \
  'cp -r x .git' \
  'cp /tmp/c .git/config.worktree' \
  'rm -rf .git/*' \
  'rm -rf .g\it' \
  'r\m -rf .git' \
  'rm .git/hoo\ks/pre-push' \
  'echo x > .cla\ude/x' \
  'rm -rf .git\/*' \
  'rm -rf .git\/hooks' \
  'rm .githooks\/pre-push' \
  'echo x >> \.claude/settings.json' \
  'echo x > .claude/x\ ' \
  'echo x > .claude\/x' \
  'rm .git/hooks/pre-push\ ' \
  'cp x .git\/' \
  'echo "a\\" > .claude/x' \
  'echo x > .claude/x\ \"' \
  'rm -rf .git/hoo*' \
  'rm -rf .git/h?oks' \
  'sudo -u nobody rm -rf .git' \
  'env -i rm -rf .git' \
  'env -i PATH=/bin rm .git/hooks/pre-push' \
  'nice -n 5 rm -rf .git' \
  'doas rm -rf .git' \
  'echo x | xargs -n1 rm .git/hooks/pre-push' \
  'xargs rm -rf .git' \
  'time rm -rf .git' \
  'sudo -u root chmod -x .git/hooks/pre-push' \
  'sudo -u nobody tee .claude/x' \
  'unlink .claude/settings.json' \
  'touch .claude/x' \
  'truncate -s0 .claude/settings.json' \
  'install -m755 x .githooks/pre-push' \
  'ln -sf /tmp/x .githooks/pre-push' \
  "sed -i 's/a/b/' .github/workflows/ci.yml" \
  'sed -i -e s/a/b/ .claude/settings.json' \
  'sed -i.bak s/a/b/ .claude/settings.json' \
  'sed --in-place s/a/b/ .claude/settings.json' \
  "perl -pi -e 's/a/b/' .githooks/pre-push" \
  'dd if=/dev/zero of=.claude/x' \
  'git rm .github/workflows/ci.yml' \
  'git mv .githooks/pre-push x' \
  'git checkout main -- .claude/settings.json' \
  'git restore .githooks/pre-push' \
  "git -C $repo rm .claude/settings.json" \
  "echo x > $repo/.claude/settings.json" \
  'FOO=1 echo x > .claude/settings.json' \
  'ls && echo y > .claude/x' \
  'make; rm .githooks/pre-push' \
  'true || echo x > .claude/x' \
  'sudo tee .claude/x' \
  'echo x > src/../.claude/x'; do
  bash_ deny "$c"
done
bash_ deny 'echo x > ../.claude/x' "$repo/web"
bash_ deny 'echo x > .claude/x' "$work/wt"
grep -q "\.claude/x" <<<"$reason" || fail "bash deny reason does not name the path: $reason"
bash_ deny 'rm -f .git' "$work/wt"
bash_ deny 'cp -r x .git/' "$work/wt"

for c in \
  'git status' \
  'git add .github/workflows/ci.yml' \
  'git diff -- .claude/settings.json' \
  'git log -- .githooks' \
  'git checkout feat/1-x' \
  'git commit -m "ci: edit .github/workflows/ci.yml"' \
  'cat .github/workflows/ci.yml' \
  'ls -la .claude .githooks' \
  'grep -r foo .githooks .github/workflows' \
  'sed -n 1p .claude/settings.json' \
  'sed -i s/a/b/ src/app.ts' \
  'cp .claude/settings.json /tmp/settings.json' \
  'cp .githooks/pre-push src/copy' \
  'echo "write it to .claude/x"' \
  'echo "a > .claude/x"' \
  "echo 'x' > src/a.txt" \
  'echo x > /dev/null' \
  'echo x 2>&1' \
  'ls > out.txt' \
  'echo x > /tmp/.claude/y' \
  'rm -rf node_modules dist' \
  'rm -rf build' \
  'rm -rf .gitignore-old .github-old' \
  'chmod +x scripts/run.sh' \
  'chmod -x src/old.sh' \
  'chmod -R 755 src' \
  'cp -r x src/' \
  'cp .git/config /tmp/config.bak' \
  'cat .git/config.worktree' \
  'git config user.name t' \
  'rm -rf .git-old/*' \
  'echo x\y > out.txt' \
  'echo x > \".claude/x' \
  'echo x > \ ' \
  'echo "a\\" > out.txt' \
  'cat my\ file' \
  'echo x > my\ file.txt' \
  "grep 'a\\.b' src/x" \
  "sed 's/\\//x/' src/f" \
  'echo a\nb' \
  'cp .git/* /tmp/backup' \
  'ls .git/*' \
  'sudo -u nobody rm -rf build' \
  'env -i ls .git' \
  'nice -n 5 make' \
  'xargs -n1 rm build/x' \
  'doas ls' \
  'mv src/a src/b' \
  'touch .github/ISSUE_TEMPLATE/new.yml' \
  'echo x > .github/pull_request_template.md' \
  'echo x > .claudeignore' \
  'dd if=.claude/x of=/tmp/x' \
  'senior-mode check' \
  'npm test'; do
  bash_ allow "$c"
done
bash_ allow 'echo x > ../.claude/x' "$repo"
bash_ allow 'echo x > .claude/x' "$bare"

# --- Outside a run, nothing is denied ---
unset run
edit allow "$repo/.github/workflows/ci.yml" Edit "" "no SENIOR_MODE_RUN"
bash_ allow 'echo x > .claude/settings.json'
run=0
edit allow "$repo/.github/workflows/ci.yml" Edit "" "SENIOR_MODE_RUN=0"
bash_ allow 'rm -rf .githooks'
run=
edit allow "$repo/.claude/settings.json" Edit "" "empty SENIOR_MODE_RUN"
run=1

# --- Other events and tools pass through ---
decide '+ {tool_name: "Read", tool_input: {file_path: ($d + "/.claude/settings.json")}}'
[ "$verdict" = allow ] || fail "Read denied"
decide '+ {hook_event_name: "PostToolUse", tool_name: "Edit", tool_input: {file_path: ($d + "/.claude/settings.json")}}'
[ "$verdict" = allow ] || fail "another event denied"
decide '+ {tool_name: "Edit", tool_input: {}}'
[ "$verdict" = allow ] || fail "edit without a path denied"

[ "$failures" -eq 0 ] && echo "self-protect: all cases pass"
exit "$failures"
