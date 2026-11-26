#!/usr/bin/env bash
# Behaviour eval of the implementer's knowledge note (#336): runs a headless session on a fixture ticket
# several times and grades each result. Needs `claude`, network and Node 22; not part of `check`.
# Usage: [EVAL_PLUGIN_DIR=<plugin dir>] evals/knowledge/run.sh [runs, default 3]
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
plugin=${EVAL_PLUGIN_DIR:-$here/../../plugins/senior-mode}
runs=${1:-3}
work=$(mktemp -d)
failures=0
git_t() { git -c user.name=eval -c user.email=eval@example.com "$@"; }
for i in $(seq "$runs"); do
  dir=$work/run-$i
  cp -r "$here/pitfall/repo" "$dir"
  git init -q -b main "$dir"
  git_t -C "$dir" add -A
  git_t -C "$dir" commit -q -m "feat: start the fixture"
  git_t -C "$dir" switch -q -c feat/900-total-label
  (cd "$dir" && claude -p --plugin-dir "$plugin" --permission-mode bypassPermissions \
    "Act as the implementer agent with the tdd skill. Commit on this branch; do not push. $(cat "$here/pitfall/ticket.md")") >"$work/run-$i.out" 2>&1 || true
  if "$here/grade.sh" "$dir" '#900'; then echo "ok    run $i"; else echo "FAIL  run $i ($dir)"; failures=$((failures + 1)); fi
done
echo "$((runs - failures))/$runs runs graded ok; results in $work"
exit "$failures"
