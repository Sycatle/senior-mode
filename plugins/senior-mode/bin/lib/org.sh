# shellcheck shell=bash
# Organizations (spec 329 §6, §7): the organization layer's file and `setup org`, which prepares an organization once.
# An organization is shared infrastructure: every action on it is explicit (--apply), and an organization ruleset is
# only printed for its administrators, never created, edited or deleted.

# The template Project senior-mode keeps in an organization, the branch and the file of the organization layer (§6.1).
ORG_TEMPLATE_TITLE="senior-mode template"
ORG_BRANCH="chore/senior-mode-org"
ORG_CONFIG_PATH="senior-mode/config.json"

# The organization layer of this clone, as JSON ({} when there is none): the file the configuration layers read
# (<git common dir>/senior-mode/organization.json).
org_layer() {
  local common
  common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || { echo '{}'; return 0; }
  jq -c 'if type == "object" then . else {} end' "$common/senior-mode/organization.json" 2>/dev/null || echo '{}'
}

# The organization ruleset of §7.2 as JSON: the rules of the repository ruleset, on the default branch of every
# repository of the organization.
org_ruleset_json() {
  jq '.name = "senior-mode (organization)" | .conditions += {repository_name: {include: ["~ALL"], exclude: []}}' <<<"$RULESET"
}

# Stops on a failed call of `setup org` and names the cause: the token scope or the organization role that is
# missing, else gh's own message. $1 is the file with gh's stderr, $2 what was being done. Nothing is changed after it.
org_fail() { # stderr-file doing
  if grep -qiE 'missing required scopes|INSUFFICIENT_SCOPES|not been granted the required scopes' "$1"; then
    die "$2: the token lacks the scope project (gh auth refresh -s project); nothing was changed"
  elif grep -qiE 'FORBIDDEN|Resource not accessible|HTTP 403|must have admin|does not have permission' "$1"; then
    die "$2: your role in the organization does not allow it (an owner of the organization can do it); nothing was changed"
  fi
  cat "$1" >&2
  die "$2: failed"
}

# Opens the pull request that sets board.template to $3 in the organization layer of $1 (default branch $2), on the
# branch chore/senior-mode-org: the default branch is never written. Prints what it did.
org_layer_pr() { # repo default-branch template-id
  local repo=$1 def=$2 tid=$3 err file cur sha="" new head url
  err=$(mktemp)
  if file=$(gh_retry api "repos/$repo/contents/$ORG_CONFIG_PATH?ref=$def" 2>"$err"); then
    cur=$(jq -r .content <<<"$file" | base64 -d) sha=$(jq -r .sha <<<"$file")
    jq -e 'type == "object"' <<<"$cur" >/dev/null 2>&1 || { rm -f "$err"; die "$repo/$ORG_CONFIG_PATH is not a JSON object; fix it first"; }
  elif grep -q 'Not Found' "$err"; then
    cur='{}'
  else
    org_fail "$err" "cannot read $repo/$ORG_CONFIG_PATH"
  fi
  if [ "$(jq -r '.board.template // empty' <<<"$cur")" = "$tid" ]; then
    rm -f "$err"
    echo "org: board.template is already $tid in $repo, nothing to change"
    return 0
  fi
  if gh_retry api "repos/$repo/git/ref/heads/$ORG_BRANCH" >/dev/null 2>&1; then
    url=$(gh_retry pr list --repo "$repo" --head "$ORG_BRANCH" --state open --json url --jq '.[0].url // empty') || url=""
    rm -f "$err"
    [ -n "$url" ] || die "the branch $ORG_BRANCH of $repo exists with no open pull request; delete it and run setup org again"
    echo "org: a pull request is already open on $repo: $url"
    return 0
  fi
  new=$(jq '.board.template = $t' --arg t "$tid" <<<"$cur")
  head=$(gh_retry api "repos/$repo/git/ref/heads/$def" --jq .object.sha 2>"$err") || org_fail "$err" "cannot read the default branch of $repo"
  gh_retry api -X POST "repos/$repo/git/refs" -f "ref=refs/heads/$ORG_BRANCH" -f "sha=$head" >/dev/null 2>"$err" ||
    org_fail "$err" "cannot create the branch $ORG_BRANCH on $repo"
  gh_retry api -X PUT "repos/$repo/contents/$ORG_CONFIG_PATH" -f "message=chore: senior-mode organization template Project" \
    -f "content=$(printf '%s\n' "$new" | base64 | tr -d '\n')" -f "branch=$ORG_BRANCH" ${sha:+-f "sha=$sha"} >/dev/null 2>"$err" ||
    org_fail "$err" "cannot write $ORG_CONFIG_PATH on the branch $ORG_BRANCH of $repo"
  url=$(gh_retry pr create --repo "$repo" --base "$def" --head "$ORG_BRANCH" --title "chore: senior-mode organization template Project" \
    --body "Sets \`board.template\` to the template Project of the organization ($tid) in the organization layer, so that \`senior-mode setup github\` in a new repository copies it. Opened by \`senior-mode setup org\`." 2>"$err") ||
    org_fail "$err" "cannot open the pull request on $repo"
  rm -f "$err"
  echo "org: pull request opened on $repo (branch $ORG_BRANCH): $url"
}

# `senior-mode setup org <owner> [--apply] [--print-ruleset]`: the template Project of an organization, offered to its
# layer. Without --apply it prints what it would do and changes nothing. A user account has no template Projects:
# nothing to do. --print-ruleset prints the organization ruleset of §7.2 and nothing else.
# shellcheck disable=SC2016 # GraphQL and jq programs, not shell
setup_org() {
  local owner="" apply=false ruleset=false template owner_type owner_node err projects found tid="" number out line repo def
  while [ $# -gt 0 ]; do
    case $1 in
      --apply) apply=true ;;
      --print-ruleset) ruleset=true ;;
      -*) usage ;;
      *) [ -z "$owner" ] || usage; owner=$1 ;;
    esac
    shift
  done
  [ -n "$owner" ] || usage
  if [ "$ruleset" = true ]; then
    [ "$apply" = false ] || usage
    org_ruleset_json
    return 0
  fi
  template=$(jq -r '.board.template' <<<"$DEFAULTS")
  IFS='|' read -r owner_type owner_node < <(gh_retry api "users/$owner" --jq '[.type, .node_id] | join("|")') ||
    die "cannot read $owner on GitHub"
  if [ "$owner_type" != Organization ]; then
    echo "org: $owner is a user account: it has no template Projects and no organization rulesets, nothing to do"
    return 0
  fi
  if [ "$apply" = true ] && line=$(gh auth status 2>&1 | grep -i 'token scopes') && ! grep -q "'project'" <<<"$line"; then
    die "the token lacks the scope project (gh auth refresh -s project); nothing was changed"
  fi
  err=$(mktemp)
  projects=$(jq -nc --arg o "$owner" '{variables: {login: $o}, query: "query($login: String!) { organization(login: $login) {
    projectsV2(first: 100) { nodes { id number title template } } } }"}' |
    gh_retry api graphql --input - --jq '[.data.organization.projectsV2.nodes[]]' 2>"$err") ||
    org_fail "$err" "cannot list the Projects of $owner"
  found=$(jq -c --arg t "$ORG_TEMPLATE_TITLE" '[.[] | select(.title == $t)]' <<<"${projects:-[]}")

  if [ "$(jq -r 'map(select(.template)) | length' <<<"$found")" -gt 0 ]; then
    tid=$(jq -r 'map(select(.template))[0].id' <<<"$found") number=$(jq -r 'map(select(.template))[0].number' <<<"$found")
    echo "org: $owner has its template Project #$number \"$ORG_TEMPLATE_TITLE\" ($tid), nothing to copy"
  else
    # A copy made by an earlier run that stopped before marking it is marked, not copied again.
    if [ "$(jq 'length' <<<"$found")" -gt 0 ]; then
      tid=$(jq -r '.[0].id' <<<"$found") number=$(jq -r '.[0].number' <<<"$found")
      echo "org: Project #$number \"$ORG_TEMPLATE_TITLE\" ($tid) is a copy not marked as a template"
    elif [ "$apply" = true ]; then
      out=$(copy_template "$ORG_TEMPLATE_TITLE" "$template" 2>"$err") || org_fail "$err" "cannot copy the template Project $template into $owner"
      read -r number tid <<<"$out"
      echo "org: copied the template Project into $owner as Project #$number \"$ORG_TEMPLATE_TITLE\" ($tid)"
    else
      echo "org: $owner has no template Project \"$ORG_TEMPLATE_TITLE\": would copy the template Project $template into $owner"
    fi
    if [ "$apply" = true ]; then
      jq -nc --arg p "$tid" '{variables: {input: {projectId: $p}}, query: "mutation($input: MarkProjectV2AsTemplateInput!) {
        markProjectV2AsTemplate(input: $input) { projectV2 { id } } }"}' |
        gh_retry api graphql --input - >/dev/null 2>"$err" || org_fail "$err" "cannot mark Project #$number as a template"
      echo "org: marked Project #$number as a template: members of $owner see it among the organization's templates"
    else
      echo "org: would mark as template (markProjectV2AsTemplate)"
    fi
  fi

  # The organization layer: board.template = the organization's template, through a pull request.
  repo=$owner/.github
  if def=$(gh_retry api "repos/$repo" --jq .default_branch 2>"$err"); then
    if [ "$apply" = true ]; then
      org_layer_pr "$repo" "$def" "$tid"
    else
      echo "org: would open a pull request on $repo (branch $ORG_BRANCH) setting board.template to ${tid:-the id of the copy} in $ORG_CONFIG_PATH"
    fi
  elif grep -q 'Not Found' "$err"; then
    if [ "$apply" = true ]; then
      echo "org: no $repo repository, none created; to make \`senior-mode setup github\` copy this template, add $ORG_CONFIG_PATH to it:"
      jq -n --arg t "$tid" '{board: {template: $t}}'
    else
      echo "org: no $repo repository: --apply would print the $ORG_CONFIG_PATH to add and create nothing"
    fi
  else
    org_fail "$err" "cannot read $repo"
  fi
  rm -f "$err"
  [ "$apply" = true ] || echo "org: dry run, nothing changed; senior-mode setup org $owner --apply does it"
  return 0
}
