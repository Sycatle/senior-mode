# shellcheck shell=bash
# What `retro` learns from failures (#364, spec 325 section 8.3): each ticket that needed a second review round, an
# escalation, a stuck stop or a revert gets one label `cause:<x>`, and a cause that repeats on the same paths or
# skill opens one improvement ticket aimed at it.

# The five causes, in the words of the labels.
RETRO_CAUSES='missing-context fuzzy-criterion fragile-test tool weak-model'

# The failures of the period and the causes that repeat. Input: the facts of `retro` (done, runs, reopened, since,
# until). $h is the history, $b the board, $repeat the number of tickets that makes a cause repeat. Prints
# {failures: [{number, title, signals, evidence, cause, labelled, paths, areas}], groups: [{cause, area, tickets}]}.
# A signal is a second review round (a merged pull request with a review after a changes-requested one), an
# escalation, a stuck stop (a run that failed, an outgrown one is a size matter), or a revert (a reopened ticket, a
# merged pull request titled Revert). The cause is read from the words of the evidence, in this order: tool, then
# fragile-test, fuzzy-criterion, missing-context; with none of them, a run that escalated or got stuck is weak-model
# and the rest is fuzzy-criterion. A cause label already on the ticket stays: a human may have corrected it.
# An area is a glob of the Paths field of the ticket, or skill:<name> for a path under skills/<name>/.
# shellcheck disable=SC2016 # a jq program, not shell
RETRO_FAILURES_JQ='def branch_ticket: [capture($ENV.SENIOR_MODE_BRANCH_RE // "^[a-z]+/(?<n>[0-9]+)(-|$)") | .n | tonumber] | first;
  def excerpt: gsub("\\s+"; " ") | gsub("^ | $"; "") | .[:160];
  def classify($sig; $text):
    ($text | ascii_downcase) as $t
    | if ($t | test("\\b(gh|git|npm|pnpm|cli|hook|sandbox|permission|network|rate limit|credentials|environment|install|auth|command not found)\\b")) then "tool"
      elif ($t | test("flak|intermittent|non-?determin|race condition|snapshot|timing|order-dependent")) then "fragile-test"
      elif ($t | test("criteri|ambigu|unclear|requirement|misread|misunderst|not what|wrong behavio|intent|scope")) then "fuzzy-criterion"
      elif ($t | test("context|convention|pitfall|did not know|unaware|already exists|legacy|undocumented|\\bdocs?\\b|knowledge")) then "missing-context"
      elif ($sig | index("escalated") or index("stuck")) then "weak-model"
      else "fuzzy-criterion" end;
  . as $d | ($d.until // "9999") as $until | $h.data.repository.pullRequests.nodes as $prs
  | ($b.items | map({key: (.number | tostring), value: .}) | from_entries) as $byn
  | ([$prs[] | select(.mergedAt >= $d.since and .mergedAt < $until) | . as $p | ($p.headRefName | branch_ticket) as $n | select($n != null)
        | $p.reviews.nodes as $r | ([$r | to_entries[] | select(.value.state == "CHANGES_REQUESTED") | .key] | first) as $i
        | select($i != null and ($r | length) > $i + 1)
        | {number: $n, signal: "second-review",
           line: "pull request #\($p.number) needed a second review round after changes requested by \($r[$i].author.login // "someone")",
           text: ($r[$i].bodyText // "" | excerpt)}]
     + [$prs[] | select(.mergedAt >= $d.since and .mergedAt < $until and (.title | test("^revert"; "i")))
        | {number: (.headRefName | branch_ticket), signal: "revert", line: "pull request #\(.number) reverts", text: .title} | select(.number != null)]
     + [$d.runs.escalated[] | select(.ticket != null) | {number: .ticket, signal: "escalated", line: "escalated to a stronger model", text: (.reason // "")}]
     + [$d.runs.failed[] | select(.ticket != null and .outcome == "failed") | {number: .ticket, signal: "stuck", line: "stopped stuck", text: (.reason // "")}]
     + [$d.reopened[] | {number, signal: "revert", line: "reopened at \(.at)", text: ""}])
    | group_by(.number)
    | map(. as $g | $g[0].number as $n | ($byn[($n | tostring)] // {}) as $i
        | ($i.labels // [] | map(select(startswith("cause:")) | ltrimstr("cause:")) | map(select(IN("missing-context", "fuzzy-criterion", "fragile-test", "tool", "weak-model"))) | first) as $have
        | ([$g[].signal] | unique) as $sig
        | ($i.paths // "" | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(. != ""))) as $paths
        | {number: $n, title: ($i.title // ([$h.data.repository.issues.nodes[] | select(.number == $n) | .title] | first) // ""), signals: $sig,
           evidence: [$g[] | .line + (if .text == "" then "" else ": \"\(.text)\"" end)],
           cause: ($have // classify($sig; [$g[].text] | join(" "))), labelled: ($have != null), paths: $paths,
           areas: ($paths + [$paths[] | scan("skills/([^/*]+)") | "skill:" + .[0]] | unique)})
    | . as $f
  | {failures: $f,
     groups: ([$f[] | . as $x | $x.areas[] | {cause: $x.cause, area: ., number: $x.number}] | group_by([.cause, .area])
       | map({cause: .[0].cause, area: .[0].area, tickets: (map(.number) | unique)})
       | map(select((.tickets | length) >= $repeat)) | sort_by([-(.tickets | length), .cause, .area])
       | reduce .[] as $g ([]; if any(.[]; .cause == $g.cause and (($g.tickets - .tickets) | length) == 0) then . else . + [$g] end))}'

# What an improvement ticket proposes for a cause: the action, then its acceptance criterion. $1 cause, $2 area.
retro_proposal() {
  case $1 in
    missing-context)
      printf 'Write a note under `docs/knowledge/` (or an ADR) for `%s` with the facts the sessions lacked, `origin: retro`.\n\n- Given the note is written, when `senior-mode check` runs, then it passes and the note `paths` cover `%s`.\n' "$2" "$2" ;;
    fuzzy-criterion)
      printf 'Make the Definition of Ready stricter for tickets on `%s`: each criterion states an observable result, with its Given/When/Then, before `ready` accepts it.\n\n- Given a new ticket on `%s`, when it is framed, then each criterion states an observable result and `ready` accepts it.\n' "$2" "$2" ;;
    fragile-test)
      printf 'Fix or replace the tests behind the evidence on `%s`.\n\n- Given the tests of `%s` named in the evidence, when they run 10 times in a row, then they pass every time.\n' "$2" "$2" ;;
    tool)
      printf 'Fix the command, hook or permission that failed on `%s` (a CLI ticket).\n\n- Given the failure in the evidence, when the same step runs again on `%s`, then it succeeds or says what to do.\n' "$2" "$2" ;;
    *)
      printf 'Propose a `models` change for tickets on `%s`, as a pull request a human merges.\n\n- Given the tickets of the evidence, when the routing change is proposed, then it names the model and quotes the evidence.\n' "$2" ;;
  esac
}

# The body of the improvement ticket for the group $1 ({cause, area, tickets}) with the failures $2: the tickets and
# their evidence, the proposal, and the line `retro-cause: <cause> <area>` that tells a second pass it is filed.
retro_improvement_body() {
  local cause area
  cause=$(jq -r .cause <<<"$1")
  area=$(jq -r .area <<<"$1")
  printf '## Context\n\n`retro` saw the cause `%s` on %s tickets on `%s`: %s.\n\n## Evidence\n\n' "$cause" "$(jq '.tickets | length' <<<"$1")" "$area" \
    "$(jq -r '.tickets | map("#\(.)") | join(", ")' <<<"$1")"
  jq -r --argjson g "$1" '.[] | select(.number as $n | $g.tickets | index($n)) | "- #\(.number) \(.title): \(.evidence | join("; "))"' <<<"$2"
  printf '\n## Proposal\n\n'
  retro_proposal "$cause" "$area" | sed '/^- Given/,$d'
  printf '## Acceptance criteria\n\n'
  retro_proposal "$cause" "$area" | sed -n '/^- Given/,$p'
  printf '\nretro-cause: %s %s\n' "$cause" "$area"
}

# The label of each failure and the improvement tickets (#364). $1 the facts of `retro`, $2 the history, $3 the board,
# $4 the repository slug. Prints the facts with `failures` and `learning` ({labelled: [numbers labelled now],
# improvements: [{cause, area, tickets, issue, created}]}). A label or a ticket that cannot be written is said on stderr
# and never stops the retro; with nothing that failed, nothing is called.
retro_learn() {
  local data=$1 history=$2 board=$3 slug=$4 repeat out n cause open g marker found title body_file prio filed labelled="" improvements=""
  repeat=$(config_get retro.repeat)
  [[ $repeat =~ ^[1-9][0-9]*$ ]] || die "retro.repeat must be a positive whole number, not $repeat"
  out=$(jq -c --argjson h "$history" --slurpfile b <(printf '%s' "$board") --argjson repeat "$repeat" '$b[0] as $b | '"$RETRO_FAILURES_JQ" <<<"$data") || {
    echo "retro: could not read the failure causes" >&2
    printf '%s\n' "$data"
    return 0
  }
  while IFS=$'\t' read -r n cause; do
    [ -n "$n" ] || continue
    if gh_retry api "repos/$slug/issues/$n/labels" -f "labels[]=cause:$cause" >/dev/null; then
      labelled+="$n"$'\n'
    else
      echo "retro: could not label #$n cause:$cause" >&2
    fi
  done < <(jq -r '.failures[] | select(.labelled | not) | [.number, .cause] | @tsv' <<<"$out")
  if [ "$(jq '.groups | length' <<<"$out")" -gt 0 ]; then
    if open=$(gh_retry issue list --repo "$slug" --state open --limit 1000 --json number,title,body); then
      prio=$(jq -r '.project.fields.Priority.options // {} | keys_unsorted | (map(select(startswith("P2"))) + [last // empty]) | first // empty' "$(config_file)")
      while IFS= read -r g; do
        [ -n "$g" ] || continue
        cause=$(jq -r .cause <<<"$g")
        marker="retro-cause: $cause $(jq -r .area <<<"$g")"
        found=$(jq -r --arg m "$marker" 'first(.[] | select((.body // "") | split("\n") | index($m)) | .number) // empty' <<<"$open")
        if [ -n "$found" ]; then
          improvements+=$(jq -c --argjson n "$found" '. + {issue: $n, created: false}' <<<"$g")$'\n'
          continue
        fi
        title="chore(retro): fix repeated cause:$cause on $(jq -r .area <<<"$g")"
        body_file=$(mktemp)
        retro_improvement_body "$g" "$(jq -c .failures <<<"$out")" >"$body_file"
        if filed=$("$SELF" issue create --title "$title" --body-file "$body_file" --size S ${prio:+--priority "$prio"} --type task </dev/null); then
          improvements+=$(jq -c --argjson n "$(sed -nE 's/^#([0-9]+) .*/\1/p' <<<"$filed" | head -n 1)" '. + {issue: $n, created: true}' <<<"$g")$'\n'
        else
          echo "retro: could not file the improvement ticket for cause:$cause on $(jq -r .area <<<"$g")" >&2
        fi
        rm -f "$body_file"
      done < <(jq -c '.groups[]' <<<"$out")
    else
      echo "retro: could not read the open issues, no improvement ticket filed" >&2
    fi
  fi
  jq -c --argjson o "$out" --argjson l "$(printf '%s' "$labelled" | jq -Rsc 'split("\n") | map(select(. != "") | tonumber)')" \
    --argjson i "$(printf '%s' "$improvements" | jq -sc '.')" '. + {failures: $o.failures, learning: {labelled: $l, improvements: $i}}' <<<"$data"
}

# The failures and the improvement tickets in plain words, a jq program for the text report.
# shellcheck disable=SC2016 # a jq program, not shell
RETRO_LEARN_TEXT_JQ='.learning.labelled as $l
  | "Failure causes (\(.failures | length))",
    (if (.failures | length) == 0 then "  nothing" else
      (.failures[] | "  #\(.number)\(if .title == "" then "" else " " + .title end): cause:\(.cause) (\(.signals | join(", ")))\(if .labelled or (.number | IN($l[])) then "" else ", not labelled" end)",
        (.evidence[] | "    " + .)) end),
    (.learning.improvements[] | "  improvement: #\(.issue) \(if .created then "filed" else "already open" end) for cause:\(.cause) on \(.area) (\(.tickets | map("#\(.)") | join(", ")))")'
