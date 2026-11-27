#!/usr/bin/env bash
# Checks a delegation brief (spec 474 §11, ADR 0034), in repositories with .claude/senior-mode.json.
# A call to the Agent tool whose prompt has no Goal or no Verify section (or leaves one empty) exits 2 with
# the missing sections named. The five other sections are advised: when absent, the call goes through with
# a reminder as additional context. Every allowed call is appended to .git/senior-mode/briefs.jsonl.
set -o pipefail
input=$(cat)
cwd=$(jq -r '.cwd // ""' <<<"$input")
root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -f "$root/.claude/senior-mode.json" ] || exit 0

prompt=$(jq -r '.tool_input.prompt // ""' <<<"$input")
missing=
advised=
goal=
for section in Goal Context Constraints Acceptance Verify Return Model; do
  body=$(awk -v h="## $section" '
    $0 ~ /^## / { on = ($0 ~ "^" h "[ \t\r]*$"); next }
    on && $0 ~ /[^ \t\r]/ { print; exit }' <<<"$prompt")
  if [ -z "$body" ]; then
    case $section in
      Goal | Verify) missing+="${missing:+, }## $section" ;;
      *) advised+="${advised:+, }## $section" ;;
    esac
  elif [ "$section" = Goal ]; then
    goal=$body
  fi
done
if [ -n "$missing" ]; then
  echo "brief: missing $missing (skill brief)" >&2
  exit 2
fi

[ -z "$advised" ] ||
  jq -nc --arg c "senior-mode: the brief lacks $advised. Not required, but the subagent starts better with them (skill brief)." \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: $c}}'

dir=$(git -C "$root" rev-parse --path-format=absolute --git-common-dir)/senior-mode || exit 0
mkdir -p "$dir" || exit 0
jq -nc --arg g "$goal" --argjson i "$input" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{time: $t, session: ($i.session_id // ""), agent_type: ($i.tool_input.subagent_type // ""),
    model: ($i.tool_input.model // ""), goal: $g}' >>"$dir/briefs.jsonl" || true
exit 0
