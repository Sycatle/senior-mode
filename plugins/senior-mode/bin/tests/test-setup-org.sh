#!/usr/bin/env bash
# Tests for `senior-mode setup org` (#401) and the organization template of `setup github`. Offline: gh is a stub
# keeping an organization's Projects and its `.github` repository in $FIX; a write to the default branch or to an
# organization ruleset is logged as FORBIDDEN.
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
notfound() { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
case "$*" in
  "auth status"*) echo "  - Token scopes: ${SCOPES:-'gist', 'project', 'repo'}" ;;
  "api users/acme --jq"*) echo '{"type": "Organization", "node_id": "O_acme"}' | respond ;;
  "api users/jdoe --jq"*) echo '{"type": "User", "node_id": "U_jdoe"}' | respond ;;
  "api repos/acme/app --jq"*) echo '{"owner": {"type": "Organization", "node_id": "O_acme"}, "private": true}' | respond ;;
  "api repos/acme/.github --jq"*) [ -f "$FIX/org-repo" ] || notfound; echo '{"default_branch": "main"}' | respond ;;
  "api repos/acme/.github/contents/senior-mode/config.json"*)
    [ -f "$FIX/org-config.json" ] || notfound
    jq -nc --arg c "$(base64 <"$FIX/org-config.json")" '{content: $c, sha: "BLOB1"}' | respond ;;
  "api repos/acme/.github/git/ref/heads/chore/senior-mode-org"*) [ -f "$FIX/branch" ] || notfound ;;
  "api repos/acme/.github/git/ref/heads/main --jq"*) echo '{"object": {"sha": "SHA_MAIN"}}' | respond ;;
  "api -X POST repos/acme/.github/git/refs"*) touch "$FIX/branch" ;;
  "api -X PUT repos/acme/.github/contents/senior-mode/config.json"*)
    case "$*" in *"branch=chore/senior-mode-org"*) ;; *) echo "FORBIDDEN $*" >>"$GH_LOG" ;; esac ;;
  "pr create"*) touch "$FIX/pr"; echo "https://github.com/acme/.github/pull/1" ;;
  "pr list"*) [ -f "$FIX/pr" ] || exit 0; echo '[{"url": "https://github.com/acme/.github/pull/1"}]' | respond ;;
  "api -X "*rulesets* | "api repos/acme/rulesets"*) echo "FORBIDDEN $*" >>"$GH_LOG"; exit 1 ;;
  "project list"*) echo '{"projects": []}' | respond ;;
  "api graphql"*)
    body=$(cat); echo "$body" >>"$GH_LOG"
    v=$(jq -c .variables <<<"$body")
    [ -z "${GRAPHQL_ERR:-}" ] || { echo "$GRAPHQL_ERR" >&2; exit 1; }
    if grep -q 'organization(login' <<<"$body"; then
      jq -c '{data: {organization: {projectsV2: {nodes: .}}}}' "$FIX/projects.json" | respond
    elif grep -q copyProjectV2 <<<"$body"; then
      jq --argjson v "$v" '. += [{id: "PVT_COPY", number: 9, title: $v.title, template: false}]' "$FIX/projects.json" >"$FIX/p" && mv "$FIX/p" "$FIX/projects.json"
      echo '{"data": {"copyProjectV2": {"projectV2": {"id": "PVT_COPY", "number": 9}}}}' | respond
    elif grep -q markProjectV2AsTemplate <<<"$body"; then
      jq --argjson v "$v" 'map(if .id == $v.input.projectId then .template = true else . end)' "$FIX/projects.json" >"$FIX/p" && mv "$FIX/p" "$FIX/projects.json"
      echo '{"data": {"markProjectV2AsTemplate": {"projectV2": {"id": "PVT_COPY"}}}}' | respond
    else echo '{"data": {"node": {"fields": {"nodes": []}}}}' | respond; fi ;;
esac
STUB
chmod +x "$work/stub/gh"
export PATH="$work/stub:$PATH" GH_LOG="$work/gh.log" FIX="$work/fix" SENIOR_MODE_RETRY_DELAY=0
mkdir -p "$FIX"

repo="$work/repo"
git init -q "$repo"
git -C "$repo" remote add origin git@github.com:acme/app.git
org() { (cd "$repo" && "$cli" setup org "$@") >"$work/out" 2>"$work/err"; }
logged() { grep -qF -- "$1" "$GH_LOG"; }
mutations() { grep -c '^{.*mutation(' "$GH_LOG"; }
writes() { grep -cE '^api -X |^pr create|FORBIDDEN' "$GH_LOG"; }
reset() { echo '[{"id": "PVT_BOARD", "number": 2, "title": "app", "template": false}]' >"$FIX/projects.json"; rm -f "$FIX/org-repo" "$FIX/org-config.json" "$FIX/branch" "$FIX/pr"; : >"$GH_LOG"; }

# An organization with no template: the dry run says what it would do and changes nothing.
reset
org acme || fail "dry run failed: $(cat "$work/err")"
for want in "would copy" "would mark as template" "dry run, nothing changed"; do
  grep -qF -- "$want" "$work/out" || fail "dry run without '$want': $(cat "$work/out")"
done
[ "$(mutations)" = 0 ] && [ "$(writes)" = 0 ] || fail "dry run wrote: $(grep -E 'mutation\(|^api -X |^pr create' "$GH_LOG")"
[ "$(jq length "$FIX/projects.json")" = 1 ] || fail "dry run copied a Project"

# --apply copies the plugin's template and marks the copy; there is no .github repository, so the file is printed.
org acme --apply || fail "apply failed: $(cat "$work/err")"
[ "$(grep -c '^{.*copyProjectV2' "$GH_LOG")" = 1 ] || fail "the template was not copied exactly once"
[ "$(grep -c '^{.*markProjectV2AsTemplate' "$GH_LOG")" = 1 ] || fail "the copy was not marked exactly once"
grep -q '"template":"PVT_kwHOAZfEPs4Bs2sq"' "$GH_LOG" || fail "not the plugin's template that was copied: $(grep copyProjectV2 "$GH_LOG")"
[ "$(jq -r '.[] | select(.id == "PVT_COPY") | .template' "$FIX/projects.json")" = true ] || fail "the copy is not a template"
grep -q '"template": "PVT_COPY"' "$work/out" || fail "the config to add is not printed: $(cat "$work/out")"
grep -q "no acme/.github repository, none created" "$work/out" || fail "missing repository not said: $(cat "$work/out")"
grep -qE 'repo create|api -X POST (user|orgs)/' "$GH_LOG" && fail "a repository was created"

# A second --apply changes nothing.
: >"$GH_LOG"
org acme --apply || fail "second apply failed: $(cat "$work/err")"
[ "$(mutations)" = 0 ] && [ "$(writes)" = 0 ] || fail "second apply wrote: $(grep -E 'mutation\(|^api -X |^pr create' "$GH_LOG")"
grep -q "nothing to copy" "$work/out" || fail "second apply does not say there is nothing to copy: $(cat "$work/out")"

# A copy that an interrupted run left unmarked is marked, not copied again.
echo '[{"id": "PVT_COPY", "number": 9, "title": "senior-mode template", "template": false}]' >"$FIX/projects.json"
: >"$GH_LOG"
org acme --apply || fail "apply after an interruption failed: $(cat "$work/err")"
[ "$(grep -c '^{.*copyProjectV2' "$GH_LOG")" = 0 ] && [ "$(grep -c '^{.*markProjectV2AsTemplate' "$GH_LOG")" = 1 ] || fail "the unmarked copy was not just marked"

# A user account has no template Projects.
: >"$GH_LOG"
org jdoe --apply || fail "user account: exit not 0: $(cat "$work/err")"
grep -q "nothing to do" "$work/out" || fail "user account: nothing-to-do not said: $(cat "$work/out")"
logged "graphql" && fail "user account: Projects were read"

# With a .github repository, the layer changes through a pull request on chore/senior-mode-org, never on main.
reset
touch "$FIX/org-repo"
echo '{"autonomy": {"parallel": 2}}' >"$FIX/org-config.json"
org acme || fail "dry run with the repository failed: $(cat "$work/err")"
grep -q "would open a pull request on acme/.github (branch chore/senior-mode-org)" "$work/out" || fail "dry run does not announce the pull request: $(cat "$work/out")"
org acme --apply || fail "apply with the repository failed: $(cat "$work/err")"
logged "api -X POST repos/acme/.github/git/refs -f ref=refs/heads/chore/senior-mode-org -f sha=SHA_MAIN" || fail "the branch was not created from main: $(cat "$GH_LOG")"
logged "branch=chore/senior-mode-org" || fail "the file was not written on the branch"
logged "sha=BLOB1" || fail "the existing file was not updated by its sha"
logged FORBIDDEN && fail "something was written to the default branch: $(grep FORBIDDEN "$GH_LOG")"
logged "pr create --repo acme/.github --base main --head chore/senior-mode-org" || fail "no pull request opened: $(cat "$GH_LOG")"
grep -q "pull request opened" "$work/out" || fail "pull request not reported: $(cat "$work/out")"
# The pull request is open: a second apply opens nothing.
: >"$GH_LOG"
org acme --apply || fail "second apply with the repository failed: $(cat "$work/err")"
[ "$(writes)" = 0 ] || fail "second apply wrote again: $(grep -E '^api -X |^pr create' "$GH_LOG")"
grep -q "already open" "$work/out" || fail "open pull request not reported: $(cat "$work/out")"
# The layer already names the template: nothing to propose.
rm -f "$FIX/branch" "$FIX/pr"
echo '{"board": {"template": "PVT_COPY"}}' >"$FIX/org-config.json"
: >"$GH_LOG"
org acme --apply || fail "apply with the layer in place failed: $(cat "$work/err")"
[ "$(writes)" = 0 ] || fail "the layer already names the template yet something was written"
grep -q "already PVT_COPY" "$work/out" || fail "not said: $(cat "$work/out")"

# A token without the project scope is named, and nothing changes.
reset
SCOPES="'gist', 'repo'" org acme --apply && fail "apply succeeded without the project scope"
grep -q "scope project" "$work/err" || fail "the scope is not named: $(cat "$work/err")"
[ "$(mutations)" = 0 ] && [ "$(writes)" = 0 ] || fail "wrote without the scope"
GRAPHQL_ERR="error: your authentication token is missing required scopes [read:project]" org acme && fail "dry run succeeded without the scope"
grep -q "scope project" "$work/err" || fail "the scope of a refused read is not named: $(cat "$work/err")"
GRAPHQL_ERR="gh: Resource not accessible by personal access token (HTTP 403)" org acme --apply && fail "apply succeeded without the role"
grep -q "role" "$work/err" || fail "the role is not named: $(cat "$work/err")"

# --print-ruleset: valid JSON with the five rules, and no API call at all.
reset
org acme --print-ruleset || fail "--print-ruleset failed: $(cat "$work/err")"
jq -e . "$work/out" >/dev/null 2>&1 || fail "the ruleset is not valid JSON: $(cat "$work/out")"
[ "$(jq -c '[.rules[].type]' "$work/out")" = '["deletion","non_fast_forward","required_linear_history","pull_request","required_status_checks"]' ] ||
  fail "wrong rules: $(jq -c '[.rules[].type]' "$work/out")"
jq -e '.rules[] | select(.type == "pull_request") | .parameters.allowed_merge_methods == ["rebase"]' "$work/out" >/dev/null || fail "pull_request without rebase"
[ "$(jq -c '[.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context]' "$work/out")" = '["senior-mode/ci","senior-mode/review","senior-mode/security"]' ] ||
  fail "wrong status check contexts"
jq -e '.conditions.repository_name.include == ["~ALL"]' "$work/out" >/dev/null || fail "the ruleset does not apply to the organization's repositories"
[ ! -s "$GH_LOG" ] || fail "--print-ruleset called gh: $(cat "$GH_LOG")"
org acme --print-ruleset --apply && fail "--print-ruleset accepted with --apply"

# setup github in a new repository copies the organization's template when the layer sets one, else the plugin's.
reset
mkdir -p "$repo/.claude" "$repo/.git/senior-mode"
echo '{}' >"$repo/.claude/senior-mode.json"
(cd "$repo" && "$cli" setup github) >"$work/out" 2>"$work/err"
grep copyProjectV2 "$GH_LOG" | grep -q '"template":"PVT_kwHOAZfEPs4Bs2sq"' || fail "no organization layer: not the plugin's template: $(grep copyProjectV2 "$GH_LOG")"
echo '{"board": {"template": "PVT_ORG"}}' >"$repo/.git/senior-mode/organization.json"
rm -f "$repo/.claude/senior-mode.json"; echo '{}' >"$repo/.claude/senior-mode.json"
: >"$GH_LOG"
(cd "$repo" && "$cli" setup github) >"$work/out" 2>"$work/err"
grep copyProjectV2 "$GH_LOG" | grep -q '"template":"PVT_ORG"' || fail "organization layer set: not copied from it: $(grep copyProjectV2 "$GH_LOG")"
# The repository's own board.template still wins.
echo '{"board": {"template": "PVT_REPO"}}' >"$repo/.claude/senior-mode.json"
: >"$GH_LOG"
(cd "$repo" && "$cli" setup github) >"$work/out" 2>"$work/err"
grep copyProjectV2 "$GH_LOG" | grep -q '"template":"PVT_REPO"' || fail "the repository's template does not win: $(grep copyProjectV2 "$GH_LOG")"

[ "$failures" = 0 ] || { echo "$failures failure(s)"; exit 1; }
echo "ok"
