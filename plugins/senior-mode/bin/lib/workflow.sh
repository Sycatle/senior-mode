# shellcheck shell=bash
# Following the workflow of the project (spec 409 §3, ADR 0022). Everything here reads the `workflow` object that
# `setup repo` detected (workflow_get, common.sh) and falls back to today's behaviour for a key that is absent.

# Whether the checkout $1 (default: this one) has a detected workflow.
workflow_active() {
  local root=${1:-}
  [ -n "$root" ] || root=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
  jq -e '.workflow | type == "object"' "$root/.claude/senior-mode.json" >/dev/null 2>&1
}

WORKFLOW_DEFAULT_PATTERN='{type}/{issue}-{slug}'

# The branch name pattern of the checkout $1.
workflow_branch_pattern() {
  local p
  p=$(workflow_get branch.pattern "${1:-}")
  printf '%s\n' "${p:-$WORKFLOW_DEFAULT_PATTERN}"
}

# A branch name: $2 the senior-mode type (feat, fix, chore), $3 the issue, $4 the slug (may be empty), $5 the
# tracker key (may be empty), for the checkout $1. The type goes through workflow.branch.types.
workflow_branch_name() {
  local pat type=$2 slug=$4 name
  pat=$(workflow_branch_pattern "$1")
  name=$(workflow_get "branch.types.$type" "$1")
  type=${name:-$type}
  if [ -z "$slug" ]; then
    pat=${pat//-\{slug\}/}
    pat=${pat//_\{slug\}/}
    pat=${pat//\/\{slug\}/}
  fi
  # An absent issue or key takes its separator with it.
  [ -n "$3" ] || { pat=${pat//\{issue\}-/}; pat=${pat//\{issue\}_/}; }
  [ -n "$5" ] || { pat=${pat//\{key\}-/}; pat=${pat//\{key\}_/}; }
  pat=${pat//\{type\}/$type}
  pat=${pat//\{issue\}/$3}
  pat=${pat//\{key\}/$5}
  printf '%s\n' "${pat//\{slug\}/$slug}"
}

# A PCRE with one named group `n`, the issue number, that matches the branches of the pattern of the checkout $1;
# nothing when the pattern has no {issue} (a branch then maps back through workflow_record_branch).
workflow_branch_re() {
  local pat out="" c
  pat=$(workflow_branch_pattern "${1:-}")
  [[ $pat == *'{issue}'* ]] || return 0
  if [ "$pat" = "$WORKFLOW_DEFAULT_PATTERN" ]; then
    printf '%s\n' '^[a-z]+/(?<n>[0-9]+)(-|$)'
    return 0
  fi
  while [ -n "$pat" ]; do
    case $pat in
      '-{slug}'*) out+='(-.*)?'; pat=${pat#-\{slug\}} ;;
      '{type}'*) out+='[A-Za-z0-9._-]+'; pat=${pat#\{type\}} ;;
      '{issue}'*) out+='(?<n>[0-9]+)'; pat=${pat#\{issue\}} ;;
      '{key}'*) out+='[A-Za-z][A-Za-z0-9]*-[0-9]+'; pat=${pat#\{key\}} ;;
      '{slug}'*) out+='.*'; pat=${pat#\{slug\}} ;;
      *)
        c=${pat:0:1}
        if [[ $c =~ [A-Za-z0-9_/-] ]]; then out+=$c; else out+="\\$c"; fi
        pat=${pat:1}
        ;;
    esac
  done
  printf '^%s$\n' "$out"
}

# The jq definition `bre($n)`: the regex of the branches of issue $n, from SENIOR_MODE_BRANCH_RE (set by the entry point
# from the project's pattern) or senior-mode's default. A jq program that finds the ticket of a branch starts with it.
# shellcheck disable=SC2016 # a jq program, not shell
BRANCH_DEF='def bre($n): ($ENV.SENIOR_MODE_BRANCH_RE // "^[a-z]+/(?<n>[0-9]+)(-|$)") | sub("\\(\\?<n>\\[0-9\\]\\+\\)"; "\($n)"); '

# Where the branches of a pattern with no {issue} are mapped to their issue: one `<branch> <issue>` line each.
workflow_branch_map() {
  printf '%s/senior-mode/branch-issues\n' "$(git rev-parse --path-format=absolute --git-common-dir)"
}

# The map as a JSON object, branch to issue number.
workflow_branch_map_json() {
  jq -Rn '[inputs | split(" ") | select(length == 2) | {(.[0]): (.[1] | tonumber)}] | add // {}' 2>/dev/null <"$(workflow_branch_map)" || echo '{}'
}

# Remembers that branch $1 is the one of issue $2 (only a pattern with no {issue} needs it).
workflow_record_branch() {
  local map
  [ -z "$(workflow_branch_re)" ] || return 0
  map=$(workflow_branch_map)
  mkdir -p "$(dirname "$map")"
  grep -qxF "$1 $2" "$map" 2>/dev/null || echo "$1 $2" >>"$map"
}

# The issue number of the branch $1, or nothing: through the pattern of the project, else the recorded map.
workflow_branch_issue() {
  local re n
  re=$(workflow_branch_re "${2:-}")
  if [ -z "$re" ]; then
    awk -v b="$1" '$1 == b { print $2; exit }' "$(workflow_branch_map)" 2>/dev/null || true
  elif [ "$re" = '^[a-z]+/(?<n>[0-9]+)(-|$)' ]; then
    [[ $1 =~ ^[a-z]+/([0-9]+)(-|$) ]] && printf '%s\n' "${BASH_REMATCH[1]}" || true
  else
    n=$(jq -nr --arg b "$1" --arg re "$re" '[$b | capture($re).n] | first // empty' 2>/dev/null) || n=""
    # A hotfix branch is named `<prefix><issue>-<slug>` whatever the pattern.
    [ -n "$n" ] || { [[ $1 =~ ^[a-z]+/([0-9]+)(-|$) ]] && n=${BASH_REMATCH[1]}; } || true
    printf '%s\n' "$n"
  fi
}

# The branch of the local repository $1 that is the branch of issue $2, when `start` made one before.
workflow_find_branch() {
  local b
  while IFS= read -r b; do
    [ "$(workflow_branch_issue "$b" "$1")" = "$2" ] || continue
    printf '%s\n' "$b"
    return 0
  done < <(git -C "$1" for-each-ref --format='%(refname:short)' refs/heads)
  return 1
}

# The tracker key of an issue body: its `Tracker: ABC-123` line.
workflow_tracker_key() {
  sed -nE 's/^Tracker:[[:space:]]*([A-Za-z][A-Za-z0-9]*-[0-9]+).*/\1/p' <<<"$1" | head -n 1
}

# The labels $2 (one per line) with the project's own names for senior-mode's turned back into senior-mode's,
# through workflow.labels of the checkout $1 (`type:bug` is `bug` there).
workflow_labels_normalize() {
  local map
  map=$(workflow_get labels "$1")
  [ -n "$map" ] || { printf '%s\n' "$2"; return 0; }
  jq -rR --argjson m "$map" '. as $l | ($m | to_entries | map(select(.value == $l)) | first | .key) // $l' <<<"$2"
}

# The project's name for a senior-mode label $2 (itself when the project has no counterpart), for the checkout $1.
workflow_label() {
  local root=${1:-} mapped
  [ -n "$root" ] || root=$(git rev-parse --show-toplevel 2>/dev/null) || { printf '%s\n' "$2"; return 0; }
  mapped=$(jq -r --arg l "$2" '.workflow.labels[$l] // empty' "$root/.claude/senior-mode.json" 2>/dev/null) || mapped=""
  printf '%s\n' "${mapped:-$2}"
}

# The merge flag of `gh pr merge` for the checkout $1: the project's method, rebase when it has none.
workflow_merge_flag() {
  case $(workflow_get merge "${1:-}") in
    squash) echo --squash ;;
    merge) echo --merge ;;
    *) echo --rebase ;;
  esac
}

# The branch a ticket targets and what kind of branch it is, as "<branch> <ticket|hotfix>", for the checkout $1:
# $2 the issue body, $3 its labels, one per line. The integration branch (the default branch in trunk), except for a
# `Base: <branch>` line or a `base:<branch>` label that names a release line (workflow.release.branches) or the
# integration or base branch, and a ticket labelled `hotfix` on a project with hotfix branches, which targets the
# base. Fails, naming why, for a branch that is none of those: the ticket is needs-human.
workflow_ticket_base() {
  local root=$1 body=$2 labels=$3 integration base want="" glob hot ok=false
  integration=$(workflow_get integration "$root")
  base=$(workflow_get base "$root")
  if [ -z "$integration" ] || [ -z "$base" ]; then
    local d
    d=$(cd "$root" && repo_default_branch) || d=main
    d=${d#origin/}
    integration=${integration:-$d}
    base=${base:-$d}
  fi
  want=$(sed -nE 's/^Base:[[:space:]]*([^[:space:]]+).*/\1/p' <<<"$body" | head -n 1 | tr -d '\r')
  [ -n "$want" ] || want=$(sed -n 's/^base://p' <<<"$labels" | head -n 1)
  hot=$(workflow_get release.hotfix "$root")
  if [ -z "$want" ] && [ -n "$hot" ] && grep -qx hotfix <<<"$labels"; then
    printf '%s hotfix\n' "$base"
    return 0
  fi
  [ -n "$want" ] || { printf '%s ticket\n' "$integration"; return 0; }
  if [ "$want" = "$integration" ] || [ "$want" = "$base" ]; then
    ok=true
  else
    while IFS= read -r glob; do
      # shellcheck disable=SC2053 # a glob of workflow.release.branches
      [[ $want == $glob ]] && ok=true
    done < <(workflow_get release.branches "$root" | jq -r '.[]?' 2>/dev/null)
  fi
  [ "$ok" = true ] || { echo "Base: $want is not the integration branch ($integration), the base ($base) or a release branch (workflow.release.branches)"; return 1; }
  printf '%s ticket\n' "$want"
}

# The ref of the branch $2 in the repository $1, fetched when it is not there yet; fails when there is none.
workflow_ref() {
  local b
  for b in "origin/$2" "$2"; do
    git -C "$1" rev-parse -q --verify "$b^{commit}" >/dev/null && { printf '%s\n' "$b"; return 0; }
  done
  git -C "$1" fetch -q origin "$2" 2>/dev/null || true
  git -C "$1" rev-parse -q --verify "origin/$2^{commit}" >/dev/null && { printf 'origin/%s\n' "$2"; return 0; }
  return 1
}

# Labels the issue $2 of $1 with $3 and says why ($4) in a comment: the ticket waits for a person, or for the missing
# information, as `senior-mode ready` leaves a ticket it cannot make Ready.
workflow_flag() {
  gh_retry api "repos/$1/issues/$2/labels" -f "labels[]=$3" >/dev/null || echo "#$2: could not label it $3" >&2
  gh_bound api "repos/$1/issues/$2/comments" -f body="senior-mode: $4" >/dev/null || echo "#$2: could not comment on it" >&2
}

# The paragraph of the prompts of a session about the workflow of the project, for the issue $1 and the branch
# $2 it works on; nothing for a project with no detected workflow.
workflow_prompt_block() {
  local n=$1 root info body labels target fmt pat tpl title link merge key subjects
  root=${RUN_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null)} || return 0
  workflow_active "$root" || return 0
  info=$(gh_retry issue view "$n" --repo "${RUN_SLUG:-$(repo_slug)}" --json body,labels 2>/dev/null) || info='{}'
  body=$(jq -r '.body // ""' <<<"$info")
  labels=$(workflow_labels_normalize "$root" "$(jq -r '.labels[]?.name' <<<"$info")")
  target=$(workflow_ticket_base "$root" "$body" "$labels" 2>/dev/null) && target=${target%% *} || target=$(workflow_get integration "$root")
  fmt=$(workflow_get commit.format "$root")
  pat=$(workflow_get commit.pattern "$root")
  tpl=$(workflow_get pr.template "$root")
  title=$(workflow_get pr.title "$root")
  link=$(workflow_get pr.link "$root")
  merge=$(workflow_get merge "$root")
  key=$(workflow_tracker_key "$body")
  echo "This project has a workflow of its own: follow it where it differs from senior-mode's defaults."
  [ -z "$target" ] || echo "- Target branch: open the pull request with \`--base $target\`; never against another branch."
  if [ -n "$fmt" ]; then
    echo "- Commits: format \`$fmt\`${pat:+, each subject must match \`$pat\`}."
    subjects=$(git -C "$root" log --no-merges -n 3 --format='  %s' "$(cd "$root" && default_branch)" 2>/dev/null || true)
    [ -z "$subjects" ] || printf '  The last subjects of the project:\n%s\n' "$subjects"
  fi
  [ -z "$key" ] || echo "- Tracker key of this ticket: \`$key\`; $([ "$fmt" = ticket-prefix ] && echo "every commit subject and the pull request title start with it" || echo "it travels in the branch name or the commit as the format says")."
  [ -z "$tpl" ] || echo "- Pull request: start its body from \`$tpl\`, keep every heading of the template and fill each one (a heading left empty is refused), then add the senior-mode blocks after them."
  [ -z "$title" ] || echo "- Pull request title: style \`$title\`."
  [ -z "$link" ] || [ "$link" = none ] || echo "- Link the issue with \`$link #$n\` in the body."
  [ -z "$merge" ] || echo "- The project merges with \`$merge\`; you never merge."
  return 0
}

# What the pull request $1 (its REST object) lacks of the project's workflow, in one phrase per gap joined by
# "; ", for the checkout $3 (default: this one): its base, the shape of its title, the headings of the project's
# template (each present and not empty) and the link to its issue. Nothing when it follows it, or when the project
# has no detected workflow. $2 is its issue number when known.
workflow_pr_gaps() {
  local pr=$1 issue=${2:-} root=${3:-} gaps="" expected body title base ref info labels tpl style kw pat tmp h
  [ -n "$root" ] || root=$(git rev-parse --show-toplevel 2>/dev/null) || return 0
  workflow_active "$root" || return 0
  body=$(jq -r '.body // ""' <<<"$pr")
  title=$(jq -r '.title // ""' <<<"$pr")
  base=$(jq -r '.base.ref // ""' <<<"$pr")
  ref=$(jq -r '.head.ref // ""' <<<"$pr")
  [ -n "$issue" ] || issue=$(workflow_branch_issue "$ref" "$root")
  [ -n "$issue" ] || issue=$(grep -oiE '(closes|fixes|resolves) #[0-9]+' <<<"$body" | head -n 1 | grep -oE '[0-9]+' || true)
  expected=$(workflow_get integration "$root")
  if [ -n "$issue" ]; then
    info=$(gh_retry issue view "$issue" --repo "${RUN_SLUG:-$(repo_slug)}" --json body,labels 2>/dev/null) || info='{}'
    labels=$(workflow_labels_normalize "$root" "$(jq -r '.labels[]?.name' <<<"$info")")
    expected=$(workflow_ticket_base "$root" "$(jq -r '.body // ""' <<<"$info")" "$labels" 2>/dev/null | cut -d' ' -f1) || expected=""
    [ -n "$expected" ] || expected=$(workflow_get integration "$root")
  fi
  [ -z "$expected" ] || [ "$base" = "$expected" ] || gaps+="${gaps:+; }it targets $base, the project's branch for it is $expected"
  style=$(workflow_get pr.title "$root")
  pat=$(workflow_get commit.pattern "$root")
  case $style in
    commit)
      [ -n "$pat" ] || pat='^[a-z]+(\(.+\))?!?: .+'
      [[ $title =~ $pat ]] || gaps+="${gaps:+; }its title does not match the commit format ($pat)"
      ;;
    ticket) [[ $title =~ ^[A-Za-z][A-Za-z0-9]*-[0-9]+ ]] || gaps+="${gaps:+; }its title does not start with a tracker key" ;;
  esac
  kw=$(workflow_get pr.link "$root")
  if [ -n "$kw" ] && [ "$kw" != none ] && [ -n "$issue" ]; then
    grep -qiE "$kw #$issue([^0-9]|\$)" <<<"$body" || gaps+="${gaps:+; }its body does not say \`$kw #$issue\`"
  fi
  tpl=$(workflow_get pr.template "$root")
  if [ -n "$tpl" ]; then
    tmp=$(mktemp)
    { git -C "$root" show "origin/$(workflow_get integration "$root"):$tpl" 2>/dev/null || cat "$root/$tpl" 2>/dev/null; } >"$tmp" || true
    while IFS= read -r h; do
      [ -n "$h" ] || continue
      # The heading must be in the body, with something under it besides comments and blank lines.
      if ! awk -v h="$h" '
        { sub(/\r$/, "") }
        $0 == h { on = 1; found = 1; next }
        on && /^#+[ \t]/ { on = 0 }
        on { line = $0; gsub(/<!--[^>]*-->/, "", line)
             if (inc) { if (line ~ /-->/) { sub(/.*-->/, "", line); inc = 0 } else next }
             if (line ~ /<!--/) { sub(/<!--.*/, "", line); inc = 1 }
             if (line ~ /[^ \t]/) filled = 1 }
        END { exit !(found && filled) }' <<<"$body"; then
        gaps+="${gaps:+; }the template heading \`$h\` is missing or empty"
      fi
    done < <(grep -E '^#{1,6}[ ]+[^ ]' "$tmp" | tr -d '\r')
    rm -f "$tmp"
  fi
  printf '%s\n' "$gaps"
}
