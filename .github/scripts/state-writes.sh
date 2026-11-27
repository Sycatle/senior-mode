#!/usr/bin/env bash
# Checks spec 373 section 3: a function of serve or run that writes under the serve dir goes through state_write (or
# state_put, state_append), never through a bare redirection, mv, cp, touch, tee or sed -i. A line that has to (a
# command's own output kept as it comes) says so with `# state-ok: <why>`. Without arguments it reads run.sh and serve*.sh.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
if [ $# -eq 0 ]; then
  set -- plugins/senior-mode/bin/lib/run.sh plugins/senior-mode/bin/lib/serve*.sh
fi
status=0
for file in "$@"; do
  out=$(awk '
    /^[[:space:]]*#/ || /# state-ok:/ { next }
    # The lines a session script is made of (printf with a %q format) are written by the script itself, tmp then mv.
    /^[[:space:]]*printf [\047][^\047]*%q/ { next }
    {
      dir = "[$]\\{?(SERVE_DIR|RUN_DIR|RUN_LAUNCH_LOG)"
      if ($0 ~ "(^|[^0-9&>])>>?[[:space:]]*\"?" dir ||
          $0 ~ "(^|[;&|(][[:space:]]*|[[:space:]])(mv|cp|touch|tee|install|sed -i)[[:space:]].*" dir) {
        printf "%s:%d: writes under the serve dir without state_write: %s\n", FILENAME, NR, $0
      }
    }' "$file")
  if [ -n "$out" ]; then
    echo "$out" >&2
    status=1
  fi
done
exit "$status"
