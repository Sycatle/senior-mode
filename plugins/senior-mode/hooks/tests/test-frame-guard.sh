#!/usr/bin/env bash
# Tests for frame-guard.sh (UserPromptExpansion, PreToolUse, SessionEnd): JSON in, decision out.
set -u
hook=$(cd "$(dirname "$0")/.." && pwd)/frame-guard.sh
cli=$(cd "$(dirname "$0")/../../bin" && pwd)/senior-mode
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

repo="$work/repo" bare="$work/bare"
git init -q "$repo"
git init -q "$bare"
mkdir -p "$repo/.claude"
echo '{"checks": []}' >"$repo/.claude/senior-mode.json"

send() { # event session [jq assignments] -> hook stdout
  jq -nc --arg e "$1" --arg s "$2" --arg d "${dir:-$repo}" "{hook_event_name: \$e, session_id: \$s, cwd: \$d} ${3:-}" | "$hook"
}
typed() { send UserPromptExpansion "$1" "+ {expansion_type: \"slash_command\", command_name: \"$2\"}" >/dev/null; }
skill() { send PreToolUse "$1" "+ {tool_name: \"Skill\", tool_input: {skill: \"$2\"}} ${3:-}" >/dev/null; }
edit() { # expected session path [tool] [extra]
  local out got=allow
  out=$(send PreToolUse "$2" "+ {tool_name: \"${4:-Edit}\", tool_input: {file_path: \"$3\", notebook_path: \"$3\"}} ${5:-}")
  [ "$(jq -r '.hookSpecificOutput.permissionDecision // empty' <<<"$out" 2>/dev/null)" = deny ] && got=deny
  [ "$got" = "$1" ] || fail "$6: expected $1, got $got"
  reason=$(jq -r '.hookSpecificOutput.permissionDecisionReason // empty' <<<"$out" 2>/dev/null)
}

edit allow s1 "$repo/src/app.js" "" "" "edit outside a frame session"
typed s1 senior-mode:frame
edit deny s1 "$repo/src/app.js" "" "" "code edit while framing"
grep -q "senior-mode frame end" <<<"$reason" || fail "deny reason gives no way out: $reason"
edit deny s1 "$repo/README.md" Write "" "write at the root while framing"
edit deny s1 "$repo/docs/../src/app.js" "" "" "path escaping docs/ while framing"
edit deny s1 "$repo/nb.ipynb" NotebookEdit "" "notebook edit while framing"
edit allow s1 "$repo/docs/specs/0002-login.md" Write "" "spec written while framing"
edit allow s1 "$repo/docs/adr/0003-db.md" Edit "" "ADR edited while framing"
edit allow s1 "docs/specs/0002-login.md" Edit "" "relative docs path while framing"
edit allow s1 "$repo/.claude/agent-memory/architect/MEMORY.md" Write '+ {agent_id: "a2", agent_type: "senior-mode:architect"}' "agent memory written while framing"
edit allow s1 ".claude/agent-memory/architect/notes.md" Edit "" "relative agent memory path while framing"
edit deny s1 "$repo/.claude/agent-memory/../settings.json" Write "" "path escaping agent memory while framing"
edit deny s1 "$repo/.claude/agent-memoryx/MEMORY.md" Write "" "directory next to agent memory while framing"
edit deny s1 "$repo/.claude/settings.json" Write "" "project settings while framing"
mkdir -p "$repo/web"
dir=$repo/web edit deny s1 "docs/x.md" Edit "" "relative path taken from the repository root, not the cwd"
ln -s "$repo" "$work/link"
dir=$work/link edit allow s1 "$work/link/docs/specs/0002-login.md" Write "" "docs reached through a symlink"
dir=$work/link edit deny s1 "$work/link/src/app.js" Edit "" "code reached through a symlink"
edit deny s1 "$repo/src/app.js" Edit '+ {agent_id: "a1", agent_type: "senior-mode:implementer"}' "subagent edit while framing"
edit allow s1 "$repo/docs/specs/0002-login.md" Write '+ {agent_id: "a2", agent_type: "senior-mode:architect"}' "architect writes the spec"
edit allow s2 "$repo/src/app.js" "" "" "another session is not affected"

skill s1 senior-mode:grill
skill s1 spec
edit deny s1 "$repo/src/app.js" "" "" "framing sub-skills keep the lock"
skill s1 senior-mode:tdd '+ {agent_id: "a1"}'
edit deny s1 "$repo/src/app.js" "" "" "a subagent's skill does not end the frame"
skill s1 senior-mode:tdd
edit allow s1 "$repo/src/app.js" "" "" "another senior-mode skill ends the frame"

skill s3 senior-mode:frame
edit deny s3 "$repo/src/app.js" "" "" "frame invoked by the model"
typed s3 other-plugin:thing
edit deny s3 "$repo/src/app.js" "" "" "a foreign command keeps the lock"
typed s3 senior-mode:verify
edit allow s3 "$repo/src/app.js" "" "" "a typed senior-mode command ends the frame"

typed s7 frame
edit deny s7 "$repo/src/app.js" "" "" "frame typed without the plugin prefix"
typed s7 other-plugin:frame
typed s7 deploy
edit deny s7 "$repo/src/app.js" "" "" "a command outside senior-mode keeps the lock"

typed s4 senior-mode:frame
send SessionEnd s4 >/dev/null
edit allow s4 "$repo/src/app.js" "" "" "session end clears the frame"

typed s5 senior-mode:frame
(cd "$repo" && "$cli" frame end >/dev/null) || fail "senior-mode frame end failed"
edit allow s5 "$repo/src/app.js" "" "" "senior-mode frame end clears the frame"
(cd "$work" && "$cli" frame end >/dev/null 2>&1) && fail "senior-mode frame end succeeds outside a repository"

# A framing works in its own worktree (senior-mode frame start): docs/ there is writable, code is not.
git -C "$repo" add -A
git -C "$repo" -c user.name=t -c user.email=t@t commit -q -m "chore: config"
git -C "$repo" worktree add -q -b docs/x "$work/repo-frame-x"
typed s8 senior-mode:frame
edit allow s8 "$work/repo-frame-x/docs/specs/12-login.md" Write "" "spec written in the framing worktree"
edit allow s8 "$work/repo-frame-x/.claude/agent-memory/architect/MEMORY.md" Write "" "agent memory written in the framing worktree"
edit deny s8 "$work/repo-frame-x/src/app.js" Write "" "code written in the framing worktree"
edit deny s8 "$work/repo-frame-x/docs/../src/app.js" Write "" "path escaping docs/ in the framing worktree"
edit deny s8 "$work/elsewhere/docs/specs/12-login.md" Write "" "docs/ outside every worktree of the repository"
dir=$work/repo-frame-x edit allow s8 "$work/repo-frame-x/docs/specs/12-login.md" Write "" "spec written with the worktree as cwd"
dir=$work/repo-frame-x edit deny s8 "$work/repo-frame-x/src/app.js" Write "" "code written with the worktree as cwd"
# #224: the framing worktree is under the git dir, <git dir>/senior-mode/worktrees/frame-<slug>.
fw=$repo/.git/senior-mode/worktrees/frame-y
git -C "$repo" worktree add -q -b docs/y "$fw"
edit allow s8 "$fw/docs/specs/12-login.md" Write "" "spec written in a framing worktree under the git dir"
edit deny s8 "$fw/src/app.js" Write "" "code written in a framing worktree under the git dir"
dir=$fw edit allow s8 "$fw/docs/specs/12-login.md" Write "" "spec written with a git dir worktree as cwd"

dir=$bare typed s6 senior-mode:frame
dir=$bare edit allow s6 "$bare/src/app.js" "" "" "repository without senior-mode config"

[ "$failures" -eq 0 ] && echo "frame-guard: all cases pass"
exit "$failures"
