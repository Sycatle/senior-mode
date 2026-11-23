#!/usr/bin/env bash
# End-to-end check of the stack presets on real projects (spec 0001 §14, #13): each fixture is
# installed, adopted with `senior-mode setup repo`, and must pass `senior-mode check`.
# Needs network and Node 22; not part of the pre-push checks. Run it before merging a pull request
# that touches presets/ or setup repo: evals/run.sh [fixture...]
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
cli=$here/../plugins/senior-mode/bin/senior-mode
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0
git_t() { git -c user.name=eval -c user.email=eval@example.com "$@"; }

if [ $# -eq 0 ]; then
  for f in "$here"/fixtures/*/; do set -- "$@" "$(basename "$f")"; done
fi
for name in "$@"; do
  dir=$work/$name
  cp -r "$here/fixtures/$name" "$dir"
  git init -q -b main "$dir"
  # The lockfile keeps the install reproducible; npm 10 cannot resolve vitest's peer set without it (#292).
  [ ! -f "$dir/package.json" ] || (cd "$dir" && npm ci --no-audit --no-fund --loglevel=error)
  git_t -C "$dir" add -A
  git_t -C "$dir" commit -q -m "feat: start the fixture"
  (cd "$dir" && "$cli" setup repo) >"$work/$name.setup"
  git_t -C "$dir" add -A
  git_t -C "$dir" commit -q -m "chore: adopt senior-mode"
  if (cd "$dir" && "$cli" check) >"$work/$name.check" 2>&1; then
    want=$(jq -r '.commands | keys | length' "$dir/.claude/senior-mode.json")
    if [ "$(grep -c '^ok ' "$work/$name.check")" -gt "$want" ] && [ "$want" -ge 4 ]; then
      echo "ok    $name: $(tr '\n' ' ' <"$work/$name.check")"
      continue
    fi
  fi
  echo "FAIL  $name"
  cat "$work/$name.setup" "$work/$name.check"
  failures=$((failures + 1))
done
exit "$failures"
