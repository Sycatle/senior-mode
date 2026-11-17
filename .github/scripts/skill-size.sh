#!/usr/bin/env bash
# Fails when a SKILL.md exceeds the budget (spec 0001 §8, §15); longer references belong in sibling files.
set -euo pipefail
budget=${SKILL_BUDGET:-3072}
status=0
while IFS= read -r -d '' file; do
  size=$(wc -c <"$file")
  if [ "$size" -gt "$budget" ]; then
    echo "$file: $size bytes, budget $budget" >&2
    status=1
  fi
done < <(find plugins -path '*/skills/*/SKILL.md' -print0)
exit "$status"
