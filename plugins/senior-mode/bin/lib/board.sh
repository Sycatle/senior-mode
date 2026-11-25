# shellcheck shell=bash
# Id of a board option cached in the config; dies naming the known fields or options.
option_id() {
  local file=$1 field=$2 option=$3 id
  jq -e --arg f "$field" '.project.fields[$f].id' "$file" >/dev/null ||
    die "unknown field $field (known: $(jq -r '.project.fields // {} | keys | join(", ")' "$file")); a config created before this field existed lacks it: rerun senior-mode setup github"
  id=$(jq -r --arg f "$field" --arg o "$option" '.project.fields[$f].options[$o] // empty' "$file")
  [ -n "$id" ] ||
    die "unknown option $option for $field (known: $(jq -r --arg f "$field" '.project.fields[$f].options | keys | join(", ")' "$file"))"
  printf '%s\n' "$id"
}

# Sets fields of an issue's Project item (pairs of field and option), using the ids cached in the
# config. A field cached without options is a text field (Paths, #174): its "option" is the text. The
# Iteration field (#180) takes an iteration title or `current`, Start and End a date as YYYY-MM-DD.
# Every pair is checked before the item is touched. Fails when gh does, even
# where `set -e` is off (a caller's `||`), so `(item_set ...) || ...` sees it.
item_set() {
  [ $# -ge 3 ] && [ $(($# % 2)) -eq 1 ] || usage
  local issue=$1 file project owner number item field option i
  local ids=() flags=()
  shift
  file=$(config_file)
  project=$(jq -r '.project.id // empty' "$file")
  owner=$(jq -r '.project.owner // empty' "$file")
  number=$(jq -r '.project.number // empty' "$file")
  [ -n "$project" ] && [ -n "$owner" ] && [ -n "$number" ] ||
    die "no Project in .claude/senior-mode.json; run /senior-mode:setup"
  for ((i = 1; i < $#; i += 2)); do
    field=${!i}
    if jq -e --arg f "$field" '.project.fields[$f] | type == "object" and .iteration == true' "$file" >/dev/null 2>&1; then
      option=$(iteration_find "${@:i+1:1}") || die "no iteration ${*:i+1:1} on the board; rerun senior-mode setup github, or extend the Iteration field in the Project settings"
      option=${option%%$'\t'*}
      flags+=(--iteration-id)
    elif jq -e --arg f "$field" '.project.fields[$f] | type == "object" and .date == true' "$file" >/dev/null 2>&1; then
      option=${*:i+1:1}
      [[ $option =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "$field takes a date as YYYY-MM-DD, not $option"
      flags+=(--date)
    elif jq -e --arg f "$field" '.project.fields[$f] | type == "object" and (has("options") | not)' "$file" >/dev/null 2>&1; then
      option=${*:i+1:1}
      flags+=(--text)
    else
      option=$(option_id "$file" "$field" "${@:i+1:1}")
      flags+=(--single-select-option-id)
    fi
    ids+=("$(jq -r --arg f "$field" '.project.fields[$f].id' "$file")" "$option")
  done
  item=$(gh_retry project item-add "$number" --owner "$owner" \
    --url "https://github.com/$(repo_slug)/issues/$issue" --format json --jq .id) || return 1
  for ((i = 0; i < ${#ids[@]}; i += 2)); do
    gh_retry project item-edit --project-id "$project" --id "$item" \
      --field-id "${ids[i]}" "${flags[i / 2]}" "${ids[i + 1]}" >/dev/null || return 1
    echo "#$issue ${*:i+1:1} = ${*:i+2:1}"
  done
}

# Prints the board fields of an issue's Project item, read in one GraphQL call: the value of one
# field (empty when it has none), or "#<issue> <field> = <value>" for each field that has one.
# shellcheck disable=SC2016 # a GraphQL query, not shell
ITEM_QUERY='query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) { issue(number: $number) { projectItems(first: 20) { nodes {
    project { id }
    fieldValues(first: 20) { nodes { ... on ProjectV2ItemFieldSingleSelectValue { name field { ... on ProjectV2FieldCommon { name } } }
      ... on ProjectV2ItemFieldTextValue { text field { ... on ProjectV2FieldCommon { name } } } } } } } } }
}'
item_get() {
  [ $# -ge 1 ] && [ $# -le 2 ] && [[ $1 =~ ^[0-9]+$ ]] || usage
  local issue=$1 field=${2:-} file project slug answer err
  file=$(config_file)
  project=$(jq -r '.project.id // empty' "$file")
  [ -n "$project" ] || die "no Project in .claude/senior-mode.json; run /senior-mode:setup"
  slug=$(repo_slug)
  answer=$(jq -nc --arg q "$ITEM_QUERY" --arg o "${slug%%/*}" --arg n "${slug#*/}" --argjson i "$issue" \
    '{query: $q, variables: {owner: $o, name: $n, number: $i}}' | gh_retry api graphql --input -) ||
    die "cannot read #$issue from GitHub"
  err=$(jq -r '.errors[0].message // empty' <<<"$answer" 2>/dev/null) || die "GitHub answered something that is not JSON"
  [ -z "$err" ] || die "GitHub refused the query for #$issue: $err"
  jq -e --arg p "$project" '[.data.repository.issue.projectItems.nodes[]? | select(.project.id == $p)] | length > 0' \
    <<<"$answer" >/dev/null || die "#$issue is not on the board"
  jq -r --arg p "$project" --arg f "$field" --arg i "$issue" '
    [.data.repository.issue.projectItems.nodes[] | select(.project.id == $p) | .fieldValues.nodes[] | select(.field.name)] | map(.name = (.name // .text))
    | if $f == "" then .[] | "#\($i) \(.field.name) = \(.name)" else (map(select(.field.name == $f) | .name)[0] // "") end' <<<"$answer"
}

# Numbers of the issues linked to an issue through a REST list (blocked_by, sub_issues).
linked() {
  gh_retry api "repos/$1/issues/$2/$3" --paginate --jq '.[].number'
}

# Adds a link unless it exists. Not retried: a POST applied before a timeout would fail again.
link() {
  local slug=$1 issue=$2 path=$3 key=$4 other=$5 existing id
  existing=$(linked "$slug" "$issue" "$path")
  ! grep -qx "$other" <<<"$existing" || return 0
  id=$(gh_retry api "repos/$slug/issues/$other" --jq .id)
  gh api -X POST "repos/$slug/issues/$issue/$path" -F "$key=$id" >/dev/null
}

# Priority a Severity implies: critical is P0, high is P1, the others none. With --priority too,
# the stricter of the two wins (the lower P number).
severity_priority() {
  case $1 in critical) echo "P0 now" ;; high) echo "P1 next" ;; esac
}

# The details of a critical risk go in a draft security advisory, private to the maintainers. A
# private repository has none: say so. The details are needed before anything is filed.
advisory() {
  local slug=$1 title=$2 details=$3 private url
  private=$(gh_retry repo view "$slug" --json isPrivate --jq .isPrivate)
  if [ "$private" = true ]; then
    echo "private repository: no security advisory opened, keep the details out of the issue"
    return 0
  fi
  [ -n "$details" ] || die "a critical risk in a public repository needs --details-file (the advisory holds the details)"
  [ "$details" != - ] || details=/dev/stdin
  url=$(jq -n --arg s "$title" --rawfile d "$details" --arg n "${slug#*/}" \
    '{summary: $s, description: $d, severity: "critical", vulnerabilities: [{package: {ecosystem: "other", name: $n}}]}' |
    gh api -X POST "repos/$slug/security-advisories" --input - --jq .html_url) || die "could not open the security advisory"
  echo "draft security advisory: $url"
}

# Creates a ticket with its board fields, milestone, type label, blocked-by links and parent epic.
# --severity adds the Severity field and the label `security`. --kind, --path and --rule (a risk
# outside the ticket) add the line `security-id: <sha256 of the three>` to the body: an open issue
# that carries it is reported and left alone. A critical one in a public repository also opens a
# draft security advisory holding --details-file, which never goes in the issue (spec 130);
# --no-advisory skips that for a risk that is no flaw of the project's own code (an alert GitHub raises).
# An open issue with the same title is reused, so a run cut short can be repeated (spec 0001 §7):
# its body, fields, milestone, label and links converge to the arguments, its Status only with --status.
issue_create() {
  local title="" body="" size="" priority="" severity="" status="" milestone="" type="" parent="" paths="" timebox=""
  local kind="" path="" rule="" details="" sid="" text private no_advisory=""
  local blockers=() edits=() file slug found number url b fields implied have
  while [ $# -gt 0 ]; do
    case $1 in -h | --help)
      echo "usage: senior-mode issue create --title <t> --body-file <file|-> --size <S|M|L> [--priority <option>] [--severity critical|high|moderate|low] [--kind <k> --path <p> --rule <r> [--details-file <file|-> | --no-advisory]] [--status <option>] [--milestone <title>] [--type feature|bug|task|chore|spike] [--timebox <N>m|<N>h|<N>[k] tokens] [--paths <globs>] [--blocked-by <n>]... [--parent <n>]"
      echo "--timebox is the timebox of a spike (--type spike needs it, no other type takes it): a duration or a token budget, written to the body as the line Timebox: <value>."
      echo "--paths is a comma-separated list of the globs the ticket touches (the board field Paths: tickets whose paths overlap never run at the same time)."
      echo "--priority is required unless --severity is critical (P0) or high (P1). --kind, --path and --rule go together and need --severity."
      return 0 ;;
    esac
    if [ "$1" = --no-advisory ]; then
      no_advisory=1
      shift
      continue
    fi
    [ $# -ge 2 ] || usage
    case $1 in
      --title) title=$2 ;;
      --body-file) body=$2 ;;
      --size) size=$2 ;;
      --priority) priority=$2 ;;
      --severity) severity=$2 ;;
      --kind) kind=$2 ;;
      --path) path=$2 ;;
      --rule) rule=$2 ;;
      --details-file) details=$2 ;;
      --status) status=$2 ;;
      --milestone) milestone=$2 ;;
      --type) type=$2 ;;
      --timebox) timebox=$2 ;;
      --paths) paths=$2 ;;
      --blocked-by) blockers+=("$2") ;;
      --parent) parent=$2 ;;
      *) usage ;;
    esac
    shift 2
  done
  case $severity in "" | critical | high | moderate | low) ;; *) die "unknown severity $severity (critical, high, moderate, low)" ;; esac
  implied=$(severity_priority "$severity")
  [ -n "$priority" ] || priority=$implied
  [ -n "$title" ] && [ -n "$size" ] && [ -n "$priority" ] ||
    die "issue create needs --title, --body-file, --size and --priority (optional with --severity critical or high)"
  [ "$body" = - ] || [ -f "$body" ] || die "no body file: $body"
  if [ -n "$kind$path$rule" ]; then
    [ -n "$kind" ] && [ -n "$path" ] && [ -n "$rule" ] || die "--kind, --path and --rule go together, none empty"
    [ -n "$severity" ] || die "--kind, --path and --rule need --severity"
    case $kind$path$rule in *$'\n'*) die "--kind, --path and --rule cannot hold a newline" ;; esac
    sid=$(printf '%s\n%s\n%s\n' "$kind" "$path" "$rule" | sha256sum | cut -d' ' -f1)
  fi
  if [ -n "$details" ]; then
    [ "$severity" = critical ] && [ -n "$sid" ] || die "--details-file is for a critical risk with --kind, --path and --rule"
    [ "$details" = - ] || [ -f "$details" ] || die "no details file: $details"
    [ "$details" != - ] || [ "$body" != - ] || die "--body-file and --details-file cannot both read stdin"
  fi
  [ -z "$no_advisory" ] || [ -z "$details" ] || die "--no-advisory and --details-file exclude each other"
  case $type in "" | feature | bug | task | chore | spike) ;; *) die "unknown type $type (feature, bug, task, chore, spike)" ;; esac
  # A spike (#321) is timeboxed: a duration (45m, 2h) or a token budget (200000 tokens, 200k tokens); only a spike has one.
  if [ "$type" = spike ]; then
    [[ $timebox =~ ^([1-9][0-9]*[mh]|[1-9][0-9]*k?\ tokens)$ ]] ||
      die "a spike needs --timebox, a duration (45m, 2h) or a token budget (200k tokens), not '$timebox'"
  else
    [ -z "$timebox" ] || die "--timebox is for --type spike"
  fi
  if [ -n "$paths" ]; then
    case $paths in *$'\n'*) die "--paths cannot hold a newline" ;; esac
    paths=$(printf '%s' "$paths" | sed -E 's/[[:space:]]*,[[:space:]]*/,/g; s/^[[:space:],]+//; s/[[:space:],]+$//; s/,+/,/g')
    [ -n "$paths" ] || die "--paths holds no glob"
  fi
  # ${a[@]+...}: an empty array is unbound under set -u before bash 4.4.
  for b in ${blockers[@]+"${blockers[@]}"}; do
    [[ $b =~ ^[1-9][0-9]*$ ]] || die "not an issue number: $b"
  done
  [ -z "$parent" ] || [[ $parent =~ ^[1-9][0-9]*$ ]] || die "not an issue number: $parent"
  file=$(config_file)
  [ -z "$priority" ] || option_id "$file" Priority "$priority" >/dev/null
  if [ -n "$implied" ]; then
    [[ $priority =~ ^P([0-9]+) ]] && have=${BASH_REMATCH[1]} || have=99
    [[ $implied =~ ^P([0-9]+) ]]
    [ "$have" -lt "${BASH_REMATCH[1]}" ] || priority=$implied
  fi
  fields=(Priority "$priority" Size "$size")
  [ -z "$severity" ] || fields+=(Severity "$severity")
  if [ -n "$paths" ]; then
    jq -e '.project.fields.Paths.id' "$file" >/dev/null ||
      die "no Paths field in .claude/senior-mode.json; a config created before it existed lacks it: rerun senior-mode setup github"
    fields+=(Paths "$paths")
  fi
  option_id "$file" Size "$size" >/dev/null
  [ -z "$severity" ] || option_id "$file" Severity "$severity" >/dev/null
  option_id "$file" Priority "$priority" >/dev/null
  option_id "$file" Status "${status:-Backlog}" >/dev/null
  slug=$(repo_slug)

  if [ -n "$sid" ]; then
    found=$(gh_retry issue list --repo "$slug" --state open --limit 1000 --json number,title,body,labels |
      jq -r --arg l "security-id: $sid" 'first(.[] | select(any(.labels[]?; .name == "security") and ((.body // "") | split("\n") | index($l))) | "#\(.number) \(.title)") // empty')
    if [ -n "$found" ]; then
      echo "$found (already filed, security-id ${sid:0:12})"
      return 0
    fi
    # Read once, before anything is created: stdin is gone after the first read.
    text=$(cat "$body")
    [ "$severity" != critical ] || [ -n "$no_advisory" ] || advisory "$slug" "$title" "$details"
    body=$(mktemp)
    printf '%s\n\nsecurity-id: %s\n' "$text" "$sid" >"$body"
  fi
  # What an unattended session files ends with `filed-by: agent`: `ready` applies its stricter rule to it (#154).
  # The timebox of a spike is a line of its body, `Timebox: <value>`, read by the daemon (#321).
  if [ -n "${SENIOR_MODE_RUN:-}$timebox" ]; then
    if [ -z "$sid" ]; then
      text=$(cat "$body")
      body=$(mktemp)
      printf '%s\n' "$text" >"$body"
    fi
    [ -z "$timebox" ] || printf '\nTimebox: %s\n' "$timebox" >>"$body"
    [ -z "${SENIOR_MODE_RUN:-}" ] || printf '\nfiled-by: agent\n' >>"$body"
  fi

  # The number of an open issue with this title, then its type labels other than the asked one.
  # With a fingerprint only the security-id matches: another issue of the same title is left alone.
  [ -n "$sid" ] || found=$(gh_retry issue list --repo "$slug" --state open --limit 1000 --json number,title,labels |
    jq -r --arg t "$title" --arg k "type:$type" 'first(.[] | select(.title == $t)
      | [.number | tostring] + [.labels[]?.name | select(startswith("type:") and . != $k)]
      | join("\n")) // empty')
  number=$(head -1 <<<"$found")
  if [ -n "$number" ]; then
    echo "#$number $title (already open, body updated)"
    [ -z "$milestone" ] || edits+=(--milestone "$milestone")
    [ -z "$severity" ] || edits+=(--add-label security)
    if [ -n "$type" ]; then
      edits+=(--add-label "$(workflow_label "" "type:$type")")
      while IFS= read -r b; do
        [ -z "$b" ] || edits+=(--remove-label "$b")
      done <<<"$(tail -n +2 <<<"$found")"
    fi
    [ ${#edits[@]} -eq 0 ] || gh_retry issue edit "$number" --repo "$slug" "${edits[@]}" >/dev/null
    # Not retried: a body read from stdin is gone after the first attempt.
    gh issue edit "$number" --repo "$slug" --body-file "$body" >/dev/null
  else
    url=$(gh issue create --repo "$slug" --title "$title" --body-file "$body" \
      ${milestone:+--milestone "$milestone"} ${type:+--label "$(workflow_label "" "type:$type")"} ${severity:+--label security})
    number=${url##*/}
    echo "#$number $title (created)"
    status=${status:-Backlog}
  fi
  [ -z "$sid${SENIOR_MODE_RUN:-}$timebox" ] || rm -f "$body"
  [ -z "$status" ] || fields=(Status "$status" "${fields[@]}")
  item_set "$number" "${fields[@]}"
  for b in ${blockers[@]+"${blockers[@]}"}; do
    link "$slug" "$number" dependencies/blocked_by issue_id "$b"
    echo "#$number blocked by #$b"
  done
  if [ -n "$parent" ]; then
    link "$slug" "$parent" sub_issues sub_issue_id "$number"
    echo "#$number under #$parent"
  fi
}

# The open alerts GitHub itself raises (#172), as one JSON object per line: severity, kind, path and
# rule for `issue create`, a title and a body. Only high and critical Dependabot alerts count (GitHub
# says "medium" where we say moderate); a secret-scanning alert is critical. The body names the alert
# and where to read it, never the vulnerability's details, and the secret's value is never read.
# shellcheck disable=SC2016 # jq programs, not shell
DEPENDABOT_ALERTS_JQ='.[] | select(.state == "open" and (.security_advisory.severity | IN("high", "critical")))
  | .security_advisory.severity as $sev | .security_advisory.ghsa_id as $id | .dependency.package.name as $pkg
  | (.dependency.manifest_path // "unknown") as $manifest | .html_url as $url
  | {severity: $sev, kind: "dependabot", path: $manifest, rule: "\($id) \($pkg)",
     title: "Update \($pkg): \($sev) Dependabot alert (\($id))",
     body: "## Context\n\nDependabot reports an open \($sev) alert on `\($pkg)` (\(.dependency.package.ecosystem)) in `\($manifest)`: \($id).\nAlert: \($url)\n\n## Acceptance criteria\n\n- Given the alert is open, when `\($pkg)` is updated to a patched version or removed, then the alert closes.\n"}
  | @json'
# shellcheck disable=SC2016 # jq programs, not shell
SECRET_ALERTS_JQ='.[] | select(.state == "open") | .number as $n | .secret_type as $type
  | (.secret_type_display_name // $type) as $name | .html_url as $url
  | {severity: "critical", kind: "secret-scanning", path: "alerts/\($n)", rule: $type,
     title: "Revoke exposed secret: \($name) (alert #\($n))",
     body: "## Context\n\nGitHub secret scanning reports an exposed \($name) in this repository. The value is not repeated here.\nAlert: \($url)\n\n## Acceptance criteria\n\n- Given the secret is exposed, when it is revoked at its provider and removed from the repository, then the alert is resolved.\n"}
  | @json'

# Files one issue for each open high or critical Dependabot alert and each open secret-scanning alert
# (treated as critical), through `issue create` with a fingerprint, so a second pass files nothing
# new (#144, #172). Below high nothing is filed. An alert source GitHub refuses (scanning not enabled,
# no permission, 404) or an issue that cannot be filed is said on stderr and never stops the caller.
security_alerts() {
  local slug source prog alerts line sev kind path rule title body
  slug=$(repo_slug)
  for source in dependabot secret-scanning; do
    case $source in dependabot) prog=$DEPENDABOT_ALERTS_JQ ;; *) prog=$SECRET_ALERTS_JQ ;; esac
    if ! alerts=$(gh_retry api "repos/$slug/$source/alerts?state=open&per_page=100" --paginate --jq "$prog" 2>&1); then
      echo "security alerts: $source alerts not read ($(head -n 1 <<<"${alerts#gh: }"))" >&2
      continue
    fi
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      IFS=$'\t' read -r sev kind path rule title < <(jq -r '[.severity, .kind, .path, .rule, .title] | @tsv' <<<"$line")
      body=$(mktemp)
      jq -r .body <<<"$line" >"$body"
      "$SELF" issue create --title "$title" --body-file "$body" --size S --severity "$sev" \
        --kind "$kind" --path "$path" --rule "$rule" --no-advisory </dev/null ||
        echo "security alerts: $kind alert $rule not filed" >&2
      rm -f "$body"
    done <<<"$alerts"
  done
}

# The open tickets of the Project with what the Definition of Ready reads (#154), as a JSON array: number,
# status, priority, size, severity, labels, body, `agent` (the body ends with the `filed-by: agent` line that
# `issue create` adds in an unattended session) and `paths`: the globs of the text field Paths, split on
# commas and spaces, brackets and quotes ignored. Paths is read here, not from the board query of `pick`: a
# Project without the field (not set up yet) gives no Paths, which the Definition of Ready counts as missing.
# shellcheck disable=SC2016 # GraphQL and jq programs, not shell
READY_QUERY='query($project: ID!, $after: String) { node(id: $project) { ... on ProjectV2 { items(first: 100, after: $after) {
  pageInfo { hasNextPage endCursor }
  nodes { fieldValues(first: 20) { nodes {
      ... on ProjectV2ItemFieldSingleSelectValue { name field { ... on ProjectV2FieldCommon { name } } }
      ... on ProjectV2ItemFieldTextValue { text field { ... on ProjectV2FieldCommon { name } } } } }
    content { ... on Issue { number state body labels(first: 20) { nodes { name } } } } } } } } }'
# The Status of an item, GitHub's default Todo read as Backlog (#556): on some organisations an option named Backlog
# makes GitHub put every issue back to it after each move, so the board keeps Todo. Needs a def single($f).
# shellcheck disable=SC2016 # a jq program, not shell
STATUS_DEF='def status: single("Status") | if . != null and ascii_downcase == "todo" then "Backlog" else . end;'
# shellcheck disable=SC2016 # a jq program, not shell
READY_ITEMS='def single($f): [.fieldValues.nodes[]? | select(.field.name == $f and .name != null) | .name][0];
  def text($f): [.fieldValues.nodes[]? | select(.field.name == $f and .text != null) | .text][0];
  '$STATUS_DEF'
  [.[].data.node.items.nodes[]? | select(.content.number != null) | .content as $c
    | {number: $c.number, open: ($c.state == "OPEN"), body: ($c.body // ""), labels: [$c.labels.nodes[].name], assoc: $c.authorAssociation,
       status: status, priority: single("Priority"), size: single("Size"), severity: single("Severity"),
       agent: (($c.body // "") | test("(^|\n)filed-by: agent[ \t]*(\n|$)")),
       paths: ((text("Paths") // "") | gsub("[\\[\\]\"\u0027]"; "") | [split("[,\\s]+"; null)[] | select(length > 0)])}]'
ready_items() {
  local file project slug page pages="[]" after="" more=true count=0 err
  file=$(config_file)
  project=$(jq -r '.project.id // empty' "$file")
  [ -n "$project" ] || die "no Project in .claude/senior-mode.json; run /senior-mode:setup"
  slug=$(repo_slug)
  while [ "$more" = true ]; do
    page=$(jq -nc --arg q "$READY_QUERY" --arg p "$project" --arg a "$after" \
      '{query: $q, variables: ({project: $p} + (if $a == "" then {} else {after: $a} end))}' | gh_retry api graphql --input -) ||
      die "cannot read the Project from GitHub"
    err=$(jq -r '.errors[0].message // empty' <<<"$page" 2>/dev/null) || die "GitHub answered something that is not JSON"
    [ -z "$err" ] || die "GitHub refused the Project query: $err"
    pages=$(json_append "$pages" "$page")
    more=$(jq -r '.data.node.items.pageInfo.hasNextPage // false' <<<"$page")
    after=$(jq -r '.data.node.items.pageInfo.endCursor // empty' <<<"$page")
    count=$((count + 1))
    [ "$count" -lt 20 ] || break
  done
  jq -c "$READY_ITEMS" <<<"$pages" || die "could not read the Project"
}

# The protected globs, JSON, as the default branch has them (a branch cannot lift its own zone), else as the
# working tree has them.
ready_zones() {
  local base zones
  if base=$(default_branch) && git cat-file -e "$base:.claude/senior-mode.json" 2>/dev/null; then
    zones=$(git show "$base:.claude/senior-mode.json" | jq -c '.protected // []') || zones=null
  else
    zones=$(jq -c '.protected // []' "$(config_file)")
  fi
  jq -e 'type == "array" and all(type == "string")' <<<"$zones" >/dev/null ||
    die "protected in .claude/senior-mode.json must be an array of globs"
  printf '%s\n' "$zones"
}

# Whether the Paths glob $2 may reach a protected zone of the JSON list $1. An approximation, on the side of
# caution: the glob, or a file name made of it (`*` as x, its fixed start plus a name), matches a protected
# glob as `protected` reads them, or a protected glob anchored in a directory shares its fixed start with it.
ready_in_zone() {
  local zones=$1 path=${2#/} lit zone fixed
  lit=${path%%[*?[]*}
  [ -z "$(printf '%s\n' "$path" "${path//[*?]/x}" "${lit}x" | protected_match "$zones")" ] || return 0
  [ -n "$lit" ] || return 1
  while IFS= read -r zone; do
    zone=${zone#/}
    [[ $zone == */* ]] || continue
    fixed=${zone%%[*?[]*}
    [[ $fixed == "$lit"* || $lit == "$fixed"* ]] && return 0
  done < <(jq -r '.[]' <<<"$zones")
  return 1
}

# What stops the ticket $1 (an item of ready_items) from being Ready, as a JSON array of reasons, empty when
# nothing does. The Definition of Ready for any ticket: acceptance criteria (a list under an "Acceptance
# criteria" heading), Size, Priority, Paths. A ticket an agent filed, with $2 the protected globs: also size S,
# no high or critical security severity, no Paths in a protected zone.
# shellcheck disable=SC2016 # a jq program, not shell
ready_missing() {
  local it=$1 zones=$2 reasons hits="" p
  reasons=$(jq -c '[(if (.body | test("(^|\n)#{1,6}[ \t]*acceptance criteria[ \t]*\n+[ \t]*([-*]|[0-9]+[.)])[ \t]+\\S"; "i")) then empty else "acceptance criteria" end),
    (if .size == null then "Size" else empty end), (if .priority == null then "Priority" else empty end),
    (if (.paths | length) == 0 then "Paths" else empty end),
    (if .agent then
      (if .size != null and .size != "S" then "size \(.size) (a ticket an agent filed is Ready only when S)" else empty end),
      (if .severity == "high" or .severity == "critical" then "\(.severity) security severity (a ticket an agent filed is never Ready by rule)" else empty end)
     else empty end)]' <<<"$it")
  if jq -e .agent <<<"$it" >/dev/null; then
    while IFS= read -r p; do
      ! ready_in_zone "$zones" "$p" || hits+=${hits:+, }$p
    done < <(jq -r '.paths[]' <<<"$it")
    [ -z "$hits" ] || reasons=$(jq -c --arg h "$hits" '. + ["protected zone: \($h)"]' <<<"$reasons")
  fi
  printf '%s\n' "$reasons"
}

# The tickets a pull request body closes (Closes, Fixes or Resolves #n, any case), one number a line, sorted.
pr_closed_tickets() {
  grep -oiE '\b(close[sd]?|fix(e[sd])?|resolve[sd]?)[: ]+#[0-9]+' <<<"$1" | grep -oE '[0-9]+$' | sort -nu || true
}

# Whether a changed file counts towards the size budget of a pull request (#303): not a lockfile, a generated
# file or a fixture.
diff_countable() {
  case $1 in
    docs/incidents/* | *.lock | package-lock.json | */package-lock.json | npm-shrinkwrap.json | */npm-shrinkwrap.json | pnpm-lock.yaml | */pnpm-lock.yaml | \
      bun.lockb | */bun.lockb | go.sum | */go.sum | *.min.js | *.min.css | *.map | *.snap | *.pb.go | *_pb2.py | *.generated.* | *_generated.* | \
      dist/* | */dist/* | generated/* | */generated/* | __generated__/* | */__generated__/* | \
      fixtures/* | */fixtures/* | fixture/* | */fixture/* | __fixtures__/* | */__fixtures__/* | testdata/* | */testdata/* | \
      fixture-* | */fixture-* | *.fixture.*) return 1 ;;
  esac
}

# What stops the pull request $2 of $1 (owner/name) from being ready to merge on account of the tickets it
# closes, in one phrase, or nothing. $3 is its REST object and $4 its changed files as `<path>\t<changed lines>`
# lines. Starts with "not ready: " when the pull request itself is at fault (#297, #303):
# - it closes a spike ticket (label type:spike) and changes a file outside docs/ (#321);
# - it closes several tickets and some are named by no commit (`Refs #n` or `Closes #n`): one commit per ticket;
# - its changed lines, lockfiles, generated and fixture files left out, exceed the sum of the budgets
#   (limits.diffLines) of the Size of the tickets it closes.
# A pull request that closes no ticket, or one, with a commit of its own, is only held to the second rule.
# Other phrases say what could not be read.
# The acceptance criteria of the tickets $3... that the "Self-review" table of the pull request body $2 lacks
# or leaves without evidence (#356), as "#<n>.<k>" words. A criterion is a top-level bullet under the
# "Acceptance criteria" heading of the issue; its row starts with `#<n>.<k>` (or `<k>` when the pull request
# closes one ticket) and its last cell is the evidence. Exit 1 when an issue cannot be read.
self_review_gaps() {
  local slug=$1 body=$2 n issue gaps=""
  shift 2
  for n in "$@"; do
    issue=$(gh_retry issue view "$n" --repo "$slug" --json body 2>/dev/null) || return 1
    gaps+=$(jq -r --arg n "$n" --arg pr "$body" --argjson one "$([ $# -eq 1 ] && echo true || echo false)" '
      [(.body // "") | split("\n") | foreach .[] as $l ({in: false};
          if ($l | test("^#{1,6}\\s")) then .in = ($l | test("^#{1,6}\\s+acceptance criteria"; "i")) else . end;
          select(.in and ($l | test("^[-*]\\s"))) | 1)] | length as $count
      | [$pr | split("\n") | foreach .[] as $l ({in: false};
          if ($l | test("^#{1,6}\\s")) then .in = ($l | test("^#{1,6}\\s+self-review"; "i")) else . end;
          select(.in and ($l | test("^\\s*\\|"))) | $l)] as $rows
      | [$rows[] | [split("|")[1:-1][] | gsub("^\\s+|\\s+$"; "")]] as $cells
      | [range(1; $count + 1) as $k | select([$cells[] | select(length >= 2
            and (.[0] | test("^(#?\($n)\\.\($k)" + (if $one then "|\($k)" else "" end) + ")(\\b|[^0-9]|$)"))
            and (.[-1] | test("^(-+|todo|n/a|tbd)?$"; "i") | not))] | length == 0) | "#\($n).\($k)"] | join(" ")' <<<"$issue" 2>/dev/null) || return 1
    gaps+=" "
  done
  printf '%s\n' "$gaps" | tr -s ' ' | sed 's/^ //; s/ $//'
}

delivery_blocker() {
  local slug=$1 pr=$2 pull=$3 files=$4 tickets=() n missing="" msgs size cfg budget total=0 lines=0 path changed sizes="" gaps outside spike hot hotfix=false
  mapfile -t tickets < <(pr_closed_tickets "$(jq -r '.body // ""' <<<"$pull")")
  [ "${#tickets[@]}" -gt 0 ] || return 0
  # A spike (#321) ends in a note, an ADR or framed tickets, never in code: only docs/ may change.
  outside=$(printf '%s\n' "$files" | cut -f1 | grep -v '^$' | grep -v '^docs/' | paste -sd, - | sed 's/,/, /g') || outside=""
  if [ -n "$outside" ]; then
    for n in "${tickets[@]}"; do
      spike=$(gh_retry issue view "$n" --repo "$slug" --json labels) || {
        echo "the type of #$n could not be read"
        return 0
      }
      ! jq -e '[.labels[]?.name] | index("type:spike") != null' <<<"$spike" >/dev/null || {
        echo "not ready: #$n is a spike and its pull request changes code outside docs/ ($outside)"
        return 0
      }
    done
  fi
  if [ "${#tickets[@]}" -gt 1 ]; then
    msgs=$(gh_retry api "repos/$slug/pulls/$pr/commits" --paginate --jq '.[].commit.message') || {
      echo "its commits could not be read"
      return 0
    }
    for n in "${tickets[@]}"; do
      grep -qiE "\b(refs?|closes?|fix(es)?|resolves?)[: ]+#$n([^0-9]|\$)" <<<"$msgs" || missing+=${missing:+, }#$n
    done
    [ -z "$missing" ] || {
      echo "not ready: it closes ${#tickets[@]} tickets and no commit references $missing (one commit per ticket, ending with Refs #n or Closes #n)"
      return 0
    }
  fi
  cfg=$(config_get limits.diffLines 2>/dev/null) || cfg=null
  jq -e 'type == "object" and all(.[]; type == "number" and . > 0 and . == floor)' <<<"$cfg" >/dev/null 2>&1 ||
    {
      echo "limits.diffLines must be positive whole numbers by size (S, M, L)"
      return 0
    }
  for n in "${tickets[@]}"; do
    hot=$(ticket_hotfix "$slug" "$n") || {
      echo "the labels of #$n could not be read"
      return 0
    }
    # A hotfix (#322) is held to the S budget, whatever its Size.
    if [ "$hot" = yes ]; then
      hotfix=true
      size=S
    else
      size=$( (item_get "$n" Size) 2>/dev/null) || size=""
    fi
    [ -n "$size" ] || {
      echo "the Size of #$n is unknown"
      return 0
    }
    budget=$(jq -r --arg s "$size" '.[$s] // empty' <<<"$cfg")
    [ -n "$budget" ] || {
      echo "limits.diffLines has no budget for the size $size of #$n"
      return 0
    }
    total=$((total + budget))
    sizes+=${sizes:+, }"#$n $size"
    [ "$hot" != yes ] || sizes+=" hotfix"
  done
  # The whole pull request of a hotfix is capped at one S, not at the sum of its tickets.
  [ "$hotfix" != true ] || total=$(jq -r '.S' <<<"$cfg")
  while IFS=$'\t' read -r path changed; do
    [[ ${changed:-} =~ ^[0-9]+$ ]] || continue
    ! diff_countable "$path" || lines=$((lines + changed))
  done <<<"$files"
  [ "$lines" -le "$total" ] || {
    echo "not ready: $lines changed lines, $((lines - total)) over the size budget of $total (limits.diffLines: $sizes)"
    return 0
  }
  gaps=$(skeleton_blocker "$slug" "$pr" "$pull" "$files")
  [ -z "$gaps" ] || {
    echo "$gaps"
    return 0
  }
  gaps=$(self_review_gaps "$slug" "$(jq -r '.body // ""' <<<"$pull")" "${tickets[@]}") || {
    echo "the acceptance criteria of its tickets could not be read"
    return 0
  }
  [ -z "$gaps" ] ||
    echo "not ready: the Self-review table has no row with evidence for ${gaps// /, } (one row per acceptance criterion: | #<ticket>.<k> criterion | evidence |)"
}

# senior-mode ready --pr <n> on an open pull request that is no framing one: whether it is ready to merge on
# account of its tickets (see delivery_blocker). Says so, and fails when it is not.
ready_delivery() {
  local slug=$1 pr=$2 pull files reason
  pull=$(gh_retry api "repos/$slug/pulls/$pr") || die "cannot read pull request #$pr"
  files=$(gh_retry api "repos/$slug/pulls/$pr/files" --paginate --jq '.[] | "\(.filename)\t\(.changes // 0)"') ||
    die "cannot read the files of pull request #$pr"
  reason=$(delivery_blocker "$slug" "$pr" "$pull" "$files")
  case $reason in
    "") echo "pull request #$pr is ready" ;;
    "not ready: "*)
      echo "pull request #$pr is $reason"
      return 1
      ;;
    *)
      echo "pull request #$pr cannot be checked: $reason"
      return 1
      ;;
  esac
}

# senior-mode ready [--pr <n>] [--dry-run]: tickets become Ready by rule, with no human step (#154).
# Candidates are the Backlog tickets without `needs-human` or `needs-info`: with --pr, those the merged
# framing pull request n (branch docs/...) names; without it, those an agent filed. A ticket with nothing
# missing (see ready_missing) is set Ready; any other gets `needs-human` and a comment that says what is
# missing, and is left alone until a person removes the label. --dry-run only says what would happen.
ready() {
  local pr="" dry=false slug info items zones nums="null" it n why
  while [ $# -gt 0 ]; do
    case $1 in
      --pr)
        [[ ${2:-} =~ ^[1-9][0-9]*$ ]] || usage
        pr=$2
        shift
        ;;
      --dry-run) dry=true ;;
      *) usage ;;
    esac
    shift
  done
  slug=$(repo_slug)
  if [ -n "$pr" ]; then
    info=$(gh_retry pr view "$pr" --repo "$slug" --json state,headRefName,body) || die "cannot read pull request #$pr"
    # An open pull request that is no framing one is a delivery: whether it is ready to merge (#297, #303).
    if [ "$(jq -r '.state' <<<"$info")" = OPEN ] && [[ $(jq -r '.headRefName' <<<"$info") != docs/* ]]; then
      ready_delivery "$slug" "$pr"
      return
    fi
    [ "$(jq -r '.state' <<<"$info")" = MERGED ] || die "pull request #$pr is not merged: its tickets are not Ready until it is"
    [[ $(jq -r '.headRefName' <<<"$info") == docs/* ]] ||
      die "pull request #$pr is not a framing pull request (its branch is not docs/...)"
    nums=$(jq -c --argjson pr "$pr" '[(.body // "") | scan("#([0-9]+)") | .[0] | tonumber | select(. != $pr)] | unique' <<<"$info")
  fi
  items=$(ready_items) || exit 1
  zones=$(ready_zones) || exit 1
  while IFS= read -r it; do
    n=$(jq -r '.number' <<<"$it")
    why=$(ready_missing "$it" "$zones" | jq -r 'join(", ")')
    if [ -z "$why" ]; then
      if [ "$dry" = true ]; then echo "#$n would be Ready"; else item_set "$n" Status Ready || echo "#$n: could not set Ready" >&2; fi
    elif [ "$dry" = true ]; then
      echo "#$n would get needs-human: $why"
    else
      gh_retry api "repos/$slug/issues/$n/labels" -f 'labels[]=needs-human' >/dev/null ||
        echo "#$n: could not label the ticket needs-human" >&2
      gh_bound api "repos/$slug/issues/$n/comments" -f body="senior-mode: this ticket is not Ready by rule. Missing: $why. Fix it and remove the needs-human label; \`senior-mode ready\` checks it again." \
        >/dev/null || echo "#$n: could not comment on the ticket" >&2
      echo "#$n needs-human: $why"
    fi
  done < <(jq -c --argjson nums "$nums" "$TRUST_DEF"'.[] | select(.open and trusted and .status == "Backlog" and (.labels | index("needs-human") | not)
    and (.labels | index("needs-info") | not)) | select(if $nums == null then .agent else (.number | IN($nums[])) end)' <<<"$items")
}

# What the hygiene report reads of a pull request and of a branch (the board query and its follow-up).
HYGIENE_PR_FIELDS='number title headRefName baseRefName isDraft isCrossRepository authorAssociation author { login } updatedAt body'
HYGIENE_BRANCH_FIELDS='name branchProtectionRule { id } associatedPullRequests(first: 1) { totalCount } target { oid ... on Commit { committedDate } }'

# The Project items, and with $1 = true the repository facts that `status` adds, in one GraphQL
# query (spec 0001 §7, §15); only a Project of more than 100 items takes a second call.
# shellcheck disable=SC2016 # a GraphQL query, not shell
BOARD_QUERY='query($project: ID!, $owner: String!, $name: String!, $after: String, $repo: Boolean!) {
  node(id: $project) { ... on ProjectV2 { items(first: 100, after: $after) {
    pageInfo { hasNextPage endCursor }
    nodes {
      id isArchived updatedAt
      fieldValues(first: 20) { nodes { ... on ProjectV2ItemFieldSingleSelectValue { name field { ... on ProjectV2FieldCommon { name } } }
        ... on ProjectV2ItemFieldTextValue { text field { ... on ProjectV2FieldCommon { name } } } } }
      content { ... on Issue { number title url state closedAt updatedAt authorAssociation labels(first: 20) { nodes { name } }
        milestone { title dueOn } blockedBy(first: 20) { nodes { number state } }
        comments(last: 1) { nodes { body authorAssociation } } } } } } } }
  repository(owner: $owner, name: $name) @include(if: $repo) {
    latestRelease { tagName publishedAt }
    defaultBranchRef { name }
    branches: refs(refPrefix: "refs/heads/", first: 100) { pageInfo { hasNextPage endCursor }
      nodes { '"$HYGIENE_BRANCH_FIELDS"' } }
    pullRequests(states: OPEN, first: 50) { pageInfo { hasNextPage endCursor }
      nodes { '"$HYGIENE_PR_FIELDS"' url labels(first: 10) { nodes { name } }
      comments(last: 1) { nodes { body authorAssociation } }
      commits(last: 1) { nodes { commit { statusCheckRollup { state contexts(first: 30) { nodes { __typename
        ... on StatusContext { context state } ... on CheckRun { name conclusion } } } } } } } } }
    closed: issues(states: CLOSED, first: 50, orderBy: {field: UPDATED_AT, direction: DESC}) { nodes { number title closedAt stateReason } }
    merged: pullRequests(states: MERGED, first: 50, orderBy: {field: UPDATED_AT, direction: DESC}) { nodes { number title mergedAt } }
  }
}'

# The pages of branches and open pull requests the board query leaves out, for the hygiene report: it
# judges a branch by its pull requests and a ticket by its pull request, so it needs every one.
# shellcheck disable=SC2016 # a GraphQL query, not shell
HYGIENE_MORE_QUERY='query($owner: String!, $name: String!, $prs: Boolean!, $branches: Boolean!, $prsAfter: String, $branchesAfter: String) {
  repository(owner: $owner, name: $name) {
    pullRequests(states: OPEN, first: 100, after: $prsAfter) @include(if: $prs) { pageInfo { hasNextPage endCursor }
      nodes { '"$HYGIENE_PR_FIELDS"' } }
    branches: refs(refPrefix: "refs/heads/", first: 100, after: $branchesAfter) @include(if: $branches) { pageInfo { hasNextPage endCursor }
      nodes { '"$HYGIENE_BRANCH_FIELDS"' } }
  }
}'

# How the hygiene report keeps a pull request and a branch.
# shellcheck disable=SC2016 # a jq program, not shell
HYGIENE_NODES='def hpr: {number, title, branch: .headRefName, base: .baseRefName, draft: .isDraft, fork: .isCrossRepository,
    author: .author.login, association: .authorAssociation, updatedAt, body};
  def hbr: {name, prs: .associatedPullRequests.totalCount, protected: (.branchProtectionRule != null), oid: .target.oid, date: .target.committedDate};
  def more($p): if $p.hasNextPage then $p.endCursor else null end;'

# Reads the pages of open pull requests and branches after the first one (in $1, a board_data result with
# its `hygiene` cursors) and returns the result with the whole lists.
# shellcheck disable=SC2016 # a jq program, not shell
board_more() {
  local data=$1 slug after_prs after_branches page count=0 err
  slug=$(repo_slug)
  while :; do
    after_prs=$(jq -r '.hygiene.prsMore // empty' <<<"$data")
    after_branches=$(jq -r '.hygiene.branchesMore // empty' <<<"$data")
    [ -n "$after_prs$after_branches" ] || break
    count=$((count + 1))
    [ "$count" -le 20 ] || die "more than 2000 open pull requests or branches: cannot judge the repository hygiene"
    page=$(jq -nc --arg q "$HYGIENE_MORE_QUERY" --arg o "${slug%%/*}" --arg n "${slug#*/}" --arg p "$after_prs" --arg b "$after_branches" \
      '{query: $q, variables: ({owner: $o, name: $n, prs: ($p != ""), branches: ($b != "")}
      + (if $p == "" then {} else {prsAfter: $p} end) + (if $b == "" then {} else {branchesAfter: $b} end))}' | gh_retry api graphql --input -) ||
      die "cannot read the pull requests and branches from GitHub"
    err=$(jq -r '.errors[0].message // empty' <<<"$page" 2>/dev/null) || die "GitHub answered something that is not JSON"
    [ -z "$err" ] || die "GitHub refused the pull request query: $err"
    data=$(jq -c --slurpfile page <(printf '%s' "$page") "$HYGIENE_NODES"'$page[0].data.repository as $r | .hygiene as $h
      | .hygiene.prs += [$r.pullRequests.nodes[]? | hpr] | .hygiene.branches += [$r.branches.nodes[]? | hbr]
      | .hygiene.prsMore = (if $r.pullRequests then more($r.pullRequests.pageInfo) else null end)
      | .hygiene.branchesMore = (if $r.branches then more($r.branches.pageInfo) else null end)' <<<"$data") ||
      die "could not read the pull requests and branches"
  done
  printf '%s\n' "$data"
}

# Runs the GraphQL query on stdin (gh_retry). A fine-grained token cannot read check runs (#548): GitHub answers
# with the data and a FORBIDDEN error per CheckRun of a statusCheckRollup, and gh fails. Such an answer is kept,
# its errors dropped (the unreadable contexts count as not failing); any other error fails as before.
board_graphql() {
  local query out err
  query=$(cat)
  err=$(mktemp)
  if out=$(gh_retry api graphql --input - <<<"$query" 2>"$err"); then
    rm -f "$err"
    printf '%s\n' "$out"
    return 0
  fi
  out=$(gh_bound api graphql --input - <<<"$query" 2>/dev/null) || true
  if jq -e '.data != null and (.errors | length > 0)
      and all(.errors[]; .type == "FORBIDDEN" and ((.path // []) | index("statusCheckRollup")))' <<<"$out" >/dev/null 2>&1; then
    rm -f "$err"
    jq -c 'del(.errors)' <<<"$out"
    return 0
  fi
  cat "$err" >&2
  rm -f "$err"
  return 1
}

# Prints {items, prs, closed, merged, release}: tickets with their board fields, labels, milestone and
# open blockers (an archived item (#179) is still there, `archived`); open pull requests with their failing statuses; recent closed issues and merged pull
# requests; the latest release. The last four are empty unless $1 is true.
# shellcheck disable=SC2016 # a jq program, not shell
board_data() {
  local with_repo=${1:-false} repo file project slug after="" page pages="[]" more=true count=0 err data
  repo=$with_repo
  file=$(config_file)
  project=$(jq -r '.project.id // empty' "$file")
  [ -n "$project" ] || die "no Project in .claude/senior-mode.json; run /senior-mode:setup"
  slug=$(repo_slug)
  while [ "$more" = true ]; do
    page=$(jq -nc --arg q "$BOARD_QUERY" --arg p "$project" --arg o "${slug%%/*}" --arg n "${slug#*/}" \
      --arg a "$after" --argjson r "$with_repo" '{query: $q, variables: ({project: $p, owner: $o, name: $n, repo: $r}
      + (if $a == "" then {} else {after: $a} end))}' | board_graphql) ||
      die "cannot read the Project from GitHub"
    err=$(jq -r '.errors[0].message // empty' <<<"$page" 2>/dev/null) || die "GitHub answered something that is not JSON"
    [ -z "$err" ] || die "GitHub refused the Project query: $err"
    pages=$(json_append "$pages" "$page")
    more=$(jq -r '.data.node.items.pageInfo.hasNextPage // false' <<<"$page")
    after=$(jq -r '.data.node.items.pageInfo.endCursor // empty' <<<"$page")
    with_repo=false
    count=$((count + 1))
    [ "$count" -lt 20 ] || break
  done
  data=$(jq -c "$HYGIENE_NODES"'def single($f): [.fieldValues.nodes[] | select(.field.name == $f) | .name][0];
    def text($f): [.fieldValues.nodes[] | select(.field.name == $f) | .text][0];
    '"$STATUS_DEF"'
    def failing: [.commits.nodes[0].commit.statusCheckRollup.contexts.nodes[]?
      | select((.state // "") | IN("FAILURE", "ERROR")) // select((.conclusion // "") | IN("FAILURE", "TIMED_OUT", "CANCELLED", "STARTUP_FAILURE"))
      | .context // .name];
    def lastc($n): ($n.comments.nodes[0] // null) | if . then {body, assoc: .authorAssociation} else null end;
    (.[0].data.repository // {}) as $r
    | {items: [.[].data.node.items.nodes[] | select(.content.number != null) | .updatedAt as $moved | .id as $iid | (.isArchived // false) as $arch | .content as $c
        | {number: $c.number, title: $c.title, url: $c.url, open: ($c.state == "OPEN"), itemId: $iid, archived: $arch, closedAt: $c.closedAt,
           status: status, priority: single("Priority"), size: single("Size"), severity: single("Severity"), paths: (text("Paths") // ""),
           labels: [$c.labels.nodes[].name], assoc: $c.authorAssociation, milestone: $c.milestone.title, due: $c.milestone.dueOn,
           updated: ([$c.updatedAt, $moved] | map(select(. != null)) | max),
           blockers: [$c.blockedBy.nodes[] | select(.state == "OPEN") | .number], last: lastc($c)}],
       prs: [$r.pullRequests.nodes[]? | {number, title, url, branch: .headRefName, labels: [.labels.nodes[].name], failing: failing,
         updated: .updatedAt, last: lastc(.)}],
       branches: [$r.branches.nodes[]?.name],
       hygiene: {base: $r.defaultBranchRef.name, prs: [$r.pullRequests.nodes[]? | hpr], branches: [$r.branches.nodes[]? | hbr],
         prsMore: more($r.pullRequests.pageInfo // {}), branchesMore: more($r.branches.pageInfo // {})},
       closed: [$r.closed.nodes[]? | {number, title, closedAt, reason: .stateReason}],
       merged: [$r.merged.nodes[]? | {number, title, mergedAt}],
       release: ($r.latestRelease | if . then {tag: .tagName, date: .publishedAt} else null end)}' <<<"$pages") ||
    die "could not read the Project"
  if [ "$repo" = true ]; then board_more "$data"; else printf '%s\n' "$data"; fi
}

# The trust gate (ADR 0024, #427), the one rule every selection of a ticket to work on applies (`pick`, hence
# `next`, `run` and `serve`, and `ready`): an issue is trusted when it does not carry `triage` and either its
# author is a collaborator (author_association OWNER, MEMBER or COLLABORATOR) or a collaborator qualified it
# with the label `qualified`. A missing association is not a collaborator. Its input is an item of
# board_data or ready_items.
# shellcheck disable=SC2016 # a jq program, not shell
TRUST_DEF='def trusted: . as $i | (($i.labels | index("triage")) | not)
    and ((["OWNER", "MEMBER", "COLLABORATOR"] | index($i.assoc // "")) != null or ($i.labels | index("qualified")) != null);'

# The tickets `run` and `next` take (spec 0001 §7): Ready, open, trusted, not size L, not blocked (open
# "blocked by" link, `blocked` label), not waiting for information (`needs-info`). Sorted by Priority
# (P0 first), a critical Severity ahead of the others, then milestone due date, then number.
# shellcheck disable=SC2016 # a jq program, not shell
PICK_DEF=$TRUST_DEF'def pick: [.items[] | select(.open and trusted and .status == "Ready" and .size != "L" and (.blockers | length == 0)
    and ((.labels | index("blocked")) | not) and ((.labels | index("needs-info")) | not))]
  | sort_by([([(.priority // "") | scan("^P([0-9]+)") | .[0] | tonumber] | first // 99),
    (if .severity == "critical" then 0 else 1 end), (.due // "9999"), .number]);'

# The Paths of a ticket (#174, #152): globs separated by commas. Two globs overlap when their static
# parts do: the text before the first wildcard, cut back to a whole directory when there is one, so a
# glob of one ticket matches a path prefix of the other, or is the same glob. A ticket with no Paths
# overlaps every other (it runs alone).
# shellcheck disable=SC2016 # a jq program, not shell
PATHS_DEF='def globs: (.paths // "") | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(. != ""));
  def gstatic: sub("^\\./"; "") | . as $g | (capture("^(?<s>[^*?\\[{]*)").s) as $s
    | (if $s == $g then $s else ($s | sub("[^/]*$"; "")) end) | sub("/+$"; "");
  def pclash($p; $q): $p == $q or $p == "" or $q == "" or ($q | startswith($p + "/")) or ($p | startswith($q + "/"));
  def overlap($a; $b): ($a | map(gstatic)) as $sa | ($b | map(gstatic)) as $sb | any($sa[]; . as $p | any($sb[]; pclash($p; .)));
  def collide($a; $b): ($a | length) == 0 or ($b | length) == 0 or overlap($a; $b);'

# The index in the queue of the first ticket that can start next to the running ones (#152), nothing when
# none can: `pick_free <board data> "<running numbers>" "<queued entries>"`; an entry is a ticket number or, for a
# batch (#263), its numbers joined by `+`, and the running numbers are those of every ticket of the sessions
# running. Tickets whose Paths overlap never run at the same time and a ticket with no Paths runs alone. A board
# whose tickets have no Paths at all (no Paths field) has no paths to compare: the first queued ticket is free, as
# before. What the board carries decides, not the config: a config from before the field existed still has its
# tickets compared (#344).
pick_free() {
  if ! jq -e 'any(.items[]; (.paths // "") != "")' <<<"$1" >/dev/null; then
    [ -z "$3" ] || echo 0
    return 0
  fi
  jq -r --arg r "$2" --arg q "$3" "$PATHS_DEF"'
    ($r | split(" ") | map(select(. != "") | tonumber)) as $run
    | ($q | split(" ") | map(select(. != "") | split("+") | map(tonumber))) as $queue
    | ([.items[] | {key: (.number | tostring), value: globs}] | from_entries) as $g
    | [range(0; $queue | length) | select(. as $i | $run | all(.[]; . as $r | $queue[$i] | all(.[]; collide($g[tostring]; $g[$r | tostring]) | not)))] | first // empty' <<<"$1"
}

# Batches (#189): the picked tickets in order, each with `batch`, the numbers of the tickets delivered
# together with it (itself included), or null. Only Ready S tickets with Paths, and no spike (#321) nor hotfix (#322), are batched, and only
# with a ticket whose Paths overlap one already in the batch; at most $cap per batch. A ticket joins the
# first batch that takes it, else starts one. A hotfix (#322) is delivered alone.
# shellcheck disable=SC2016 # a jq program, not shell
BATCH_DEF='def batchable: .size == "S" and (globs | length) > 0 and ((.labels // []) | index("type:spike") | not) and ((.labels // []) | index("hotfix") | not);
  def grouped($cap): reduce .[] as $t ([]; ([range(0; length) as $i | select($t | batchable)
      | select((.[$i] | length) < $cap and (.[$i][0] | batchable) and any(.[$i][]; overlap(globs; $t | globs))) | $i] | first) as $at
    | if $at == null then . + [[$t]] else .[$at] += [$t] end);
  def batched($cap): . as $all | (grouped($cap) | map(map(.number))) as $g
    | $all | map(.number as $n | . + {batch: ([$g[] | select(length > 1 and any(.[]; . == $n))] | first // null)});'

# How many tickets a batch holds: an S is about 50 lines (skill triage), so limits.prLines / 50, 3 at most.
batch_cap() {
  local cap
  cap=$(config_get limits.prLines)
  [[ $cap =~ ^[1-9][0-9]*$ ]] || die "limits.prLines must be a positive whole number, not $cap"
  cap=$((cap / 50))
  [ "$cap" -le 3 ] || cap=3
  echo "$cap"
}

# The picked tickets of a board_data result as `number<TAB>size<TAB>title<TAB>batch` lines, in pick order: batch is the
# numbers delivered together with the ticket, space-separated and empty for a ticket alone (#263). $2 keeps the
# first N tickets when given, before the batches are formed, as `pick --max`. The first line of a batch is its lead.
queue_lines() {
  local cap
  cap=$(batch_cap) || exit 1
  jq -r --argjson max "${2:-0}" --argjson cap "$cap" "$PICK_DEF$PATHS_DEF$BATCH_DEF"'pick | if $max > 0 then .[:$max] else . end
    | batched($cap)[] | [.number, (.size // "-"), .title, (.batch // [] | map(tostring) | join(" "))] | @tsv' <<<"$1"
}

# senior-mode pick [--json] [--max N]
pick() {
  local json=false max="" data cap
  while [ $# -gt 0 ]; do
    case $1 in
      --json) json=true ;;
      --max)
        [[ ${2:-} =~ ^[1-9][0-9]*$ ]] || die "pick --max needs a positive number"
        max=$2
        shift
        ;;
      *) usage ;;
    esac
    shift
  done
  data=$(board_data false) || exit 1
  cap=$(batch_cap) || exit 1
  if [ "$json" = true ]; then
    jq -c --argjson max "${max:-0}" --argjson cap "$cap" "$PICK_DEF$PATHS_DEF$BATCH_DEF"'pick | if $max > 0 then .[:$max] else . end
      | batched($cap) | map({number, title, url, priority, size, milestone, due, paths: globs, batch})' <<<"$data"
  else
    jq -r --argjson max "${max:-0}" --argjson cap "$cap" "$PICK_DEF$PATHS_DEF$BATCH_DEF"'pick | if $max > 0 then .[:$max] else . end
      | batched($cap)
      | if length == 0 then "No Ready ticket to pick." else .[] | "#\(.number) \(.priority // "no priority") · \(.size // "?") · \(.title)"
        + (if .milestone then " (\(.milestone))" else "" end)
        + (if .batch then " [batch \(.batch | map("#\(.)") | join(" "))]" else "" end) end' <<<"$data"
  fi
}

# The ref a new branch starts from: origin's default branch, else a local main or master.
start_base() {
  local main=$1 base integration
  integration=$(workflow_get integration "$main")
  if [ -n "$integration" ] && base=$(workflow_ref "$main" "$integration"); then
    printf '%s\n' "$base"
    return 0
  fi
  base=$(git -C "$main" symbolic-ref -q --short refs/remotes/origin/HEAD) ||
    base=$(git -C "$main" for-each-ref --format='%(refname:short)' refs/remotes/origin/main refs/remotes/origin/master | head -1)
  [ -n "$base" ] || base=$(git -C "$main" for-each-ref --format='%(refname:short)' refs/heads/main refs/heads/master | head -1)
  [ -n "$base" ] || return 1
  printf '%s\n' "$base"
}

# Every worktree senior-mode makes (a ticket, a framing, the docs session of a run) is
# `${XDG_DATA_HOME:-~/.local/share}/senior-mode/worktrees/<repo>/<name>` (#224): never a sibling of the
# repository, and not under its .git, where Claude Code refuses edits as sensitive files. $1 is the main
# worktree of the repository, $2 the name (`<issue>`, `frame-<slug>`, `run-docs-<stamp>`). <repo> is its
# basename and 8 hex digits of the checksum of its absolute path, so two clones never collide. The same
# path from any worktree. Older worktrees (beside the repository, or under .git/senior-mode/worktrees)
# stay where they are; `branch_worktree` finds them by their branch.
worktree_path() {
  printf '%s/senior-mode/worktrees/%s-%08x/%s\n' "${XDG_DATA_HOME:-$HOME/.local/share}" "$(basename "$1")" \
    "$(printf '%s' "$1" | cksum | cut -d' ' -f1)" "$2"
}

# The path of the worktree of repository $1 that has branch $2 checked out; nothing when there is none.
branch_worktree() {
  git -C "$1" worktree list --porcelain | awk -v b="refs/heads/$2" '$1 == "worktree" {p = substr($0, 10)} $1 == "branch" && $2 == b {print p}'
}

# The worktrees of the tickets in the repository of $1, as `<issue> <path>` lines, wherever they are: any
# worktree on a branch `<type>/<issue>-<slug>` with a type `start` makes (feat, fix, chore).
ticket_worktrees() {
  local p="" b n
  if [ -n "$(workflow_get branch.pattern "$1")" ]; then
    while IFS=$'\t' read -r p b; do
      n=$(workflow_branch_issue "$b" "$1")
      [ -z "$n" ] || echo "$n $p"
    done < <(git -C "$1" worktree list --porcelain | awk '$1 == "worktree" {p = substr($0, 10)} $1 == "branch" {print p "\t" substr($2, 12)}')
    return 0
  fi
  git -C "$1" worktree list --porcelain | awk '$1 == "worktree" {p = substr($0, 10)}
    $1 == "branch" && match($2, /^refs\/heads\/(feat|fix|chore|hotfix)\/[0-9]+(-|$)/) {
      n = substr($2, 12); sub(/^[a-z]+\//, "", n); sub(/[^0-9].*/, "", n); print n, p}'
}

# senior-mode frame start <idea>: the worktree `frame-<slug>` and the branch `docs/<slug>` of a
# framing (spec 0001 §8), from origin's default branch, so parallel framings never share a working tree
# or branch. Refuses when the local default branch holds commits origin lacks: they would ride along in
# the framing's pull request.
frame_start() {
  local name common main base branch path local_branch ahead
  name=$(slugify "${1:-}")
  [ -n "$name" ] || usage
  common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || die "not inside a git repository"
  main=${common%/.git}
  git -C "$main" fetch -q origin 2>/dev/null || die "cannot fetch origin"
  base=$(start_base "$main") || die "no default branch to frame from"
  local_branch=${base#origin/}
  if git -C "$main" show-ref -q --verify "refs/heads/$local_branch"; then
    ahead=$(git -C "$main" rev-list --count "$base..$local_branch")
    [ "$ahead" -eq 0 ] ||
      die "$local_branch is ahead of $base by $ahead commit(s) (unpushed, such as a setup commit): push or open a pull request for them first, then frame again"
  fi
  branch=docs/$name
  path=$(branch_worktree "$main" "$branch")
  if [ -z "$path" ]; then
    path=$(worktree_path "$main" "frame-$name")
    [ ! -e "$path" ] || die "$path exists and is not the worktree of $branch"
    if git -C "$main" show-ref -q --verify "refs/heads/$branch"; then
      git -C "$main" worktree add -q "$path" "$branch" >/dev/null || die "cannot create the worktree"
    else
      git -C "$main" worktree add -q --no-track -b "$branch" "$path" "$base" >/dev/null || die "cannot create the worktree"
      fresh=true
    fi
  fi
  echo "branch $branch"
  echo "worktree $path"
}

# senior-mode frame decide <issue> <question> <answer> (#310): appends the line `- <date> #<issue>: <question> ->
# <answer>` to docs/decisions.md of the repository it runs in (created with its title), the log of what the owner
# chose while framing. A line already there is not added again, so a rerun is safe; the file is committed with the
# framing, never written to the default branch from here.
frame_decide() {
  local root file q a line
  [[ ${1:-} =~ ^[1-9][0-9]*$ ]] || usage
  q=$(tr -s '[:space:]' ' ' <<<"${2:-}" | sed 's/^ //; s/ $//')
  a=$(tr -s '[:space:]' ' ' <<<"${3:-}" | sed 's/^ //; s/ $//')
  [ -n "$q" ] && [ -n "$a" ] || die "frame decide needs a question and an answer"
  root=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repository"
  file=$root/docs/decisions.md
  line="- $(date -u +%F) #$1: $q -> $a"
  if [ ! -f "$file" ]; then
    mkdir -p "$root/docs"
    printf '%s\n' '# Decision log' '' \
      'What the owner chose when a request was framed, one line per question, oldest first: date, ticket, question, answer.' \
      'Written by `senior-mode frame decide`; an answer taken without the owner ends with "(assumed)".' '' >"$file"
  fi
  if grep -qxF -- "$line" "$file"; then
    echo "decision already logged: #$1"
  else
    printf '%s\n' "$line" >>"$file"
    echo "decision logged: #$1"
  fi
}

# Whether `start` is called by a live `run` (#145): `run` keeps a random token in the shell variable
# RUN_TOKEN, which is never exported (and cleared at startup, so a variable set by hand does not survive),
# and writes the same token to a 0600 file of its own, whose path it gives `start` in
# SENIOR_MODE_RUN_TOKEN_FILE. Both must agree. SENIOR_MODE_RUN=1 alone proves nothing: it only tells the
# guard hooks that the session is unattended. The aim is to stop an accidental or hand-set bypass; a
# process of the same user can still read the file, but cannot start a `start` that holds the token.
run_token_ok() {
  local f=${SENIOR_MODE_RUN_TOKEN_FILE:-}
  [ -n "${RUN_TOKEN:-}" ] && [ -n "$f" ] && [ -f "$f" ] && [ ! -L "$f" ] || return 1
  [ "$(file_owner "$f")" = "$(id -u)" ] && [ "$(file_mode "$f")" = 600 ] || return 1
  [ "$(cat "$f" 2>/dev/null)" = "$RUN_TOKEN" ]
}

# Refuses to start <issue> when the open tickets In progress, other than it, already reach `wip`.
# A run is bounded by autonomy.parallel instead, so `start` skips this when run_token_ok.
wip_check() {
  local limit data others
  limit=$(config_get wip)
  [[ $limit =~ ^[1-9][0-9]*$ ]] || die "wip must be a positive whole number, not $limit"
  data=$(board_data false)
  others=$(jq -r --argjson n "$1" --argjson w "$limit" '[.items[] | select(.open and .status == "In progress"
    and .number != $n) | "#\(.number) \(.title)"] | select(length >= $w) | join(", ")' <<<"$data")
  [ -z "$others" ] ||
    die "work in progress is at its limit (wip $limit): $others. Finish it first (merge, or set it back to Ready), or raise wip in .claude/senior-mode.json"
}

# senior-mode start <issue>: the worktree and the branch `<type>/<issue>-<slug>` of a ticket, then Status
# In progress. Shared by `next` and `run`. The branch type follows the `type:` label (feature: feat, bug:
# fix, task and chore: chore; feat without a label). The branch starts from the default branch, fetched
# first when origin answers; the worktree is `<data dir>/senior-mode/worktrees/<repo>/<issue>` (#224, see `worktree_path`).
# A project with a detected workflow (spec 409 §3) has its own branch name pattern and base: the integration branch,
# a release line named by a `Base:` line, the base for a `hotfix` ticket; a base that is none of those, or a missing
# tracker key the name needs, labels the ticket needs-human or needs-info and stops. `base <branch>` says where
# its pull request goes.
# Rerunning reuses the branch and the worktree, wherever an earlier start put it. A new worktree gets its dependencies (a node one that
# lost them too), installed with the project's install command (#110); a failed install only warns, and
# `check` says what is missing. Prints `branch <name>` and `worktree <path>`.
start() {
  [ $# -eq 1 ] && [[ $1 =~ ^[1-9][0-9]*$ ]] || usage
  local issue=$1 slug info state title labels type common main name base branch path existing created=false cmd dir
  local body target kind="ticket" key="" pat wf=false fresh=false
  slug=$(repo_slug)
  info=$(gh_retry issue view "$issue" --repo "$slug" --json title,labels,state,body) || die "cannot read issue #$issue"
  state=$(jq -r '.state' <<<"$info")
  [ "$state" = OPEN ] || die "issue #$issue is ${state,,}"
  title=$(jq -r '.title' <<<"$info")
  labels=$(jq -r '.labels[].name' <<<"$info")
  # A hotfix (#322) jumps the queue: the work-in-progress limit does not hold it back.
  run_token_ok || grep -qx hotfix <<<"$labels" || wip_check "$issue"
  common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || die "not inside a git repository"
  main=${common%/.git}
  ! workflow_active "$main" || wf=true
  if [ "$wf" = true ]; then
    labels=$(workflow_labels_normalize "$main" "$labels")
    body=$(jq -r '.body // ""' <<<"$info")
    if ! target=$(workflow_ticket_base "$main" "$body" "$labels"); then
      workflow_flag "$slug" "$issue" needs-human "$target"
      die "$target: #$issue is needs-human"
    fi
    kind=${target#* }
    target=${target%% *}
    key=$(workflow_tracker_key "$body")
    pat=$(workflow_branch_pattern "$main")
    if [ -z "$key" ] && { [[ $pat == *'{key}'* ]] || [ "$(workflow_get commit.format "$main")" = ticket-prefix ]; }; then
      workflow_flag "$slug" "$issue" needs-info "the project's branch and commit format need a tracker key; add a \`Tracker: ABC-123\` line to the issue"
      die "#$issue has no \`Tracker: KEY-n\` line, which the project's branch and commit format need: it is needs-info"
    fi
  fi
  case $(sed -n 's/^type://p' <<<"$labels" | head -1) in
    bug) type=fix ;;
    task | chore | spike) type=chore ;;
    *) type=feat ;;
  esac
  name=$(slugify "$title")
  if [ "$wf" = true ]; then
    # The branch of an earlier start wins, whatever its slug.
    branch=$(workflow_find_branch "$main" "$issue") || branch=""
    if [ -z "$branch" ] && [ "$kind" = hotfix ]; then
      branch=$(workflow_get release.hotfix "$main")
      branch=${branch%\*}$issue${name:+-$name}
    fi
    [ -n "$branch" ] || branch=$(workflow_branch_name "$main" "$type" "$issue" "$name" "$key")
  else
    # The branch of an earlier start wins, whatever its slug.
    branch=$(git -C "$main" for-each-ref --format='%(refname:short)' "refs/heads/$type/$issue-*" | head -1)
    branch=${branch:-$type/$issue${name:+-$name}}
  fi
  existing=$(branch_worktree "$main" "$branch")
  if [ -n "$existing" ]; then
    path=$existing
  else
    created=true
    path=$(worktree_path "$main" "$issue")
    [ ! -e "$path" ] || die "$path exists and is not the worktree of $branch"
    if ! git -C "$main" show-ref -q --verify "refs/heads/$branch"; then
      git -C "$main" fetch -q origin 2>/dev/null || true
      if [ "$wf" = true ]; then
        base=$(workflow_ref "$main" "$target") || die "the branch $target of the project's workflow does not exist: cannot start $branch from it"
      else
        base=$(start_base "$main") || die "no default branch to start $branch from"
      fi
      git -C "$main" worktree add -q --no-track -b "$branch" "$path" "$base" >/dev/null || die "cannot create the worktree"
      fresh=true
    else
      git -C "$main" worktree add -q "$path" "$branch" >/dev/null || die "cannot create the worktree"
    fi
  fi
  if [ "$wf" = true ]; then (cd "$main" && workflow_record_branch "$branch" "$issue"); fi
  echo "branch $branch"
  echo "worktree $path"
  [ "$wf" != true ] || echo "base $target"
  if [ "$created" = true ] || deps_missing "$path"; then
    while IFS=$'\t' read -r dir cmd; do
      echo "senior-mode: installing dependencies: $cmd" >&2
      (cd "$path/$dir" && bash -c "$cmd" </dev/null >&2) ||
        echo "senior-mode: could not install dependencies in $path/$dir; run: $cmd" >&2
    done < <(install_plan "$path")
  fi
  # The criteria of a feature or a fix become failing tests, the first commit of its new branch (#311). A project
  # with its own commit format (a detected workflow) writes its own commits.
  if [ "$fresh" = true ] && [ "$wf" != true ]; then
    case $(sed -n 's/^type://p' <<<"$labels" | head -1) in
      task | chore | spike | docs) ;;
      *) skeleton_commit "$issue" "$(jq -r '.body // ""' <<<"$info")" "$path" ;;
    esac
  fi
  item_set "$issue" Status "In progress"
  cycle_start "$issue"
}
