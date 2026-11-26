# shellcheck shell=bash
# `setup repo --knowledge` (#369, spec 325 section 9): adopts the long-lived project layout in an existing repository, in
# one draft pull request `docs(knowledge): adopt long-lived project layout`, plus a label and the standing maintenance
# epic on GitHub. Idempotent: what exists is kept, so a second run changes nothing. No ticket is ever edited.

# Says what a step wrote ($1 true) or would write ($1 false).
knowledge_say() { # apply path [detail]
  if [ "$1" = true ]; then echo "wrote: $2${3:+ ($3)}"; else echo "would write: $2${3:+ ($3)}"; fi
}

# The raw value of the front matter key $2 of the file $1; fails when the file has no such key.
knowledge_fm() { # file key
  awk -v k="$2" 'NR == 1 && $0 != "---" { exit } NR > 1 && $0 == "---" { exit }
    NR > 1 && index($0, k ":") == 1 { v = substr($0, length(k) + 2); sub(/^[ \t]+/, "", v); sub(/\r$/, "", v); print v; found = 1; exit }
    END { exit !found }' "$1"
}

# A JSON list of strings as the specs write it: ["a", "b"].
knowledge_list() {
  jq -r 'map(@json) | join(", ") | "[" + . + "]"'
}

# The ADRs of the tree $1 that have front matter and no `paths`: each gets the union of the `paths` of the specs whose
# `adrs` cite it. An ADR no spec with paths cites is left as it is.
knowledge_adrs() { # root apply
  local root=$1 apply=$2 specs f adr id paths ids tmp
  specs=$(for f in "$root"/docs/specs/*.md; do
    [ -f "$f" ] || continue
    jq -nc --arg f "$(basename "$f")" --arg i "$(knowledge_fm "$f" id || true)" --arg a "$(knowledge_fm "$f" adrs || true)" \
      --arg p "$(knowledge_fm "$f" paths || true)" \
      '{id: (if $i != "" then ($i | gsub("[\"\u0027]"; "")) else ($f | capture("^(?<n>[0-9]+)").n // $f) end),
        adrs: ($a | fromjson? // [] | if type == "array" then map(tonumber? // empty) else [] end),
        paths: ($p | fromjson? // [] | if type == "array" then map(select(type == "string")) else [] end)}'
  done | jq -sc '.')
  for adr in "$root"/docs/adr/*.md; do
    [ -f "$adr" ] || continue
    [ "$(head -n 1 "$adr")" = --- ] || continue
    ! knowledge_fm "$adr" paths >/dev/null || continue
    id=$(knowledge_fm "$adr" id || true)
    id=${id//[\"\']/}
    [[ $id =~ ^[0-9]+$ ]] || id=$(basename "$adr" | grep -oE '^[0-9]+' || true)
    [[ $id =~ ^[0-9]+$ ]] || continue
    ids=$(jq -r --argjson n "$((10#$id))" '[.[] | select(.adrs | index($n))] | map(.id) | join(", ")' <<<"$specs")
    paths=$(jq -c --argjson n "$((10#$id))" '[.[] | select(.adrs | index($n)) | .paths[]] | unique' <<<"$specs")
    [ "$paths" != "[]" ] || continue
    if [ "$apply" = true ]; then
      tmp=$(mktemp)
      awk -v line="paths: $(knowledge_list <<<"$paths")" 'NR == 1 { print; next } !done && $0 == "---" { print line; done = 1 } { print }' "$adr" >"$tmp" &&
        cat "$tmp" >"$adr"
      rm -f "$tmp"
    fi
    knowledge_say "$apply" "docs/adr/$(basename "$adr")" "paths $(knowledge_list <<<"$paths") from specs $ids; correct them by hand"
  done
}

# The glob of a path cited in a draft: the tracked file itself, or a directory with tracked files in it.
knowledge_glob() { # tracked-files token
  awk -v t="${2%/}" '$0 == t { print t; exit } index($0, t "/") == 1 { dir = t "/**" } END { if (dir != "") print dir }' <<<"$1" | head -n 1
}

# A note for each draft of $2 (the JSON of retro_drafts) that has none yet: `docs/knowledge/<agent>-<draft>.md`, kind
# `context`, origin `retro`, the paths the draft cites between backticks (else `**`, to narrow by hand), the text of the
# draft cut to knowledge.maxLines.
knowledge_notes() { # root drafts apply
  local root=$1 apply=$3 max slug file agent name body n paths tracked tok glob globs note
  max=$(config_get knowledge.maxLines)
  [[ $max =~ ^[1-9][0-9]*$ ]] || die "knowledge.maxLines must be a positive whole number, not $max"
  tracked=$(git -C "$root" -c core.quotePath=false ls-files)
  while IFS=$'\t' read -r agent file; do
    [ -f "$file" ] || continue
    name=$(basename "$file")
    slug=$(printf '%s-%s' "$agent" "${name%.*}" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9]\{1,\}/-/g; s/^-//; s/-$//')
    note=docs/knowledge/$slug.md
    [ ! -e "$root/$note" ] || continue
    body=$(awk 'NR == 1 && $0 == "---" { fm = 1; next } fm && $0 == "---" { fm = 0; next } !fm { print }' "$file" |
      awk 'NF { started = 1 } started { print }')
    [ -n "${body//[[:space:]]/}" ] || continue
    n=$(printf '%s\n' "$body" | wc -l)
    globs=()
    while IFS= read -r tok; do
      glob=$(knowledge_glob "$tracked" "$tok")
      [ -z "$glob" ] || [[ " ${globs[*]:-} " == *" $glob "* ]] || globs+=("$glob")
    done < <(printf '%s\n' "$body" | grep -oE '`[^` ]+`' | tr -d '`' | sort -u)
    paths=$(printf '%s\n' ${globs[@]+"${globs[@]}"} | head -n 5 | jq -Rnc '[inputs | select(length > 0)] | if length == 0 then ["**"] else . end')
    if [ "$apply" = true ]; then
      mkdir -p "$root/docs/knowledge"
      {
        printf -- '---\npaths: %s\nverified: %s\norigin: "retro"\nkind: context\n---\n\n# %s: %s\n\n' \
          "$(knowledge_list <<<"$paths")" "$(date -u +%F)" "$agent" "${name%.*}"
        if [ "$n" -le $((max - 2)) ]; then printf '%s\n' "$body"
        else printf '%s\n\n(cut to fit knowledge.maxLines: the draft is longer)\n' "$(printf '%s\n' "$body" | head -n $((max - 4)))"
        fi
      } >"$root/$note"
    fi
    knowledge_say "$apply" "$note" "from the draft of $agent: $name; paths $(knowledge_list <<<"$paths")$([ "$paths" != '["**"]' ] || echo ', narrow them by hand')"
  done < <(jq -r '.[] | [.agent, .file] | @tsv' <<<"$2")
}

# docs/vision.md from the README, a draft for the owner to rewrite: the first paragraph, one goal G1 from its first
# sentence, an empty non-goals section so that `check` passes.
knowledge_vision() { # root apply
  local root=$1 apply=$2 readme=$1/README.md para title first
  [ ! -e "$root/docs/vision.md" ] || return 0
  [ -f "$readme" ] || { echo "vision: no README.md to draft docs/vision.md from"; return 0; }
  title=$(sed -n 's/^#[[:space:]]\{1,\}//p' "$readme" | head -n 1)
  para=$(awk '/^[[:space:]]*$/ { if (p != "") exit; next } /^[#<]|^!?\[!?\[|^!\[|^\[!/ { if (p != "") exit; next }
    { sub(/^[[:space:]]+/, ""); p = (p == "" ? $0 : p " " $0) } END { print p }' "$readme")
  first=$(printf '%s' "$para" | sed 's/\([.!?]\)[[:space:]].*/\1/' | cut -c1-200)
  [ -n "$first" ] || first="${title:-$(basename "$root")}"
  if [ "$apply" = true ]; then
    mkdir -p "$root/docs"
    {
      printf '# Vision%s\n\n' "${title:+: $title}"
      printf '> Draft written from README.md by `senior-mode setup repo --knowledge`. The owner rewrites it and merges it; agents do not.\n\n'
      [ -z "$para" ] || printf '%s\n\n' "$para"
      printf '## Goals\n\n- G1: %s\n\n## Non-goals\n\n- To be written by the owner.\n' "$first"
    } >"$root/docs/vision.md"
  fi
  knowledge_say "$apply" docs/vision.md "draft from README.md, for the owner to rewrite"
}

# The current violations of the architecture rules of the tree $1 as the baseline, when it has rules, violations, and no
# baseline yet (an existing one is the ratchet's: only `check --update-baseline` lowers it).
knowledge_baseline() { # root apply
  local root=$1 apply=$2 rules errs rows json n files
  rules=$(jq -c '.architecture.rules // []' "$root/.claude/senior-mode.json" 2>/dev/null) || rules='[]'
  [ "$rules" != '[]' ] || { echo "baseline: no architecture.rules, nothing to record"; return 0; }
  if [ -e "$root/.claude/architecture-baseline.json" ]; then
    echo "baseline: .claude/architecture-baseline.json exists, kept"
    return 0
  fi
  errs=$(architecture_rules_errors "$rules")
  [ -z "$errs" ] || { echo "baseline: architecture.rules is invalid ($(head -n 1 <<<"$errs")), not recorded"; return 0; }
  rows=$(architecture_violations "$root" "$rules" 2>&1) || { echo "baseline: the rules could not be run ($(tail -n 1 <<<"$rows")), not recorded"; return 0; }
  [ -n "$rows" ] || { echo "baseline: no violation of the architecture rules, nothing to record"; return 0; }
  json=$(cut -f1,2 <<<"$rows" | LC_ALL=C sort | uniq -c |
    jq -Rsc '{violations: [split("\n")[] | select(length > 0) | capture("^\\s*(?<c>[0-9]+) (?<r>[^\t]+)\t(?<f>.*)$") | {rule: .r, file: .f, count: (.c | tonumber)}]}')
  n=$(jq '[.violations[].count] | add' <<<"$json")
  files=$(jq '[.violations[].file] | unique | length' <<<"$json")
  echo "baseline: $n violation$([ "$n" = 1 ] || echo s) in $files file$([ "$files" = 1 ] || echo s) of the architecture rules"
  if [ "$apply" = true ]; then
    mkdir -p "$root/.claude"
    jq . <<<"$json" >"$root/.claude/architecture-baseline.json"
  fi
  knowledge_say "$apply" .claude/architecture-baseline.json "what is there now, so that only new violations fail"
}

# Everything written into the tree $1 (the default branch, in a temporary worktree), with $2 the agents' drafts.
knowledge_files() { # root drafts apply
  knowledge_adrs "$1" "$3"
  knowledge_notes "$1" "$2" "$3"
  knowledge_vision "$1" "$3"
  knowledge_baseline "$1" "$3"
}

# The labels `gardening` and `maintenance`, created when missing (the project's own, `workflow.labels`, stand for ours).
knowledge_labels() { # slug apply tree
  local have label color description
  have=$(gh_retry label list --repo "$1" --limit 1000 --json name --jq '.[].name') || die "cannot list the labels of $1"
  while IFS='|' read -r label color description; do
    ! jq -e --arg l "$label" '(.workflow.labels // {}) | has($l)' "$3/.claude/senior-mode.json" >/dev/null 2>&1 || continue
    ! grep -qxF -- "$label" <<<"$have" || continue
    if [ "$2" = true ]; then
      gh_retry label create "$label" --repo "$1" --color "$color" --description "$description" >/dev/null || die "cannot create the label $label"
      echo "created: label $label"
    else
      echo "would create: label $label"
    fi
  done <<<"gardening|fbca04|A maintenance ticket: keeps the project healthy, not a feature"$'\n'"maintenance|c5def5|The standing epic of the gardening tickets"
}

# The standing epic of the gardening tickets: an open issue labelled `maintenance`, created when there is none.
knowledge_epic() { # slug apply
  local found url
  found=$(gh_retry issue list --repo "$1" --label maintenance --state open --limit 1 --json number --jq '.[0].number // empty') ||
    die "cannot list the issues of $1"
  [ -z "$found" ] || return 0
  if [ "$2" != true ]; then
    echo "would create: the maintenance epic"
    return 0
  fi
  url=$(gh_retry issue create --repo "$1" --title "Maintenance" --label maintenance \
    --body "The standing epic of the gardening tickets: stale knowledge notes, architecture violations of the baseline, an outdated docs/architecture.md, dead paths. Tickets labelled \`gardening\` sit under it. Keep it open. Created by \`senior-mode setup repo --knowledge\`.") ||
    die "cannot create the maintenance epic"
  echo "created: the maintenance epic $url"
}

# The open tickets that would be orphans under `hierarchy.enforce` (spec 325 section 7), listed, none changed: a ticket
# with no parent epic, no exempt label (`hierarchy.exempt`, default security and hotfix) and not under the maintenance
# epic, or whose epic's milestone has no `Goal: Gn`.
# shellcheck disable=SC2016 # a GraphQL query and a jq program, not shell
knowledge_orphans() { # slug tree
  local query after="" page nodes="[]" exempt n
  query='query($owner: String!, $name: String!, $after: String) { repository(owner: $owner, name: $name) {
    issues(first: 100, states: OPEN, after: $after, orderBy: {field: CREATED_AT, direction: ASC}) { pageInfo { hasNextPage endCursor }
      nodes { number title labels(first: 30) { nodes { name } } subIssuesSummary { total }
        parent { number labels(first: 30) { nodes { name } } milestone { description } } } } } }'
  for _ in $(seq 1 20); do
    page=$(jq -nc --arg q "$query" --arg o "${1%%/*}" --arg n "${1#*/}" --arg a "$after" \
      '{query: $q, variables: ({owner: $o, name: $n} + (if $a == "" then {} else {after: $a} end))}' | gh_retry api graphql --input - 2>/dev/null) &&
      jq -e '.data.repository.issues.nodes' >/dev/null 2>&1 <<<"$page" || { echo "orphans: the open tickets could not be read from GitHub"; return 0; }
    nodes=$(jq -c --argjson p "$nodes" '$p + .data.repository.issues.nodes' <<<"$page")
    [ "$(jq -r '.data.repository.issues.pageInfo.hasNextPage' <<<"$page")" = true ] || break
    after=$(jq -r '.data.repository.issues.pageInfo.endCursor' <<<"$page")
  done
  exempt=$(jq -c '.hierarchy.exempt // ["security", "hotfix"]' "$2/.claude/senior-mode.json" 2>/dev/null) || exempt='["security","hotfix"]'
  nodes=$(jq -r --argjson ex "$exempt" 'def names: [.labels.nodes[].name];
    [.[] | select(.subIssuesSummary.total == 0 and (names | any(. == "maintenance") | not) and (names | any(. as $l | $ex | index($l)) | not))
      | if .parent == null then "#\(.number) \(.title): no parent epic"
        elif (.parent.labels.nodes | any(.name == "maintenance")) then empty
        elif ((.parent.milestone.description // "") | test("(^|\n)\\s*Goal:\\s*G[0-9]+")) then empty
        else "#\(.number) \(.title): its epic #\(.parent.number) has no milestone with a goal" end] | .[]' <<<"$nodes")
  if [ -z "$nodes" ]; then
    echo "orphans: no open ticket would be one"
    return 0
  fi
  n=$(grep -c '' <<<"$nodes")
  echo "orphans: $n open ticket$([ "$n" = 1 ] || echo s) would be orphans under hierarchy.enforce; none is changed. Attach them to epics, then set hierarchy.enforce to true"
  sed 's/^/  /' <<<"$nodes"
}

# `setup repo --knowledge [--dry-run]`: the files through a draft pull request made in a temporary worktree of the default
# branch (the checkout of the user is not touched), then the labels and the epic. A pull request already open is left as it is.
setup_knowledge() {
  local dry=false root slug base tmp drafts plan pr url branch=docs/adopt-knowledge-layout report title="docs(knowledge): adopt long-lived project layout"
  while [ $# -gt 0 ]; do
    case $1 in
      --dry-run) dry=true; shift ;;
      *) usage ;;
    esac
  done
  root=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repository"
  slug=$(repo_slug)
  base=$(gh_retry api "repos/$slug" --jq .default_branch) || die "cannot read $slug on GitHub"
  git_bound -C "$root" fetch -q origin "$base" || die "cannot fetch $base from origin"
  drafts=$(retro_drafts) || drafts='[]'
  tmp=$(mktemp -d)
  # shellcheck disable=SC2064 # the paths are those of now
  trap "$(printf 'git -C %q worktree remove --force %q >/dev/null 2>&1; rm -rf %q' "$root" "$tmp" "$tmp")" EXIT
  git -C "$root" worktree add -q --detach "$tmp" "origin/$base" || die "cannot read $base of $slug"
  if [ "$dry" = true ]; then echo "knowledge: $slug (dry run: nothing changes)"; else echo "knowledge: $slug"; fi
  plan=$(knowledge_files "$tmp" "$drafts" false)
  if ! grep -q '^would write' <<<"$plan"; then
    [ -z "$plan" ] || echo "$plan"
    echo "files: nothing to change on $base"
  elif [ "$dry" = true ]; then
    echo "$plan"
    echo "would open: a draft pull request on $base with these files"
  else
    pr=$(gh_retry pr list --repo "$slug" --head "$branch" --state open --json url --jq '.[0].url // empty') || die "cannot list the pull requests of $slug"
    if [ -n "$pr" ]; then
      echo "$plan"
      echo "files: the pull request is already open: $pr"
    else
      # A branch left by an earlier run that stopped before the pull request.
      ! git -C "$tmp" ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1 ||
        git_bound -C "$tmp" push -q origin --delete "$branch" || die "cannot delete the stale branch $branch"
      git -C "$tmp" switch -q -c "$branch" || die "cannot create the branch $branch"
      report=$(knowledge_files "$tmp" "$drafts" true)
      echo "$report"
      git -C "$tmp" add -A
      git -C "$tmp" -c core.hooksPath=/dev/null commit -q -m "$title" \
        -m "Adds paths to the ADRs, a note per agent draft, a draft docs/vision.md, the architecture baseline. Generated by senior-mode setup repo --knowledge." ||
        die "cannot commit the knowledge layout"
      git_bound -C "$tmp" -c core.hooksPath=/dev/null push -q -u origin "$branch" || die "cannot push $branch"
      url=$(gh pr create --repo "$slug" --base "$base" --head "$branch" --draft --title "$title" \
        --body "Adopts the long-lived project layout (spec 325 section 9). Generated by \`senior-mode setup repo --knowledge\`; it changes no ticket.

The vision is a draft written from the README: the owner rewrites it before merging. The ADR paths are the union of the paths of the specs that cite them: correct them by hand.

$report") || die "cannot open the pull request"
      echo "files: draft pull request opened: $url"
    fi
  fi
  knowledge_labels "$slug" "$([ "$dry" = true ] && echo false || echo true)" "$tmp"
  knowledge_epic "$slug" "$([ "$dry" = true ] && echo false || echo true)"
  knowledge_orphans "$slug" "$tmp"
  [ "$dry" = false ] || echo "knowledge: dry run, nothing changed; senior-mode setup repo --knowledge does it"
}
