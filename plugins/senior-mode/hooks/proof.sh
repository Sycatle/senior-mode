#!/usr/bin/env bash
# Proof before claims (spec 0001 §4.5, §16), in repositories with .claude/senior-mode.json.
# PostToolUse: an edit marks the session "edited"; a successful verification command marks it
# "verified" (failed commands go to PostToolUseFailure, not here). Stop, and SubagentStop of the
# implementer, remind while the session is "edited" and never block (ADR 0034): the Stop event takes no
# additionalContext, so the reminder is a systemMessage. PreCompact prints what the summary keeps.
set -o pipefail
input=$(cat)
get() { jq -r "$1 // empty" <<<"$input"; }

root=$(git -C "$(get .cwd)" rev-parse --show-toplevel 2>/dev/null) || exit 0
config=$root/.claude/senior-mode.json
[ -f "$config" ] || exit 0
data=${CLAUDE_PLUGIN_DATA:-${TMPDIR:-/tmp}/senior-mode}/proof
mkdir -p "$data"
state=$data/$(get .session_id | tr -cd 'A-Za-z0-9_-')
checks=$(jq -r '.checks[]?.name' "$config" 2>/dev/null | paste -sd, - | sed 's/,/, /g')

is_verification() {
  local run
  [[ $1 == *"senior-mode check"* ]] && return 0
  while IFS= read -r run; do
    [ -n "$run" ] && [[ $1 == *"$run"* ]] && return 0
  done < <(jq -r '.checks[]?.run' "$config" 2>/dev/null)
  return 1
}
remind() {
  jq -nc --arg c "senior-mode: files changed since the last successful verification. Run \`senior-mode check\`${checks:+ ($checks)} and read its output before finishing; if it cannot run here, say plainly that the change is not verified and why." \
    '{systemMessage: $c}'
}

event=$(get .hook_event_name)
case $event in
  PostToolUse)
    case $(get .tool_name) in
      Edit | Write | MultiEdit | NotebookEdit) echo edited >"$state" ;;
      Bash) is_verification "$(get .tool_input.command)" && echo verified >"$state" ;;
    esac
    ;;
  Stop | SubagentStop)
    [ "$event" = Stop ] || [[ $(get .agent_type) == *implementer ]] || exit 0
    [ "$(get .stop_hook_active)" = true ] || [ "$(cat "$state" 2>/dev/null)" != edited ] || remind
    ;;
  PreCompact)
    branch=$(git -C "$root" symbolic-ref --short -q HEAD)
    issue=$(sed -nE 's#^[a-z]+/([0-9]+)-.*#\1#p' <<<"$branch")
    verified="verified by the last check run"
    [ "$(cat "$state" 2>/dev/null)" = edited ] && verified="changes made since the last check run are not verified"
    echo "Keep in the summary: the current ticket${issue:+ #$issue} (branch ${branch:-detached}) and the path of its spec; every decision taken, with its reason; the files changed; open questions; verification state: $verified."
    ;;
esac
exit 0
