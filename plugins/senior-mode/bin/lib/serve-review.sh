# shellcheck shell=bash
# Says why a pull request waits, once: the line is repeated only when the reason changes. $1 names the pull
# request, $2 is the line.
serve_note() {
  [ "${SERVE_NOTED[$1]:-}" != "$2" ] || return 0
  SERVE_NOTED[$1]=$2
  RUN_WAITING+=("$2")
}

# The state of each status of a commit, {context: state}.
serve_states() {
  gh_retry api "repos/$RUN_SLUG/commits/$1/status" --jq '[.statuses[] | {key: .context, value: .state}] | from_entries'
}

# A pull request that needs a person: needs-human on it and on its ticket, and why on the pull request.
serve_needs_human() {
  local n=$1 pr=$2 reason=$3 t
  for t in "$pr" "$n"; do
    gh_retry api "repos/$RUN_SLUG/issues/$t/labels" -f 'labels[]=needs-human' >/dev/null || echo "#$n: could not label #$t needs-human" >&2
  done
  gh_bound api "repos/$RUN_SLUG/issues/$pr/comments" -f body="senior-mode serve: $reason

It is labelled needs-human: a person decides what happens next." >/dev/null || echo "#$n: could not comment on #$pr" >&2
  serve_note "nh$pr" "#$n ${RUN_TITLE[$n]:-}: pull request #$pr, $reason"
}

# Whether a run_blocker reason $1 is one no poll will lift: merging off, an external pull request, no server protection,
# a protected zone, a pull request that is not ready (a ticket without its commit, a diff over its size budget: needs-human
# with the numbers, #297, #303) or that departs from the project's workflow.
# A status not green yet, a mergeable state or an unreadable answer is transient: the next poll looks again.
serve_permanent() {
  case $1 in
    "merging is off"* | "it is external"* | "the server enforces no branch protection"* | "it touches a protected zone"* | "the protected zones could not be read"* | "not ready: "* | "it does not follow the project's workflow"*) ;;
    *) return 1 ;;
  esac
}

# A pull request that cannot merge on its own (#282): the alert of #155 on the pull request (label, comment with
# the reason, webhook), needs-human on its ticket too. Candidates skip needs-human, so the next poll leaves it be.
serve_stuck() {
  local t=$1 pr=$2 reason=$3
  notify needs-human "$pr" "pull request #$pr (ticket #$t) cannot merge on its own: $reason"
  gh_retry api "repos/$RUN_SLUG/issues/$t/labels" -f 'labels[]=needs-human' >/dev/null || echo "#$t: could not label it needs-human" >&2
}

# The pull requests of tickets In review, in `pick` order, as `ticket pr sha branch title` lines: open, not a draft,
# not needs-human, on a branch named <type>/<ticket>-... $1 is the board, $2 the open pull requests. With $3 = held, the
# needs-human ones instead (serve_pending).
# shellcheck disable=SC2016 # a jq program, not shell
serve_candidates() {
  local re held=false
  [ "${3:-}" != held ] || held=true
  re=$(workflow_branch_re "$RUN_ROOT")
  jq -r --argjson held "$held" --slurpfile d <(printf '%s' "$1") --argjson map "$(workflow_branch_map_json)" --arg re "${re:-^[a-z]+/(?<n>[0-9]+)(-|\$)}" '$d[0] as $d | [.[] | . as $p
      | ((try ($p.head.ref | capture($re) | .n | tonumber) catch null) // $map[$p.head.ref]) as $t
      | select($t != null)
      | ($d.items[] | select(.number == $t and .open and .status == "In review")) as $i
      | select(((($i.labels | index("needs-human")) // ([$p.labels[]?.name] | index("needs-human"))) != null) == $held)
      | select(.draft | not)
      | {t: $t, pr: $p.number, sha: $p.head.sha, ref: $p.head.ref, title: $i.title,
         k: ([($i.priority // "") | scan("^P([0-9]+)") | .[0] | tonumber] | first // 99)}]
    | sort_by([.k, .t])[] | [.t, .pr, .sha, .ref, .title] | @tsv' <<<"$2"
}

# A pull request with no red-tests record for a feature or bug ticket $1 (#306, $4 says which): the ticket session
# resumes once on its branch to prove its tests (senior-mode red-tests verify). Returns 0 when it did, 1 when it
# already had its retry (or none can start): the caller then leaves the pull request to a person.
serve_red_retry() {
  local t=$1 pr=$2 reason=$4
  [ ! -f "$SERVE_DIR/red-retry-$t" ] || return 1
  serve_can_launch "$t" || return 1
  RUN_ROLE[$t]=ticket
  unset 'RUN_CWD[$t]'
  run_open "$t" || return 1
  : | state_write "$SERVE_DIR/red-retry-$t"
  serve_red_prompt "$t" "${RUN_TITLE[$t]:-}" "${RUN_BRANCH[$t]}" "$pr" "$reason" | state_write "$RUN_DIR/$t.prompt"
  echo "#$t: pull request #$pr has no red-tests record; the ticket session resumes once to prove its tests"
  if run_launch "$t" sonnet; then running+=("$t"); else return 1; fi
}

# Best-of-N (#367, spec 325 section 8.3): a ticket whose pull request $2 still has changes requested after its 2 fix rounds
# is a ticket that already failed once. Instead of a person, up to bestOf.n candidates (3 at most, the pull request being the
# first) are tried: the others start from the base, one at a time, on branches `<branch>-b2`, `-b3`, in their own worktrees
# (SENIOR_MODE_CANDIDATE, see `start`), each a session that counts against the slots and the hourly ceilings. The first
# candidate whose review passes merges as any pull request does, and serve_done closes the others (serve_close_candidates);
# a candidate whose review fails is closed (serve_candidate_lost). bestof-<n> holds the number of candidates started.
# Returns 0 when it took care of the pull request (a candidate starts or is awaited), 1 for the old end: needs-human,
# with bestOf.n at 1 (off) or once every candidate is out.
serve_bestof() {
  local t=$1 pr=$2 n k others
  n=$(serve_int bestOf.n 1)
  [ "$n" -le 3 ] || n=3
  [ "$n" -gt 1 ] || return 1
  k=$(state_num "$SERVE_DIR/bestof-$t")
  [ "$k" -ge 1 ] || k=1
  if [ "$k" -lt "$n" ]; then
    serve_candidate "$t" "$pr" $((k + 1)) "$n" || true
    return 0
  fi
  others=$(serve_ticket_prs "$t" "$pr")
  [ "$others" -gt 0 ]
}

# The number of open pull requests of ticket $1, the pull request $2 apart.
serve_ticket_prs() {
  jq -r --argjson pr "$2" --arg re "^[a-z]+/$1(-|\$)" '[.[] | select(.number != $pr and (.head.ref | test($re)))] | length' <<<"${SERVE_PRS:-[]}"
}

# The candidate $3 of $4 of ticket $1, against the pull request $2: its session starts when a slot is free.
serve_candidate() {
  local t=$1 pr=$2 k=$3 n=$4
  serve_can_launch "$t" || return 1
  RUN_ROLE[$t]=ticket
  unset 'RUN_CWD[$t]'
  SENIOR_MODE_CANDIDATE=$k run_open "$t" || return 1
  state_put "$SERVE_DIR/bestof-$t" "$k"
  {
    printf 'This is candidate %s of %s for this ticket. The first attempt, pull request #%s, still had changes requested after 2 fix\nrounds (`gh pr view %s --comments` says why). Start from the base branch, as it is in this worktree, and do not copy that\nattempt: solve the ticket your own way, and avoid what its reviewer found. Other candidates are worked on separately;\nonly the first whose review passes merges.\n\n' "$k" "$n" "$pr" "$pr"
    serve_prompt "$t" "${RUN_TITLE[$t]:-}" "${RUN_BRANCH[$t]}"
  } | state_write "$RUN_DIR/$t.prompt"
  echo "#$t: pull request #$pr still has changes requested after 2 fix rounds; candidate $k of $n starts on ${RUN_BRANCH[$t]}"
  if run_launch "$t" sonnet; then running+=("$t"); else return 1; fi
}

# A candidate pull request $2 of ticket $1 whose review failed is closed: a candidate has no fix rounds.
serve_candidate_lost() {
  local t=$1 pr=$2
  gh_bound api "repos/$RUN_SLUG/issues/$pr/comments" -f body="senior-mode serve: this candidate for #$t failed its review; it is closed. The other candidates go on." >/dev/null ||
    echo "#$t: could not comment on #$pr" >&2
  gh_retry api "repos/$RUN_SLUG/pulls/$pr" -X PATCH -f state=closed >/dev/null || echo "#$t: could not close pull request #$pr" >&2
}

# The merge of pull request $2 settles best-of-N for ticket $1 (it has a <bestof> file): the other open pull requests of the
# ticket, the candidates it beat, are closed with a comment that names the winner.
serve_close_candidates() {
  local t=$1 pr=$2 other
  [ -e "$SERVE_DIR/bestof-$t" ] || return 0
  rm -f "$SERVE_DIR/bestof-$t"
  for other in $(jq -r --argjson pr "$pr" --arg re "^[a-z]+/$t(-|\$)" '.[] | select(.number != $pr and (.head.ref | test($re))) | .number' <<<"${SERVE_PRS:-[]}"); do
    gh_bound api "repos/$RUN_SLUG/issues/$other/comments" -f body="senior-mode serve: closed. Candidate pull request #$pr of #$t passed its review and merged first." >/dev/null ||
      echo "#$t: could not comment on #$other" >&2
    gh_retry api "repos/$RUN_SLUG/pulls/$other" -X PATCH -f state=closed >/dev/null || echo "#$t: could not close pull request #$other" >&2
  done
}

# Changes requested on the pull request $2 (branch $3) of ticket $1: the ticket session resumes on the same
# branch with the findings, twice at most; then a person.
serve_changes() {
  local t=$1 pr=$2 ref=$3 rounds
  if [[ $ref =~ -b[2-9]$ ]]; then
    serve_candidate_lost "$t" "$pr"
    return 0
  fi
  rounds=$(state_num "$SERVE_DIR/rounds-$t")
  if [ "$rounds" -ge 2 ]; then
    serve_bestof "$t" "$pr" && return 0
    serve_needs_human "$t" "$pr" "the reviewer still requests changes after $rounds fix rounds"
    return 0
  fi
  serve_can_launch "$t" || return 0
  RUN_ROLE[$t]=ticket
  unset 'RUN_CWD[$t]'
  run_open "$t" || return 0
  state_put "$SERVE_DIR/rounds-$t" "$((rounds + 1))"
  serve_fix_prompt "$t" "${RUN_TITLE[$t]:-}" "${RUN_BRANCH[$t]}" "$pr" $((rounds + 1)) | state_write "$RUN_DIR/$t.prompt"
  echo "#$t: the reviewer requested changes on pull request #$pr; the ticket session resumes (round $((rounds + 1)) of 2)"
  if run_launch "$t" sonnet; then running+=("$t"); fi
}

# The model of the reviewer session of ticket $1 (#304): Opus, unless review.crossModel is on and the ticket's last
# implementer session ran on Opus (escalated): then review.otherModel, so that the reviewer is never the model that
# wrote the code. The implementer is read from the ticket's outcome file; a ticket with none was not Opus's.
serve_review_model() {
  local impl
  [ "$(config_get review.crossModel)" = false ] && {
    echo opus
    return 0
  }
  impl=$(jq -r '.model // empty' "$RUN_DIR/$1.json" 2>/dev/null) || impl=""
  if [ "$impl" = opus ]; then config_get review.otherModel; else echo opus; fi
}

# A pull request In review whose head has senior-mode/ci and no review status: a reviewer session on another model
# than the implementer's (serve_review_model), in a detached worktree of that head (ADR 0017, 0019: no reviewer, no
# review; the status stays unset and the next poll after a usage limit's reset tries again).
serve_review() {
  local t=$1 pr=$2 sha=$3 ref=$4 again=${5:-} wt model
  model=$(serve_review_model "$t")
  serve_can_launch "$t" || return 0
  git_bound fetch -q origin "$ref" 2>/dev/null || true
  wt=$(worktree_path "$RUN_ROOT" "review-$t")
  git worktree remove --force "$wt" 2>/dev/null || true
  if ! git worktree add -q --detach "$wt" "$sha" 2>/dev/null; then
    echo "#$t: could not open a worktree to review pull request #$pr; trying again at the next poll" >&2
    return 0
  fi
  RUN_ROLE[$t]=reviewer
  RUN_CWD[$t]=$wt
  RUN_WT[$t]=$wt
  RUN_BRANCH[$t]=$ref
  SERVE_PR[$t]=$pr
  SERVE_SHA[$t]=$sha
  serve_review_prompt "$t" "${RUN_TITLE[$t]:-}" "$pr" "$sha" "$model" "$again" | state_write "$RUN_DIR/$t.prompt"
  echo "#$t: reviewing pull request #$pr on $model"
  if run_launch "$t" "$model"; then running+=("$t"); else git worktree remove --force "$wt" 2>/dev/null || true; fi
}

# The time (epoch) of the last change of the review rules on the base branch: CLAUDE.md and the project config (protected
# list, review settings). Nothing when the history has none.
serve_rules_changed() {
  git_bound fetch -q origin 2>/dev/null || true
  git log -1 --format=%ct "$RUN_BASE" -- CLAUDE.md .claude/senior-mode.json 2>/dev/null || true
}

# The time (epoch) senior-mode/review was last set on commit $1; nothing when it is not set.
serve_review_stamp() {
  gh_retry api "repos/$RUN_SLUG/commits/$1/status" \
    --jq '[.statuses[] | select(.context == "senior-mode/review") | .updated_at | fromdateiso8601] | first // empty'
}

# The pull requests that wait for a person after a review left senior-mode/review pending (#674): the reviewer labels them
# needs-human, so the pass of serve_prs skips them, and none was ever looked at again. Once per head, one gets a fresh
# reviewer session (serve_review) when the review rules changed on the base branch since the review (serve_rules_changed),
# or when it is behind its base and the review is older than serve.pendingReviewHours; one in conflict with its base is
# resolved on a -rN branch by the integrator (serve_conflict), at most one per poll. $1 is the board, $2 the open pull requests.
serve_pending() {
  local t pr sha ref title states ci stamp changed="" fetched=false moved=false pull state due
  while IFS=$'\t' read -r t pr sha ref title; do
    [ -n "$t" ] || continue
    [ "$SERVE_TERM" = false ] || break
    serve_busy "$t" && continue
    states=$(serve_states "$sha") || continue
    [ "$(jq -r '.["senior-mode/review"] // empty' <<<"$states")" = pending ] || continue
    stamp=$(serve_review_stamp "$sha") || continue
    [[ $stamp =~ ^[0-9]+$ ]] || continue
    RUN_TITLE[$t]=$title
    pull=$(gh_retry api "repos/$RUN_SLUG/pulls/$pr") || continue
    state=$(jq -r '.mergeable_state // "unknown"' <<<"$pull")
    if [ "$state" = dirty ]; then
      if [ "$moved" = false ] && serve_conflict "$t" "$pr" "$ref"; then moved=true; fi
      continue
    fi
    [ "$(state_get "$SERVE_DIR/rereview-$pr" '[0-9a-f]+')" != "$sha" ] || continue
    ci=$(jq -r '.["senior-mode/ci"] // empty' <<<"$states")
    [ "$ci" = success ] || continue
    if [ "$fetched" = false ]; then
      changed=$(serve_rules_changed)
      fetched=true
    fi
    due=false
    [[ $changed =~ ^[0-9]+$ ]] && [ "$changed" -gt "$stamp" ] && due=true
    [ "$state" != behind ] || [ $(($(serve_now) - stamp)) -lt $((SERVE_PENDING_HOURS * 3600)) ] || due=true
    [ "$due" = true ] || continue
    state_put "$SERVE_DIR/rereview-$pr" "$sha"
    serve_review "$t" "$pr" "$sha" "$ref" again
  done < <(serve_candidates "$1" "$2" held)
}

# Every pull request of a ticket In review, in `pick` order: its head decides. CI success and no review
# status: a reviewer session. Review failure: the ticket session resumes. Review success: merged (the integrator
# pass), at most one per poll.
serve_prs() {
  local data=$1 prs=$2 acted=false t pr sha ref title states review ci old gate
  # The independent review is a locked gate; a profile lifts it only with an accepted ADR (process.gates.review).
  gate=$(config_get process.gates.review) || gate=true
  while IFS=$'\t' read -r t pr sha ref title; do
    [ -n "$t" ] || continue
    [ "$SERVE_TERM" = false ] || break
    RUN_TITLE[$t]=$title
    serve_busy "$t" && continue
    if [ -f "$SERVE_DIR/queued-$pr" ] && [ "$(state_get "$SERVE_DIR/queued-$pr" '[0-9a-f]+ [0-9]+' | cut -d' ' -f1)" = "$sha" ]; then continue; fi
    # A rebase whose requalification was cut short (serve stopped, the new head came late): carry on.
    if [ -f "$SERVE_DIR/rebased-$pr" ] && old=$(state_get "$SERVE_DIR/rebased-$pr" '[0-9a-f]+') && [ "$old" != "$sha" ]; then
      if [ "$acted" = false ]; then
        serve_requalify "$t" "$pr" "$old" "$sha" "$ref"
        acted=true
      fi
      continue
    fi
    states=$(serve_states "$sha") || continue
    review=$(jq -r '.["senior-mode/review"] // empty' <<<"$states")
    ci=$(jq -r '.["senior-mode/ci"] // empty' <<<"$states")
    # The review of a hotfix (#322) is mandatory whatever the profile says.
    [ -n "$review" ] || [ "$gate" != false ] || [ "$ci" != success ] || hotfix_item "$data" "$t" || review=success
    case $review in
      "") [ "$ci" != success ] || serve_review "$t" "$pr" "$sha" "$ref" ;;
      failure | error) serve_changes "$t" "$pr" "$ref" ;;
      success)
        if [ "$acted" = false ] && serve_merge "$t" "$pr" "$sha" "$ref"; then acted=true; fi
        ;;
    esac
  done < <(serve_candidates "$data" "$prs")
  serve_pending "$data" "$prs"
}
