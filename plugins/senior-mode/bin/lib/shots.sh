# UI pull requests and their screenshots (epic #389, spec §4, ADR 0025). Definitions only.
# A pull request is a UI pull request when its diff touches a glob of `ui.paths`, or when the ticket it closes
# carries the label `ui`. A project with neither has no UI tickets.

# The globs of `ui.paths` as JSON, [] when the project sets none.
ui_globs() {
  config_effective 2>/dev/null | jq -c '.ui.paths // []' 2>/dev/null || echo '[]'
}

# The labels, one a line, of the tickets the open pull request that contains the commit $1 closes.
# shellcheck disable=SC2016 # a GraphQL query, not shell
UI_LABELS_QUERY='query($owner: String!, $name: String!, $sha: GitObjectID!) { repository(owner: $owner, name: $name) {
  object(oid: $sha) { ... on Commit { associatedPullRequests(first: 10) { nodes { state
    closingIssuesReferences(first: 20) { nodes { labels(first: 30) { nodes { name } } } } } } } } } }'
ui_labels() {
  local slug
  slug=$(repo_slug) || return 1
  jq -nc --arg q "$UI_LABELS_QUERY" --arg o "${slug%%/*}" --arg n "${slug#*/}" --arg s "$1" \
    '{query: $q, variables: {owner: $o, name: $n, sha: $s}}' | gh_retry api graphql --input - |
    jq -r '[.data.repository.object.associatedPullRequests.nodes[]? | select(.state == "OPEN")
      | .closingIssuesReferences.nodes[]?.labels.nodes[]?.name] | unique | .[]'
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
  labels=$(ui_labels "$(git rev-parse "$sha^{commit}")" 2>/dev/null) || labels=""
  if grep -qx ui <<<"$labels"; then
    echo "the ticket is labelled ui"
    return 0
  fi
  return 1
}

# What `publish` says of a commit once its statuses are set: one line when it is a UI pull request.
ui_report() {
  local why
  ! why=$(ui_pr "$1") || echo "ui: UI pull request ($why)"
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
