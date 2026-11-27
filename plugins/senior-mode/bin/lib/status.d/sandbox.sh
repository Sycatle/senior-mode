# shellcheck shell=bash
# The sandbox (#786): mode, runtime, image, network, and what it refused in the last 24 hours: the hosts the egress proxy
# refused (<serve dir>/<n>.egress, one line per host, counted from the files touched in the day) and the requests the
# credential broker denied (<serve dir>/broker.log, epoch session verb decision exit). 0 when a file is absent.
STATUS_SECTION_SANDBOX_ORDER=1950
# shellcheck disable=SC2016 # a jq program, not shell
STATUS_SECTION_SANDBOX_TEXT_JQ='.sandbox as $s
  | (if $s.mode == "off" then "Sandbox: off (configured)"
    elif $s.runtime == null then (if $s.mode == "required" then "Sandbox: required but no container runtime, launches are held" else "Sandbox: off (no runtime)" end)
    else "Sandbox: \($s.runtime) (\($s.rootless)), image \($s.image), network \($s.network)" end),
  (if $s.runtime != null and $s.mode != "off" then "  last 24h: \($s.egressDenied) egress refusals, \($s.brokerDenied) broker denials" else empty end),
  ($s.warnings[] | "  warning: \(.)")'
status_section_sandbox_json() {
  local now_s=$4 network dir mode rt="" rootless="" egress=0 broker=0 warnings='[]' f n
  mode=$(cd "$3" && sandbox_mode)
  network=$(cd "$3" && sandbox_network)
  if [ "$mode" != off ]; then
    rt=$(cd "$3" && sandbox_runtime) || rt=""
  fi
  dir=$(cd "$3" && broker_dir)
  if [ -n "$rt" ]; then
    rootless=$(sandbox_rootless "$rt")
    [ "$rootless" != rootful ] || warnings='["rootful runtime: allowed, but rootless podman is the reference"]'
    [ "$network" != open ] || warnings=$(jq -c '. + ["sandbox network: open"]' <<<"$warnings")
  fi
  while IFS= read -r f; do
    n=$(wc -l <"$f" 2>/dev/null) || n=0
    egress=$((egress + n))
  done < <(find "$dir" -maxdepth 1 -name '*.egress' -mmin -1440 2>/dev/null)
  broker=$(awk -v now="$now_s" '$1 >= now - 86400 && $4 == "deny" { n++ } END { print n + 0 }' "$dir/broker.log" 2>/dev/null) || broker=0
  jq -nc --arg mode "$mode" --arg rt "$rt" --arg rootless "$rootless" --arg image "$(cd "$3" && sandbox_image_name)" \
    --arg network "$network" --argjson e "$egress" --argjson b "$broker" --argjson w "$warnings" \
    '{sandbox: {mode: $mode, runtime: (if $rt == "" then null else $rt end), rootless: (if $rootless == "" then null else $rootless end),
      image: $image, network: $network, egressDenied: $e, brokerDenied: $b, warnings: $w}}'
}
