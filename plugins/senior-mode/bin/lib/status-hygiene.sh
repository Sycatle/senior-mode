# shellcheck shell=bash
# The repository hygiene (#226), from a board_data result (whole lists of open pull requests and branches):
# - stale: open pull requests with no activity for $days days;
# - branches: remote branches with no pull request at all, leaving out the default branch, a branch that
#   an open pull request targets and a protected one; `ticket` says it is named like a ticket branch;
# - superseded: open pull requests that another one claims with a line starting "Supersedes #12". `act`
#   says it may be closed: the claimant is not a draft nor from a fork, wrote #12 or may write here, and
#   neither is a claimant itself (two that claim each other: none); `why` says what stops it otherwise;
# - orphans: tickets In progress that show no life: no worktree ($trees maps a ticket to its worktree),
#   no open pull request, no branch (remote or in $locals), no activity for $days days (the issue, or its
#   board item: a Status change moves the item only);
#   a `Supersedes` line inside a fenced code block does not count.
# `hygiene_lines` words them.
# shellcheck disable=SC2016 # a jq program, not shell
HYGIENE_DEF="$BRANCH_DEF"'def prose: reduce (split("\n")[]) as $l ({f: false, out: []};
      if ($l | test("^\\s{0,3}(```|~~~)")) then .f |= not elif .f then . else .out += [$l] end) | .out[];
  def hygiene($days; $trees; $now; $locals):
    def age($t): ((($now | fromdateiso8601) - ($t | fromdateiso8601)) / 86400 | floor);
    . as $d | ($d.hygiene.prs // []) as $prs | $d.hygiene.base as $base | ([$prs[].base] | unique) as $bases
    | [$prs[] | . as $p | [(.body // "") | prose | capture("^supersedes\\s+#(?<m>[0-9]+)"; "i") | .m | tonumber]
        | unique[] | select(. != $p.number) | {m: ., by: $p.number}] as $claims
    | ($claims | map(.by) | unique) as $claimants
    | {base: $base, days: $days,
       stale: [$prs[] | select(.updatedAt != null and age(.updatedAt) >= $days) | {number, title, days: age(.updatedAt)}],
       branches: [$d.hygiene.branches[]? | select(.name != $base and .prs == 0 and (.protected | not) and (.name | IN($bases[]) | not))
         | {name, oid, age: (if .date then age(.date) else null end), ticket: (.name | test("^(feat|fix|chore|docs|test|refactor)/[0-9]+-"))}],
       superseded: ([$claims[] | . as $c | ($prs[] | select(.number == $c.m)) as $pm | ($prs[] | select(.number == $c.by)) as $pn
           | {number: $c.m, by: $c.by, title: $pm.title,
              why: (if ($claims | any(.m == $c.by and .by == $c.m)) then "they supersede each other"
                elif ($claimants | index($c.m)) != null then "supersedes another pull request itself"
                elif $pn.draft then "is a draft"
                elif $pn.fork then "comes from a fork"
                elif ($pn.author != null and $pn.author == $pm.author) or ($pn.association | IN("OWNER", "MEMBER", "COLLABORATOR")) then null
                else "is by someone who cannot write here" end)}
           | . + {act: (.why == null)}]
         | group_by(.number) | map(sort_by(.act | not)[0])),
       orphans: [$d.items[] | select(.open and .status == "In progress" and .updated != null and age(.updated) >= $days) | . as $i
         | select($trees[$i.number | tostring] == null)
         | select(([$prs[].branch] + [$d.hygiene.branches[]?.name] + $locals) | any(test(bre($i.number))) | not)
         | {number, title}]};
  def hygiene_lines: . as $h
    | [(.stale[] | "pull request #\(.number) \(.title): no activity for \(.days) days"),
       (.branches[] | "branch \(.name): no pull request"),
       (.superseded[] | "pull request #\(.number) \(.title): "
         + (if .act then "superseded by #\(.by), still open" else "#\(.by) says it supersedes it, but \(.why); not closed" end)),
       (.orphans[] | "#\(.number) \(.title): In progress with no worktree and no open pull request, no branch, no activity for \($h.days) days")];'

# `hygiene.days` as a positive whole number.
hygiene_days() {
  local days
  days=$(config_get hygiene.days)
  [[ $days =~ ^[1-9][0-9]*$ ]] || die "hygiene.days must be a positive whole number, not $days"
  printf '%s\n' "$days"
}

# The local branch names, as a JSON array.
local_branches() {
  git for-each-ref --format='%(refname:short)' refs/heads | jq -Rsc 'split("\n") | map(select(length > 0))' || echo '[]'
}

# The hygiene report as JSON. $1 board_data result, $2 the worktrees of the tickets (`ticket_trees`), $3 now,
# $4 the local branches (`local_branches`).
hygiene_report() {
  jq -c --argjson t "$2" --arg now "$3" --argjson days "$(hygiene_days)" --argjson l "$4" "$HYGIENE_DEF"'hygiene($days; $t; $now; $l)' <<<"$1"
}

# The worktrees of the tickets of the repository at $1 as a JSON object {"<issue>": "<path>"}.
ticket_trees() {
  ticket_worktrees "$1" | jq -Rsc 'split("\n") | map(select(length > 0) | capture("^(?<n>[0-9]+) (?<p>.*)$")) | map({(.n): .p}) | add // {}' ||
    echo '{}'
}

# A ref name as a URL path: each segment percent-encoded, the slashes kept (`fix#12` is not `fix`).
ref_path() {
  jq -rn --arg n "$1" '$n | split("/") | map(@uri) | join("/")'
}

# What a fresh read of an issue answers: its state, its last update and its board item (a Status change moves the
# item, not the issue).
# shellcheck disable=SC2016 # a GraphQL query, not shell
ORPHAN_QUERY='query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) { issue(number: $number) { state updatedAt projectItems(first: 20) { nodes {
    updatedAt project { id }
    fieldValues(first: 20) { nodes { ... on ProjectV2ItemFieldSingleSelectValue { name field { ... on ProjectV2FieldCommon { name } } } } } } } } }
}'
# Whether the ticket $2 of repository $1 still looks abandoned on a fresh read, for a repair at $3 days.
# Prints why not when it does not. The report may be minutes old, and a run on another machine leaves
# no worktree here: the board, the issue, the open pull requests and the branches are read again.
orphan_check() {
  local slug=$1 n=$2 days=$3 project answer live state status activity heads h
  project=$(jq -r '.project.id // empty' "$(config_file)")
  answer=$(jq -nc --arg q "$ORPHAN_QUERY" --arg o "${slug%%/*}" --arg n "${slug#*/}" --argjson i "$n" \
    '{query: $q, variables: {owner: $o, name: $n, number: $i}}' | gh_retry api graphql --input -) || { echo "could not read the issue"; return 1; }
  live=$(jq -r --arg p "$project" '.data.repository.issue as $i | [$i.projectItems.nodes[] | select(.project.id == $p)][0] as $m
    | [$i.state, ([$m.fieldValues.nodes[] | select(.field.name == "Status") | .name][0] // "empty"), ([$i.updatedAt, $m.updatedAt] | max)] | @tsv' <<<"$answer") ||
    { echo "could not read the issue"; return 1; }
  IFS=$'\t' read -r state status activity <<<"$live"
  [ "$status" = "In progress" ] || { echo "its Status is $status now"; return 1; }
  jq -ne --arg s "$state" --arg a "$activity" --argjson days "$days" --argjson now "$(date +%s)" \
    '$s == "OPEN" and ($now - ($a | fromdateiso8601)) / 86400 >= $days' >/dev/null || { echo "the issue or its Status changed since the report"; return 1; }
  ticket_trees "$(git rev-parse --show-toplevel)" | jq -e --arg n "$n" 'has($n) | not' >/dev/null || { echo "it has a worktree now"; return 1; }
  heads=$({ gh_retry pr list --state open --limit 1000 --json headRefName --jq '.[].headRefName' &&
    gh_retry api "repos/$slug/branches" --paginate --jq '.[].name' && git for-each-ref --format='%(refname:short)' refs/heads; }) ||
    { echo "could not read the pull requests and branches"; return 1; }
  ! { while IFS= read -r h; do [ "$(workflow_branch_issue "$h")" != "$n" ] || echo y; done <<<"$heads"; } | grep -q y ||
    { echo "a branch or a pull request exists now"; return 1; }
}

# The repairs of `status --fix` for the hygiene report ($1 is the status as JSON), one JSON line each:
# {kind, id, fixed, line}. Only what is safe:
# - a pull request that a trusted one supersedes (`act`) is closed with a comment;
# - a remote branch with no pull request is deleted when it is named like a ticket branch, its last commit is
#   older than hygiene.days, it is neither protected nor moved since the report, and it has no commit outside
#   the default branch (all read again just before);
# - a ticket In progress that looks abandoned goes back to Ready with a comment, after a fresh look at it.
# A stale pull request, and what is left for the reasons above, is only said. Fails when a repair failed.
status_hygiene_fix() {
  local slug base days entry n by name title age oid path fresh prot ahead why rc=0
  slug=$(repo_slug)
  base=$(jq -r '.hygiene.base // empty' <<<"$1")
  days=$(jq -r '.hygiene.days' <<<"$1")
  hy_line() { jq -nc --arg k "$1" --arg i "$2" --argjson f "$3" --arg l "$4" '{kind: $k, id: $i, fixed: $f, line: $l}'; }
  while IFS= read -r entry; do
    n=$(jq -r .number <<<"$entry") by=$(jq -r .by <<<"$entry") title=$(jq -r .title <<<"$entry")
    if gh pr close "$n" --comment "Superseded by #$by: its description says it supersedes this pull request." >/dev/null; then
      hy_line superseded "$n" true "fixed: pull request #$n $title: closed, superseded by #$by"
    else
      rc=1
      hy_line superseded "$n" false "not fixed: pull request #$n $title: could not close it"
    fi
  done < <(jq -c '.hygiene.superseded[] | select(.act)' <<<"$1")
  while IFS= read -r entry; do
    name=$(jq -r .name <<<"$entry") oid=$(jq -r '.oid // empty' <<<"$entry") age=$(jq -r '.age // empty' <<<"$entry")
    path=$(ref_path "$name")
    if [ "$(jq -r .ticket <<<"$entry")" != true ]; then
      hy_line branch "$name" false "left: branch $name: not a ticket branch (type/<issue>-...), a human decides"
    elif [ -z "$age" ] || [ "$age" -lt "$days" ]; then
      hy_line branch "$name" false "left: branch $name: last commit ${age:-unknown}d ago, less than hygiene.days ($days)"
    elif [ -z "$base" ] || [ -z "$oid" ]; then
      hy_line branch "$name" false "left: branch $name: no default branch or no head to check"
    elif ! fresh=$(gh_retry api "repos/$slug/branches/$path" --jq '[.protected, .commit.sha] | @tsv'); then
      rc=1
      hy_line branch "$name" false "not fixed: branch $name: could not read it"
    else
      prot=${fresh%%$'\t'*}
      if [ "$prot" != false ]; then
        hy_line branch "$name" false "left: branch $name: protected"
      elif [ "${fresh#*$'\t'}" != "$oid" ]; then
        hy_line branch "$name" false "left: branch $name: moved since the report"
      elif ! ahead=$(gh_retry api "repos/$slug/compare/$base...$path" --jq .ahead_by); then
        rc=1
        hy_line branch "$name" false "not fixed: branch $name: could not compare it with $base"
      elif [ "$ahead" != 0 ]; then
        hy_line branch "$name" false "left: branch $name: $ahead commits outside $base; a human decides whether to open a pull request or delete it"
      elif gh api -X DELETE "repos/$slug/git/refs/heads/$path" >/dev/null; then
        hy_line branch "$name" true "fixed: branch $name: deleted, no commit outside $base"
      else
        rc=1
        hy_line branch "$name" false "not fixed: branch $name: could not delete it"
      fi
    fi
  done < <(jq -c '.hygiene.branches[]' <<<"$1")
  while IFS= read -r entry; do
    n=$(jq -r .number <<<"$entry") title=$(jq -r .title <<<"$entry")
    if ! why=$(orphan_check "$slug" "$n" "$days"); then
      hy_line orphan "$n" false "left: #$n $title: $why; a human decides"
    elif (item_set "$n" Status Ready) >/dev/null &&
      gh issue comment "$n" --body "Moved back to Ready by \`senior-mode status --fix\`: it was In progress with no worktree, no open pull request, no branch and no activity for $days days." >/dev/null; then
      hy_line orphan "$n" true "fixed: #$n $title: moved back to Ready"
    else
      rc=1
      hy_line orphan "$n" false "not fixed: #$n $title: could not move it back to Ready"
    fi
  done < <(jq -c '.hygiene.orphans[]' <<<"$1")
  while IFS= read -r entry; do
    n=$(jq -r .number <<<"$entry") title=$(jq -r .title <<<"$entry")
    hy_line stale "$n" false "left: pull request #$n $title: stale, a human decides whether to resume or close it"
  done < <(jq -c '(.hygiene.superseded | map(select(.act) | .number)) as $s | .hygiene.stale[] | select(.number | IN($s[]) | not)' <<<"$1")
  return "$rc"
}
