#!/usr/bin/env bash
# Tests for `senior-mode setup github`. Offline: gh is a stub simulating the API from files in $FIX.
set -u
cli=$(cd "$(dirname "$0")/.." && pwd)/senior-mode
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

mkdir -p "$work/stub"
cat >"$work/stub/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$GH_LOG"
jqf="" prev=""
for a in "$@"; do [ "$prev" = --jq ] && jqf=$a; prev=$a; done
respond() { if [ -n "$jqf" ]; then jq -r "$jqf"; else cat; fi; }
plan_limit() { # PROTECTION_403=1 refuses reads and writes, =write only the write; real gh error line
  [ -z "${PROTECTION_403:-}" ] || { [ "$1" = read ] && [ "$PROTECTION_403" = write ]; } && return 0
  echo "${PROTECTION_ERR:-gh: Upgrade to GitHub Pro or make this repository public to enable this feature. (HTTP 403)}" >&2; exit 1
}
sec_limit() { # SEC_REFUSE lists the features the plan refuses (alerts fixes scanning); real gh error line
  case " ${SEC_REFUSE:-} " in *" $1 "*) echo "gh: ${SEC_ERR:-Advanced Security must be enabled for this repository to use this feature. (HTTP 422)}" >&2; exit 1 ;; esac
}
case "$*" in
  "api repos/acme/app --jq"*) respond <"$FIX/repo.json" ;;
  "api repos/acme/app/contents/.github/CODEOWNERS"*)
    [ -z "${CONTENTS_ERR:-}" ] || { echo "$CONTENTS_ERR" >&2; exit 1; }
    [ -f "$FIX/default-codeowners" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    cat "$FIX/default-codeowners" ;;
  "api user --jq"*) echo '{"login": "maintainer"}' | respond ;;
  "api repos/acme/app/rulesets --jq"*) plan_limit read
    if [ -f "$FIX/rulesets.json" ]; then respond <"$FIX/rulesets.json"; else echo '[]' | respond; fi ;;
  "api -X POST repos/acme/app/rulesets"*) plan_limit write; cat >>"$GH_LOG"
    echo '[{"id": 9, "name": "senior-mode", "source_type": "Repository"}]' >"$FIX/rulesets.json" ;;
  "api repos/acme/app/rulesets/"*" --jq"*)
    # RULESET_GET_ERR fails every read of the ruleset, RULESET_GET_FAIL_ONCE only the first; real gh error line
    [ -z "${RULESET_GET_ERR:-}" ] || { echo "$RULESET_GET_ERR" >&2; exit 1; }
    if [ -n "${RULESET_GET_FAIL_ONCE:-}" ] && [ ! -f "$FIX/get-failed" ]; then
      touch "$FIX/get-failed"; echo "gh: Resource not accessible by personal access token (HTTP 403)" >&2; exit 1
    fi
    respond <"$FIX/ruleset-9.json" ;;
  "api -X PUT repos/acme/app/rulesets/"*) cat >>"$GH_LOG" ;;
  "api -X PUT repos/acme/app/vulnerability-alerts"*) sec_limit alerts ;;
  "api -X PUT repos/acme/app/automated-security-fixes"*) sec_limit fixes ;;
  "api -X PATCH repos/acme/app -f"*) sec_limit scanning ;;
  "workflow list"*) if [ -f "$FIX/workflows.json" ]; then respond <"$FIX/workflows.json"; else echo '[]' | respond; fi ;;
  "workflow disable"* | "workflow enable"*) ;;
  "api repos/acme/app/actions/permissions/workflow"*) respond <"$FIX/actions-permissions.json" ;;
  "api repos/acme/app/actions/secrets/RELEASE_PLEASE_TOKEN"*)
    [ -f "$FIX/secret" ] || { echo "HTTP 404: Not Found" >&2; exit 1; }
    echo '{"name": "RELEASE_PLEASE_TOKEN"}' | respond ;;
  "project view"*)
    [ -z "${VIEW_ERR:-}" ] || { echo "$VIEW_ERR" >&2; exit 1; }
    jq -e --argjson n "$3" '.number == $n' "$FIX/project.json" >/dev/null 2>&1 ||
      { echo "Could not resolve to a ProjectV2 with the number $3." >&2; exit 1; }
    respond <"$FIX/project.json" ;;
  "project list"*) [ -z "${LIST_ERR:-}" ] || { echo "$LIST_ERR" >&2; exit 1; }
    respond <"$FIX/projects.json" ;;
  "project link"*) [ -z "${LINK_ERR:-}" ] || { echo "$LINK_ERR" >&2; exit 1; } ;;
  "project create"*) echo "project create is gone: the board is copied from the template" >&2; exit 1 ;;
  "api graphql"*)
    body=$(cat); echo "$body" >>"$GH_LOG"
    v=$(jq -c .variables <<<"$body")
    if grep -q 'dataType: ITERATION' <<<"$body"; then
      # An Iteration field is read by its own query, not with the others.
      jq -nc --argjson v "$v" '{data: {node: {field: {id: "F_Iteration", configuration: {duration: $v.cfg.duration, completedIterations: [],
        iterations: ($v.cfg.iterations | to_entries | map(.value + {id: "it\(.key)"}))}}}}}' >"$FIX/iteration.json"
    elif grep -q createProjectV2Field <<<"$body"; then
      dt=$(grep -o 'dataType: [A-Z_]*' <<<"$body" | head -1 | cut -d' ' -f2)
      jq --argjson v "$v" --arg dt "${dt:-TEXT}" '.data.node.fields.nodes += [{id: ("F_" + $v.name), name: $v.name}
        + (if $v.options then {options: ($v.options | map(. + {id: ("O_" + .name)}))} else {dataType: ($v.type // $dt)} end)]' \
        "$FIX/fields.json" >"$FIX/f" && mv "$FIX/f" "$FIX/fields.json"
    elif grep -q 'configuration { duration' <<<"$body"; then
      if [ -f "$FIX/iteration.json" ]; then cat "$FIX/iteration.json"; else echo '{"data": {"node": {"field": null}}}'; fi
    elif grep -q updateProjectV2Field <<<"$body"; then
      jq --argjson v "$v" '(.data.node.fields.nodes[] | select(.id == $v.field)
        | .options) = ($v.options | map(.id //= ("O_" + .name)))' "$FIX/fields.json" >"$FIX/f" &&
        mv "$FIX/f" "$FIX/fields.json"
    elif grep -q copyProjectV2 <<<"$body"; then
      [ -z "${COPY_ERR:-}" ] || { echo "$COPY_ERR" >&2; exit 1; }
      jq -nc --argjson n "${COPY_NUMBER:-7}" --arg i "${COPY_ID:-PVT_NEW}" '{number: $n, id: $i, title: "app"}' >"$FIX/project.json"
      jq -nc --argjson n "${COPY_NUMBER:-7}" --arg i "${COPY_ID:-PVT_NEW}" '{data: {copyProjectV2: {projectV2: {id: $i, number: $n}}}}' | respond
    elif grep -q 'updateProjectV2(input' <<<"$body"; then
      jq --argjson v "$v" '.data.node += ($v.input | del(.projectId))' "$FIX/board.json" >"$FIX/f" && mv "$FIX/f" "$FIX/board.json"
    elif grep -q 'views(first' <<<"$body"; then
      if [ "$(jq -r .id <<<"$v")" = PVT_TPL ]; then
        [ -z "${TEMPLATE_ERR:-}" ] || { echo "$TEMPLATE_ERR" >&2; exit 1; }
        respond <"$FIX/template-project.json"
      else respond <"$FIX/workflows-project.json"; fi
    elif grep -q 'addProjectV2DraftIssue' <<<"$body"; then
      f=$FIX/items-$(jq -r .p <<<"$v").json; [ -f "$f" ] || echo '{"data":{"node":{"items":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}' >"$f"
      id=I_$(jq '.data.node.items.nodes | length + 1' "$f")
      jq --argjson v "$v" --arg id "$id" '.data.node.items.nodes += [{id: $id, content: {__typename: "DraftIssue", title: $v.t, body: $v.b}, fieldValues: {nodes: []}}]' "$f" >"$f.t" && mv "$f.t" "$f"
      jq -nc --arg id "$id" '{data: {addProjectV2DraftIssue: {projectItem: {id: $id}}}}' | respond
    elif grep -q 'addProjectV2ItemById' <<<"$body"; then
      f=$FIX/items-$(jq -r .p <<<"$v").json; [ -f "$f" ] || echo '{"data":{"node":{"items":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}' >"$f"
      if [ -n "${ADD_FAIL_AFTER:-}" ] && [ "$(jq '.data.node.items.nodes | length' "$f")" -ge "$ADD_FAIL_AFTER" ]; then echo "gh: HTTP 401: Bad credentials" >&2; exit 1; fi
      id=I_$(jq '.data.node.items.nodes | length + 1' "$f")
      jq --argjson v "$v" --arg id "$id" '.data.node.items.nodes += [{id: $id, content: {__typename: "Issue", id: $v.c}, fieldValues: {nodes: []}}]' "$f" >"$f.t" && mv "$f.t" "$f"
      jq -nc --arg id "$id" '{data: {addProjectV2ItemById: {item: {id: $id}}}}' | respond
    elif grep -q 'updateProjectV2ItemFieldValue' <<<"$body"; then
      f=$FIX/items-$(jq -r .p <<<"$v").json
      jq --argjson v "$v" --slurpfile fl "$FIX/fields.json" '($fl[0].data.node.fields.nodes | map(select(.id == $v.f))[0]) as $fd
        | (.data.node.items.nodes[] | select(.id == $v.i) | .fieldValues.nodes) += [{field: {name: $fd.name}}
          + (if $v.v.singleSelectOptionId then {name: ($fd.options | map(select(.id == $v.v.singleSelectOptionId))[0].name)} else $v.v end)]' "$f" >"$f.t" && mv "$f.t" "$f"
    elif grep -q 'items(first' <<<"$body"; then
      f=$FIX/items-$(jq -r .id <<<"$v").json
      if [ -f "$f" ]; then respond <"$f"; else echo '{"data":{"node":{"title":"app","public":false,"items":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}' | respond; fi
    elif grep -q 'readme' <<<"$body"; then respond <"$FIX/board.json"
    elif grep -q workflows <<<"$body"; then
      [ ! -f "$FIX/workflows-fail" ] || { echo "HTTP 403: forbidden" >&2; exit 1; }
      respond <"$FIX/workflows-project.json"
    else
      f=$FIX/fields-$(jq -r '.id // empty' <<<"$v").json; [ -f "$f" ] || f=$FIX/fields.json
      respond <"$f"
    fi ;;
esac
STUB
chmod +x "$work/stub/gh"
export PATH="$work/stub:$PATH" GH_LOG="$work/gh.log" FIX="$work/fix" SENIOR_MODE_RETRY_DELAY=0

repo="$work/repo"
git init -q "$repo"
git -C "$repo" remote add origin git@github.com:acme/app.git
mkdir -p "$repo/.claude" "$FIX"
echo '{"language": "fr", "board": {"template": "PVT_TPL"}}' >"$repo/.claude/senior-mode.json"
repo_json() { echo "{\"owner\": {\"type\": \"$1\", \"node_id\": \"U_acme\"}, \"private\": ${2:-true}}" >"$FIX/repo.json"; }
repo_json User
echo '{"data": {"node": {"readme": null, "shortDescription": null}}}' >"$FIX/board.json"
echo '{"rules": []}' >"$FIX/ruleset-9.json"
echo '{"projects": [{"number": 2, "title": "other"}]}' >"$FIX/projects.json"
echo '{"data": {"node": {"fields": {"nodes": [{}, {"id": "F_Status", "name": "Status", "options": [
  {"id": "O_todo", "name": "Todo", "color": "GRAY", "description": ""},
  {"id": "O_prog", "name": "In Progress", "color": "YELLOW", "description": ""},
  {"id": "O_done", "name": "Done", "color": "PURPLE", "description": "Shipped"}]}]}}}}' >"$FIX/fields.json"
project_workflows() { # enabled flags of "Item closed" and "Pull request merged"; the template has the same views and workflows
  jq -n --argjson c "$1" --argjson m "$2" '{data: {node: {views: {nodes: [{name: "BACKLOG"}, {name: "KANBAN"}]}, workflows: {nodes: [
    {name: "Item closed", enabled: $c}, {name: "Pull request merged", enabled: $m},
    {name: "Auto-add to project", enabled: false}]}}}}' >"$FIX/workflows-project.json"
  cp "$FIX/workflows-project.json" "$FIX/template-project.json"
}
project_workflows true true

setup() {
  : >"$GH_LOG"
  (cd "$repo" && "$cli" setup github) >"$work/out" 2>"$work/err" || fail "setup exited non-zero: $(cat "$work/err")"
}
cfg() { jq -r "$1" "$repo/.claude/senior-mode.json"; }
logged() { grep -qF -- "$1" "$GH_LOG"; }
status_field() {
  jq --argjson o "$1" '(.data.node.fields.nodes[] | select(.name == "Status") | .options) = $o' \
    "$FIX/fields.json" >"$FIX/f" && mv "$FIX/f" "$FIX/fields.json"
}

# A repository without senior-mode.
setup
logged "project create" && fail "an empty Project created instead of a copy of the template"
logged "copyProjectV2" || fail "the template Project was not copied"
logged '"template":"PVT_TPL"' || fail "copied from another Project than board.template: $(cat "$GH_LOG")"
logged '"owner":"U_acme"' || fail "the copy is not owned by the repository's owner"
logged '"title":"app"' || fail "the copy is not named after the repository"
logged "includeDraftIssues: false" || fail "draft issues copied"
logged '"public":true' && fail "the copy of a private repository made public"
grep -q "Project #7 app: copied from the template" "$work/err" "$work/out" || fail "copy not reported: $(cat "$work/out" "$work/err")"
grep -q "the copy lacks" "$work/out" && fail "a copy that has everything reported lacking: $(cat "$work/out")"
logged "project link 7 --owner acme --repo acme/app" || fail "Project not linked"
[ "$(cfg .project.number)/$(cfg .project.id)/$(cfg .project.owner)" = 7/PVT_NEW/acme ] || fail "project not cached: $(cfg .project)"
[ "$(cfg .language)" = fr ] || fail "other config keys lost"
[ "$(cfg '.project.fields.Status.options | keys_unsorted | join(",")')" = "Backlog,Ready,In progress,In review,Done" ] ||
  fail "Status options: $(cfg .project.fields.Status.options)"
[ "$(cfg '.project.fields.Status.options | [.Backlog, ."In progress", .Done] | join(",")')" = O_todo,O_prog,O_done ] ||
  fail "existing Status options not kept by id: $(cfg .project.fields.Status.options)"
[ "$(cfg '.project.fields.Priority.options | keys_unsorted | join(",")')" = "P0 now,P1 next,P2 later,P3 someday" ] ||
  fail "Priority: $(cfg .project.fields.Priority)"
[ "$(cfg '.project.fields.Size.options | keys_unsorted | join(",")')" = "S,M,L" ] || fail "Size: $(cfg .project.fields.Size)"
[ "$(cfg '.project.fields.Severity.options | keys_unsorted | join(",")')" = "critical,high,moderate,low" ] ||
  fail "Severity: $(cfg .project.fields.Severity)"
logged '"name":"critical","color":"RED"' || fail "Severity created without its colours"
# #174: a text field Paths, cached by id only.
[ "$(cfg '.project.fields.Paths.id')" = F_Paths ] || fail "Paths not cached: $(cfg .project.fields)"
[ "$(cfg '.project.fields.Paths | has("options")')" = false ] || fail "Paths cached with options: $(cfg .project.fields.Paths)"
logged 'dataType: TEXT' || fail "Paths not created as a text field: $(cat "$GH_LOG")"
grep -q 'Severity, Paths; ids cached' "$work/out" || fail "output does not mention Paths: $(cat "$work/out")"
logged '"name":"P0 now","color":"RED"' || fail "created fields without their colours"
for label in needs-human needs-info blocked security triage qualified type:feature type:bug type:task type:chore; do
  logged "label create $label" || fail "label $label not created"
done
logged "--enable-rebase-merge --enable-merge-commit=false --enable-squash-merge=false --delete-branch-on-merge" ||
  fail "merge settings not set"
logged "api -X POST repos/acme/app/rulesets" || fail "no ruleset created"
for rule in '"include":["~DEFAULT_BRANCH"]' '{"context":"senior-mode/ci"},{"context":"senior-mode/review"},{"context":"senior-mode/security"}' \
  '"strict_required_status_checks_policy":true' '{"type":"required_linear_history"}' '"bypass_mode":"always"' \
  '"allowed_merge_methods":["rebase"]'; do
  tr -d ' \n' <"$GH_LOG" | grep -qF -- "$rule" || fail "ruleset without $rule"
done
logged "/protection" && fail "classic branch protection rewritten"

# #180: an Iteration field of two weeks (26 of them from the Monday of this week), Start and End dates, cached by id.
logged 'dataType: ITERATION' || fail "no Iteration field created: $(cat "$GH_LOG")"
logged '"duration":14' || fail "iterations are not two weeks"
[ "$(jq -r '.data.node.field.configuration.iterations | length' "$FIX/iteration.json")" -eq 26 ] || fail "iterations: $(cat "$FIX/iteration.json")"
monday=$(date -u -d "@$(($(date +%s) - ($(date -u +%u) - 1) * 86400))" +%Y-%m-%d)
[ "$(jq -r '.data.node.field.configuration.iterations[0].startDate' "$FIX/iteration.json")" = "$monday" ] ||
  fail "the first iteration is not this week's Monday: $(jq -c '.data.node.field.configuration.iterations[0]' "$FIX/iteration.json")"
[ "$(jq -r '.data.node.field.configuration.iterations[1].startDate' "$FIX/iteration.json")" = "$(date -u -d "$monday +14 days" +%Y-%m-%d)" ] ||
  fail "iterations are not two weeks apart"
logged 'dataType: DATE' || fail "no date field created"
[ "$(cfg '.project.fields.Iteration | [.id, .iteration] | join("|")')" = "F_Iteration|true" ] || fail "Iteration not cached: $(cfg .project.fields)"
[ "$(cfg '[.project.fields.Start, .project.fields.End] | map([.id, .date] | join("|")) | join(",")')" = "F_Start|true,F_End|true" ] ||
  fail "Start and End not cached: $(cfg .project.fields)"
grep -q 'fields created: Iteration (14-day iterations from .*), Start, End' "$work/out" || fail "output does not say the cycle fields: $(cat "$work/out")"

# Running it again changes nothing that exists.
before=$(cat "$repo/.claude/senior-mode.json")
setup
logged "copyProjectV2" && fail "second run copies the template again"
logged "createProjectV2Field" && fail "second run creates a field"
logged "updateProjectV2Field" && fail "second run rewrites field options"
logged "api -X POST repos/acme/app/rulesets" && fail "second run creates another ruleset"
logged "api -X PUT repos/acme/app/rulesets/9" || fail "second run does not update the ruleset"
[ "$(cat "$repo/.claude/senior-mode.json")" = "$before" ] || fail "second run changes the config"

# The board template: the default is the Project senior-mode ships, board.template overrides it.
echo '{"language": "fr"}' >"$repo/.claude/senior-mode.json"
setup
logged '"template":"PVT_kwHOAZfEPs4Bs2sq"' || fail "the default template is not the shipped one: $(cat "$GH_LOG")"
[ "$(cd "$repo" && "$cli" config get board.template)" = PVT_kwHOAZfEPs4Bs2sq ] ||
  fail "board.template has no default"
echo '{"language": "fr", "board": {"template": "PVT_TPL"}}' >"$repo/.claude/senior-mode.json"

# A public repository gets a public Project.
repo_json User false
setup
logged '"public":true' || fail "the copy of a public repository is not made public: $(cat "$GH_LOG")"
repo_json User

# Views and workflows the template has and the copy lacks are named, with where to fix them.
jq '.data.node.views.nodes += [{name: "ROADMAP"}] | .data.node.workflows.nodes += [{name: "Item added to project", enabled: true}]' \
  "$FIX/template-project.json" >"$FIX/f" && mv "$FIX/f" "$FIX/template-project.json"
echo '{"language": "fr", "board": {"template": "PVT_TPL"}}' >"$repo/.claude/senior-mode.json"
setup
grep -q "the copy lacks views ROADMAP; workflows Item added to project" "$work/out" || fail "what the copy lacks not named: $(cat "$work/out")"
grep -q "by hand" "$work/out" || fail "no word on where to fix it: $(cat "$work/out")"
# A workflow the template has off is not asked for.
grep -q "workflows .*Item closed" "$work/out" && fail "a workflow off in the template reported lacking: $(cat "$work/out")"

# An existing Project is never replaced: setup lists what the template has and it lacks and names --migrate.
: >"$GH_LOG"
setup
logged "copyProjectV2" && fail "an existing Project copied over"
grep -q "the Project lacks views ROADMAP; workflows Item added to project" "$work/out" || fail "existing Project: lacks not named: $(cat "$work/out")"
grep -q -- "--migrate" "$work/out" || fail "existing Project: --migrate not mentioned: $(cat "$work/out")"
# Nothing lacking: nothing said.
project_workflows true true
setup
grep -q "lacks" "$work/out" && fail "an existing Project that matches the template reported lacking: $(cat "$work/out")"
# A template that cannot be read does not stop setup.
jq '.data.node.views.nodes += [{name: "ROADMAP"}]' "$FIX/template-project.json" >"$FIX/f" && mv "$FIX/f" "$FIX/template-project.json"
TEMPLATE_ERR="gh: Could not resolve to a node (HTTP 404)" setup
grep -q "could not read the template Project PVT_TPL" "$work/out" || fail "unreadable template not said: $(cat "$work/out")"
project_workflows true true

# A template that cannot be copied stops setup, with no config written.
echo '{"language": "fr", "board": {"template": "PVT_TPL"}}' >"$repo/.claude/senior-mode.json"
cp "$repo/.claude/senior-mode.json" "$work/before"
: >"$GH_LOG"
(cd "$repo" && COPY_ERR="gh: Could not resolve to a ProjectV2 (HTTP 404)" "$cli" setup github) >"$work/out" 2>"$work/err" &&
  fail "setup succeeds although the template cannot be copied"
grep -q "Could not resolve" "$work/err" || fail "copy error not reported: $(cat "$work/err")"
cmp -s "$work/before" "$repo/.claude/senior-mode.json" || fail "config rewritten after a failed copy"

# The Project README and short description state the process, in the project language (#178); only the
# block between the markers is rewritten.
readme() { jq -r '.data.node.readme // ""' "$FIX/board.json"; }
short() { jq -r '.data.node.shortDescription // ""' "$FIX/board.json"; }
set_board() { jq -n --arg r "$1" --arg d "$2" '{data: {node: {readme: $r, shortDescription: $d}}}' >"$FIX/board.json"; }
lang() { jq --arg l "$1" '.language = $l' "$repo/.claude/senior-mode.json" >"$work/c" && mv "$work/c" "$repo/.claude/senior-mode.json"; }
set_board "" ""
lang fr
setup
for want in "<!-- senior-mode:begin" "<!-- senior-mode:end -->" "Backlog" "Ready" "In progress" "In review" "Done" "Définition de Ready" \
  "Qui déplace quoi" "https://github.com/acme/app/tree/HEAD/docs/specs"; do
  readme | grep -qF -- "$want" || fail "README without '$want': $(readme)"
done
readme | grep -qF "{{" && fail "README placeholder left: $(readme)"
[ -n "$(short)" ] || fail "no short description"
short | grep -q "Tableau senior-mode" || fail "short description not in the project language: $(short)"
grep -q "board README: written" "$work/out" || fail "README write not reported: $(cat "$work/out")"
# A rerun changes nothing.
setup
logged "UpdateProjectV2Input" && fail "a rerun rewrites the README: $(cat "$GH_LOG")"
grep -q "board README: written" "$work/out" && fail "a rerun reports a write: $(cat "$work/out")"
# English, and a language without templates falls back to it.
for l in en de; do
  set_board "" ""
  lang "$l"
  setup
  readme | grep -qF "Definition of Ready" || fail "$l: README not in English: $(readme)"
  readme | grep -qF "Who moves what" || fail "$l: README without who moves what: $(readme)"
  short | grep -q "senior-mode board" || fail "$l: short description not in English: $(short)"
done
# Text around the block survives, above and below; a change of language rewrites the block alone.
lang en
setup
printf '# Our board\n\nKeep this.\n\n%s\n\n## Notes\nAnd this.' "$(readme)" >"$work/readme"
set_board "$(cat "$work/readme")" "$(short)"
lang fr
setup
readme | grep -qF "Définition de Ready" || fail "block not rewritten in the new language: $(readme)"
readme | grep -qF "Definition of Ready" && fail "the old block stayed: $(readme)"
[ "$(readme | head -4)" = "$(head -4 "$work/readme")" ] || fail "text above the block changed: $(readme)"
readme | tail -2 | grep -qF "And this." || fail "text below the block lost: $(readme)"
[ "$(readme | grep -c 'senior-mode:begin')" = 1 ] || fail "block duplicated: $(readme)"
short | grep -q "Tableau senior-mode" || fail "our short description not updated with the language: $(short)"
# A README with no block gets one at the end.
set_board "Hand written board notes." ""
setup
[ "$(readme | head -1)" = "Hand written board notes." ] || fail "hand written README rewritten: $(readme)"
readme | grep -qF "senior-mode:begin" || fail "block not appended: $(readme)"
# A short description of the user's own stays.
set_board "" "My board, my words"
setup
[ "$(short)" = "My board, my words" ] || fail "the user's short description replaced: $(short)"
# Broken markers: left untouched, and said.
set_board $'before\n<!-- senior-mode:begin\nno end' ""
setup
[ "$(readme)" = $'before\n<!-- senior-mode:begin\nno end' ] || fail "broken markers: README rewritten: $(readme)"
grep -q "markers broken" "$work/out" || fail "broken markers not said: $(cat "$work/out")"
set_board "" ""
lang fr

# A required check someone added by hand to the ruleset survives the update (merged, not replaced), and
# ours are not listed twice.
echo '{"rules": [{"type": "required_status_checks", "parameters": {"required_status_checks": [
  {"context": "senior-mode/ci"}, {"context": "ci/lint", "integration_id": 15368}]}}]}' >"$FIX/ruleset-9.json"
setup
logged "api -X PUT repos/acme/app/rulesets/9" || fail "no update to merge into"
tr -d ' \n' <"$GH_LOG" | grep -qF '{"context":"ci/lint","integration_id":15368}' || fail "a hand-added required check was dropped: $(cat "$GH_LOG")"
[ "$(grep -o 'senior-mode/security' "$GH_LOG" | wc -l)" -eq 1 ] || fail "senior-mode/security not required exactly once"
[ "$(grep -o '"senior-mode/ci"' "$GH_LOG" | wc -l)" -eq 1 ] || fail "senior-mode/ci listed twice"
echo '{"rules": []}' >"$FIX/ruleset-9.json"

# #296: github.requiredChecks false leaves the required status checks out of the ruleset, and removes the rule
# an existing ruleset had (a check added by hand included); setup says so. The default stays true.
cp "$repo/.claude/senior-mode.json" "$work/config.checks"
echo '{"rules": [{"type": "required_status_checks", "parameters": {"required_status_checks": [
  {"context": "senior-mode/ci"}, {"context": "ci/lint"}]}}]}' >"$FIX/ruleset-9.json"
jq '.github.requiredChecks = false' "$work/config.checks" >"$repo/.claude/senior-mode.json"
setup
logged "api -X PUT repos/acme/app/rulesets/9" || fail "requiredChecks false: ruleset not updated"
tr -d ' \n' <"$GH_LOG" | grep -qF '{"type":"required_linear_history"}' || fail "requiredChecks false: the other rules are gone: $(cat "$GH_LOG")"
logged "required_status_checks" && fail "requiredChecks false: the ruleset still has the rule: $(cat "$GH_LOG")"
logged "senior-mode/ci" && fail "requiredChecks false: a status is still required"
logged "ci/lint" && fail "requiredChecks false: a check added by hand kept"
grep -q "github.requiredChecks is false, so it requires no status check" "$work/out" || fail "requiredChecks false not said: $(cat "$work/out")"
grep -q "senior-mode/ci, senior-mode/review and senior-mode/security on an up-to-date branch" "$work/out" && fail "requiredChecks false: the output still announces the statuses"
[ "$(cfg .github.requiredChecks)" = false ] || fail "requiredChecks lost from the config: $(cfg .github)"
# A new ruleset has none either.
rm -f "$FIX/rulesets.json"
setup
logged "api -X POST repos/acme/app/rulesets" || fail "requiredChecks false: no ruleset created"
logged "required_status_checks" && fail "requiredChecks false: a new ruleset has the rule: $(cat "$GH_LOG")"
# Only a boolean is a value.
jq '.github.requiredChecks = "no"' "$work/config.checks" >"$repo/.claude/senior-mode.json"
: >"$GH_LOG"
(cd "$repo" && "$cli" setup github) >"$work/out" 2>"$work/err" && fail "requiredChecks \"no\" accepted"
grep -q "github.requiredChecks .* must be true or false" "$work/err" || fail "a bad requiredChecks not explained: $(cat "$work/err")"
logged "label create" && fail "a bad requiredChecks reported only after the changes"
# true is the default and says it.
jq '.github.requiredChecks = true' "$work/config.checks" >"$repo/.claude/senior-mode.json"
setup
tr -d ' \n' <"$GH_LOG" | grep -qF '{"context":"senior-mode/ci"}' || fail "requiredChecks true: no required status"
[ "$(cd "$repo" && "$cli" config get github.requiredChecks)" = true ] || fail "github.requiredChecks has no default"
cp "$work/config.checks" "$repo/.claude/senior-mode.json"
echo '[{"id": 9, "name": "senior-mode", "source_type": "Repository"}]' >"$FIX/rulesets.json"
echo '{"rules": []}' >"$FIX/ruleset-9.json"

grep -q 'Workflows' "$work/out" && fail "built-in workflows reported although both are on: $(cat "$work/out")"

# Built-in workflows off: setup names them and says where to turn them on.
project_workflows false false
setup
grep -q '"Item closed".*"Pull request merged"\|Item closed, Pull request merged' "$work/out" ||
  fail "workflows off not named: $(cat "$work/out")"
grep -q 'Workflows' "$work/out" || fail "no hint where to turn the workflows on: $(cat "$work/out")"
grep -q 'Auto-add' "$work/out" && fail "an unrelated workflow reported"
project_workflows true false
setup
grep -q 'Pull request merged' "$work/out" || fail "one workflow off not named"
grep -q 'Item closed' "$work/out" && fail "an enabled workflow named as off"
project_workflows true true
# The workflows query fails (#163): setup still succeeds and says to check by hand.
touch "$FIX/workflows-fail"
setup
rm -f "$FIX/workflows-fail"
grep -q 'built-in workflows: could not read them; check Project → Workflows by hand' "$work/out" ||
  fail "an unreadable workflows query is not said: $(cat "$work/out")"
grep -q 'built-in workflows off' "$work/out" && fail "workflows reported off when they could not be read: $(cat "$work/out")"

# The cycle fields are never duplicated, and an existing Start of another type is left alone, said, not cached.
setup
grep -q 'fields created' "$work/out" && fail "a rerun created cycle fields again: $(cat "$work/out")"
jq '(.data.node.fields.nodes[] | select(.name == "Start") | .dataType) = "TEXT"' "$FIX/fields.json" >"$FIX/f" && mv "$FIX/f" "$FIX/fields.json"
setup
grep -q 'field Start: exists and is not a date field' "$work/out" || fail "a Start of another type is not said: $(cat "$work/out")"
[ "$(cfg '.project.fields | has("Start")')" = false ] || fail "a Start that is not a date was cached"
[ "$(cfg '.project.fields | has("End")')" = true ] || fail "End lost with Start"
logged "createProjectV2Field" && fail "a field named Start created twice"
jq '(.data.node.fields.nodes[] | select(.name == "Start") | .dataType) = "DATE"' "$FIX/fields.json" >"$FIX/f" && mv "$FIX/f" "$FIX/fields.json"
# board.iterationDays sets the length of the iterations of a new field.
rm -f "$FIX/iteration.json"
cp "$repo/.claude/senior-mode.json" "$work/config.keep"
jq '.board.iterationDays = 7' "$work/config.keep" >"$repo/.claude/senior-mode.json"
setup
[ "$(jq -r '.data.node.field.configuration.duration' "$FIX/iteration.json")" -eq 7 ] || fail "board.iterationDays ignored: $(cat "$FIX/iteration.json")"
jq '.board.iterationDays = "x"' "$work/config.keep" >"$repo/.claude/senior-mode.json"
(cd "$repo" && "$cli" setup github) >"$work/out" 2>"$work/err" && fail "iterationDays x accepted"
grep -q 'board.iterationDays must be a positive whole number' "$work/err" || fail "bad iterationDays not explained: $(cat "$work/err")"
cp "$work/config.keep" "$repo/.claude/senior-mode.json"
rm -f "$FIX/iteration.json"
setup

# A field deleted on the board is created again.
jq 'del(.data.node.fields.nodes[] | select(.name == "Size"))' "$FIX/fields.json" >"$FIX/f" && mv "$FIX/f" "$FIX/fields.json"
setup
logged '"name":"Size"' || fail "deleted Size field not recreated"
[ "$(cfg '.project.fields.Size.options | keys_unsorted | join(",")')" = "S,M,L" ] || fail "Size after repair: $(cfg .project.fields.Size)"

# A Status with both the name and its alias: the exact name keeps its id, the alias stays as an extra.
status_field '[{"id": "O_todo2", "name": "Todo", "color": "GRAY", "description": ""},
  {"id": "O_todo", "name": "Backlog", "color": "GRAY", "description": ""},
  {"id": "O_prog", "name": "In progress", "color": "YELLOW", "description": ""},
  {"id": "O_done", "name": "Done", "color": "PURPLE", "description": ""}]'
setup
[ "$(cfg '.project.fields.Status.options | [.Backlog, .Todo] | join(",")')" = O_todo,O_todo2 ] ||
  fail "name and alias mixed up: $(cfg .project.fields.Status.options)"

# A cached Project that cannot be read for another reason stops setup without creating one.
: >"$GH_LOG"
(cd "$repo" && VIEW_ERR="HTTP 401: Bad credentials" "$cli" setup github) >"$work/out" 2>"$work/err" &&
  fail "setup succeeds although the Project cannot be read"
grep -q "Bad credentials" "$work/err" || fail "view error not reported: $(cat "$work/err")"
logged "copyProjectV2" && fail "copies the template after a view error"
logged "project list" && fail "looks the Project up by title after a view error"

# A cached Project that no longer exists falls back to the one with the repository's title, in an organization.
echo '{"language": "fr", "project": {"number": 99}}' >"$repo/.claude/senior-mode.json"
echo '{"projects": [{"number": 5, "title": "app"}]}' >"$FIX/projects.json"
echo '{"number": 5, "id": "PVT_5"}' >"$FIX/project.json"
jq '(.data.node.fields.nodes[] | select(.name == "Status") | .options) += [{"id": "O_ice", "name": "Icebox", "color": "BLUE", "description": ""}]' \
  "$FIX/fields.json" >"$FIX/f" && mv "$FIX/f" "$FIX/fields.json"
repo_json Organization
setup
logged "copyProjectV2" && fail "copies the template although a Project has the repository's title"
[ "$(cfg .project.number)" = 5 ] || fail "Project found by title not used: $(cfg .project.number)"
[ "$(cfg '.project.fields.Status.options.Icebox')" = O_ice ] || fail "a Project's own option was dropped"
logged "label create type:" && fail "type labels in an organization (issue types instead)"

# A failing Project command stops setup: no duplicate Project, no empty id cached.
failing() {
  : >"$GH_LOG"
  cp "$repo/.claude/senior-mode.json" "$work/before"
  (cd "$repo" && env "$1=HTTP 401: Bad credentials" "$cli" setup github) >"$work/out" 2>"$work/err" &&
    fail "$1: setup succeeds although a Project command failed"
  logged "copyProjectV2" && fail "$1: copies the template after the failure"
  cmp -s "$work/before" "$repo/.claude/senior-mode.json" || fail "$1: config rewritten after the failure"
}
echo '{"language": "fr", "project": {"number": 99}}' >"$repo/.claude/senior-mode.json"
failing LIST_ERR
echo '{"language": "fr", "project": {"number": 5}}' >"$repo/.claude/senior-mode.json"
failing LINK_ERR

# ci.mode local (the default): active workflows are disabled on GitHub, never deleted.
echo '[{"id": 11, "name": "CI", "path": ".github/workflows/ci.yml", "state": "active"},
  {"id": 12, "name": "Old", "path": ".github/workflows/old.yml", "state": "disabled_manually"},
  {"id": 13, "name": "Dependabot Updates", "path": "dynamic/dependabot/dependabot-updates", "state": "active"},
  {"id": 14, "name": "senior-mode", "path": ".github/workflows/senior-mode.yml", "state": "active"}]' >"$FIX/workflows.json"
setup
logged "workflow list --all --limit 1000" || fail "workflows past the first 50 are not listed"
logged "workflow disable 11 --repo acme/app" || fail "an active workflow is left running in local mode"
logged "workflow disable 12" && fail "an already disabled workflow is disabled again"
logged "workflow disable 13" && fail "a GitHub built-in workflow (Dependabot) is disabled"
grep -q "workflows: disabled CI, senior-mode" "$work/out" || fail "disabled workflows not reported: $(cat "$work/out")"
grep -q "gh workflow enable" "$work/out" || fail "no way back given: $(cat "$work/out")"
grep -q "setup github --ci actions" "$work/out" || fail "no lasting way back given: $(cat "$work/out")"
[ "$(cfg .ci.mode)" = null ] || fail "ci.mode written without --ci"

# --ci actions: stored, nothing disabled, and our own workflow turned back on.
jq '(.[] | select(.id == 14) | .state) = "disabled_manually"' "$FIX/workflows.json" >"$work/w" && mv "$work/w" "$FIX/workflows.json"
: >"$GH_LOG"
echo '{"can_approve_pull_request_reviews": false}' >"$FIX/actions-permissions.json"
(cd "$repo" && "$cli" setup github --ci actions) >"$work/out" 2>"$work/err" || fail "setup --ci actions failed: $(cat "$work/err")"
grep -q "RELEASE_PLEASE_TOKEN" "$work/out" || fail "release PRs blocked by the Actions setting, not said: $(cat "$work/out")"
logged "api -X PUT repos/acme/app/actions/permissions" && fail "the Actions permissions are changed without consent"
touch "$FIX/secret"
(cd "$repo" && "$cli" setup github) >"$work/out" 2>&1
grep -q "RELEASE_PLEASE_TOKEN" "$work/out" && fail "release warning repeated though the token secret is stored: $(cat "$work/out")"
rm "$FIX/secret"
[ "$(cfg .ci.mode)" = actions ] || fail "--ci actions not stored: $(cfg .ci)"
logged "workflow disable" && fail "workflows disabled in actions mode"
logged "workflow enable 14 --repo acme/app" || fail "a disabled senior-mode workflow stays off in actions mode"
echo '{"can_approve_pull_request_reviews": true}' >"$FIX/actions-permissions.json"
setup
logged "workflow disable" && fail "a rerun without --ci forgets the stored mode"
grep -q "RELEASE_PLEASE_TOKEN" "$work/out" && fail "release note printed though Actions may open pull requests"
(cd "$repo" && "$cli" setup github --ci cloud) >/dev/null 2>&1 && fail "an unknown ci mode is accepted"

# The ruleset is recorded as the protection when it is in place.
[ "$(cfg .github.protection)" = ruleset ] || fail "protection not recorded as ruleset: $(cfg .github)"

# GitHub's own scanners (#172, amended by #222): Dependabot alerts, secret scanning and push protection
# are switched on. Security updates (automated-security-fixes) are not: GitHub has no severity filter
# for them, so alerts become issues only (#144 path). No dependabot.yml is written; one that exists
# is left untouched and setup says so.
dep=$repo/.github/dependabot.yml
rm -f "$dep"
echo '{}' >"$repo/package.json"
setup
logged "api -X PUT repos/acme/app/vulnerability-alerts" || fail "Dependabot alerts not enabled: $(cat "$GH_LOG")"
logged "automated-security-fixes" && fail "Dependabot security updates turned on: $(cat "$GH_LOG")"
for want in "security_and_analysis[secret_scanning][status]=enabled" "security_and_analysis[secret_scanning_push_protection][status]=enabled"; do
  logged "api -X PATCH repos/acme/app -f" || fail "repository not patched"
  logged "$want" || fail "repository not patched with $want"
done
[ ! -e "$dep" ] || fail "dependabot.yml written: $(cat "$dep")"
grep -qF "Dependabot security updates" "$work/out" && fail "security updates still reported: $(cat "$work/out")"
logged "git commit" && fail "setup committed something"
grep -qiE "alerts.*(on|enabled)" "$work/out" || fail "scanners not reported on: $(cat "$work/out")"
grep -q "dependabot.yml" "$work/out" && fail "dependabot.yml mentioned though there is none: $(cat "$work/out")"

# A dependabot.yml of the project's own is left untouched, and setup says so; a rerun keeps the scanners on.
mkdir -p "$repo/.github"; echo "version: 2 # mine" >"$dep"
setup
[ "$(cat "$dep")" = "version: 2 # mine" ] || fail "a dependabot.yml of the project's own was rewritten"
grep -q "dependabot.yml: .*untouched" "$work/out" || fail "existing file not reported untouched: $(cat "$work/out")"
logged "api -X PUT repos/acme/app/vulnerability-alerts" || fail "rerun does not keep the scanners on"
logged "automated-security-fixes" && fail "rerun turned security updates on"

# No manifest or another ecosystem: still no file.
rm -f "$dep" "$repo/package.json"
echo 'module example.com/app' >"$repo/go.mod"
setup
[ ! -e "$dep" ] || fail "dependabot.yml written for a go project: $(cat "$dep")"
rm -f "$repo/go.mod"

# A plan that refuses (HTTP 403 or 422): each refusal is said, the other features are still tried,
# and setup goes on to the end.
SEC_REFUSE="alerts scanning" setup
for f in vulnerability-alerts "api -X PATCH repos/acme/app"; do
  logged "$f" || fail "refused plan: $f not attempted"
done
for want in "Dependabot alerts: not enabled" "secret scanning (with push protection): not enabled" "HTTP 422"; do
  grep -qF -- "$want" "$work/out" || fail "refusal without '$want': $(cat "$work/out")"
done
logged "workflow list" || fail "setup stopped at the refusal"
SEC_REFUSE="alerts" SEC_ERR="Resource not accessible by personal access token (HTTP 403)" setup
grep -qF "Dependabot alerts: not enabled" "$work/out" || fail "403 not said: $(cat "$work/out")"
grep -qF "secret scanning (with push protection): not enabled" "$work/out" && fail "an accepted feature reported as refused"
rm -f "$dep"

# CODEOWNERS from the protected globs (#171): a managed block, the owner's entries around it kept, and
# the ruleset requires code owner review only when there is something to own.
co=$repo/.github/CODEOWNERS
review_required() { tr -d ' \n' <"$GH_LOG" | grep -qF '"require_code_owner_review":true'; }
set_protected() { jq --argjson p "$1" '.protected = $p' "$repo/.claude/senior-mode.json" >"$work/c" && mv "$work/c" "$repo/.claude/senior-mode.json"; }
repo_json User
set_protected '[]'
setup
[ ! -e "$co" ] || fail "CODEOWNERS written without protected globs: $(cat "$co")"
review_required && fail "code owner review required without protected globs"
set_protected '["**/migrations/**", ".github/workflows/**", ".env*", "*.pem", "Dockerfile*", "docs/", "/infra/*.tf", "src/middleware.*", "a?.txt", "ci/**/x.sh"]'
setup
want='# senior-mode:begin (managed from protected in .claude/senior-mode.json; edit outside this block)
**/migrations/** @acme
/.github/workflows/** @acme
.env* @acme
*.pem @acme
Dockerfile* @acme
/docs/ @acme
/infra/*.tf @acme
/src/middleware.* @acme
a?.txt @acme
/ci/**/x.sh @acme
# senior-mode:end'
[ "$(cat "$co" 2>/dev/null)" = "$want" ] || fail "CODEOWNERS: $(cat "$co" 2>/dev/null)"
review_required || fail "ruleset without require_code_owner_review"
grep -q "CODEOWNERS: created" "$work/out" || fail "creation not reported: $(cat "$work/out")"
grep -q "commit" "$work/out" || fail "no word that the file is for the user to commit: $(cat "$work/out")"
grep -q "approve their own" "$work/out" || fail "author-cannot-approve limit not said: $(cat "$work/out")"
logged "git commit" && fail "setup committed CODEOWNERS"

# A rerun changes nothing; entries added by hand, above and below the block, survive a changed list.
cp "$co" "$work/co"
setup
cmp -s "$work/co" "$co" || fail "rerun changed CODEOWNERS"
grep -qE "CODEOWNERS: (created|updated)" "$work/out" && fail "rerun reports a change: $(cat "$work/out")"
{ echo '/docs/api/ @alice'; cat "$work/co"; echo '/docs/legal/ @bob'; } >"$co"
set_protected '["*.pem", "infra/"]'
setup
[ "$(cat "$co")" = "/docs/api/ @alice
# senior-mode:begin (managed from protected in .claude/senior-mode.json; edit outside this block)
*.pem @acme
/infra/ @acme
# senior-mode:end
/docs/legal/ @bob" ] || fail "hand entries lost or block not rewritten: $(cat "$co")"
grep -q "CODEOWNERS: updated" "$work/out" || fail "update not reported: $(cat "$work/out")"

# A file with no block gets one at the end; globs CODEOWNERS cannot express are named, not written.
printf '* @acme\n' >"$co"
set_protected '["*.pem", "my file/*", "#hash", "!neg", "a[b].c"]'
setup
[ "$(cat "$co")" = "* @acme

# senior-mode:begin (managed from protected in .claude/senior-mode.json; edit outside this block)
*.pem @acme
# left to the reviewer, CODEOWNERS has no spelling for them: my file/*, #hash, !neg, a[b].c
# senior-mode:end" ] || fail "block not appended: $(cat "$co")"
for g in "my file/*" "#hash" "!neg" "a[b].c"; do
  grep -qF "$g" "$work/out" || fail "inexpressible glob $g not named: $(cat "$work/out")"
done

# Emptied list: the block stays, empty, and review is no longer required.
set_protected '[]'
setup
[ "$(cat "$co")" = "* @acme

# senior-mode:begin (managed from protected in .claude/senior-mode.json; edit outside this block)
# senior-mode:end" ] || fail "block not emptied: $(cat "$co")"
review_required && fail "code owner review required with an empty list"

# Broken markers: the file is left alone and setup says so.
printf '# senior-mode:begin\n*.pem @x\n' >"$co"
set_protected '["*.pem"]'
setup
[ "$(cat "$co")" = '# senior-mode:begin
*.pem @x' ] || fail "broken markers: file rewritten: $(cat "$co")"
grep -q "markers" "$work/out" || fail "broken markers not reported: $(cat "$work/out")"
review_required || fail "broken markers over a file that owns: review lowered"
grep -q "stays required: .github/CODEOWNERS, the CODEOWNERS file GitHub reads, has an owner entry" "$work/out" ||
  fail "broken markers: reason not said: $(cat "$work/out")"
printf '# senior-mode:begin\n# no owner here\n' >"$co"
setup
review_required && fail "broken markers over a file with no owner line: review required"

# Never lowered: a ruleset that already requires code owner review keeps it while nothing in the files owns.
jq -n '{rules: [{type: "pull_request", parameters: {require_code_owner_review: true}}]}' >"$FIX/ruleset-9.json"
setup
review_required || fail "ruleset already requiring review lowered"
grep -q "stays required: the ruleset already requires it" "$work/out" || fail "ruleset reason not said: $(cat "$work/out")"

# A ruleset that cannot be read is not a ruleset that does not require review: it stays required, and
# says why. When setup's own read of the ruleset fails, it does not write at all.
rm -f "$FIX/get-failed"
RULESET_GET_FAIL_ONCE=1 setup
review_required || fail "an unreadable ruleset lowered the review"
grep -q "stays required: the current ruleset could not be read" "$work/out" || fail "unreadable ruleset not said: $(cat "$work/out")"
: >"$GH_LOG"
(cd "$repo" && RULESET_GET_ERR="gh: Resource not accessible by personal access token (HTTP 403)" "$cli" setup github) \
  >"$work/out" 2>"$work/err" && fail "setup went on although the ruleset could not be read"
logged "-X PUT repos/acme/app/rulesets" && fail "ruleset written although it could not be read: $(cat "$GH_LOG")"
grep -q "ruleset on the default branch" "$work/err" || fail "unreadable ruleset not reported: $(cat "$work/err")"
echo '{"rules": []}' >"$FIX/ruleset-9.json"

# An organization has no user to own the file: the owner is the signed-in user.
rm "$co"
repo_json Organization
setup
[ "$(cat "$co")" = "# senior-mode:begin (managed from protected in .claude/senior-mode.json; edit outside this block)
*.pem @maintainer
# senior-mode:end" ] || fail "organization owner: $(cat "$co")"

# Until the file is on the default branch nothing is enforced, and a rerun that changes nothing says
# so; the copy there, when identical, ends the warning.
rm -f "$FIX/default-codeowners"
set_protected '["*.pem"]'
setup
cp "$co" "$work/co"
setup
cmp -s "$work/co" "$co" || fail "rerun changed CODEOWNERS"
grep -qE "CODEOWNERS: (created|updated)" "$work/out" && fail "unchanged rerun reports a change: $(cat "$work/out")"
grep -q "enforces nothing until .github/CODEOWNERS is on the default branch" "$work/out" ||
  fail "unchanged rerun does not say nothing is enforced yet: $(cat "$work/out")"
echo "stale" >"$FIX/default-codeowners"
setup
grep -q "enforces nothing until .github/CODEOWNERS is on the default branch" "$work/out" ||
  fail "a differing copy on the default branch not said: $(cat "$work/out")"
cp "$co" "$FIX/default-codeowners"
setup
grep -q "enforces nothing" "$work/out" && fail "warning although the default branch holds the file: $(cat "$work/out")"
rm -f "$FIX/default-codeowners"
set_protected '[]'
setup
grep -q "enforces nothing" "$work/out" && fail "warning without protected globs: $(cat "$work/out")"
set_protected '["*.pem"]'

# A root or docs/ CODEOWNERS would be shadowed by .github/CODEOWNERS (GitHub reads .github/ first):
# setup refuses to create the shadow, says so, and goes on with the rest.
for shadow in CODEOWNERS docs/CODEOWNERS; do
  rm -rf "$repo/.github" "$repo/docs" "$repo/CODEOWNERS"
  mkdir -p "$(dirname "$repo/$shadow")"
  echo "* @alice" >"$repo/$shadow"
  : >"$GH_LOG"
  setup
  [ ! -e "$co" ] || fail "$shadow: .github/CODEOWNERS written over it: $(cat "$co")"
  [ "$(cat "$repo/$shadow")" = "* @alice" ] || fail "$shadow: the existing file was changed"
  grep -q "CODEOWNERS: $shadow would be shadowed" "$work/out" || fail "$shadow: refusal not said: $(cat "$work/out")"
  logged "rulesets" || fail "$shadow: setup stopped at the refusal"
  review_required || fail "$shadow: the file GitHub reads owns by hand, review no longer required"
  grep -q "stays required: $shadow, the CODEOWNERS file GitHub reads, has an owner entry" "$work/out" ||
    fail "$shadow: reason not said: $(cat "$work/out")"
done
# Already shadowed by a .github/CODEOWNERS: the block is written, the lost file is named on each run.
mkdir -p "$repo/.github"
printf '/docs/api/ @bob\n' >"$co"
for i in 1 2; do
  setup
  grep -q "ignored by GitHub: docs/CODEOWNERS" "$work/out" || fail "shadowed file not named (run $i): $(cat "$work/out")"
done
grep -q "^\*.pem @maintainer$" "$co" || fail "block not written next to a shadowed file: $(cat "$co")"
rm -rf "$repo/.github" "$repo/docs" "$repo/CODEOWNERS"
# A root file with no owner line owns nothing: nothing to keep, review not required.
rm -rf "$repo/.github" "$repo/docs" "$repo/CODEOWNERS"
printf '# nobody yet\n' >"$repo/CODEOWNERS"
setup
review_required && fail "review required with a root CODEOWNERS that owns nothing"
grep -q "code owner review is not required" "$work/out" || fail "no word that review is not required: $(cat "$work/out")"
rm -f "$repo/CODEOWNERS"
setup
rm -f "$FIX/default-codeowners"

# Only a 404 from the contents API means the default branch has none; any other error is reported as such.
mkdir -p "$repo/.github"
printf '# senior-mode:begin\n*.pem @acme\n# senior-mode:end\n' >"$co"
CONTENTS_ERR="gh: Server Error (HTTP 500)" setup
grep -q "the default branch has none" "$work/out" && fail "a 500 read as an absent file: $(cat "$work/out")"
grep -q "could not read .github/CODEOWNERS on the default branch.*HTTP 500" "$work/out" || fail "a 500 not reported: $(cat "$work/out")"
setup
grep -q "the default branch has none" "$work/out" || fail "a 404 not read as absent: $(cat "$work/out")"

# Every glob untranslatable: a block with no entry says nobody owns the zones; with no file, the
# block is still written (docs/guide/autonomy.md), and the review is not required.
set_protected '["my file/*", "#hash"]'
setup
grep -q "protected zones owned by" "$work/out" && fail "an empty block claims an owner: $(cat "$work/out")"
grep -q "no protected zone owned" "$work/out" || fail "empty block not said: $(cat "$work/out")"
review_required && fail "code owner review required with an empty block"
rm -rf "$repo/.github"
setup
[ "$(cat "$co" 2>/dev/null)" = "# senior-mode:begin (managed from protected in .claude/senior-mode.json; edit outside this block)
# left to the reviewer, CODEOWNERS has no spelling for them: my file/*, #hash
# senior-mode:end" ] || fail "no file, no spelling: block not written: $(cat "$co" 2>/dev/null)"
review_required && fail "code owner review required with no entry"
set_protected '["*.pem"]'

# Root and docs/ CODEOWNERS together, no .github one: GitHub already ignores docs/; only the root's
# ownership would be lost.
rm -rf "$repo/.github" "$repo/docs" "$repo/CODEOWNERS"
mkdir -p "$repo/docs"
echo "* @alice" >"$repo/CODEOWNERS"
echo "* @bob" >"$repo/docs/CODEOWNERS"
setup
grep -q "CODEOWNERS: CODEOWNERS would be shadowed" "$work/out" || fail "root file not named alone: $(cat "$work/out")"
grep -q "CODEOWNERS and docs/CODEOWNERS would be shadowed" "$work/out" && fail "both files said lost: $(cat "$work/out")"
grep -q "docs/CODEOWNERS is already ignored by GitHub" "$work/out" || fail "docs/ not said already ignored: $(cat "$work/out")"
rm -rf "$repo/.github" "$repo/docs" "$repo/CODEOWNERS"
setup
rm -f "$FIX/default-codeowners"

# Refused plan: the file is still written, but nothing claims the review is enforced.
rm -f "$FIX/rulesets.json" "$co"
PROTECTION_403=1 setup
[ -e "$co" ] || fail "CODEOWNERS not written when the plan refuses the ruleset"
grep -q "approve their own" "$work/out" && fail "owner-approval note printed without a ruleset: $(cat "$work/out")"
rm -rf "$repo/.github"
set_protected '[]'
setup

# Private repository on GitHub Free: the API refuses rulesets (real response of GET and POST, HTTP 403).
# Setup finishes, forces ci.mode local, records protection none and warns in plain words.
rm -f "$FIX/rulesets.json"
echo '[{"id": 14, "name": "senior-mode", "path": ".github/workflows/senior-mode.yml", "state": "disabled_manually"}]' >"$FIX/workflows.json"
for where in 1 write; do
  rm -f "$FIX/rulesets.json"
  jq '.ci.mode = "actions"' "$repo/.claude/senior-mode.json" >"$work/c" && mv "$work/c" "$repo/.claude/senior-mode.json"
  PROTECTION_403=$where setup
  [ "$(cfg .github.protection)" = none ] || fail "$where: protection not recorded as none: $(cfg .github)"
  [ "$(cfg .ci.mode)" = local ] || fail "$where: ci.mode not forced to local: $(cfg .ci)"
  [ "$(cfg .project.number)" = 5 ] || fail "$where: the rest of the setup is lost: $(cfg .project)"
  grep -q "NOT enforced" "$work/out" || fail "$where: no plain warning: $(cat "$work/out")"
  grep -q "push to the default branch" "$work/out" || fail "$where: risk not spelled out: $(cat "$work/out")"
  for option in "public" "Pro" "local"; do
    grep -qi "$option" "$work/out" || fail "$where: option $option missing from the warning"
  done
  logged "workflow enable" && fail "$where: a workflow turned on although ci.mode is local"
  logged "api -X PUT repos/acme/app/rulesets" && fail "$where: ruleset updated although the plan refuses it"
done
[ "$(grep -c "NOT enforced" "$work/out")" = 1 ] || fail "warning repeated: $(cat "$work/out")"

# The plan changes (public, Pro): the next run puts the ruleset back and says so.
setup
[ "$(cfg .github.protection)" = ruleset ] || fail "protection not back to ruleset: $(cfg .github)"
grep -q "NOT enforced" "$work/out" && fail "warning printed although the ruleset is in place"
[ "$(cfg .ci.mode)" = local ] || fail "ci.mode changed back by itself: $(cfg .ci)"

# Any other refusal (403 for a missing permission, 404) still stops setup, and records nothing.
rm -f "$FIX/rulesets.json"
for err in "gh: Resource not accessible by personal access token (HTTP 403)" "gh: Not Found (HTTP 404)" \
  "gh: Upgrade to GitHub Pro or make this repository public to enable this feature. (HTTP 500)"; do
  jq '.github.protection = "ruleset"' "$repo/.claude/senior-mode.json" >"$work/c" && mv "$work/c" "$repo/.claude/senior-mode.json"
  : >"$GH_LOG"
  (cd "$repo" && PROTECTION_403=1 PROTECTION_ERR="$err" "$cli" setup github) >"$work/out" 2>"$work/err" &&
    fail "setup succeeds on: $err"
  grep -qF "${err#gh: }" "$work/err" || fail "error not reported for: $err"
  [ "$(cfg .github.protection)" = ruleset ] || fail "protection rewritten on: $err"
done

# Migrating an existing board (#181): a Project built from the template, every item with its field values.
rm -f "$FIX/rulesets.json"
status_opts() { jq -c 'map({id: ("O_" + .), name: ., color: "GRAY", description: ""})' <<<"$1"; }
jq -n --argjson st "$(status_opts '["Backlog","Ready","In progress","In review","Done"]')" --argjson pr "$(status_opts '["P0 now","P1 next","P2 later","P3 someday"]')" \
  --argjson sz "$(status_opts '["S","M","L"]')" --argjson sv "$(status_opts '["critical","high","moderate","low"]')" \
  '{data: {node: {fields: {nodes: [{}, {id: "F_Status", name: "Status", options: $st}, {id: "F_Priority", name: "Priority", options: $pr},
    {id: "F_Size", name: "Size", options: $sz}, {id: "F_Severity", name: "Severity", options: $sv}, {id: "F_Paths", name: "Paths", dataType: "TEXT"}]}}}}' >"$FIX/fields.json"
jq -n --argjson st "$(status_opts '["Todo","In Progress","Done","Icebox"]')" --argjson pr "$(status_opts '["P0 now","Urgent"]')" \
  --argjson sz "$(status_opts '["S","M","L"]')" --argjson tm "$(status_opts '["Core","Infra"]')" \
  '{data: {node: {fields: {nodes: [{}, {id: "OF_Status", name: "Status", options: $st}, {id: "OF_Priority", name: "Priority", options: $pr},
    {id: "OF_Size", name: "Size", options: $sz}, {id: "OF_Team", name: "Team", options: $tm},
    {id: "OF_Points", name: "Points", dataType: "NUMBER"}, {id: "OF_Notes", name: "Owner notes", dataType: "TEXT"},
    {id: "OF_Sprint", name: "Sprint", dataType: "ITERATION"}, {id: "OF_Title", name: "Title", dataType: "TITLE"}]}}}}' >"$FIX/fields-PVT_OLD.json"
item() { # item-id content-json field-values-json
  jq -nc --arg id "$1" --argjson c "$2" --argjson v "$3" '{id: $id, content: $c, fieldValues: {nodes: $v}}'
}
sel() { jq -nc --arg f "$1" --arg n "$2" '{name: $n, field: {name: $f}}'; }
jq -n --argjson a "$(item OI_1 '{"__typename":"Issue","id":"ISSUE_1"}' "[$(sel Status Todo), $(sel Priority "P0 now"), $(sel Size M), {\"number\": 3, \"field\": {\"name\": \"Points\"}}, {\"text\": \"hello\", \"field\": {\"name\": \"Owner notes\"}}, $(sel Team Core)]")" \
  --argjson b "$(item OI_2 '{"__typename":"PullRequest","id":"PR_2"}' "[$(sel Status "In Progress"), $(sel Priority Urgent)]")" \
  --argjson c "$(item OI_3 '{"__typename":"Issue","id":"ISSUE_3"}' "[$(sel Status Icebox)]")" \
  --argjson d "$(item OI_4 '{"__typename":"DraftIssue","title":"Idea","body":"b"}' "[$(sel Status Done)]")" \
  '{data: {node: {title: "app", public: true, items: {pageInfo: {hasNextPage: false}, nodes: [$a, $b, $c, $d]}}}}' >"$FIX/items-PVT_OLD.json"
rm -f "$FIX"/items-PVT_NEW.json "$FIX"/items-PVT_MIG.json
echo '{"language": "fr", "board": {"template": "PVT_TPL"}, "project": {"owner": "acme", "number": 5, "id": "PVT_OLD"}}' >"$repo/.claude/senior-mode.json"
migrate() { : >"$GH_LOG"; (cd "$repo" && "$cli" setup github --migrate "$@") >"$work/out" 2>"$work/err"; }
mutations() { grep -c '^{.*mutation(' "$GH_LOG"; }
calls() { grep -c "^{.*$1" "$2"; } # GraphQL bodies of a log that name $1

# --dry-run prints the mapping and changes nothing.
cp "$repo/.claude/senior-mode.json" "$work/before"
migrate --dry-run || fail "migrate --dry-run failed: $(cat "$work/err")"
[ "$(mutations)" = 0 ] || fail "dry run mutated GitHub: $(grep '^{.*mutation(' "$GH_LOG")"
logged "project link" && fail "dry run linked a Project"
logged "label create" && fail "dry run went on with the rest of setup"
cmp -s "$work/before" "$repo/.claude/senior-mode.json" || fail "dry run wrote the config: $(cat "$repo/.claude/senior-mode.json")"
for want in "migrate: items: 4 to add, 0 already in the new Project" \
  "migrate: fields to create as is: Team (SINGLE_SELECT), Points (NUMBER), Owner notes (TEXT)" \
  "migrate: options to create as is: Status Icebox, Priority Urgent" \
  "migrate: values mapped: Status Todo -> Backlog, Status In Progress -> In progress" \
  "migrate: not migrated: Sprint (ITERATION)" "dry run, nothing changed"; do
  grep -qF -- "$want" "$work/out" || fail "dry run without '$want': $(cat "$work/out")"
done

# A migration interrupted halfway (the third item fails) keeps the new Project in the config...
COPY_NUMBER=8 COPY_ID=PVT_MIG ADD_FAIL_AFTER=2 migrate && fail "migration succeeded although an item could not be added"
cp "$GH_LOG" "$work/first.log"
[ "$(cfg .project.migration.id)" = PVT_MIG ] || fail "the new Project is not recorded while migrating: $(cfg .project)"
[ "$(cfg .project.number)" = 5 ] || fail "the board switched before the migration was done: $(cfg .project)"
logged '"closed":true' && fail "the old Project closed before the migration was done"
# ...and the rerun picks up where it stopped: nothing added twice, no second copy.
: >"$GH_LOG"
(cd "$repo" && COPY_NUMBER=8 COPY_ID=PVT_MIG "$cli" setup github --migrate) >"$work/out" 2>"$work/err" || fail "rerun of the migration failed: $(cat "$work/err")"
cat "$GH_LOG" >>"$work/first.log"
[ "$(calls copyProjectV2 "$work/first.log")" = 1 ] || fail "the template copied twice"
# Three issues and pull requests, one of them tried twice: the first try failed.
[ "$(calls addProjectV2ItemById "$work/first.log")" = 4 ] || fail "an item added twice or missing: $(calls addProjectV2ItemById "$work/first.log")"
[ "$(calls addProjectV2DraftIssue "$work/first.log")" = 1 ] || fail "the draft not added exactly once"
[ "$(calls updateProjectV2ItemFieldValue "$work/first.log")" = 10 ] || fail "field values set $(calls updateProjectV2ItemFieldValue "$work/first.log") times, expected 10"
grep -q "migrate: items: 2 to add, 2 already in the new Project" "$work/out" || fail "the rerun does not say what is left: $(cat "$work/out")"
# Every item has its values, mapped to the new options.
new=$FIX/items-PVT_MIG.json
val() { jq -r --arg c "$1" --arg f "$2" '.data.node.items.nodes[] | select((.content.id // .content.title) == $c) | .fieldValues.nodes[] | select(.field.name == $f) | (.name // .text // .number)' "$new"; }
[ "$(val ISSUE_1 Status)" = Backlog ] || fail "Todo not mapped to Backlog: $(val ISSUE_1 Status)"
[ "$(val PR_2 Status)" = "In progress" ] || fail "In Progress not mapped to In progress: $(val PR_2 Status)"
[ "$(val ISSUE_1 Priority)" = "P0 now" ] || fail "Priority lost"
[ "$(val ISSUE_1 Size)" = M ] || fail "Size lost"
[ "$(val ISSUE_1 Points)" = 3 ] || fail "number field lost"
[ "$(val ISSUE_1 'Owner notes')" = hello ] || fail "text field lost"
[ "$(val ISSUE_1 Team)" = Core ] || fail "single-select field the template lacks lost"
[ "$(val PR_2 Priority)" = Urgent ] || fail "an option the template lacks lost"
[ "$(val ISSUE_3 Status)" = Icebox ] || fail "the Status option the template lacks lost"
[ "$(val Idea Status)" = Done ] || fail "the draft lost its Status"
[ "$(jq '.data.node.items.nodes | length' "$new")" = 4 ] || fail "wrong item count in the new Project"
# The new Project is the board; the old one is closed, not deleted, with the way back.
[ "$(cfg '.project.number')/$(cfg .project.id)/$(cfg .project.owner)" = 8/PVT_MIG/acme ] || fail "new Project not recorded: $(cfg .project)"
[ "$(cfg '.project.migration')" = null ] || fail "migration state kept after the migration: $(cfg .project)"
[ "$(cfg '.project.fields.Status.id')" = F_Status ] || fail "the fields of the new Project are not cached: $(cfg .project.fields)"
grep -q '"name":"Team".*"name":"Core"' "$work/first.log" || fail "the field the template lacks not created"
grep -q '"projectId":"PVT_OLD".*"closed":true\|"closed":true.*"projectId":"PVT_OLD"' "$GH_LOG" || fail "the old Project not closed: $(cat "$GH_LOG")"
logged "deleteProjectV2" && fail "the old Project deleted"
grep -q "Project #5 closed, not deleted" "$work/out" || fail "old Project's fate not said: $(cat "$work/out")"
grep -q "gh project close 5 --owner acme --undo" "$work/out" || fail "no way to reopen the old Project: $(cat "$work/out")"
logged "project link 8 --owner acme --repo acme/app" || fail "the new Project not linked"
logged "label create" || fail "the rest of setup did not run after the migration"
# Public like the old one's repository only when it is: the repository here is private.
logged '"public":true' && fail "the new Project made public for a private repository"

# Without a Project to migrate there is nothing to do.
echo '{"language": "fr"}' >"$repo/.claude/senior-mode.json"
migrate && fail "--migrate succeeds with no Project"
grep -q "no Project to migrate" "$work/err" || fail "no explanation: $(cat "$work/err")"
(cd "$repo" && "$cli" setup github --dry-run) >/dev/null 2>&1 && fail "--dry-run accepted without --migrate"

[ "$failures" -eq 0 ] && echo "setup-github: all cases pass"
exit "$failures"
