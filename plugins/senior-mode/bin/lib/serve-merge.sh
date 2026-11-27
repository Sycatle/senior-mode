# shellcheck shell=bash
# A merged hotfix pull request (head matching workflow.release.hotfix, base other than the integration branch): the
# ticket `chore: back-merge <hotfix> into <integration>` that brings the fix back to the integration branch. Filed
# once per hotfix branch; a failure is said, never fatal.
serve_backmerge() {
  local pr=$2 hot integration info head base title file
  workflow_active "$RUN_ROOT" || return 0
  hot=$(workflow_get release.hotfix "$RUN_ROOT")
  integration=$(workflow_get integration "$RUN_ROOT")
  [ -n "$hot" ] && [ -n "$integration" ] || return 0
  info=$(gh_retry pr view "$pr" -R "$RUN_SLUG" --json headRefName,baseRefName --jq '[.headRefName, .baseRefName] | @tsv') || return 0
  IFS=$'\t' read -r head base <<<"$info"
  # shellcheck disable=SC2053 # a glob of workflow.release.hotfix
  [[ $head == $hot ]] && [ "$base" != "$integration" ] || return 0
  title="chore: back-merge $head into $integration"
  file=$(mktemp)
  printf '## Context\n\nThe hotfix pull request #%s merged into `%s`; `%s` lacks it.\n\n## Acceptance criteria\n\n- Given `%s` is merged, when `%s` is merged into `%s`, then `%s` holds the hotfix and its check is green.\n' \
    "$pr" "$base" "$integration" "$head" "$base" "$integration" "$integration" >"$file"
  (issue_create --title "$title" --body-file "$file" --size S --priority P1 --type chore --paths '**' --status Ready) >/dev/null ||
    echo "pull request #$pr: could not file $title" >&2
  rm -f "$file"
}

# After a merge (serve_done leaves main-verify), the head of the base branch has no senior-mode/ci status: two pull
# requests green on their own can fail together (#683). The check list runs on a detached worktree of that head and is
# published there as senior-mode/ci, as for a pull request. A failure holds every launch (the main-red hold, which the
# probe of the next polls keeps while the status is red on the head) and files a P0 ticket that names the failing
# check, a person's to take: no session starts on a red base branch. A head that already has a status is left alone.
serve_verify_main() {
  local sha ci wt log="$SERVE_DIR/main-check.log" state desc base=${RUN_BASE#origin/} body title
  [ -e "$SERVE_DIR/main-verify" ] && [ "$SERVE_TERM" = false ] || return 0
  git_bound fetch -q origin 2>/dev/null || true
  sha=$(git rev-parse -q --verify "$RUN_BASE^{commit}") || return 0
  ci=$(serve_states "$sha" | jq -r '.["senior-mode/ci"] // empty') || return 0
  rm -f "$SERVE_DIR/main-verify"
  [ -z "$ci" ] || return 0
  wt=$(worktree_path "$RUN_ROOT" "verify-main")
  git worktree remove --force "$wt" 2>/dev/null || true
  if ! git worktree add -q --detach "$wt" "$sha" 2>/dev/null; then
    echo "serve: could not open a worktree of $RUN_BASE to check it after a merge" >&2
    return 0
  fi
  serve_install "$wt" >"$log" 2>&1 || true
  (cd "$wt" && "$SELF" check) >>"$log" 2>&1 || true
  state=$(cd "$wt" && sed -n 1p "$(check_record "$sha")" 2>/dev/null) || state=""
  desc=$(cd "$wt" && sed -n 2p "$(check_record "$sha")" 2>/dev/null) || desc=""
  if ! (cd "$wt" && "$SELF" publish) >>"$log" 2>&1; then
    echo "serve: the check of $RUN_BASE after a merge could not be published (log $log)" >&2
    state=""
  fi
  git worktree remove --force "$wt" 2>/dev/null || true
  [ "$state" = failure ] || return 0
  echo "serve: $RUN_BASE (${sha:0:7}) fails its checks after a merge: $desc" >&2
  serve_hold_set main-red "senior-mode/ci is failure on $RUN_BASE (${sha:0:7}): $desc"
  [ -n "$SERVE_HELD" ] || SERVE_HELD="held, environment problem (main-red): $desc"
  title="fix($base): $base fails its checks after a merge"
  body=$(mktemp)
  printf '## Context\n\nAfter a merge, serve ran the checks on `%s` (`%s`) and they fail: %s.\n\nserve published `senior-mode/ci` failure on that commit and holds every launch until `%s` is green again. The log is `%s`.\n\n## Acceptance criteria\n\n- Given `%s` at `%s`, when the failing check is fixed or the merge that broke it is reverted, then `senior-mode check` passes on its head.\n' \
    "$base" "${sha:0:7}" "${desc:-no description}" "$base" "$log" "$base" "${sha:0:7}" >"$body"
  "$SELF" issue create --title "$title" --body-file "$body" --size S --priority "P0 now" --type bug </dev/null >/dev/null ||
    echo "serve: the ticket for the red $RUN_BASE was not filed" >&2
  rm -f "$body"
}

# A merged pull request: counted, its ticket Done, and the breaker's trips start again at 0. The head of the base branch
# is checked at the next poll (serve_verify_main).
serve_done() {
  local t=$1 pr=$2 m
  : | state_write "$SERVE_DIR/main-verify"
  rm -f "$SERVE_DIR/queued-$pr" "$SERVE_DIR/rounds-$t" "$SERVE_DIR/breaker" "$SERVE_DIR/$t.wrong-test" "$SERVE_DIR/$t.retest"
  serve_close_candidates "$t" "$pr"
  serve_backmerge "$t" "$pr"
  hotfix_release "$t" "$pr"
  # Every ticket of a batch is done with its one pull request (the lead's <n>.batch).
  for m in $(serve_batch "$t"); do
    RUN_MERGED+=("#$m ${RUN_TITLE[$m]:-} (pull request #$pr)")
    if (item_set "$m" Status Done) >/dev/null; then
      cycle_end "$m"
    else
      echo "#$m: merged, but could not set the Status Done" >&2
      RUN_NOT_DONE+=("#$m ${RUN_TITLE[$m]:-} (pull request #$pr)")
    fi
  done
  fault_point after-done
}

# A pull request that merged while serve was down, or died before it set the Status (spec 373, section 2): a ticket In
# review whose branch (or `Closes #<n>`) has a merged pull request and no open one is Done now, whether or not a queued-<pr>
# file remembers it, and its worktree is cleaned. $1 is the board, $2 the open pull requests. Read from GitHub at every poll.
# shellcheck disable=SC2016 # a jq program, not shell
serve_merged_done() {
  local data=$1 prs=$2 merged t pr moved=false d
  merged=$(gh_retry pr list --repo "$RUN_SLUG" --state merged --limit 50 --json number,headRefName,body) || return 0
  while IFS=$'\t' read -r t pr; do
    [ -n "$t" ] || continue
    # Done in this very poll (serve_queued): the board read above is older.
    for d in "${RUN_MERGED[@]}"; do [[ $d == "#$t "* ]] && continue 2; done
    serve_busy "$t" && continue
    serve_done "$t" "$pr"
    moved=true
  done < <(jq -r --slurpfile d <(printf '%s' "$data") --slurpfile o <(printf '%s' "$prs") '
      def ticket: try (capture("^[a-z]+/(?<n>[0-9]+)(-|$)") | .n | tonumber) catch null;
      $d[0] as $d | $o[0] as $o
      | ([$o[] | .head.ref | ticket] | map(select(. != null))) as $open
      | [.[] | . as $p
          | ([($p.headRefName | ticket)] + [($p.body // "" | scan("(?i)(?:closes|fixes|resolves) #([0-9]+)") | .[0] | tonumber)])
          | map(select(. != null))[] | {t: ., pr: $p.number}]
      | map(select(. as $x | ($open | index($x.t) | not)
          and any($d.items[]; .number == $x.t and .open and .status == "In review")))
      | unique_by(.t)[] | [.t, .pr] | @tsv' <<<"$merged")
  [ "$moved" = false ] || "$SELF" clean || echo "serve: clean failed; trying again later" >&2
}

# The pull requests queued for auto-merge (queued-<pr>: the head and the ticket): merged is read back, then
# Done; a closed one is forgotten. One whose head is no longer the queued one is a candidate again.
serve_queued() {
  local f pr sha t state
  for f in "$SERVE_DIR"/queued-*; do
    [ -e "$f" ] || continue
    case $f in *.corrupt-* | *.tmp.*) continue ;; esac
    pr=${f##*queued-}
    read -r sha t < <(state_get "$f" '[0-9a-f]+ [0-9]+') || continue
    state=$(gh_retry pr view "$pr" -R "$RUN_SLUG" --json state --jq .state) || continue
    case $state in
      MERGED) serve_done "$t" "$pr" ;;
      CLOSED) rm -f "$f" ;;
    esac
  done
}

# Does the repository allow auto-merge (#173)?
serve_auto() {
  gh_retry api "repos/$RUN_SLUG" --jq '.allow_auto_merge // false' 2>/dev/null || echo false
}

# Merges the pull request $2 of ticket $1 at head $3: queued with auto-merge when the repository allows it
# (else, or when GitHub refuses, merged now), --match-head-commit in both. Merged means the state read back is
# MERGED; only then the ticket is Done.
serve_do_merge() {
  local t=$1 pr=$2 sha=$3 err="$SERVE_DIR/$1.merge" queued=false state method
  : >"$err"
  method=$(workflow_merge_flag "$RUN_ROOT")
  fault_point before-merge
  if [ "$(serve_auto)" = true ] &&
    gh_bound pr merge "$pr" --auto "$method" --match-head-commit "$sha" -R "$RUN_SLUG" >/dev/null 2>"$err"; then
    queued=true
  elif ! gh_bound pr merge "$pr" "$method" --match-head-commit "$sha" -R "$RUN_SLUG" >/dev/null 2>"$err"; then
    serve_note "w$pr" "#$t ${RUN_TITLE[$t]:-}: pull request #$pr, the merge failed: $(head -n 1 "$err")"
    return 0
  fi
  fault_point after-merge
  state=$(gh_retry pr view "$pr" -R "$RUN_SLUG" --json state --jq .state) || state=""
  if [ "$state" = MERGED ]; then
    serve_done "$t" "$pr"
  elif [ "$queued" = true ]; then
    state_put "$SERVE_DIR/queued-$pr" "$sha $t"
    echo "#$t: pull request #$pr queued for auto-merge"
  else
    serve_note "w$pr" "#$t ${RUN_TITLE[$t]:-}: pull request #$pr, merged but GitHub says it is ${state:-unknown}"
  fi
}

# The commit among the commits of the pull request that the head $1 has over the base, and $1 itself, whose tree is $2
# and whose status senior-mode/ci is success (#412): the tree that `check` already passed. Prints its sha.
serve_tested_from() {
  local c
  while IFS= read -r c; do
    [ "$(git rev-parse "$c^{tree}" 2>/dev/null)" = "$2" ] || continue
    [ "$(serve_states "$c" 2>/dev/null | jq -r '.["senior-mode/ci"] // empty')" = success ] || continue
    echo "$c"
    return 0
  done < <(git rev-list -n 50 "$1" "^$RUN_BASE" 2>/dev/null; git rev-parse "$1")
  return 1
}

# After a rebase of the pull request $2 (ticket $1) from head $3 to head $4 (branch $5): check and publish on
# the new head, then the review is carried over when `git range-diff` finds the same patches, or asked again
# when it finds any change (the head has no review status, so the next poll starts a reviewer). A new head whose
# tree is one that `check` passed with senior-mode/ci success (#412) runs no check: its result is carried over, the
# description names the tree and the commit, and publish only adds what depends on the head (security).
serve_requalify() {
  local t=$1 pr=$2 old=$3 new=$4 ref=$5 wt log="$SERVE_DIR/$1.check.log" same=false ob nb ci review rd tree from="" ran heavy_from
  git_bound fetch -q origin 2>/dev/null || true
  if git cat-file -e "$old^{commit}" 2>/dev/null && git cat-file -e "$new^{commit}" 2>/dev/null &&
    ob=$(git merge-base "$old" "$new") && nb=$(git merge-base "$RUN_BASE" "$new") &&
    rd=$(git range-diff --no-color "$ob..$old" "$nb..$new" 2>/dev/null) && [ -n "$rd" ] &&
    printf '%s\n' "$rd" | state_write "$SERVE_DIR/$t.range-diff" &&
    awk 'NF && $3 != "=" { bad = 1 } END { exit (bad || NR == 0) }' "$SERVE_DIR/$t.range-diff"; then
    same=true
  fi
  # With the same patches the heavy result of the old head is carried over by publish (#717).
  heavy_from=""
  [ "$same" != true ] || heavy_from=$old
  tree=$(git rev-parse "$new^{tree}" 2>/dev/null) && from=$(serve_tested_from "$old" "$tree") || from=""
  if [ -n "$from" ]; then
    log=$SERVE_DIR/$t.carry.log
    ran="the tree of the new head (\`${tree:0:12}\`) is the tree of \`${from:0:7}\`, which has senior-mode/ci success, so that status is carried over and no check ran"
    if ! (cd "$RUN_ROOT" && mkdir -p "$(dirname "$(check_record x)")" &&
      printf 'success\ncarried over from %s: same tree %s, no check ran\n' "${from:0:7}" "${tree:0:12}" >"$(check_record "$new")" &&
      SENIOR_MODE_HEAVY_FROM=$heavy_from "$SELF" publish "$new") >"$log" 2>&1; then
      serve_needs_human "$t" "$pr" "it was rebased on $RUN_BASE but its check result could not be published (log $log)"
      return 0
    fi
  else
    ran="check and publish ran again"
    wt=$(worktree_path "$RUN_ROOT" "integrate-$t")
    git worktree remove --force "$wt" 2>/dev/null || true
    if ! git worktree add -q --detach "$wt" "$new" 2>/dev/null; then
      serve_needs_human "$t" "$pr" "it was rebased on $RUN_BASE but a worktree of the new head could not be opened to check it"
      return 0
    fi
    serve_install "$wt" >"$log" 2>&1 || true
    (cd "$wt" && "$SELF" check) >>"$log" 2>&1 || true
    if ! (cd "$wt" && SENIOR_MODE_HEAVY_FROM=$heavy_from "$SELF" publish) >>"$log" 2>&1; then
      git worktree remove --force "$wt" 2>/dev/null || true
      serve_needs_human "$t" "$pr" "it was rebased on $RUN_BASE but its check result could not be published (log $log)"
      return 0
    fi
    git worktree remove --force "$wt" 2>/dev/null || true
  fi
  rm -f "$SERVE_DIR/rebased-$pr"
  ci=$(serve_states "$new" | jq -r '.["senior-mode/ci"] // empty') || ci=""
  if [ "$ci" != success ]; then
    serve_needs_human "$t" "$pr" "it was rebased on $RUN_BASE and its check is $ci now (log $log)"
    return 0
  fi
  review=$(serve_states "$old" | jq -r '.["senior-mode/review"] // empty') || review=""
  if [ "$same" = true ] && [ "$review" = success ]; then
    gh_retry api "repos/$RUN_SLUG/statuses/$new" -f state=success -f context=senior-mode/review \
      -f description="carried over from ${old:0:7}: git range-diff shows the same patches" >/dev/null ||
      echo "#$t: could not carry the review over to ${new:0:7}" >&2
    gh_bound api "repos/$RUN_SLUG/issues/$pr/comments" -f body="senior-mode serve rebased this pull request on $RUN_BASE (\`${old:0:7}\` to \`${new:0:7}\`): \`git range-diff\` shows the same patches, so the review of \`${old:0:7}\` is carried over; $ran." >/dev/null || true
  else
    gh_bound api "repos/$RUN_SLUG/issues/$pr/comments" -f body="senior-mode serve rebased this pull request on $RUN_BASE (\`${old:0:7}\` to \`${new:0:7}\`): \`git range-diff\` shows changes, so $ran and a new review is requested." >/dev/null || true
  fi
}

# The pull request $2 of ticket $1 (head $3, branch $4) is behind its base: rebased on the server
# (`gh pr update-branch --rebase`), then requalified. Returns 0 when the head moved (new head in SERVE_HEAD),
# 1 when not, 2 for a conflict.
serve_rebase() {
  local t=$1 pr=$2 old=$3 ref=$4 new="" i err="$SERVE_DIR/$1.rebase"
  git_bound fetch -q origin "$ref" 2>/dev/null || true
  state_put "$SERVE_DIR/rebased-$pr" "$old"
  if ! gh_bound pr update-branch "$pr" --rebase -R "$RUN_SLUG" >/dev/null 2>"$err"; then
    rm -f "$SERVE_DIR/rebased-$pr"
    if grep -qi conflict "$err"; then return 2; fi
    serve_note "w$pr" "#$t ${RUN_TITLE[$t]:-}: pull request #$pr, it is behind $RUN_BASE and could not be updated: $(head -n 1 "$err")"
    return 1
  fi
  for ((i = 0; i < 6; i++)); do
    new=$(gh_retry api "repos/$RUN_SLUG/pulls/$pr" --jq .head.sha) || new=""
    { [ -n "$new" ] && [ "$new" != "$old" ]; } && break
    sleep "${SENIOR_MODE_POLL:-15}"
  done
  if [ -z "$new" ] || [ "$new" = "$old" ]; then
    echo "#$t: pull request #$pr is being rebased; looking again at the next poll" >&2
    return 1
  fi
  serve_requalify "$t" "$pr" "$old" "$new" "$ref"
}

# The pull request $2 of ticket $1 (branch $3) conflicts with its base: an Opus integrator session resolves it
# on the branch <branch>-r2 (-r3 the second time), in a worktree of its own, and opens a pull request that says
# "Supersedes #<old>". A resolution that was tried twice is a person's. Returns 0 when a session started.
serve_conflict() {
  local t=$1 pr=$2 ref=$3 base=$3 k=2 new wt
  if [[ $ref =~ ^(.*)-r([0-9]+)$ ]]; then
    base=${BASH_REMATCH[1]}
    k=$((BASH_REMATCH[2] + 1))
  fi
  if [ "$k" -gt 3 ]; then
    serve_needs_human "$t" "$pr" "it conflicts with $RUN_BASE again after the integrator resolved it twice"
    return 1
  fi
  serve_can_launch "$t" || return 1
  new=$base-r$k
  git_bound fetch -q origin 2>/dev/null || true
  wt=$(worktree_path "$RUN_ROOT" "$t-r$k")
  git worktree remove --force "$wt" 2>/dev/null || true
  git branch -D -q "$new" 2>/dev/null || true
  if ! git worktree add -q --no-track -b "$new" "$wt" "origin/$ref" 2>/dev/null; then
    serve_needs_human "$t" "$pr" "it conflicts with $RUN_BASE and a worktree for the integrator could not be opened on $new"
    return 1
  fi
  RUN_ROLE[$t]=integrator
  unset 'RUN_CWD[$t]'
  RUN_WT[$t]=$wt
  RUN_BRANCH[$t]=$new
  state_put "$RUN_DIR/$t.oldpr" "$pr"
  serve_integrator_prompt "$t" "${RUN_TITLE[$t]:-}" "$ref" "$pr" "$new" | state_write "$RUN_DIR/$t.prompt"
  echo "#$t: pull request #$pr conflicts with $RUN_BASE; the integrator resolves it on $new"
  if run_launch "$t" opus; then running+=("$t"); fi
}

# The review of an approved pull request $2 (ticket $1, head $3, branch $4): merged by the integrator pass. Returns
# 0 when it acted (merged, queued, rebased, a conflict session started), so that a poll merges at most one.
serve_merge() {
  local t=$1 pr=$2 ref=$4 pull sha reason state rc=0
  pull=$(gh_retry api "repos/$RUN_SLUG/pulls/$pr") || return 1
  sha=$(jq -r '.head.sha' <<<"$pull")
  reason=$(run_blocker "$pr" "$sha" "$pull")
  if [[ $reason == "it is behind "* ]]; then
    # github.protection local (ADR 0032): GitHub has no up-to-date rule to report it, run_blocker does.
    state=behind
  elif [ -n "$reason" ]; then
    # Red tests missing (#306): the ticket session is resumed once to prove them; a second time is a person's.
    case $reason in "not ready: no red-tests record"*) serve_red_retry "$t" "$pr" "$ref" "$reason" && return 0 ;; esac
    serve_note "w$pr" "#$t ${RUN_TITLE[$t]:-}: pull request #$pr, $reason"
    serve_permanent "$reason" && serve_stuck "$t" "$pr" "$reason"
    return 1
  else
    state=$(jq -r '.mergeable_state // "unknown"' <<<"$pull")
  fi
  case $state in
    unknown) return 1 ;;
    dirty)
      serve_conflict "$t" "$pr" "$ref"
      return
      ;;
    behind)
      serve_rebase "$t" "$pr" "$sha" "$ref" || rc=$?
      [ "$rc" -ne 2 ] || {
        serve_conflict "$t" "$pr" "$ref"
        return
      }
      [ "$rc" -eq 0 ] || return 1
      pull=$(gh_retry api "repos/$RUN_SLUG/pulls/$pr") || return 0
      sha=$(jq -r '.head.sha' <<<"$pull")
      # A rebase that changed the patches has no review on its new head: the next poll starts a reviewer.
      [ -z "$(run_blocker "$pr" "$sha" "$pull")" ] || return 0
      ;;
  esac
  serve_do_merge "$t" "$pr" "$sha"
}
