# UI pull requests and their screenshots (epic #389, spec §4, ADR 0025). Definitions only.
# A pull request is a UI pull request when its diff touches a glob of `ui.paths`, or when the ticket it closes
# carries the label `ui`. A project with neither has no UI tickets.

# The globs of `ui.paths` as JSON, [] when the project sets none.
ui_globs() {
  config_effective 2>/dev/null | jq -c '.ui.paths // []' 2>/dev/null || echo '[]'
}

# The open pull request that contains the commit $1, as JSON {number, branch, labels}, the labels of the tickets it
# closes included; fails when there is none.
# shellcheck disable=SC2016 # a GraphQL query, not shell
UI_ASSOC_QUERY='query($owner: String!, $name: String!, $sha: GitObjectID!) { repository(owner: $owner, name: $name) {
  object(oid: $sha) { ... on Commit { associatedPullRequests(first: 10) { nodes { number state headRefName
    closingIssuesReferences(first: 20) { nodes { labels(first: 30) { nodes { name } } } } } } } } } }'
ui_assoc() {
  local slug
  slug=$(repo_slug) || return 1
  jq -nc --arg q "$UI_ASSOC_QUERY" --arg o "${slug%%/*}" --arg n "${slug#*/}" --arg s "$1" \
    '{query: $q, variables: {owner: $o, name: $n, sha: $s}}' | gh_retry api graphql --input - |
    jq -ce '[.data.repository.object.associatedPullRequests.nodes[]? | select(.state == "OPEN")][0] | select(. != null)
      | {number, branch: .headRefName, labels: ([.closingIssuesReferences.nodes[]?.labels.nodes[]?.name] | unique)}'
}

# `ui_pr [<sha> [<base>]]`: whether the pull request that ends at the commit (default HEAD) is a UI pull request:
# the diff with the base (default: the default branch) touches a glob of `ui.paths`, or its ticket is labelled `ui`.
# The diff decides, never a prediction. Exit 0 and the reason on stdout when it is, 1 when it is not.
ui_pr() {
  local sha=${1:-HEAD} base=${2:-} globs files hit labels
  globs=$(ui_globs)
  if [ "$globs" != "[]" ]; then
    [ -n "$base" ] || base=$(default_branch) || return 1
    files=$(git -c core.quotePath=false diff --name-only --no-renames "$base...$sha") || return 1
    hit=$(protected_match "$globs" <<<"$files" | head -n 1) || true
    [ -z "$hit" ] || {
      echo "the diff touches $hit"
      return 0
    }
  fi
  labels=$(ui_assoc "$(git rev-parse "$sha^{commit}")" 2>/dev/null | jq -r '.labels[]') || labels=""
  if grep -qx ui <<<"$labels"; then
    echo "the ticket is labelled ui"
    return 0
  fi
  return 1
}

# `{{pr}}`, `{{branch}}`, `{{sha}}` and `{{slug}}` (the branch in lower case, anything but letters and digits as -) of
# the template $1 for the pull request $2 of the branch $3 at the commit $4.
preview_expand() {
  local t=$1 slug
  slug=$(tr '[:upper:]' '[:lower:]' <<<"$3" | sed 's/[^a-z0-9]\{1,\}/-/g; s/^-//; s/-$//')
  t=${t//\{\{pr\}\}/$2}
  t=${t//\{\{branch\}\}/$3}
  t=${t//\{\{sha\}\}/$4}
  printf '%s\n' "${t//\{\{slug\}\}/$slug}"
}

# The `environment_url` of a successful GitHub deployment status on the commit $1, nothing when there is none.
preview_deployed() {
  local slug id url
  slug=$(repo_slug) || return 0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    url=$(gh_retry api "repos/$slug/deployments/$id/statuses" \
      --jq '[.[] | select(.state == "success" and (.environment_url // "") != "") | .environment_url][0] // empty') || continue
    [ -z "$url" ] || {
      printf '%s\n' "$url"
      return 0
    }
  done < <(gh_retry api "repos/$slug/deployments?sha=$1" --jq '.[].id' 2>/dev/null)
  return 0
}

# The line of the preview comment for the pull request $2 of the branch $3 at the commit $1: `Preview: <url>`
# or `No preview: <reason>`. Sources, the first that answers: `preview.url` (a template), then the `environment_url` of
# a successful deployment status on the commit, polled every SENIOR_MODE_PREVIEW_POLL seconds (15) for
# `preview.waitSeconds` (300). A URL is shown only when one `curl` of it succeeds (2xx or 3xx).
preview_line() {
  local sha=$1 pr=$2 branch=$3 cfg tpl wait poll waited=0 url=""
  cfg=$(config_effective 2>/dev/null) || cfg='{}'
  tpl=$(jq -r '.preview.url // empty' <<<"$cfg")
  wait=$(jq -r '.preview.waitSeconds // 300' <<<"$cfg")
  poll=${SENIOR_MODE_PREVIEW_POLL:-15}
  if [ -n "$tpl" ]; then
    url=$(preview_expand "$tpl" "$pr" "$branch" "$sha")
  else
    # Nothing is configured when there is no `preview` key and the project does not deploy previews on `ready`.
    if ! jq -e '(.preview != null) or (.deploy.previews == "ready")' <<<"$cfg" >/dev/null; then
      echo "No preview: not configured"
      return 0
    fi
    while :; do
      url=$(preview_deployed "$sha")
      [ -z "$url" ] || break
      [ "$waited" -lt "$wait" ] || break
      sleep "$poll"
      waited=$((waited + poll))
    done
    [ -n "$url" ] || {
      echo "No preview: not deployed within $wait s"
      return 0
    }
  fi
  if curl -fsS --max-time 10 -o /dev/null "$url" 2>/dev/null; then
    echo "Preview: $url"
  else
    echo "No preview: the preview URL did not answer with a 2xx or 3xx status"
  fi
}

# Sets the one comment of the pull request $2 that carries the marker, in place: created the first time, edited after.
PREVIEW_MARKER='<!-- senior-mode:preview -->'
preview_comment() { # sha pr line
  local slug id
  slug=$(repo_slug) || return 1
  id=$(gh_retry api "repos/$slug/issues/$2/comments" --paginate \
    --jq ".[] | select(.body | contains(\"$PREVIEW_MARKER\")) | .id") || return 1
  id=${id%%$'\n'*}
  if [ -n "$id" ]; then
    gh_retry api -X PATCH "repos/$slug/issues/comments/$id" -f body="$PREVIEW_MARKER
$3" >/dev/null
  else
    gh_retry api "repos/$slug/issues/$2/comments" -f body="$PREVIEW_MARKER
$3" >/dev/null
  fi
}

# What `publish` says of a commit once its statuses are set: one line when it is a UI pull request, and its preview
# comment, kept up to date after each push. A pull request that is not UI gets no comment.
ui_report() {
  local why info pr
  why=$(ui_pr "$1") || return 0
  echo "ui: UI pull request ($why)"
  info=$(ui_assoc "$(git rev-parse "$1^{commit}")" 2>/dev/null) || {
    echo "ui: no open pull request for this commit, no preview comment" >&2
    return 0
  }
  pr=$(jq -r '.number' <<<"$info")
  preview_comment "$1" "$pr" "$(preview_line "$(git rev-parse "$1^{commit}")" "$pr" "$(jq -r '.branch' <<<"$info")")" ||
    echo "ui: could not write the preview comment" >&2
  return 0
}

# Whether the ticket $1 (an item of ready_items) is predicted to be a UI ticket: it is labelled `ui`, or a glob of
# its Paths may reach one of the globs $2 of `ui.paths`. The diff decides at `publish`.
ui_predicted() {
  local p
  ! jq -e '.labels | index("ui")' <<<"$1" >/dev/null || return 0
  [ "$2" != "[]" ] || return 1
  while IFS= read -r p; do
    ! ready_in_zone "$2" "$p" || return 0
  done < <(jq -r '.paths[]' <<<"$1")
  return 1
}
