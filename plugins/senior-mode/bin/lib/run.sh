# shellcheck shell=bash
# The headless CLI named by agent.command (default claude): on PATH, else where its installer puts it
# (cron and systemd timers have a short PATH).
agent_bin() {
  local cmd
  cmd=$(config_get agent.command)
  command -v "$cmd" 2>/dev/null && return 0
  [ -x "$HOME/.local/bin/$cmd" ] || die "$cmd not found on PATH or in ~/.local/bin (agent.command)"
  printf '%s\n' "$HOME/.local/bin/$cmd"
}

# A session is a ticket or, for a batch (#263), the tickets delivered together in one worktree, by one session and one
# pull request. Its key (the number the RUN_* arrays and the session files use) is the lead, the first of
# RUN_BATCH[lead], the space-separated numbers of the batch. The tickets of a session, lead first.
run_members() {
  echo "${RUN_BATCH[$1]:-$1}"
}

# The tickets of the sessions running, for pick_free.
run_busy() {
  local n
  for n in "${running[@]}"; do
    # A reviewer writes no ticket code of its own; an integrator resolves conflicts in its ticket's files (#426).
    case ${RUN_ROLE[$n]:-ticket} in reviewer) ;; *) run_members "$n" ;; esac
  done | paste -sd' ' -
}

# A queue entry for pick_free: the tickets of the session $1 joined by `+`.
run_entry() {
  local m
  m=$(run_members "$1")
  echo "${m// /+}"
}

# The flags every claude session of run and serve gets, for its directory $1, in SESSION_FLAGS (#348). By default a
# session sees only the project's settings and MCP servers and the plugin's own hooks: not the owner's user CLAUDE.md,
# plugins, MCP servers or settings, so it behaves the same on any machine. The plugin is then loaded with --plugin-dir,
# as user settings no longer enable it. Login credentials are not settings and still work. autonomy.userSettings true
# brings the user's configuration back. Another agent than claude gets only SENIOR_MODE_PLUGIN_DIR, as before.
run_session_flags() {
  local plugin=${SENIOR_MODE_PLUGIN_DIR:-}
  SESSION_FLAGS=()
  if [ "$(config_get agent.command)" = claude ] && [ "$(config_get autonomy.userSettings)" != true ]; then
    SESSION_FLAGS+=(--setting-sources project,local --strict-mcp-config)
    [ ! -f "$1/.mcp.json" ] || SESSION_FLAGS+=(--mcp-config "$1/.mcp.json")
    plugin=${plugin:-$(dirname "$(dirname "$SELF")")}
  fi
  [ -z "$plugin" ] || SESSION_FLAGS+=(--plugin-dir "$plugin")
}

# Marks the directory $1 as trusted for Claude Code before a session starts there (#350): a headless session in an
# untrusted workspace ignores the project's permissions.allow and says so in its log (its hooks and env do load).
# Trust is kept per path in projects[<path>].hasTrustDialogAccepted of .claude.json (CLAUDE_CONFIG_DIR, else
# ~/.claude.json) and is not inherited from a parent, so each worktree gets its own entry. Written only when missing,
# atomically, under a lock of ours; a missing or unreadable file is left alone (nothing is signed in there).
run_trust() {
  local cfg
  [ "$(config_get agent.command)" = claude ] || return 0
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then cfg=$CLAUDE_CONFIG_DIR/.claude.json; else cfg=$HOME/.claude.json; fi
  [ -f "$cfg" ] || return 0
  (
    flock -w 10 9 || exit 0
    jq -e --arg p "$1" '.projects[$p].hasTrustDialogAccepted == true' "$cfg" >/dev/null 2>&1 && exit 0
    umask 077
    jq --arg p "$1" '.projects[$p].hasTrustDialogAccepted = true' "$cfg" >"$cfg.senior-mode.tmp" 2>/dev/null &&
      mv "$cfg.senior-mode.tmp" "$cfg" || rm -f "$cfg.senior-mode.tmp"
  ) 9>"$cfg.senior-mode.lock" || true
}

# Can run give a background session a process group of its own? setsid (util-linux), else perl's
# POSIX::setsid (always on macOS). Without either, a session that outlives the timeout cannot be stopped.
run_can_detach() {
  command -v setsid >/dev/null || command -v perl >/dev/null
}

# Starts a session script in the background, in its own session so that run_kill can kill the group
# without killing run. run checks run_can_detach before it starts anything.
run_detach() {
  if command -v setsid >/dev/null; then
    nohup setsid bash "$1" >/dev/null 2>&1 &
  else
    nohup perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' bash "$1" >/dev/null 2>&1 &
  fi
}

# The tokens of a session, one line per model it used, from the JSON that `claude -p --output-format json` prints (#299).
# shellcheck disable=SC2016 # a jq program, not shell
USAGE_JQ='(.modelUsage // {}) | to_entries[] | .value as $u | ($u.cacheCreationEphemeral1hInputTokens // 0) as $h
  | {ticket: $n, role: $r, at: $t, model: .key, input: ($u.inputTokens // 0), output: ($u.outputTokens // 0),
     cacheRead: ($u.cacheReadInputTokens // 0), cacheWrite5m: ((($u.cacheCreationInputTokens // 0) - $h) | if . < 0 then 0 else . end), cacheWrite1h: $h}'

# The line of a session script that appends the tokens of the session to <git common dir>/senior-mode/usage.jsonl,
# the ledger `retro` reads: the session logs are overwritten by the next session of the same ticket and model.
# $1 the ticket (null for none), $2 the role, $3 the session JSON. A session that left no JSON adds nothing.
# shellcheck disable=SC2016 # a line of the script, expanded when it runs
run_usage_line() {
  printf 'jq -c --argjson n %q --arg r %q --arg t "$(date -u +%s)" %q %q >>%q 2>/dev/null || true\n' "$1" "$2" '%Y-%m-%dT%H:%M:%SZ' \
    "$USAGE_JQ" "$3" "$RUN_USAGE"
}

# Writes the script of a ticket session on a model and starts it in a window of the tmux session
# senior-mode-run, else in the background. serve gives a session a role (RUN_ROLE[<n>], the SENIOR_MODE_ROLE the
# guards read) and may give it a directory of its own (RUN_CWD[<n>]); run gives none. The script leaves <n>.exit when the session ends. A window
# that tmux does not start fails the ticket at once (run_halt) and returns 1: no session would ever
# leave <n>.exit, and run would wait for the whole timeout.
# shellcheck disable=SC2016 # lines of the script, expanded when it runs
run_launch() {
  local n=$1 model=$2 script=$RUN_DIR/$1.sh cmd rc=0 dir
  local -a SESSION_FLAGS
  rm -f "$RUN_DIR/$n.outcome" "$RUN_DIR/$n.exit" "$RUN_DIR/$n.pgid"
  RUN_MODEL[$n]=$model
  RUN_STARTED[$n]=$SECONDS
  dir=${RUN_CWD[$n]:-${RUN_WT[$n]}}
  run_session_flags "$dir"
  run_trust "$dir"
  {
    echo '#!/usr/bin/env bash'
    # Its process group, for run_timeout to kill the session with everything it started.
    printf 'ps -o pgid= -p $$ | tr -d " " >%q\n' "$RUN_DIR/$n.pgid"
    printf 'cd %q || exit 1\n' "$dir"
    # Through `slot` (#153): a slot of its own, among the ${parallel:-autonomy.parallel} of the run.
    printf 'SENIOR_MODE_RUN=1 %sSENIOR_MODE_RUN_OUTCOME=%q SENIOR_MODE_SLOTS=%q %q slot -- %q -p --model %q --permission-mode bypassPermissions --output-format json' \
      "${RUN_ROLE[$n]:+SENIOR_MODE_ROLE=${RUN_ROLE[$n]} }" "$RUN_DIR/$n.outcome" "${parallel:-$(config_get autonomy.parallel)}" "$SELF" "$RUN_CLAUDE" "$model"
    [ ${#SESSION_FLAGS[@]} -eq 0 ] || printf ' %q' "${SESSION_FLAGS[@]}"
    printf ' "$(cat %q)" >%q 2>%q\n' "$RUN_DIR/$n.prompt" "$RUN_DIR/$n-$model.json" "$RUN_DIR/$n-$model.log"
    echo 'rc=$?'
    run_usage_line "$n" "${RUN_ROLE[$n]:-ticket}" "$RUN_DIR/$n-$model.json"
    printf 'echo $rc >%q.tmp && mv %q.tmp %q\n' "$RUN_DIR/$n.exit" "$RUN_DIR/$n.exit" "$RUN_DIR/$n.exit"
  } >"$script"
  cmd="bash $(printf '%q' "$script")"
  if command -v tmux >/dev/null; then
    if tmux has-session -t senior-mode-run 2>/dev/null; then
      tmux new-window -d -t senior-mode-run -n "#$n" "$cmd" 2>"$RUN_DIR/$n.tmux" || rc=$?
    else
      tmux new-session -d -s senior-mode-run -n "#$n" "$cmd" 2>"$RUN_DIR/$n.tmux" || rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
      run_halt "$n" "the session window did not start: $(head -n 1 "$RUN_DIR/$n.tmux" 2>/dev/null || true)" "$RUN_DIR/$n.tmux" \
        "An autonomous senior-mode run could not start this ticket's session" "tmux's error output is"
      return 1
    fi
  else
    run_detach "$script"
  fi
  echo "#$n: session started on $model${RUN_BATCH[$n]:+ (batch: $(run_members "$n"))}"
  # serve counts its launches for autonomy.sessionsPerHour, the safety cap: one line, the time, per session started.
  [ -z "${RUN_LAUNCH_LOG:-}" ] || serve_now >>"$RUN_LAUNCH_LOG"
}

# Opens the ticket with `senior-mode start` (worktree, branch and Status In progress, named and tracked
# as everywhere else). A ticket that cannot be opened is given up.
run_open() {
  local n=$1 out rc=0 m
  out=$(SENIOR_MODE_RUN=1 SENIOR_MODE_RUN_TOKEN_FILE="$RUN_DIR/token" start "$n" 2>"$RUN_DIR/$n.err") || rc=$?
  RUN_BRANCH[$n]=$(sed -n 's/^branch //p' <<<"$out")
  RUN_WT[$n]=$(sed -n 's/^worktree //p' <<<"$out")
  if [ -z "${RUN_WT[$n]}" ]; then
    run_giveup "$n" "no worktree: $(head -n 1 "$RUN_DIR/$n.err")"
    # The other tickets of its batch were not touched: they stay Ready for the next pick.
    for m in $(run_members "$n"); do [ "$m" = "$n" ] || echo "#$m: not started, #$n, the lead of its batch, has no worktree"; done
    return 1
  fi
  [ "$rc" -eq 0 ] || echo "#$n: could not set the Status In progress: $(head -n 1 "$RUN_DIR/$n.err")" >&2
  # A batch is one worktree, on the branch of its lead: its other tickets are In progress there too.
  for m in $(run_members "$n"); do
    [ "$m" != "$n" ] || continue
    RUN_BRANCH[$m]=${RUN_BRANCH[$n]}
    RUN_WT[$m]=${RUN_WT[$n]}
    (item_set "$m" Status "In progress") >/dev/null || echo "#$m: could not set the Status In progress" >&2
  done
}

# Opens the ticket (run_open), then launches its session on Sonnet with the prompt of RUN_PROMPT (run's own
# by default); a batch gets the prompt of RUN_PROMPT_BATCH (run's own by default): serve sets both, for a session
# that cannot set senior-mode/review (#305).
run_start() {
  local model=sonnet
  run_open "$1" || return 1
  rm -f "$RUN_DIR/$1.batch"
  # A session that a transient error interrupted (serve_transient) resumes on its model, with its prompt as it was.
  if [ -s "$RUN_DIR/$1.model" ] && [ -s "$RUN_DIR/$1.prompt" ]; then
    model=$(cat "$RUN_DIR/$1.model")
    [ -z "${RUN_BATCH[$1]:-}" ] || echo "${RUN_BATCH[$1]}" >"$RUN_DIR/$1.batch"
  elif [ -n "${RUN_BATCH[$1]:-}" ]; then
    # The tickets of the batch, for serve_recover to find them after a restart.
    echo "${RUN_BATCH[$1]}" >"$RUN_DIR/$1.batch"
    "${RUN_PROMPT_BATCH:-run_prompt_batch}" "$1" "${RUN_BRANCH[$1]}" "${RUN_BATCH[$1]}" >"$RUN_DIR/$1.prompt"
  else
    "${RUN_PROMPT:-run_prompt}" "$1" "${RUN_TITLE[$1]}" "${RUN_BRANCH[$1]}" >"$RUN_DIR/$1.prompt"
  fi
  run_launch "$1" "$model"
}

# A ticket whose session cannot go on, as opposed to failed work: labelled needs-human with a comment
# ($4 opens it, $5 says what $3, the file to look at, holds), recorded as failed with reason $2 and counted for the
# circuit breaker. Its Status stays In progress, needs-human is the signal.
run_halt() {
  local s=$1 reason=$2 log=$3 intro=$4 what=$5 n
  # Every ticket of a batch is stuck with its one session.
  for n in $(run_members "$s"); do
    gh_retry api "repos/$RUN_SLUG/issues/$n/labels" -f 'labels[]=needs-human' >/dev/null ||
      echo "#$n: could not label the ticket needs-human" >&2
    gh_bound api "repos/$RUN_SLUG/issues/$n/comments" -f body="$intro: $reason

$what \`$log\`. The branch \`${RUN_BRANCH[$n]}\` is kept as it was, in the worktree \`${RUN_WT[$n]}\`; the Status is unchanged. A person decides what happens next." \
      >/dev/null || echo "#$n: could not comment on the ticket" >&2
    run_record "$n" failed "$reason" "$s"
    RUN_FAILED+=("#$n ${RUN_TITLE[$n]}: $reason (branch ${RUN_BRANCH[$n]} kept, log $log)")
  done
  RUN_FAILS=$((RUN_FAILS + 1))
  [ "$RUN_FAILS" -lt "$RUN_MAXFAIL" ] || RUN_STOP="$RUN_FAILS failed ticket(s) in a row (autonomy.maxConsecutiveFailures)"
  for n in $(run_members "$s"); do notify needs-human "$n" "$reason"; done
}

# A ticket the run stops working on: back to Backlog with a comment, kept worktree and branch.
run_giveup() {
  local n=$1 reason=$2
  (item_set "$n" Status Backlog) >/dev/null || echo "#$n: could not set the Status Backlog" >&2
  gh_bound api "repos/$RUN_SLUG/issues/$n/comments" -f body="An autonomous senior-mode run stopped working on this ticket: $reason

It is back in Backlog. The branch \`${RUN_BRANCH[$n]}\` is kept as it was, in the worktree \`${RUN_WT[$n]}\`." \
    >/dev/null || echo "#$n: could not comment on the ticket" >&2
  RUN_FAILED+=("#$n ${RUN_TITLE[$n]}: $reason (branch ${RUN_BRANCH[$n]} kept)")
  RUN_FAILS=$((RUN_FAILS + 1))
  [ "$RUN_FAILS" -lt "$RUN_MAXFAIL" ] || RUN_STOP="$RUN_FAILS failed ticket(s) in a row (autonomy.maxConsecutiveFailures)"
  notify failed "$n" "$reason"
}

# Kills the process group of the session script $1 (<name>.sh, its group in <name>.pgid), the ticket
# number or docs; $2 names it in the message when it cannot be stopped.
run_kill() {
  local name=$1 pgid="" i
  pgid=$(cat "$RUN_DIR/$name.pgid" 2>/dev/null) || pgid=""
  # Only the group of this session's script: a pgid file that is empty, 0 or 1, run's own group or a
  # leader that is not <name>.sh is never signalled.
  if [[ $pgid =~ ^([2-9]|[1-9][0-9]+)$ ]] && [ "$pgid" != "$(ps -o pgid= -p $$ | tr -d ' ')" ] &&
    [[ $(ps -o args= -p "$pgid" 2>/dev/null) == *"/$name.sh"* ]]; then
    kill -TERM -- "-$pgid" 2>/dev/null || true
    for ((i = 0; i < 20; i++)); do kill -0 -- "-$pgid" 2>/dev/null || break; sleep 0.1; done
    kill -KILL -- "-$pgid" 2>/dev/null || true
  else
    echo "$2: session not stopped (no process group of its own to kill), it may still be running" >&2
  fi
}

# Whether the session script of ticket $1 is gone: nothing alive (a zombie is not) is left in the process
# group it recorded in <n>.pgid, and it left no exit file. The exit file is read again after the check: the
# script may have ended between the two. Not gone while it has not recorded its group yet, or when ps fails.
run_dead() {
  local pgid live
  pgid=$(cat "$RUN_DIR/$1.pgid" 2>/dev/null) || return 1
  [[ $pgid =~ ^([2-9]|[1-9][0-9]+)$ ]] || return 1
  live=$(ps -A -o pgid=,stat= 2>/dev/null) && [ -n "$live" ] || return 1
  ! awk -v g="$pgid" '$1 == g && $2 !~ /^Z/ {found = 1} END {exit !found}' <<<"$live" || return 1
  [ ! -f "$RUN_DIR/$1.exit" ]
}

# Sleeps one poll interval, never past $1 seconds (what is left of the timeout).
run_nap() {
  local poll=${SENIOR_MODE_POLL:-15}
  [ "$1" -ge $((${poll%%.*})) ] || poll=$(($1 > 0 ? $1 : 0))
  sleep "$poll"
}

# A session script that is gone without its exit file (killed, or its tmux window closed): the
# ticket is labelled needs-human with the log path, recorded as failed and counted for the circuit breaker,
# not retried on Opus, as for a timeout. Its Status stays In progress.
run_vanished() {
  local n=$1
  run_halt "$n" "the session ended without leaving its exit code" "$RUN_DIR/$n-${RUN_MODEL[$n]}.log" \
    "An autonomous senior-mode run found this ticket's session gone" "The session log is"
}

# A session that outlived autonomy.sessionTimeout: killed with its process group (the group of a tmux
# window or of setsid; processes that left it by their own setsid are out of reach), then the ticket is
# labelled needs-human with the log path, recorded as failed and counted for the circuit breaker. Not
# retried on Opus: ADR 0014 escalates failed work, not a stuck session. Its Status stays In progress,
# needs-human is the signal.
run_timeout() {
  local n=$1 reason
  reason="timed out after $RUN_TIMEOUT minute$([ "$RUN_TIMEOUT" -eq 1 ] || echo s)"
  run_kill "$n" "#$n"
  run_halt "$n" "$reason" "$RUN_DIR/$n-${RUN_MODEL[$n]}.log" \
    "An autonomous senior-mode run stopped this ticket's session (autonomy.sessionTimeout)" "The session log is"
}

# Whether the pull request $1 (its REST object) is external (ADR 0024, #427): its head is in another repository
# (a fork) or its author is not a collaborator (author_association other than OWNER, MEMBER, COLLABORATOR). A
# missing association counts as external. The daemon never merges one: its content is untrusted data and the
# merge stays human.
pr_external() {
  jq -e '. as $p | ($p.head.repo.full_name != $p.base.repo.full_name)
    or ((["OWNER", "MEMBER", "COLLABORATOR"] | index($p.author_association // "")) == null)' <<<"$1" >/dev/null
}

# Why the pull request $1 (head $2, $3 its REST object) may not merge on its own, in one phrase, or nothing when
# every bound holds (ADR 0003, 0008, 0018, 0024): merging is on, the pull request is not external, the server
# enforces protection, no needs-human, the three statuses green on the head, no protected zone among the files
# GitHub would merge.
run_blocker() {
  local pr=$1 sha=$2 missing="" files zones
  if [ "$RUN_MERGE" != true ]; then
    echo "merging is off (autonomy.merge)"
  elif pr_external "$3"; then
    echo "it is external (a fork or a non-collaborator): its merge stays human"
  elif [ "$RUN_PROTECTION" != ruleset ]; then
    echo "the server enforces no branch protection (github.protection is ${RUN_PROTECTION:-unset})"
  elif jq -e '[.labels[]?.name] | index("needs-human")' <<<"$3" >/dev/null; then
    echo "labelled needs-human"
  # github.requiredChecks false (ADR 0016): the ruleset requires no status, so none is waited for.
  elif [ "$RUN_REQUIRED" = true ] && ! missing=$(gh_retry api "repos/$RUN_SLUG/commits/$sha/status" | jq -r '["senior-mode/ci", "senior-mode/review", "senior-mode/security"]
      - [.statuses[] | select(.state == "success") | .context] | join(" and ")'); then
    echo "its statuses could not be read"
  elif [ "$RUN_REQUIRED" = true ] && [ -n "$missing" ]; then
    echo "$missing not green"
  # The command applies the protected zones, not the reviewer: the files GitHub would merge, against
  # the globs of the base branch, so a pull request cannot unprotect itself.
  elif [ "$RUN_ZONES_KNOWN" != true ]; then
    echo "the protected zones could not be read: $RUN_BASE has no .claude/senior-mode.json"
  elif ! files=$(gh_retry api "repos/$RUN_SLUG/pulls/$pr/files" --paginate --jq '.[] | .filename, (.previous_filename // empty)'); then
    echo "its changed files could not be read"
  elif zones=$(protected_match "$RUN_GLOBS" <<<"$files") && [ -n "$zones" ]; then
    echo "it touches a protected zone ($(paste -sd, - <<<"$zones" | sed 's/,/, /g'))"
  else
    # One commit per ticket of a batch (#297).
    delivery_blocker "$RUN_SLUG" "$pr" "$3"
  fi
}

# A delivered ticket: merged when merging is on and every bound holds (run_blocker), else listed for a human
# with the reason. $2 is the open pull request as the REST list gives it; the tickets after it are the others
# delivered by the same pull request (a batch). --match-head-commit refuses a head pushed after the checks.
run_merge() {
  local n=$1 pr sha reason m all=("$1" "${@:3}")
  pr=$(jq -r '.[0].number' <<<"$2")
  sha=$(jq -r '.[0].head.sha' <<<"$2")
  reason=$(run_blocker "$pr" "$sha" "$(jq -c '.[0]' <<<"$2")")
  if [ -z "$reason" ]; then
    if gh_bound pr merge "$pr" --rebase --match-head-commit "$sha" -R "$RUN_SLUG" >/dev/null 2>"$RUN_DIR/$n.merge"; then
      RUN_PRS+=("#$pr")
      for m in "${all[@]}"; do
        RUN_MERGED+=("#$m ${RUN_TITLE[$m]} (pull request #$pr)")
        if (item_set "$m" Status Done) >/dev/null; then
          cycle_end "$m"
        else
          echo "#$m: merged, but could not set the Status Done" >&2
          RUN_NOT_DONE+=("#$m ${RUN_TITLE[$m]} (pull request #$pr)")
        fi
      done
      return 0
    fi
    reason="the merge failed: $(head -n 1 "$RUN_DIR/$n.merge")"
  fi
  for m in "${all[@]}"; do RUN_WAITING+=("#$m ${RUN_TITLE[$m]}: pull request #$pr, $reason"); done
}

# Writes the outcome of a ticket, the file `retro` reads: $RUN_DIR/<n>.json holds {ticket, outcome
# (delivered, outgrown or failed), escalated (the ticket went to Opus), reason (the last failure the
# session reported, null for a clean delivery), model (of the last session), finishedAt}. $2 is the
# outcome and $3 the reason, possibly empty; $4 the session of the ticket when it is not its own (a batch).
# Spec 0001 section 10.
run_record() {
  local s=${4:-$1}
  jq -nc --argjson n "$1" --arg o "$2" --arg r "$3" --arg m "${RUN_MODEL[$s]}" --arg e "${RUN_ESCALATED[$s]:-false}" \
    --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{ticket: $n, outcome: $o, escalated: ($e == "true"),
    reason: (if $r == "" then null else $r end), model: $m, finishedAt: $t}' >"$RUN_DIR/$1.json"
}

# Sets a ticket In review when its Status is anything else, and says so in the report; a write that
# fails is listed too. A Status that cannot be read counts as not In review.
run_review() {
  local n=$1 current
  current=$( (item_get "$n" Status) 2>/dev/null) || current=""
  [ "$current" != "In review" ] || return 0
  if (item_set "$n" Status "In review") >/dev/null; then
    RUN_REVIEWED+=("#$n ${RUN_TITLE[$n]}")
  else
    echo "#$n: could not set the Status In review" >&2
    RUN_NOT_REVIEW+=("#$n ${RUN_TITLE[$n]}")
  fi
}

# Reads how a finished batch session went (#263): one outcome line per ticket in its outcome file, `#<n> delivered`,
# `#<n> outgrown: <reason>` or `#<n> failed: <reason>`; a file without such lines gives its first line to every
# ticket. The delivered ones are merged or left for a human with their one pull request; each of the others goes
# back alone as a ticket would (run_giveup: Backlog, needs-human, a comment), the delivered ones are not held back.
# When none is delivered the session goes on Opus as a ticket would. Returns 1 when the session goes on.
run_finish_batch() {
  local n=$1 m file=$RUN_DIR/$1.outcome first line pulls='[]' waiting why
  local -a done_=() bad=()
  local -A out=()
  first=$(head -n 1 "$file" 2>/dev/null) || first=""
  [ -n "$first" ] || first="failed: the session ended without saying how it went (exit code $(cat "$RUN_DIR/$n.exit"), log in $RUN_DIR)"
  for m in $(run_members "$n"); do
    if grep -q '^#[0-9]' "$file" 2>/dev/null; then
      line=$(sed -n "s/^#$m //p" "$file" | head -n 1)
      out[$m]=${line:-failed: the session did not say how this ticket went}
    else
      out[$m]=$first
    fi
    if [ "${out[$m]}" = delivered ]; then done_+=("$m"); else bad+=("$m"); fi
  done
  if [ ${#done_[@]} -gt 0 ]; then
    pulls=$(gh_retry api "repos/$RUN_SLUG/pulls?head=${RUN_SLUG%%/*}:${RUN_BRANCH[$n]}&state=open") || pulls='[]'
    if ! jq -e 'length > 0' <<<"$pulls" >/dev/null; then
      for m in "${done_[@]}"; do out[$m]="failed: the session said delivered but there is no open pull request for its branch"; done
      bad=("${done_[@]}" "${bad[@]}")
      done_=()
    fi
  fi
  if [ ${#done_[@]} -eq 0 ] && [ "$RUN_ESCALATE" = true ] && [ "${RUN_MODEL[$n]}" = sonnet ] && [[ ${out[*]} != *outgrown:* ]]; then
    why=${out[$n]#failed: }
    printf '\nA first attempt on Sonnet gave up: %s\nIts work is in this worktree; build on it or reset it.\n' "$why" >>"$RUN_DIR/$n.prompt"
    RUN_ESCALATED[$n]=true
    RUN_REASON[$n]=$why
    run_launch "$n" opus || return 0
    return 1
  fi
  if [ ${#done_[@]} -gt 0 ]; then
    RUN_FAILS=0
    for m in "${done_[@]}"; do run_record "$m" delivered "${RUN_REASON[$n]:-}" "$n"; done
    if [ -n "${RUN_ROLE[$n]:-}" ]; then
      # serve leaves the merge to its integrator pass and the review to its reviewer; the tickets are In review.
      for m in "${done_[@]}"; do run_review "$m"; done
    else
      waiting=${#RUN_WAITING[@]}
      run_merge "${done_[0]}" "$pulls" "${done_[@]:1}"
      if [ ${#RUN_WAITING[@]} -gt "$waiting" ]; then
        for m in "${done_[@]}"; do run_review "$m"; done
      fi
    fi
  fi
  for m in "${bad[@]}"; do
    case ${out[$m]} in
      outgrown:*)
        RUN_STOP="#$m outgrew its size"
        run_record "$m" outgrown "${out[$m]#outgrown: }" "$n"
        run_giveup "$m" "it outgrew its size: ${out[$m]#outgrown: }"
        ;;
      *)
        run_record "$m" failed "${out[$m]#failed: }" "$n"
        run_giveup "$m" "${out[$m]#failed: }"
        ;;
    esac
  done
  return 0
}

# Reads how a finished session went. Returns 1 when the ticket goes on (a retry on Opus).
run_finish() {
  local n=$1 outcome pulls='[]' waiting
  if [ -n "${RUN_BATCH[$n]:-}" ]; then
    run_finish_batch "$n"
    return
  fi
  outcome=$(head -n 1 "$RUN_DIR/$n.outcome" 2>/dev/null) || outcome=""
  [ -n "$outcome" ] || outcome="failed: the session ended without saying how it went (exit code $(cat "$RUN_DIR/$n.exit"), log in $RUN_DIR)"
  if [ "$outcome" = delivered ]; then
    pulls=$(gh_retry api "repos/$RUN_SLUG/pulls?head=${RUN_SLUG%%/*}:${RUN_BRANCH[$n]}&state=open") || pulls='[]'
    jq -e 'length > 0' <<<"$pulls" >/dev/null ||
      outcome="failed: the session said delivered but there is no open pull request for its branch"
  fi
  case $outcome in
    delivered)
      RUN_FAILS=0
      run_record "$n" delivered "${RUN_REASON[$n]:-}"
      # serve leaves the merge to its integrator pass and the review to its reviewer; the ticket is In review.
      if [ -n "${RUN_ROLE[$n]:-}" ]; then
        run_review "$n"
      else
        waiting=${#RUN_WAITING[@]}
        run_merge "$n" "$pulls"
        # Left for a human, the ticket is In review whatever its session did (#261); a merged one is Done.
        if [ ${#RUN_WAITING[@]} -gt "$waiting" ]; then run_review "$n"; fi
      fi
      ;;
    outgrown:*)
      RUN_STOP="#$n outgrew its size"
      run_record "$n" outgrown "${outcome#outgrown: }"
      run_giveup "$n" "it outgrew its size: ${outcome#outgrown: }"
      ;;
    *)
      if [ "$RUN_ESCALATE" = true ] && [ "${RUN_MODEL[$n]}" = sonnet ]; then
        printf '\nA first attempt on Sonnet gave up: %s\nIts work is in this worktree; build on it or reset it.\n' \
          "${outcome#failed: }" >>"$RUN_DIR/$n.prompt"
        RUN_ESCALATED[$n]=true
        RUN_REASON[$n]=${outcome#failed: }
        # A window that did not start has failed the ticket: it is finished, not going on.
        run_launch "$n" opus || return 0
        return 1
      fi
      run_record "$n" failed "${outcome#failed: }"
      run_giveup "$n" "${outcome#failed: }"
      ;;
  esac
}

# An alert (#155): $1 the event (needs-human, failed or breaker), $2 the issue or pull request number (empty when
# there is none: the breaker pause), $3 the reason. A number gets the needs-human label and a comment that mentions
# notify.mention (the repository owner when empty); when notify.webhook is set, it gets a JSON POST
# {event, repo, number, url, reason}. Never fatal: what cannot be sent is said on stderr.
notify() {
  local event=$1 n=$2 reason=$3 mention hook url=""
  mention=$(config_get notify.mention)
  mention=${mention:-${RUN_SLUG%%/*}}
  if [ -n "$n" ]; then
    url="https://github.com/$RUN_SLUG/issues/$n"
    gh_retry api "repos/$RUN_SLUG/issues/$n/labels" -f 'labels[]=needs-human' >/dev/null ||
      echo "#$n: could not label it needs-human" >&2
    gh_bound api "repos/$RUN_SLUG/issues/$n/comments" -f body="@${mention#@} this needs a human ($event): $reason" >/dev/null ||
      echo "#$n: could not mention $mention" >&2
  fi
  hook=$(config_get notify.webhook)
  [ -z "$hook" ] || curl -fsS -m 10 -X POST -H 'Content-Type: application/json' "$hook" -d "$(jq -nc --arg e "$event" \
    --arg r "$RUN_SLUG" --arg n "$n" --arg u "$url" --arg why "$reason" '{event: $e, repo: $r,
    number: (if $n == "" then null else ($n | tonumber) end), url: (if $u == "" then null else $u end), reason: $why}')" >/dev/null ||
    echo "notify: the webhook did not answer ($event)" >&2
}

# After merges, one session brings the living docs up to date, on its own branch and pull request. It is
# bounded like a ticket session (autonomy.sessionTimeout, killed with its process group) and its outcome
# is written to $RUN_DIR/docs-outcome.json ({session, outcome (done or failed), reason, finishedAt}; not a
# ticket, so `retro` does not read it). No ticket to label: a failure is on stderr and in the report. The
# worktree and branch are kept as they were. The poll never sleeps past the timeout, and a script that is gone
# without its exit file is reported as that, not as a timeout.
# shellcheck disable=SC2016 # lines of the script, expanded when it runs
run_docs() {
  local wt branch=docs/run-$RUN_STAMP script=$RUN_DIR/docs.sh reason="" rc started=$SECONDS pid limit left stat
  local -a SESSION_FLAGS
  wt=$(worktree_path "$RUN_ROOT" "run-docs-$RUN_STAMP")
  git_bound fetch -q origin 2>/dev/null || true
  git worktree add -q -b "$branch" "$wt" "$RUN_BASE" 2>/dev/null || {
    echo "docs: no worktree, skipped" >&2
    return 0
  }
  run_session_flags "$wt"
  run_trust "$wt"
  printf "Pull requests %s were just merged on %s. Bring the living docs up to date with them (README, architecture, user-facing changelog), with the project's docs skill if it has one. If nothing needs to change, stop. Otherwise commit on branch %s, run senior-mode check, push and open a pull request; never merge it.\n" \
    "${RUN_PRS[*]}" "$RUN_SLUG" "$branch" >"$RUN_DIR/docs.prompt"
  {
    echo '#!/usr/bin/env bash'
    printf 'ps -o pgid= -p $$ | tr -d " " >%q\n' "$RUN_DIR/docs.pgid"
    printf 'cd %q || exit 1\n' "$wt"
    printf 'SENIOR_MODE_RUN=1 %q -p --model sonnet --permission-mode bypassPermissions --output-format json' "$RUN_CLAUDE"
    [ ${#SESSION_FLAGS[@]} -eq 0 ] || printf ' %q' "${SESSION_FLAGS[@]}"
    printf ' "$(cat %q)" >%q 2>%q\n' "$RUN_DIR/docs.prompt" "$RUN_DIR/docs.json" "$RUN_DIR/docs.log"
    echo 'rc=$?'
    run_usage_line null docs "$RUN_DIR/docs.json"
    printf 'echo $rc >%q.tmp && mv %q.tmp %q\n' "$RUN_DIR/docs.exit" "$RUN_DIR/docs.exit" "$RUN_DIR/docs.exit"
  } >"$script"
  run_detach "$script"
  pid=$!
  limit=$((RUN_TIMEOUT * ${SENIOR_MODE_TIMEOUT_UNIT:-60}))
  until [ -f "$RUN_DIR/docs.exit" ]; do
    left=$((limit - (SECONDS - started)))
    if [ "$left" -le 0 ]; then
      reason="docs session timed out after $RUN_TIMEOUT minute$([ "$RUN_TIMEOUT" -eq 1 ] || echo s)"
      run_kill docs docs
      break
    fi
    # The script is gone (killed, not a zombie) and left no exit file: the cause, not the timeout.
    stat=$(ps -o stat= -p "$pid" 2>/dev/null || true)
    if { [ -z "$stat" ] || [[ $stat == Z* ]]; } && [ ! -f "$RUN_DIR/docs.exit" ]; then
      reason="docs session ended without leaving its exit code (log in $RUN_DIR/docs.log)"
      break
    fi
    run_nap "$left"
  done
  if [ -z "$reason" ]; then
    rc=$(cat "$RUN_DIR/docs.exit")
    [ "$rc" -eq 0 ] || reason="docs session failed (exit code $rc, log in $RUN_DIR/docs.log)"
  fi
  [ -z "$reason" ] || {
    echo "docs: $reason" >&2
    RUN_FAILED+=("$reason (branch $branch kept, log $RUN_DIR/docs.log)")
  }
  jq -nc --arg r "$reason" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{session: "docs", outcome: (if $r == "" then "done" else "failed" end),
    reason: (if $r == "" then null else $r end), finishedAt: $t}' >"$RUN_DIR/docs-outcome.json"
}

# Is the plugin enabled for the sessions the run starts? Claude Code keeps it in `enabledPlugins`
# ("<plugin>@<marketplace>": true) of the user settings (CLAUDE_CONFIG_DIR, else ~/.claude) and of the
# project's tracked .claude/settings.json; the project's wins. Ticket sessions run in fresh worktrees of
# the base branch, so the project's file is read from $RUN_BASE: an untracked settings.local.json is not in
# their worktree and does not count. The managed settings (managed-settings.json of the platform, or the
# colon-separated files of SENIOR_MODE_MANAGED_SETTINGS) are read last and win over both. `run` starts its
# sessions without --settings, so no flag changes this.
run_plugin_enabled() {
  local f managed=${SENIOR_MODE_MANAGED_SETTINGS-"/etc/claude-code/managed-settings.json:/Library/Application Support/ClaudeCode/managed-settings.json"}
  {
    cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" 2>/dev/null || true
    git show "$RUN_BASE:.claude/settings.json" 2>/dev/null || true
    while IFS= read -r f; do
      [ -z "$f" ] || cat "$f" 2>/dev/null || true
    done < <(tr ':' '\n' <<<"$managed")
  } | jq -es 'reduce .[] as $s ({}; . + ($s.enabledPlugins // {}))
    | to_entries | any(.[]; (.key | startswith("senior-mode@")) and .value == true)' >/dev/null 2>&1
}

# Stops the probe: its process group when it has one of its own ($2 not empty: it ran under setsid, so the
# group is its pid), TERM then KILL, so the hooks and MCP servers it started go with it; else its pid only.
run_probe_stop() {
  local i
  if [ -z "$2" ]; then
    kill "$1" 2>/dev/null || true
    return 0
  fi
  kill -TERM -- "-$1" 2>/dev/null || return 0
  for ((i = 0; i < 20; i++)); do kill -0 -- "-$1" 2>/dev/null || return 0; sleep 0.1; done
  kill -KILL -- "-$1" 2>/dev/null || true
}

# Once a day, a probe session that tries a command guard-bash denies in every session and that is inert
# if the deny fails (git init of a temporary directory under a core.hooksPath override). It runs in a
# throwaway worktree of the base branch, what a ticket session sees, in a process group of its own that is
# stopped, with what it started, after SENIOR_MODE_PROBE_TIMEOUT seconds (default 300) or when run gets
# INT or TERM (the worktree and the temporary directory go too). The probe passes when the deny shows in
# the session's output and the directory was not created. The date of the last pass is in
# <git common dir>/senior-mode/probe. A failed probe leaves its output in probe.log and its time and
# reason in probe-failed: it is not retried, and run refuses to start, until SENIOR_MODE_PROBE_RETRY
# seconds (default 3600) have passed, so a cron tick does not start a session every time.
run_probe() {
  local state=$1/senior-mode/probe failed=$1/senior-mode/probe-failed tmp why="" rc=0 pid="" dog="" ss="" last now
  local -a SESSION_FLAGS
  [ "$(cat "$state" 2>/dev/null)" != "$(date +%F)" ] || return 0
  mkdir -p "$1/senior-mode"
  last=$(sed -n 1p "$failed" 2>/dev/null) || last=""
  now=$(date +%s)
  if [[ $last =~ ^[0-9]+$ ]] && [ $((now - last)) -lt "${SENIOR_MODE_PROBE_RETRY:-3600}" ]; then
    die "the guard probe failed $(((now - last) / 60)) minute(s) ago: $(sed -n 2p "$failed"). It is retried once every $((${SENIOR_MODE_PROBE_RETRY:-3600} / 60)) minutes, not at every run. Output in $1/senior-mode/probe.log; nothing was started."
  fi
  tmp=$(mktemp -d)
  git -C "$RUN_ROOT" worktree add -q --detach "$tmp/probe" "$RUN_BASE" 2>/dev/null || {
    rm -rf "$tmp"
    die "the guard probe could not open a worktree of $RUN_BASE; nothing was started."
  }
  trap 'run_probe_cleanup; exit 130' INT
  trap 'run_probe_cleanup; exit 143' TERM
  ! command -v setsid >/dev/null || ss=setsid
  # With the flags of a ticket session, so the probe proves the guards load the way the sessions load them.
  run_session_flags "$tmp/probe"
  (cd "$tmp/probe" && SENIOR_MODE_RUN=1 exec ${ss:+"$ss"} "$RUN_CLAUDE" -p --model haiku \
    --permission-mode bypassPermissions --output-format stream-json --verbose \
    ${SESSION_FLAGS[@]+"${SESSION_FLAGS[@]}"} \
    "This is a guard probe. Run exactly this one Bash command and nothing else: \`git -c core.hooksPath=/dev/null init -q $tmp/ran\`. If a hook denies it, do not retry and do not work around it: answer with one line saying it was denied." \
    >"$tmp/out" 2>&1) &
  pid=$!
  (trap 'kill "$s" 2>/dev/null; exit' INT TERM; sleep "${SENIOR_MODE_PROBE_TIMEOUT:-300}" & s=$!; wait "$s"; run_probe_stop "$pid" "$ss") &
  dog=$!
  wait "$pid" || rc=$?
  kill "$dog" 2>/dev/null || true
  run_probe_stop "$pid" "$ss"
  trap - INT TERM
  git -C "$RUN_ROOT" worktree remove --force "$tmp/probe" 2>/dev/null || true
  if [ -e "$tmp/ran" ]; then
    why="the denied command ran"
  elif ! grep -q 'senior-mode: skipping checks is denied' "$tmp/out"; then
    why="no deny showed in the session (exit code $rc)"
  fi
  if [ -n "$why" ]; then
    cp "$tmp/out" "$1/senior-mode/probe.log"
    printf '%s\n%s\n' "$(date +%s)" "$why" >"$failed"
    rm -rf "$tmp"
    die "the guard probe failed: $why. A session was asked to run git -c core.hooksPath=... and the guard did not stop it, so the guards may not be active in run sessions. Output in $1/senior-mode/probe.log; nothing was started."
  fi
  rm -rf "$tmp"
  rm -f "$failed"
  date +%F >"$state"
}

# What run_probe's INT and TERM traps undo: the probe with its processes, its worktree, its directory.
run_probe_cleanup() {
  [ -z "$dog" ] || kill "$dog" 2>/dev/null || true
  [ -z "$pid" ] || run_probe_stop "$pid" "$ss"
  git -C "$RUN_ROOT" worktree remove --force "$tmp/probe" 2>/dev/null || true
  rm -rf "$tmp"
}

# Before a run starts (#117): with the claude CLI, the plugin is enabled (or loaded with --plugin-dir) and
# its hooks.json is there, and the daily probe shows the guards deny. $1 is the git common dir.
run_guards() {
  local root hooks
  root=${SENIOR_MODE_PLUGIN_DIR:-$(dirname "$(dirname "$SELF")")}
  hooks=$root/hooks/hooks.json
  [ "$(config_get agent.command)" = claude ] || return 0
  [ -f "$hooks" ] || die "no hooks.json at $hooks: the guards would not run in the sessions; nothing was started."
  # Unless autonomy.userSettings brings the user's settings back, sessions load the plugin with --plugin-dir.
  [ -n "${SENIOR_MODE_PLUGIN_DIR:-}" ] || [ "$(config_get autonomy.userSettings)" != true ] || run_plugin_enabled ||
    die "the senior-mode plugin is not enabled for ticket sessions (enabledPlugins in ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json or in .claude/settings.json committed on $RUN_BASE; an untracked settings.local.json is not in their worktrees): the guards would not run; nothing was started."
  run_probe "$1"
}

# What `run` and `serve` ($1) share before their first session: refuses root and a machine that cannot stop
# a session group, reads the config into the RUN_* variables of its caller, finds the agent, the slug, the
# main checkout and the base branch, and checks the guards (#117) and the protected zones of the base.
run_prepare() {
  [ "$(id -u)" != 0 ] || die "$1 cannot work as root: claude refuses to skip permission prompts for root; use a normal user"
  run_can_detach || die "$1 needs setsid or perl to stop a session that outlives autonomy.sessionTimeout, and has neither (install util-linux for setsid); nothing was started."
  command -v flock >/dev/null || die "$1 needs flock to give each session a slot of its own, and has none (install util-linux); nothing was started."
  file=$(config_file)
  RUN_MAXFAIL=$(config_get autonomy.maxConsecutiveFailures)
  RUN_MERGE=$(config_get autonomy.merge)
  RUN_ESCALATE=$(config_get autonomy.escalate)
  RUN_TIMEOUT=$(config_get autonomy.sessionTimeout)
  [[ $RUN_TIMEOUT =~ ^[1-9][0-9]*$ ]] && [ "$RUN_TIMEOUT" -le 1440 ] ||
    die "autonomy.sessionTimeout must be a whole number of minutes from 1 to 1440, not $RUN_TIMEOUT"
  RUN_PROTECTION=$(jq -r '.github.protection // empty' "$file")
  RUN_REQUIRED=$(jq -r 'if .github.requiredChecks == false then "false" else "true" end' "$file")
  RUN_CLAUDE=$(agent_bin)
  RUN_SLUG=$(repo_slug)
  # The main checkout, even when run from a ticket worktree (they live in its .git, or beside it).
  RUN_ROOT=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")
  RUN_USAGE=$(git rev-parse --path-format=absolute --git-common-dir)/senior-mode/usage.jsonl
  git_bound fetch -q origin || echo "senior-mode: could not fetch origin; starting from the last fetched state" >&2
  RUN_BASE=$(default_branch) || die "no default branch found"
  run_guards "$(git rev-parse --path-format=absolute --git-common-dir)"
  # Protected zones as the base branch has them; a branch cannot edit its own.
  RUN_GLOBS='[]' RUN_ZONES_KNOWN=false
  if git cat-file -e "$RUN_BASE:.claude/senior-mode.json" 2>/dev/null; then
    RUN_ZONES_KNOWN=true
    RUN_GLOBS=$(git show "$RUN_BASE:.claude/senior-mode.json" | jq -c '.protected // []') || RUN_GLOBS=null
  fi
  jq -e 'type == "array" and all(type == "string")' <<<"$RUN_GLOBS" >/dev/null ||
    die "protected in .claude/senior-mode.json of $RUN_BASE must be an array of globs"
}

# The token `start` checks to skip the wip limit (#145): in memory and in a 0600 file under $RUN_DIR, which
# the caller removes when it ends.
run_token_new() {
  RUN_TOKEN=$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')
  [ ${#RUN_TOKEN} -eq 48 ] || die "cannot draw a random token for the run"
  (umask 077 && printf '%s\n' "$RUN_TOKEN" >"$RUN_DIR/token") || die "cannot write the run token"
}

# One look at the sessions in `running` (the caller's array): finished ones are read (run_finish), the ones
# past autonomy.sessionTimeout are killed (run_timeout), the others stay. RUN_ON_EXIT, when set, names a
# function that gets a finished session first and returns 0 when it took care of it (serve: a usage limit);
# RUN_FINISH names the one that reads how it went (default run_finish; serve: one per role).
# SENIOR_MODE_TIMEOUT_UNIT: seconds in a minute of autonomy.sessionTimeout (default 60), for the tests.
run_reap() {
  local n still=()
  for n in "${running[@]}"; do
    if [ -f "$RUN_DIR/$n.exit" ]; then
      if [ -n "${RUN_ON_EXIT:-}" ] && "$RUN_ON_EXIT" "$n"; then continue; fi
      "${RUN_FINISH:-run_finish}" "$n" && continue
    elif [ $((SECONDS - RUN_STARTED[$n])) -ge $((RUN_TIMEOUT * ${SENIOR_MODE_TIMEOUT_UNIT:-60})) ]; then
      run_timeout "$n"
      continue
    elif run_dead "$n"; then
      run_vanished "$n"
      continue
    fi
    still+=("$n")
  done
  running=("${still[@]}")
}

# senior-mode run [--max N] [--parallel P]: delivers up to N Ready tickets, P at a time, each in a
# headless claude session in its own worktree (spec 0001 §10, ADR 0007), then reports in plain words.
run() {
  local max="" parallel="" n size title t left batch
  local -a queue=() running=() RUN_MERGED=() RUN_NOT_DONE=() RUN_REVIEWED=() RUN_NOT_REVIEW=() RUN_WAITING=() RUN_FAILED=() RUN_PRS=()
  local -A RUN_TITLE=() RUN_BRANCH=() RUN_WT=() RUN_MODEL=() RUN_ESCALATED=() RUN_REASON=() RUN_STARTED=() RUN_ROLE=() RUN_CWD=() RUN_BATCH=()
  local RUN_TOKEN RUN_SLUG RUN_BASE RUN_DIR RUN_ROOT RUN_STAMP RUN_CLAUDE RUN_MERGE RUN_ESCALATE RUN_MAXFAIL RUN_PROTECTION RUN_REQUIRED RUN_GLOBS RUN_ZONES_KNOWN RUN_TIMEOUT
  local RUN_FAILS=0 RUN_STOP=""
  while [ $# -gt 0 ]; do
    case $1 in
      --max | --parallel)
        [[ ${2:-} =~ ^[1-9][0-9]*$ ]] || die "run $1 needs a positive number"
        if [ "$1" = --max ]; then max=$2; else parallel=$2; fi
        shift
        ;;
      *) usage ;;
    esac
    shift
  done
  run_prepare run
  max=${max:-$(config_get autonomy.maxTickets)}
  parallel=${parallel:-$(config_get autonomy.parallel)}
  RUN_STAMP=$(date +%Y%m%d-%H%M%S)-$$
  RUN_DIR=$(git rev-parse --path-format=absolute --git-common-dir)/senior-mode/runs/$RUN_STAMP
  "$SELF" clean || echo "senior-mode: clean failed; the run goes on" >&2
  security_alerts
  data=$(board_data false) || exit 1
  board_archive "$data"
  while IFS=$'\t' read -r n size title batch; do
    [ -n "$n" ] || continue
    RUN_TITLE[$n]=$title
    # A batch is one queue entry, under its lead; its other tickets come after it in the pick order.
    if [ -n "$batch" ]; then
      [ "${batch%% *}" = "$n" ] || continue
      RUN_BATCH[$n]=$batch
    fi
    queue+=("$n")
  done < <(queue_lines "$data" "$max")
  if [ ${#queue[@]} -eq 0 ]; then
    echo "No Ready ticket to run."
    return 0
  fi
  mkdir -p "$RUN_DIR"
  # shellcheck disable=SC2064 # expand now: RUN_DIR is local and gone when the trap runs
  trap "rm -f '$RUN_DIR/token'" EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  run_token_new
  echo "run: ${#queue[@]} ticket(s), $parallel at a time; sessions and logs in $RUN_DIR"

  while [ ${#queue[@]} -gt 0 ] || [ ${#running[@]} -gt 0 ]; do
    while [ -z "$RUN_STOP" ] && [ ${#running[@]} -lt "$parallel" ] && [ ${#queue[@]} -gt 0 ]; do
      # The first queued ticket whose Paths do not overlap a running one (#152): the index in t.
      t=$(pick_free "$data" "$(run_busy)" "$(for n in "${queue[@]}"; do run_entry "$n"; done | paste -sd' ' -)")
      [ -n "$t" ] || break
      n=${queue[t]}
      queue=("${queue[@]:0:t}" "${queue[@]:t+1}")
      if run_start "$n"; then running+=("$n"); fi
    done
    [ ${#running[@]} -gt 0 ] || break
    # SENIOR_MODE_TIMEOUT_UNIT: seconds in a minute of autonomy.sessionTimeout (default 60), for the tests.
    # The nap stops at the first timeout to come.
    left=$((RUN_TIMEOUT * ${SENIOR_MODE_TIMEOUT_UNIT:-60}))
    for n in "${running[@]}"; do
      t=$((RUN_TIMEOUT * ${SENIOR_MODE_TIMEOUT_UNIT:-60} - (SECONDS - RUN_STARTED[$n])))
      [ "$t" -ge "$left" ] || left=$t
    done
    run_nap "$left"
    run_reap
  done
  [ ${#RUN_MERGED[@]} -eq 0 ] || run_docs
  "$SELF" clean || echo "senior-mode: clean failed" >&2

  echo
  [ -z "$RUN_STOP" ] || echo "The run stopped early: $RUN_STOP."
  for t in "${RUN_MERGED[@]}"; do echo "Merged: $t"; done
  for t in "${RUN_NOT_DONE[@]}"; do echo "Status not set to Done: $t"; done
  for t in "${RUN_REVIEWED[@]}"; do echo "Status set to In review: $t"; done
  for t in "${RUN_NOT_REVIEW[@]}"; do echo "Status not set to In review: $t"; done
  for t in "${RUN_WAITING[@]}"; do echo "Waiting for a human: $t"; done
  for t in "${RUN_FAILED[@]}"; do echo "Failed: $t"; done
  for n in "${queue[@]}"; do
    for t in $(run_members "$n"); do echo "Not started: #$t ${RUN_TITLE[$t]}"; done
  done
}
