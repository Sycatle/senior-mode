# shellcheck shell=bash
# The Iteration field of the Project (#180) as JSON {id, duration, iterations: [{id, title, startDate, duration}]}, the
# completed iterations too, by start date; nothing when the Project has no Iteration field.
# shellcheck disable=SC2016 # a GraphQL query, not shell
iteration_field() {
  local project res err
  project=$(jq -r '.project.id // empty' "$(config_file)")
  [ -n "$project" ] || die "no Project in .claude/senior-mode.json; run /senior-mode:setup"
  err=$(mktemp)
  # GitHub answers a missing field with an error, not null (#536).
  if ! res=$(jq -nc --arg id "$project" '{variables: {id: $id}, query: "query($id: ID!) { node(id: $id) { ... on ProjectV2 {
    field(name: \"Iteration\") { ... on ProjectV2IterationField { id configuration { duration
    iterations { id title startDate duration } completedIterations { id title startDate duration } } } } } } }"}' |
    gh_retry api graphql --input - 2>"$err"); then
    grep -q 'Could not resolve to a .* with the name Iteration' "$err" && { rm -f "$err"; return 0; }
    cat "$err" >&2; rm -f "$err"
    return 1
  fi
  rm -f "$err"
  jq -c '.data.node.field // empty | select(.id) | {id, duration: .configuration.duration,
    iterations: ((.configuration.completedIterations + .configuration.iterations) | sort_by(.startDate))}' <<<"$res"
}

# The iteration named $1, or `current` (the one that holds today), as a tab-separated line: id, title, first day, the
# day after its last and its last day. Fails when there is none or the board has no Iteration field.
iteration_find() {
  local field
  field=$(iteration_field) && [ -n "$field" ] || return 1
  jq -r --arg n "$1" --arg today "$(date -u +%Y-%m-%d)" '.iterations[]
    | . + {end: ((.startDate + "T00:00:00Z" | fromdateiso8601) + .duration * 86400 | strftime("%Y-%m-%d"))}
    | select(if $n == "current" then .startDate <= $today and $today < .end else .title == $n end)
    | [.id, .title, .startDate, .end, ((.end + "T00:00:00Z" | fromdateiso8601) - 86400 | strftime("%Y-%m-%d"))] | @tsv' <<<"$field" | head -n 1 | grep .
}

# Whether the board has the fields of the cycle (#180): Iteration, Start and End cached in the config.
cycle_fields() {
  jq -e '.project.fields | (.Iteration.iteration == true) and (.Start.date == true) and (.End.date == true)' "$(config_file)" >/dev/null 2>&1
}

# A ticket starts (#180): it gets the current iteration and Start today. Best effort and silent on a board with no
# cycle fields (a config from before them): the Status is already set.
cycle_start() {
  cycle_fields || return 0
  if ! iteration_find current >/dev/null; then
    echo "senior-mode: no iteration holds today; extend the Iteration field in the Project settings. Start is set, the iteration is not" >&2
    (item_set "$1" Start "$(date -u +%Y-%m-%d)") >/dev/null || echo "senior-mode: could not set Start on #$1" >&2
  else
    (item_set "$1" Iteration current Start "$(date -u +%Y-%m-%d)") >/dev/null || echo "senior-mode: could not set the iteration and Start on #$1" >&2
  fi
}

# A ticket is merged (#180): End is today. Best effort, silent on a board with no cycle fields.
cycle_end() {
  cycle_fields || return 0
  (item_set "$1" End "$(date -u +%Y-%m-%d)") >/dev/null || echo "senior-mode: could not set End on #$1" >&2
}

# Archives the items that are Done and whose issue closed more than board.archiveAfterDays days ago (#179), and lists
# them; $1 is a board_data result. An open item, an item that is not Done and an archived one are never touched.
# One that cannot be archived is said and left for the next time.
# shellcheck disable=SC2016 # a GraphQL query, not shell
board_archive() {
  local days project cutoff entry n title id
  days=$(config_get board.archiveAfterDays)
  [[ $days =~ ^[1-9][0-9]*$ ]] || die "board.archiveAfterDays must be a positive whole number, not $days"
  project=$(jq -r '.project.id // empty' "$(config_file)")
  cutoff=$(iso_time $(($(date +%s) - days * 86400)))
  while IFS= read -r entry; do
    n=$(jq -r .number <<<"$entry") title=$(jq -r .title <<<"$entry") id=$(jq -r .itemId <<<"$entry")
    if jq -nc --arg p "$project" --arg i "$id" '{variables: {project: $p, item: $i}, query: "mutation($project: ID!, $item: ID!) {
      archiveProjectV2Item(input: {projectId: $project, itemId: $item}) { item { id } } }"}' | gh_retry api graphql --input - >/dev/null; then
      echo "Archived: #$n $title (Done, closed more than $days days ago)"
    else
      echo "senior-mode: could not archive #$n" >&2
    fi
  done < <(jq -c --arg c "$cutoff" '.items[] | select(.status == "Done" and (.open | not) and (.archived | not) and .itemId != null
    and .closedAt != null and .closedAt < $c)' <<<"$1")
}

# Posts a Project status update (#155, #177): body $1 and, when given, its status $2 (ON_TRACK, AT_RISK or OFF_TRACK), start date
# $3 and target date $4 (YYYY-MM-DD). Fails unless GitHub answers with the id of the update. Shared by `status --publish`,
# `retro` and the daily digest of serve.
# shellcheck disable=SC2016 # a GraphQL query, not shell
project_post_update() {
  local project res
  project=$(jq -r '.project.id // empty' "$(config_file)")
  [ -n "$project" ] || return 1
  res=$(jq -nc --arg p "$project" --arg b "${1:0:60000}" --arg s "${2:-}" --arg a "${3:-}" --arg t "${4:-}" '{query: "mutation($project: ID!, $body: String!,
      $status: ProjectV2StatusUpdateStatus, $start: Date, $target: Date) { createProjectV2StatusUpdate(input: {projectId: $project, body: $body,
      status: $status, startDate: $start, targetDate: $target}) { statusUpdate { id } } }",
      variables: ({project: $p, body: $b} + (if $s == "" then {} else {status: $s} end)
        + (if $a == "" then {} else {start: $a} end) + (if $t == "" then {} else {target: $t} end))}' | gh_retry api graphql --input -) &&
    jq -e '.data.createProjectV2StatusUpdate.statusUpdate.id' <<<"$res" >/dev/null 2>&1
}

# When each open ticket labelled needs-human got the label (#177): the time of the last `labeled` event of its timeline, as
# {"<number>": "<time>"}. $1 is a board_data result. Fails when GitHub does not answer.
# shellcheck disable=SC2016 # a GraphQL query, not shell
health_needs_human() {
  local nums slug query="" n res
  nums=$(jq -r '.items[] | select(.open and (.archived | not) and (.labels | index("needs-human"))) | .number' <<<"$1")
  if [ -z "$nums" ]; then
    echo '{}'
    return 0
  fi
  slug=$(repo_slug)
  for n in $nums; do
    query+="i$n: issue(number: $n) { timelineItems(last: 50, itemTypes: [LABELED_EVENT]) { nodes { ... on LabeledEvent { createdAt label { name } } } } } "
  done
  res=$(jq -nc --arg q "query(\$owner: String!, \$name: String!) { repository(owner: \$owner, name: \$name) { $query} }" --arg o "${slug%%/*}" --arg n "${slug#*/}" \
    '{query: $q, variables: {owner: $o, name: $n}}' | gh_retry api graphql --input -) || return 1
  jq -ec '(.data.repository // error("no repository")) | with_entries(select(.value != null)
    | {key: (.key | ltrimstr("i")), value: ([.value.timelineItems.nodes[] | select(.label.name == "needs-human") | .createdAt] | max)}
    | select(.value != null))' <<<"$res"
}

# The health of the Project (#177) from a board_data result, $drift (the board drift as JSON), $nh (health_needs_human) and
# $now. Off track when an open milestone is past due with open issues; at risk when an open issue has carried needs-human
# for more than 24 hours, an open pull request fails its checks or there is drift; on track otherwise. The target date is
# the earliest due date of an open milestone, if any; the body names the rule that decided.
# shellcheck disable=SC2016 # a jq program, not shell
HEALTH_JQ='def plural($n; $w): "\($n) \($w)\(if $n == 1 then "" else "s" end)";
  . as $d | $drift[0] as $drift | $nh[0] as $nh | ($d.items | map(select(.archived | not))) as $items | ($now | fromdateiso8601) as $t
  | [$items[] | select(.open and .milestone != null and .due != null)] as $dated
  | [$dated[] | select(.due < $now)] as $late
  | ($late | sort_by(.due) | group_by(.milestone) | map({milestone: .[0].milestone, due: .[0].due[:10], open: length}) | sort_by(.due)) as $ms
  | [$items[] | select(.open and (.labels | index("needs-human")) and $nh[.number | tostring] != null
      and ($t - ($nh[.number | tostring] | fromdateiso8601)) > 86400)
    | {number, title, hours: (($t - ($nh[.number | tostring] | fromdateiso8601)) / 3600 | floor)}] as $stuck
  | [$d.prs[] | select(.failing | length > 0) | {number, title, failing}] as $failing
  | [$items[] | select(.open and (.labels | index("needs-human"))) | {number, title}] as $human
  | ($stuck | map("#\(.number) has needed a human for \(.hours) hours")) as $r1
  | ($failing | map("pull request #\(.number) fails its checks (\(.failing | join(", ")))")) as $r2
  | (if ($drift | length) > 0 then [plural($drift | length; "board drift item") + " (\($drift | map("#\(.number)") | join(", ")))"] else [] end) as $r3
  | (if ($ms | length) > 0 then {status: "OFF_TRACK", label: "Off track",
       rule: ($ms | map("milestone \(.milestone) was due \(.due) and has \(plural(.open; "open issue"))") | join("; "))}
     elif ($r1 + $r2 + $r3 | length) > 0 then {status: "AT_RISK", label: "At risk", rule: ($r1 + $r2 + $r3 | join("; "))}
     else {status: "ON_TRACK", label: "On track", rule: "no milestone past due, nothing waiting for a human for more than 24 hours, no pull request failing its checks, no drift"} end) as $h
  | ([$items[] | .status // "No Status"] | group_by(.) | map({key: .[0], value: length}) | from_entries) as $c
  | (["Backlog", "Ready", "In progress", "In review", "Done"] as $order
     | ($order + ([$c | keys[] | select(. as $k | $order | index($k) | not)] | sort)) | map(select($c[.] != null) | "\(.) \($c[.])") | join(" · ")) as $counts
  | $h + {startDate: $now[:10], targetDate: ([$dated[].due] | min | if . then .[:10] else null end),
    body: ("\($h.label): \($h.rule)\n\nBoard: \($counts)\n"
      + "Needs a human: \(if ($human | length) == 0 then "nothing" else ($human | map("#\(.number) \(.title)") | join(", ")) end)\n"
      + "Failing pull requests: \(if ($failing | length) == 0 then "none" else ($failing | map("#\(.number) \(.title)") | join(", ")) end)\n"
      + "Drift: \(if ($drift | length) == 0 then "none" else ($drift | map("#\(.number) \(.why)") | join(", ")) end)")}'

# Publishes the health of the Project as a status update (#177): $1 a board_data result, $2 the board drift, $3 now. Prints the
# update as JSON {status, label, rule, startDate, targetDate, body}; fails, saying why on stderr, when it could not be built or posted.
health_publish() {
  local nh health
  nh=$(health_needs_human "$1") || { echo "senior-mode: could not read when the tickets got needs-human; no status update posted" >&2; return 1; }
  health=$(jq -c --slurpfile drift <(printf '%s' "$2") --slurpfile nh <(printf '%s' "$nh") --arg now "$3" "$HEALTH_JQ" <<<"$1") ||
    { echo "senior-mode: could not work out the health of the Project; no status update posted" >&2; return 1; }
  project_post_update "$(jq -r .body <<<"$health")" "$(jq -r .status <<<"$health")" "$(jq -r .startDate <<<"$health")" \
    "$(jq -r '.targetDate // empty' <<<"$health")" ||
    { echo "senior-mode: could not post the status update to the Project" >&2; return 1; }
  printf '%s\n' "$health"
}
