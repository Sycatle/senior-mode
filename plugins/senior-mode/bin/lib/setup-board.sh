# shellcheck shell=bash
# Board fields and options (spec 0001 §11), in order. Aliases match options of GitHub's default
# Status field, so that values already set on items survive the repair.
BOARD='{
  "Status": [{"name": "Backlog", "color": "GRAY", "aliases": ["todo"]}, {"name": "Ready", "color": "BLUE"},
    {"name": "In progress", "color": "YELLOW"}, {"name": "In review", "color": "PURPLE"}, {"name": "Done", "color": "GREEN"}],
  "Priority": [{"name": "P0 now", "color": "RED"}, {"name": "P1 next", "color": "ORANGE"},
    {"name": "P2 later", "color": "YELLOW"}, {"name": "P3 someday", "color": "GRAY"}],
  "Size": [{"name": "S", "color": "GREEN"}, {"name": "M", "color": "YELLOW"}, {"name": "L", "color": "RED"}],
  "Severity": [{"name": "critical", "color": "RED"}, {"name": "high", "color": "ORANGE"},
    {"name": "moderate", "color": "YELLOW"}, {"name": "low", "color": "GRAY"}]
}'

# Options to give a field: the wanted ones, keeping the id, colour and description of an existing
# option with the same name (any case), else of an alias, then the field's other options unchanged.
# shellcheck disable=SC2016 # a jq program, not shell
MERGE_OPTIONS='.options as $cur
  | (reduce $want[] as $w ([];
      (map(.id)) as $taken
      | ([$cur[] | select((.id | IN($taken[]) | not) and (.name | ascii_downcase) == ($w.name | ascii_downcase))][0]
         // [$cur[] | select((.id | IN($taken[]) | not) and ((.name | ascii_downcase) | IN(($w.aliases // [])[])))][0]) as $m
      # An option found by an alias keeps its name (#556): with the default Todo renamed Backlog, some organisations
      # put every issue back to Backlog after each move. Todo reads as Backlog.
      | . + [{name: (if $m and (($m.name | ascii_downcase) != ($w.name | ascii_downcase)) then $m.name else $w.name end),
              color: ($m.color // $w.color), description: ($m.description // "")}
             + (if $m then {id: $m.id} else {} end)])) as $ours
  | $ours + [$cur[] | select(.id | IN($ours[].id) | not) | {id, name, color, description}]'

# The rules senior-mode owns on the default branch (ADR 0006), as a ruleset of its own: it adds to
# whatever protection the repository has and never rewrites it. Admins may bypass, explicitly.
RULESET='{"name": "senior-mode", "target": "branch", "enforcement": "active",
  "conditions": {"ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []}},
  "bypass_actors": [{"actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always"}],
  "rules": [{"type": "deletion"}, {"type": "non_fast_forward"}, {"type": "required_linear_history"},
    {"type": "pull_request", "parameters": {"required_approving_review_count": 0, "dismiss_stale_reviews_on_push": false,
      "require_code_owner_review": false, "require_last_push_approval": false,
      "required_review_thread_resolution": false, "allowed_merge_methods": ["rebase"]}},
    {"type": "required_status_checks", "parameters": {"strict_required_status_checks_policy": true,
      "do_not_enforce_on_create": false,
      "required_status_checks": [{"context": "senior-mode/ci"}, {"context": "senior-mode/review"}, {"context": "senior-mode/security"}]}}]}'

# Single-select fields of a Project, with their options.
board_fields() {
  jq -nc --arg id "$1" '{variables: {id: $id}, query: "query($id: ID!) { node(id: $id) { ... on ProjectV2 {
    fields(first: 50) { nodes { ... on ProjectV2SingleSelectField { id name options { id name color description } }
    ... on ProjectV2Field { id name dataType } ... on ProjectV2IterationField { id name dataType } } } } } }"}' |
    gh_retry api graphql --input - --jq '[.data.node.fields.nodes[] | select(.name)]'
}

# Copies the template Project into the repository's owner, without draft issues: views and built-in
# workflows come with it, fields too. Prints "<number> <id>". Reads template and owner_node of setup_github. The
# source is the template of the config, except that the organization layer's board.template (setup org, #401) replaces
# the plugin's own when the repository sets none; $2 forces a source.
copy_template() { # title [source]
  local src=${2:-$template} org
  if [ -z "${2:-}" ] && [ "$src" = "$(jq -r .board.template <<<"$DEFAULTS")" ]; then
    org=$(org_layer | jq -r '.board.template // empty')
    [ -z "$org" ] || src=$org
  fi
  jq -nc --arg t "$src" --arg o "$owner_node" --arg title "$1" '{variables: {template: $t, owner: $o, title: $title},
    query: "mutation($template: ID!, $owner: ID!, $title: String!) { copyProjectV2(input: {projectId: $template,
    ownerId: $owner, title: $title, includeDraftIssues: false}) { projectV2 { id number } } }"}' |
    gh_retry api graphql --input - --jq '.data.copyProjectV2.projectV2 | "\(.number) \(.id)"'
}

# A fine-grained token is bound to one resource owner: from another owner's token GitHub cannot resolve the
# template Project, public as it is (#527). The error it answers, and what setup says about it.
UNRESOLVED='Could not resolve to a node with the global id'
template_unreadable() { # owner title
  echo "senior-mode: the template Project $template (board.template) cannot be read with this token: a fine-grained token is bound to one owner and sees no Project of another owner, even a public one. Either open the template on GitHub, choose \"Make a copy\" into $1 with the title $2, then run setup github again, which finds the Project by its title; or set board.template in .claude/senior-mode.json to the id of a template Project that $1 owns." >&2
}

# The fields of the template, built in, for when it cannot be read: the single-selects of $BOARD with their
# options, Paths, Start and End (the Iteration field is made apart, by setup_cycle).
# shellcheck disable=SC2016 # a jq program, not shell
builtin_template_fields() {
  jq -c '[to_entries[] | {id: ("builtin:" + .key), name: .key, options: [.value[] | {name, color, description: ""}]}]
    + [{name: "Paths", dataType: "TEXT"}, {name: "Start", dataType: "DATE"}, {name: "End", dataType: "DATE"}
       | . + {id: ("builtin:" + .name)}]' <<<"$BOARD"
}

# Sets fields of a Project (updateProjectV2): $2 is a JSON object of the input fields.
project_update() { # project-id fields
  jq -nc --arg id "$1" --argjson f "$2" '{variables: {input: ({projectId: $id} + $f)},
    query: "mutation($input: UpdateProjectV2Input!) { updateProjectV2(input: $input) { projectV2 { id } } }"}' |
    gh_retry api graphql --input - >/dev/null
}

# Finds the Project of the repository (cached number, else same title) or copies the template Project
# (a copy is private: public when the repository is); prints "<number> <id> <copied|found>". Called as
# `setup_project || die`, which turns off set -e here: every command checks its own status. Reads
# template, owner_node and private of setup_github.
setup_project() {
  local file=$1 owner=$2 name=$3 slug=$4 number id err how=found out
  number=$(jq -r '.project.number // empty' "$file")
  if [ -n "$number" ]; then
    err=$(mktemp)
    if ! id=$(gh_retry project view "$number" --owner "$owner" --format json --jq .id 2>"$err"); then
      grep -q "Could not resolve to a ProjectV2" "$err" || die "cannot read Project #$number: $(cat "$err")"
      number=""
    fi
    rm -f "$err"
  fi
  if [ -z "$number" ]; then
    number=$(gh_retry project list --owner "$owner" --limit 100 --format json \
      --jq "[.projects[] | select(.title == \"$name\")][0].number // empty") || return 1
    if [ -n "$number" ]; then
      id=$(gh_retry project view "$number" --owner "$owner" --format json --jq .id) || return 1
    else
      err=$(mktemp)
      if ! out=$(copy_template "$name" 2>"$err"); then
        if grep -q "$UNRESOLVED" "$err"; then
          template_unreadable "$owner" "$name"
        else
          cat "$err" >&2
          echo "senior-mode: cannot copy the template Project $template (board.template)" >&2
        fi
        rm -f "$err"
        return 1
      fi
      rm -f "$err"
      read -r number id <<<"$out"
      how=copied
      echo "Project #$number $name: copied from the template" >&2
      [ "$private" != false ] || project_update "$id" '{"public": true}' || return 1
    fi
  fi
  [ -n "$id" ] || return 1
  gh_retry project link "$number" --owner "$owner" --repo "$slug" >/dev/null || return 1
  echo "$number $id $how"
}

# The views and the built-in workflows of a Project, as {views: [name], workflows: [{name, enabled}]}.
board_shape() { # project-id
  jq -nc --arg id "$1" '{variables: {id: $id}, query: "query($id: ID!) { node(id: $id) { ... on ProjectV2 {
    views(first: 20) { nodes { name } } workflows(first: 20) { nodes { name enabled } } } } }"}' |
    gh_retry api graphql --input - --jq '.data.node | {views: [.views.nodes[].name], workflows: .workflows.nodes}'
}

# What the template has and the Project $1 lacks, in words: its views, and the built-in workflows it has
# on. Empty when nothing lacks; status 1 when either Project cannot be read.
board_lacks() { # project-id template-id
  local mine tpl
  mine=$(board_shape "$1") && tpl=$(board_shape "$2") || return 1
  jq -nr --argjson m "$mine" --argjson t "$tpl" '
    [([$t.views[] | select(. as $v | $m.views | index($v) | not)] | if length > 0 then "views " + join(", ") else empty end),
     ([$t.workflows[] | select(.enabled) | .name | select(. as $w | $m.workflows | map(select(.enabled) | .name) | index($w) | not)]
       | if length > 0 then "workflows " + join(", ") else empty end)] | join("; ")'
}

# Compares the Project with the template (#176): the copy is checked and a gap named with where to fix it
# (GitHub has no API for views and built-in workflows); an existing Project is never replaced, and
# setup names --migrate. Reads template of setup_github.
setup_board_template() { # project-id copied|found
  local lacks err
  err=$(mktemp)
  if ! lacks=$(board_lacks "$1" "$template" 2>"$err"); then
    if grep -q "$UNRESOLVED" "$err"; then
      echo "board: the template Project $template cannot be read with this token (a fine-grained token sees no Project of another owner); the fields and options the commands need are set from the built-in list, compare the views and workflows with the template by hand"
    else
      echo "board: could not read the template Project $template; compare the Project with it by hand"
    fi
    rm -f "$err"
    return 0
  fi
  rm -f "$err"
  if [ "$2" = copied ]; then
    if [ -z "$lacks" ]; then echo "board: the copy has the views and workflows of the template"
    else echo "board: the copy lacks $lacks that the template has; add the views by hand (GitHub has no API for views) and turn the workflows on in Project → Workflows"
    fi
  elif [ -n "$lacks" ]; then
    echo "board: the Project lacks $lacks that the template has; senior-mode setup github --upgrade adds the fields and options it lacks (--dry-run lists them), and --migrate builds a new Project from the template and moves every item (add --dry-run to see the mapping first)"
  fi
}

# The short description and the README of the Project in the project language (#178): what each Status
# means, the Definition of Ready, who moves what, a link to docs/specs. Only the block between the
# senior-mode markers (templates/<language>/board-readme.md) is written; the rest of the README stays,
# and so does a short description that is not ours.
# shellcheck disable=SC2016 # a GraphQL query, not shell
setup_board_readme() { # project-id slug language
  local tpl lang=$3 block cur readme short new written=""
  tpl=$(dirname "$SELF")/../templates
  [ -d "$tpl/$lang" ] || lang=en
  block=$(<"$tpl/$lang/board-readme.md")
  block=${block//\{\{repo\}\}/$2}
  cur=$(jq -nc --arg id "$1" '{variables: {id: $id}, query: "query($id: ID!) { node(id: $id) { ... on ProjectV2 { readme shortDescription } } }"}' |
    gh_retry api graphql --input - --jq '.data.node') ||
    { echo "board README: could not read the Project; skipped"; return 0; }
  readme=$(jq -r '.readme // ""' <<<"$cur") short=$(jq -r '.shortDescription // ""' <<<"$cur")
  if [ -z "$readme" ]; then new=$block
  elif ! grep -qE '^<!-- senior-mode:(begin|end)' <<<"$readme"; then new=$readme$'\n\n'$block
  # One opening marker, then one closing marker, else awk refuses and the README is left alone.
  elif ! new=$(BLOCK=$block awk '
      /^<!-- senior-mode:begin/ { if (seen++) bad = 1; print ENVIRON["BLOCK"]; skip = 1; next }
      /^<!-- senior-mode:end -->/ { if (!skip) bad = 1; skip = 0; next }
      !skip { print } END { exit (bad || skip) }' <<<"$readme"); then
    echo "board README: senior-mode markers broken, README left untouched; restore one begin and one end marker"
    return 0
  fi
  case $lang in
    fr) desc="Tableau senior-mode : Backlog → Ready → In progress → In review → Done. Voir le README." ;;
    *) desc="senior-mode board: Backlog → Ready → In progress → In review → Done. See the README." ;;
  esac
  [ "$new" = "$readme" ] || written="README"
  if [ "$short" != "$desc" ] && { [ -z "$short" ] || [[ $short == "Tableau senior-mode"* ]] || [[ $short == "senior-mode board"* ]]; }; then
    written+="${written:+ and }short description"
  else
    desc=$short
  fi
  [ -n "$written" ] || return 0
  project_update "$1" "$(jq -nc --arg r "$new" --arg d "$desc" '{readme: $r, shortDescription: $d}')" ||
    { echo "board README: could not write it; skipped"; return 0; }
  echo "board README: written ($written, language $lang)"
}

# Every item of a Project (paged) as {title, public, items: [{item, key, kind, id, title, body, values}]}: key
# is the node id of the issue or pull request, "draft:<title>" for a draft; values are the item's
# single-select, text, number and date values by field name; number is the issue or pull request number.
# shellcheck disable=SC2016 # a GraphQL query, not shell
BOARD_ITEMS_QUERY='query($id: ID!, $after: String) { node(id: $id) { ... on ProjectV2 { title public
  items(first: 50, after: $after) { pageInfo { hasNextPage endCursor } nodes { id
    content { __typename ... on Issue { id number } ... on PullRequest { id number } ... on DraftIssue { title body } }
    fieldValues(first: 30) { nodes {
      ... on ProjectV2ItemFieldSingleSelectValue { name field { ... on ProjectV2FieldCommon { name } } }
      ... on ProjectV2ItemFieldTextValue { text field { ... on ProjectV2FieldCommon { name } } }
      ... on ProjectV2ItemFieldNumberValue { number field { ... on ProjectV2FieldCommon { name } } }
      ... on ProjectV2ItemFieldDateValue { date field { ... on ProjectV2FieldCommon { name } } } } } } } } } }'
board_items() { # project-id
  local after="" page pages="[]" more=true count=0
  while [ "$more" = true ]; do
    page=$(jq -nc --arg q "$BOARD_ITEMS_QUERY" --arg id "$1" --arg a "$after" \
      '{query: $q, variables: ({id: $id} + (if $a == "" then {} else {after: $a} end))}' | gh_retry api graphql --input -) || return 1
    pages=$(json_append "$pages" "$page")
    more=$(jq -r '.data.node.items.pageInfo.hasNextPage // false' <<<"$page")
    after=$(jq -r '.data.node.items.pageInfo.endCursor // empty' <<<"$page")
    count=$((count + 1))
    [ "$count" -lt 200 ] || return 1
  done
  jq -c '{title: .[0].data.node.title, public: .[0].data.node.public, items: [.[].data.node.items.nodes[] | select(.content != null)
    | .content as $c | {item: .id, kind: $c.__typename, id: $c.id, title: $c.title, body: $c.body,
      number: $c.number, key: (if $c.__typename == "DraftIssue" then "draft:" + $c.title else $c.id end),
      values: [.fieldValues.nodes[] | select(.field.name) | {field: .field.name, name, text, number, date}]}]}' <<<"$pages"
}

# Runs a GraphQL query or mutation with its variables (JSON); more gh arguments follow.
gql() { # query variables [gh-argument...]
  jq -nc --arg q "$1" --argjson v "$2" '{query: $q, variables: $v}' | gh_retry api graphql --input - "${@:3}"
}

# How the fields and values of a board map onto the fields of another (#181): a field or single-select
# option matches by name in any case, else by the aliases of $BOARD (GitHub's Todo is our Backlog).
# shellcheck disable=SC2016 # a jq program, not shell
MIGRATE_DEFS='def lc: ascii_downcase;
  def tname($f; $o): ($board[$f] // [] | map(select((.aliases // []) | map(lc) | index($o | lc))) | .[0].name) // $o;
  def field($fs; $n): [$fs[] | select((.name | lc) == ($n | lc))][0];
  def option($t; $f; $o): ([$t.options[]? | select((.name | lc) == ($o | lc))][0])
    // ([$t.options[]? | select((.name | lc) == (tname($f; $o) | lc))][0]);
  def custom: select(.options or (.dataType | IN("TEXT", "NUMBER", "DATE")));'

# What a migration will do, as JSON: the fields and options to create as is, the values that change
# name, what has no API, and the items to add. $1 old fields, $2 target fields, $3 old items, $4 the
# new Project's items.
# shellcheck disable=SC2016 # a jq program, not shell
migrate_plan() {
  jq -nc --argjson old "$1" --argjson tgt "$2" --argjson oi "$3" --argjson cur "$4" --argjson board "$BOARD" "$MIGRATE_DEFS"'
    ([$oi[] | select(.key | IN($cur[].key) | not)] | length) as $add
    | {create: [$old[] | custom | select(field($tgt; .name) == null)
        | {name, kind: (if .options then "SINGLE_SELECT" else .dataType end),
           options: [.options[]? | {name, color, description: (.description // "")}]}],
       options: [$old[] | select(.options) | . as $f | field($tgt; .name) as $t | select($t != null)
        | {field: $t.name, id: $t.id, current: $t.options,
           missing: [$f.options[] | select(option($t; $f.name; .name) == null) | {name, color, description: (.description // "")}]}
        | select(.missing | length > 0)],
       mapped: [$old[] | select(.options) | . as $f | field($tgt; .name) as $t | select($t != null) | $f.options[]
        | (option($t; $f.name; .name).name // empty) as $to | select($to != .name) | "\($f.name) \(.name) -> \($to)"],
       skipped: [$old[] | select(.dataType == "ITERATION") | "\(.name) (ITERATION)"],
       add: $add, present: (($oi | length) - $add)}'
}

# The mutations of a migration that remain: for each item of the old Project, its content when the new
# one lacks it, and the values the new item still lacks, resolved against the new Project's fields.
# shellcheck disable=SC2016 # a jq program, not shell
migrate_ops() { # target-fields old-items new-items
  jq -nc --argjson tgt "$1" --argjson oi "$2" --argjson cur "$3" --argjson board "$BOARD" "$MIGRATE_DEFS"'
    $oi[] as $o | ([$cur[] | select(.key == $o.key)][0]) as $n
    | ($n.values // [] | map(.field | lc)) as $have
    | {key: $o.key, kind: $o.kind, id: $o.id, title: $o.title, body: $o.body, item: ($n.item // null),
       sets: [$o.values[] | . as $v | field($tgt; $v.field) as $t | select($t != null)
        | (if $v.name != null then (option($t; $v.field; $v.name) as $op | select($op != null) | {value: {singleSelectOptionId: $op.id}})
           elif $v.text != null and $t.dataType == "TEXT" then {value: {text: $v.text}}
           elif $v.number != null and $t.dataType == "NUMBER" then {value: {number: $v.number}}
           elif $v.date != null and $t.dataType == "DATE" then {value: {date: $v.date}}
           else empty end) + {field: $t.id, label: $t.name}
        | select((.label | lc) | IN($have[]) | not)]}
    | select(.item == null or (.sets | length > 0))'
}

# Creates in Project $1 the fields and options of the plan $2 (JSON) that the template lacks, as they are.
# shellcheck disable=SC2016 # GraphQL mutations, not shell
migrate_fields() { # project-id plan
  local f
  while IFS= read -r f; do
    gql 'mutation($project: ID!, $name: String!, $type: ProjectV2CustomFieldType!, $options: [ProjectV2SingleSelectFieldOptionInput!]) {
      createProjectV2Field(input: {projectId: $project, name: $name, dataType: $type, singleSelectOptions: $options}) { clientMutationId } }' \
      "$(jq -c --arg p "$1" '{project: $p, name, type: .kind, options: (if .kind == "SINGLE_SELECT" then .options else null end)}' <<<"$f")" >/dev/null ||
      die "cannot create the field $(jq -r .name <<<"$f") in the new Project"
  done < <(jq -c '.create[]' <<<"$2")
  while IFS= read -r f; do
    gql 'mutation($field: ID!, $options: [ProjectV2SingleSelectFieldOptionInput!]!) {
      updateProjectV2Field(input: {fieldId: $field, singleSelectOptions: $options}) { clientMutationId } }' \
      "$(jq -c '{field: .id, options: (.current + .missing)}' <<<"$f")" >/dev/null ||
      die "cannot add options to the field $(jq -r .field <<<"$f") in the new Project"
  done < <(jq -c '.options[]' <<<"$2")
}

# Adds to Project $1 the items that $2 (migrate_ops lines) says are missing, and sets their values.
# shellcheck disable=SC2016 # a GraphQL query, not shell
migrate_items() { # project-id ops
  local op item set
  while IFS= read -r op; do
    item=$(jq -r '.item // empty' <<<"$op")
    if [ -z "$item" ]; then
      if [ "$(jq -r .kind <<<"$op")" = DraftIssue ]; then
        item=$(gql 'mutation($p: ID!, $t: String!, $b: String) { addProjectV2DraftIssue(input: {projectId: $p, title: $t, body: $b}) { projectItem { id } } }' \
          "$(jq -c --arg p "$1" '{p: $p, t: .title, b: .body}' <<<"$op")" --jq .data.addProjectV2DraftIssue.projectItem.id)
      else
        item=$(gql 'mutation($p: ID!, $c: ID!) { addProjectV2ItemById(input: {projectId: $p, contentId: $c}) { item { id } } }' \
          "$(jq -c --arg p "$1" '{p: $p, c: .id}' <<<"$op")" --jq .data.addProjectV2ItemById.item.id)
      fi || die "cannot add $(jq -r .key <<<"$op") to the new Project"
    fi
    while IFS= read -r set; do
      gql 'mutation($p: ID!, $i: ID!, $f: ID!, $v: ProjectV2FieldValue!) {
        updateProjectV2ItemFieldValue(input: {projectId: $p, itemId: $i, fieldId: $f, value: $v}) { clientMutationId } }' \
        "$(jq -c --arg p "$1" --arg i "$item" '{p: $p, i: $i, f: .field, v: .value}' <<<"$set")" >/dev/null ||
        die "cannot set $(jq -r .label <<<"$set") of $(jq -r .key <<<"$op") in the new Project"
    done < <(jq -c '.sets[]' <<<"$op")
  done <<<"$2"
}

# Moves the board to a Project built from the template (#181): every item of the old Project with its field
# values, the fields and single-select options the template lacks created as is, the new Project linked
# and recorded, the old one closed (never deleted). The new Project is recorded in the config as soon as
# it exists (project.migration), so that a rerun after an interruption goes on with it and adds
# nothing twice. With dry set, prints the mapping and changes nothing.
# Reads template, owner_node and private of setup_github.
# shellcheck disable=SC2016 # jq programs, not shell
setup_migrate() { # config-file dry-run
  local file=$1 dry=$2 old_number old_id new_number new_id owner old oldf tgt tgtf cur plan ops title out
  old_number=$(jq -r '.project.number // empty' "$file") old_id=$(jq -r '.project.id // empty' "$file")
  owner=$(jq -r '.project.owner // empty' "$file")
  [ -n "$old_number" ] && [ -n "$old_id" ] && [ -n "$owner" ] ||
    die "no Project to migrate in .claude/senior-mode.json; run senior-mode setup github first"
  new_number=$(jq -r '.project.migration.number // empty' "$file") new_id=$(jq -r '.project.migration.id // empty' "$file")
  old=$(board_items "$old_id") || die "cannot read the items of Project #$old_number"
  oldf=$(board_fields "$old_id") || die "cannot read the fields of Project #$old_number"
  title=$(jq -r '.title' <<<"$old")
  tgt=${new_id:-$template}
  tgtf=$(board_fields "$tgt") || die "cannot read the fields of Project $tgt"
  cur='[]'
  if [ -n "$new_id" ]; then
    cur=$(board_items "$new_id") || die "cannot read the items of Project #$new_number"
    cur=$(jq -c .items <<<"$cur")
    echo "migrate: Project #$new_number was already created from the template, going on with it"
  fi
  plan=$(migrate_plan "$oldf" "$tgtf" "$(jq -c .items <<<"$old")" "$cur")
  jq -r --arg n "$old_number" --arg t "$title" --arg tpl "$template" '
    "migrate: Project #\($n) \"\($t)\" -> a Project built from the template \($tpl)",
    "migrate: items: \(.add) to add, \(.present) already in the new Project",
    (if (.create | length) > 0 then "migrate: fields to create as is: " + (.create | map("\(.name) (\(.kind))") | join(", ")) else empty end),
    (if (.options | length) > 0 then "migrate: options to create as is: " + ([.options[] | .field as $f | .missing[] | "\($f) \(.name)"] | join(", ")) else empty end),
    (if (.mapped | length) > 0 then "migrate: values mapped: " + (.mapped | join(", ")) else empty end),
    (if (.skipped | length) > 0 then "migrate: not migrated: " + (.skipped | join(", ")) else empty end)' <<<"$plan"
  if [ "$dry" = true ]; then
    echo "migrate: dry run, nothing changed; senior-mode setup github --migrate does it"
    return 0
  fi
  if [ -z "$new_id" ]; then
    out=$(copy_template "$title") || die "cannot copy the template Project $template (board.template)"
    read -r new_number new_id <<<"$out"
    json_update "$file" '.project.migration = {number: $n, id: $id}' --argjson n "$new_number" --arg id "$new_id" ||
      [ $? -eq 2 ] || die "could not write .claude/senior-mode.json"
    [ "$private" != false ] || project_update "$new_id" '{"public": true}' || die "cannot make Project #$new_number public"
    echo "migrate: Project #$new_number $title: copied from the template"
    tgtf=$(board_fields "$new_id") || die "cannot read the fields of Project #$new_number"
    plan=$(migrate_plan "$oldf" "$tgtf" "$(jq -c .items <<<"$old")" "[]")
  fi
  setup_fields "$new_id"
  migrate_fields "$new_id" "$plan"
  tgtf=$(board_fields "$new_id") || die "cannot read the fields of Project #$new_number"
  cur=$(board_items "$new_id") || die "cannot read the items of Project #$new_number"
  ops=$(migrate_ops "$tgtf" "$(jq -c .items <<<"$old")" "$(jq -c .items <<<"$cur")")
  [ -z "$ops" ] || migrate_items "$new_id" "$ops"
  project_update "$old_id" '{"closed": true}' || die "cannot close Project #$old_number"
  json_update "$file" '.project = {owner: $o, number: $n, id: $id}' --arg o "$owner" --argjson n "$new_number" --arg id "$new_id" ||
    [ $? -eq 2 ] || die "could not write .claude/senior-mode.json"
  echo "migrate: Project #$new_number is the board now, recorded in .claude/senior-mode.json"
  echo "migrate: Project #$old_number closed, not deleted; reopen it with: gh project close $old_number --owner $owner --undo"
}

# What the move to a shared Project leaves unmapped, one line per value: a value whose field the target lacks, a
# single-select value whose option the target lacks. $1 target fields, $2 old items, $3 the target's name.
# shellcheck disable=SC2016 # a jq program, not shell
move_unmapped() { # target-fields old-items target
  jq -nr --argjson tgt "$1" --argjson oi "$2" --arg to "$3" --argjson board "$BOARD" "$MIGRATE_DEFS"'
    $oi[] | (if .kind == "DraftIssue" then .title else "#\(.number)" end) as $ref
    | .values[] | . as $v | field($tgt; $v.field) as $t
    | if $t == null then "move: \($ref) \($v.field): the field is not on Project #\($to), left unmapped"
      elif $v.name != null and option($t; $v.field; $v.name) == null then
        "move: \($ref) \($v.field) \($v.name): no such option on Project #\($to), left unmapped"
      else empty end'
}

# Moves the repository's items to the shared Project $3 (#723): the items it lacks are added with the field values
# of the mapping of --migrate, the repository is linked to it and unlinked from its own Project, which is never
# deleted nor closed, and the config names the shared Project. The shared Project's fields are never touched: a
# field or option it lacks is reported and the value left unmapped. Items go first and the config last, so a rerun
# after an interruption adds nothing twice; once the config names the Project there is nothing left to do.
# With dry set, prints the mapping and changes nothing.
# shellcheck disable=SC2016 # jq programs, not shell
setup_move_items() { # config-file dry-run number owner slug
  local file=$1 dry=$2 number=$3 owner=$4 slug=$5 old_number old_id new_id old oldf tgtf cur plan ops fields
  old_number=$(jq -r '.project.number // empty' "$file") old_id=$(jq -r '.project.id // empty' "$file")
  [ -n "$old_number" ] && [ -n "$old_id" ] || die "no Project to move in .claude/senior-mode.json; run senior-mode setup github first"
  if [ "$old_number" = "$number" ] && [ "$(jq -r '.project.owner // empty' "$file")" = "$owner" ]; then
    echo "move: $slug is already on Project #$number, nothing to do"
    return 0
  fi
  new_id=$(gh_retry project view "$number" --owner "$owner" --format json --jq .id) ||
    die "cannot read Project #$number of $owner"
  old=$(board_items "$old_id") || die "cannot read the items of Project #$old_number"
  oldf=$(board_fields "$old_id") || die "cannot read the fields of Project #$old_number"
  tgtf=$(board_fields "$new_id") || die "cannot read the fields of Project #$number"
  cur=$(board_items "$new_id") || die "cannot read the items of Project #$number"
  cur=$(jq -c .items <<<"$cur") old=$(jq -c .items <<<"$old")
  plan=$(migrate_plan "$oldf" "$tgtf" "$old" "$cur")
  jq -r --arg o "$old_number" --arg n "$number" '
    "move: Project #\($o) -> Project #\($n)",
    "move: items: \(.add) to add, \(.present) already on Project #\($n)",
    (if (.mapped | length) > 0 then "move: values mapped: " + (.mapped | join(", ")) else empty end),
    (if (.skipped | length) > 0 then "move: not moved: " + (.skipped | join(", ")) else empty end)' <<<"$plan"
  move_unmapped "$tgtf" "$old" "$number"
  if [ "$dry" = true ]; then
    echo "move: dry run, nothing changed; senior-mode setup github --project $number --move-items does it"
    return 0
  fi
  ops=$(migrate_ops "$tgtf" "$old" "$cur")
  [ -z "$ops" ] || migrate_items "$new_id" "$ops"
  gh_retry project link "$number" --owner "$owner" --repo "$slug" >/dev/null || die "cannot link $slug to Project #$number"
  gh_retry project unlink "$old_number" --owner "$owner" --repo "$slug" >/dev/null ||
    die "cannot unlink $slug from Project #$old_number"
  fields=$(board_fields "$new_id") || die "cannot read the fields of Project #$number"
  cache_project "$file" "$owner" "$number" "$new_id" "$fields" false
  echo "move: Project #$number is the board of $slug now, recorded in .claude/senior-mode.json"
  echo "move: $slug unlinked from Project #$old_number, which is kept as it is; link it again with: gh project link $old_number --owner $owner --repo $slug"
}

# `setup github --project <n> --move-items [--dry-run]`: the entry point of setup_move_items. Only the items move: the
# repository steps of setup github are not run. --project alone attaches the repository (setup_attach, #398).
setup_github_move() {
  local target="" move=false dry=false root file slug owner
  while [ $# -gt 0 ]; do
    case $1 in
      --project) [[ ${2:-} =~ ^[0-9]+$ ]] || usage; target=$2; shift 2 ;;
      --move-items) move=true; shift ;;
      --dry-run) dry=true; shift ;;
      *) usage ;;
    esac
  done
  [ -n "$target" ] && [ "$move" = true ] || usage
  root=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repository"
  file=$root/.claude/senior-mode.json
  [ -f "$file" ] && jq empty "$file" 2>/dev/null || die "no valid .claude/senior-mode.json; run senior-mode setup github first"
  slug=$(repo_slug) owner=${slug%%/*}
  setup_move_items "$file" "$dry" "$target" "$owner" "$slug"
}

# The number of the Project $1, given as a number or as its URL, that the repository $3 of $2 can be attached to: GitHub
# links a repository only to a Project of its own owner, so a URL of another owner is refused.
attach_number() { # project owner slug
  local o
  if [[ $1 =~ ^[0-9]+$ ]]; then
    echo "$1"
  elif [[ $1 =~ ^https://github\.com/(orgs|users)/([^/]+)/projects/([0-9]+)(/.*)?$ ]]; then
    o=${BASH_REMATCH[2]}
    [ "${o,,}" = "${2,,}" ] ||
      die "Project #${BASH_REMATCH[3]} belongs to $o and $3 belongs to $2: GitHub links a repository only to a Project of its own owner"
    echo "${BASH_REMATCH[3]}"
  else
    usage
  fi
}

# The repositories linked to the Project $1 (its id), one nameWithOwner per line.
# shellcheck disable=SC2016 # a GraphQL query, not shell
attach_linked() { # project-id
  jq -nc --arg id "$1" '{variables: {id: $id}, query: "query($id: ID!) { node(id: $id) { ... on ProjectV2 {
    repositories(first: 100) { nodes { nameWithOwner } } } } }"}' |
    gh_retry api graphql --input - --jq '.data.node.repositories.nodes[].nameWithOwner'
}

# The repository that holds the duties of the Project as a whole (project.home): the one given with --home, else the
# one named like the Project's title (among the linked ones and this one), else the home this config already names for
# this Project, else the first linked, else this repository.
attach_home() { # explicit title linked slug kept
  local named
  if [ -n "$1" ]; then echo "$1"; return; fi
  named=$(printf '%s\n%s\n' "$3" "$4" | grep -ixF "${4%%/*}/$2" | head -1 || true)
  if [ -n "$named" ]; then echo "$named"; return; fi
  if [ -n "$5" ]; then echo "$5"; return; fi
  printf '%s\n%s\n' "$3" "$4" | grep -v '^$' | head -1
}

# `setup github --project <number|url>` (#398): attaches the repository to the Project of its owner instead of
# creating or finding one by title. The fields the commands need are created when missing and never rewritten (an
# option a field lacks is reported, setup_fields), the repository is linked unless it already is, and the config names
# the Project and its home. With dry set, says all of it and changes nothing. Sets number and id of setup_github.
setup_attach() { # config-file slug project home dry
  local file=$1 slug=$2 explicit=$4 dry=$5 owner=${2%%/*} info title linked kept home fields
  [ -z "$explicit" ] || [[ $explicit =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || die "--home takes owner/name, got $explicit"
  [ -z "$explicit" ] || [ "${explicit%%/*}" = "$owner" ] ||
    die "--home $explicit belongs to ${explicit%%/*} and the Project to $owner: a product holds the repositories of one owner"
  number=$(attach_number "$3" "$owner" "$slug") || exit 1
  info=$(gh_retry project view "$number" --owner "$owner" --format json --jq '[.id, .title] | join("\t")') ||
    die "cannot read Project #$number of $owner"
  id=${info%%$'\t'*} title=${info#*$'\t'}
  linked=$(attach_linked "$id") || die "cannot read the repositories linked to Project #$number"
  kept=$(jq -r --arg id "$id" 'select(.project.id == $id) | .project.home // empty' "$file")
  home=$(attach_home "$explicit" "$title" "$linked" "$slug" "$kept")
  echo "Project #$number $title of $owner: $slug is attached to it, home $home"
  echo "fields: Status, Priority, Size, Severity and Paths are checked; a missing field is created, an option a field lacks is reported and never added"
  if [ "$dry" = true ]; then setup_fields "$id" dry; else setup_fields "$id" attach; fi
  if grep -qixF "$slug" <<<"$linked"; then
    echo "link: $slug is already linked to Project #$number"
  elif [ "$dry" = true ]; then
    echo "link: would link $slug to Project #$number"
  else
    gh_retry project link "$number" --owner "$owner" --repo "$slug" >/dev/null || die "cannot link $slug to Project #$number"
    echo "link: $slug linked to Project #$number"
  fi
  if [ "$dry" = true ]; then
    echo "config: would write project owner $owner, number $number, id $id, home $home and the ids of its fields in .claude/senior-mode.json"
    return 0
  fi
  fields=$(board_fields "$id") || die "could not read the fields of Project #$number"
  cache_project "$file" "$owner" "$number" "$id" "$fields" false "$home"
  echo "config: project owner $owner, number $number, home $home; ids cached in .claude/senior-mode.json"
}

# Creates missing board fields with their colours, repairs the options of existing ones. $2 is attach for a shared
# Project (#398): a missing field is still created, but an option a field lacks is only reported, since rewriting the
# options of a shared field would move the items of the other repositories; dry (with attach) creates nothing.
setup_fields() { # project-id [attach|dry]
  local id=$1 mode=${2:-} fields field want current options missing
  fields=$(board_fields "$id")
  for field in Status Priority Size Severity; do
    want=$(jq -c --arg f "$field" '.[$f]' <<<"$BOARD")
    current=$(jq -c --arg f "$field" '.[] | select(.name == $f)' <<<"$fields")
    if [ -z "$current" ]; then
      [ "$mode" != dry ] || { echo "field $field: would be created"; continue; }
      jq -nc --arg p "$id" --arg n "$field" --argjson w "$want" '{variables: {project: $p, name: $n,
        options: ($w | map({name, color, description: ""}))}, query: "mutation($project: ID!, $name: String!,
        $options: [ProjectV2SingleSelectFieldOptionInput!]!) { createProjectV2Field(input: {projectId: $project,
        dataType: SINGLE_SELECT, name: $name, singleSelectOptions: $options}) { clientMutationId } }"}' |
        gh_retry api graphql --input - >/dev/null
      echo "field $field: created"
      continue
    fi
    options=$(jq -c --argjson want "$want" "$MERGE_OPTIONS" <<<"$current")
    if [ -n "$mode" ]; then
      missing=$(jq -r 'map(select(has("id") | not) | .name) | join(", ")' <<<"$options")
      [ -z "$missing" ] ||
        echo "field $field: the option $missing is missing and is left as it is; add it in the Project, Settings, field $field (senior-mode never rewrites the options of a shared field: it would move the items of the other repositories)"
      continue
    fi
    [ "$(jq -c 'map(.name)' <<<"$options")" != "$(jq -c '.options | map(.name)' <<<"$current")" ] || continue
    jq -nc --arg f "$(jq -r .id <<<"$current")" --argjson o "$options" '{variables: {field: $f, options: $o},
      query: "mutation($field: ID!, $options: [ProjectV2SingleSelectFieldOptionInput!]!) {
        updateProjectV2Field(input: {fieldId: $field, singleSelectOptions: $options}) { clientMutationId } }"}' |
      gh_retry api graphql --input - >/dev/null
    echo "field $field: options repaired, existing values kept"
  done
  # The text field Paths (#174): the globs a ticket touches, read by `pick` and `run`.
  if ! jq -e '.[] | select(.name == "Paths")' <<<"$fields" >/dev/null; then
    [ "$mode" != dry ] || { echo "field Paths: would be created"; return 0; }
    jq -nc --arg p "$id" '{variables: {project: $p, name: "Paths"}, query: "mutation($project: ID!, $name: String!) {
      createProjectV2Field(input: {projectId: $project, dataType: TEXT, name: $name}) { clientMutationId } }"}' |
      gh_retry api graphql --input - >/dev/null
    echo "field Paths: created"
  fi
}

# The fields of the cycle (#180): an Iteration field of board.iterationDays days (26 iterations from the Monday of this week), and the
# dates Start and End. A field that exists is reused, never duplicated (a Start or End of another type is left alone and said); their
# ids are cached in the config, which setup_github has just written. $1 the id of the Project, $2 the config file.
# shellcheck disable=SC2016 # a GraphQL query, not shell
setup_cycle() {
  local id=$1 file=$2 days iter fields name dow start made=""
  days=$(config_get board.iterationDays)
  [[ $days =~ ^[1-9][0-9]*$ ]] || die "board.iterationDays must be a positive whole number, not $days"
  iter=$(iteration_field) || die "cannot read the Iteration field of the Project"
  if [ -z "$iter" ]; then
    dow=$(date -u +%u)
    start=$(iso_time $(($(date +%s) - (dow - 1) * 86400)))
    jq -nc --arg p "$id" --arg s "${start:0:10}" --argjson d "$days" '($s + "T00:00:00Z" | fromdateiso8601) as $t0
      | {variables: {project: $p, name: "Iteration", cfg: {startDate: $s, duration: $d,
        iterations: [range(0; 26) | {title: "Iteration \(. + 1)", startDate: ($t0 + . * $d * 86400 | strftime("%Y-%m-%d")), duration: $d}]}},
      query: "mutation($project: ID!, $name: String!, $cfg: ProjectV2IterationFieldConfigurationInput!) {
        createProjectV2Field(input: {projectId: $project, dataType: ITERATION, name: $name, iterationConfiguration: $cfg}) { clientMutationId } }"}' |
      gh_retry api graphql --input - >/dev/null || die "could not create the Iteration field"
    made="Iteration (${days}-day iterations from ${start:0:10})"
    iter=$(iteration_field) || die "cannot read the Iteration field of the Project"
  fi
  fields=$(board_fields "$id") || die "could not read the fields of the Project"
  for name in Start End; do
    if ! jq -e --arg n "$name" '.[] | select(.name == $n)' <<<"$fields" >/dev/null; then
      jq -nc --arg p "$id" --arg n "$name" '{variables: {project: $p, name: $n}, query: "mutation($project: ID!, $name: String!) {
        createProjectV2Field(input: {projectId: $project, dataType: DATE, name: $name}) { clientMutationId } }"}' |
        gh_retry api graphql --input - >/dev/null || die "could not create the $name field"
      made+="${made:+, }$name"
    fi
  done
  [ -z "$made" ] || echo "fields created: $made"
  fields=$(board_fields "$id") || die "could not read the fields of the Project"
  for name in Start End; do
    jq -e --arg n "$name" '.[] | select(.name == $n and .dataType == "DATE")' <<<"$fields" >/dev/null ||
      echo "field $name: exists and is not a date field; rename it, then run setup github again, or Start and End are not set"
  done
  jq --argjson f "$fields" --arg i "$(jq -r '.id // empty' <<<"$iter")" '.project.fields += (if $i == "" then {} else {Iteration: {id: $i, iteration: true}} end)
    + ($f | map(select(.name | IN("Start", "End")) | select(.dataType == "DATE") | {key: .name, value: {id, date: true}}) | from_entries)' \
    "$file" >"$file.tmp" || die "could not write .claude/senior-mode.json"
  mv "$file.tmp" "$file"
}

# Names the Project's built-in workflows that keep Status true and are off. GitHub has no API to
# turn them on, so this only says where.
setup_board_workflows() {
  local off
  off=$(jq -nc --arg id "$1" '{variables: {id: $id}, query: "query($id: ID!) { node(id: $id) {
    ... on ProjectV2 { workflows(first: 20) { nodes { name enabled } } } } }"}' |
    gh_retry api graphql --input - --jq '[.data.node.workflows.nodes[]
      | select((.name | IN("Item closed", "Pull request merged")) and (.enabled | not)) | .name] | join(", ")') ||
    { echo "built-in workflows: could not read them; check Project → Workflows by hand"; return 0; }
  [ -z "$off" ] ||
    echo "built-in workflows off: $off; turn them on in the Project → Workflows (no API can), so the board moves to Done"
}

# Caches in the config the Project and the ids of its fields (Status, Priority, Size, Severity, Paths); $5 is the
# fields of board_fields, $6 true to keep project.migration (an interrupted migration) of the former entry, $7 the
# project.home of a shared Project (#398).
# shellcheck disable=SC2016 # a jq program, not shell
cache_project() { # config-file owner number id fields keep-migration [home]
  jq --arg o "$2" --argjson n "$3" --arg id "$4" --argjson f "$5" --argjson keep "$6" --arg home "${7:-}" \
    '((if $keep then (.project // {} | with_entries(select(.key == "migration"))) else {} end)
      + {owner: $o, number: $n, id: $id, fields: ($f | map(select(.name | IN("Status", "Priority", "Size", "Severity", "Paths")))
      | map({key: .name, value: (if .options then {id, options: (.options | map({key: .name, value: .id}) | from_entries)} else {id} end)}) | from_entries
      # A Status that keeps Todo and has no Backlog (#556): Backlog is written as Todo.
      | if .Status.options and (.Status.options | has("Backlog") | not) then
          .Status.options += ([.Status.options | to_entries[] | select(.key | ascii_downcase == "todo") | {key: "Backlog", value}] | from_entries)
        else . end)}) as $p
      | .project = $p | if $home != "" then .project.home = $home else . end' \
    "$1" >"$1.tmp" || die "could not write .claude/senior-mode.json"
  mv "$1.tmp" "$1"
}

# Adds to the board of the config every field and single-select option the template has and the board lacks (#298), and
# nothing else: no value, option, item or view is touched or removed, and the ruleset, labels and repository settings
# are not read. A field matches by name in any case, an option by name or by the alias of $BOARD (Todo is Backlog). The
# Iteration field and the dates Start and End are made as `setup github` makes them (setup_cycle). With dry set, lists
# and changes nothing. A rerun finds nothing to add. Reads template of setup_github.
# shellcheck disable=SC2016 # jq programs, not shell
setup_upgrade() { # config-file dry-run owner
  local file=$1 dry=$2 owner=$3 number id tplf boardf plan fields options added="" err
  number=$(jq -r '.project.number // empty' "$file") id=$(jq -r '.project.id // empty' "$file")
  [ -n "$number" ] && [ -n "$id" ] || die "no Project to upgrade in .claude/senior-mode.json; run senior-mode setup github first"
  # A template this token cannot resolve (#527): its built-in field list stands in for it.
  err=$(mktemp)
  if ! tplf=$(board_fields "$template" 2>"$err"); then
    grep -q "$UNRESOLVED" "$err" || {
      cat "$err" >&2
      rm -f "$err"
      die "cannot read the template Project $template (board.template)"
    }
    echo "upgrade: the template Project $template cannot be read with this token (a fine-grained token sees no Project of another owner); its built-in field list is used instead"
    tplf=$(builtin_template_fields)
  fi
  rm -f "$err"
  boardf=$(board_fields "$id") || die "cannot read the fields of Project #$number"
  # The fields to create come from the migration plan; the options are the template's that the board has under neither
  # their name nor an alias of $BOARD (a board whose Status has Todo does not lack Backlog).
  plan=$(migrate_plan "$tplf" "$boardf" '[]' '[]' | jq -c --argjson tpl "$tplf" --argjson brd "$boardf" --argjson board "$BOARD" '
    .options = [$tpl[] | select(.options) | . as $f
      | ($brd[] | select(.options and (.name | ascii_downcase) == ($f.name | ascii_downcase))) as $t
      | {field: $t.name, id: $t.id, current: ($t.options | map({id, name, color, description})),
         missing: [$f.options[] | . as $w | [($board[$f.name] // [])[] | select(.name == $w.name) | .aliases[]? | ascii_downcase] as $al
           | select([$t.options[] | .name | ascii_downcase] | any(. == ($w.name | ascii_downcase) or IN($al[])) | not)
           | {name, color, description: (.description // "")}]}
      | select(.missing | length > 0)]')
  fields=$(jq -r '[.create[] | "\(.name) (\(.kind))"] | join(", ")' <<<"$plan")
  options=$(jq -r '[.options[] | .field as $f | .missing[] | "\($f) \(.name)"] | join(", ")' <<<"$plan")
  jq -e '.[] | select(.name == "Iteration")' <<<"$boardf" >/dev/null || fields+="${fields:+, }Iteration (ITERATION)"
  if [ "$dry" = true ]; then
    echo "upgrade: Project #$number: fields to add: ${fields:-none}"
    echo "upgrade: Project #$number: options to add: ${options:-none}"
    echo "upgrade: dry run, nothing changed; senior-mode setup github --upgrade does it"
    return 0
  fi
  migrate_fields "$id" "$plan"
  boardf=$(board_fields "$id") || die "cannot read the fields of Project #$number"
  cache_project "$file" "$owner" "$number" "$id" "$boardf" true
  setup_cycle "$id" "$file"
  [ -z "$fields" ] || added+="fields added: $fields"
  [ -z "$options" ] || added+="${added:+; }options added: $options"
  echo "upgrade: Project #$number: ${added:-nothing to add, the board has every field and option of the template}"
}
