#!/usr/bin/env bash
# Before/after eval of a change to a skill or an agent (#368): runs the case evals/<case>/run.sh with `claude -p`
# on the plugin of the base and on the plugin of the branch, several runs each, and prints the table to put under
# "## Eval" in the pull request. Needs `claude`, network and Node 22; not part of `check`.
# Usage: evals/compare.sh <case> [runs, default 3] [base ref, default origin/main]
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
case_name=${1:?usage: evals/compare.sh <case> [runs] [base ref]}
runs=${2:-3}
base=${3:-origin/main}
[ -f "$here/$case_name/run.sh" ] || { echo "compare: no case evals/$case_name/run.sh" >&2; exit 1; }
[[ $runs =~ ^[0-9]+$ ]] && [ "$runs" -ge 2 ] || { echo "compare: runs must be at least 2" >&2; exit 1; }
work=$(mktemp -d)
trap 'git -C "$root" worktree remove --force "$work/base" >/dev/null 2>&1 || true; rm -rf "$work"' EXIT
git -C "$root" worktree add -q --detach "$work/base" "$base"
# The score of a run of the case: the "N/M runs graded ok" line of its summary.
score() { # plugin dir
  EVAL_PLUGIN_DIR=$1 "$here/$case_name/run.sh" "$runs" 2>&1 | sed -nE 's/^([0-9]+\/[0-9]+) runs graded ok.*/\1/p' | tail -n 1
}
before=$(score "$work/base/plugins/senior-mode")
after=$(score "$root/plugins/senior-mode")
[ -n "$before" ] && [ -n "$after" ] || { echo "compare: the case printed no score (before '$before', after '$after')" >&2; exit 1; }
printf '| Case | Before | After |\n|---|---|---|\n| %s | %s | %s |\n' "$case_name" "$before" "$after"
