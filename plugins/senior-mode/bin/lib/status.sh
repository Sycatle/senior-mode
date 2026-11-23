# shellcheck shell=bash
# What a session needs at start (SessionStart hook, spec 0001 §15): a short router and, on a ticket
# branch <type>/<issue>-<slug>, the ticket, its Status, its spec and acceptance criteria. Never fails.
context() {
  local root branch issue json spec status criteria
  cat <<'ROUTER'
senior-mode is active: framing, specs and ADRs, test-driven delivery, atomic Conventional Commits, GitHub Project board.
The user needs /senior-mode:frame, /senior-mode:go and /senior-mode:status; "go" or "enchaîne" runs /senior-mode:go. Disciplines load by themselves; ask the scout agent for codebase facts.
A secret seen by accident in a tool output is never repeated in a reply, a file, a commit, an issue or a pull request: report it so a human rotates it.
ROUTER
  # Spec 0001 §10, "Sessions without a human": the one rule, stated where a run session starts.
  [ -z "${SENIOR_MODE_RUN:-}" ] || echo "Unattended run: nobody answers questions. Take the recommended option for reversible choices; never accept an L spec or an ADR, never touch a protected zone: label needs-human and stop with a report."
  root=$(git rev-parse --show-toplevel 2>/dev/null) || return 0
  if [ ! -f "$root/.claude/senior-mode.json" ]; then
    echo "This repository is not set up for senior-mode; /senior-mode:setup adopts it."
    return 0
  fi
  overrides_context || true
  branch=$(git symbolic-ref --short -q HEAD) || return 0
  issue=$(sed -nE 's#^[a-z]+/([0-9]+)-.*#\1#p' <<<"$branch")
  [ -n "$issue" ] || return 0
  echo
  if ! json=$(gh issue view "$issue" --json number,title,state,body,projectItems 2>/dev/null); then
    echo "Current ticket: #$issue, branch $branch; details not loaded (GitHub unreachable)."
    return 0
  fi
  jq -r --arg b "$branch" '"Current ticket: #\(.number) \(.title) (\(.state | ascii_downcase), Status: \(.projectItems[0].status.name // "not on the board")), branch \($b)"' <<<"$json"
  spec=$(jq -r .body <<<"$json" | grep -oE 'docs/specs/[A-Za-z0-9._-]+\.md' | head -1) || true
  if [ -n "$spec" ]; then
    status=$(sed -nE 's/^status: *//p' "$root/$spec" 2>/dev/null | head -1) || true
    echo "Spec: $spec (${status:-file not found})"
  fi
  criteria=$(jq -r .body <<<"$json" | awk '/^## / { on = /Acceptance criteria/; next } on && /^- /' |
    head -6 | cut -c1-200)
  [ -z "$criteria" ] || printf 'Acceptance criteria:\n%s\n' "$criteria"
}

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
HYGIENE_DEF='def prose: reduce (split("\n")[]) as $l ({f: false, out: []};
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
         | select(([$prs[].branch] + [$d.hygiene.branches[]?.name] + $locals) | any(test("^[a-z]+/\($i.number)(-|$)")) | not)
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

# The drift of the board: tickets whose Status says something their issue does not (closed but not Done, open
# but Done, In progress or In review with no branch and no open pull request). $locals the local branch names.
# shellcheck disable=SC2016 # a jq program, not shell
DRIFT_DEF='def drift($d; $locals): $d.items as $items
  | ([$items[] | select((.open | not) and .status != "Done")
      | {number, title, kind: "closed", why: "closed but \(.status // "without a Status")"}]
    + [$items[] | select(.open and .status == "Done") | {number, title, kind: "open-done", why: "open but Done"}]
    + [$items[] | select(.open and (.status | IN("In progress", "In review"))) | . as $i
      | select([$d.hygiene.prs[].branch, $d.hygiene.branches[].name, $locals[]] | any(test("^[a-z]+/\($i.number)(-|$)")) | not)
      | {number, title, kind: "stale", why: "\(.status) with no open pull request and no branch"}]);'

# The dashboard as JSON, from board_data; $1 is the start of the period, $2 now, $3 the repository, $locals the
# local branch names.
# shellcheck disable=SC2016 # a jq program, not shell
STATUS_JQ='. as $d | $d.items as $items | {
  repository: $repo, generatedAt: $now, since: $since,
  done: [$d.closed[] | select(.closedAt >= $since and .reason != "NOT_PLANNED") | {number, title, closedAt}] | sort_by(.closedAt) | reverse,
  mergedPullRequests: ([$d.merged[] | select(.mergedAt >= $since)] | length),
  inProgress: [$items[] | select(.open and .status == "In progress") | {number, title}],
  inReview: [$items[] | select(.open and .status == "In review") | . as $i
    | {number, title, pr: ([$d.prs[] | select(.branch | test("^[a-z]+/\($i.number)-")) | .number][0])}],
  blocked: [$items[] | select(.open) | ([
      (if (.labels | index("blocked")) then "blocked" else empty end),
      (if (.labels | index("needs-info")) then "needs information" else empty end),
      (if (.blockers | length) > 0 and (.status | IN("Ready", "In progress", "In review"))
        then "waits for " + (.blockers | map("#\(.)") | join(", ")) else empty end)]) as $r
    | select($r | length > 0) | {number, title, reasons: $r}],
  waiting: (([$d.prs[] | select(.labels | index("needs-human")) | {kind: "pull request", number, title, why: "needs a human decision"}]
      + [$d.prs[] | select(.failing | length > 0) | {kind: "pull request", number, title, why: ("failing: " + (.failing | join(", ")))}]
      + [$items[] | select(.open and (.labels | index("needs-human"))) | {kind: "ticket", number, title, why: "needs a human decision"}])
    | group_by([.kind, .number]) | map(.[0] + {why: (map(.why) | join("; "))})),
  drift: drift($d; $locals),
  wip: {limit: $wip, count: ([$items[] | select(.open and .status == "In progress")] | length)},
  audit: $audit,
  process: $process,
  next: ($d | pick | .[:3] | map({number, title, priority, size, milestone})),
  release: {latest: $d.release, pr: ([$d.prs[] | select(.branch | startswith("release-please")) | {number, title}][0])}
}'

# The same, in plain words; $head says which period it covers.
# shellcheck disable=SC2016 # a jq program, not shell
STATUS_TEXT_JQ='def sec($h; $ls): $h, (if ($ls | length) == 0 then "  nothing" else ($ls[] | "  " + .) end);
  def ticket: "#\(.number) \(.title)";
  "senior-mode · \(.repository) · \(.generatedAt)", "",
  sec("\($head) (\(.done | length))"; [.done[] | ticket] + (if .mergedPullRequests > 0
    then ["\(.mergedPullRequests) pull request\(if .mergedPullRequests > 1 then "s" else "" end) merged"] else [] end)),
  sec("In progress (\(.inProgress | length)\(if .wip.count > .wip.limit then ", over the limit of \(.wip.limit)" else "" end))";
    [.inProgress[] | ticket + (if .worktree then " (worktree \(.worktree))" else "" end)]),
  sec("In review (\(.inReview | length))"; [.inReview[] | ticket + (if .pr then " (pull request #\(.pr))" else "" end)]),
  sec("Blocked or missing information (\(.blocked | length))"; [.blocked[] | ticket + ": " + (.reasons | join(", "))]),
  sec("Waiting for a human (\(.waiting | length))"; [.waiting[] | "\(.kind) #\(.number) \(.title): \(.why)"]),
  (if (.drift | length) > 0 then sec("Board drift (\(.drift | length))"; [.drift[] | ticket + ": " + .why]) else empty end),
  (if (.hygiene | hygiene_lines | length) > 0 then sec("Hygiene (\(.hygiene | hygiene_lines | length))"; .hygiene | hygiene_lines) else empty end),
  (if ((.specDrift // []) | length) > 0 then sec("Spec drift (\(.specDrift | length))"; [.specDrift[]
    | "\(.spec): \(.commits | length) \(if (.commits | length) == 1 then "commit" else "commits" end) under its paths since it last changed, with no Spec-Unchanged",
      (.commits[:5][] | "  \(.sha) \(.subject)"),
      (if (.commits | length) > 5 then "  ... and \((.commits | length) - 5) more" else empty end)]) else empty end),
  (if .specDriftNote then "Spec drift: not checked (\(.specDriftNote))" else empty end),
  (if .audit then empty else "Dependency audit: off (audit: false)" end),
  (if .process.profile != "strict" then "Process profile: \(.process.profile)" else empty end),
  (.process.lifted[]? | "WARNING locked gate lifted: \(.rule) (profile \(.profile), \(.adr))"),
  (.process.problems[]? | "WARNING process refused: \(.)"),
  sec("Next Ready"; [.next[] | "#\(.number) \(.priority // "no priority") · \(.size // "?") · \(.title)"
    + (if .milestone then " (\(.milestone))" else "" end)]),
  "Release",
  (if .release.latest then "  Last release \(.release.latest.tag), \(.release.latest.date[:10])." else "  No release yet." end)
    + (if .release.pr then " Release pull request #\(.release.pr.number) is open." else " No release pull request open." end),
  (if .serve.running then "Daemon: serve is running (pid \(.serve.pid))" else empty end),
  (if .retro.due then "Retro due: the last one was \(.retro.lastDays) days ago" else empty end)'

# The repairs of `status --fix`, one JSON line per drift entry: {number, title, fixed, line}. Only a
# closed ticket is set Done; what else drifted needs a human's judgement and is left, saying why.
# Fails when a repair failed.
status_fix() {
  local entry n title kind why rc=0
  while IFS= read -r entry; do
    n=$(jq -r .number <<<"$entry") title=$(jq -r .title <<<"$entry") kind=$(jq -r .kind <<<"$entry")
    why=$(jq -r .why <<<"$entry")
    case $kind in
      closed)
        if (item_set "$n" Status Done) >/dev/null; then
          jq -nc --argjson n "$n" --arg t "$title" '{number: $n, title: $t, fixed: true,
            line: "fixed: #\($n) \($t): closed, Status set to Done"}'
        else
          rc=1
          jq -nc --argjson n "$n" --arg t "$title" '{number: $n, title: $t, fixed: false,
            line: "not fixed: #\($n) \($t): could not set the Status Done"}'
        fi
        ;;
      open-done)
        jq -nc --argjson n "$n" --arg t "$title" --arg w "$why" '{number: $n, title: $t, fixed: false,
          line: "left: #\($n) \($t): \($w); a human decides whether it is finished (close it) or not (move it back)"}' ;;
      *)
        jq -nc --argjson n "$n" --arg t "$title" --arg w "$why" '{number: $n, title: $t, fixed: false,
          line: "left: #\($n) \($t): \($w); a human decides whether to resume it or move it back to Ready"}' ;;
    esac
  done < <(jq -c '.drift[]' <<<"$1")
  return "$rc"
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
  local slug=$1 n=$2 days=$3 project answer live state status activity heads
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
  ! grep -Eq "^[a-z]+/$n(-|\$)" <<<"$heads" || { echo "a branch or a pull request exists now"; return 1; }
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

# The Iteration field of the Project (#180) as JSON {id, duration, iterations: [{id, title, startDate, duration}]}, the
# completed iterations too, by start date; nothing when the Project has no Iteration field.
# shellcheck disable=SC2016 # a GraphQL query, not shell
iteration_field() {
  local project res
  project=$(jq -r '.project.id // empty' "$(config_file)")
  [ -n "$project" ] || die "no Project in .claude/senior-mode.json; run /senior-mode:setup"
  res=$(jq -nc --arg id "$project" '{variables: {id: $id}, query: "query($id: ID!) { node(id: $id) { ... on ProjectV2 {
    field(name: \"Iteration\") { ... on ProjectV2IterationField { id configuration { duration
    iterations { id title startDate duration } completedIterations { id title startDate duration } } } } } } }"}' |
    gh_retry api graphql --input -) || return 1
  jq -c '.data.node.field // empty | select(.id) | {id, duration: .configuration.duration,
    iterations: ((.configuration.completedIterations + .configuration.iterations) | sort_by(.startDate))}' <<<"$res"
}

# The iteration named $1, or `current` (the one that holds today), as a tab-separated line: id, title, first day, the
# day after its last and its last day. Fails when there is none or the board has no Iteration field.
iteration_find() {
  local field
  field=$(iteration_field) && [ -n "$field" ] || return 1
  jq -r --arg n "$1" --arg today "$(date -u +%Y-%m-%d)" '.iterations[]
    | . + {end: ((.startDate + "T00:00:00Z" | fromdateiso8601) + .duration * 86400 | strftime("%Y-%m-%d"))}
    | select(if $n == "current" then .startDate <= $today and $today < .end else .title == $n end)
    | [.id, .title, .startDate, .end, ((.end + "T00:00:00Z" | fromdateiso8601) - 86400 | strftime("%Y-%m-%d"))] | @tsv' <<<"$field" | head -n 1 | grep .
}

# Whether the board has the fields of the cycle (#180): Iteration, Start and End cached in the config.
cycle_fields() {
  jq -e '.project.fields | (.Iteration.iteration == true) and (.Start.date == true) and (.End.date == true)' "$(config_file)" >/dev/null 2>&1
}

# A ticket starts (#180): it gets the current iteration and Start today. Best effort and silent on a board with no
# cycle fields (a config from before them): the Status is already set.
cycle_start() {
  cycle_fields || return 0
  if ! iteration_find current >/dev/null; then
    echo "senior-mode: no iteration holds today; extend the Iteration field in the Project settings. Start is set, the iteration is not" >&2
    (item_set "$1" Start "$(date -u +%Y-%m-%d)") >/dev/null || echo "senior-mode: could not set Start on #$1" >&2
  else
    (item_set "$1" Iteration current Start "$(date -u +%Y-%m-%d)") >/dev/null || echo "senior-mode: could not set the iteration and Start on #$1" >&2
  fi
}

# A ticket is merged (#180): End is today. Best effort, silent on a board with no cycle fields.
cycle_end() {
  cycle_fields || return 0
  (item_set "$1" End "$(date -u +%Y-%m-%d)") >/dev/null || echo "senior-mode: could not set End on #$1" >&2
}

# Archives the items that are Done and whose issue closed more than board.archiveAfterDays days ago (#179), and lists
# them; $1 is a board_data result. An open item, an item that is not Done and an archived one are never touched.
# One that cannot be archived is said and left for the next time.
# shellcheck disable=SC2016 # a GraphQL query, not shell
board_archive() {
  local days project cutoff entry n title id
  days=$(config_get board.archiveAfterDays)
  [[ $days =~ ^[1-9][0-9]*$ ]] || die "board.archiveAfterDays must be a positive whole number, not $days"
  project=$(jq -r '.project.id // empty' "$(config_file)")
  cutoff=$(iso_time $(($(date +%s) - days * 86400)))
  while IFS= read -r entry; do
    n=$(jq -r .number <<<"$entry") title=$(jq -r .title <<<"$entry") id=$(jq -r .itemId <<<"$entry")
    if jq -nc --arg p "$project" --arg i "$id" '{variables: {project: $p, item: $i}, query: "mutation($project: ID!, $item: ID!) {
      archiveProjectV2Item(input: {projectId: $project, itemId: $item}) { item { id } } }"}' | gh_retry api graphql --input - >/dev/null; then
      echo "Archived: #$n $title (Done, closed more than $days days ago)"
    else
      echo "senior-mode: could not archive #$n" >&2
    fi
  done < <(jq -c --arg c "$cutoff" '.items[] | select(.status == "Done" and (.open | not) and (.archived | not) and .itemId != null
    and .closedAt != null and .closedAt < $c)' <<<"$1")
}

# Posts a Project status update (#155, #177): body $1 and, when given, its status $2 (ON_TRACK, AT_RISK or OFF_TRACK), start date
# $3 and target date $4 (YYYY-MM-DD). Fails unless GitHub answers with the id of the update. Shared by `status --publish`,
# `retro` and the daily digest of serve.
# shellcheck disable=SC2016 # a GraphQL query, not shell
project_post_update() {
  local project res
  project=$(jq -r '.project.id // empty' "$(config_file)")
  [ -n "$project" ] || return 1
  res=$(jq -nc --arg p "$project" --arg b "${1:0:60000}" --arg s "${2:-}" --arg a "${3:-}" --arg t "${4:-}" '{query: "mutation($project: ID!, $body: String!,
      $status: ProjectV2StatusUpdateStatus, $start: Date, $target: Date) { createProjectV2StatusUpdate(input: {projectId: $project, body: $body,
      status: $status, startDate: $start, targetDate: $target}) { statusUpdate { id } } }",
      variables: ({project: $p, body: $b} + (if $s == "" then {} else {status: $s} end)
        + (if $a == "" then {} else {start: $a} end) + (if $t == "" then {} else {target: $t} end))}' | gh_retry api graphql --input -) &&
    jq -e '.data.createProjectV2StatusUpdate.statusUpdate.id' <<<"$res" >/dev/null 2>&1
}

# When each open ticket labelled needs-human got the label (#177): the time of the last `labeled` event of its timeline, as
# {"<number>": "<time>"}. $1 is a board_data result. Fails when GitHub does not answer.
# shellcheck disable=SC2016 # a GraphQL query, not shell
health_needs_human() {
  local nums slug query="" n res
  nums=$(jq -r '.items[] | select(.open and (.archived | not) and (.labels | index("needs-human"))) | .number' <<<"$1")
  if [ -z "$nums" ]; then
    echo '{}'
    return 0
  fi
  slug=$(repo_slug)
  for n in $nums; do
    query+="i$n: issue(number: $n) { timelineItems(last: 50, itemTypes: [LABELED_EVENT]) { nodes { ... on LabeledEvent { createdAt label { name } } } } } "
  done
  res=$(jq -nc --arg q "query(\$owner: String!, \$name: String!) { repository(owner: \$owner, name: \$name) { $query} }" --arg o "${slug%%/*}" --arg n "${slug#*/}" \
    '{query: $q, variables: {owner: $o, name: $n}}' | gh_retry api graphql --input -) || return 1
  jq -ec '(.data.repository // error("no repository")) | with_entries(select(.value != null)
    | {key: (.key | ltrimstr("i")), value: ([.value.timelineItems.nodes[] | select(.label.name == "needs-human") | .createdAt] | max)}
    | select(.value != null))' <<<"$res"
}

# The health of the Project (#177) from a board_data result, $drift (the board drift as JSON), $nh (health_needs_human) and
# $now. Off track when an open milestone is past due with open issues; at risk when an open issue has carried needs-human
# for more than 24 hours, an open pull request fails its checks or there is drift; on track otherwise. The target date is
# the earliest due date of an open milestone, if any; the body names the rule that decided.
# shellcheck disable=SC2016 # a jq program, not shell
HEALTH_JQ='def plural($n; $w): "\($n) \($w)\(if $n == 1 then "" else "s" end)";
  . as $d | ($d.items | map(select(.archived | not))) as $items | ($now | fromdateiso8601) as $t
  | [$items[] | select(.open and .milestone != null and .due != null)] as $dated
  | [$dated[] | select(.due < $now)] as $late
  | ($late | sort_by(.due) | group_by(.milestone) | map({milestone: .[0].milestone, due: .[0].due[:10], open: length}) | sort_by(.due)) as $ms
  | [$items[] | select(.open and (.labels | index("needs-human")) and $nh[.number | tostring] != null
      and ($t - ($nh[.number | tostring] | fromdateiso8601)) > 86400)
    | {number, title, hours: (($t - ($nh[.number | tostring] | fromdateiso8601)) / 3600 | floor)}] as $stuck
  | [$d.prs[] | select(.failing | length > 0) | {number, title, failing}] as $failing
  | [$items[] | select(.open and (.labels | index("needs-human"))) | {number, title}] as $human
  | ($stuck | map("#\(.number) has needed a human for \(.hours) hours")) as $r1
  | ($failing | map("pull request #\(.number) fails its checks (\(.failing | join(", ")))")) as $r2
  | (if ($drift | length) > 0 then [plural($drift | length; "board drift item") + " (\($drift | map("#\(.number)") | join(", ")))"] else [] end) as $r3
  | (if ($ms | length) > 0 then {status: "OFF_TRACK", label: "Off track",
       rule: ($ms | map("milestone \(.milestone) was due \(.due) and has \(plural(.open; "open issue"))") | join("; "))}
     elif ($r1 + $r2 + $r3 | length) > 0 then {status: "AT_RISK", label: "At risk", rule: ($r1 + $r2 + $r3 | join("; "))}
     else {status: "ON_TRACK", label: "On track", rule: "no milestone past due, nothing waiting for a human for more than 24 hours, no pull request failing its checks, no drift"} end) as $h
  | ([$items[] | .status // "No Status"] | group_by(.) | map({key: .[0], value: length}) | from_entries) as $c
  | (["Backlog", "Ready", "In progress", "In review", "Done"] as $order
     | ($order + ([$c | keys[] | select(. as $k | $order | index($k) | not)] | sort)) | map(select($c[.] != null) | "\(.) \($c[.])") | join(" · ")) as $counts
  | $h + {startDate: $now[:10], targetDate: ([$dated[].due] | min | if . then .[:10] else null end),
    body: ("\($h.label): \($h.rule)\n\nBoard: \($counts)\n"
      + "Needs a human: \(if ($human | length) == 0 then "nothing" else ($human | map("#\(.number) \(.title)") | join(", ")) end)\n"
      + "Failing pull requests: \(if ($failing | length) == 0 then "none" else ($failing | map("#\(.number) \(.title)") | join(", ")) end)\n"
      + "Drift: \(if ($drift | length) == 0 then "none" else ($drift | map("#\(.number) \(.why)") | join(", ")) end)")}'

# Publishes the health of the Project as a status update (#177): $1 a board_data result, $2 the board drift, $3 now. Prints the
# update as JSON {status, label, rule, startDate, targetDate, body}; fails, saying why on stderr, when it could not be built or posted.
health_publish() {
  local nh health
  nh=$(health_needs_human "$1") || { echo "senior-mode: could not read when the tickets got needs-human; no status update posted" >&2; return 1; }
  health=$(jq -c --argjson drift "$2" --argjson nh "$nh" --arg now "$3" "$HEALTH_JQ" <<<"$1") ||
    { echo "senior-mode: could not work out the health of the Project; no status update posted" >&2; return 1; }
  project_post_update "$(jq -r .body <<<"$health")" "$(jq -r .status <<<"$health")" "$(jq -r .startDate <<<"$health")" \
    "$(jq -r '.targetDate // empty' <<<"$health")" ||
    { echo "senior-mode: could not post the status update to the Project" >&2; return 1; }
  printf '%s\n' "$health"
}

# What only this machine knows (#319): whether `serve` runs here, and when the last retro ran. $1 the git common dir,
# $2 now in seconds. The retro mark starts at the first status, so a new repository is not told a retro is due.
# Prints {serve: {running, pid}, retro: {lastDays, due}}.
local_facts() {
  local common=$1 now_s=$2 pid="" mark last
  pid=$(cat "$common/senior-mode/serve/serve.pid" 2>/dev/null) || pid=""
  if ! [[ $pid =~ ^[0-9]+$ ]] || ! kill -0 "$pid" 2>/dev/null || [[ $(ps -o args= -p "$pid" 2>/dev/null) != *senior-mode* ]]; then
    pid=""
  fi
  mark=$common/senior-mode/retro-last
  if ! last=$(cat "$mark" 2>/dev/null) || ! [[ $last =~ ^[0-9]+$ ]]; then
    mkdir -p "$common/senior-mode" && printf '%s\n' "$now_s" >"$mark" 2>/dev/null
    last=$now_s
  fi
  jq -nc --arg pid "$pid" --argjson days $(((now_s - last) / 86400)) \
    '{serve: {running: ($pid != ""), pid: (if $pid == "" then null else ($pid | tonumber) end)},
      retro: {lastDays: $days, due: ($days >= 7)}}'
}

# One status report. $1 json|text, $2 --since duration or "", $3 true to move the "last time" mark,
# $4 true to repair the drift (--fix), $5 true to publish the health of the Project (--publish).
status_once() {
  local json=$1 since=$2 save=$3 fix=${4:-false} publish=${5:-false} root cache now_s now since_iso head data out wip audit results fixed trees locals
  local lines="" rc=0 health="" drift specs
  root=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repository"
  cache=$root/.claude/senior-mode/status-seen
  now_s=$(date +%s)
  now=$(iso_time "$now_s")
  if [ -n "$since" ]; then
    since_iso=$(iso_time $((now_s - $(duration_seconds "$since"))))
    head="Done in the last $since"
  elif [ -s "$cache" ]; then
    since_iso=$(sed -n 1p "$cache")
    head="Done since last time"
  else
    since_iso=$(iso_time $((now_s - 604800)))
    head="Done in the last 7d"
  fi
  data=$(board_data true) || return 1
  wip=$(config_get wip)
  [[ $wip =~ ^[1-9][0-9]*$ ]] || die "wip must be a positive whole number, not $wip"
  if audit_enabled; then audit=true; else audit=false; fi
  # The local branches count too: a ticket worked on and not pushed yet has a branch.
  locals=$(local_branches)
  out=$(jq -c --arg now "$now" --arg since "$since_iso" --arg repo "$(repo_slug)" --argjson wip "$wip" \
    --argjson audit "$audit" --argjson locals "$locals" --argjson process "$(process_summary)" "$PICK_DEF$DRIFT_DEF$STATUS_JQ" <<<"$data") ||
    die "could not build the status"
  trees=$(ticket_trees "$root")
  out=$(jq -c --argjson t "$trees" '.inProgress |= map(. + {worktree: ($t[.number | tostring])})' <<<"$out")
  # A ticket the hygiene repair takes is not also drift that waits for a human.
  out=$(jq -c --argjson h "$(hygiene_report "$data" "$trees" "$now" "$locals")" '. + {hygiene: $h}
    | .drift |= map(select(.kind != "stale" or (.number as $n | $h.orphans | all(.number != $n))))' <<<"$out") || return 1
  # The spec drift reads git, and GitHub only for the pull requests of the commits it needs; it never fails the report.
  specs=$(spec_drift 2>/dev/null) || specs='{"drift": [], "note": "could not be read"}'
  out=$(jq -c --argjson s "$specs" '. + {specDrift: $s.drift, specDriftNote: $s.note}' <<<"$out") || return 1
  out=$(jq -c --argjson l "$(local_facts "$(git rev-parse --path-format=absolute --git-common-dir)" "$now_s")" '. + $l' <<<"$out") || return 1
  # The report is out before --fix touches anything.
  [ "$json" = true ] || jq -r --arg head "$head" "$HYGIENE_DEF$STATUS_TEXT_JQ" <<<"$out"
  if [ "$fix" = true ]; then
    results=$(status_fix "$out") || rc=1
    fixed=$(jq -sc '[.[] | select(.fixed)]' <<<"$results")
    lines=$(jq -r '.line' <<<"$results")
    out=$(jq -c --argjson f "$fixed" '. + {fixed: ($f | map({number, title}))}' <<<"$out")
    results=$(status_hygiene_fix "$out") || rc=1
    fixed=$(jq -sc '[.[] | select(.fixed) | {kind, id}]' <<<"$results")
    lines=$(printf '%s\n%s' "$lines" "$(jq -r '.line' <<<"$results")" | sed '/^$/d')
    out=$(jq -c --argjson f "$fixed" '.hygiene.fixed = $f' <<<"$out")
  fi
  if [ "$publish" = true ]; then
    # What --fix repaired is not drift any more.
    drift=$(jq -c '(.fixed // []) as $f | .drift | map(select(.number as $n | $f | all(.number != $n)))' <<<"$out")
    if health=$(health_publish "$data" "$drift" "$now"); then
      out=$(jq -c --argjson h "$health" '. + {health: ($h | del(.body))}' <<<"$out")
    else
      rc=1
    fi
  fi
  if [ "$json" = true ]; then
    printf '%s\n' "$out"
  else
    [ -z "$lines" ] || printf '\n%s\n' "$lines"
    [ -z "$health" ] || jq -r '"\nProject status update posted: \(.label): \(.rule)"' <<<"$health"
  fi
  if [ "$save" = true ]; then
    # The directory ignores itself, so the mark never dirties the tree that `check` records.
    mkdir -p "$(dirname "$cache")"
    echo '*' >"$(dirname "$cache")/.gitignore"
    printf '%s\n' "$now" >"$cache"
  fi
  # The report is out; --fix also tidies the repository (#225). Its text goes to stderr under --json.
  if [ "$fix" = true ]; then
    if [ "$json" = true ]; then "$SELF" clean >&2 || echo "senior-mode: clean failed" >&2; else "$SELF" clean || echo "senior-mode: clean failed" >&2; fi
  fi
  return "$rc"
}

# senior-mode status [--json] [--since <dur>] [--watch [secs]] [--fix] [--publish]
# A plain run reports what is new since the previous plain run and moves that mark; --json, --since
# and --watch only read it. --fix repairs the board drift once, so it does not mix with --watch.
# --publish also posts the health of the Project (On track, At risk or Off track, #177) as a Project status
# update; nothing else posts it but `retro`. (`senior-mode publish`, another command, sets commit statuses.)
status() {
  local json=false since="" watch=false secs=30 fix=false publish=false
  while [ $# -gt 0 ]; do
    case $1 in
      --json) json=true ;;
      --fix) fix=true ;;
      --publish) publish=true ;;
      --since)
        [ -n "${2:-}" ] || usage
        since=$2
        duration_seconds "$since" >/dev/null
        shift
        ;;
      --watch)
        watch=true
        if [[ ${2:-} =~ ^[1-9][0-9]*$ ]]; then
          secs=$2
          shift
        fi
        ;;
      *) usage ;;
    esac
    shift
  done
  if [ "$watch" = true ]; then
    [ "$json" = false ] || die "status --watch cannot print JSON"
    [ "$fix" = false ] || die "status --watch cannot --fix: a repair runs once, on purpose"
    [ "$publish" = false ] || die "status --watch cannot --publish: an update is posted once, on purpose"
    while :; do
      if [ -t 1 ]; then printf '\033[H\033[2J'; else echo; fi
      status_once false "$since" false || echo "GitHub did not answer; trying again in ${secs}s"
      sleep "$secs"
    done
  fi
  if [ "$json" = false ] && [ -z "$since" ]; then
    status_once false "" true "$fix" "$publish" || exit 1
  else
    status_once "$json" "$since" false "$fix" "$publish" || exit 1
  fi
}

# What `retro` needs beyond the board (spec 0001 §7): the status changes and reopenings of recently
# updated issues, and recently merged pull requests with their size and reviews. One more query.
# shellcheck disable=SC2016 # a GraphQL query, not shell
HISTORY_QUERY='query($owner: String!, $name: String!, $since: DateTime!) {
  repository(owner: $owner, name: $name) {
    issues(first: 100, filterBy: {since: $since}, orderBy: {field: UPDATED_AT, direction: DESC}) { nodes { number title
      timelineItems(first: 50, itemTypes: [PROJECT_V2_ITEM_STATUS_CHANGED_EVENT, REOPENED_EVENT]) { nodes { __typename
        ... on ProjectV2ItemStatusChangedEvent { createdAt status } ... on ReopenedEvent { createdAt } } } } }
    pullRequests(states: MERGED, first: 50, orderBy: {field: UPDATED_AT, direction: DESC}) { nodes { number title headRefName
      additions deletions mergedAt labels(first: 10) { nodes { name } }
      reviews(first: 20) { nodes { state bodyText author { login } } } } }
  }
}'

# The run outcomes of this repository (one object per ticket run, `run` writes it to
# <git common dir>/senior-mode/runs/<stamp>/<n>.json with `ticket`, `outcome`, `escalated`, `reason`,
# `model`, `finishedAt`), as {found, failed, escalated} for the period starting at $2 (and ending before $3, when given). $1 is the git
# common directory. Absent or unreadable files are not an error; the session logs next to the
# outcomes (<n>-<model>.json) are not outcomes. An outgrown ticket counts as failed.
retro_runs() {
  local dir=$1/senior-mode/runs f
  if [ ! -d "$dir" ]; then
    echo '{"found":false,"failed":[],"escalated":[]}'
    return 0
  fi
  {
    for f in "$dir"/*/[0-9]*.json; do
      [[ $f =~ /[0-9]+\.json$ ]] && [ -f "$f" ] || continue
      jq -c --arg m "$(iso_time "$(file_mtime "$f")")" 'if type == "object"
        then {ticket, outcome, escalated, reason, at: (.finishedAt // $m)} else empty end' "$f" 2>/dev/null || true
    done
  } | jq -sc --arg since "$2" --arg until "${3:-9999}" '[.[] | select(.at >= $since and .at < $until)] as $l | {found: true,
    failed: [$l[] | select(.outcome | IN("failed", "outgrown")) | {ticket, reason, at}] | sort_by(.ticket),
    escalated: [$l[] | select(.escalated == true or .outcome == "escalated") | {ticket, reason, at}] | sort_by(.ticket)}'
}

# The tokens of the sessions of the period (#299), from the ledger the session scripts append to
# (<git common dir>/senior-mode/usage.jsonl, one line per session and model), per ticket and role, with an
# estimated USD equivalent at the public API prices of lib/prices.json. A model that table does not price
# keeps its tokens and is listed as unpriced; a date suffix (claude-haiku-4-5-20251001) prices as its model.
# shellcheck disable=SC2016 # a jq program, not shell
USAGE_RETRO_JQ='$prices[0] as $p
  | def price($m): [$p.perMTok | to_entries[]
      | select(.key as $k | $m == $k or (($m | startswith($k + "-")) and ($m[($k | length) + 1:] | test("^[0-9]{8}$")))) | .value] | first;
  def r4: if . == null then null else . * 10000 | round / 10000 end;
  def total: reduce .[] as $l ({input: 0, output: 0, cacheRead: 0, cacheWrite5m: 0, cacheWrite1h: 0, usd: null, unpriced: []};
      .input += $l.input | .output += $l.output | .cacheRead += $l.cacheRead | .cacheWrite5m += $l.cacheWrite5m | .cacheWrite1h += $l.cacheWrite1h
      | price($l.model) as $q
      | if $q == null then .unpriced = (.unpriced + [$l.model] | unique)
        else .usd = (.usd // 0) + ($l.input * $q.input + $l.output * $q.output + $l.cacheRead * $q.cacheRead
          + $l.cacheWrite5m * $q.cacheWrite5m + $l.cacheWrite1h * $q.cacheWrite1h) / 1000000 end)
    | .usd |= r4;
  [.[] | select(.at >= $since and .at < $until)] as $l
  | {prices: {date: $p.date, source: $p.source},
     tickets: [$l | group_by(.ticket)[] | {ticket: .[0].ticket} + total + {roles: [group_by(.role)[] | {role: .[0].role} + total]}],
     total: ($l | total)}'

retro_usage() {
  local f=$1/senior-mode/usage.jsonl
  { [ ! -f "$f" ] || jq -cR 'fromjson? | select(type == "object" and (.at | type) == "string")' "$f" 2>/dev/null || true; } |
    jq -sc --slurpfile prices "$LIB/prices.json" --arg since "$2" --arg until "${3:-9999}" "$USAGE_RETRO_JQ"
}

# The failed results `check` recorded since the epoch $1 (and before $2, when given), in this repository and its worktrees (ADR 0006).
retro_checks() {
  local common d f mt
  common=$(git rev-parse --path-format=absolute --git-common-dir)
  {
    for d in "$common/senior-mode/checks" "$common"/worktrees/*/senior-mode/checks; do
      [ -d "$d" ] || continue
      for f in "$d"/*; do
        [ -f "$f" ] && [ "$(sed -n 1p "$f")" = failure ] || continue
        mt=$(file_mtime "$f")
        [ "$mt" -ge "$1" ] && [ "$mt" -lt "${2:-99999999999}" ] || continue
        jq -nc --arg c "$(basename "$f" | cut -c1-7)" --arg d "$(sed -n 2p "$f")" --arg at "$(iso_time "$mt")" \
          '{commit: $c, description: $d, at: $at}'
      done
    done
  } | jq -sc 'sort_by(.at)'
}

# The facts of a period as JSON. Inputs: $d board_data, $h the history, $runs, $checks; $since, $now, $repo.
# $until ends the period ("9999" for none) and $iteration names the iteration it is, if any (#180).
# Cycle time runs from the first move to In progress to the close of the ticket; a ticket with no
# recorded start is left out of it. A size is over when the pull request holds more than 1.5 times the
# lines its size allows (S ~50, M ~400, spec §5), since those are approximate.
# shellcheck disable=SC2016 # a jq program, not shell
RETRO_JQ='def branch_ticket: [capture("^[a-z]+/(?<n>[0-9]+)-") | .n | tonumber] | first;
  def round1: . * 10 | round / 10;
  . as $d | $h.data.repository.issues.nodes as $iss | $h.data.repository.pullRequests.nodes as $prs
  | ($d.items | map({key: (.number | tostring), value: .}) | from_entries) as $byn
  | def lines($n): [$prs[] | select((.headRefName | branch_ticket) == $n) | .additions + .deletions] | if length == 0 then null else add end;
  def cycle($c): ([$iss[] | select(.number == $c.number) | .timelineItems.nodes[]
      | select(.__typename == "ProjectV2ItemStatusChangedEvent" and .status == "In progress") | .createdAt] | sort | first) as $start
    | if $start == null then null else (($c.closedAt | fromdateiso8601) - ($start | fromdateiso8601)) / 3600
      | if . < 0 then null else round1 end end;
  def excerpt: gsub("\\s+"; " ") | gsub("^ | $"; "") | .[:160];
  def why: (if (.labels | index("needs-human")) then ["needs-human label"] else [] end)
    + ([.reviews[]? | select(.state == "CHANGES_REQUESTED")] | last
      | if . then ["changes requested by \(.author.login // "someone")" + (if (.bodyText | test("\\S")) then ": " + (.bodyText | excerpt) else "" end)] else [] end);
  [$d.closed[] | select(.closedAt >= $since and .closedAt < $until and .reason != "NOT_PLANNED") | . as $c | ($byn[($c.number | tostring)] // {}) as $i
    | {number, title, size: $i.size, closedAt, cycleHours: cycle($c), lines: lines($c.number)}] | sort_by(.number) as $done
  | [$done[] | select(.cycleHours != null) | .cycleHours] | sort as $hs
  | {repository: $repo, generatedAt: $now, since: $since, until: (if $until == "9999" then null else $until end), iteration: $iteration, done: $done,
     cycle: {measured: ($hs | length),
       medianHours: (if ($hs | length) == 0 then null else (($hs[(($hs | length) - 1) / 2 | floor] + $hs[($hs | length) / 2 | floor]) / 2) | round1 end),
       worst: ([$done[] | select(.cycleHours != null)] | max_by(.cycleHours) | if . then {number, title, hours: .cycleHours} else null end)},
     humanPullRequests: (([$d.prs[] | select(.labels | index("needs-human")) | {number, title, state: "open", why: ["needs-human label"]}]
       + [$prs[] | select(.mergedAt >= $since and .mergedAt < $until) | .labels = [.labels.nodes[].name] | .reviews = .reviews.nodes
         | {number, title, state: "merged", why: why} | select(.why | length > 0)]) | sort_by(.number)),
     runs: $runs,
     reopened: [$iss[] | . as $i | ([.timelineItems.nodes[] | select(.__typename == "ReopenedEvent" and .createdAt >= $since and .createdAt < $until)] | last) as $e
       | select($e != null) | {number: $i.number, title: $i.title, at: $e.createdAt}] | sort_by(.number),
     checkFailures: $checks,
     sizes: [$done[] | select((.size | IN("S", "M")) and .lines != null) | (if .size == "S" then 50 else 400 end) as $l
       | {number, title, size, lines, limit: $l, over: (.lines > $l * 1.5)}]}'

# The same, in plain words; $head says which period it covers.
# shellcheck disable=SC2016 # a jq program, not shell
RETRO_TEXT_JQ='def sec($h; $ls): $h, (if ($ls | length) == 0 then "  nothing" else ($ls[] | "  " + .) end);
  def ticket: "#\(.number) \(.title)";
  "senior-mode retro · \(.repository) · \(.generatedAt)", "",
  sec("\($head) (\(.done | length))"; [.done[] | ticket + (if .cycleHours then " · \(.cycleHours)h" else "" end)]),
  "Cycle time (In progress to Done)",
  (if .cycle.measured == 0 then "  nothing measured"
   else "  median \(.cycle.medianHours)h, worst \(.cycle.worst.hours)h (\(.cycle.worst | ticket)), over \(.cycle.measured) ticket\(if .cycle.measured > 1 then "s" else "" end)" end),
  sec("Needed a human (\(.humanPullRequests | length))"; [.humanPullRequests[]
    | "pull request #\(.number) \(.title)\(if .state == "open" then " (still open)" else "" end): \(.why | join("; "))"]),
  (if .runs.found then sec("Failed or escalated runs (\((.runs.failed | length) + (.runs.escalated | length)))";
     [.runs.failed[] | "#\(.ticket): failed: \(.reason // "no reason recorded")"]
     + [.runs.escalated[] | "#\(.ticket): escalated: \(.reason // "no reason recorded")"])
   else "Failed or escalated runs", "  no run logs" end),
  sec("Reopened (\(.reopened | length))"; [.reopened[] | ticket]),
  sec("Check failures (\(.checkFailures | length))"; [.checkFailures[] | "\(.commit): \(.description)"]),
  sec("Repository hygiene (\(.hygiene | hygiene_lines | length))"; .hygiene | hygiene_lines),
  sec("Estimates against reality"; [.sizes[] | select(.over) | "#\(.number) \(.size): \(.lines) lines, the size allows about \(.limit)"]
    + (if (.sizes | length) > 0 and all(.sizes[]; .over | not) then ["all within their size"] else [] end)),
  (def tok: if . >= 1000000 then "\(. / 100000 | round / 10)M" elif . >= 1000 then "\(. / 100 | round / 10)k" else tostring end;
   def cost: (if .usd == null then "no price" elif .usd > 0 and .usd < 0.01 then "<$0.01" else "$\(.usd * 100 | round / 100)" end)
     + (if .usd != null and (.unpriced | length) > 0 then " (no price for \(.unpriced | join(", ")))" else "" end);
   def line: "input \(.input | tok), output \(.output | tok), cache read \(.cacheRead | tok), cache write \(.cacheWrite5m + .cacheWrite1h | tok) · \(cost)";
   sec("Token use (estimated at the API prices of \(.usage.prices.date))";
     [.usage.tickets[] | (if .ticket == null then "run" else "#\(.ticket)" end) as $t | .roles[] | "\($t) \(.role): \(line)"]
     + (if (.usage.tickets | length) > 0 then ["total: \(.usage.total | line)"] else [] end)))'

# senior-mode retro [--since <dur> | --iteration [<name>]] [--json]
# The facts of the weekly review (default period: 7 days; --iteration: the current iteration, or the one named, of the
# Project, #180). Reads only, apart from the Project status update with the health of the Project that each pass
# publishes (#177); the skill turns the facts into proposals.
retro() {
  local json=false since="" iteration="" iter="" root now_s now since_s since_iso until_iso="" data board history runs checks slug hygiene
  local head drift health title first last usage
  while [ $# -gt 0 ]; do
    case $1 in
      --json) json=true ;;
      --since)
        [ -n "${2:-}" ] || usage
        since=$2
        duration_seconds "$since" >/dev/null
        shift
        ;;
      --iteration)
        iteration=current
        if [ -n "${2:-}" ] && [[ $2 != --* ]]; then
          iteration=$2
          shift
        fi
        ;;
      *) usage ;;
    esac
    shift
  done
  [ -z "$iteration" ] || [ -z "$since" ] || die "retro takes --since or --iteration, not both"
  root=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || die "not inside a git repository"
  now_s=$(date +%s)
  now=$(iso_time "$now_s")
  if [ -n "$iteration" ]; then
    iter=$(iteration_find "$iteration") || die "no iteration $iteration on the board (is there an Iteration field? setup github creates it)"
    IFS=$'\t' read -r _ title first until_iso last <<<"$iter"
    since_iso=${first}T00:00:00Z until_iso=${until_iso}T00:00:00Z
    since_s=$(jq -nr --arg d "$since_iso" '$d | fromdateiso8601')
    head="Done in iteration $title ($first to $last)"
  else
    since=${since:-7d}
    since_s=$((now_s - $(duration_seconds "$since")))
    since_iso=$(iso_time "$since_s")
    head="Done in the last $since"
  fi
  slug=$(repo_slug)
  # --json keeps stdout pure.
  if [ "$json" = true ]; then security_alerts >&2; else security_alerts; fi
  board=$(board_data true) || exit 1
  history=$(jq -nc --arg q "$HISTORY_QUERY" --arg o "${slug%%/*}" --arg n "${slug#*/}" --arg s "$since_iso" \
    '{query: $q, variables: {owner: $o, name: $n, since: $s}}' | gh_retry api graphql --input -) ||
    die "cannot read the history from GitHub"
  [ -z "$(jq -r '.errors[0].message // empty' <<<"$history" 2>/dev/null)" ] ||
    die "GitHub refused the history query: $(jq -r '.errors[0].message' <<<"$history")"
  runs=$(retro_runs "$root" "$since_iso" "$until_iso")
  checks=$(retro_checks "$since_s" "${until_iso:+$(jq -nr --arg d "$until_iso" '$d | fromdateiso8601')}")
  hygiene=$(hygiene_report "$board" "$(ticket_trees "$(git rev-parse --show-toplevel)")" "$now" "$(local_branches)") || die "could not build the hygiene report"
  data=$(jq -c --argjson h "$history" --argjson runs "$runs" --argjson checks "$checks" --arg now "$now" --arg since "$since_iso" \
    --arg until "${until_iso:-9999}" --argjson iteration "$(jq -nc --arg t "${title:-}" 'if $t == "" then null else $t end')" \
    --arg repo "$slug" "$RETRO_JQ" <<<"$board") || die "could not build the retro"
  usage=$(retro_usage "$root" "$since_iso" "$until_iso") || die "could not read the token ledger"
  data=$(jq -c --argjson h "$hygiene" --argjson u "$usage" '. + {hygiene: $h, usage: $u}' <<<"$data")
  if [ "$json" = true ]; then
    printf '%s\n' "$data"
  else
    jq -r --arg head "$head" "$HYGIENE_DEF$RETRO_TEXT_JQ" <<<"$data"
  fi
  # `status` proposes the next retro a week after this one (#319).
  mkdir -p "$root/senior-mode" && printf '%s\n' "$now_s" >"$root/senior-mode/retro-last"
  # The pass ends with the health of the Project (#177); a failure is said and does not undo the retro.
  drift=$(jq -c --argjson l "$(local_branches)" --argjson h "$hygiene" "$DRIFT_DEF"'drift(.; $l)
    | map(select(.kind != "stale" or (.number as $n | $h.orphans | all(.number != $n))))' <<<"$board") || drift='[]'
  if health=$(health_publish "$board" "$drift" "$now"); then
    if [ "$json" = true ]; then
      jq -r '"Project status update posted: \(.label): \(.rule)"' <<<"$health" >&2
    else
      jq -r '"\nProject status update posted: \(.label): \(.rule)"' <<<"$health"
    fi
  fi
}

# One line for Claude Code's status line (spec 0001 §20): the ticket of the branch, the last check
# recorded for it and, during a run, a mark. Offline and fast; prints nothing where senior-mode is not
# set up, and never fails. Claude Code sends the session as JSON on stdin; its directory is used.
statusline() {
  local input="" dir root branch ticket record state="no check" parts
  [ -t 0 ] || input=$(cat)
  dir=$(jq -r '.workspace.current_dir // .cwd // empty' <<<"$input" 2>/dev/null) || dir=""
  [ -z "$dir" ] || cd "$dir" 2>/dev/null || return 0
  root=$(git rev-parse --show-toplevel 2>/dev/null) || return 0
  [ -f "$root/.claude/senior-mode.json" ] || return 0
  branch=$(git symbolic-ref --short -q HEAD) || branch=$(git rev-parse --short HEAD 2>/dev/null) || return 0
  ticket=$(sed -nE 's#^[a-z]+/([0-9]+)-.*#\1#p' <<<"$branch")
  parts=${ticket:+#$ticket}
  parts=${parts:-$branch}
  record=$(check_record "$(git rev-parse HEAD 2>/dev/null)") || true
  if [ -f "$record" ]; then
    if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
      state="check stale"
    elif [ "$(sed -n 1p "$record")" = success ]; then
      state="check ok"
    else
      state="check FAILED"
    fi
  fi
  parts+=" · $state"
  [ -z "${SENIOR_MODE_RUN:-}" ] || parts+=" · run in progress"
  printf '%s\n' "$parts"
}

# The command of the status line setup writes. A plugin cannot ship a status line, and the plugin's
# directory changes with every version, so the command looks the script up each time: the install
# path in Claude Code's plugin registry, else the newest version in its plugin cache; nothing is
# printed when the plugin is not installed.
# shellcheck disable=SC2016 # a command for the project's settings, not for this shell
STATUSLINE_COMMAND='b=$(jq -r '\''[.plugins | to_entries[] | select(.key | startswith("senior-mode@")) | .value[].installPath] | last // empty'\'' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null)/bin/senior-mode; [ -x "$b" ] || b=$(ls -d "$HOME"/.claude/plugins/cache/*/senior-mode/*/bin/senior-mode 2>/dev/null | sort -V | tail -1); [ -x "$b" ] && exec "$b" statusline; exit 0'

# Writes the status line of the project into .claude/settings.json. A status line of the project's
# own is kept; ours is refreshed. A project setting hides the user's own status line in this project.
setup_statusline() {
  local root file current out=0
  root=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repository"
  file=$root/.claude/settings.json
  mkdir -p "$root/.claude"
  [ -f "$file" ] || echo '{}' >"$file"
  jq empty "$file" 2>/dev/null || die "invalid .claude/settings.json; fix or remove it, then run setup again"
  current=$(jq -r '.statusLine.command // empty' "$file")
  if [ -n "$current" ] && ! grep -q 'senior-mode' <<<"$current"; then
    echo "statusline: yours kept; to add senior-mode's, call \`senior-mode statusline\` from your command"
    return 0
  fi
  # shellcheck disable=SC2016 # a jq program, not shell
  json_update "$file" '.statusLine = {type: "command", command: $c}' --arg c "$STATUSLINE_COMMAND" || out=$?
  [ "$out" -ne 1 ] || die "could not update .claude/settings.json"
  if [ "$out" -eq 2 ]; then
    echo "statusline: already set in .claude/settings.json"
  else
    echo "statusline: set in .claude/settings.json (ticket, last check, run in progress)"
  fi
}
