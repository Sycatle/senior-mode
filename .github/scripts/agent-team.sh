#!/usr/bin/env bash
# Checks the agent team against ADR 0004: every role pinned to its model and effort with a turn cap
# (so the reviewer is never cheaper than the implementer), ops without CLAUDE.md, existing skills.
set -euo pipefail
plugin=${1:-plugins/senior-mode}
status=0

err() { echo "$*" >&2; status=1; }
field() { # file key: value of a top-level frontmatter key
  awk -v k="$2" 'NR == 1 && /^---$/ { f = 1; next } f && /^---$/ { exit }
    f && index($0, k ": ") == 1 { sub(/^[^:]*: */, ""); print }' "$1"
}
for pin in scout:haiku:low researcher:sonnet:medium architect:opus:high test-author:sonnet:medium \
  implementer:sonnet:medium reviewer:opus:high security:opus:high ops:haiku:low; do
  IFS=: read -r name model effort <<<"$pin"
  file=$plugin/agents/$name.md
  [ -f "$file" ] || { err "$file: missing"; continue; }
  [ "$(field "$file" model)" = "$model" ] || err "$file: model must be $model"
  [ "$(field "$file" effort)" = "$effort" ] || err "$file: effort must be $effort"
  [ -n "$(field "$file" maxTurns)" ] || err "$file: maxTurns missing"
  for skill in $(field "$file" skills | tr -d '[],'); do
    [ -f "$plugin/skills/${skill#*:}/SKILL.md" ] || err "$file: unknown skill $skill"
  done
done

ops=$plugin/agents/ops.md
[ ! -f "$ops" ] || [ "$(field "$ops" omitClaudeMd)" = true ] || err "$ops: omitClaudeMd must be true"
exit "$status"
