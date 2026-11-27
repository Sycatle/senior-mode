#!/usr/bin/env bash
# Runs shellcheck on every shell script of the repository; falls back to uvx when it is not installed.
# The modules of bin/lib have no shebang and share variables: shellcheck reaches them by following the
# source lines of bin/senior-mode (-x), not on their own.
set -euo pipefail
mapfile -d '' files < <(git ls-files -z '*.sh' '.githooks/*' 'plugins/*/bin/*' ':!:plugins/*/bin/lib/*')
# The status sections are sourced by a glob, so shellcheck checks them on their own; their constants are read by status.sh (SC2034).
mapfile -d '' sections < <(git ls-files -z 'plugins/*/bin/lib/status.d/*.sh')
sc() { if command -v shellcheck >/dev/null; then shellcheck "$@"; else uvx --quiet --from shellcheck-py shellcheck "$@"; fi; }
sc -x "${files[@]}"
[ "${#sections[@]}" -eq 0 ] || sc -e SC2034 "${sections[@]}"
