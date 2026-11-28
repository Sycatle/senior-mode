# shellcheck shell=bash
# Organizations (spec 329 §6, §7): the organization layer's file and `setup org`, which prepares an organization once.
# An organization is shared infrastructure: every action on it is explicit (--apply), and an organization ruleset is
# only printed for its administrators, never created, edited or deleted.

# The template Project senior-mode keeps in an organization, the branch and the file of the organization layer (§6.1).
ORG_TEMPLATE_TITLE="senior-mode template"
ORG_BRANCH="chore/senior-mode-org"
ORG_CONFIG_PATH="senior-mode/config.json"

# The organization layer (#400, spec 329 §6.1): the directory org.path of the repository <owner>/<org.repo>, read from its
# default branch only (or from org.ref), cached under ${XDG_CACHE_HOME:-~/.cache}/senior-mode/org/<owner>/<sha>/. The cache
# is asked again after ORG_TTL seconds (ORG_TTL_SERVE for serve, ORG_TTL_MISSING for an organization with no layer) with a
# conditional read (ETag), and not before ORG_RETRY seconds after a read that failed. Reading never fails a command.
ORG_TTL=600
ORG_TTL_SERVE=3600
ORG_TTL_MISSING=3600
ORG_RETRY=60

# The owner of the origin remote when it is on GitHub, else nothing.
org_owner() {
  git remote get-url origin 2>/dev/null | sed -nE 's#.*github\.com[:/]([^/]+)/[^/]+$#\1#p' || true
}

# A duration in seconds as 45s, 12m, 3h or 2d.
org_age() {
  local s=$1
  if [ "$s" -lt 60 ]; then echo "${s}s"; elif [ "$s" -lt 3600 ]; then echo "$((s / 60))m"
  elif [ "$s" -lt 86400 ]; then echo "$((s / 3600))h"; else echo "$((s / 86400))d"; fi
}

# Writes the state of a read: {sha, etag, checkedAt, failedAt, missing}.
org_state_put() { # file sha etag checked failed missing
  jq -nc --arg s "$2" --arg e "$3" --argjson c "$4" --argjson f "$5" --argjson m "$6" \
    '{sha: $s, etag: $e, checkedAt: $c, failedAt: $f, missing: $m}' >"$1.tmp.$$" && mv "$1.tmp.$$" "$1"
}

# Asks GitHub for the commit of the organization layer (one conditional read), then for config.json at that commit when
# it is new, and records the result. A failure keeps the last good copy and says so on one line.
org_sync() { # owner repo path ref state-file cache-dir key
  local owner=$1 repo=$2 path=$3 ref=$4 sf=$5 dir=$6 key=$7 err out rc=0 status="" sha="" etag="" old_sha="" old_etag="" checked=0 now cfg body
  now=$(date +%s)
  mkdir -p "$dir"
  if [ -f "$sf" ]; then
    read -r old_sha old_etag checked < <(jq -r '[(.sha // "-"), (.etag // "-"), (.checkedAt // 0)] | join(" ")' "$sf" 2>/dev/null) || true
    [ "$old_sha" != - ] || old_sha=""
    [ "$old_etag" != - ] || old_etag=""
  fi
  [ -n "$old_sha" ] && [ -f "$dir/$old_sha/$key.json" ] || old_etag=""
  err=$(mktemp)
  out=$(gh_bound api -i "repos/$owner/$repo/commits/${ref:-HEAD}" -H "Accept: application/vnd.github.sha" \
    ${old_etag:+-H "If-None-Match: $old_etag"} 2>"$err") || rc=$?
  status=$(sed -n '1s#^HTTP/[0-9.]* \([0-9]*\).*#\1#p' <<<"$out")
  if [ "$status" = 304 ] || grep -q 'HTTP 304' "$err"; then
    org_state_put "$sf" "$old_sha" "$old_etag" "$now" 0 false
  elif [ "$status" = 404 ] || grep -q 'HTTP 404' "$err"; then
    org_state_put "$sf" "" "" "$now" 0 true
  else
    body=$(tr -d '\r' <<<"$out" | awk 'b { print; exit } /^$/ { b = 1 }')
    [ -n "$status" ] || { [ "$rc" -ne 0 ] || status=200; }
    if [ "$status" = 200 ] && [[ $body =~ ^[0-9a-f]{40}$ ]]; then
      sha=$body
      etag=$(tr -d '\r' <<<"$out" | sed -n 's/^[Ee][Tt][Aa][Gg]: *//p' | head -n 1)
      cfg=$dir/$sha/$key.json
      if [ -f "$cfg" ]; then
        org_state_put "$sf" "$sha" "$etag" "$now" 0 false
      else
        mkdir -p "$dir/$sha"
        if body=$(gh_bound api "repos/$owner/$repo/contents/$path/config.json?ref=$sha" --jq .content 2>"$err"); then
          body=$(base64 -d <<<"$body" 2>/dev/null) || body=""
          if ! jq -e 'type == "object"' <<<"$body" >/dev/null 2>&1; then
            echo "org layer: $owner/$repo/$path/config.json is not a JSON object, ignored" >&2
            body='{}'
          fi
          printf '%s\n' "$body" >"$cfg.tmp.$$" && mv "$cfg.tmp.$$" "$cfg"
          org_state_put "$sf" "$sha" "$etag" "$now" 0 false
        elif grep -q 'HTTP 404' "$err"; then
          printf '{}\n' >"$cfg"
          org_state_put "$sf" "$sha" "$etag" "$now" 0 true
        else
          sha=""
        fi
      fi
    else
      sha=""
    fi
    if [ -z "$sha" ]; then
      org_state_put "$sf" "$old_sha" "$old_etag" "$checked" "$now" false
      if [ -n "$old_sha" ] && [ -f "$dir/$old_sha/$key.json" ]; then
        echo "org layer: cached ${old_sha:0:7}, $(org_age $((now - checked)))" >&2
      else
        echo "org layer: $owner/$repo unreachable and no cached copy, empty layer" >&2
      fi
    fi
  fi
  rm -f "$err"
}

# The organization layer of this clone as one JSON object {sha, source, config}, nothing when there is none (no GitHub
# origin, org.inherit false, no repository or directory, unreachable with no copy). $1 and $2 are the texts of the
# repository and local layers: org.inherit, org.repo, org.path and org.ref are read from these two only, and an `org` key
# of the organization's own config.json is dropped.
org_layer_read() { # repository-layer-text local-layer-text
  local owner settings repo path ref key root dir sf now ttl checked=0 failed=0 missing=false sha="" cfg
  owner=$(org_owner)
  [ -n "$owner" ] || return 0
  settings=$(printf '%s\n%s\n' "$1" "${2:-}" | jq -sc '[.[] | select(type == "object") | .org? // empty | select(type == "object")] | add // {}' 2>/dev/null) ||
    settings='{}'
  [ "$(jq -r '.inherit' <<<"$settings")" != false ] || return 0
  repo=$(jq -r '.repo | if type == "string" and . != "" then . else ".github" end' <<<"$settings")
  path=$(jq -r '.path | if type == "string" and . != "" then . else "senior-mode" end' <<<"$settings")
  ref=$(jq -r '.ref | if type == "string" then . else "" end' <<<"$settings")
  [[ $repo =~ ^[A-Za-z0-9._-]+$ ]] && [[ $path =~ ^[A-Za-z0-9._/-]+$ && $path != *..* && $path != /* ]] &&
    { [ -z "$ref" ] || { [[ $ref =~ ^[A-Za-z0-9._/-]+$ ]] && [[ $ref != *..* ]]; }; } || return 0
  key=$(sha256 "$repo|$path|$ref" | cut -c1-12)
  root=${XDG_CACHE_HOME:-$HOME/.cache}/senior-mode/org
  dir=$root/$owner
  sf=$dir/state-$key.json
  now=$(date +%s)
  ttl=$ORG_TTL
  [ -z "${SERVE_DIR:-}" ] || ttl=$ORG_TTL_SERVE
  if [ -f "$sf" ]; then
    read -r checked failed missing < <(jq -r '[(.checkedAt // 0), (.failedAt // 0), (.missing // false)] | join(" ")' "$sf" 2>/dev/null) || true
    [ "$missing" != true ] || ttl=$ORG_TTL_MISSING
  fi
  if { [ "$checked" -eq 0 ] || [ $((now - checked)) -ge "$ttl" ]; } && { [ "$failed" -eq 0 ] || [ $((now - failed)) -ge "$ORG_RETRY" ]; }; then
    org_sync "$owner" "$repo" "$path" "$ref" "$sf" "$dir" "$key"
  fi
  [ -f "$sf" ] || return 0
  read -r sha missing < <(jq -r '[(.sha // "-"), (.missing // false)] | join(" ")' "$sf" 2>/dev/null) || true
  [ "$missing" != true ] && [ -n "$sha" ] && [ "$sha" != - ] || return 0
  cfg=$dir/$sha/$key.json
  [ -f "$cfg" ] || return 0
  jq -c --arg s "$sha" --arg src "organization $owner/$repo/$path@${sha:0:7}" \
    '{sha: $s, source: $src, config: (if type == "object" then del(.org) else {} end)}' "$cfg" 2>/dev/null || return 0
}

# The organization layer of this clone, as JSON ({} when there is none): the file
# <git common dir>/senior-mode/organization.json when a machine keeps one, else the organization's repository.
org_layer() {
  local common file text="" loc="" got
  common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || { echo '{}'; return 0; }
  file=$common/senior-mode/organization.json
  if [ -e "$file" ]; then
    jq -c 'if type == "object" then . else {} end' "$file" 2>/dev/null || echo '{}'
    return 0
  fi
  text=$(config_repo_text 2>/dev/null) || text=""
  loc=$(cat "$(dirname "$common")/.claude/senior-mode.local.json" 2>/dev/null) || loc=""
  got=$(org_layer_read "$text" "$loc") || got=""
  [ -n "$got" ] || { echo '{}'; return 0; }
  jq -c '.config' <<<"$got"
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
