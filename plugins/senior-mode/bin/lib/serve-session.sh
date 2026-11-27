# shellcheck shell=bash
# RUN_FINISH of serve (see run_reap): reads how a finished session went, by its role. Returns 1 when the
# ticket goes on with another session.
serve_finish() {
  case ${RUN_ROLE[$1]:-ticket} in
    test-author) serve_finish_tests "$1" ;;
    reviewer) serve_finish_review "$1" ;;
    integrator) serve_finish_integrator "$1" ;;
    framer) serve_finish_frame "$1" ;;
    *) serve_finish_ticket "$1" ;;
  esac
}

# A ticket session is over. An implementer that reports a red test as wrong (`wrong-test: <finding>`, M tickets only: it
# cannot edit the red tests) sends the ticket back to the test-author once; any other end is run's.
serve_finish_ticket() {
  local n=$1 outcome
  outcome=$(head -n 1 "$RUN_DIR/$n.outcome" 2>/dev/null) || outcome=""
  if [[ $outcome == wrong-test:* ]] && [ -z "${RUN_BATCH[$n]:-}" ] && [ -f "$SERVE_COMMON/senior-mode/runs/$n/red-tests" ]; then
    serve_wrong_test "$n" "${outcome#wrong-test:}" && return 0
    return 1
  fi
  run_finish "$n"
}

# The implementer of ticket $1 says a red test is wrong ($2 its finding). The first time, the test-author session starts
# again on the same branch with the finding (<n>.retest holds the head it starts from, <n>.wrong-test the finding), then
# the implementer again (serve_finish_tests). The second time the ticket is given up and needs a person, as any ticket
# whose session cannot go on. Returns 1 when the ticket goes on with another session.
serve_wrong_test() {
  local n=$1 finding reason
  finding=$(sed -e 's/^[[:space:]]*//' <<<"$2")
  [ -n "$finding" ] || finding="no detail given"
  if [ -s "$RUN_DIR/$n.wrong-test" ]; then
    reason="the implementer reports a red test as wrong a second time, after the test-author revised the tests: $finding"
    run_record "$n" failed "$reason"
    run_giveup "$n" "$reason"
    return 0
  fi
  state_put "$RUN_DIR/$n.wrong-test" "$finding"
  state_put "$RUN_DIR/$n.retest" "$(git -C "${RUN_WT[$n]}" rev-parse HEAD)"
  RUN_ROLE[$n]=test-author
  serve_retest_prompt "$n" "${RUN_TITLE[$n]:-}" "${RUN_BRANCH[$n]}" "$finding" | state_write "$RUN_DIR/$n.prompt"
  echo "#$n: the implementer reports a red test as wrong ($finding); the test-author revises it once" >&2
  run_launch "$n" sonnet || return 0
  return 1
}

# The files the test-author session added or changed since the head <n>.retest holds join the red tests (the list
# is written once by `red-tests record`, so this is the second pass of the same step). The implementer's commits come
# before that head: they never join.
serve_retest_record() {
  local n=$1 list=$SERVE_COMMON/senior-mode/runs/$1/red-tests since
  since=$(cat "$RUN_DIR/$n.retest")
  { cat "$list"; git -C "${RUN_WT[$n]}" diff -z --no-renames --name-only --diff-filter=AM "$since" HEAD | tr '\0' '\n'; } |
    awk 'NF && !seen[$0]++' | state_write "$list"
}

# The test-author session of an M ticket is over: its tests are recorded as the red tests (senior-mode red-tests
# record), then the ticket session starts on the same branch. After a wrong test reported by the implementer
# (<n>.retest), the tests it revised are added to the record instead.
serve_finish_tests() {
  local n=$1 outcome reason="" red rc=0
  outcome=$(head -n 1 "$RUN_DIR/$n.outcome" 2>/dev/null) || outcome=""
  if [ "$outcome" = delivered ]; then
    if [ -f "$RUN_DIR/$n.retest" ]; then
      red=$(serve_retest_record "$n" 2>&1) || rc=$?
      rm -f "$RUN_DIR/$n.retest"
    else
      red=$(cd "${RUN_WT[$n]}" && "$SELF" red-tests record "$n" 2>&1) || rc=$?
    fi
    printf '%s\n' "$red" | state_write "$RUN_DIR/$n.red"
    if [ "$rc" -eq 0 ]; then
      RUN_ROLE[$n]=ticket
      serve_prompt "$n" "${RUN_TITLE[$n]:-}" "${RUN_BRANCH[$n]}" | state_write "$RUN_DIR/$n.prompt"
      run_launch "$n" sonnet || return 0
      return 1
    fi
    reason="its tests could not be recorded: $(head -n 1 "$RUN_DIR/$n.red")"
  elif [ -n "$outcome" ]; then
    reason=${outcome#*: }
  else
    reason="the session ended without saying how it went (exit code $(cat "$RUN_DIR/$n.exit"), log in $RUN_DIR)"
  fi
  run_record "$n" failed "$reason"
  run_giveup "$n" "the test-author session wrote no red tests: $reason"
}

# A reviewer session is over: it must have left senior-mode/review on the head it reviewed; else the pull
# request is a person's (a reviewer that ends without a verdict would be started again at every poll).
serve_finish_review() {
  local n=$1 pr=${SERVE_PR[$1]} sha=${SERVE_SHA[$1]} review desc model=${RUN_MODEL[$1]}
  [ -z "${RUN_CWD[$n]:-}" ] || git worktree remove --force "${RUN_CWD[$n]}" 2>/dev/null || true
  review=$(serve_states "$sha" | jq -r '.["senior-mode/review"] // empty') || review=""
  if [ -n "$review" ]; then
    # The model that reviewed is in the description of the status (#304), whoever wrote it.
    desc=$(gh_retry api "repos/$RUN_SLUG/commits/$sha/status" --jq '[.statuses[] | select(.context == "senior-mode/review") | .description // ""][0] // ""') || desc=""
    case $desc in
      "reviewed on $model"*) ;;
      *) gh_retry api "repos/$RUN_SLUG/statuses/$sha" -f state="$review" -f context=senior-mode/review \
        -f description="reviewed on $model${desc:+: ${desc:0:100}}" >/dev/null || echo "#$n: could not record the reviewer model on ${sha:0:7}" >&2 ;;
    esac
    RUN_FAILS=0
    echo "#$n: pull request #$pr reviewed: senior-mode/review is $review"
    return 0
  fi
  gh_retry api "repos/$RUN_SLUG/issues/$pr/labels" -f 'labels[]=needs-human' >/dev/null || echo "#$n: could not label #$pr needs-human" >&2
  run_halt "$n" "the reviewer session of pull request #$pr ended without setting senior-mode/review" "$RUN_DIR/$n-${RUN_MODEL[$n]}.log" \
    "An autonomous senior-mode serve found this pull request's reviewer session over" "The session log is"
}

# An integrator session is over: the pull request it opened on the -rN branch supersedes the old one, which is
# closed (the new one is reviewed like any other); without one, the old pull request is a person's. The ticket
# is recorded as delivered and left In review, on the new pull request: serve_recover reads a ticket whose end
# was never recorded as a lost session (#285).
serve_finish_integrator() {
  local n=$1 old new outcome
  old=$(cat "$RUN_DIR/$n.oldpr" 2>/dev/null) || old=""
  outcome=$(head -n 1 "$RUN_DIR/$n.outcome" 2>/dev/null) || outcome=""
  new=$(gh_retry api "repos/$RUN_SLUG/pulls?head=${RUN_SLUG%%/*}:${RUN_BRANCH[$n]}&state=open" --jq '.[0].number // empty') || new=""
  if [ -n "$new" ] && [ "$outcome" = delivered ]; then
    RUN_FAILS=0
    run_record "$n" delivered ""
    run_review "$n"
    gh_bound api "repos/$RUN_SLUG/issues/$old/comments" -f body="Superseded by #$new, which resolves the conflicts with $RUN_BASE." >/dev/null || true
    gh_retry api "repos/$RUN_SLUG/pulls/$old" -X PATCH -f state=closed >/dev/null || echo "#$n: could not close pull request #$old" >&2
    echo "#$n: pull request #$new supersedes #$old"
    return 0
  fi
  RUN_FAILS=$((RUN_FAILS + 1))
  RUN_FAILED+=("#$n ${RUN_TITLE[$n]:-}: the integrator could not resolve pull request #$old (${outcome:-no outcome}; branch ${RUN_BRANCH[$n]} kept)")
  serve_needs_human "$n" "$old" "the integrator session could not resolve its conflicts with $RUN_BASE (${outcome:-no outcome})"
}

# What the sessions that ended since the last poll left to a person, once.
serve_report() {
  local t
  for t in "${RUN_MERGED[@]}"; do echo "Merged: $t"; done
  for t in "${RUN_NOT_DONE[@]}"; do echo "Status not set to Done: $t"; done
  for t in "${RUN_FAILED[@]}"; do echo "Failed: $t"; done
  for t in "${RUN_REVIEWED[@]}"; do echo "Status set to In review: $t"; done
  for t in "${RUN_NOT_REVIEW[@]}"; do echo "Status not set to In review: $t"; done
  for t in "${RUN_WAITING[@]}"; do echo "Waiting for a human: $t"; done
  RUN_FAILED=() RUN_WAITING=() RUN_MERGED=() RUN_NOT_DONE=() RUN_REVIEWED=() RUN_NOT_REVIEW=() RUN_PRS=()
}

# The tickets of the batch of the lead $1 (<n>.batch), the ticket alone when it has none.
serve_batch() {
  state_get "$SERVE_DIR/$1.batch" '[0-9]+( [0-9]+)*' || echo "$1"
}

# What became of the session of ticket $1 (its <n>.sh is in the serve dir), for serve_recover: `live` (its process group
# is alive and left no exit file), `ended` (it left an exit file and a verdict, or its group is gone with a verdict: the
# end can be read), `lost` (no verdict, nothing alive: its ticket is put back).
serve_orphan() {
  local n=$1 verdict=false
  [ -z "$(head -n 1 "$SERVE_DIR/$n.outcome" 2>/dev/null)" ] || verdict=true
  if [ -f "$SERVE_DIR/$n.exit" ]; then
    [ "$verdict" = true ] && echo ended || echo lost
  elif [ ! -f "$SERVE_DIR/$n.pgid" ]; then
    echo lost
  elif run_dead "$n"; then
    [ "$verdict" = true ] && echo ended || echo lost
  else
    echo live
  fi
}

# Whether a process runs inside the directory $1.
serve_wt_busy() {
  # One find and one awk, not a readlink per process: a busy host runs thousands of them. find may fail on a process
  # that ends meanwhile, and awk reads to the end, so that pipefail sees neither.
  # shellcheck disable=SC2016 # an awk program, not expanded here
  { find /proc -maxdepth 2 -path '/proc/[0-9]*/cwd' -printf '%l\n' 2>/dev/null || true; } |
    awk -v d="$1" '$0 == d || index($0, d "/") == 1 { found = 1 } END { exit !found }'
}

# The tickets of serve's sessions that the serve dir no longer knows (it was deleted): the worktrees of a ticket's branch
# that hold serve's marker (run_mark) and where no process runs, as `<lead> <ticket>...` lines.
serve_marked() {
  local path branch gd
  while IFS=$'\t' read -r path branch; do
    [[ $branch =~ ^refs/heads/[a-z]+/([0-9]+)(-|$) ]] || continue
    [ ! -e "$SERVE_DIR/${BASH_REMATCH[1]}.sh" ] || continue
    gd=$(git -C "$path" rev-parse --absolute-git-dir 2>/dev/null) || continue
    [ -f "$gd/senior-mode-session" ] || continue
    ! serve_wt_busy "$path" || continue
    printf '%s %s\n' "${BASH_REMATCH[1]}" "$(sed -n 1p "$gd/senior-mode-session")"
  done < <(git worktree list --porcelain | awk '$1 == "worktree" {p = substr($0, 10)} $1 == "branch" {print p "\t" $2}')
}

# Takes over the session of ticket $1 from a serve that died, from its <n>.meta: the arrays run keeps for a session are
# restored and the session is tracked like one this serve started. A session that ended is read like any end (run_reap).
serve_adopt() {
  local n=$1 meta m now
  local -a f
  meta=$(state_json "$SERVE_DIR/$n.meta") || return 1
  mapfile -t f < <(jq -r '(.role // "ticket"), (.model // "sonnet"), (.branch // ""), (.worktree // ""), (.cwd // ""), (.batch // ""),
    (.pr // ""), (.sha // ""), (.started // 0)' <<<"$meta")
  RUN_ROLE[$n]=${f[0]}
  RUN_MODEL[$n]=${f[1]}
  RUN_BRANCH[$n]=${f[2]}
  RUN_WT[$n]=${f[3]}
  if [ -n "${f[4]}" ]; then RUN_CWD[$n]=${f[4]}; else unset 'RUN_CWD[$n]'; fi
  if [ -n "${f[5]}" ]; then RUN_BATCH[$n]=${f[5]}; else unset 'RUN_BATCH[$n]'; fi
  if [ "${f[0]}" = reviewer ]; then
    SERVE_PR[$n]=${f[6]}
    SERVE_SHA[$n]=${f[7]}
  fi
  [ "${f[0]}" != ticket ] || [ "${f[1]}" != opus ] || RUN_ESCALATED[$n]=true
  now=$(serve_now)
  if [[ ! ${f[8]} =~ ^[0-9]+$ ]] || [ "${f[8]}" -gt "$now" ]; then f[8]=$now; fi
  RUN_STARTED[$n]=$((SECONDS - (now - f[8])))
  for m in $(run_members "$n"); do
    RUN_BRANCH[$m]=${f[2]}
    RUN_WT[$m]=${f[3]}
  done
  # The session ended with a verdict but its script died before the exit file: the exit code is not known.
  if [ ! -f "$SERVE_DIR/$n.exit" ] && run_dead "$n"; then state_put "$SERVE_DIR/$n.exit" 0; fi
  running+=("$n")
}

# After a crash or a restart (#272, spec 373 section 2): a ticket serve launched (its <n>.sh is in the serve dir) whose
# session is not one of this serve's. A session still alive, or ended with a verdict that nobody read (the end of a dead
# serve), is adopted (serve_adopt) and read at once like any other. One with no verdict and nothing alive, whose ticket
# is In progress, goes back to Ready, to be picked again (its worktree and branch are kept); once
# autonomy.maxConsecutiveFailures recoveries are used up it gets needs-human instead. The recoveries are counted in
# <n>.recovered. Left alone: a ticket whose end serve already read (its <n>.json is newer than its <n>.meta, else its
# <n>.sh), a ticket with needs-human. With the serve dir lost, the tickets In progress whose worktree holds serve's marker
# (serve_marked) and where nothing runs are put back the same way.
serve_recover() {
  local f n data count m base role want adopted=false
  local -a cand=() adopt=()
  local -A marked=()
  for f in "$SERVE_DIR"/*.sh; do
    [ -e "$f" ] || continue
    n=$(basename "$f" .sh)
    [[ $n =~ ^[0-9]+$ ]] || continue
    [[ " ${running[*]-} " != *" $n "* ]] || continue
    base=$f
    [ ! -f "$SERVE_DIR/$n.meta" ] || base=$SERVE_DIR/$n.meta
    if [ -f "$SERVE_DIR/$n.json" ] && [ "$SERVE_DIR/$n.json" -nt "$base" ]; then continue; fi
    role=$(jq -r '.role // "ticket"' "$SERVE_DIR/$n.meta" 2>/dev/null) || role=ticket
    case $(serve_orphan "$n") in
      live) [ ! -f "$SERVE_DIR/$n.meta" ] || adopt+=("$n") ;;
      ended)
        # A reviewer or an integrator ended: the pull request is looked at again, as it always was.
        if [ -f "$SERVE_DIR/$n.meta" ] && { [ "$role" = ticket ] || [ "$role" = test-author ]; }; then adopt+=("$n"); else cand+=("$n"); fi
        ;;
      lost) cand+=("$n") ;;
    esac
  done
  while read -r n m; do
    [ -n "$n" ] || continue
    marked[$n]=${m:-$n}
    cand+=("$n")
  done < <(serve_marked)
  [ $((${#cand[@]} + ${#adopt[@]})) -gt 0 ] || return 0
  if ! data=$(board_data false); then
    echo "serve: cannot read the board to recover tickets; trying again at the next poll" >&2
    return 0
  fi
  for n in "${adopt[@]}"; do
    role=$(jq -r '.role // "ticket"' "$SERVE_DIR/$n.meta" 2>/dev/null) || role=ticket
    want="In progress"
    case $role in reviewer | integrator) want="In review" ;; framer) want=Backlog ;; esac
    jq -e --argjson n "$n" --arg s "$want" '.items[] | select(.number == $n and .open and .status == $s and (.labels | index("needs-human") | not))' \
      <<<"$data" >/dev/null || continue
    serve_adopt "$n" || continue
    RUN_TITLE[$n]=$(jq -r --argjson n "$n" '.items[] | select(.number == $n) | .title' <<<"$data")
    echo "serve: #$n: taking over the $role session of a serve that stopped"
    adopted=true
  done
  for n in "${cand[@]}"; do
    jq -e --argjson n "$n" '.items[] | select(.number == $n and .open and .status == "In progress" and (.labels | index("needs-human") | not))' \
      <<<"$data" >/dev/null || continue
    count=$(state_update state_counter_add "$SERVE_DIR/$n.recovered") || continue
    if [ "$count" -ge "$RUN_MAXFAIL" ]; then
      echo "serve: #$n has lost its session $count times; needs-human"
      notify needs-human "$n" "serve found the ticket In progress with no live session $count times (autonomy.maxConsecutiveFailures); the session files are in $SERVE_DIR"
    else
      # A lost batch session puts every ticket of the batch back.
      for m in ${marked[$n]:-$(serve_batch "$n")}; do
        if (item_set "$m" Status Ready) >/dev/null; then
          echo "serve: #$m was In progress with no live session; back to Ready (recovery $count of $((RUN_MAXFAIL - 1)))"
        else
          echo "#$m: could not set the Status back to Ready" >&2
        fi
      done
    fi
  done
  [ "$adopted" = false ] || run_reap
}
