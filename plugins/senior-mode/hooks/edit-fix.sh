#!/usr/bin/env bash
# Tier 1 (spec 474 §3, #482): after an edit, run the `check.edit` fixers (formatter, lint --fix) on the file
# the agent just wrote, so formatting problems are not discovered at push time. Each fixer runs for at most
# 10 seconds and the hook for at most 15. It never blocks: what the fixers could not fix goes back to the agent
# as 10 `file:line message` lines at most, the edit is kept. No `check.edit`, a git-ignored file or a file
# outside the repository: nothing runs.
set -o pipefail
input=$(cat)
get() { jq -r "$1 // empty" <<<"$input"; }

cwd=$(get .cwd)
root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || exit 0
config=$root/.claude/senior-mode.json
[ -f "$config" ] || exit 0
fixers=()
while IFS= read -r fixer; do
  [ -n "$fixer" ] && fixers+=("$fixer")
done < <(jq -r '.check.edit | arrays | .[] | strings' "$config" 2>/dev/null)
[ "${#fixers[@]}" -gt 0 ] || exit 0

file=$(get .tool_input.file_path)
[ -n "$file" ] || exit 0
[[ $file == /* ]] || file=$cwd/$file
file=$(realpath -m "$file") && root=$(realpath "$root") || exit 0
[[ $file == "$root"/* ]] && [ -f "$file" ] || exit 0
git -C "$root" check-ignore -q -- "$file" && exit 0

out=$(mktemp) || exit 0
trap 'rm -f "$out"' EXIT
quoted=$(printf '%q' "$file")
messages=()
SECONDS=0
for fixer in "${fixers[@]}"; do
  left=$((15 - SECONDS))
  [ "$left" -gt 0 ] || break
  [ "$left" -le 10 ] || left=10
  (cd "$root" && timeout -k 1 "$left" bash -c "${fixer//\{file\}/$quoted}" >"$out" 2>&1 </dev/null)
  [ $? -ne 124 ] || messages+=("edit-fix: $fixer timed out")
  re='^([^[:space:]:]+):([0-9]+)(:[0-9]+)?:?[[:space:]]+([^[:space:]].*)$'
  while IFS= read -r line; do
    [[ $line =~ $re ]] || continue
    path=${BASH_REMATCH[1]}
    messages+=("${path#"$root"/}:${BASH_REMATCH[2]} ${BASH_REMATCH[4]}")
  done <"$out"
done
[ "${#messages[@]}" -gt 0 ] || exit 0

jq -nc --arg c "$(printf '%s\n' "${messages[@]}" | head -n 10)" \
  '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $c}}'
exit 0
