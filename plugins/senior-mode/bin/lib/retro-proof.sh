# shellcheck shell=bash
# The proof metrics of a long run (#423, spec 327 section 11): the hourly snapshot `serve` appends to
# <serve dir>/snapshots.jsonl, and the "run proof" section of `retro`: the audit of every merge of the period, the new
# secret scanning alerts, the drift per day, the incidents no issue covers and the metrics of the week. Definitions only.

# The snapshot of this hour, once an hour (the time of the last is kept in <serve dir>/snapshot-at, set first: a snapshot
# that fails waits for the next hour). One JSON line: at (epoch), running sessions, free slots, Ready tickets that could
# run, the train ({id, phase, entries, evicted} from <serve dir>/train, null with none), the quota band (<serve dir>/band,
# null with none), the leases this worker holds on the tickets In progress, the state of senior-mode/ci on the base head,
# the drift count of the board, why serve holds its launches (null when it does not) and when this serve started. What
# cannot be read is null: a value is never made up. Runs in serve_loop, which owns running, SERVE_PARALLEL and the rest.
serve_snapshot() {
  local now board free runnable="null" drift="null" ci="null" sha held="null" train="null" band="null" leases="null" started
  now=$(serve_now)
  [ $((now - $(state_num "$SERVE_DIR/snapshot-at"))) -ge 3600 ] || return 0
  state_put "$SERVE_DIR/snapshot-at" "$now"
  free=$((SERVE_PARALLEL - ${#running[@]}))
  [ "$free" -ge 0 ] || free=0
  if board=$(board_data true); then
    runnable=$(queue_lines "$board" | awk -F'\t' -v r=" ${running[*]} " 'r !~ " " $1 " " { n++ } END { print n + 0 }')
    drift=$(jq -c --argjson l "$(local_branches)" "$DRIFT_DEF"'drift(.; $l) | length' <<<"$board") || drift=null
    leases=$(proof_leases_held "$board") || leases=null
  fi
  if sha=$(git rev-parse -q --verify "$RUN_BASE^{commit}"); then
    ci=$(serve_states "$sha" | jq -c '.["senior-mode/ci"] // null') || ci=null
  fi
  if [ -e "$SERVE_DIR/paused" ]; then
    held='"paused"'
  elif [ -s "$SERVE_DIR/held" ]; then
    held=$(state_json "$SERVE_DIR/held" | jq -c '.cause // "held"') || held=null
  fi
  [ ! -e "$SERVE_DIR/train" ] || train=$(state_json "$SERVE_DIR/train" |
    jq -c '{id, phase, entries: (.entries // [] | length), evicted: (.evicted // [] | length)}') || train=null
  [ ! -e "$SERVE_DIR/band" ] || band=$(state_get "$SERVE_DIR/band" '[A-Za-z0-9 ._:%-]+' | jq -Rc .) || band=null
  started=$(file_mtime "$SERVE_DIR/serve.pid") || started=null
  jq -nc --argjson at "$now" --argjson running "${#running[@]}" --argjson free "$free" --argjson runnable "$runnable" \
    --argjson train "$train" --argjson band "$band" --argjson leases "$leases" --argjson ci "$ci" --argjson drift "$drift" \
    --argjson held "$held" --argjson started "$started" \
    '{at: $at, running: $running, free: $free, runnable: $runnable, train: $train, band: $band, leases: $leases, mainCi: $ci,
      drift: $drift, held: $held, started: $started}' | state_append "$SERVE_DIR/snapshots.jsonl" || true
}

# The leases of the tickets In progress or In review that this worker holds (a lease that is not released and not expired),
# one read of the ref for each, so at most as many as the work in progress. Prints the count; fails when a ref cannot be
# read, the clock is off, or the lease module is not there.
proof_leases_held() {
  local n rc held=0
  declare -F lease_read >/dev/null || return 1
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    rc=0
    lease_read "ticket-$n" 2>/dev/null || rc=$?
    case $rc in
      0) if lease_held_by_me && ! lease_expired; then held=$((held + 1)); fi ;;
      1) ;;
      *) return 1 ;;
    esac
  done < <(jq -r '.items[] | select(.open and (.status | IN("In progress", "In review"))) | .number' <<<"$1")
  echo "$held"
}

# The snapshots of the period [$2, $3) (epochs; $3 empty for no end) from the file under the git directory $1: the lines that are
# not a snapshot are left out. Prints {found, count, meanParallel, starvationMinutes, mainRedMinutes, trains, ticketsPerTrain,
# evictions, restarts, drift: [{day, drift, snapshots}], holds: [{at, cause}], restartsAt: [epoch]}. Every snapshot stands
# for the hour it opens. found is false with no snapshot in the period, and then no value is given.
# shellcheck disable=SC2016 # a jq program, not shell
RETRO_PROOF_SNAPSHOTS_JQ='def round1: . * 10 | round / 10;
  def num: type == "number";
  [.[] | select(.at >= $since and .at < $until)] | sort_by(.at) as $s
  | if ($s | length) == 0 then {found: false, count: 0}
    else
      ([$s[] | select((.running | num))] ) as $r
      | ([$s[] | select(.train | type == "object")] | group_by(.train.id)
          | map({id: .[0].train.id, entries: (map(.train.entries // 0) | max), evicted: (map(.train.evicted // 0) | max)})) as $t
      | {found: true, count: ($s | length),
         meanParallel: (if ($r | length) == 0 then null else ($r | map(.running) | add) / ($r | length) | round1 end),
         starvationMinutes: ([$s[] | select((.free | num) and (.runnable | num) and .free > 0 and .runnable == 0)] | length * 60),
         mainRedMinutes: ([$s[] | select(.mainCi | IN("failure", "error"))] | length * 60),
         trains: ($t | length),
         ticketsPerTrain: (if ($t | length) == 0 then null else ($t | map(.entries) | add) / ($t | length) | round1 end),
         evictions: ($t | map(.evicted) | add // 0),
         drift: ([$s[] | select(.drift | num) | . + {day: (.at | strftime("%Y-%m-%d"))}] | group_by(.day)
           | map({day: .[0].day, drift: .[-1].drift, snapshots: length})),
         holds: ([range(0; $s | length) as $i | $s[$i] | select(.held != null and ($i == 0 or $s[$i - 1].held != .held)) | {at, cause: .held}]),
         restartsAt: ([$s[] | select(.started | num) | .started] | unique | .[1:]),
         trainList: $t}
    end'

retro_proof_snapshots() {
  local f=$1/senior-mode/serve/snapshots.jsonl
  { [ ! -f "$f" ] || jq -cR 'fromjson? | select(type == "object" and (.at | type) == "number")' "$f" 2>/dev/null || true; } |
    jq -sc --argjson since "$2" --argjson until "${3:-99999999999}" "$RETRO_PROOF_SNAPSHOTS_JQ"
}

# The merge gate audit: each pull request merged in [$2, $3) (ISO times) of the repository $1 with the statuses of its merged
# head, one JSON line each: {number, title, head, mergedBy, statuses: {<context>: {state, by, description}} or null when unread}.
retro_proof_merges() {
  local slug=$1 prs pr sha st
  prs=$(gh_retry pr list --repo "$slug" --state merged --search "merged:>=${2%%T*}" --limit 200 \
    --json number,title,headRefOid,mergedAt,mergedBy) || return 1
  while IFS= read -r pr; do
    [ -n "$pr" ] || continue
    sha=$(jq -r .headRefOid <<<"$pr")
    if st=$(gh_retry api "repos/$slug/commits/$sha/status?per_page=100"); then
      st=$(jq -c '[.statuses[]? | {key: .context, value: {state, by: (.creator.login // null), description: (.description // "")}}] | from_entries' <<<"$st") || st=null
    else
      st=null
    fi
    jq -c --argjson s "$st" '{number, title, head: .headRefOid[:7], mergedBy: (.mergedBy.login // null), statuses: $s}' <<<"$pr"
  done < <(jq -c --arg s "$2" --arg u "${3:-9999}" '.[] | select(.mergedAt >= $s and .mergedAt < $u)' <<<"$prs")
}

# The lease records of every lease ref of the repository $1, as one JSON array of {name, worker, reason, at, expires}, oldest
# first. A ref is walked back through its parents (200 commits at most). Fails when GitHub does not answer.
retro_proof_leases() {
  local slug=$1 refs ref sha name depth c recs=""
  refs=$(gh_retry api "repos/$slug/git/matching-refs/senior-mode/leases/") || return 1
  while IFS=$'\t' read -r ref sha; do
    [ -n "$ref" ] || continue
    name=${ref#refs/senior-mode/leases/}
    depth=0
    while [ -n "$sha" ] && [ "$depth" -lt 200 ]; do
      c=$(gh_retry api "repos/$slug/git/commits/$sha") || return 1
      recs+=$(jq -c --arg n "$name" --argjson d "$depth" '(.message | fromjson? // {}) as $m
        | {name: $n, depth: $d, worker: $m.worker, reason: $m.reason, at: $m.renewed, expires: $m.expires}' <<<"$c")$'\n'
      sha=$(jq -r '.parents[0].sha // empty' <<<"$c")
      depth=$((depth + 1))
    done
  done < <(jq -r '.[] | [.ref, .object.sha] | @tsv' <<<"$refs")
  jq -sc 'sort_by(.name, -.depth) | map(del(.depth))' <<<"$recs"
}

# The facts of the proof, from the facts of `retro` on stdin: $merges_f the merged pull requests with their statuses (null: not
# read), $alerts_f the secret scanning alerts (null), $leases_f the lease records (null), $issues_f the issues of the period (null),
# each slurped from a file,
# $snap the snapshots, $since and $until the period (epochs; $until 0 for none), $now. Prints the facts with `proof`.
# The gate of a pull request is open when one of the three statuses is not success on the merged head: that merge got through
# a ruleset (a bypass). GitHub gives the account that set `review`, not the kind of session: it is listed to be read.
# shellcheck disable=SC2016 # a jq program, not shell
RETRO_PROOF_JQ='$merges_f[0] as $merges | $alerts_f[0] as $alerts | $leases_f[0] as $leases | $issues_f[0] as $issues
  | def round1: . * 10 | round / 10;
  def gaps: . as $s | ["ci", "review", "security"] | map("senior-mode/" + .) | map(. as $c
    | ($s[$c].state // "missing") as $st | select($st != "success") | "\($c) \($st)");
  . as $d | ($until | if . == 0 then $now else . end) as $end | (($end - $since) / 86400) as $days
  | ([($merges // [])[] | . + {gaps: (if .statuses == null then ["statuses not readable"] else (.statuses | gaps) end)}
      | . + {bypass: (.gaps | length > 0), reviewBy: (.statuses["senior-mode/review"].by // null)}]) as $m
  | ([($leases // [])[] | select(.at >= $since and .at < $end)]) as $l
  | ([($leases // []) | group_by(.name)[] | select(.[0].name | startswith("ticket-")) | . as $h | range(1; length) as $i
      | $h[$i - 1] as $p | $h[$i] | select((.reason | IN("claim", "takeover")) and .at >= $since and .at < $end and .worker != $p.worker
          and $p.reason != "release" and .at < $p.expires) | {name, at, workers: [$p.worker, .worker]}]) as $dup
  | ([$l[] | select(.reason == "takeover")]) as $take
  | ([$snap.holds[]? | {kind: "hold", ref: null, at, text: "serve held its launches: \(.cause)"}]
     + [$snap.restartsAt[]? | {kind: "restart", ref: null, at: ., text: "serve restarted"}]
     + [$snap.trainList[]? | select(.evicted > 0) | {kind: "eviction", ref: null, at: null, text: "train \(.id) evicted \(.evicted)"}]
     + [$take[] | {kind: "takeover", ref: (.name | sub("^[a-z]+-"; "") | tonumber? // null), at, text: "lease \(.name) taken over from a dead worker"}]
     + [$d.humanPullRequests[]? | select(.why | index("needs-human label")) | {kind: "needs-human", ref: .number, at: null,
         text: "#\(.number) needs a human decision"}]) as $inc
  | def kw: {hold: "held|hold|pause|breaker", restart: "restart", eviction: "evict", takeover: "takeover|lease",
      "needs-human": "needs.human"}[.];
  def covered($issues): . as $i | any($issues[]; (.createdAt | fromdateiso8601) >= ($i.at // $since) and (.number != $i.ref)
      and ((.title + " " + (.body // "")) | ascii_downcase
        | if $i.ref != null then test("#\($i.ref)\\b") else test($i.kind | kw) end));
  $d + {proof: {
    period: {since: $since, until: (if $until == 0 then null else $until end), days: ($days | round1)},
    snapshots: $snap,
    merges: {read: ($merges != null), count: ($m | length), open: ($m | map(select(.bypass)) | length),
      pullRequests: ($m | map({number, title, head, mergedBy, reviewBy, gaps, bypass}))},
    secrets: {read: ($alerts != null),
      new: [($alerts // [])[] | select(.created_at >= ($since | todate) and .created_at < ($end | todate)) | {number, createdAt: .created_at, type, state}]},
    drift: ($snap.drift // []),
    incidents: {read: ($issues != null), count: ($inc | length),
      uncovered: (if $issues == null then [] else [$inc[] | select(covered($issues) | not)] end)},
    metrics: {
      throughputPerDay: (if $days > 0 then (($d.done | length) / $days | round1) else null end),
      meanParallel: ($snap.meanParallel // null), starvationMinutes: ($snap.starvationMinutes // null),
      trains: ($snap.trains // null), ticketsPerTrain: ($snap.ticketsPerTrain // null), evictions: ($snap.evictions // null),
      mainRedMinutes: ($snap.mainRedMinutes // null), restarts: (if $snap.found then ($snap.restartsAt | length) else null end),
      takeovers: (if $leases == null then null else ($take | length) end),
      duplicateWork: (if $leases == null then null else ($dup | length) end)},
    duplicates: $dup}}'

# The facts $1 of `retro` with `proof`. $2 the git directory, $3 the repository slug, $4 and $5 the period as epochs ($5 empty for
# none), $6 the time of the pass. What GitHub does not give is null in the facts and said in the report; nothing stops the retro.
retro_proof() {
  local data=$1 root=$2 slug=$3 since=$4 until=${5:-} now=$6 snap merges alerts leases issues si ui
  si=$(iso_time "$since")
  ui=""
  [ -z "$until" ] || ui=$(iso_time "$until")
  snap=$(retro_proof_snapshots "$root" "$since" "$until") || snap='{"found":false,"count":0}'
  if merges=$(retro_proof_merges "$slug" "$si" "$ui"); then merges=$(jq -sc . <<<"$merges"); else merges=null; fi
  if alerts=$(gh_retry api "repos/$slug/secret-scanning/alerts?per_page=100" --paginate \
    --jq '.[] | {number, created_at, state, type: .secret_type} | @json' 2>/dev/null); then
    alerts=$(jq -sc . <<<"$alerts")
  else
    alerts=null
  fi
  leases=$(retro_proof_leases "$slug") || leases=null
  issues=$(gh_retry issue list --repo "$slug" --state all --search "created:>=${si%%T*}" --limit 500 --json number,title,body,createdAt 2>/dev/null) || issues=null
  jq -c --slurpfile merges_f <(printf '%s' "$merges") --slurpfile alerts_f <(printf '%s' "$alerts") --slurpfile leases_f <(printf '%s' "$leases") \
    --slurpfile issues_f <(printf '%s' "$issues") --argjson snap "$snap" --argjson since "$since" --argjson until "${until:-0}" --argjson now "$now" "$RETRO_PROOF_JQ" <<<"$data"
}

# The proof in plain words, a jq program for the text report.
# shellcheck disable=SC2016 # a jq program, not shell
RETRO_PROOF_TEXT_JQ='.proof as $p | def v: if . == null then "not measured" else tostring end;
  "Run proof (\($p.period.days) days)",
  (if $p.snapshots.found then "  snapshots: \($p.snapshots.count), one an hour"
   else "  no snapshot in this period: serve writes one an hour to .git/senior-mode/serve/snapshots.jsonl, so the metrics that read them are not measured" end),
  (if $p.merges.read | not then "  merge gate: the merged pull requests could not be read"
   else "  merge gate: \($p.merges.count) merged pull request\(if $p.merges.count == 1 then "" else "s" end), \($p.merges.open) past the gate",
     ($p.merges.pullRequests[] | "    #\(.number) \(.head): review set by \(.reviewBy // "nobody"), merged by \(.mergedBy // "unknown")"
       + (if .bypass then ", GATE OPEN: \(.gaps | join("; "))" else ", ci, review and security success" end)) end),
  (if $p.secrets.read | not then "  secret scanning: alerts could not be read"
   else "  new secret scanning alerts: \($p.secrets.new | length)", ($p.secrets.new[] | "    alert #\(.number) (\(.type // "unknown type"), \(.state)) at \(.createdAt)") end),
  (if ($p.drift | length) == 0 then "  drift per day: not measured" else "  drift per day", ($p.drift[] | "    \(.day): \(.drift) (last of \(.snapshots) snapshot\(if .snapshots == 1 then "" else "s" end))") end),
  (if $p.incidents.read | not then "  incidents: the issues could not be read, so none was checked against an issue"
   else "  incidents without an issue: \($p.incidents.uncovered | length) of \($p.incidents.count)", ($p.incidents.uncovered[] | "    \(.kind): \(.text)") end),
  "  metrics",
  "    throughput: \($p.metrics.throughputPerDay | v) tickets a day",
  "    mean parallel: \($p.metrics.meanParallel | v)",
  "    starvation minutes (a free slot, no runnable ticket): \($p.metrics.starvationMinutes | v)",
  "    trains: \($p.metrics.trains | v), tickets per train: \($p.metrics.ticketsPerTrain | v), evictions: \($p.metrics.evictions | v)",
  "    main red minutes: \($p.metrics.mainRedMinutes | v)",
  "    takeovers: \($p.metrics.takeovers | v), duplicate work: \($p.metrics.duplicateWork | v), restarts: \($p.metrics.restarts | v)"'
