# shellcheck shell=bash
# The maintenance budget (#351): the gardening slots in use and the open gardening tickets (the ones serve files and the others).
STATUS_SECTION_MAINTENANCE_ORDER=1900
# shellcheck disable=SC2016 # a jq program, not shell
STATUS_SECTION_MAINTENANCE_TEXT_JQ='"Maintenance: \(.maintenance.slotsUsed) of \(.maintenance.reservedSlots) reserved gardening slots used (of \(.maintenance.parallel)), \(.maintenance.open) open gardening tickets (at most \(.maintenance.maxOpen))"'
status_section_maintenance_json() {
  local parallel
  parallel=$(config_get autonomy.parallel)
  jq -c --arg l "$(workflow_label "" gardening)" --argjson parallel "$parallel" \
    --argjson reserved "$(maintenance_reserved "$parallel")" --argjson max "$(config_get maintenance.maxOpen)" \
    '{maintenance: {reservedSlots: $reserved, parallel: $parallel, maxOpen: $max,
      slotsUsed: ([.items[] | select(.open and .status == "In progress" and (.labels | index($l)))] | length),
      open: ([.items[] | select(.open and (.labels | index($l)))] | length)}}' <<<"$1"
}
