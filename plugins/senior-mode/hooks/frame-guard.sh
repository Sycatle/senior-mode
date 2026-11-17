#!/usr/bin/env bash
# Keeps a frame session to docs/ (spec 0001 §16), in repositories with .claude/senior-mode.json.
# /senior-mode:frame, typed or invoked by the model, marks the session as framing; any other
# senior-mode command or skill, SessionEnd or `senior-mode frame end` clears the mark. While it is
# set, Edit, Write, MultiEdit and NotebookEdit outside docs/ are denied, subagents included (they
# share the session id). Only the main conversation sets or clears the mark.
set -o pipefail
# One jq call: this runs on every edit. The unit separator, not whitespace, keeps empty fields.
IFS=$'\x1f' read -r event session cwd agent command tool skill path < <(jq -r '[.hook_event_name,
  .session_id, .cwd, .agent_id, .command_name, .tool_name, .tool_input.skill,
  .tool_input.file_path // .tool_input.notebook_path] | map(. // "" | tostring) | join("\u001f")')

root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -f "$root/.claude/senior-mode.json" ] || exit 0
marks=$(git -C "$root" rev-parse --path-format=absolute --git-common-dir)/senior-mode/frame || exit 0
mark=$marks/$(tr -cd 'A-Za-z0-9_-' <<<"$session")

# Skills the frame skill runs itself; any other senior-mode skill means framing is over.
follow() {
  [ -z "$agent" ] || return 0
  local name=${1#senior-mode:}
  [[ $name != *:* ]] && [ -d "$(dirname "$0")/../skills/$name" ] || return 0
  case $name in
    frame) mkdir -p "$marks" && touch "$mark" ;;
    triage | grill | spec | adr | commit | ready) ;;
    *) rm -f "$mark" ;;
  esac
  return 0
}

case $event in
  UserPromptExpansion) follow "$command" ;;
  SessionEnd) rm -f "$mark" ;;
  PreToolUse)
    if [ "$tool" = Skill ]; then
      follow "$skill"
      exit 0
    fi
    [ -f "$mark" ] || exit 0
    [[ $path == /* ]] || path=$cwd/$path
    # No path resolution (GNU-only realpath -m): a ".." segment is simply never under docs/.
    # git resolves symlinks in the root, Claude Code sends paths as reached from the cwd: try both.
    here=$(cd "$cwd/$(git -C "$cwd" rev-parse --show-cdup)" 2>/dev/null && pwd) || here=$root
    [[ $path != */../* && $path != */.. ]] &&
      [[ $path == "$root"/docs/* || $path == "$here"/docs/* ]] && exit 0
    jq -nc --arg r "senior-mode: framing only writes under docs/ (specs, ADRs); ${path#"$root"/} is code or config. Do not work around this: stop and tell the user. They leave framing by starting another senior-mode command, or by running \`! senior-mode frame end\` themselves." \
      '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
    ;;
esac
exit 0
