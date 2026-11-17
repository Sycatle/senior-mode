#!/usr/bin/env bash
# Runs shellcheck on every shell script of the repository; falls back to uvx when it is not installed.
set -euo pipefail
mapfile -d '' files < <(git ls-files -z '*.sh' '.githooks/*' 'plugins/*/bin/*')
if command -v shellcheck >/dev/null; then
  shellcheck "${files[@]}"
else
  uvx --quiet --from shellcheck-py shellcheck "${files[@]}"
fi
