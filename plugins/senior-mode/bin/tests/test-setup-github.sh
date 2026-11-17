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
plan_limit() {
  [ -z "${PROTECTION_403:-}" ] || { echo "HTTP 403: Upgrade to GitHub Pro or make this repository public to enable this feature." >&2; exit 1; }
}
case "$*" in
  "api repos/acme/app --jq"*) respond <"$FIX/repo.json" ;;
  "api repos/acme/app/rulesets --jq"*) plan_limit
    if [ -f "$FIX/rulesets.json" ]; then respond <"$FIX/rulesets.json"; else echo '[]' | respond; fi ;;
  "api -X POST repos/acme/app/rulesets"*) plan_limit; cat >>"$GH_LOG"
    echo '[{"id": 9, "name": "senior-mode", "source_type": "Repository"}]' >"$FIX/rulesets.json" ;;
  "api -X PUT repos/acme/app/rulesets/"*) cat >>"$GH_LOG" ;;
  "workflow list"*) if [ -f "$FIX/workflows.json" ]; then respond <"$FIX/workflows.json"; else echo '[]' | respond; fi ;;
  "workflow disable"* | "workflow enable"*) ;;
  "project view"*)
    [ -z "${VIEW_ERR:-}" ] || { echo "$VIEW_ERR" >&2; exit 1; }
    jq -e --argjson n "$3" '.number == $n' "$FIX/project.json" >/dev/null 2>&1 ||
      { echo "Could not resolve to a ProjectV2 with the number $3." >&2; exit 1; }
    respond <"$FIX/project.json" ;;
  "project list"*) [ -z "${LIST_ERR:-}" ] || { echo "$LIST_ERR" >&2; exit 1; }
    respond <"$FIX/projects.json" ;;
  "project link"*) [ -z "${LINK_ERR:-}" ] || { echo "$LINK_ERR" >&2; exit 1; } ;;
  "project create"*) echo '{"number":7,"id":"PVT_NEW","title":"app"}' | tee "$FIX/project.json" | respond ;;
  "api graphql"*)
    body=$(cat); echo "$body" >>"$GH_LOG"
    v=$(jq -c .variables <<<"$body")
    if grep -q createProjectV2Field <<<"$body"; then
      jq --argjson v "$v" '.data.node.fields.nodes += [{id: ("F_" + $v.name), name: $v.name,
        options: ($v.options | map(. + {id: ("O_" + .name)}))}]' "$FIX/fields.json" >"$FIX/f" &&
        mv "$FIX/f" "$FIX/fields.json"
    elif grep -q updateProjectV2Field <<<"$body"; then
      jq --argjson v "$v" '(.data.node.fields.nodes[] | select(.id == $v.field)
        | .options) = ($v.options | map(.id //= ("O_" + .name)))' "$FIX/fields.json" >"$FIX/f" &&
        mv "$FIX/f" "$FIX/fields.json"
    else respond <"$FIX/fields.json"; fi ;;
esac
STUB
chmod +x "$work/stub/gh"
export PATH="$work/stub:$PATH" GH_LOG="$work/gh.log" FIX="$work/fix" SENIOR_MODE_RETRY_DELAY=0

repo="$work/repo"
git init -q "$repo"
git -C "$repo" remote add origin git@github.com:acme/app.git
mkdir -p "$repo/.claude" "$FIX"
echo '{"language": "fr"}' >"$repo/.claude/senior-mode.json"
echo '{"owner": {"type": "User"}}' >"$FIX/repo.json"
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
status_field() {
  jq --argjson o "$1" '(.data.node.fields.nodes[] | select(.name == "Status") | .options) = $o' \
    "$FIX/fields.json" >"$FIX/f" && mv "$FIX/f" "$FIX/fields.json"
}

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
logged '"name":"P0 now","color":"RED"' || fail "created fields without their colours"
for label in needs-human needs-info blocked type:feature type:bug type:task type:chore; do
  logged "label create $label" || fail "label $label not created"
done
logged "--enable-rebase-merge --enable-merge-commit=false --enable-squash-merge=false --delete-branch-on-merge" ||
  fail "merge settings not set"
logged "api -X POST repos/acme/app/rulesets" || fail "no ruleset created"
for rule in '"include":["~DEFAULT_BRANCH"]' '{"context":"senior-mode/ci"},{"context":"senior-mode/review"}' \
  '"strict_required_status_checks_policy":true' '{"type":"required_linear_history"}' '"bypass_mode":"always"' \
  '"allowed_merge_methods":["rebase"]'; do
  tr -d ' \n' <"$GH_LOG" | grep -qF -- "$rule" || fail "ruleset without $rule"
done
logged "/protection" && fail "classic branch protection rewritten"

# Running it again changes nothing that exists.
before=$(cat "$repo/.claude/senior-mode.json")
setup
logged "project create" && fail "second run creates a Project"
logged "createProjectV2Field" && fail "second run creates a field"
logged "updateProjectV2Field" && fail "second run rewrites field options"
logged "api -X POST repos/acme/app/rulesets" && fail "second run creates another ruleset"
logged "api -X PUT repos/acme/app/rulesets/9" || fail "second run does not update the ruleset"
[ "$(cat "$repo/.claude/senior-mode.json")" = "$before" ] || fail "second run changes the config"

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
logged "project create" && fail "creates a Project after a view error"
logged "project list" && fail "looks the Project up by title after a view error"

# A cached Project that no longer exists falls back to the one with the repository's title, in an organization.
echo '{"language": "fr", "project": {"number": 99}}' >"$repo/.claude/senior-mode.json"
echo '{"projects": [{"number": 5, "title": "app"}]}' >"$FIX/projects.json"
echo '{"number": 5, "id": "PVT_5"}' >"$FIX/project.json"
jq '(.data.node.fields.nodes[] | select(.name == "Status") | .options) += [{"id": "O_ice", "name": "Icebox", "color": "BLUE", "description": ""}]' \
  "$FIX/fields.json" >"$FIX/f" && mv "$FIX/f" "$FIX/fields.json"
echo '{"owner": {"type": "Organization"}}' >"$FIX/repo.json"
setup
logged "project create" && fail "creates a Project although one has the repository's title"
[ "$(cfg .project.number)" = 5 ] || fail "Project found by title not used: $(cfg .project.number)"
[ "$(cfg '.project.fields.Status.options.Icebox')" = O_ice ] || fail "a Project's own option was dropped"
logged "label create type:" && fail "type labels in an organization (issue types instead)"

# A failing Project command stops setup: no duplicate Project, no empty id cached.
failing() {
  : >"$GH_LOG"
  cp "$repo/.claude/senior-mode.json" "$work/before"
  (cd "$repo" && env "$1=HTTP 401: Bad credentials" "$cli" setup github) >"$work/out" 2>"$work/err" &&
    fail "$1: setup succeeds although a Project command failed"
  logged "project create" && fail "$1: creates a Project after the failure"
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
(cd "$repo" && "$cli" setup github --ci actions) >"$work/out" 2>"$work/err" || fail "setup --ci actions failed: $(cat "$work/err")"
[ "$(cfg .ci.mode)" = actions ] || fail "--ci actions not stored: $(cfg .ci)"
logged "workflow disable" && fail "workflows disabled in actions mode"
logged "workflow enable 14 --repo acme/app" || fail "a disabled senior-mode workflow stays off in actions mode"
setup
logged "workflow disable" && fail "a rerun without --ci forgets the stored mode"
(cd "$repo" && "$cli" setup github --ci cloud) >/dev/null 2>&1 && fail "an unknown ci mode is accepted"

# Rulesets unavailable on the plan.
rm "$FIX/rulesets.json"
PROTECTION_403=1 setup
grep -qi "not available" "$work/out" || fail "plan limit not reported: $(cat "$work/out")"

[ "$failures" -eq 0 ] && echo "setup-github: all cases pass"
exit "$failures"
