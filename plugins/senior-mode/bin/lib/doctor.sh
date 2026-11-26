# shellcheck shell=bash
# `senior-mode doctor` (#316): diagnoses the installation and prints, for each failure, the command that fixes it.

# Records one check: level ok|warn|fail, a name, what was found, and the fix when it is not ok.
doctor_add() { # level name message [fix]
  DOCTOR_CHECKS+=("$(jq -nc --arg l "$1" --arg n "$2" --arg m "$3" --arg f "${4:-}" \
    '{level: $l, name: $n, message: $m} + (if $f != "" then {fix: $f} else {} end)')")
}

# The installed plugin is not older than the checkout of its marketplace (#607): a restart refreshes the checkout, not the
# plugin, and a marketplace declared by managed settings answers "not found" to `claude plugin marketplace update`.
# Silent without an install record or a checkout (a CLI run from a clone).
doctor_plugin_lag() {
  local cfg=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins root installed dir src market
  root=$(git rev-parse --show-toplevel 2>/dev/null) || root=""
  installed=$(jq -r --arg root "$root" '[.plugins // {} | to_entries[] | select(.key | startswith("senior-mode@")) | .value[]
    | select((.projectPath // $root) == $root) | .version // empty] | .[]' "$cfg/installed_plugins.json" 2>/dev/null | sort -V | tail -n 1) || installed=""
  dir=$(jq -r '.["senior-mode"].installLocation // empty' "$cfg/known_marketplaces.json" 2>/dev/null) || dir=""
  dir=${dir:-$cfg/marketplaces/senior-mode}
  src=$(jq -r '[.plugins[] | select(.name == "senior-mode") | .source | strings] | first // empty' "$dir/.claude-plugin/marketplace.json" 2>/dev/null) || src=""
  market=$(jq -r '.version // empty' "$dir/${src:-.}/.claude-plugin/plugin.json" 2>/dev/null) || market=""
  [ -n "$installed" ] && [ -n "$market" ] || return 0
  if [ "$installed" != "$market" ] && [ "$(printf '%s\n%s\n' "$installed" "$market" | sort -V | tail -n 1)" = "$market" ]; then
    doctor_add warn "plugin version" "the installed plugin is $installed, its marketplace is at $market" \
      "claude plugin update senior-mode@senior-mode, then restart Claude Code (a marketplace declared by managed settings: docs/guide/self-hosting.md, \"Update a managed install\")"
  else
    doctor_add ok "plugin version" "$installed installed, $market in its marketplace"
  fi
}

# The settings fix of a session in the Claude Code sandbox: an excluded command leaves the sandbox only when it is the
# whole command line (`cd x && senior-mode doctor` and `gh ... | jq` stay sandboxed).
DOCTOR_SANDBOX_FIX='add "senior-mode *" to sandbox.excludedCommands in the managed settings, and run senior-mode alone on its command line (docs/guide/self-hosting.md, "Claude Code sandbox")'

# This session probably runs in the Claude Code sandbox: it sets SANDBOX_RUNTIME, and its policy may deny the config of gh.
doctor_sandboxed() {
  local dir=${GH_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/gh}
  [ -n "${SANDBOX_RUNTIME:-}" ] && return 0
  [ -d "$dir" ] && { [ ! -r "$dir" ] || [ ! -x "$dir" ]; }
}

# `senior-mode version` (#615): the plugin version and the commit of the checkout it runs from; `unknown` from a copy that is
# no checkout of the plugin's repository (the plugin cache), where the commit of some enclosing repository would be wrong.
print_version() {
  local root version top commit=unknown
  root=$(plugin_root)
  version=$(jq -r '.version // empty' "$root/.claude-plugin/plugin.json" 2>/dev/null) || version=""
  top=$(git -C "$root" rev-parse --show-toplevel 2>/dev/null) || top=""
  if [ -n "$top" ] && [ -f "$top/plugins/senior-mode/.claude-plugin/plugin.json" ]; then
    commit=$(git -C "$root" rev-parse --short HEAD 2>/dev/null) || commit=unknown
  fi
  echo "senior-mode ${version:-unknown} ($commit)"
}

# git, jq, gh and claude on the PATH, their versions, and the version of the plugin.
doctor_tools() {
  local t v hint found="" plugin
  for t in git jq gh claude; do
    if command -v "$t" >/dev/null; then
      v=$("$t" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n 1) || v=""
      found="$found${found:+, }$t ${v:-?}"
    else
      if [ "$t" = claude ] && doctor_sandboxed; then
        doctor_add warn "tool claude" "claude is not on the PATH of this sandbox (it may be installed outside it)" "$DOCTOR_SANDBOX_FIX"
        continue
      fi
      case $t in
        git) hint="install git: https://git-scm.com/downloads" ;;
        jq) hint="install jq: https://jqlang.org/download/" ;;
        gh) hint="install the GitHub CLI: https://cli.github.com" ;;
        *) hint="install Claude Code: https://docs.claude.com/en/docs/claude-code/setup" ;;
      esac
      doctor_add fail "tool $t" "$t is not on the PATH" "$hint"
    fi
  done
  plugin=$(jq -r '.version // empty' "$(plugin_root)/.claude-plugin/plugin.json" 2>/dev/null) || plugin=""
  doctor_add ok versions "${found:-no tool found}; senior-mode plugin ${plugin:-of unknown version}"
}

# gh is logged in, with the scopes the board and the pull requests need (repo, project).
doctor_gh() {
  local out scopes line s missing=""
  command -v gh >/dev/null || return 0
  if ! out=$(gh_bound auth status 2>&1); then
    if [ -z "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ] && doctor_sandboxed; then
      doctor_add warn "gh auth" "gh cannot read its credentials: running inside a sandbox?" "$DOCTOR_SANDBOX_FIX"
      return 0
    fi
    doctor_add fail "gh auth" "gh is not logged in: $(head -n 1 <<<"$out")" "gh auth login --scopes repo,project,workflow"
    return 0
  fi
  line=$(grep -i 'token scopes' <<<"$out" | head -n 1 || true)
  if [ -z "$line" ] && { [[ ${GH_TOKEN:-${GITHUB_TOKEN:-}} == github_pat_* ]] || grep -q 'github_pat_' <<<"$out"; }; then
    doctor_gh_fine_grained
    return 0
  fi
  if [ -z "$line" ]; then
    doctor_add warn "gh scopes" "logged in, but gh does not list the scopes of the token (a token from the environment?)" "gh auth refresh -s repo -s project"
    return 0
  fi
  scopes=$(tr -d "',*" <<<"${line#*:}")
  for s in repo project; do
    # shellcheck disable=SC2086 # the scopes are words
    printf '%s\n' $scopes | grep -qx "$s" || missing="$missing${missing:+, }$s"
  done
  if [ -n "$missing" ]; then
    doctor_add fail "gh scopes" "the token lacks the scope $missing" "gh auth refresh -s repo -s project"
  else
    doctor_add ok "gh auth" "logged in with the scopes repo and project"
  fi
}

# What senior-mode needs of a fine-grained token, to grant when a probe is refused (a read call cannot tell a missing
# write permission, so the list is the full one).
DOCTOR_TOKEN_GRANT='grant the permissions Contents, Pull requests, Issues, Commit statuses and Workflows: read and write; Checks and Actions: read; organization Projects: read and write (docs/guide/self-hosting.md, "The GitHub token")'

# A fine-grained token lists no scopes: probe what senior-mode reads (contents, pull requests, issues, commit statuses,
# check runs, workflows, the Project) and name the permissions that GitHub refuses.
doctor_gh_fine_grained() {
  local slug sha file owner number missing="" probe name path
  slug=$(repo_slug 2>/dev/null) || slug=""
  [ -n "$slug" ] || { doctor_add warn "gh auth" "logged in with a fine-grained token, but there is no origin remote to probe its permissions"; return 0; }
  sha=$(gh_bound api "repos/$slug/commits?per_page=1" --jq '.[0].sha' 2>/dev/null) || sha=""
  [ -n "$sha" ] || missing="Contents"
  for probe in "Pull requests|repos/$slug/pulls?per_page=1" "Issues|repos/$slug/issues?per_page=1" \
    "Commit statuses|repos/$slug/commits/$sha/statuses" "Checks|repos/$slug/commits/$sha/check-runs" \
    "Actions|repos/$slug/actions/workflows?per_page=1"; do
    name=${probe%%|*}
    path=${probe#*|}
    [ -n "$sha" ] || case $name in Commit* | Checks) continue ;; esac
    gh_bound api "$path" >/dev/null 2>&1 || missing="$missing${missing:+, }$name"
  done
  file=$(git rev-parse --show-toplevel 2>/dev/null)/.claude/senior-mode.json
  if [ -f "$file" ] && owner=$(jq -r '.project.owner // empty' "$file" 2>/dev/null) && number=$(jq -r '.project.number // empty' "$file" 2>/dev/null) &&
    [ -n "$owner" ] && [ -n "$number" ]; then
    # shellcheck disable=SC2016 # a GraphQL query, not shell
    gh_bound api graphql -f owner="$owner" -F number="$number" -f query='query($owner: String!, $number: Int!) {
      repositoryOwner(login: $owner) { ... on User { projectV2(number: $number) { id } } ... on Organization { projectV2(number: $number) { id } } } }' \
      >/dev/null 2>&1 || missing="$missing${missing:+, }Projects"
  fi
  if [ -n "$missing" ]; then
    name=permission
    [[ $missing == *,* ]] && name=permissions
    doctor_add fail "gh auth" "the fine-grained token lacks the $name $missing (GitHub refused a read on $slug)" "$DOCTOR_TOKEN_GRANT"
  else
    doctor_add ok "gh auth" "logged in with a fine-grained token that reads contents, pull requests, issues, statuses, checks, actions and the Project (write access is not probed)"
  fi
}

# Claude Code is logged in.
doctor_claude() {
  local out
  command -v claude >/dev/null || return 0
  out=$(net_bound 30 claude auth status 2>/dev/null </dev/null) || true
  if jq -e '.loggedIn == true' <<<"$out" >/dev/null 2>&1; then
    doctor_add ok "claude login" "logged in ($(jq -r '.authMethod // "unknown method"' <<<"$out"))"
  elif jq -e '.loggedIn == false' <<<"$out" >/dev/null 2>&1; then
    doctor_add fail "claude login" "Claude Code is not logged in" "claude auth login"
  else
    doctor_add warn "claude login" "could not read the login state of Claude Code" "claude auth status"
  fi
}

# The commit-msg and pre-push hooks are where git looks for them, and are senior-mode's (or call it).
doctor_hooks() {
  local root path dir hook bad="" soft=""
  root=$(git rev-parse --show-toplevel 2>/dev/null) || { doctor_add fail "git hooks" "not inside a git repository" "cd into the repository"; return 0; }
  path=$(git config core.hooksPath || true)
  if [ -z "$path" ]; then
    dir=$(git rev-parse --path-format=absolute --git-path hooks)
  elif [[ $path == /* ]]; then
    dir=$path
  else
    dir=$root/$path
  fi
  # pre-push is the gate (check before a push); commit-msg only keeps the subjects, which check also reads.
  for hook in pre-push commit-msg; do
    if [ ! -x "$dir/$hook" ]; then
      [ "$hook" = pre-push ] && bad="$bad${bad:+, }$hook missing or not executable" || soft="$soft${soft:+, }$hook missing or not executable"
    elif ! grep -Eq 'senior-mode|\.githooks' "$dir/$hook"; then
      [ "$hook" = pre-push ] && bad="$bad${bad:+, }$hook is not senior-mode's and does not call it" ||
        soft="$soft${soft:+, }$hook is not senior-mode's and does not call it"
    fi
  done
  if [ -n "$bad$soft" ] && { [ ! -w "$(git rev-parse --path-format=absolute --git-path hooks)" ] || [ ! -w "$(git rev-parse --path-format=absolute --git-path config)" ]; }; then
    doctor_add "$([ -n "$bad" ] && echo fail || echo warn)" "git hooks" "in $dir: ${bad:-pre-push is in place}${soft:+${bad:+, }$soft}; .git/hooks or .git/config is read-only here, so an agent cannot install them: a person must run the fix" \
      "! senior-mode setup repo --hooks"
  elif [ -n "$bad" ]; then
    doctor_add fail "git hooks" "in $dir: $bad${soft:+, $soft}" "senior-mode setup repo --hooks"
  elif [ -n "$soft" ]; then
    doctor_add warn "git hooks" "pre-push is in place in $dir; $soft" "senior-mode setup repo --hooks"
  else
    doctor_add ok "git hooks" "pre-push and commit-msg in $dir"
  fi
}

# The fix to print for a finding of the configuration, from where it comes.
doctor_config_fix() { # path layer message
  local file
  case $2 in
    local) file=.claude/senior-mode.local.json ;;
    organization) file="$(git rev-parse --git-common-dir)/senior-mode/organization.json" ;;
    *) file=.claude/senior-mode.json ;;
  esac
  case $1 in
    process.lifts) echo "make the ADR of the lift 'status: accepted' and merge it on the default branch, or remove the lift and choose the strict profile (a lift is read from $file)" ;;
    process.profile) echo "set process.profile to strict or fast, or add .claude/senior-mode/profiles/<name>.json" ;;
    minVersion) echo "update the plugin, then restart Claude Code: claude plugin update senior-mode@senior-mode (do not edit $file: its keys are valid for the newer version)" ;;
    overrides/*) echo "rename or delete the file under .claude/senior-mode/overrides/" ;;
    *) case $3 in
      *"did you mean"*) echo "edit $file: ${3##*did you mean }" ;;
      *) echo "edit $file, then run senior-mode config validate" ;;
    esac ;;
  esac
}

# The config is valid: the findings of config validate (unknown keys with the closest one, values out of their
# domain, deprecated keys, lifts, overrides), each with its fix. Leaves the resolved layers in DOCTOR_RES.
doctor_config() {
  local findings n w line level path layer msg
  DOCTOR_RES=""
  if ! git rev-parse --show-toplevel >/dev/null 2>&1 || [ ! -f "$(git rev-parse --show-toplevel)/.claude/senior-mode.json" ]; then
    doctor_add fail config "no .claude/senior-mode.json here" "/senior-mode:setup (or: senior-mode setup repo)"
    return 0
  fi
  if ! jq empty "$(git rev-parse --show-toplevel)/.claude/senior-mode.json" 2>/dev/null; then
    doctor_add fail config ".claude/senior-mode.json is not valid JSON" "fix the syntax, or: senior-mode setup repo"
    return 0
  fi
  DOCTOR_RES=$(config_resolve --validate) || { doctor_add fail config "the configuration cannot be read" "senior-mode config validate"; return 0; }
  findings=$(jq -sc --argjson f "$(jq -c .findings <<<"$DOCTOR_RES")" '$f + .' <<<"$(override_findings)")
  n=$(jq -r 'map(select(.level == "error")) | length' <<<"$findings")
  w=$(jq -r 'map(select(.level == "warning")) | length' <<<"$findings")
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    level=$(jq -r .level <<<"$line")
    path=$(jq -r '.path' <<<"$line")
    layer=$(jq -r '.layer // "repository"' <<<"$line")
    msg=$(jq -r '.message' <<<"$line")
    doctor_add "$([ "$level" = error ] && echo fail || echo warn)" "config ${path:-(file)}" "$([ "$layer" = repository ] || echo "$layer: ")$msg" \
      "$(doctor_config_fix "$path" "$layer" "$msg")"
  done < <(jq -c '.[]' <<<"$findings")
  [ "$n" -gt 0 ] || [ "$w" -gt 0 ] || doctor_add ok config "valid against the schema"
}

# The type:* labels that `issue create --type` puts on a ticket exist on the repository.
doctor_type_labels() { # slug config-file
  local have missing="" t l
  command -v gh >/dev/null || return 0
  have=$(gh_bound label list --repo "$1" --limit 200 --json name --jq '.[].name' 2>/dev/null) || return 0
  for t in feature bug task chore spike; do
    l=$(workflow_label "" "type:$t")
    grep -qxF "$l" <<<"$have" || missing+="${missing:+ }$l"
  done
  if [ -n "$missing" ]; then
    doctor_add warn "type labels" "$1 lacks the labels $missing, which issue create --type puts on a ticket" "senior-mode setup github"
  else
    doctor_add ok "type labels" "the type:* labels of issue create exist on $1"
  fi
}

# Open issues that are not on the Project (#687): `ready` adds them to Backlog; the board has no "Auto-add to project".
doctor_orphans() {
  local nums n
  command -v gh >/dev/null || return 0
  nums=$(unboarded_issues 2>/dev/null) || return 0
  n=$(grep -c . <<<"$nums" || true)
  if [ "$n" -gt 0 ]; then
    doctor_add warn "board issues" "$n open issue(s) not on the Project, so ready, pick and serve do not see them" "senior-mode ready (adds them to Backlog), or enable \"Auto-add to project\" in the Project workflows"
  else
    doctor_add ok "board issues" "every open issue is on the Project"
  fi
}

# The built-in workflows of the Project that are on (#633): all but those that only close, archive or add can set a
# Status, and one that does turns back what serve and `item set` write. GitHub has no API for the "Sync with issue
# status" setting of the Project, so it is named, not read.
doctor_workflows() {
  local project answer on risky
  command -v gh >/dev/null || return 0
  project=$(jq -r '.project.id // empty' "$(config_file)")
  [ -n "$project" ] || return 0
  answer=$(jq -nc --arg id "$project" '{variables: {id: $id}, query: "query($id: ID!) { node(id: $id) {
    ... on ProjectV2 { workflows(first: 20) { nodes { name enabled } } } } }"}' | gh_retry api graphql --input - 2>/dev/null) || return 0
  jq -e '.data.node.workflows.nodes | type == "array"' <<<"$answer" >/dev/null 2>&1 || return 0
  on=$(jq -r '[.data.node.workflows.nodes[] | select(.enabled) | .name] | join(", ")' <<<"$answer")
  risky=$(jq -r '[.data.node.workflows.nodes[] | select(.enabled)
    | select(.name | IN("Item closed", "Pull request merged", "Auto-add to project", "Auto-add sub-issues to project", "Auto-archive items", "Auto-close issue") | not) | .name]
    | join(", ")' <<<"$answer")
  if [ -n "$risky" ]; then
    doctor_add warn "board workflows" "the Project workflows $risky are on and can set Status, which turns back what serve and item set write (on: $on)" "turn them off in the Project, Workflows (no API can), and check that Sync with issue status is off in the Project settings"
  else
    doctor_add ok "board workflows" "the enabled Project workflows (${on:-none}) leave Status alone; check by hand that Sync with issue status is off, no API shows it"
  fi
}

# The board of the config has its fields; the ruleset required by github.protection exists.
doctor_github() {
  local file missing protection slug n
  file=$(git rev-parse --show-toplevel 2>/dev/null)/.claude/senior-mode.json
  [ -f "$file" ] && jq empty "$file" 2>/dev/null || return 0
  if jq -e '.project.id' "$file" >/dev/null 2>&1; then
    missing=$(jq -r '[("Status", "Priority", "Size", "Severity") as $f | select((.project.fields // {}) | has($f) | not) | $f] | join(", ")' "$file")
    if [ -n "$missing" ]; then
      doctor_add fail "board fields" "the Project of the config lacks the fields $missing" "senior-mode setup github"
    else
      doctor_add ok "board fields" "Status, Priority, Size and Severity are in the config of Project #$(jq -r '.project.number // "?"' "$file")"
    fi
    doctor_orphans
    doctor_workflows
  else
    doctor_add warn "board fields" "no Project board in the config" "senior-mode setup github"
  fi
  slug=$(repo_slug 2>/dev/null) && doctor_type_labels "$slug"
  protection=$(jq -r '.github.protection // empty' "$file")
  case $protection in
    ruleset)
      slug=$(repo_slug 2>/dev/null) || slug=""
      command -v gh >/dev/null && [ -n "$slug" ] || return 0
      if n=$(gh_bound api "repos/$slug/rulesets" --jq '[.[] | select(.name == "senior-mode" and .source_type == "Repository" and .enforcement == "active")] | length' 2>/dev/null); then
        if [ "$n" -ge 1 ]; then
          doctor_add ok ruleset "the senior-mode ruleset of $slug is active, as github.protection says"
        else
          doctor_add fail ruleset "github.protection is ruleset, but $slug has no active senior-mode ruleset" "senior-mode setup github"
        fi
      else
        doctor_add warn ruleset "could not read the rulesets of $slug (gh api failed)" "gh auth status"
      fi
      ;;
    local) doctor_add warn ruleset "github.protection is local: GitHub enforces nothing on the default branch; senior-mode requires the statuses and an up-to-date branch before it merges, and the audit workflow reports direct pushes (ci.mode local, the pre-push hook is the only gate)" "" ;;
    none) doctor_add warn ruleset "github.protection is none: nothing enforces the default branch on the server (ci.mode local, the pre-push hook is the only gate)" "" ;;
    *) doctor_add warn ruleset "github.protection is not set: setup github has not recorded the ruleset" "senior-mode setup github" ;;
  esac
}

# What the repository customizes (spec 330 §6, what the layers, the overrides and the profiles provide): the profile, the
# lifted gates with their ADR, the override files, and the layer values that differ from the defaults (the keys that
# `setup` writes for every project, preset, checks, ci, github and project, do not count as customization).
# shellcheck disable=SC2016 # a jq program, not shell
doctor_customization() {
  [ -n "${DOCTOR_RES:-}" ] || { echo '{"profile":"strict","lifts":[],"overrides":[],"values":[],"nothing":true}'; return 0; }
  jq -c --argjson d "$DEFAULTS" --argjson ov "$(override_files | jq -Rsc 'split("\n") | map(select(length > 0) | split("\t") | {file: .[0], mode: .[1], target: .[2]})')" '
    def flat($p): if type == "object" then (to_entries[] | .key as $k | .value | flat($p + [$k])) else {path: $p, value: .} end;
    ([.layers[] | select(.name != "defaults" and .name != "profile") | .name as $n
      | (.config | del(.["$schema"], .process, .project, .github, .preset, .checks, .ci)) | flat([])
      | select((try (.path as $q | $d | getpath($q)) catch null) != .value) | {layer: $n, key: (.path | join(".")), value: .value}]
     + [.layers[] | select(.name == "profile") | .config | flat([]) | select((try (.path as $q | $d | getpath($q)) catch null) != .value)
        | {layer: "profile", key: (.path | join(".")), value: .value}]) as $values
    | {profile: .profile.name, origin: .profile.origin, chain: .profile.chain,
       lifts: [.lifted[] | . + {status: "accepted"}], overrides: $ov, values: $values}
    | . + {nothing: (.profile == "strict" and (.lifts | length) == 0 and (.overrides | length) == 0 and (.values | length) == 0)}' <<<"$DOCTOR_RES"
}

# The project has a test command (commands.test, or a check named test), and the test files that exist run somewhere (#638):
# without one, `red-tests verify` stops and nothing checks the suites.
doctor_tests() {
  local root file files n
  root=$(git rev-parse --show-toplevel 2>/dev/null) || return 0
  file=$root/.claude/senior-mode.json
  [ -f "$file" ] && jq empty "$file" 2>/dev/null || return 0
  jq -e '.commands.test // ([.checks[]? | select(.name == "test" or .name == "tests")][0].run) // empty' "$file" >/dev/null && return 0
  files=$(project_test_files "$root" 5)
  if [ -n "$files" ]; then
    n=$(project_test_files "$root" 1000 | grep -c '')
    doctor_add warn tests "no test command, and $n test files that no check runs, among them $(paste -sd' ' <<<"$files")" \
      'senior-mode setup repo --command test="<the command that runs them>"'
  else
    doctor_add warn tests "no test command: red-tests verify stops, and a pull request has no tests to run" \
      'senior-mode setup repo --command test="<the command that runs the tests>"'
  fi
}

# `senior-mode doctor [--json]`: runs the checks, prints one line per result and the fix under each failure, then the
# customization of the repository. Exit 1 when a check failed (a warning does not fail).
doctor() {
  local json=false out cust
  [ $# -eq 0 ] || { [ $# -eq 1 ] && [ "$1" = --json ]; } || usage
  [ "${1:-}" != --json ] || json=true
  DOCTOR_CHECKS=()
  doctor_tools
  doctor_plugin_lag
  doctor_gh
  doctor_claude
  doctor_hooks
  doctor_config
  doctor_github
  doctor_tests
  cust=$(doctor_customization)
  out=$(printf '%s\n' "${DOCTOR_CHECKS[@]}" | jq -sc --argjson c "$cust" '{ok: (map(.level == "fail") | any | not), checks: ., customization: $c}')
  if $json; then
    printf '%s\n' "$out"
  else
    jq -r '.checks[] | "\(if .level == "ok" then "ok   " elif .level == "warn" then "warn " else "FAIL " end) \(.name): \(.message)"
        + (if .fix then "\n       fix: \(.fix)" else "" end)' <<<"$out"
    echo
    echo "Customization"
    jq -r '.customization | if .nothing then "  nothing overridden" else (
        "  profile: \(.profile)\(if .origin then " (\(.origin)\(if (.chain | length) > 1 then ", extends \(.chain[1:] | join(", "))" else "" end))" else "" end)",
        (.lifts[] | "  LIFTED \(.rule): \(.adr) (\(.status), profile \(.profile))"),
        (.overrides[] | "  override \(.target) (\(.mode)): .claude/senior-mode/overrides/\(.file)"),
        (.values[] | "  \(.layer): \(.key) = \(.value | tojson)")) end' <<<"$out"
  fi
  jq -e '.ok' <<<"$out" >/dev/null
}
