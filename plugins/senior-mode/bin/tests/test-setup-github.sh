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
case "$*" in
  "api repos/acme/app --jq"*) respond <"$FIX/repo.json" ;;
  "project view"*) [ -f "$FIX/project.json" ] || { echo "Could not resolve to a ProjectV2" >&2; exit 1; }
    respond <"$FIX/project.json" ;;
  "project list"*) respond <"$FIX/projects.json" ;;
  "project create"*) echo '{"number":7,"id":"PVT_NEW","title":"app"}' | tee "$FIX/project.json" | respond ;;
  "project field-create"*)
    name=$(sed -E 's/.*--name ([A-Za-z]+).*/\1/' <<<"$*")
    opts=$(sed -E 's/.*--single-select-options ([^-]+[^ ]).*/\1/' <<<"$*")
    jq --arg n "$name" --arg o "$opts" '.data.node.fields.nodes += [{id: ("F_" + $n), name: $n,
      options: ($o | split(",") | map({id: ("O_" + .), name: ., color: "GRAY", description: ""}))}]' \
      "$FIX/fields.json" >"$FIX/f" && mv "$FIX/f" "$FIX/fields.json" ;;
  "api graphql"*)
    body=$(cat); echo "$body" >>"$GH_LOG"
    if grep -q mutation <<<"$body"; then
      jq --argjson v "$(jq .variables <<<"$body")" '(.data.node.fields.nodes[] | select(.id == $v.field)
        | .options) = ($v.options | map(.id //= ("O_" + .name)))' "$FIX/fields.json" >"$FIX/f" &&
        mv "$FIX/f" "$FIX/fields.json"
    else respond <"$FIX/fields.json"; fi ;;
  "api -X PUT"*) cat >>"$GH_LOG"
    [ -z "${PROTECTION_403:-}" ] || { echo "HTTP 403: Upgrade to GitHub Pro or make this repository public to enable this feature." >&2; exit 1; } ;;
esac
STUB
chmod +x "$work/stub/gh"
export PATH="$work/stub:$PATH" GH_LOG="$work/gh.log" FIX="$work/fix" SENIOR_MODE_RETRY_DELAY=0

repo="$work/repo"
git init -q "$repo"
git -C "$repo" remote add origin git@github.com:acme/app.git
mkdir -p "$repo/.claude" "$FIX"
echo '{"language": "fr"}' >"$repo/.claude/senior-mode.json"
echo '{"owner": {"type": "User"}, "default_branch": "main"}' >"$FIX/repo.json"
echo '{"projects": [{"number": 2, "title": "other"}]}' >"$FIX/projects.json"
echo '{"data": {"node": {"fields": {"nodes": [{}, {"id": "F_Status", "name": "Status", "options": [
  {"id": "O_todo", "name": "Todo", "color": "GRAY", "description": ""},
  {"id": "O_prog", "name": "In Progress", "color": "YELLOW", "description": ""},
  {"id": "O_done", "name": "Done", "color": "PURPLE", "description": "Shipped"}]}]}}}}' >"$FIX/fields.json"

setup() {
  : >"$GH_LOG"
  (cd "$repo" && "$cli" setup github) >"$work/out" 2>"$work/err" || fail "setup exited non-zero: $(cat "$work/err")"
}
cfg() { jq -r "$1" "$repo/.claude/senior-mode.json"; }
logged() { grep -qF -- "$1" "$GH_LOG"; }

# A repository without senior-mode.
setup
logged "project create --owner acme --title app" || fail "no Project created"
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
for label in needs-human needs-info blocked type:feature type:bug type:task type:chore; do
  logged "label create $label" || fail "label $label not created"
done
logged "--enable-rebase-merge --enable-merge-commit=false --enable-squash-merge=false --delete-branch-on-merge" ||
  fail "merge settings not set"
logged "api -X PUT repos/acme/app/branches/main/protection" || fail "no branch protection"
logged '"contexts":["senior-mode/ci","senior-mode/review"]' || fail "protection does not require both statuses"
logged '"required_linear_history":true' || fail "protection without linear history"
logged '"enforce_admins":false' || fail "admins cannot override explicitly"

# Running it again changes nothing that exists.
before=$(cat "$repo/.claude/senior-mode.json")
setup
logged "project create" && fail "second run creates a Project"
logged "field-create" && fail "second run creates a field"
logged "mutation" && fail "second run rewrites field options"
[ "$(cat "$repo/.claude/senior-mode.json")" = "$before" ] || fail "second run changes the config"

# A Project with an option of its own, found by title, in an organization.
rm "$FIX/project.json"
echo '{"language": "fr"}' >"$repo/.claude/senior-mode.json"
echo '{"projects": [{"number": 5, "title": "app"}]}' >"$FIX/projects.json"
echo '{"number": 5, "id": "PVT_5"}' >"$FIX/project.json"
jq '(.data.node.fields.nodes[] | select(.name == "Status") | .options) += [{"id": "O_ice", "name": "Icebox", "color": "BLUE", "description": ""}]' \
  "$FIX/fields.json" >"$FIX/f" && mv "$FIX/f" "$FIX/fields.json"
echo '{"owner": {"type": "Organization"}, "default_branch": "trunk"}' >"$FIX/repo.json"
setup
logged "project create" && fail "creates a Project although one has the repository's title"
[ "$(cfg .project.number)" = 5 ] || fail "Project found by title not used: $(cfg .project.number)"
[ "$(cfg '.project.fields.Status.options.Icebox')" = O_ice ] || fail "a Project's own option was dropped"
logged "label create type:" && fail "type labels in an organization (issue types instead)"
logged "branches/trunk/protection" || fail "protection not on the default branch"

# Branch protection unavailable on the plan.
PROTECTION_403=1 setup
grep -qi "not available" "$work/out" || fail "plan limit not reported: $(cat "$work/out")"

[ "$failures" -eq 0 ] && echo "setup-github: all cases pass"
exit "$failures"
