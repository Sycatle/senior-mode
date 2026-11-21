#!/usr/bin/env bash
# senior-mode: fails when a forbidden pattern (envGuard.forbidden in .claude/senior-mode.json: literal
# strings, or /regex/ for an extended regular expression) appears in a .env* file of the worktree,
# tracked or not, or in the environment variables of this process. Agent machines use development
# environments only. Prints file names, variable names and line numbers, never a value or a pattern.
# Standalone: needs only bash, jq and find.
set -u
root=$(git rev-parse --show-toplevel 2>/dev/null) || root=$PWD
config=$root/.claude/senior-mode.json
command -v jq >/dev/null || { echo "env-guard: jq is needed to read $config" >&2; exit 1; }
patterns=()
if [ -f "$config" ]; then
  jq -e '(.envGuard.forbidden // []) | type == "array" and all(type == "string")' "$config" >/dev/null 2>&1 ||
    { echo "env-guard: envGuard.forbidden in .claude/senior-mode.json must be a list of strings" >&2; exit 1; }
  mapfile -t patterns < <(jq -r '(.envGuard.forbidden // [])[] | select(length > 0)' "$config")
fi
if [ "${#patterns[@]}" -eq 0 ]; then
  echo "skipped: envGuard.forbidden is not set in .claude/senior-mode.json"
  exit 0
fi

for i in "${!patterns[@]}"; do
  p=${patterns[$i]}
  if [[ $p == /?*/ ]]; then
    re=${p:1:${#p}-2}
    [[ "" =~ $re ]]
    [ $? -ne 2 ] || { echo "env-guard: envGuard.forbidden entry $((i + 1)) is not a valid regular expression" >&2; exit 1; }
  fi
done

# Succeeds when the text contains a forbidden string or matches a forbidden regex.
forbidden() {
  local p re
  for p in "${patterns[@]}"; do
    if [[ $p == /?*/ ]]; then
      re=${p:1:${#p}-2}
      ! [[ $1 =~ $re ]] || return 0
    else
      [[ $1 != *"$p"* ]] || return 0
    fi
  done
  return 1
}

hits=
while IFS= read -r -d '' file; do
  names='' n=0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    forbidden "$line" || continue
    # The variable name for VAR=value (unless the name itself is forbidden), else the line number.
    label="line $n"
    if [[ $line =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)= ]]; then
      key=${BASH_REMATCH[2]}
      ! forbidden "$key" || key=
      [ -z "$key" ] || label=$key
    fi
    [[ ", $names," == *", $label,"* ]] || names+="${names:+, }$label"
  done <"$file"
  [ -z "$names" ] || hits+="  ${file#"$root"/}: $names"$'\n'
done < <(find "$root" \( -name .git -o -name node_modules \) -prune -o -type f -name '.env*' -print0 | sort -z)

while IFS= read -r var; do
  [ "$var" != _ ] || continue
  if forbidden "${!var}"; then
    forbidden "$var" && var="(a variable whose name is forbidden)"
    hits+="  environment: $var"$'\n'
  fi
done < <(compgen -e | sort)

if [ -n "$hits" ]; then
  echo "a forbidden pattern (envGuard.forbidden) appears in:"
  printf '%s' "$hits"
  echo "Agent machines use development environments only: point these at a development environment."
  exit 1
fi
echo "ok: no forbidden pattern in .env* files or in the environment"
