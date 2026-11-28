# shellcheck shell=bash
# The config serve runs with against the default branch's (#681): serve reloads it at each poll (serve-config.sh), so a difference
# between two polls, or one that serve cannot apply (an invalid value), shows here. Prints {serveConfig: {differs, keys}}; no
# difference, no daemon, or a base config that does not validate (#444: the settings stand) is differs false.
STATUS_SECTION_SERVECONFIG_ORDER=2010
# shellcheck disable=SC2016 # a jq program, not shell
STATUS_SECTION_SERVECONFIG_TEXT_JQ='if .serveConfig.differs then "Serve config: the running settings differ from the default branch (\(.serveConfig.keys | join(", "))); serve applies them at its next poll, or at once on SIGHUP" else empty end'
status_section_serveconfig_json() {
  local common pid running values keys="[]"
  common=$(git rev-parse --path-format=absolute --git-common-dir)
  pid=$(cat "$common/senior-mode/serve/serve.pid" 2>/dev/null) || pid=""
  if [[ $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null && [[ $(ps -o args= -p "$pid" 2>/dev/null) == *senior-mode* ]] &&
    running=$(cat "$common/senior-mode/serve/config.running" 2>/dev/null) && values=$(serve_config_values); then
    keys=$(jq -nc --argjson a "$running" --argjson b "$values" '[$b | keys[] | select($a[.] != $b[.])]') || keys="[]"
  fi
  jq -nc --argjson keys "$keys" '{serveConfig: {differs: ($keys | length > 0), keys: $keys}}'
}
