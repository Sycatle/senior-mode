#!/usr/bin/env bash
# Runs shellcheck on every shell script of the repository; falls back to uvx when it is not installed.
# The modules of bin/lib have no shebang and share variables: shellcheck reaches them by following the
# source lines of bin/senior-mode (-x), not on their own.
set -euo pipefail
mapfile -d '' files < <(git ls-files -z '*.sh' '.githooks/*' 'plugins/*/bin/*' ':!:plugins/*/bin/lib/*')
if command -v shellcheck >/dev/null; then
  shellcheck -x "${files[@]}"
else
  uvx --quiet --from shellcheck-py shellcheck -x "${files[@]}"
fi
