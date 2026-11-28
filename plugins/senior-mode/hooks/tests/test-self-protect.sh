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
tw=$work/xdg/senior-mode/worktrees/repo-0a1b2c3d/2
git -C "$repo" worktree add -q "$tw" -b feat/2-y
link=$work/link
ln -s "$repo" "$link"
bare="$work/bare"
mkdir -p "$bare"

# decide <jq filter merged into the input> [jq args] -> $verdict (allow or deny) and $reason.
decide() {
  local filter=$1 out
  shift
  out=$(jq -nc --arg d "${dir:-$repo}" "$@" "{hook_event_name: \"PreToolUse\", session_id: \"s\", cwd: \$d} $filter" |
    env -u SENIOR_MODE_RUN -u SENIOR_MODE_ROLE ${run+SENIOR_MODE_RUN="$run"} ${role+SENIOR_MODE_ROLE="$role"} "$hook")
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
edit deny "$repo/.claude/senior-mode/hooks/x.sh" Edit "" "a hook of the levers directory (#739)"
edit deny "$repo/.claude/senior-mode/roles/y.md" Write "" "a role of the levers directory (#739)"
edit deny "$repo/.claude/senior-mode/overrides/z.json" MultiEdit
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
# #224: a ticket worktree lives under $XDG_DATA_HOME/senior-mode/worktrees; its files are the project's,
# so its code is editable, its guard rails are still denied, and so are the git hooks of the repository.
dir=$tw edit allow "$tw/src/app.js" Write "" "code in a worktree under the data dir"
dir=$tw edit allow "src/app.js" Edit "" "relative code path in a worktree under the data dir"
dir=$tw edit deny "$tw/.claude/settings.json" Edit "" "guard rails of a worktree under the data dir"
dir=$tw edit deny ".githooks/pre-push" Edit "" "relative guard rails of a worktree under the data dir"
dir=$tw edit deny "$repo/.git/hooks/pre-push" Write "" "the git hooks from a worktree under the data dir"
dir=$tw bash_ allow "echo x > src/app.js" "$tw"
dir=$tw bash_ deny "echo x > .github/workflows/ci.yml" "$tw"
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
edit deny "$repo/.git/refs/heads/main" Write "" "a branch ref"
edit deny "$repo/.git/objects/pack/x" Write "" "the object store"
edit deny "$repo/.git/worktrees/wt/HEAD" Write "" "the admin dir of a linked worktree"
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
  'rm -rf .git/refs' \
  'rm -rf .git/refs/' \
  'rm -rf .git/refs/heads' \
  'rm -rf .git/objects' \
  'rm -rf .git/objects/pack' \
  'rm -rf .git/worktrees' \
  'rm -rf .git/worktrees/wt' \
  'mv .git/refs /tmp/refs' \
  'rm -rf .g\it/refs' \
  'sudo rm -rf .git/objects' \
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
  'ls .git/refs .git/objects .git/worktrees' \
  'cat .git/refs/heads/main' \
  'cp .git/objects/pack/x /tmp/backup' \
  'git worktree remove ../wt' \
  'rm -rf .git-refs' \
  'rm -rf src/refs src/objects' \
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

# --- #235: HEAD, packed-refs, info/ and modules/ of the git dir; refs and objects discarded by command ---
for f in HEAD packed-refs info info/exclude info/attributes modules modules/sub modules/sub/config; do
  edit deny "$repo/.git/$f" Write "" ".git/$f"
  bash_ deny "echo x > .git/$f"
  bash_ deny "rm -rf .git/$f"
  dir=$work/wt edit deny "$repo/.git/$f" Edit "" ".git/$f from a linked worktree"
done
bash_ deny 'mv .git/packed-refs /tmp/p'
bash_ deny 'cp /tmp/h .git/HEAD'
bash_ deny 'sed -i s/a/b/ .git/info/exclude'
bash_ deny 'rm .git/HEAD' "$work/wt"
bash_ deny 'rm -rf .git/hooks' "$work/wt"
bash_ deny 'echo x > .git/info/exclude' "$work/wt"
bash_ deny "rm $repo/.git/HEAD" "$work/wt"
edit allow "$repo/.git-info/x" Write "" "a name that only starts like info"
for c in \
  'cat .git/HEAD' \
  'cat .git/packed-refs' \
  'cat .git/info/exclude' \
  'ls .git/modules' \
  'cp .git/HEAD /tmp/head' \
  'git rev-parse HEAD' \
  'git submodule update --init' \
  'echo x > src/info/y' \
  'rm -rf src/modules docs/info' \
  'rm -rf node_modules/info' \
  'echo x > HEAD.txt' \
  'rm packed-refs.bak' \
  'rm -rf .git-modules'; do
  bash_ allow "$c"
done
for c in \
  'git update-ref -d refs/heads/main' \
  'git update-ref -d refs/heads/feat/1-x' \
  'git update-ref -d refs/heads/feat/1-x abc123' \
  'git update-ref --no-deref -d refs/heads/x' \
  'git update-ref -m gone -d refs/heads/x' \
  'git update-ref -dm gone refs/heads/x' \
  'git update-ref -d HEAD' \
  'git -C . update-ref -d refs/heads/x' \
  'git -c core.x=1 update-ref -d refs/heads/x' \
  'git reflog expire --expire=now --all' \
  'git reflog expire --all && git gc --prune=now' \
  'git reflog delete HEAD@{1}' \
  'git gc --prune=now' \
  'git gc --aggressive --prune=now' \
  'git gc --prune=all' \
  'git gc --pr=now' \
  'git gc --p=now' \
  'git prune --expire=now' \
  'git prune --expire now' \
  'git prune --exp now' \
  'sudo git gc --prune=now'; do
  bash_ deny "$c"
done
bash_ deny 'git update-ref -d refs/heads/x' "$work/wt"
for c in \
  'git update-ref refs/heads/x HEAD' \
  'git update-ref -m x refs/heads/x HEAD' \
  'git update-ref -d refs/remotes/origin/x' \
  'git update-ref -d refs/tags/v0' \
  'git update-ref -d refs/stash' \
  'git reflog' \
  'git reflog show HEAD' \
  'git reflog -5' \
  'git gc' \
  'git gc --auto' \
  'git gc --prune=2.weeks.ago' \
  'git prune' \
  'git prune -n' \
  'git worktree prune' \
  'git branch -D feat/9-x' \
  'echo "git gc --prune=now"' \
  'echo "git update-ref -d refs/heads/x"'; do
  bash_ allow "$c"
done
# Review of #244: recovery operations in the git dir of a main checkout are not guarded files; a dry run discards nothing.
for c in \
  'rm .git/index.lock' \
  'rm -f .git/index.lock' \
  'rm -rf .git/rebase-merge' \
  'rm -rf .git/rebase-apply' \
  'rm .git/MERGE_HEAD' \
  'rm .git/CHERRY_PICK_HEAD' \
  'rm -rf .git/senior-mode/runs/old' \
  'echo x > .git/senior-mode/probe' \
  'git reflog expire --dry-run --all' \
  'git reflog expire --dry --all' \
  'git reflog expire --all --dry-run' \
  'git prune -n --expire=now' \
  'git prune --dry-run --expire now' \
  'git prune -nv --expire=now'; do
  bash_ allow "$c"
done
bash_ deny 'rm .git/index.lock' "$work/wt"
bash_ deny 'rm .git/HEAD'
bash_ deny 'git reflog expire --all'
# A cd earlier in the command moves where the relative paths that follow point.
for c in \
  'cd .git && rm -rf hooks' \
  'cd .git; rm hooks/pre-push' \
  'cd .git/hooks && rm pre-push' \
  'cd .git && echo x > HEAD' \
  'cd .git && echo x > info/exclude' \
  'cd .github && rm -rf workflows' \
  'cd .claude && echo x > settings.json' \
  'cd .githooks && chmod -x pre-push' \
  'cd ./.git && rm config' \
  'cd web && rm -rf ../.claude' \
  'cd web && cd .. && rm -rf .claude' \
  "cd $repo/.git && rm -rf hooks" \
  'pushd .git && rm -rf hooks'; do
  bash_ deny "$c"
done
bash_ deny 'cd .git && rm -rf hooks' "$work/wt"
for c in \
  'cd web && rm -rf node_modules' \
  'cd web && echo x > out.txt' \
  'cd .git && ls' \
  'cd .git && cat config' \
  'cd /tmp && rm -rf x' \
  'cd $dir && rm -rf x' \
  'cd && rm -rf x' \
  'cd - && ls' \
  'cd src; rm -rf build' \
  'cd web && git status'; do
  bash_ allow "$c"
done

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

# --- #191: the red tests of the test-author session are read-only for the ticket session ---
# The list of the test-author's files is <git common dir>/senior-mode/runs/<ticket>/red-tests, one path per
# line from the repository root; the ticket is read in the branch (feat/2-y is ticket 2). It acts for
# SENIOR_MODE_ROLE=ticket, in a run or not.
mkdir -p "$repo/.git/senior-mode/runs/2" "$tw/web"
printf 'tests/a.sh\nweb/tests/b.test.js\n' >"$repo/.git/senior-mode/runs/2/red-tests"
role=ticket
for run in 1 ""; do
  [ -n "$run" ] || unset run
  label=${run:+run }
  dir=$tw edit deny "$tw/tests/a.sh" Edit "" "${label}ticket edits a red test"
  dir=$tw edit deny "$tw/tests/a.sh" Write "" "${label}ticket writes a red test"
  dir=$tw edit deny "$tw/web/tests/b.test.js" MultiEdit "" "${label}ticket multi-edits a red test"
  dir=$tw edit deny "tests/a.sh" Edit "" "${label}relative path to a red test"
  dir=$tw edit deny "$tw/src/../tests/a.sh" Edit "" "${label}a .. segment does not hide a red test"
  dir=$tw/web edit deny "tests/b.test.js" Edit "" "${label}relative path from a subdirectory"
  dir=$tw edit deny "$repo/.git/senior-mode/runs/2/red-tests" Write "" "${label}the list itself"
  dir=$tw edit allow "$tw/tests/new.sh" Write "" "${label}a new test of the implementer"
  dir=$tw edit allow "$tw/tests/a.sh.md" Edit "" "${label}a name that only starts like a red test"
  dir=$tw edit allow "$tw/src/app.js" Edit "" "${label}code"
  for c in 'echo x >> tests/a.sh' 'echo x > tests/a.sh' 'rm tests/a.sh' 'rm -f web/tests/b.test.js' 'mv tests/a.sh /tmp/a.sh'
    do dir=$tw bash_ deny "$c" "$tw"; done
  for c in 'mv /tmp/x tests/a.sh' 'cp /tmp/x tests/a.sh' 'sed -i s/a/b/ tests/a.sh' 'git rm tests/a.sh' 'git mv tests/a.sh tests/c.sh' \
    'git checkout HEAD~1 -- tests/a.sh' 'truncate -s0 tests/a.sh' 'echo x | tee tests/a.sh' 'cd tests && rm a.sh' 'rm -rf tests' \
    'rm -r web' 'mv web web2' "rm $repo/.git/senior-mode/runs/2/red-tests" \
    "rm -f $tw/tests/a.sh" 'rm ./tests/../tests/a.sh' 'FOO=1 rm tests/a.sh' 'sudo rm tests/a.sh'
    do dir=$tw bash_ deny "$c" "$tw"; done
  for c in 'cat tests/a.sh' 'bash tests/a.sh' 'echo x > tests/new.sh' 'rm tests/new.sh' 'cp tests/a.sh /tmp/a.sh' 'cp /tmp/x tests/' \
    'git add tests/a.sh' 'git commit -m "test: x"' 'echo "rm tests/a.sh" > src/note.txt' 'git commit -m "rm tests/a.sh"' \
    'sed s/a/b/ tests/a.sh' 'sed -n 1p tests/a.sh' 'touch src/x.js' 'rm src/x.js' 'git rm src/x.js'
    do dir=$tw bash_ allow "$c" "$tw"; done
done
# Not a ticket session: the roles that write the tests, review, or integrate, and a manual session, edit freely.
for role in test-author reviewer integrator ""; do
  [ -n "$role" ] || unset role
  dir=$tw edit allow "$tw/tests/a.sh" Edit "" "role ${role:-unset}"
  dir=$tw bash_ allow "rm tests/a.sh" "$tw"
done
role=ticket
# A list binds the branch of its own ticket only (#875): the branch of another ticket, a stacked one for instance, or
# a ticket whose branch is merged and gone, edits the files of that list.
git -C "$repo" worktree add -q "$work/other" -b feat/3-stacked 2>/dev/null
dir=$work/other edit allow "$work/other/tests/a.sh" Edit "" "another ticket's branch edits a file of ticket 2's list"
# A branch with no list, a list that is not there, and a branch that names no ticket have nothing to protect.
dir=$work/wt edit allow "$work/wt/tests/a.sh" Edit "" "ticket 1 has no list"
mkdir -p "$work/nobranch"
git -C "$repo" worktree add -q --detach "$work/nobranch/d" 2>/dev/null
dir=$work/nobranch/d edit allow "$work/nobranch/d/tests/a.sh" Edit "" "detached head"
# A ticket session outside a run is not given the run's guard rails.
dir=$tw edit allow "$tw/.claude/settings.json" Edit "" "ticket role without SENIOR_MODE_RUN"
run=1
dir=$tw edit deny "$tw/.claude/settings.json" Edit "" "ticket role in a run keeps the run's guard rails"
dir=$tw decide '+ {tool_name: "Edit", tool_input: {file_path: $p}}' --arg p "$tw/tests/a.sh"
grep -q test-author <<<"$reason" || fail "red test reason does not name the test-author: $reason"
unset role

# --- Other events and tools pass through ---
decide '+ {tool_name: "Read", tool_input: {file_path: ($d + "/.claude/settings.json")}}'
[ "$verdict" = allow ] || fail "Read denied"
decide '+ {hook_event_name: "PostToolUse", tool_name: "Edit", tool_input: {file_path: ($d + "/.claude/settings.json")}}'
[ "$verdict" = allow ] || fail "another event denied"
decide '+ {tool_name: "Edit", tool_input: {}}'
[ "$verdict" = allow ] || fail "edit without a path denied"

[ "$failures" -eq 0 ] && echo "self-protect: all cases pass"
exit "$failures"
