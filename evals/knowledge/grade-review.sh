#!/usr/bin/env bash
# Grades the comment of a review (#359, spec 325 §4): grade-review.sh <comment file>
# Every finding, a list item that names a `file:line`, ends with `<!-- finding: <slug> -->`, the slug in
# kebab-case, and nothing follows the marker. Offline.
set -euo pipefail
file=${1:?usage: grade-review.sh <comment file>}
awk '
  function flush() {
    if (item != "" && item ~ /[A-Za-z0-9_.\/-]+:[0-9]+/ && item !~ /<!-- finding: [a-z0-9]+(-[a-z0-9]+)* -->$/) {
      print "FAIL: finding without its marker: " first; bad++
    }
    item = ""
  }
  /^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]/ { flush(); first = $0; item = $0; next }
  /^[[:space:]]+[^[:space:]]/ && item != "" { item = item " " $0; sub(/[[:space:]]+$/, "", item); next }
  { flush() }
  END { flush(); exit bad ? 1 : 0 }
' "$file"
echo "ok: every finding has its marker"
