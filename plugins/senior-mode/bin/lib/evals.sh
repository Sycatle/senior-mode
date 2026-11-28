# shellcheck shell=bash
# Skill evals (#368): a change to a skill or an agent that answers a failure cause (an improvement ticket of `retro`)
# carries a before/after eval of the targeted `evals/` case in its pull request, and `ready` refuses it without one. Only the
# shipped skills and agents (`plugins/senior-mode/`) are held to it, not a project's own `.claude/` ones (ADR 0034).

# The "Eval" table of a pull request body $1, one row per line as `<case>\t<before k>\t<before n>\t<after k>\t<after n>`:
# the rows under a heading that says "eval" whose second and third cells are scores `k/n`.
eval_rows() {
  jq -rn --arg body "$1" '
    [$body | split("\n") | foreach .[] as $l ({in: false};
        if ($l | test("^#{1,6}\\s")) then .in = ($l | test("^#{1,6}\\s+.*eval"; "i")) else . end;
        select(.in and ($l | test("^\\s*\\|"))) | $l)][]
    | [split("|")[1:-1][] | gsub("^\\s+|\\s+$"; "")]
    | select(length >= 3 and (.[1] | test("^[0-9]+/[0-9]+$")) and (.[2] | test("^[0-9]+/[0-9]+$")))
    | [.[0], (.[1] | split("/")[]), (.[2] | split("/")[])] | @tsv'
}

# What stops the pull request $2 of $1 (owner/name), with REST object $3 and changed files $4 (`<path>\t<lines>` lines),
# for the skill or agent it changes on account of an improvement ticket (its body has a `retro-cause:` line), in one
# phrase, or nothing. Starts with "not ready: " when the pull request is at fault; other phrases say what could not be read.
eval_blocker() {
  local slug=$1 pull=$3 files=$4 changed n issue rows row cases="" c name bk bn ak an
  changed=$(cut -f1 <<<"$files" | grep -E '^plugins/senior-mode/(skills|agents)/' | paste -sd, - | sed 's/,/, /g') || changed=""
  [ -n "$changed" ] || return 0
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    issue=$(gh_retry issue view "$n" --repo "$slug" --json body 2>/dev/null) || {
      echo "the body of #$n could not be read"
      return 0
    }
    jq -e '(.body // "") | test("(^|\n)retro-cause: ")' <<<"$issue" >/dev/null || continue
    rows=$(eval_rows "$(jq -r '.body // ""' <<<"$pull")")
    if [ -z "$rows" ]; then
      for c in "$(git rev-parse --show-toplevel 2>/dev/null)"/evals/*/run.sh; do
        [ ! -f "$c" ] || cases+=${cases:+, }$(basename "$(dirname "$c")")
      done
      echo "not ready: #$n answers a failure cause and changes a skill or agent ($changed) but its body has no Eval table: run the targeted case with evals/compare.sh <case>${cases:+ ($cases)} and put its table under \"## Eval\" (| Case | Before | After |, scores as k/n)"
      return 0
    fi
    while IFS=$'\t' read -r name bk bn ak an; do
      if [ "$bn" -lt 2 ] || [ "$an" -lt 2 ]; then
        echo "not ready: the Eval table of #$n shows $name with fewer than 2 runs on one side: several runs each"
        return 0
      fi
      if [ $((ak * bn)) -lt $((bk * an)) ]; then
        echo "not ready: the Eval table of #$n shows $name at $ak/$an after, below $bk/$bn before"
        return 0
      fi
    done <<<"$rows"
  done < <(pr_closed_tickets "$(jq -r '.body // ""' <<<"$pull")")
}
