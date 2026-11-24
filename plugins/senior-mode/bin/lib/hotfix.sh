# shellcheck shell=bash
# The hotfix lane (#322): a production emergency keeps the whole process (issue, branch, check, pull request,
# independent review, audit trail) and shortens only what the ticket allows: the queue, the size budget, the release.

# Whether the ticket $2 of $1 (owner/name) carries the label `hotfix`: prints yes or no; fails when the labels cannot be read.
ticket_hotfix() {
  local labels
  labels=$(gh_retry issue view "$2" --repo "$1" --json labels --jq '.labels[]?.name') || return 1
  if grep -qx hotfix <<<"$labels"; then echo yes; else echo no; fi
}

# Whether the pull request $2 (its REST object) of $1 closes a hotfix ticket. A ticket whose labels cannot be read
# counts as one: the independent review is only lifted for a pull request known to be no hotfix.
pr_hotfix() {
  local n hot
  while read -r n; do
    [ -n "$n" ] || continue
    hot=$(ticket_hotfix "$1" "$n") || return 0
    [ "$hot" != yes ] || return 0
  done < <(pr_closed_tickets "$(jq -r '.body // ""' <<<"$2")")
  return 1
}

# Whether ticket $2 of the board data $1 carries the label `hotfix`.
hotfix_item() {
  jq -e --argjson n "$2" '[.items[] | select(.number == $n) | .labels | index("hotfix") != null] | any' <<<"$1" >/dev/null
}

# senior-mode hotfix <issue>: puts a production emergency ahead of everything. The ticket gets the label `hotfix` (and
# `type:bug` when it has no type), Priority P0, Severity critical and Size S (the S diff budget caps its pull request),
# is started at once (the wip limit does not hold it back; the daemon leaves an In progress ticket alone) and gets an
# incident note, docs/incidents/<date>-<issue>-<slug>.md, in its worktree, to be committed with the fix. The independent
# review stays mandatory whatever process.profile says, and `release --patch` follows the merge.
hotfix() {
  [ $# -eq 1 ] && [[ $1 =~ ^[1-9][0-9]*$ ]] || usage
  local n=$1 slug info state title labels add=hotfix started path name note
  slug=$(repo_slug)
  info=$(gh_retry issue view "$n" --repo "$slug" --json title,labels,state) || die "cannot read issue #$n"
  state=$(jq -r '.state' <<<"$info")
  [ "$state" = OPEN ] || die "issue #$n is ${state,,}"
  title=$(jq -r '.title' <<<"$info")
  labels=$(jq -r '.labels[].name' <<<"$info")
  grep -q '^type:' <<<"$labels" || add+=",type:bug"
  gh_retry label create hotfix --repo "$slug" --color B60205 --description "A production emergency: ahead of the queue, S budget, reviewed, patch release" --force >/dev/null ||
    die "cannot create the label hotfix"
  gh_retry issue edit "$n" --repo "$slug" --add-label "$add" >/dev/null || die "cannot label #$n"
  item_set "$n" Priority P0 Size S Status Ready || die "cannot set the fields of #$n"
  if jq -e '.project.fields.Severity.options.critical' "$(config_file)" >/dev/null 2>&1; then
    item_set "$n" Severity critical || die "cannot set the Severity of #$n"
  else
    echo "hotfix: no Severity critical on the board; Priority P0 still puts #$n first" >&2
  fi
  started=$(start "$n") || exit 1
  printf '%s\n' "$started"
  path=$(sed -n 's/^worktree //p' <<<"$started")
  name=$(slugify "$title")
  note="docs/incidents/$(date -u +%F)-$n${name:+-$name}.md"
  if compgen -G "$path/docs/incidents/*-$n-*.md" >/dev/null || compgen -G "$path/docs/incidents/*-$n.md" >/dev/null; then
    echo "incident note already there for #$n"
    return 0
  fi
  mkdir -p "$path/docs/incidents"
  printf '%s\n' "# Incident: $title" '' "Ticket: #$n" "Opened: $(date -u +%FT%TZ)" '' \
    '## Impact' '' 'Who is affected, since when, how badly.' '' \
    '## Timeline' '' 'What was seen and done, with times (UTC), oldest first.' '' \
    '## Cause' '' 'Why it happened.' '' \
    '## Fix' '' 'What the pull request changes, and why it is the smallest change that stops the harm.' '' \
    '## Follow-ups' '' 'What would stop it from happening again: tickets, with their numbers.' >"$path/$note"
  echo "incident $path/$note"
}

# After the merge of pull request $2 of ticket $1: when it was a hotfix, opens the patch release (`release --patch`).
# A failure is said, never fatal: the merge is done.
hotfix_release() {
  local hot
  hot=$(ticket_hotfix "$(repo_slug)" "$1") || return 0
  [ "$hot" = yes ] || return 0
  if (release --patch) >/dev/null; then
    echo "pull request #$2 was a hotfix: the patch release is opened (merge its release pull request to ship it)"
  else
    echo "pull request #$2 was a hotfix: could not open the patch release; run senior-mode release --patch" >&2
  fi
}
