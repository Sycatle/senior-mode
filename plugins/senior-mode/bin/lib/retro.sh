# shellcheck shell=bash
# What `retro` needs beyond the board (spec 0001 §7): the status changes and reopenings of recently
# updated issues, and recently merged pull requests with their size and reviews. One more query.
# shellcheck disable=SC2016 # a GraphQL query, not shell
HISTORY_QUERY='query($owner: String!, $name: String!, $since: DateTime!) {
  repository(owner: $owner, name: $name) {
    issues(first: 100, filterBy: {since: $since}, orderBy: {field: UPDATED_AT, direction: DESC}) { nodes { number title
      timelineItems(first: 50, itemTypes: [PROJECT_V2_ITEM_STATUS_CHANGED_EVENT, REOPENED_EVENT]) { nodes { __typename
        ... on ProjectV2ItemStatusChangedEvent { createdAt status } ... on ReopenedEvent { createdAt } } } } }
    pullRequests(states: MERGED, first: 50, orderBy: {field: UPDATED_AT, direction: DESC}) { nodes { number title headRefName
      additions deletions mergedAt labels(first: 10) { nodes { name } }
      reviews(first: 20) { nodes { state bodyText author { login } } } } }
  }
}'

# The run outcomes of this repository (one object per ticket run, `run` writes it to
# <git common dir>/senior-mode/runs/<stamp>/<n>.json with `ticket`, `outcome`, `escalated`, `reason`,
# `model`, `finishedAt`), as {found, failed, escalated} for the period starting at $2 (and ending before $3, when given). $1 is the git
# common directory. Absent or unreadable files are not an error; the session logs next to the
# outcomes (<n>-<model>.json) are not outcomes. An outgrown ticket counts as failed.
retro_runs() {
  local dir=$1/senior-mode/runs f
  if [ ! -d "$dir" ]; then
    echo '{"found":false,"failed":[],"escalated":[]}'
    return 0
  fi
  {
    for f in "$dir"/*/[0-9]*.json; do
      [[ $f =~ /[0-9]+\.json$ ]] && [ -f "$f" ] || continue
      jq -c --arg m "$(iso_time "$(file_mtime "$f")")" 'if type == "object"
        then {ticket, outcome, escalated, reason, at: (.finishedAt // $m)} else empty end' "$f" 2>/dev/null || true
    done
  } | jq -sc --arg since "$2" --arg until "${3:-9999}" '[.[] | select(.at >= $since and .at < $until)] as $l | {found: true,
    failed: [$l[] | select(.outcome | IN("failed", "outgrown")) | {ticket, outcome, reason, at}] | sort_by(.ticket),
    escalated: [$l[] | select(.escalated == true or .outcome == "escalated") | {ticket, reason, at}] | sort_by(.ticket)}'
}

# The tokens of the sessions of the period (#299), from the ledger the session scripts append to
# (<git common dir>/senior-mode/usage.jsonl, one line per session and model), per ticket and role, with an
# estimated USD equivalent at the public API prices of lib/prices.json. A model that table does not price
# keeps its tokens and is listed as unpriced; a date suffix (claude-haiku-4-5-20251001) prices as its model.
# shellcheck disable=SC2016 # a jq program, not shell
USAGE_RETRO_JQ='$prices[0] as $p
  | def price($m): [$p.perMTok | to_entries[]
      | select(.key as $k | $m == $k or (($m | startswith($k + "-")) and ($m[($k | length) + 1:] | test("^[0-9]{8}$")))) | .value] | first;
  def r4: if . == null then null else . * 10000 | round / 10000 end;
  def total: reduce .[] as $l ({input: 0, output: 0, cacheRead: 0, cacheWrite5m: 0, cacheWrite1h: 0, usd: null, unpriced: []};
      .input += $l.input | .output += $l.output | .cacheRead += $l.cacheRead | .cacheWrite5m += $l.cacheWrite5m | .cacheWrite1h += $l.cacheWrite1h
      | price($l.model) as $q
      | if $q == null then .unpriced = (.unpriced + [$l.model] | unique)
        else .usd = (.usd // 0) + ($l.input * $q.input + $l.output * $q.output + $l.cacheRead * $q.cacheRead
          + $l.cacheWrite5m * $q.cacheWrite5m + $l.cacheWrite1h * $q.cacheWrite1h) / 1000000 end)
    | .usd |= r4;
  [.[] | select(.at >= $since and .at < $until)] as $l
  | {prices: {date: $p.date, source: $p.source},
     tickets: [$l | group_by(.ticket)[] | {ticket: .[0].ticket} + total + {roles: [group_by(.role)[] | {role: .[0].role} + total]}],
     total: ($l | total)}'

retro_usage() {
  local f=$1/senior-mode/usage.jsonl
  { [ ! -f "$f" ] || jq -cR 'fromjson? | select(type == "object" and (.at | type) == "string")' "$f" 2>/dev/null || true; } |
    jq -sc --slurpfile prices "$LIB/prices.json" --arg since "$2" --arg until "${3:-9999}" "$USAGE_RETRO_JQ"
}

# The failed results `check` recorded since the epoch $1 (and before $2, when given), in this repository and its worktrees (ADR 0006).
retro_checks() {
  local common d f mt
  common=$(git rev-parse --path-format=absolute --git-common-dir)
  {
    for d in "$common/senior-mode/checks" "$common"/worktrees/*/senior-mode/checks; do
      [ -d "$d" ] || continue
      for f in "$d"/*; do
        [ -f "$f" ] && [ "$(sed -n 1p "$f")" = failure ] || continue
        mt=$(file_mtime "$f")
        [ "$mt" -ge "$1" ] && [ "$mt" -lt "${2:-99999999999}" ] || continue
        jq -nc --arg c "$(basename "$f" | cut -c1-7)" --arg d "$(sed -n 2p "$f")" --arg at "$(iso_time "$mt")" \
          '{commit: $c, description: $d, at: $at}'
      done
    done
  } | jq -sc 'sort_by(.at)'
}

# The facts of a period as JSON. Inputs: $d board_data, $h the history, $runs, $checks; $since, $now, $repo.
# $until ends the period ("9999" for none) and $iteration names the iteration it is, if any (#180).
# Cycle time runs from the first move to In progress to the close of the ticket; a ticket with no
# recorded start is left out of it. A size is over when the pull request holds more than 1.5 times the
# lines its size allows (S ~50, M ~400, spec §5), since those are approximate.
# shellcheck disable=SC2016 # a jq program, not shell
RETRO_JQ='def branch_ticket: [capture($ENV.SENIOR_MODE_BRANCH_RE // "^[a-z]+/(?<n>[0-9]+)(-|$)") | .n | tonumber] | first;
  def round1: . * 10 | round / 10;
  . as $d | $h.data.repository.issues.nodes as $iss | $h.data.repository.pullRequests.nodes as $prs
  | ($d.items | map({key: (.number | tostring), value: .}) | from_entries) as $byn
  | def lines($n): [$prs[] | select((.headRefName | branch_ticket) == $n) | .additions + .deletions] | if length == 0 then null else add end;
  def cycle($c): ([$iss[] | select(.number == $c.number) | .timelineItems.nodes[]
      | select(.__typename == "ProjectV2ItemStatusChangedEvent" and .status == "In progress") | .createdAt] | sort | first) as $start
    | if $start == null then null else (($c.closedAt | fromdateiso8601) - ($start | fromdateiso8601)) / 3600
      | if . < 0 then null else round1 end end;
  def excerpt: gsub("\\s+"; " ") | gsub("^ | $"; "") | .[:160];
  def why: (if (.labels | index("needs-human")) then ["needs-human label"] else [] end)
    + ([.reviews[]? | select(.state == "CHANGES_REQUESTED")] | last
      | if . then ["changes requested by \(.author.login // "someone")" + (if (.bodyText | test("\\S")) then ": " + (.bodyText | excerpt) else "" end)] else [] end);
  [$d.closed[] | select(.closedAt >= $since and .closedAt < $until and .reason != "NOT_PLANNED") | . as $c | ($byn[($c.number | tostring)] // {}) as $i
    | {number, title, size: $i.size, closedAt, cycleHours: cycle($c), lines: lines($c.number)}] | sort_by(.number) as $done
  | [$done[] | select(.cycleHours != null) | .cycleHours] | sort as $hs
  | {repository: $repo, generatedAt: $now, since: $since, until: (if $until == "9999" then null else $until end), iteration: $iteration, done: $done,
     cycle: {measured: ($hs | length),
       medianHours: (if ($hs | length) == 0 then null else (($hs[(($hs | length) - 1) / 2 | floor] + $hs[($hs | length) / 2 | floor]) / 2) | round1 end),
       worst: ([$done[] | select(.cycleHours != null)] | max_by(.cycleHours) | if . then {number, title, hours: .cycleHours} else null end)},
     humanPullRequests: (([$d.prs[] | select(.labels | index("needs-human")) | {number, title, state: "open", why: ["needs-human label"]}]
       + [$prs[] | select(.mergedAt >= $since and .mergedAt < $until) | .labels = [.labels.nodes[].name] | .reviews = .reviews.nodes
         | {number, title, state: "merged", why: why} | select(.why | length > 0)]) | sort_by(.number)),
     runs: $runs,
     reopened: [$iss[] | . as $i | ([.timelineItems.nodes[] | select(.__typename == "ReopenedEvent" and .createdAt >= $since and .createdAt < $until)] | last) as $e
       | select($e != null) | {number: $i.number, title: $i.title, at: $e.createdAt}] | sort_by(.number),
     checkFailures: $checks,
     sizes: [$done[] | select((.size | IN("S", "M")) and .lines != null) | (if .size == "S" then 50 else 400 end) as $l
       | {number, title, size, lines, limit: $l, over: (.lines > $l * 1.5)}]}'

# The same, in plain words; $head says which period it covers.
# shellcheck disable=SC2016 # a jq program, not shell
RETRO_TEXT_JQ='def sec($h; $ls): $h, (if ($ls | length) == 0 then "  nothing" else ($ls[] | "  " + .) end);
  def ticket: "#\(.number) \(.title)";
  "senior-mode retro · \(.repository) · \(.generatedAt)", "",
  sec("\($head) (\(.done | length))"; [.done[] | ticket + (if .cycleHours then " · \(.cycleHours)h" else "" end)]),
  "Cycle time (In progress to Done)",
  (if .cycle.measured == 0 then "  nothing measured"
   else "  median \(.cycle.medianHours)h, worst \(.cycle.worst.hours)h (\(.cycle.worst | ticket)), over \(.cycle.measured) ticket\(if .cycle.measured > 1 then "s" else "" end)" end),
  sec("Needed a human (\(.humanPullRequests | length))"; [.humanPullRequests[]
    | "pull request #\(.number) \(.title)\(if .state == "open" then " (still open)" else "" end): \(.why | join("; "))"]),
  (if .runs.found then sec("Failed or escalated runs (\((.runs.failed | length) + (.runs.escalated | length)))";
     [.runs.failed[] | "#\(.ticket): failed: \(.reason // "no reason recorded")"]
     + [.runs.escalated[] | "#\(.ticket): escalated: \(.reason // "no reason recorded")"])
   else "Failed or escalated runs", "  no run logs" end),
  sec("Reopened (\(.reopened | length))"; [.reopened[] | ticket]),
  sec("Check failures (\(.checkFailures | length))"; [.checkFailures[] | "\(.commit): \(.description)"]),
  sec("Repository hygiene (\(.hygiene | hygiene_lines | length))"; .hygiene | hygiene_lines),
  sec("Estimates against reality"; [.sizes[] | select(.over) | "#\(.number) \(.size): \(.lines) lines, the size allows about \(.limit)"]
    + (if (.sizes | length) > 0 and all(.sizes[]; .over | not) then ["all within their size"] else [] end)
    + [.calibration[] | (def st($u): if . == null then "n/a" else "\(.median)\($u) (\(.min)-\(.max))" end;
        "\(.size): \(.count) ticket\(if .count > 1 then "s" else "" end), median hours \(.hours | st("h")), lines \(.lines | st("")), tokens \(.tokens | st(""))")]
    + [.calibration[] | .size as $s | .outliers[] | "far outside \($s): #\(.number) \(.title): \(.why | join(", "))"]
    + [.calibration[] | select(.recalibrate) | "recalibrate: \(.recalibrate)"]),
  (def tok: if . >= 1000000 then "\(. / 100000 | round / 10)M" elif . >= 1000 then "\(. / 100 | round / 10)k" else tostring end;
   def cost: (if .usd == null then "no price" elif .usd > 0 and .usd < 0.01 then "<$0.01" else "$\(.usd * 100 | round / 100)" end)
     + (if .usd != null and (.unpriced | length) > 0 then " (no price for \(.unpriced | join(", ")))" else "" end);
   def line: "input \(.input | tok), output \(.output | tok), cache read \(.cacheRead | tok), cache write \(.cacheWrite5m + .cacheWrite1h | tok) · \(cost)";
   sec("Token use (estimated at the API prices of \(.usage.prices.date))";
     [.usage.tickets[] | (if .ticket == null then "run" else "#\(.ticket)" end) as $t | .roles[] | "\($t) \(.role): \(line)"]
     + (if (.usage.tickets | length) > 0 then ["total: \(.usage.total | line)"] else [] end)))'

# Each size against its delivered tickets (#313): count, then median and spread (min, max) of cycle hours,
# changed lines and tokens (the ledger of #299: every kind of token of every role). A ticket is far outside its
# size when it holds more than 1.5 times the lines the size allows, or took more than three times the median
# hours of its size (three measured at least). A size with three tickets or more, most of them over its line
# budget, gets a recalibration hint; the retro skill weighs the hint across iterations.
# shellcheck disable=SC2016 # a jq program, not shell
CALIBRATION_JQ='def med: sort | if length == 0 then null else ((.[(length - 1) / 2 | floor] + .[length / 2 | floor]) / 2) end;
  def stat: if length == 0 then null else {median: med, min: min, max: max} end;
  (.usage.tickets | map(select(.ticket != null) | {key: (.ticket | tostring),
    value: (.input + .output + .cacheRead + .cacheWrite5m + .cacheWrite1h)}) | from_entries) as $tok
  | [.done[] | select(.size | IN("S", "M", "L")) | . + {tokens: $tok[(.number | tostring)]}] as $d
  | {"S": 50, "M": 400} as $limit
  | [$d | group_by(.size)[] | .[0].size as $s | ([.[].cycleHours | select(. != null)]) as $hs
    | {size: $s, count: length, hours: ($hs | stat), lines: ([.[].lines | select(. != null)] | stat),
       tokens: ([.[].tokens | select(. != null)] | stat),
       outliers: [.[] | ([if $limit[$s] and .lines != null and .lines > $limit[$s] * 1.5 then "\(.lines) lines" else empty end]
           + [if ($hs | length) >= 3 and .cycleHours != null and .cycleHours > 3 * ($hs | med) then "\(.cycleHours)h" else empty end]) as $why
         | select($why | length > 0) | {number, title, why: $why}],
       recalibrate: (if $limit[$s] and length >= 3 and ([.[] | select(.lines != null and .lines > $limit[$s] * 1.5)] | length) * 2 > length
         then "most \($s) tickets exceed about \($limit[$s]) lines: size such work up, or split it" else null end)}]'

# What the iteration rules cost (spec 474 §12), from the check times (.git/senior-mode/check-times.jsonl: ts, branch,
# check, seconds, status) and the briefs log (briefs.jsonl: time, session, agent_type, goal) of the period. A run of
# `check` is the stretch of a branch's lines in which no check name comes back; a round trip is a failing run before
# the first passing one. A cached check counts zero seconds. The costliest checks (three, by time) each get one
# recommendation: end its period when it only warned, cache it when it never hit the cache, narrow its inputs when
# it rarely did, else move it to tier 3. A rework is a call of an agent type that repeats the session and the Goal
# of an earlier call. Input: the retro data; $times and $briefs are arrays of lines, $since and $until the period.
# shellcheck disable=SC2016 # a jq program, not shell
RETRO_ITERATION_JQ='def branch_ticket: [capture($ENV.SENIOR_MODE_BRANCH_RE // "^[a-z]+/(?<n>[0-9]+)(-|$)") | .n | tonumber] | first;
  def round1: . * 10 | round / 10;
  def runs: reduce .[] as $e ({done: [], cur: [], seen: []};
      if .seen | index($e.check) then .done += [.cur] | .cur = [$e] | .seen = [$e.check]
      else .cur += [$e] | .seen += [$e.check] end) | .done + [.cur] | map(select(length > 0));
  def failed($c): any(.[]; .check == $c and .status == "fail");
  def advice: if .warns > 0 and .failures == 0 and .ok == 0 then "end its period"
    elif .cacheRate == 0 then "cache it"
    elif .cacheRate < 0.5 then "narrow its inputs"
    else "move it to tier 3" end;
  (.usage.tickets | map(select(.ticket != null) | {key: (.ticket | tostring),
    value: (.input + .output + .cacheRead + .cacheWrite5m + .cacheWrite1h)}) | from_entries) as $tok
  | [$times[] | select((.ts | type) == "string" and .ts >= $since and .ts < $until and (.tier // 2) == 2)] as $t
  | [$t | group_by(.branch // "")[] | sort_by(.ts) | . as $es | runs as $r
      | ([$r | to_entries[] | select(all(.value[]; .status != "fail")) | .key] | first) as $pass
      | ($r | if $pass == null then . else .[:$pass] end | map(select(any(.[]; .status == "fail")))) as $bad
      | {branch: $es[0].branch, ticket: (($es[0].branch // "") | branch_ticket), runs: ($r | length), roundTrips: ($bad | length),
         seconds: ([$es[] | select(.status != "cached") | .seconds] | add // 0 | round1),
         failures: ([$bad[][] | select(.status == "fail") | .check] | group_by(.) | map({check: .[0], count: length})),
         badRuns: $bad}] as $b
  | ([$b[].badRuns[]]) as $trips
  | ([$t | group_by(.check)[] | . as $c | $c[0].check as $n
      | {check: $n, runs: length, seconds: ([$c[] | select(.status != "cached") | .seconds] | add // 0 | round1),
         ok: ([$c[] | select(.status == "ok")] | length), failures: ([$c[] | select(.status == "fail")] | length),
         warns: ([$c[] | select(.status == "warn")] | length),
         cacheRate: (([$c[] | select(.status == "cached")] | length) / length * 100 | round / 100),
         tripShare: (if ($trips | length) == 0 then 0 else ([$trips[] | select(failed($n))] | length) / ($trips | length) * 100 | round / 100 end)}]
    | sort_by(-.seconds, .check)) as $checks
  | [$briefs[] | select((.time | type) == "string" and .time >= $since and .time < $until)] as $bs
  | . + {iterationCost: {history: (($t | length) > 0),
      tickets: [$b[] | del(.badRuns) | . + {tokens: $tok[(.ticket | tostring)]}] | sort_by(.ticket // 0, .branch),
      checks: $checks,
      costliest: [$checks[:3][] | select(.seconds > 0) | . + {recommendation: advice}],
      agents: [$bs | group_by(.agent_type)[] | {agentType: .[0].agent_type, delegations: length,
        rework: ([group_by([.session, .goal])[] | length - 1] | add)}]}}'

# shellcheck disable=SC2016 # a jq program, not shell
RETRO_ITERATION_TEXT_JQ='.iterationCost as $i | def pct: "\(. * 100 | round)%";
  "", "Iteration",
  (if $i.history then
     ($i.tickets[] | "  \(if .ticket then "#\(.ticket)" else .branch end): \(.roundTrips) round trip\(if .roundTrips == 1 then "" else "s" end)"
       + (if .roundTrips > 0 then " (" + ([.failures[] | "\(.check) x\(.count)"] | join(", ")) + ")" else "" end)
       + ", \(.seconds)s in check"),
     "  Costliest checks",
     ($i.costliest[] | "    \(.check): \(.seconds)s over \(.runs) run\(if .runs == 1 then "" else "s" end), \(.failures) failure\(if .failures == 1 then "" else "s" end), \(.tripShare | pct) of the round trips, \(.warns) warn\(if .warns == 1 then "" else "s" end), cache \(.cacheRate | pct): \(.recommendation)")
   else "  no check history yet" end),
  (if ($i.agents | length) == 0 then "  no delegations logged"
   else "  Delegations", ($i.agents[] | "    \(.agentType): \(.delegations) call\(if .delegations == 1 then "" else "s" end), rework \(.rework) of \(.delegations)") end)'

# The objects of a JSON lines file ($1), or nothing; a damaged line is skipped.
jsonl_objects() {
  [ ! -f "$1" ] || jq -cR 'fromjson? | select(type == "object")' "$1" 2>/dev/null || true
}

# $1 the retro data, $2 the git common dir, $3 the start and $4 the end (or empty) of the period; prints the data with `iteration`.
retro_iteration() {
  local times briefs
  times=$(jsonl_objects "$2/senior-mode/check-times.jsonl" | jq -sc .)
  briefs=$(jsonl_objects "$2/senior-mode/briefs.jsonl" | jq -sc .)
  jq -c --argjson times "$times" --argjson briefs "$briefs" --arg since "$3" --arg until "${4:-9999}" "$RETRO_ITERATION_JQ" <<<"$1"
}

# senior-mode retro [--since <dur> | --iteration [<name>]] [--json]
# The facts of the weekly review (default period: 7 days; --iteration: the current iteration, or the one named, of the
# Project, #180). Reads only, apart from the Project status update with the health of the Project that each pass
# publishes (#177); the skill turns the facts into proposals.
retro() {
  local json=false since="" iteration="" iter="" root now_s now since_s since_iso until_iso="" data board history runs checks slug hygiene
  local head drift health title first last usage
  while [ $# -gt 0 ]; do
    case $1 in
      --json) json=true ;;
      --since)
        [ -n "${2:-}" ] || usage
        since=$2
        duration_seconds "$since" >/dev/null
        shift
        ;;
      --iteration)
        iteration=current
        if [ -n "${2:-}" ] && [[ $2 != --* ]]; then
          iteration=$2
          shift
        fi
        ;;
      *) usage ;;
    esac
    shift
  done
  [ -z "$iteration" ] || [ -z "$since" ] || die "retro takes --since or --iteration, not both"
  root=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || die "not inside a git repository"
  now_s=$(date +%s)
  now=$(iso_time "$now_s")
  if [ -n "$iteration" ]; then
    iter=$(iteration_find "$iteration") || die "no iteration $iteration on the board (is there an Iteration field? setup github creates it)"
    IFS=$'\t' read -r _ title first until_iso last <<<"$iter"
    since_iso=${first}T00:00:00Z until_iso=${until_iso}T00:00:00Z
    since_s=$(jq -nr --arg d "$since_iso" '$d | fromdateiso8601')
    head="Done in iteration $title ($first to $last)"
  else
    since=${since:-7d}
    since_s=$((now_s - $(duration_seconds "$since")))
    since_iso=$(iso_time "$since_s")
    head="Done in the last $since"
  fi
  slug=$(repo_slug)
  # --json keeps stdout pure.
  if [ "$json" = true ]; then security_alerts >&2; else security_alerts; fi
  board=$(board_data true) || exit 1
  history=$(jq -nc --arg q "$HISTORY_QUERY" --arg o "${slug%%/*}" --arg n "${slug#*/}" --arg s "$since_iso" \
    '{query: $q, variables: {owner: $o, name: $n, since: $s}}' | gh_retry api graphql --input -) ||
    die "cannot read the history from GitHub"
  [ -z "$(jq -r '.errors[0].message // empty' <<<"$history" 2>/dev/null)" ] ||
    die "GitHub refused the history query: $(jq -r '.errors[0].message' <<<"$history")"
  runs=$(retro_runs "$root" "$since_iso" "$until_iso")
  checks=$(retro_checks "$since_s" "${until_iso:+$(jq -nr --arg d "$until_iso" '$d | fromdateiso8601')}")
  hygiene=$(hygiene_report "$board" "$(ticket_trees "$(git rev-parse --show-toplevel)")" "$now" "$(local_branches)") || die "could not build the hygiene report"
  data=$(jq -c --argjson h "$history" --argjson runs "$runs" --argjson checks "$checks" --arg now "$now" --arg since "$since_iso" \
    --arg until "${until_iso:-9999}" --argjson iteration "$(jq -nc --arg t "${title:-}" 'if $t == "" then null else $t end')" \
    --arg repo "$slug" "$RETRO_JQ" <<<"$board") || die "could not build the retro"
  usage=$(retro_usage "$root" "$since_iso" "$until_iso") || die "could not read the token ledger"
  data=$(jq -c --argjson h "$hygiene" --argjson u "$usage" '. + {hygiene: $h, usage: $u}' <<<"$data")
  data=$(jq -c ". + {calibration: ($CALIBRATION_JQ)}" <<<"$data") || die "could not compare the sizes"
  # The cost of the iteration rules: round trips, time in check, costliest checks, rework (#486).
  data=$(retro_iteration "$data" "$root" "$since_iso" "$until_iso") || die "could not read the check times"
  # The journeys of the accepted specs and their flaky runs (#798).
  data=$(retro_journeys "$data" "$root" "$since_iso" "$until_iso") || die "could not read the journeys"
  # The cause label of each failed ticket and the improvement tickets of the causes that repeat (#364).
  data=$(retro_learn "$data" "$history" "$board" "$slug") || exit 1
  # The notes to merge or delete and the agents' drafts (#340): facts for the pull request the skill opens.
  data=$(retro_knowledge "$data") || exit 1
  # The proof of a long run (#423): the merge gate audit, the snapshots and the metrics of the period.
  data=$(retro_proof "$data" "$root" "$slug" "$since_s" "${until_iso:+$(jq -nr --arg d "$until_iso" '$d | fromdateiso8601')}" "$now_s") || exit 1
  if [ "$json" = true ]; then
    printf '%s\n' "$data"
  else
    jq -r --arg head "$head" "$HYGIENE_DEF$RETRO_TEXT_JQ" <<<"$data"
    jq -r "$RETRO_ITERATION_TEXT_JQ" <<<"$data"
    jq -r "$RETRO_JOURNEYS_TEXT_JQ" <<<"$data"
    jq -r "$RETRO_LEARN_TEXT_JQ" <<<"$data"
    jq -r "$RETRO_NOTES_TEXT_JQ" <<<"$data"
    jq -r "$RETRO_PROOF_TEXT_JQ" <<<"$data"
  fi
  # `status` proposes the next retro a week after this one (#319).
  mkdir -p "$root/senior-mode" && printf '%s\n' "$now_s" >"$root/senior-mode/retro-last"
  # The pass ends with the health of the Project (#177); a failure is said and does not undo the retro.
  drift=$(jq -c --argjson l "$(local_branches)" --argjson h "$hygiene" "$DRIFT_DEF"'drift(.; $l)
    | map(select(.kind != "stale" or (.number as $n | $h.orphans | all(.number != $n))))' <<<"$board") || drift='[]'
  if health=$(health_publish "$board" "$drift" "$now"); then
    if [ "$json" = true ]; then
      jq -r '"Project status update posted: \(.label): \(.rule)"' <<<"$health" >&2
    else
      jq -r '"\nProject status update posted: \(.label): \(.rule)"' <<<"$health"
    fi
  fi
}
