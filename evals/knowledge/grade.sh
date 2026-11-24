#!/usr/bin/env bash
# Grades what an implementer session left in a repository (#336, spec 325 §4): grade.sh <repo> <origin> [none]
# With a pitfall: one or two notes under docs/knowledge/, each `origin` the ticket, and `senior-mode
# knowledge-check` passes. With `none`: no note at all. Offline.
set -euo pipefail
repo=${1:?usage: grade.sh <repo> <origin, like #900> [none]}
origin=${2:?usage: grade.sh <repo> <origin, like #900> [none]}
cli=$(cd "$(dirname "$0")/../../plugins/senior-mode/bin" && pwd)/senior-mode
notes=()
for f in "$repo"/docs/knowledge/*.md; do [ ! -e "$f" ] || notes+=("$f"); done

if [ "${3:-}" = none ]; then
  [ "${#notes[@]}" -eq 0 ] || { echo "FAIL: ${#notes[@]} note(s) with no pitfall"; exit 1; }
  echo "ok: no note"
  exit 0
fi
[ "${#notes[@]}" -ge 1 ] || { echo "FAIL: no note under docs/knowledge/"; exit 1; }
[ "${#notes[@]}" -le 2 ] || { echo "FAIL: ${#notes[@]} notes, at most 2"; exit 1; }
for f in "${notes[@]}"; do
  grep -qE "^origin: \"?$origin\"?\$" "$f" || { echo "FAIL: $f: origin is not $origin"; exit 1; }
done
(cd "$repo" && "$cli" knowledge-check) || { echo "FAIL: knowledge-check"; exit 1; }
echo "ok: ${#notes[@]} note(s), origin $origin"
