# shellcheck shell=bash
# What only this machine knows (#319): whether `serve` runs here, and when the last retro ran. The retro mark starts at
# the first status, so a new repository is not told a retro is due. Prints {serve: {running, pid}, retro: {lastDays, due}}.
STATUS_SECTION_LOCAL_ORDER=2000
# shellcheck disable=SC2016 # a jq program, not shell
STATUS_SECTION_LOCAL_TEXT_JQ='(if .serve.running then "Daemon: serve is running (pid \(.serve.pid))" else empty end),
  (if .retro.due then "Retro due: the last one was \(.retro.lastDays) days ago" else empty end)'
status_section_local_json() {
  local now_s=$4 common pid="" mark last
  common=$(git rev-parse --path-format=absolute --git-common-dir)
  pid=$(cat "$common/senior-mode/serve/serve.pid" 2>/dev/null) || pid=""
  if ! [[ $pid =~ ^[0-9]+$ ]] || ! kill -0 "$pid" 2>/dev/null || [[ $(ps -o args= -p "$pid" 2>/dev/null) != *senior-mode* ]]; then
    pid=""
  fi
  mark=$common/senior-mode/retro-last
  if ! last=$(cat "$mark" 2>/dev/null) || ! [[ $last =~ ^[0-9]+$ ]]; then
    mkdir -p "$common/senior-mode" && printf '%s\n' "$now_s" >"$mark" 2>/dev/null
    last=$now_s
  fi
  jq -nc --arg pid "$pid" --argjson days $(((now_s - last) / 86400)) \
    '{serve: {running: ($pid != ""), pid: (if $pid == "" then null else ($pid | tonumber) end)},
      retro: {lastDays: $days, due: ($days >= 7)}}'
}
