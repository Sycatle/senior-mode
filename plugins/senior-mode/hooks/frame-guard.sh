#!/usr/bin/env bash
# Keeps a frame session to docs/ (spec 0001 §16), in repositories with .claude/senior-mode.json.
# /senior-mode:frame, typed or invoked by the model, marks the session as framing; any other
# senior-mode command or skill, SessionEnd or `senior-mode frame end` clears the mark. While it is
# set, Edit, Write, MultiEdit and NotebookEdit of the main conversation outside docs/ are denied.
# Subagents are left alone: they neither set, clear nor are held by the mark.
set -o pipefail
input=$(cat)
get() { jq -r "$1 // empty" <<<"$input"; }

[ -z "$(get .agent_id)" ] || exit 0
root=$(git -C "$(get .cwd)" rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -f "$root/.claude/senior-mode.json" ] || exit 0
marks=$(git -C "$root" rev-parse --path-format=absolute --git-common-dir)/senior-mode/frame
mark=$marks/$(get .session_id | tr -cd 'A-Za-z0-9_-')

# Skills the frame skill runs itself; any other senior-mode skill means framing is over.
follow() {
  local name=${1#senior-mode:}
  [[ $name != *:* ]] && [ -d "$(dirname "$0")/../skills/$name" ] || return 0
  case $name in
    frame) mkdir -p "$marks" && touch "$mark" ;;
    triage | grill | spec | adr | commit | ready) ;;
    *) rm -f "$mark" ;;
  esac
  return 0
}

case $(get .hook_event_name) in
  UserPromptExpansion)
    name=$(get .command_name)
    [[ $name == senior-mode:* ]] && follow "$name"
    ;;
  SessionEnd) rm -f "$mark" ;;
  PreToolUse)
    tool=$(get .tool_name)
    if [ "$tool" = Skill ]; then
      follow "$(get .tool_input.skill)"
      exit 0
    fi
    [ -f "$mark" ] || exit 0
    path=$(get '.tool_input.file_path // .tool_input.notebook_path')
    [[ $path == /* ]] || path=$root/$path
    path=$(realpath -m "$path")
    [[ $path == "$root"/docs/* ]] && exit 0
    jq -nc --arg r "senior-mode: framing only writes under docs/ (specs, ADRs); ${path#"$root"/} is code or config. Finish the framing first; to leave it now, run \`senior-mode frame end\`." \
      '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
    ;;
esac
exit 0
