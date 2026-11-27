# shellcheck shell=bash
# The journeys of the accepted specs kept true (#798): a journey whose test is missing on the base branch, one whose spec paths
# match no file, and a test title carrying a journey id no spec declares. Prints {journeys: {...}}, nothing for a project with no journey.
STATUS_SECTION_JOURNEYS_ORDER=950
# shellcheck disable=SC2016 # a jq program, not shell
STATUS_SECTION_JOURNEYS_TEXT_JQ='(.journeys // null) as $j
  | if $j != null and (($j.missingTests | length) + ($j.noPaths | length) + ($j.orphans | length)) > 0 then
      sec("Journeys (\($j.withTest) of \($j.declared) with a test)";
        [$j.missingTests[] | "journey \(.id) of spec \(.spec): no test at \(.test)"]
        + [$j.noPaths[] | "journey \(.id) of spec \(.spec): the paths of the spec match no file"]
        + [$j.orphans[] | "warning: a test title of \(.file) carries journey \(.id), which no spec declares"])
    else empty end'
status_section_journeys_json() {
  journeys_report "$3" | jq -c 'if .declared == 0 then {} else {journeys: .} end'
}
