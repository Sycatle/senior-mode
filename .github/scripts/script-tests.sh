#!/usr/bin/env bash
# Runs the script tests of the repository (*/test-*.sh), as many at a time as there are CPUs. Each file's
# output is kept apart and printed in the order of the files; a failing file is named, and the others still
# run. On a push (SENIOR_MODE_CHANGED_FILES, set by the pre-push hook) only the files the changed paths touch
# run: a changed test, a test whose text names the changed file. A path that cannot be mapped runs them all.
set -u
cd "$(git rev-parse --show-toplevel)" || exit 1
mapfile -t tests < <(git ls-files '*/test-*.sh')

# Milliseconds, and a duration since one as "1.2s".
now_ms() { local t=${EPOCHREALTIME:-}; t=${t/[.,]/}; if [ -n "$t" ]; then echo $((t / 1000)); else echo $((SECONDS * 1000)); fi; }
took() { local ms=$(($(now_ms) - $1)); printf '%d.%ds' $((ms / 1000)) $((ms % 1000 / 100)); }

# The files to run, one per line.
select_tests() {
  local list=${SENIOR_MODE_CHANGED_FILES:-} p t base
  local -A want=()
  if [ -z "$list" ] || [ ! -r "$list" ]; then
    printf '%s\n' "${tests[@]}"
    return
  fi
  while IFS= read -r p; do
    case $p in
      */templates/*) ;;
      docs/* | *.md | LICENSE | .github/workflows/* | .claude/agent-memory/*) continue ;;
    esac
    case $p in
      # The shared script and its modules, the config and this runner reach every test.
      */bin/senior-mode | */bin/lib/*.sh | .claude/senior-mode.json | .github/scripts/script-tests.sh)
        printf '%s\n' "${tests[@]}"
        return
        ;;
      */test-*.sh)
        [ ! -e "$p" ] || want[$p]=1
        continue
        ;;
    esac
    base=$(basename "$p")
    local found=false
    for t in "${tests[@]}"; do
      if grep -qF -- "$base" "$t"; then
        want[$t]=1
        found=true
      fi
    done
    if ! $found; then
      printf '%s\n' "${tests[@]}"
      return
    fi
  done <"$list"
  for t in "${tests[@]}"; do [ -z "${want[$t]:-}" ] || printf '%s\n' "$t"; done
}

mapfile -t selected < <(select_tests)
# The tests run as if from a shell, not from the session that runs check (#587): a serve session's
# SENIOR_MODE_RUN, SENIOR_MODE_SLOTS or plugin variables change what the scripts under test do.
unset "${!SENIOR_MODE_@}" "${!CLAUDE_PLUGIN_@}" CLAUDE_PROJECT_DIR CLAUDECODE
if [ "${#selected[@]}" -eq 0 ]; then
  echo "skipped: no test file is affected by this push"
  exit 0
fi

jobs=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)
out=$(mktemp -d)
# Two runs at once (parallel sessions, #295) share nothing: the test files get a temp directory and a lock
# directory (XDG_RUNTIME_DIR, where the machine-wide lock files go) of this run only.
mkdir -m 700 "$out/tmp" "$out/runtime"
export TMPDIR=$out/tmp XDG_RUNTIME_DIR=$out/runtime
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$out"' EXIT

# Runs one file with its own output; the result file appears when it is done.
run_one() {
  local i=$1 started rc=0
  started=$(now_ms)
  "./${selected[i]}" >"$out/$i.log" 2>&1 </dev/null || rc=$?
  echo "$rc $(took "$started")" >"$out/$i.tmp" && mv "$out/$i.tmp" "$out/$i.done"
}

next=0
failed=""
# Prints the results that are ready, in order.
flush() {
  local rc time
  while [ "$next" -lt "${#selected[@]}" ] && [ -f "$out/$next.done" ]; do
    read -r rc time <"$out/$next.done"
    if [ "$rc" -eq 0 ]; then
      echo "ok    ${selected[next]} ($time)"
    else
      echo "FAIL  ${selected[next]} ($time)"
      sed 's/^/      /' "$out/$next.log"
      failed="${failed:+$failed, }${selected[next]}"
    fi
    next=$((next + 1))
  done
}

for i in "${!selected[@]}"; do
  while [ "$(jobs -rp | wc -l)" -ge "$jobs" ]; do
    wait -n
    flush
  done
  run_one "$i" &
done
while wait -n 2>/dev/null; do flush; done
flush
if [ "$next" -lt "${#selected[@]}" ]; then
  echo "FAIL  ${selected[next]}: no result (killed?)"
  failed="${failed:+$failed, }${selected[next]}"
fi
[ -z "$failed" ] || {
  echo "failed: $failed"
  exit 1
}
