#!/usr/bin/env bash
# Tests for `senior-mode setup github --project <number|url> [--home <owner/name>]` (#398). Offline: gh is a stub simulating
# organization Projects from files in $FIX; anything that would rewrite a field of the shared Project or touch its items
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
  "api repos/acme/web --jq"*) echo '{"owner": {"type": "Organization", "node_id": "O_acme"}, "private": true}' | respond ;;
  "api repos/acme/web/rulesets --jq"*) echo '[]' | respond ;;
  "project view "*)
    [ -f "$FIX/proj-$3.json" ] || { echo "Could not resolve to a ProjectV2 with the number $3." >&2; exit 1; }
    respond <"$FIX/proj-$3.json" ;;
  "project link "*)
    [ -z "${LINK_ERR:-}" ] || { echo "$LINK_ERR" >&2; exit 1; }
    echo "$7" >>"$FIX/linked-$(jq -r .id "$FIX/proj-$3.json")" ;;
  "api graphql"*)
    body=$(cat); echo "$body" >>"$GH_LOG"
    v=$(jq -c .variables <<<"$body")
    if grep -q createProjectV2Field <<<"$body"; then
      f=$FIX/fields-$(jq -r .project <<<"$v").json
      jq --argjson v "$v" '.data.node.fields.nodes += [{id: ("F_" + $v.name), name: $v.name}
        + (if $v.options then {options: ($v.options | map(. + {id: ("O_" + .name)}))} else {dataType: "TEXT"} end)]' "$f" >"$f.t" && mv "$f.t" "$f"
    elif grep -qE 'updateProjectV2Field|updateProjectV2\(|deleteProjectV2|addProjectV2|updateProjectV2ItemFieldValue|archiveProjectV2Item' <<<"$body"; then
      echo "FORBIDDEN $body" >>"$GH_LOG"; echo "gh: forbidden" >&2; exit 1
    elif grep -q 'repositories(first' <<<"$body"; then
      jq -R . "$FIX/linked-$(jq -r .id <<<"$v")" | jq -s '{data: {node: {repositories: {nodes: map({nameWithOwner: .})}}}}' | respond
    elif grep -q 'fields(first' <<<"$body"; then respond <"$FIX/fields-$(jq -r .id <<<"$v").json"
    fi ;;
esac
STUB
chmod +x "$work/stub/gh"
export PATH="$work/stub:$PATH" GH_LOG="$work/gh.log" FIX="$work/fix" SENIOR_MODE_RETRY_DELAY=0

repo="$work/repo"
git init -q "$repo"
git -C "$repo" remote add origin git@github.com:acme/web.git
mkdir -p "$repo/.claude" "$FIX"
cfgfile=$repo/.claude/senior-mode.json
cfg() { jq -r "$1" "$cfgfile"; }
logged() { grep -qF -- "$1" "$GH_LOG"; }
mutations() { grep -c '^{.*mutation(' "$GH_LOG"; }

opts() { jq -c --arg p "$2" 'map({id: ($p + "_" + .), name: ., color: "GRAY", description: ""})' <<<"$1"; }
fields() { # prefix status-options with-paths
  jq -n --argjson st "$(opts "$2" "$1S")" --argjson pr "$(opts '["P0 now","P1 next","P2 later","P3 someday"]' "$1P")" \
    --argjson sz "$(opts '["S","M","L"]' "$1Z")" --argjson sv "$(opts '["critical","high","moderate","low"]' "$1V")" --arg paths "$3" \
    '{data: {node: {fields: {nodes: ([{id: "F_Status", name: "Status", options: $st}, {id: "F_Priority", name: "Priority", options: $pr},
      {id: "F_Size", name: "Size", options: $sz}, {id: "F_Severity", name: "Severity", options: $sv}]
      + (if $paths == "yes" then [{id: "F_Paths", name: "Paths", dataType: "TEXT"}] else [] end))}}}}'
}
FULL='["Backlog","Ready","In progress","In review","Done"]'
# Project 7 "product": complete, linked to two other repositories, with their items. Project 8 "mobile": same.
# Project 6 "gaps": no Paths, a Status without In review.
proj() { echo "{\"id\": \"PVT_$1\", \"title\": \"$2\"}" >"$FIX/proj-$1.json"; }
reset() {
  rm -f "$FIX"/*
  proj 7 product; proj 8 mobile; proj 6 gaps
  fields N "$FULL" yes >"$FIX/fields-PVT_7.json"
  cp "$FIX/fields-PVT_7.json" "$FIX/fields-PVT_8.json"
  fields G '["Backlog","Ready","In progress","Done"]' no >"$FIX/fields-PVT_6.json"
  for n in 6 7 8; do printf 'acme/api\nacme/mobile\n' >"$FIX/linked-PVT_$n"; done
  echo '{}' >"$cfgfile"
  : >"$GH_LOG"
}
attach() { (cd "$repo" && "$cli" setup github "$@") >"$work/out" 2>"$work/err"; }

# --dry-run: the fields, the link and the config are said, nothing is written, linked or created.
reset
attach --project 7 --dry-run || fail "dry run failed: $(cat "$work/err")"
for want in "Project #7 product of acme: acme/web is attached to it, home acme/api" "fields: Status, Priority, Size, Severity and Paths" \
  "link: would link acme/web to Project #7" "config: would write project owner acme, number 7, id PVT_7, home acme/api"; do
  grep -qF -- "$want" "$work/out" || fail "dry run without '$want': $(cat "$work/out")"
done
[ "$(mutations)" = 0 ] || fail "dry run mutated GitHub"
logged "project link" && fail "dry run linked the repository"
[ "$(cat "$cfgfile")" = '{}' ] || fail "dry run wrote the config: $(cat "$cfgfile")"

# The attachment: linked, the config names Project 7 and its home, nothing of the others' items is touched.
attach --project 7 || fail "attach failed: $(cat "$work/err")"
logged "project link 7 --owner acme --repo acme/web" || fail "Project 7 not linked: $(cat "$GH_LOG")"
[ "$(cfg '.project.number')/$(cfg .project.id)/$(cfg .project.owner)" = 7/PVT_7/acme ] || fail "Project 7 not recorded: $(cfg .project)"
[ "$(cfg .project.home)" = acme/api ] || fail "home is not the first linked repository: $(cfg .project)"
[ "$(cfg '.project.fields.Paths.id')" = F_Paths ] && [ "$(cfg '.project.fields.Status.options["In review"]')" = NS_In\ review ] ||
  fail "the fields of Project 7 not cached: $(cfg .project)"
logged FORBIDDEN && fail "a field or an item of the shared Project was rewritten: $(grep FORBIDDEN "$GH_LOG")"
[ "$(mutations)" = 0 ] || fail "a complete Project needed no mutation: $(grep '^{.*mutation(' "$GH_LOG")"
[ "$(wc -l <"$FIX/linked-PVT_7")" = 3 ] || fail "the other repositories' links changed: $(cat "$FIX/linked-PVT_7")"
grep -q "labels:" "$work/out" || fail "the repository steps did not run: $(cat "$work/out")"

# A second run changes nothing.
cp "$cfgfile" "$work/before"
: >"$GH_LOG"
attach --project 7 || fail "second run failed: $(cat "$work/err")"
[ "$(mutations)" = 0 ] || fail "second run mutated GitHub"
logged "project link" && fail "second run linked again"
cmp -s "$work/before" "$cfgfile" || fail "second run changed the config: $(cat "$cfgfile")"
grep -q "already linked" "$work/out" || fail "second run does not say it is linked: $(cat "$work/out")"

# Paths missing and a Status without In review: Paths is created, the option is reported, no option changes.
reset
cp "$FIX/fields-PVT_6.json" "$work/fields-before"
attach --project 6 || fail "attach to Project 6 failed: $(cat "$work/err")"
jq -e '.data.node.fields.nodes[] | select(.name == "Paths")' "$FIX/fields-PVT_6.json" >/dev/null || fail "Paths not created"
[ "$(mutations)" = 1 ] || fail "only Paths should be created: $(grep '^{.*mutation(' "$GH_LOG")"
grep -q "field Paths: created" "$work/out" || fail "Paths creation not said: $(cat "$work/out")"
grep -q "field Status: the option In review is missing.*Project, Settings, field Status" "$work/out" || fail "the missing option is not reported with where to add it: $(cat "$work/out")"
[ "$(jq -c '[.data.node.fields.nodes[] | select(.options) | .options]' "$FIX/fields-PVT_6.json")" = "$(jq -c '[.data.node.fields.nodes[] | select(.options) | .options]' "$work/fields-before")" ] ||
  fail "an existing option changed"
logged updateProjectV2Field && fail "a field was rewritten"
# A dry run says what it would create and creates nothing.
reset
attach --project 6 --dry-run || fail "dry run on Project 6 failed: $(cat "$work/err")"
grep -q "field Paths: would be created" "$work/out" || fail "the dry run does not name Paths: $(cat "$work/out")"
[ "$(mutations)" = 0 ] || fail "dry run created a field"

# A Project of another owner is refused, naming both owners; nothing is linked.
reset
attach --project https://github.com/orgs/other/projects/7 && fail "a Project of another owner was accepted"
{ grep -q "belongs to other" "$work/err" && grep -q "acme/web belongs to acme" "$work/err"; } || fail "both owners not named: $(cat "$work/err")"
logged "project link" && fail "linked to a Project of another owner"
[ "$(cat "$cfgfile")" = '{}' ] || fail "a refused Project was recorded"
attach --project https://github.com/orgs/acme/projects/7 || fail "the URL of the owner's Project refused: $(cat "$work/err")"
[ "$(cfg .project.number)" = 7 ] || fail "the URL was not read: $(cfg .project)"
attach --project 99 && fail "an unknown Project was accepted"
grep -q "cannot read Project #99 of acme" "$work/err" || fail "unknown Project not named: $(cat "$work/err")"

# The home: --home, else the repository named like the Project's title, else the first linked.
reset
attach --project 7 --home acme/mobile || fail "attach with --home failed: $(cat "$work/err")"
[ "$(cfg .project.home)" = acme/mobile ] || fail "--home not written: $(cfg .project)"
reset
attach --project 8 || fail "attach to Project 8 failed: $(cat "$work/err")"
[ "$(cfg .project.home)" = acme/mobile ] || fail "the repository named like the Project is not the home: $(cfg .project)"
reset
printf 'acme/zeta\nacme/api\n' >"$FIX/linked-PVT_7"
attach --project 7 || fail "attach failed: $(cat "$work/err")"
[ "$(cfg .project.home)" = acme/zeta ] || fail "home is not the first linked: $(cfg .project)"
attach --project 7 --home other/x && fail "--home of another owner accepted"
attach --project 7 --home nonsense && fail "a malformed --home accepted"
attach --home acme/api && fail "--home without --project accepted"

# Without --project, setup github has no attach step and the usage line names the options.
reset
(cd "$repo" && "$cli" setup github --dry-run) >"$work/out" 2>&1 || fail "plain dry run failed: $(cat "$work/out")"
grep -q "^Project: found, or copied from the template" "$work/out" || fail "plain dry run changed: $(cat "$work/out")"
grep -q "attached" "$work/out" && fail "plain dry run attaches"
"$cli" nonsense 2>&1 | grep -qF -- '[--project <n|url> [--home <owner/name>] [--move-items]]' || fail "usage line without --project and --home"

[ "$failures" = 0 ] || { echo "$failures failure(s)"; exit 1; }
echo "ok"
