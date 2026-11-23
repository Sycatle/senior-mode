# shellcheck shell=bash
# Where the result of `check` is kept for a commit, until `publish` sends it (ADR 0006).
check_record() {
  printf '%s/%s\n' "$(git rev-parse --git-path senior-mode/checks)" "$1"
}

# How many full logs of failed checks are kept; the oldest go first.
CHECK_LOGS_KEEP=20

# Keeps the output file $2 of the failed check $1 as a log of its own, under senior-mode/check-logs of the git
# directory (#294), removes the oldest logs past CHECK_LOGS_KEEP, and prints the path of the new one. Prints
# nothing when the log cannot be written: the tail shown is then all there is.
check_log_keep() {
  local dir slug log f i=0
  dir=$(git rev-parse --path-format=absolute --git-path senior-mode/check-logs) || return 0
  slug=$(slugify "$1")
  log=$dir/$(date -u +%Y%m%d-%H%M%S)-$$-${slug:-check}.log
  { mkdir -p "$dir" && cp "$2" "$log"; } 2>/dev/null || return 0
  while IFS= read -r f; do
    i=$((i + 1))
    [ "$i" -le "$CHECK_LOGS_KEEP" ] || rm -f "$dir/$f"
  done < <(ls -1t "$dir" 2>/dev/null)
  printf '%s\n' "$log"
}

# Whether `check` audits the dependencies (`audit`, on by default); anything but a boolean is an error.
audit_enabled() {
  local value
  value=$(config_get audit)
  [[ $value =~ ^(true|false)$ ]] || die "audit must be true or false, not $value"
  [ "$value" = true ]
}

# The paths a push changes, from the lines git gives a pre-push hook on stdin (<ref> <sha> <remote ref>
# <remote sha>): what the remote does not have yet. Prints nothing and fails when they cannot all be told
# (no ref, a deletion, a remote commit this clone does not have, a new branch with no base): the caller then
# runs everything.
pushed_paths() {
  local sha rsha from found=false
  while read -r _ sha _ rsha; do
    [[ $sha =~ ^0+$ ]] && return 1
    if [[ $rsha =~ ^0+$ ]]; then
      from=$(default_branch) && from=$(git merge-base "$sha" "$from") || return 1
    else
      git cat-file -e "$rsha^{commit}" 2>/dev/null || return 1
      from=$rsha
    fi
    git -c core.quotePath=false diff --name-only --no-renames "$from" "$sha" || return 1
    found=true
  done
  $found
}

# The drift between the accepted specs and the code (#169). For each docs/specs/*.md whose front matter says
# `status: accepted`: the commits (first parent only, so a merge counts once) that touched its `paths` since
# the spec file last changed and carry no `Spec-Unchanged: <reason>` line, neither in their message nor in the
# body of a pull request they belong to. The pull requests of a commit are the ones GitHub associates with it
# (`associatedPullRequests`), whatever the merge method and the subject; they are read in batched GraphQL calls
# (50 commits each, one alias per commit), only for the commits that need one. Prints
# {"drift": [{spec, id, title, commits: [{sha, pr, subject}]}], "note": null|"<why>"}, `pr` being the merged
# pull request of the commit, or null. When the pull requests cannot be read (no gh, offline) the drift is left
# out and the note says so: a guess would blame commits that are fine.
spec_drift() {
  local root spec fm title id globs g since sha msg subject slug owner name q resp i j prn ok note="" rows="" key
  local -a specs=() pathspec=() shas=() need=() chunk=() spec_order=()
  local -A spec_shas=() msg_ok=() sha_pr=() sha_subject=() pr_ok=() meta=()
  local unchanged='^[[:space:]]*Spec-Unchanged:[[:space:]]*[^[:space:]]'
  root=$(git rev-parse --show-toplevel) || return 1
  mapfile -t specs < <(git -C "$root" ls-files -- 'docs/specs/*.md')
  for spec in "${specs[@]}"; do
    fm=$(awk 'NR == 1 && $0 != "---" { exit } NR > 1 && $0 == "---" { exit } NR > 1 { print }' "$root/$spec" 2>/dev/null) || continue
    [ "$(sed -n 's/^status:[[:space:]]*//p' <<<"$fm" | tr -d "\"' \r")" = accepted ] || continue
    globs=$(sed -n 's/^paths:[[:space:]]*\[\(.*\)\][[:space:]]*$/\1/p' <<<"$fm")
    pathspec=()
    while IFS= read -r g; do
      g=$(tr -d "\"'\r" <<<"$g" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
      [ -z "$g" ] || pathspec+=(":(glob)$g")
    done < <(tr ',' '\n' <<<"$globs")
    [ "${#pathspec[@]}" -gt 0 ] || continue
    since=$(git -C "$root" log -1 --format=%H -- "$spec") && [ -n "$since" ] || continue
    mapfile -t shas < <(git -C "$root" log --first-parent --format=%H "$since..HEAD" -- "${pathspec[@]}" 2>/dev/null)
    [ "${#shas[@]}" -gt 0 ] || continue
    id=$(sed -n 's/^id:[[:space:]]*//p' <<<"$fm" | tr -d "\"'\r" | head -n 1)
    title=$(sed -n 's/^title:[[:space:]]*//p' <<<"$fm" | tr -d '\r' | head -n 1)
    meta[$spec]="$id"$'\t'"$title"
    spec_order+=("$spec")
    spec_shas[$spec]="${shas[*]}"
    for sha in "${shas[@]}"; do
      [ -z "${sha_subject[$sha]+x}" ] || continue
      msg=$(git -C "$root" log -1 --format=%B "$sha")
      subject=$(head -n 1 <<<"$msg")
      sha_subject[$sha]=$subject
      if grep -qiE "$unchanged" <<<"$msg"; then msg_ok[$sha]=1; fi
    done
  done
  for sha in "${!sha_subject[@]}"; do
    [ -n "${msg_ok[$sha]:-}" ] || need+=("$sha")
  done
  if [ "${#need[@]}" -gt 0 ]; then
    mapfile -t need < <(printf '%s\n' "${need[@]}" | sort)
    slug=$(repo_slug 2>/dev/null) || slug=""
    if [ -z "$slug" ] || ! command -v gh >/dev/null; then
      note="pull requests not read: no GitHub remote or no gh"
    else
      owner=${slug%%/*} name=${slug#*/}
      for ((i = 0; i < ${#need[@]}; i += 50)); do
        chunk=("${need[@]:i:50}")
        # shellcheck disable=SC2016 # GraphQL variables, not shell
        q='query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) {'
        for j in "${!chunk[@]}"; do
          q+=" c$j: object(oid: \"${chunk[j]}\") { ... on Commit { associatedPullRequests(first: 5) { nodes { number state body } } } }"
        done
        q+=' } }'
        if resp=$(jq -nc --arg q "$q" --arg o "$owner" --arg n "$name" '{query: $q, variables: {owner: $o, name: $n}}' |
          gh_retry api graphql --input - 2>/dev/null) && jq -e '.data.repository' <<<"$resp" >/dev/null 2>&1; then
          while IFS=$'\t' read -r j ok prn; do
            sha=${chunk[j]}
            sha_pr[$sha]=${prn:-}
            [ "$ok" != 1 ] || pr_ok[$sha]=1
          done < <(jq -r '.data.repository | to_entries[] | (.value.associatedPullRequests.nodes // []) as $n
            | [(.key[1:] | tonumber), ($n | any(.[]; (.body // "") | test("(^|\\n)[ \\t]*Spec-Unchanged:[ \\t]*[^ \\t\\n]"; "i")) | if . then 1 else 0 end),
              ([$n[] | select(.state == "MERGED")][0] // $n[0] // {} | .number // "")] | @tsv' <<<"$resp")
        else
          note="pull requests not read: GitHub did not answer"
          break
        fi
      done
    fi
  fi
  if [ -z "$note" ]; then
    for spec in "${spec_order[@]}"; do
      for sha in ${spec_shas[$spec]}; do
        [ -z "${msg_ok[$sha]:-}" ] && [ -z "${pr_ok[$sha]:-}" ] || continue
        key=${meta[$spec]}
        rows+=$(printf '%s\t%s\t%s\t%s\t%s' "$spec" "$key" "${sha:0:7}" "${sha_pr[$sha]:-}" "${sha_subject[$sha]}")$'\n'
      done
    done
  fi
  jq -Rsc --arg note "$note" 'split("\n") | map(select(length > 0) | split("\t")) | group_by(.[0])
    | {drift: map({spec: .[0][0], id: .[0][1], title: .[0][2],
        commits: map({sha: .[3], pr: (if .[4] == "" then null else (.[4] | tonumber) end), subject: (.[5:] | join("\t"))})}),
       note: (if $note == "" then null else $note end)}' <<<"$rows"
}

# The warning of `check` about the spec drift: a line per drifting spec, and a note when it could not be told.
# Never fails: the drift is advice, not a gate.
spec_drift_warn() {
  local out
  out=$(spec_drift 2>/dev/null) || return 0
  jq -r '(.drift[] | "warn  spec drift: \(.spec): \(.commits | length) \(if (.commits | length) == 1 then "commit" else "commits" end) under its paths since it last changed, with no Spec-Unchanged (senior-mode status lists them)"),
    (if .note then "note: spec drift not checked: \(.note)" else empty end)' <<<"$out" 2>/dev/null || true
}

# Runs the built-in secret scan and dependency audit, then the configured checks, from the repository
# root, each with the time it took. On a clean tree, records the result for HEAD. With --pre-push (the
# hook's stdin is the pushed refs) the checks get the changed paths in SENIOR_MODE_CHANGED_FILES, so one that
# can narrow itself to them does; that run is not recorded, because publish needs a full one.
check() {
  local file root count i name cmd output passed=0 failed="" state description names cmds started took scope="" log rundir runtmp
  file=$(config_file)
  unset SENIOR_MODE_CHANGED_FILES
  if [ "${1:-}" = --pre-push ]; then
    scope=$(mktemp)
    if pushed_paths >"$scope"; then
      export SENIOR_MODE_CHANGED_FILES=$scope
    else
      rm -f "$scope"
      scope=""
    fi
  fi
  root=$(git rev-parse --show-toplevel)
  count=$(jq '.checks // [] | length' "$file")
  [ "$count" -gt 0 ] || die "no checks in .claude/senior-mode.json; run /senior-mode:setup"
  # Without its dependencies a node project fails typecheck and build with errors that do not say so (#110).
  if deps_missing "$root"; then
    echo "FAIL  dependencies not installed: run $(install_command "$root")"
    rm -f "$scope"
    return 1
  fi
  # The secret scan is not configurable: it runs first, on every preset. The dependency audit follows, and
  # `audit: false` turns it off (ADR 0015). The new dependencies are looked up on their registries (#302). The
  # `config` step reads the configuration against its schema (#317).
  names=("secret scan" "dependency audit" "new dependencies" "config")
  cmds=("$(printf '%q' "$SELF") secret-scan" "$(printf '%q' "$SELF") audit" "$(printf '%q' "$SELF") deps" "$(printf '%q' "$SELF") config validate")
  for ((i = 0; i < count; i++)); do
    names+=("$(jq -r ".checks[$i].name" "$file")")
    cmds+=("$(jq -r ".checks[$i].run" "$file")")
  done
  count=${#names[@]}
  # Parallel sessions run `check` at the same time (#295): this run has a directory of its own, mktemp's name
  # being unique, for its output and for the TMPDIR its checks see, so that no two runs share a temp path.
  rundir=$(mktemp -d)
  output=$rundir/output
  mkdir "$rundir/tmp"
  for ((i = 0; i < count; i++)); do
    name=${names[i]}
    cmd=${cmds[i]}
    started=$(now_ms)
    runtmp=$rundir/tmp
    # End-to-end suites are heavy: parallel tickets share e2e.slots of them per machine. Their lock is
    # machine-wide, so only the suite gets the private TMPDIR, not the lock (its fallback directory is in TMPDIR).
    if [ "$name" = e2e ]; then
      cmd="$(printf '%q' "$SELF") e2e-lock -- env TMPDIR=$(printf '%q' "$runtmp") bash -c $(printf '%q' "$cmd")"
      runtmp=${TMPDIR:-/tmp}
    fi
    # Git exports GIT_DIR to hooks, absolute in a linked worktree: a check that runs git on a test
    # fixture would write into this repository.
    if (cd "$root" && for v in $(git rev-parse --local-env-vars); do unset "$v"; done && export TMPDIR=$runtmp && bash -c "$cmd") \
      >"$output" 2>&1; then
      took=$(since_ms "$started")
      passed=$((passed + 1))
      # A check with nothing to do says so on its first line; show why instead of a bare ok.
      if [[ $(head -n 1 "$output") == "skipped: "* ]]; then
        echo "skip  $name: $(head -n 1 "$output" | cut -c10-) ($took)"
      else
        echo "ok    $name ($took)"
      fi
      # A warning of a passing check (an advisory with no severity) is shown, not lost.
      { grep '^warning: ' "$output" || true; } | sed 's/^/      /'
    else
      took=$(since_ms "$started")
      failed="${failed:+$failed, }$name"
      echo "FAIL  $name ($took)"
      # The audit lists every blocking advisory (it caps them itself); another check shows its last lines.
      tail -n "$([ "$name" = "dependency audit" ] && echo 300 || echo 20)" "$output" | sed 's/^/      /'
      log=$(check_log_keep "$name" "$output")
      [ -z "$log" ] || echo "      full log: $log"
    fi
  done
  rm -rf "$rundir"
  rm -f "$scope"
  spec_drift_warn
  if [ -z "$failed" ]; then
    state=success description="$passed/$count checks passed"
  else
    state=failure description="failed: $failed"
  fi
  description=${description:0:140}
  if [ -n "$scope" ]; then
    echo "note: narrowed to the pushed paths, result not recorded for publishing"
  elif [ -z "$(git status --porcelain)" ]; then
    mkdir -p "$(dirname "$(check_record x)")"
    printf '%s\n%s\n' "$state" "$description" >"$(check_record "$(git rev-parse HEAD)")"
  else
    echo "note: uncommitted changes, result not recorded for publishing"
  fi
  echo "$description"
  [ "$state" = success ]
}

# Open pull requests that contain a commit, with the issues each closes (for the security status).
# shellcheck disable=SC2016 # a GraphQL query, not shell
ASSOC_QUERY='query($owner: String!, $name: String!, $sha: GitObjectID!) { repository(owner: $owner, name: $name) {
  object(oid: $sha) { ... on Commit { associatedPullRequests(first: 10) { nodes { number state
    closingIssuesReferences(first: 20) { nodes { number } } } } } } } }'

# What `publish` says of senior-mode/security on a commit, as "<state> <description>" (ADR 0015): success
# "not required" only when no protected zone of the base branch is touched and no ticket the pull
# request closes is L; pending in every other case, also when that cannot be read. The globs come from
# the base branch, so a branch cannot lift its own zone.
security_verdict() {
  local sha=$1 base globs files zones slug answer issues n size
  GIT_TERMINAL_PROMPT=0 git_bound fetch -q origin 2>/dev/null || true # the base as it is now; offline, the last fetch stands
  base=$(default_branch) || { echo "pending required: no default branch to compare with"; return; }
  if git cat-file -e "$base:.claude/senior-mode.json" 2>/dev/null; then
    globs=$(git show "$base:.claude/senior-mode.json" | jq -c '.protected // []') || globs=null
  else
    globs=$(config_get protected 2>/dev/null) || globs='[]'
  fi
  jq -e 'type == "array" and all(type == "string")' <<<"$globs" >/dev/null ||
    { echo "pending required: protected is not a list of globs"; return; }
  files=$(git -c core.quotePath=false diff --name-only --no-renames "$base...$sha") ||
    { echo "pending required: cannot compare with $base"; return; }
  zones=$(protected_match "$globs" <<<"$files")
  [ -z "$zones" ] || { echo "pending required: protected zone ($(paste -sd, - <<<"$zones" | sed 's/,/, /g'))"; return; }
  slug=$(repo_slug)
  answer=$(jq -nc --arg q "$ASSOC_QUERY" --arg o "${slug%%/*}" --arg n "${slug#*/}" --arg s "$sha" \
    '{query: $q, variables: {owner: $o, name: $n, sha: $s}}' | gh_retry api graphql --input -) || answer=""
  if [ -z "$answer" ] || ! issues=$(jq -r '[.data.repository.object.associatedPullRequests.nodes[] | select(.state == "OPEN")]
    | if length == 0 then error("no open pull request") else [.[].closingIssuesReferences.nodes[].number] | unique | .[] end' \
    <<<"$answer" 2>/dev/null); then
    echo "pending required: no open pull request found for this commit, so its tickets are unknown"
    return
  fi
  for n in $issues; do
    size=$( (item_get "$n" Size) 2>/dev/null) || size=""
    [ -n "$size" ] || { echo "pending required: the Size of #$n is unknown"; return; }
    [ "$size" != L ] || { echo "pending required: closes the L ticket #$n"; return; }
  done
  echo "success not required: no protected zone, not L"
}

# Publishes the recorded check result of a commit as the status senior-mode/ci, and senior-mode/security
# when the pull request does not need the security pass. A due pass is left pending, and a status the
# security agent already set on the commit is never overwritten.
publish() {
  local sha record state description slug verdict current
  sha=$(git rev-parse --verify "${1:-HEAD}^{commit}" 2>/dev/null) || die "unknown commit: ${1:-HEAD}"
  record=$(check_record "$sha")
  [ -f "$record" ] || die "no check result for ${sha:0:7}; run senior-mode check on a clean tree first"
  state=$(sed -n 1p "$record")
  description=$(sed -n 2p "$record")
  slug=$(repo_slug)
  gh_retry api "repos/$slug/statuses/$sha" -f state="$state" -f context=senior-mode/ci \
    -f description="$description" >/dev/null ||
    die "could not publish the status of ${sha:0:7}; push the commit first"
  echo "senior-mode/ci = $state on ${sha:0:7}: $description"
  verdict=$(security_verdict "$sha")
  state=${verdict%% *} description=${verdict#* }
  # Only publish's own words are replaced: a success "not required", a pending "required: ...". Any
  # other state of the context is the security agent's (or a person's) and stays.
  current=$(gh_retry api "repos/$slug/commits/$sha/status" --jq '[.statuses[] | select(.context == "senior-mode/security")
    | select(((.state == "success" and (.description // "" | startswith("not required")))
      or (.state == "pending" and (.description // "" | startswith("required:")))) | not) | .state][0] // empty') || die "could not read the security status of ${sha:0:7}"
  [ -z "$current" ] || { echo "senior-mode/security = $current on ${sha:0:7}: left as it is"; return 0; }
  gh_retry api "repos/$slug/statuses/$sha" -f state="$state" -f context=senior-mode/security \
    -f description="${description:0:140}" >/dev/null || die "could not publish the security status of ${sha:0:7}"
  echo "senior-mode/security = $state on ${sha:0:7}: $description"
}
