#!/usr/bin/env bash
# Tests for `senior-mode doctor` (#316): gh and claude are stubs, nothing touches the network.
set -u
bin=$(cd "$(dirname "$0")/.." && pwd)
cli=$bin/senior-mode
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0
unset SANDBOX_RUNTIME
export CLAUDE_CONFIG_DIR="$work/claude-home"
mkdir -p "$CLAUDE_CONFIG_DIR"
export GH_CONFIG_DIR="$work/gh-config"
mkdir -p "$GH_CONFIG_DIR"

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

stubs="$work/stubs"
mkdir -p "$stubs"
cat >"$stubs/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "--version "*) echo "gh version 2.65.0 (2025-01-06)" ;;
  "auth status")
    [ "${GH_STUB_AUTH:-ok}" = ok ] || { echo "You are not logged into any GitHub hosts. To log in, run: gh auth login" >&2; exit 1; }
    echo "github.com"
    if [ -n "${GH_STUB_FINE:-}" ]; then echo "  - Token: github_pat_**********"; else echo "  - Token scopes: ${GH_STUB_SCOPES:-'repo', 'project', 'workflow'}"; fi
    ;;
  "api repos/o/r/commits/abc123/check-runs"|"api repos/o/r/commits/abc123/statuses")
    case "$2 ${GH_STUB_DENY:-}" in
      *check-runs*checks*|*statuses*statuses*) echo "gh: Resource not accessible by personal access token (HTTP 403)" >&2; exit 1 ;;
    esac
    echo '{}'
    ;;
  "api repos/o/r/commits"*|"api repos/o/r/pulls"*|"api repos/o/r/issues"*|"api repos/o/r/actions/workflows"*|"api graphql")
    case "$2" in
      repos/o/r/commits\?*) w=contents ;; repos/o/r/pulls*) w=pulls ;; repos/o/r/issues*) w=issues ;;
      repos/o/r/actions/*) w=actions ;; *) w=projects ;;
    esac
    case " ${GH_STUB_DENY:-} " in *" $w "*) echo "gh: Resource not accessible by personal access token (HTTP 403)" >&2; exit 1 ;; esac
    q="$*"
    [ "$w" != projects ] || [ -t 0 ] || q="$q $(cat)"
    if [ "$w" = contents ]; then echo abc123
    elif [ "$w" = projects ] && [ -n "${GH_STUB_WORKFLOWS:-}" ] && grep -q 'workflows(first' <<<"$q"; then
      jq -nc --arg w "$GH_STUB_WORKFLOWS" '{data: {node: {workflows: {nodes: ($w | split(",") | map({name: ., enabled: true}))}}}}'
    elif [ "$w" = projects ] && [ -n "${GH_STUB_ORPHANS:-}" ] && grep -q 'issues(states' <<<"$q"; then
      jq -nc --argjson n "$GH_STUB_ORPHANS" '{data: {repository: {issues: {pageInfo: {hasNextPage: false}, nodes: [range(0; $n) | {number: (. + 1), labels: {nodes: []}, projectItems: {nodes: []}}]}}}}'
    else echo '[]'; fi
    ;;
  "api repos/o/r/rulesets") [ "${GH_STUB_RULESETS:-1}" != fail ] || exit 1; echo "${GH_STUB_RULESETS:-1}" ;;
  "label list")
    [ "${GH_STUB_LABELS:-all}" != fail ] || exit 1
    [ "${GH_STUB_LABELS:-all}" = all ] && printf 'type:feature\ntype:bug\ntype:task\ntype:chore\ntype:spike\n' || printf '%s\n' "$GH_STUB_LABELS"
    ;;
  *) exit 1 ;;
esac
EOF
cat >"$stubs/claude" <<'EOF'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "--version ") echo "2.1.311 (Claude Code)" ;;
  "auth status") echo "{\"loggedIn\": ${CLAUDE_STUB_LOGGED:-true}, \"authMethod\": \"claude.ai\"}" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$stubs/gh" "$stubs/claude"

repo="$work/repo"
git init -q -b main "$repo"
git -C "$repo" remote add origin git@github.com:o/r.git
mkdir -p "$repo/.claude" "$repo/.githooks" "$repo/docs/adr"
for h in pre-push commit-msg; do
  printf '#!/bin/sh\n# senior-mode hook\nexit 0\n' >"$repo/.githooks/$h"
  chmod +x "$repo/.githooks/$h"
done
git -C "$repo" config core.hooksPath .githooks
good='{"preset":"generic","github":{"protection":"ruleset"},"project":{"owner":"o","number":3,"id":"P","fields":{"Status":{"id":"S"},"Priority":{"id":"P"},"Size":{"id":"Z"},"Severity":{"id":"V"}}}}'
config() { printf '%s\n' "$1" >"$repo/.claude/senior-mode.json"; }
doctor() { (cd "$repo" && PATH="$stubs:$PATH" "$cli" doctor "$@") >"$work/out" 2>"$work/err"; }
expect_fail() { # case what fix
  doctor && fail "$1: doctor exited 0"
  grep -q "$2" "$work/out" || fail "$1: '$2' not in the output: $(cat "$work/out")"
  grep -q "fix: $3" "$work/out" || fail "$1: the fix '$3' is not printed: $(cat "$work/out")"
}

# A: everything in place: exit 0, every line ok, nothing overridden (the strict profile: the default fast one lifts the review).
good=$(jq -c '.process = {profile: "strict"}' <<<"$good")
config "$good"
doctor || fail "A: doctor failed: $(cat "$work/out" "$work/err")"
for c in 'gh auth' 'claude login' 'git hooks' config 'board fields' 'type labels' ruleset; do
  grep -q "ok .*$c" "$work/out" || fail "A: $c is not ok: $(cat "$work/out")"
done
grep -q 'senior-mode plugin' "$work/out" || fail "A: no version line: $(cat "$work/out")"
grep -q 'nothing overridden' "$work/out" || fail "A: customization not said: $(cat "$work/out")"
doctor --json && [ "$(jq -r '.ok' "$work/out")" = true ] && [ "$(jq -r '.customization.nothing' "$work/out")" = true ] || fail "A: --json wrong: $(cat "$work/out")"
doctor --bogus && fail "A: an unknown option was accepted"

# B: gh and claude.
GH_STUB_AUTH=no expect_fail "B1" 'gh is not logged in' 'gh auth login'
GH_STUB_SCOPES="'repo', 'gist'" expect_fail "B2" 'lacks the scope project' 'gh auth refresh -s repo -s project'
GH_STUB_SCOPES="'repo', 'read:project'" expect_fail "B3" 'lacks the scope project' 'gh auth refresh'
CLAUDE_STUB_LOGGED=false expect_fail "B4" 'not logged in' 'claude auth login'
# B6: inside a sandbox a logged-out gh and a missing claude are not reported as such.
GH_STUB_AUTH=no SANDBOX_RUNTIME=1 doctor || fail "B6: a sandboxed gh fails: $(cat "$work/out")"
grep -q 'not logged in' "$work/out" && fail "B6: says gh is not logged in: $(cat "$work/out")"
grep -q 'warn .*gh auth: gh cannot read its credentials: running inside a sandbox?' "$work/out" || fail "B6: the sandbox is not named: $(cat "$work/out")"
grep -q 'fix: .*"senior-mode \*".*excludedCommands.*alone' "$work/out" || fail "B6: no settings fix: $(cat "$work/out")"
grep -q 'gh auth login' "$work/out" && fail "B6: still suggests gh auth login"
nogh="$work/nogh"
mkdir -p "$nogh"
ln -s "$stubs/gh" "$nogh/gh"
(cd "$repo" && SANDBOX_RUNTIME=1 PATH="$nogh:$(dirname "$(command -v jq)"):$(dirname "$(command -v git)"):/usr/bin:/bin" "$cli" doctor >"$work/out" 2>&1)
grep -q 'warn .*tool claude: claude is not on the PATH of this sandbox' "$work/out" || fail "B7: the sandbox is not named for claude: $(cat "$work/out")"
grep -q 'install Claude Code' "$work/out" && fail "B7: still says to install Claude Code: $(cat "$work/out")"
if [ "$(id -u)" != 0 ]; then
  chmod 000 "$GH_CONFIG_DIR"
  GH_STUB_AUTH=no doctor
  chmod 755 "$GH_CONFIG_DIR"
  grep -q 'gh cannot read its credentials' "$work/out" || fail "B8: an unreadable gh config is not named: $(cat "$work/out")"
fi
doctor --json
[ "$(jq -r '[.checks[] | select(.level == "fail")] | length' "$work/out")" = 0 ] || fail "B5: the stubs leaked between cases"

# B9: a fine-grained token: the permissions are probed with read calls, the missing ones named, the fix lists them.
GH_STUB_FINE=1 doctor || fail "B9: a complete fine-grained token fails: $(cat "$work/out")"
grep -q 'ok .*gh auth: logged in with a fine-grained token' "$work/out" || fail "B9: not ok: $(cat "$work/out")"
GH_STUB_FINE=1 GH_STUB_DENY="checks" expect_fail "B10" 'the fine-grained token lacks the permission Checks' 'grant the permissions .*Checks.*read'
grep -q 'gh auth refresh' "$work/out" && fail "B10: still suggests gh auth refresh: $(cat "$work/out")"
GH_STUB_FINE=1 GH_STUB_DENY="statuses projects" expect_fail "B11" 'lacks the permissions Commit statuses, Projects' 'grant the permissions Contents, Pull requests, Issues, Commit statuses and Workflows: read and write'
GH_STUB_FINE=1 GH_TOKEN=github_pat_x GH_STUB_DENY="pulls issues actions" expect_fail "B12" 'lacks the permissions Pull requests, Issues, Actions' 'grant the permissions .*organization Projects: read and write'

# B13: the installed plugin lags the checkout of its marketplace (#607).
cc=$CLAUDE_CONFIG_DIR/plugins
mkdir -p "$cc/marketplaces/senior-mode/.claude-plugin" "$cc/marketplaces/senior-mode/plugins/senior-mode/.claude-plugin" "$cc/cache/senior-mode/senior-mode/0.6.0/.claude-plugin"
echo '{"name":"senior-mode","plugins":[{"name":"senior-mode","source":"./plugins/senior-mode"}]}' >"$cc/marketplaces/senior-mode/.claude-plugin/marketplace.json"
echo '{"version":"0.8.0"}' >"$cc/marketplaces/senior-mode/plugins/senior-mode/.claude-plugin/plugin.json"
echo '{"version":"0.6.0"}' >"$cc/cache/senior-mode/senior-mode/0.6.0/.claude-plugin/plugin.json"
jq -nc --arg p "$cc/cache/senior-mode/senior-mode/0.6.0" --arg o "$work/elsewhere" \
  '{version: 2, plugins: {"senior-mode@senior-mode": [{scope: "project", projectPath: $o, installPath: "/nope", version: "9.9.9"}, {scope: "user", installPath: $p, version: "0.6.0"}]}}' >"$cc/installed_plugins.json"
doctor || fail "B13: a lagging plugin fails: $(cat "$work/out")"
grep -q 'warn .*plugin version: the installed plugin is 0.6.0, its marketplace is at 0.8.0' "$work/out" || fail "B13: no warning: $(cat "$work/out")"
grep -q 'fix: claude plugin update senior-mode@senior-mode' "$work/out" || fail "B13: no update command: $(cat "$work/out")"
jq -nc --arg p "$cc/cache/senior-mode/senior-mode/0.6.0" '{version: 2, plugins: {"senior-mode@senior-mode": [{scope: "user", installPath: $p, version: "0.8.0"}]}}' >"$cc/installed_plugins.json"
doctor || fail "B14: an up to date plugin fails"
grep -q 'ok .*plugin version: 0.8.0 installed' "$work/out" || fail "B14: not ok: $(cat "$work/out")"
rm "$cc/installed_plugins.json"
doctor || fail "B15: no install record fails"
grep -q 'plugin version' "$work/out" && fail "B15: reports without an install record: $(cat "$work/out")"

# C: git hooks.
rm "$repo/.githooks/pre-push"
expect_fail "C1" 'pre-push missing' 'senior-mode setup repo'
printf '#!/bin/sh\nexit 0\n' >"$repo/.githooks/pre-push"
chmod +x "$repo/.githooks/pre-push"
expect_fail "C2" "pre-push is not senior-mode's" 'senior-mode setup repo'
printf '#!/bin/sh\n# senior-mode hook\n' >"$repo/.githooks/pre-push"
rm "$repo/.githooks/commit-msg"
doctor || fail "C3: a missing commit-msg fails: $(cat "$work/out")"
grep -q 'warn .*commit-msg missing' "$work/out" || fail "C3: no warning: $(cat "$work/out")"
printf '#!/bin/sh\n# senior-mode hook\n' >"$repo/.githooks/commit-msg"
chmod +x "$repo/.githooks/commit-msg"

# C4: .git/config read-only (the sandbox of an agent): the fix is for a person to run, with the hooks only.
rm "$repo/.githooks/pre-push"
if [ "$(id -u)" -ne 0 ]; then
  chmod a-w "$repo/.git/config"
  expect_fail "C4" 'a person must run the fix' '! senior-mode setup repo --hooks'
  chmod u+w "$repo/.git/config"
fi
expect_fail "C5" 'pre-push missing' 'senior-mode setup repo --hooks'
grep -q 'a person must run' "$work/out" && fail "C5: a writable .git asks for a person: $(cat "$work/out")"
printf '#!/bin/sh\n# senior-mode hook\n' >"$repo/.githooks/pre-push"
chmod +x "$repo/.githooks/pre-push"

# C6: tests (#638): no test command and test files that no check runs are named; a test command settles it.
printf 'x\n' >"$repo/tooling.test.mjs"
mkdir -p "$repo/node_modules/dep"
printf 'x\n' >"$repo/node_modules/dep/ignored.test.mjs"
config "$good"
doctor || fail "C6: a missing test command fails"
grep -q 'warn .*tests.*no test command' "$work/out" || fail "C6: no warning: $(cat "$work/out")"
grep -q 'fix: senior-mode setup repo --command test=' "$work/out" || fail "C6: no fix: $(cat "$work/out")"
grep -q 'warn .*tests.*tooling.test.mjs' "$work/out" || fail "C6: the test files are not named: $(cat "$work/out")"
grep -q 'ignored.test.mjs' "$work/out" && fail "C6: a file of node_modules is named"
config "$(jq -c '.commands.test = "node --test"' <<<"$good")"
doctor || fail "C7: doctor failed with a test command"
grep -q 'tests' "$work/out" && grep -q 'warn .*tests' "$work/out" && fail "C7: a test command still warns: $(cat "$work/out")"
config "$(jq -c '.checks = [{"name": "test", "run": "make test"}]' <<<"$good")"
doctor || fail "C8: doctor failed with a test check"
grep -q 'warn .*tests' "$work/out" && fail "C8: a test check still warns: $(cat "$work/out")"
rm -rf "$repo/tooling.test.mjs" "$repo/node_modules"
config "$good"
doctor || fail "C9: doctor failed with no test file"
grep -q 'warn .*tests.*no test command' "$work/out" || fail "C9: no warning for a missing test command: $(cat "$work/out")"
config "$good"

# D: config validity: the unknown key and its closest, a deprecated value as a warning only.
config "$(jq -c '.autonomy = {"maxTicket": 3}' <<<"$good")"
expect_fail "D1" 'did you mean maxTickets' 'edit .claude/senior-mode.json: maxTickets'
config "$(jq -c '.preset = "typescript"' <<<"$good")"
doctor || fail "D2: a deprecated value fails: $(cat "$work/out")"
grep -q 'warn .*"typescript" is deprecated' "$work/out" || fail "D2: no warning: $(cat "$work/out")"
config "$(jq -c '.minVersion = "99.0.0" | .lsp = true | .autonomyy = 1 | .project.protection = "local"' <<<"$good")"
expect_fail "D4" 'this config needs senior-mode >= 99.0.0' 'update the plugin, then restart Claude Code: claude plugin update senior-mode@senior-mode'
[ "$(grep -c '^FAIL .*config' "$work/out")" -eq 1 ] || fail "D4: more than one config failure: $(cat "$work/out")"
rm "$repo/.claude/senior-mode.json"
expect_fail "D3" 'no .claude/senior-mode.json' '/senior-mode:setup'

# E: the board and the ruleset.
config "$(jq -c 'del(.project.fields.Size)' <<<"$good")"
expect_fail "E1" 'lacks the fields Size' 'senior-mode setup github'
config "$good"
GH_STUB_RULESETS=0 expect_fail "E2" 'no active senior-mode ruleset' 'senior-mode setup github'
GH_STUB_LABELS='type:bug' doctor || fail "E4: a missing type label fails"
grep -q 'warn .*type labels.*type:feature type:task type:chore type:spike' "$work/out" || fail "E4: the missing labels are not named: $(cat "$work/out")"
grep -q 'fix: senior-mode setup github' "$work/out" || fail "E4: no fix: $(cat "$work/out")"
GH_STUB_LABELS=fail doctor || fail "E5: an unreadable label list fails"
grep -q 'type labels' "$work/out" && fail "E5: type labels reported with no list"
GH_STUB_RULESETS=fail doctor || fail "E3: an unreadable ruleset fails"
grep -q 'warn .*could not read the rulesets' "$work/out" || fail "E3: no warning: $(cat "$work/out")"

config "$(jq -c '.github.protection = "local"' <<<"$good")"
doctor || fail "E4: github.protection local fails"
grep -q 'warn .*github.protection is local' "$work/out" || fail "E4: no warning for local: $(cat "$work/out")"
config "$good"

# E6 (#687): open issues missing from the Project are warned about, with the fix.
GH_STUB_ORPHANS=3 doctor || fail "E6: orphan issues fail doctor"
grep -q 'warn .*board issues.*3 open issue(s) not on the Project' "$work/out" || fail "E6: the orphans are not counted: $(cat "$work/out")"
grep -q 'fix: senior-mode ready' "$work/out" || fail "E6: no fix: $(cat "$work/out")"
GH_STUB_ORPHANS=0 doctor || fail "E6: no orphan fails doctor"
grep -q 'ok .*board issues' "$work/out" || fail "E6: no ok line without orphans: $(cat "$work/out")"

# E7 (#633): a Project workflow that can set Status is warned about; the ones that close or archive are not.
GH_STUB_WORKFLOWS="Item closed,Pull request merged,Item reopened,Item added to project" doctor || fail "E7: a risky workflow fails doctor"
grep -q 'warn .*board workflows.*Item reopened, Item added to project are on and can set Status' "$work/out" || fail "E7: the workflows are not named: $(cat "$work/out")"
grep -q 'fix: turn them off' "$work/out" || fail "E7: no fix: $(cat "$work/out")"
GH_STUB_WORKFLOWS="Item closed,Pull request merged,Auto-archive items" doctor || fail "E7: harmless workflows fail doctor"
grep -q 'ok .*board workflows.*Sync with issue status' "$work/out" || fail "E7: no ok line for harmless workflows: $(cat "$work/out")"
doctor
grep -q 'board workflows' "$work/out" && fail "E7: workflows reported with no answer"

# F: customization: a lift names its ADR, a refused one fails; overrides and layer values are listed.
printf -- '---\nid: 0016\nstatus: proposed\n---\n' >"$repo/docs/adr/0016-lift.md"
config "$(jq -c '.process = {profile: "fast", lifts: [{rule: "review", adr: "docs/adr/0016-lift.md"}]}' <<<"$good")"
expect_fail "F1" 'proposed, not accepted' 'make the ADR of the lift'
grep -q 'review.*docs/adr/0016-lift.md' "$work/out" || fail "F1: the rule and the ADR are not named: $(cat "$work/out")"
printf -- '---\nid: 0016\nstatus: accepted\n---\n' >"$repo/docs/adr/0016-lift.md"
mkdir -p "$repo/.claude/senior-mode/overrides/skills/review"
echo "extra" >"$repo/.claude/senior-mode/overrides/skills/review/SKILL.append.md"
config "$(jq -c '.wip = 2 | .process = {profile: "fast", lifts: [{rule: "review", adr: "docs/adr/0016-lift.md"}]}' <<<"$good")"
doctor || fail "F2: an accepted lift fails: $(cat "$work/out")"
grep -q 'profile: fast (plugin, extends strict)' "$work/out" || fail "F2: profile missing: $(cat "$work/out")"
grep -q 'LIFTED review: docs/adr/0016-lift.md (accepted' "$work/out" || fail "F2: lift missing: $(cat "$work/out")"
grep -q 'override skills/review/SKILL.md (append)' "$work/out" || fail "F2: override missing: $(cat "$work/out")"
grep -q 'repository: wip = 2' "$work/out" || fail "F2: layer value missing: $(cat "$work/out")"
grep -q 'nothing overridden' "$work/out" && fail "F2: says nothing is overridden"
echo '{"wip": 5}' >"$repo/.claude/senior-mode.local.json"
doctor
grep -q 'local: wip = 5' "$work/out" || fail "F3: the local layer is not listed: $(cat "$work/out")"

# G (#446): the hooks, roles, routing rows and providers of the layers, each with its file and layer.
rm -f "$repo/.claude/senior-mode.local.json"
rm -rf "$repo/.claude/senior-mode"
# shellcheck disable=SC2016 # a jq program, not shell
levers='.hooks = {on: [{name: "slack", event: ["needs-human"], run: ".claude/senior-mode/hooks/slack.sh"}]}
  | .roles = {designer: {agent: ".claude/senior-mode/roles/designer.md", kind: "reviewer", when: {labels: ["ui"]}}}
  | .models = [{role: "implementer", size: "S", model: "haiku"}]
  | .providers = {local: {env: {ANTHROPIC_BASE_URL: "http://localhost:11434", ANTHROPIC_AUTH_TOKEN: "$LOCAL_TOKEN"}}}'
config "$(jq -c "$levers" <<<"$good")"
doctor
grep -q 'hook slack (needs-human) .claude/senior-mode/hooks/slack.sh \[version 1\]: repository layer, .claude/senior-mode.json' "$work/out" || fail "G1: the hook is not listed: $(cat "$work/out")"
grep -q 'role designer (reviewer) .claude/senior-mode/roles/designer.md: repository layer' "$work/out" || fail "G1: the role is not listed: $(cat "$work/out")"
grep -q 'row implementer size S: haiku: repository layer' "$work/out" || fail "G1: the row is not listed: $(cat "$work/out")"
grep -q 'provider local (ANTHROPIC_AUTH_TOKEN, ANTHROPIC_BASE_URL): repository layer' "$work/out" || fail "G1: the provider is not listed: $(cat "$work/out")"
grep -q 'localhost:11434\|LOCAL_TOKEN' "$work/out" && fail "G1: a provider value is printed: $(cat "$work/out")"
grep -q 'nothing overridden' "$work/out" && fail "G1: says nothing is overridden"
doctor --json
[ "$(jq -c '.customization | [(.hooks | map(.name)), (.roles | map(.name)), (.rows | map(.model)), (.providers | map(.name)), (.hooks[0].layer)]' "$work/out")" = '[["slack"],["designer"],["haiku"],["local"],"repository"]' ] ||
  fail "G2: --json lacks the levers: $(jq -c .customization "$work/out")"
# G3: a hook pinned to payload version 1 once version 3 has shipped is deprecated; a current one is not.
config "$(jq -c "$levers" <<<"$good")"
# (The schema does not know `hooks` yet, so doctor still fails on the key: only the warning is asserted.)
SENIOR_MODE_HOOK_PAYLOAD_LATEST=3 doctor
grep -q 'warn .*hook slack.*version 1.*deprecated' "$work/out" || fail "G3: no deprecation warning: $(cat "$work/out")"
config "$(jq -c "$levers | .hooks.on[0].version = 3" <<<"$good")"
SENIOR_MODE_HOOK_PAYLOAD_LATEST=3 doctor
grep -q 'deprecated' "$work/out" && fail "G3: a current hook version is flagged: $(cat "$work/out")"
config "$good"

[ "$failures" -eq 0 ] && echo "doctor: all cases pass"
exit "$failures"
