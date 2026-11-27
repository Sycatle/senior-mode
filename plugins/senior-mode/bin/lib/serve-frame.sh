# shellcheck shell=bash
# Ready by rule (#272), once a poll: `ready --pr <n>` for each framing pull request (branch docs/...) merged since
# the last poll, then `ready` for the tickets agents filed, then `ready --optin` for those a person opted in (#612).
# The time of the last poll that went well is kept in <serve dir>/ready-last: a failure leaves it, so the pull requests are read again at the next poll, and a
# restart does not miss what merged while serve was down. The first poll only sets the mark.
serve_ready() {
  local now last prs pr ok=true
  now=$(serve_now)
  last=$(state_num "$SERVE_DIR/ready-last" "$now")
  if prs=$(gh_retry pr list --repo "$RUN_SLUG" --state merged --limit 50 --json number,headRefName,mergedAt); then
    while IFS= read -r pr; do
      [ -n "$pr" ] || continue
      "$SELF" ready --pr "$pr" || ok=false
    done < <(jq -r --argjson l "$last" '.[] | select((.headRefName | startswith("docs/")) and ((.mergedAt | fromdateiso8601) > $l)) | .number' <<<"$prs")
  else
    echo "serve: cannot list the merged pull requests; trying again at the next poll" >&2
    ok=false
  fi
  "$SELF" ready || ok=false
  "$SELF" ready --optin || ok=false
  [ "$ok" = false ] || state_put "$SERVE_DIR/ready-last" "$now"
}

# Framing of raw ideas (#585). An open Backlog issue by a collaborator with no acceptance criteria (and none of
# `filed-by: agent`, `framed-by: serve`, needs-human, needs-info, needs-decision, later, epic) is a raw idea: one
# framing session (role framer, Opus, effort medium) turns it into Ready tickets, in place when it is one S, else as
# sub-issues of the original, which becomes their epic. The questions of a framing wait in one comment of the epic
# that starts with SERVE_FRAME_MARK and the tickets they concern carry needs-decision; a collaborator's reply starts a
# short session that writes the answers into them. A framing session writes no file of the repository, opens no pull
# request and merges nothing.
SERVE_FRAME_MARK='<!-- senior-mode:frame -->'

# A framing session is running.
serve_frame_running() {
  local n
  for n in "${running[@]}"; do
    [ "${RUN_ROLE[$n]:-}" != framer ] || return 0
  done
  return 1
}

# Has a collaborator replied under the last framing comment of epic $1 (not a comment of senior-mode itself)?
serve_frame_replied() {
  gh_retry api "repos/$RUN_SLUG/issues/$1/comments?per_page=100" --paginate --jq '.[] | {body, a: .author_association}' 2>/dev/null |
    jq -se --arg m "$SERVE_FRAME_MARK" 'to_entries | (map(select(.value.body | contains($m))) | last | .key // null) as $i
      | $i != null and any(.[$i + 1:][].value; (.body | contains("<!-- senior-mode:") | not) and (.a | IN("OWNER", "MEMBER", "COLLABORATOR")))' >/dev/null
}

# The next framing job from the items of the Project ($1, ready_items): `reply<TAB>epic<TAB>tickets` for an epic whose
# questions got an answer, else `idea<TAB>number`; nothing (status 1) when there is none to start now. A reply goes first.
# shellcheck disable=SC2016 # jq programs, not shell
serve_frame_job() {
  local items=$1 now e members n
  now=$(serve_now)
  while read -r e members; do
    [ -n "$e" ] || continue
    [ "$(serve_retry_at "$e")" -le "$now" ] || continue
    ! serve_env_held "$e" || continue
    serve_frame_replied "$e" || continue
    printf 'reply\t%s\t%s\n' "$e" "$members"
    return 0
  done < <(jq -r '[.[] | select(.open and .framed and (.labels | index("needs-decision")) and .parent != null
      and ((.parent.labels | index("needs-human")) | not))] | group_by(.parent.number)[] | "\(.[0].parent.number) \(map(.number) | join(" "))"' <<<"$items")
  while read -r n; do
    [ -n "$n" ] || continue
    [ "$(serve_retry_at "$n")" -le "$now" ] || continue
    ! serve_env_held "$n" || continue
    printf 'idea\t%s\n' "$n"
    return 0
  done < <(jq -r "$TRUST_DEF$HAS_CRITERIA_DEF"'[.[] | select(.open and trusted and .status == "Backlog" and (.agent | not) and (.framed | not)
      and ((.labels | map(select(IN("needs-human", "needs-info", "needs-decision", "later", "epic"))) | length) == 0) and (.body | has_criteria | not))]
    | sort_by([([(.priority // "") | scan("^P([0-9]+)") | .[0] | tonumber] | first // 99), .number])[] | .number' <<<"$items")
  return 1
}

# An epic that senior-mode framed whose sub-issues are all closed is closed. $1 the items of the Project.
serve_frame_epics() {
  local e
  while read -r e; do
    [ -n "$e" ] || continue
    gh_retry api "repos/$RUN_SLUG/issues/$e/sub_issues?per_page=100" --jq '[.[].state] | length > 0 and all(. == "closed")' 2>/dev/null | grep -qx true || continue
    gh_retry api "repos/$RUN_SLUG/issues/$e/comments?per_page=100" --paginate --jq '.[].body' 2>/dev/null | grep -qF "$SERVE_FRAME_MARK" || continue
    if gh_retry api "repos/$RUN_SLUG/issues/$e" -X PATCH -f state=closed -f state_reason=completed >/dev/null; then
      (item_set "$e" Status Done) >/dev/null || echo "#$e: could not set the Status Done" >&2
      echo "#$e: all its sub-issues are closed; the epic is closed"
    else
      echo "#$e: could not close the epic" >&2
    fi
  done < <(jq -r '.[] | select(.open and (.labels | index("epic")) and ((.labels | index("maintenance")) | not)) | .number' <<<"$1")
}

# The framing of the poll: closes the finished epics, then, when no Ready ticket waits for a slot ($2 their number) and
# none is being framed, starts one session on the next job. $1 the board data.
serve_frame() {
  local data=$1 waiting=$2 items job kind n members title wt
  items=$(ready_items 2>/dev/null) || return 0
  serve_frame_epics "$items"
  [ "$waiting" -eq 0 ] || return 0
  serve_frame_running && return 0
  serve_can_launch || return 0
  job=$(serve_frame_job "$items") || return 0
  IFS=$'\t' read -r kind n members <<<"$job"
  title=$(jq -r --argjson n "$n" '.items[] | select(.number == $n) | .title' <<<"$data")
  git_bound fetch -q origin "$RUN_BASE" 2>/dev/null || true
  wt=$(worktree_path "$RUN_ROOT" "idea-$n")
  git worktree remove --force "$wt" 2>/dev/null || true
  if ! { git worktree add -q --detach "$wt" "origin/$RUN_BASE" 2>/dev/null || git worktree add -q --detach "$wt" "$RUN_BASE" 2>/dev/null; }; then
    echo "#$n: could not open a worktree to frame it; trying again at the next poll" >&2
    return 0
  fi
  RUN_TITLE[$n]=$title
  RUN_ROLE[$n]=framer
  RUN_CWD[$n]=$wt
  RUN_WT[$n]=$wt
  RUN_BRANCH[$n]=""
  unset 'RUN_BATCH[$n]'
  printf '%s\n' "$kind" | state_write "$RUN_DIR/$n.frame"
  if [ "$kind" = idea ]; then
    jq -r --argjson n "$n" '.[] | select(.number == $n) | .body' <<<"$items" | state_write "$RUN_DIR/$n.idea"
    jq -r --argjson n "$n" '.items[] | select(.open and .number != $n) | "#\(.number) \(.title)"' <<<"$data" | state_write "$RUN_DIR/$n.tickets"
    serve_frame_prompt "$n" "$title" "$RUN_DIR/$n.idea" "$RUN_DIR/$n.tickets" | state_write "$RUN_DIR/$n.prompt"
  else
    serve_frame_reply_prompt "$n" "$title" "$members" | state_write "$RUN_DIR/$n.prompt"
  fi
  echo "#$n: framing ($kind) on opus"
  if run_launch "$n" opus; then running+=("$n"); else git worktree remove --force "$wt" 2>/dev/null || true; fi
}

# A framing session is over (the outcome `framed: <what>`). Its work is checked: an idea must have its criteria in place
# or be an epic now; a reply must have been answered by a new framing comment. Else, or without that outcome, the issue is
# a person's (needs-human, a comment): a framing that did nothing would be started again at every poll.
serve_frame_finish_ok() {
  local n=$1 kind=$2 issue
  if [ "$kind" = reply ]; then
    ! serve_frame_replied "$n"
    return
  fi
  issue=$(gh_retry api "repos/$RUN_SLUG/issues/$n" --jq '{body: (.body // ""), epic: ([.labels[].name] | index("epic") != null)}') || return 1
  jq -e "$HAS_CRITERIA_DEF"'.epic or (.body | has_criteria)' <<<"$issue" >/dev/null
}

serve_finish_frame() {
  local n=$1 kind outcome reason
  [ -z "${RUN_CWD[$n]:-}" ] || git worktree remove --force "${RUN_CWD[$n]}" 2>/dev/null || true
  kind=$(head -n 1 "$RUN_DIR/$n.frame" 2>/dev/null) || kind=idea
  outcome=$(head -n 1 "$RUN_DIR/$n.outcome" 2>/dev/null) || outcome=""
  if [[ $outcome == framed:* ]] && serve_frame_finish_ok "$n" "$kind"; then
    RUN_FAILS=0
    run_record "$n" framed ""
    echo "#$n: framed:${outcome#framed:}"
    return 0
  fi
  reason=${outcome:-the framing session ended without saying how it went (log in $RUN_DIR)}
  [[ $outcome != framed:* ]] || reason="the session said framed but left the issue as it was"
  gh_retry api "repos/$RUN_SLUG/issues/$n/labels" -f 'labels[]=needs-human' >/dev/null || echo "#$n: could not label the issue needs-human" >&2
  gh_bound api "repos/$RUN_SLUG/issues/$n/comments" -f body="senior-mode: the framing session could not frame this issue: $reason. A person frames it, or removes needs-human to try again." \
    >/dev/null || echo "#$n: could not comment on the issue" >&2
  run_record "$n" failed "$reason"
  RUN_FAILED+=("#$n ${RUN_TITLE[$n]:-}: framing failed: $reason")
  RUN_FAILS=$((RUN_FAILS + 1))
  [ "$RUN_FAILS" -lt "$RUN_MAXFAIL" ] || RUN_STOP="$RUN_FAILS failed session(s) in a row (autonomy.maxConsecutiveFailures)"
  notify needs-human "$n" "framing failed: $reason"
}
