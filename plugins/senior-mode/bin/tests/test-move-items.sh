#!/usr/bin/env bash
# Tests for `senior-mode setup github --project <n> --move-items` (#723). Offline: gh is a stub simulating two
# Projects from files in $FIX; any call that would rewrite a field of the shared Project or close or delete a Project
# is logged as FORBIDDEN.
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
case "$*" in
  "api repos/acme/app --jq"*) echo '{"owner": {"type": "User", "node_id": "U_acme"}, "private": true}' | respond ;;
  "project view 7 --owner acme"*) echo '{"id": "PVT_NEW"}' | respond ;;
  "project view"*) echo "Could not resolve to a ProjectV2 with the number $3." >&2; exit 1 ;;
  "project link"* | "project unlink"*) ;;
  "project close"* | "project delete"*) echo "FORBIDDEN $*" >>"$GH_LOG" ;;
  "api graphql"*)
    body=$(cat); echo "$body" >>"$GH_LOG"
    v=$(jq -c .variables <<<"$body")
    if grep -qE 'createProjectV2Field|updateProjectV2Field|updateProjectV2\(|deleteProjectV2' <<<"$body"; then
      echo "FORBIDDEN $body" >>"$GH_LOG"; echo "gh: forbidden" >&2; exit 1
    elif grep -q 'addProjectV2DraftIssue' <<<"$body"; then
      f=$FIX/items-$(jq -r .p <<<"$v").json
      id=I_new$(jq '.data.node.items.nodes | length + 1' "$f")
      jq --argjson v "$v" --arg id "$id" '.data.node.items.nodes += [{id: $id, content: {__typename: "DraftIssue", title: $v.t, body: $v.b}, fieldValues: {nodes: []}}]' "$f" >"$f.t" && mv "$f.t" "$f"
      jq -nc --arg id "$id" '{data: {addProjectV2DraftIssue: {projectItem: {id: $id}}}}' | respond
    elif grep -q 'addProjectV2ItemById' <<<"$body"; then
      f=$FIX/items-$(jq -r .p <<<"$v").json
      id=I_new$(jq '.data.node.items.nodes | length + 1' "$f")
      jq --argjson v "$v" --arg id "$id" '.data.node.items.nodes += [{id: $id, content: {__typename: "Issue", id: $v.c}, fieldValues: {nodes: []}}]' "$f" >"$f.t" && mv "$f.t" "$f"
      jq -nc --arg id "$id" '{data: {addProjectV2ItemById: {item: {id: $id}}}}' | respond
    elif grep -q 'updateProjectV2ItemFieldValue' <<<"$body"; then
      f=$FIX/items-$(jq -r .p <<<"$v").json
      jq --argjson v "$v" --slurpfile fl "$FIX/fields-$(jq -r .p <<<"$v").json" '($fl[0].data.node.fields.nodes | map(select(.id == $v.f))[0]) as $fd
        | (.data.node.items.nodes[] | select(.id == $v.i) | .fieldValues.nodes) += [{field: {name: $fd.name}}
          + (if $v.v.singleSelectOptionId then {name: ($fd.options | map(select(.id == $v.v.singleSelectOptionId))[0].name)} else $v.v end)]' "$f" >"$f.t" && mv "$f.t" "$f"
    elif grep -q 'items(first' <<<"$body"; then respond <"$FIX/items-$(jq -r .id <<<"$v").json"
    else respond <"$FIX/fields-$(jq -r .id <<<"$v").json"; fi ;;
esac
STUB
chmod +x "$work/stub/gh"
export PATH="$work/stub:$PATH" GH_LOG="$work/gh.log" FIX="$work/fix" SENIOR_MODE_RETRY_DELAY=0

repo="$work/repo"
git init -q "$repo"
git -C "$repo" remote add origin git@github.com:acme/app.git
mkdir -p "$repo/.claude" "$FIX"
cfgfile=$repo/.claude/senior-mode.json
cfg() { jq -r "$1" "$cfgfile"; }
logged() { grep -qF -- "$1" "$GH_LOG"; }
mutations() { grep -c '^{.*mutation(' "$GH_LOG"; }

opts() { jq -c --arg p "$2" 'map({id: ($p + "_" + .), name: ., color: "GRAY", description: ""})' <<<"$1"; }
fields() { # prefix status-options
  jq -n --argjson st "$(opts "$2" "$1S")" --argjson pr "$(opts '["P0 now","P1 next"]' "$1P")" --argjson sz "$(opts '["S","M","L"]' "$1Z")" \
    '{data: {node: {fields: {nodes: [{id: "F_Status", name: "Status", options: $st}, {id: "F_Priority", name: "Priority", options: $pr},
      {id: "F_Size", name: "Size", options: $sz}, {id: "F_Paths", name: "Paths", dataType: "TEXT"}]}}}}'
}
fields OLD '["Todo","In Progress","Done","Icebox"]' >"$FIX/fields-PVT_OLD.json"
fields NEW '["Backlog","Ready","In progress","In review","Done"]' >"$FIX/fields-PVT_NEW.json"
sel() { jq -nc --arg f "$1" --arg n "$2" '{name: $n, field: {name: $f}}'; }
txt() { jq -nc --arg f "$1" --arg t "$2" '{text: $t, field: {name: $f}}'; }
item() { jq -nc --arg id "$1" --argjson c "$2" --argjson v "$3" '{id: $id, content: $c, fieldValues: {nodes: $v}}'; }
reset() {
  jq -n --argjson a "$(item OI_1 '{"__typename":"Issue","id":"ISSUE_1","number":11}' "[$(sel Status Todo), $(sel Priority "P0 now"), $(sel Size M), $(txt Paths "a.sh,b.sh")]")" \
    --argjson b "$(item OI_2 '{"__typename":"PullRequest","id":"PR_2","number":12}' "[$(sel Status "In Progress"), $(txt Paths "c.sh")]")" \
    --argjson c "$(item OI_3 '{"__typename":"Issue","id":"ISSUE_3","number":13}' "[$(sel Status Icebox), $(sel Size S)]")" \
    --argjson d "$(item OI_4 '{"__typename":"DraftIssue","title":"Idea","body":"b"}' "[$(sel Status Done)]")" \
    '{data: {node: {title: "app", public: false, items: {pageInfo: {hasNextPage: false}, nodes: [$a, $b, $c, $d]}}}}' >"$FIX/items-PVT_OLD.json"
  # Another repository's item is already on the shared Project.
  jq -n --argjson a "$(item NI_1 '{"__typename":"Issue","id":"OTHER_1","number":3}' "[$(sel Status Ready), $(sel Priority "P1 next")]")" \
    '{data: {node: {title: "product", public: true, items: {pageInfo: {hasNextPage: false}, nodes: [$a]}}}}' >"$FIX/items-PVT_NEW.json"
  echo '{"project": {"owner": "acme", "number": 5, "id": "PVT_OLD", "fields": {"Status": {"id": "F_Status"}}}}' >"$cfgfile"
  : >"$GH_LOG"
}
move() { (cd "$repo" && "$cli" setup github "$@") >"$work/out" 2>"$work/err"; }
new_val() { jq -r --arg c "$1" --arg f "$2" '.data.node.items.nodes[] | select((.content.id // .content.title) == $c) | .fieldValues.nodes[] | select(.field.name == $f) | (.name // .text)' "$FIX/items-PVT_NEW.json"; }

# --dry-run: the mapping is printed, nothing is written, linked or unlinked.
reset
cp "$cfgfile" "$work/before"
cp "$FIX/items-PVT_NEW.json" "$work/items-before"
move --project 7 --move-items --dry-run || fail "dry run failed: $(cat "$work/err")"
[ "$(mutations)" = 0 ] || fail "dry run mutated GitHub: $(grep '^{.*mutation(' "$GH_LOG")"
logged "project link" && fail "dry run linked a Project"
logged "project unlink" && fail "dry run unlinked a Project"
cmp -s "$work/before" "$cfgfile" || fail "dry run wrote the config: $(cat "$cfgfile")"
cmp -s "$work/items-before" "$FIX/items-PVT_NEW.json" || fail "dry run changed the shared Project"
for want in "move: Project #5 -> Project #7" "move: items: 4 to add, 0 already on Project #7" \
  "move: values mapped: Status Todo -> Backlog, Status In Progress -> In progress" \
  "move: #13 Status Icebox: no such option on Project #7, left unmapped" "dry run, nothing changed"; do
  grep -qF -- "$want" "$work/out" || fail "dry run without '$want': $(cat "$work/out")"
done

# The move: items with the same values, the old Project unlinked and kept.
move --project 7 --move-items || fail "move failed: $(cat "$work/err")"
[ "$(jq '.data.node.items.nodes | length' "$FIX/items-PVT_NEW.json")" = 5 ] || fail "wrong item count on Project 7"
[ "$(new_val ISSUE_1 Status)" = Backlog ] || fail "Todo not mapped to Backlog: $(new_val ISSUE_1 Status)"
[ "$(new_val PR_2 Status)" = "In progress" ] || fail "In Progress not mapped: $(new_val PR_2 Status)"
[ "$(new_val Idea Status)" = Done ] || fail "the draft lost its Status"
[ "$(new_val ISSUE_1 Priority)" = "P0 now" ] || fail "Priority lost"
[ "$(new_val ISSUE_1 Size)" = M ] || fail "Size lost"
[ "$(new_val ISSUE_1 Paths)" = "a.sh,b.sh" ] || fail "Paths lost"
[ "$(new_val PR_2 Paths)" = c.sh ] || fail "Paths of the pull request lost"
logged "project link 7 --owner acme --repo acme/app" || fail "Project 7 not linked"
logged "project unlink 5 --owner acme --repo acme/app" || fail "the old Project not unlinked"
logged FORBIDDEN && fail "the old Project closed or deleted, or a field of the shared Project rewritten: $(grep FORBIDDEN "$GH_LOG")"
grep -q "Project #5, which is kept" "$work/out" || fail "the old Project's fate not said: $(cat "$work/out")"
[ "$(cfg '.project.number')/$(cfg .project.id)/$(cfg .project.owner)" = 7/PVT_NEW/acme ] || fail "Project 7 not recorded: $(cfg .project)"
[ "$(cfg '.project.fields.Status.id')" = F_Status ] || fail "the fields of Project 7 not cached: $(cfg .project)"
# Another repository's item on Project 7 is untouched.
[ "$(jq -c '.data.node.items.nodes[0]' "$FIX/items-PVT_NEW.json")" = "$(item NI_1 '{"__typename":"Issue","id":"OTHER_1","number":3}' "[$(sel Status Ready), $(sel Priority "P1 next")]")" ] ||
  fail "an item of another repository changed"

# A Status option the shared Project lacks: reported, the item moved, the value left unmapped, the field untouched.
grep -qF "move: #13 Status Icebox: no such option on Project #7, left unmapped" "$work/out" || fail "Icebox not reported: $(cat "$work/out")"
[ -z "$(new_val ISSUE_3 Status)" ] || fail "an option the shared Project lacks was mapped: $(new_val ISSUE_3 Status)"
[ "$(new_val ISSUE_3 Size)" = S ] || fail "the other values of the unmapped item lost"
[ "$(jq '.data.node.fields.nodes[0].options | length' "$FIX/fields-PVT_NEW.json")" = 5 ] || fail "the Status field of Project 7 was rewritten"

# A second run changes nothing.
cp "$cfgfile" "$work/before"
cp "$FIX/items-PVT_NEW.json" "$work/items-before"
: >"$GH_LOG"
move --project 7 --move-items || fail "second run failed: $(cat "$work/err")"
[ "$(mutations)" = 0 ] || fail "second run mutated GitHub"
logged "project link" && fail "second run linked again"
logged "project unlink" && fail "second run unlinked again"
cmp -s "$work/before" "$cfgfile" || fail "second run wrote the config"
cmp -s "$work/items-before" "$FIX/items-PVT_NEW.json" || fail "second run changed Project 7"
grep -q "already on Project #7" "$work/out" || fail "second run says nothing: $(cat "$work/out")"

# A run interrupted before the config was written: the rerun adds no item twice.
echo '{"project": {"owner": "acme", "number": 5, "id": "PVT_OLD"}}' >"$cfgfile"
cp "$FIX/items-PVT_NEW.json" "$work/items-before"
: >"$GH_LOG"
move --project 7 --move-items || fail "rerun failed: $(cat "$work/err")"
[ "$(mutations)" = 0 ] || fail "the rerun added or set something again: $(grep '^{.*mutation(' "$GH_LOG")"
cmp -s "$work/items-before" "$FIX/items-PVT_NEW.json" || fail "the rerun changed Project 7"
[ "$(cfg .project.number)" = 7 ] || fail "the rerun did not record Project 7"

# Without --move-items, --project touches nothing; --move-items alone is a usage error.
reset
move --project 7 && fail "--project alone succeeded"
grep -q "move-items" "$work/err" || fail "--project alone does not name --move-items: $(cat "$work/err")"
logged "project unlink" && fail "the old Project unlinked without --move-items"
[ "$(mutations)" = 0 ] || fail "--project alone mutated GitHub"
[ "$(cfg .project.number)" = 5 ] || fail "--project alone wrote the config"
move --move-items && fail "--move-items without --project succeeded"
grep -q "usage:" "$work/err" || fail "no usage for --move-items alone: $(cat "$work/err")"
move --project 7 --move-items --migrate && fail "--move-items accepted with --migrate"

[ "$failures" = 0 ] || { echo "$failures failure(s)"; exit 1; }
echo "ok"
