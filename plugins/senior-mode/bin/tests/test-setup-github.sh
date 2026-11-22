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
  "api repos/acme/app/rulesets/"*" --jq"*) respond <"$FIX/ruleset-9.json" ;;
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
    elif grep -q workflows <<<"$body"; then respond <"$FIX/workflows-project.json"
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
echo '{"rules": []}' >"$FIX/ruleset-9.json"
echo '{"projects": [{"number": 2, "title": "other"}]}' >"$FIX/projects.json"
echo '{"data": {"node": {"fields": {"nodes": [{}, {"id": "F_Status", "name": "Status", "options": [
  {"id": "O_todo", "name": "Todo", "color": "GRAY", "description": ""},
  {"id": "O_prog", "name": "In Progress", "color": "YELLOW", "description": ""},
  {"id": "O_done", "name": "Done", "color": "PURPLE", "description": "Shipped"}]}]}}}}' >"$FIX/fields.json"
project_workflows() { # enabled flags of "Item closed" and "Pull request merged"
  jq -n --argjson c "$1" --argjson m "$2" '{data: {node: {workflows: {nodes: [
    {name: "Item closed", enabled: $c}, {name: "Pull request merged", enabled: $m},
    {name: "Auto-add to project", enabled: false}]}}}}' >"$FIX/workflows-project.json"
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
[ "$(cfg '.project.fields.Severity.options | keys_unsorted | join(",")')" = "critical,high,moderate,low" ] ||
  fail "Severity: $(cfg .project.fields.Severity)"
logged '"name":"critical","color":"RED"' || fail "Severity created without its colours"
logged '"name":"P0 now","color":"RED"' || fail "created fields without their colours"
for label in needs-human needs-info blocked security type:feature type:bug type:task type:chore; do
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

# Running it again changes nothing that exists.
before=$(cat "$repo/.claude/senior-mode.json")
setup
logged "project create" && fail "second run creates a Project"
logged "createProjectV2Field" && fail "second run creates a field"
logged "updateProjectV2Field" && fail "second run rewrites field options"
logged "api -X POST repos/acme/app/rulesets" && fail "second run creates another ruleset"
logged "api -X PUT repos/acme/app/rulesets/9" || fail "second run does not update the ruleset"
[ "$(cat "$repo/.claude/senior-mode.json")" = "$before" ] || fail "second run changes the config"

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
echo '{"owner": {"type": "User"}}' >"$FIX/repo.json"
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

# An organization has no user to own the file: the owner is the signed-in user.
rm "$co"
echo '{"owner": {"type": "Organization"}}' >"$FIX/repo.json"
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
  review_required && fail "$shadow: code owner review required although no CODEOWNERS owns the zones"
  grep -q "code owner review is not required" "$work/out" || fail "$shadow: no word that review is not required: $(cat "$work/out")"
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

[ "$failures" -eq 0 ] && echo "setup-github: all cases pass"
exit "$failures"
