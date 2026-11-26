# shellcheck shell=bash
# Session checkpoints (#346, spec 325 §8.1): the block of the draft pull request of a ticket branch that says what is done, what
# is being done, what comes next and what was assumed, so that a resumed session reads it instead of exploring again. The block
# lives between two markers in the body; a checkpoint replaces it whole and touches nothing else of the body. The plan of the
# session (#352) is the fifth part of the block: it is the file $SENIOR_MODE_RUN_PLAN copied in, and what run_plan_gap reads back.

CHECKPOINT_BEGIN='<!-- senior-mode:checkpoint -->'
CHECKPOINT_END='<!-- /senior-mode:checkpoint -->'

# The lines of the block of the pull request body $1, markers left out; nothing when the body has no block.
checkpoint_inner() {
  tr -d '\r' <<<"$1" | awk -v b="$CHECKPOINT_BEGIN" -v e="$CHECKPOINT_END" '$0 == b { on = 1; next } $0 == e { on = 0 } on'
}

# The plan lines held in the block of the pull request body $1: the fenced text after the `**Plan**` heading.
checkpoint_plan() {
  checkpoint_inner "$1" | awk '/^\*\*Plan\*\*$/ { p = 1; next } p && /^```/ { if (f) exit; f = 1; next } p && f'
}

# The block, markers included. $1..$4 the items of Done, Doing, Next and Assumptions, one per line; $5 the plan, or nothing.
checkpoint_render() {
  local title list items fence='```' quotes="'''" plan=$5
  printf '%s\nUpdated %s\n' "$CHECKPOINT_BEGIN" "$(date -u +%FT%TZ)"
  for list in "Done:$1" "Doing:$2" "Next:$3" "Assumptions:$4"; do
    title=${list%%:*}
    items=${list#*:}
    printf '\n**%s**\n\n%s\n' "$title" "${items:-- none}"
  done
  [ -z "$plan" ] || printf '\n**Plan**\n\n%stext\n%s\n%s\n' "$fence" "${plan//$fence/$quotes}" "$fence"
  printf '%s\n' "$CHECKPOINT_END"
}

# The body $1 with its block replaced by the block $2, or ending with it when it has none.
checkpoint_replace() {
  if [ "$(grep -cxF "$CHECKPOINT_BEGIN" <<<"$1")" -eq 1 ] && grep -qxF "$CHECKPOINT_END" <<<"$1"; then
    BLK=$2 awk -v b="$CHECKPOINT_BEGIN" -v e="$CHECKPOINT_END" \
      '$0 == b { print ENVIRON["BLK"]; skip = 1; next } skip && $0 == e { skip = 0; next } !skip' <<<"$1"
  else
    printf '%s\n\n%s\n' "$1" "$2"
  fi
}

# `senior-mode checkpoint [--done <t>]... [--doing <t>]... [--next <t>]... [--assumption <t>]...`: rewrites the block of the
# draft pull request of the ticket branch (HEAD) with those four lists; a list not given is empty. With no pull request yet,
# the branch is pushed and a draft one is opened with `Closes #<n>`. The plan file of the session, when there is one, is kept in it.
checkpoint() {
  local done_="" doing="" next="" assume="" item branch issue slug ref base prs num body plan block title url
  [ $# -gt 0 ] || usage
  while [ $# -gt 0 ]; do
    [ $# -ge 2 ] && [ -n "$2" ] || usage
    item="- ${2//$'\n'/ }"$'\n'
    case $1 in
      --done) done_+=$item ;;
      --doing) doing+=$item ;;
      --next) next+=$item ;;
      --assumption) assume+=$item ;;
      *) usage ;;
    esac
    shift 2
  done
  branch=$(git symbolic-ref --short -q HEAD) || die "checkpoint: no branch is checked out"
  issue=$(workflow_branch_issue "$branch") && [ -n "$issue" ] || die "checkpoint: $branch is not the branch of a ticket"
  slug=$(repo_slug)
  prs=$(gh_retry pr list --repo "$slug" --head "$branch" --state open --json number,body) || die "checkpoint: cannot list the pull requests of $slug"
  num=$(jq -r '.[0].number // empty' <<<"$prs")
  body=$(jq -r '.[0].body // ""' <<<"$prs")
  plan=""
  [ -z "${SENIOR_MODE_RUN_PLAN:-}" ] || plan=$(head -c 6000 "$SENIOR_MODE_RUN_PLAN" 2>/dev/null) || plan=""
  [ -n "$plan" ] || plan=$(checkpoint_plan "$body")
  block=$(checkpoint_render "${done_%$'\n'}" "${doing%$'\n'}" "${next%$'\n'}" "${assume%$'\n'}" "$plan")
  if [ -n "$num" ]; then
    gh_retry pr edit "$num" --repo "$slug" --body "$(checkpoint_replace "$body" "$block")" >/dev/null ||
      die "checkpoint: could not update pull request #$num"
    echo "checkpoint: pull request #$num updated"
    return 0
  fi
  ref=$(default_branch) || die "checkpoint: no default branch to compare $branch with"
  base=${ref#origin/}
  [ "$(git rev-list --count "$ref..HEAD" 2>/dev/null || echo 0)" -gt 0 ] ||
    die "checkpoint: $branch has no commit yet, so no draft pull request can be opened; checkpoint after the first commit"
  title=$(git log --reverse --format=%s "$ref..HEAD" | sed -n 1p)
  git_bound push -q -u origin "$branch" || die "checkpoint: could not push $branch"
  url=$(gh_retry pr create --repo "$slug" --base "$base" --head "$branch" --draft --title "$title" \
    --body "Closes #$issue"$'\n\n'"$block") || die "checkpoint: could not open the draft pull request of $branch"
  echo "checkpoint: draft pull request opened: $url"
}
