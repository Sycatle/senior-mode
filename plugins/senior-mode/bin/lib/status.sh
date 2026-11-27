# shellcheck shell=bash
# The drift of the board: tickets whose Status says something their issue does not (closed but not Done, open
# but Done, In progress or In review with no branch and no open pull request, Ready but labelled `needs-human`: `pick`
# never takes it, #603; Backlog with an open pull request: something turned the Status back, #633). $locals the local branch names.
# shellcheck disable=SC2016 # a jq program, not shell
DRIFT_DEF="$BRANCH_DEF"'def drift($d; $locals): $d.items as $items
  | ([$items[] | select((.open | not) and .status != "Done")
      | {number, title, kind: "closed", why: "closed but \(.status // "without a Status")"}]
    + [$items[] | select(.open and .status == "Done") | {number, title, kind: "open-done", why: "open but Done"}]
    + [$items[] | select(.open and (.status | IN("In progress", "In review"))) | . as $i
      | select([$d.hygiene.prs[].branch, $d.hygiene.branches[].name, $locals[]] | any(test(bre($i.number))) | not)
      | {number, title, kind: "stale", why: "\(.status) with no open pull request and no branch"}]
    + [$items[] | select(.open and .status == "Ready" and (.labels | index("needs-human")))
      | {number, title, kind: "needs-human-ready", why: "Ready but labelled needs-human"}]
    + [$items[] | select(.open and .status == "Backlog") | . as $i
      | select([$d.hygiene.prs[].branch] | any(test(bre($i.number))))
      | {number, title, kind: "reverted", why: "Backlog with an open pull request: a Project workflow may have reset the Status"}]);'

# The decisions (#308): everything that waits for the human, from board_data and $now. A ticket with `needs-human`
# (kind needs-human), a pull request with `needs-human` (pull-request), a ticket in framing (an open ticket with
# `needs-info`: the questions of the framing wait for an answer) and a pull request labelled `framing-draft` (framing). A
# ticket with `needs-decision` (#363, #621) is kind needs-decision, with the question and the recommended option of its last
# `<!-- senior-mode:decision -->` comment, when a collaborator wrote it; it is listed under that kind, not as needs-human, which it also carries.
# Each has its age (seconds since its last activity, GitHub's updatedAt; null when unknown) and the question to answer: the
# first line of the last comment when a collaborator wrote it (the reason of the alert, without its mention), else a
# default that does not repeat the title. Plain text, control characters stripped, 300 characters at most (a title can be an
# outsider's). `options` and `id` are there for the answers of #466 and empty until then; `recommended` is the recommended option of a needs-decision ticket. Sorted by Priority
# (a pull request has none), then the oldest first.
# shellcheck disable=SC2016 # a jq program, not shell
DECISIONS_DEF='def plain: gsub("[[:cntrl:]]"; " ") | gsub("^ +| +$"; "") | .[:300];
  def asked($default): (.last // null) as $c
    | (if $c != null and ((["OWNER", "MEMBER", "COLLABORATOR"] | index($c.assoc // "")) != null)
        then ([$c.body | gsub("<!--.*?-->"; ""; "s") | split("\n")[] | select(test("\\S"))][0] // "")
          | sub("^\\s*@[^ ]+ this needs a human \\([^)]*\\): "; "") | plain
        else "" end) as $q
    | if $q != "" then $q else $default end;
  def decision($kind; $default): . as $i | {number, kind: $kind, title: (.title | plain),
    age: (if .updated then (($now | fromdateiso8601) - (.updated | fromdateiso8601) | if . < 0 then 0 else . end) else null end),
    question: asked($default), options: [], recommended: null, id: null,
    priority: ($i.priority // null)};
  def marked($k): [(.decision.body // "") | gsub("\r"; "") | split("\n")[] | select(startswith("**\($k):** ")) | ltrimstr("**\($k):** ") | plain][0] // "";
  def waits_decision: marked("Question") as $q | marked("Recommended option") as $r
    | decision("needs-decision"; "Needs your decision")
    | .question = (if $q != "" then $q else .question end)
    | .recommended = (if $r == "" or ($r | test("^none given$"; "i")) then null else $r end);
  def decisions($d): ([$d.items[] | select(.open and (.archived | not))
      | if (.labels | index("needs-decision")) then waits_decision
        elif (.labels | index("needs-human")) then decision("needs-human"; "Needs your decision")
        elif (.labels | index("needs-info")) then decision("framing"; "Answer the open questions of the framing")
        else empty end]
    + [$d.prs[] | if (.labels | index("needs-human")) then decision("pull-request"; "Merge or close this pull request")
        elif (.labels | index("framing-draft")) then decision("framing"; "Approve or amend the framing")
        else empty end])
    | sort_by([([(.priority // "") | scan("^P([0-9]+)") | .[0] | tonumber] | first // 99), -(.age // 0), .number]);'

# The dashboard as JSON, from board_data; $1 is the start of the period, $2 now, $3 the repository, $locals the
# local branch names.
# shellcheck disable=SC2016 # a jq program, not shell
STATUS_JQ="$BRANCH_DEF"'. as $d | $d.items as $items | {
  repository: $repo, generatedAt: $now, since: $since,
  done: [$d.closed[] | select(.closedAt >= $since and .reason != "NOT_PLANNED") | {number, title, closedAt}] | sort_by(.closedAt) | reverse,
  mergedPullRequests: ([$d.merged[] | select(.mergedAt >= $since)] | length),
  inProgress: [$items[] | select(.open and .status == "In progress") | {number, title}],
  inReview: [$items[] | select(.open and .status == "In review") | . as $i
    | {number, title, pr: ([$d.prs[] | select(.branch | test(bre($i.number))) | .number][0])}],
  blocked: [$items[] | select(.open) | ([
      (if (.labels | index("blocked")) then "blocked" else empty end),
      (if (.labels | index("needs-info")) then "needs information" else empty end),
      (if (.blockers | length) > 0 and (.status | IN("Ready", "In progress", "In review"))
        then "waits for " + (.blockers | map("#\(.)") | join(", ")) else empty end)]) as $r
    | select($r | length > 0) | {number, title, reasons: $r}],
  waiting: (([$d.prs[] | select(.labels | index("needs-human")) | {kind: "pull request", number, title, why: "needs a human decision"}]
      + [$d.prs[] | select(.failing | length > 0) | {kind: "pull request", number, title, why: ("failing: " + (.failing | join(", ")))}]
      + [$items[] | select(.open and (.labels | index("needs-human"))) | {kind: "ticket", number, title, why: "needs a human decision"}])
    | group_by([.kind, .number]) | map(.[0] + {why: (map(.why) | join("; "))})),
  decisions: decisions($d),
  drift: drift($d; $locals),
  orphans: (([$items[] | .parent.number // empty] | unique) as $epics
    | [$items[] | select(.open and (.status | IN("Backlog", "Ready", "In progress", "In review")) and .orphan != null and (.number | IN($epics[]) | not))
      | {number, title, why: .orphan}]),
  hierarchyEnforced: ($d.hierarchy.enforce == true),
  wip: {limit: $wip, count: ([$items[] | select(.open and .status == "In progress")] | length)},
  audit: $audit,
  process: $process,
  customized: $customized,
  next: ($d | pick | .[:3] | map({number, title, priority, size, milestone})),
  release: {latest: $d.release, pr: ([$d.prs[] | select(.branch | startswith("release-please")) | {number, title}][0])}
}'

# The hierarchy of spec 325 §7 (#353): progress per goal, milestone and epic, from a milestone query. A ticket is an issue
# of a milestone with no sub-issue, an epic one with sub-issues (its own progress is that of its sub-issues). The goal of
# a milestone is its `Goal: Gn` description line; the goals are those of docs/vision.md ($goals, null without one: the goal
# level is then left out, and so is its drift). Drift: a milestone with no goal (or one the vision does not list), an epic
# with no spec or more than one in its body.
# shellcheck disable=SC2016 # a GraphQL query, not shell
HIERARCHY_QUERY='query($owner: String!, $name: String!) {
  repository(owner: $owner, name: $name) { milestones(first: 100, states: OPEN, orderBy: {field: DUE_DATE, direction: ASC}) { nodes {
    number title description issues(first: 100) { totalCount nodes { number title state body parent { number } subIssuesSummary { total completed } } } } } }
}'
# shellcheck disable=SC2016 # a jq program, not shell
HIERARCHY_DEF=$PART_OF_DEF'def hierarchy($goals):
    def total($k): map(.[$k]) | add // 0;
    def part: {closed: total("closed"), total: total("total")};
    ($goals // []) as $g
    | def listed($id): $id != null and ($g | any(.id == $id));
    [.data.repository.milestones.nodes[]? | . as $m | $m.issues.nodes as $is
      | ([($m.description // "") | split("\n")[] | capture("^\\s*Goal:\\s*(?<g>G[0-9]+)\\b")? | .g][0]) as $goal
      | [$is[] | select(.parent == null and .subIssuesSummary.total == 0) | (.body // "" | part_of) | select(. != null)] as $linked
      | def kids($e): [$is[] | select(.parent == null and .subIssuesSummary.total == 0 and (.body // "" | part_of) == $e.number)];
      [$is[] | select(.subIssuesSummary.total == 0 and (.number | IN($linked[]) | not))] as $tickets
      | {number: $m.number, title: $m.title, goal: $goal,
         closed: ($tickets | map(select(.state == "CLOSED")) | length), total: ($tickets | length),
         truncated: ($m.issues.totalCount > ($is | length)),
         epics: [$is[] | select(.subIssuesSummary.total > 0 or (.number | IN($linked[]))) | . as $e | kids($e) as $k
           | ([(.body // "") | scan("docs/specs/[A-Za-z0-9._-]+\\.md")] | unique) as $specs
           | {number, title, closed: (.subIssuesSummary.completed + ($k | map(select(.state == "CLOSED")) | length)),
              total: (.subIssuesSummary.total + ($k | length)), specs: $specs}]}] as $ms
    | [$ms[] | select(listed(.goal) | not)] as $loose
    | {goals: (if $goals == null then null else [$goals[] | . as $o | [$ms[] | select(.goal == $o.id)] as $mm
          | {id, title} + ($mm | part) + {milestones: ($mm | map(.title))}] end),
       noGoal: (if $goals == null then null else ({milestones: ($loose | map(.title))} + ($loose | part)) end),
       milestones: $ms,
       drift: ((if $goals == null then [] else [$loose[]
           | {kind: "milestone", number, title, why: (if .goal == null then "no Goal: line in its description" else "Goal: \(.goal) is not in docs/vision.md" end)}] end)
         + [$ms[].epics[] | select(.specs | length != 1)
           | {kind: "epic", number, title, why: (if (.specs | length) == 0 then "no spec in its body" else "\(.specs | length) specs in its body" end)}]),
       note: null};'
# shellcheck disable=SC2016 # a jq program, not shell
HIERARCHY_TEXT_DEF='def hierarchy_lines:
    def mline($why): "    \(.title): \(.closed)/\(.total) tickets" + $why + (if .truncated then " (first 100 issues only)" else "" end);
    def eline: "      #\(.number) \(.title): \(.closed)/\(.total) sub-issues"
      + (if (.specs | length) == 0 then ", no spec in its body" elif (.specs | length) > 1 then ", \(.specs | length) specs in its body" else "" end);
    . as $h
    | if $h.note then "Progress: not read (\($h.note))"
      elif ($h.milestones | length) == 0 then empty
      else
        "Progress\(if ($h.drift | length) > 0 then " (\($h.drift | length) drift)" else "" end)",
        (if $h.goals == null then
           ($h.milestones[] | "  \(.title): \(.closed)/\(.total) tickets" + (if .goal then " (\(.goal))" else "" end), (.epics[] | eline))
         else
           ($h.goals[] | "  \(.id) \(.title): \(.closed)/\(.total) tickets",
             (. as $g | $h.milestones[] | select(.goal == $g.id) | mline(""), (.epics[] | eline))),
           (if ($h.noGoal.milestones | length) > 0 then "  No goal: \($h.noGoal.closed)/\($h.noGoal.total) tickets",
             ($h.milestones[] | select(.title as $t | $h.noGoal.milestones | index($t))
               | mline(if .goal == null then ", no Goal: line" else ", Goal: \(.goal) is not in docs/vision.md" end), (.epics[] | eline)) else empty end)
         end)
      end;'

# The same, in plain words; $head says which period it covers.
# shellcheck disable=SC2016 # a jq program, not shell
STATUS_TEXT_JQ="$HIERARCHY_TEXT_DEF"'def sec($h; $ls): $h, (if ($ls | length) == 0 then "  nothing" else ($ls[] | "  " + .) end);
  def ticket: "#\(.number) \(.title)";
  def age_text: if . == null then "age unknown" elif . < 3600 then "\(. / 60 | floor)m" elif . < 86400 then "\(. / 3600 | floor)h" else "\(. / 86400 | floor)d" end;
  "senior-mode · \(.repository) · \(.generatedAt)", "",
  sec("\($head) (\(.done | length))"; [.done[] | ticket] + (if .mergedPullRequests > 0
    then ["\(.mergedPullRequests) pull request\(if .mergedPullRequests > 1 then "s" else "" end) merged"] else [] end)),
  sec("In progress (\(.inProgress | length)\(if .wip.count > .wip.limit then ", over the limit of \(.wip.limit)" else "" end))";
    [.inProgress[] | ticket + (if .worktree then " (worktree \(.worktree))" else "" end)]),
  sec("In review (\(.inReview | length))"; [.inReview[] | ticket + (if .pr then " (pull request #\(.pr))" else "" end)]),
  sec("Blocked or missing information (\(.blocked | length))"; [.blocked[] | ticket + ": " + (.reasons | join(", "))]),
  sec("Decisions (\(.decisions | length))"; [.decisions[] | "#\(.number) \(.title) · \(.kind) · \(.age | age_text): \(.question)\(if .recommended then " (recommended: \(.recommended))" else "" end)"]),
  (if ([.waiting[] | select(.why | test("failing: "))] | length) > 0 then sec("Failing checks (\([.waiting[] | select(.why | test("failing: "))] | length))";
    [.waiting[] | select(.why | test("failing: ")) | "\(.kind) #\(.number) \(.title): \(.why | sub("^needs a human decision; "; ""))"]) else empty end),
  (if (.drift | length) > 0 then sec("Board drift (\(.drift | length))"; [.drift[] | ticket + ": " + .why]) else empty end),
  (if (.hygiene | hygiene_lines | length) > 0 then sec("Hygiene (\(.hygiene | hygiene_lines | length))"; .hygiene | hygiene_lines) else empty end),
  (if (.orphans | length) > 0 then sec("Orphans (\(.orphans | length))\(if .hierarchyEnforced then ", refused by hierarchy.enforce" else ", hierarchy.enforce is off" end)";
    [.orphans[] | ticket + ": " + .why]) else empty end),
  (if ((.specDrift // []) | length) > 0 then sec("Spec drift (\(.specDrift | length))"; [.specDrift[]
    | "\(.spec): \(.commits | length) \(if (.commits | length) == 1 then "commit" else "commits" end) under its paths since it last changed, with no Spec-Unchanged",
      (.commits[:5][] | "  \(.sha) \(.subject)"),
      (if (.commits | length) > 5 then "  ... and \((.commits | length) - 5) more" else empty end)]) else empty end),
  (if .specDriftNote then "Spec drift: not checked (\(.specDriftNote))" else empty end),
  (.hierarchy // empty | hierarchy_lines),
  (if .audit then empty else "Dependency audit: off (audit: false)" end),
  (if .process.profile != "strict" then "Process profile: \(.process.profile)" else empty end),
  (.customized.line // empty),
  (.process.lifted[]? | "WARNING locked gate lifted: \(.rule) (profile \(.profile), \(.adr))"),
  (.process.problems[]? | "WARNING process refused: \(.)"),
  sec("Next Ready"; [.next[] | "#\(.number) \(.priority // "no priority") · \(.size // "?") · \(.title)"
    + (if .milestone then " (\(.milestone))" else "" end)]),
  "Release",
  (if .release.latest then "  Last release \(.release.latest.tag), \(.release.latest.date[:10])." else "  No release yet." end)
    + (if .release.pr then " Release pull request #\(.release.pr.number) is open." else " No release pull request open." end),
  "Maintenance: \(.maintenance.slotsUsed) of \(.maintenance.reservedSlots) reserved gardening slots used (of \(.maintenance.parallel)), \(.maintenance.open) open gardening tickets (at most \(.maintenance.maxOpen))",
  (if .serve.running then "Daemon: serve is running (pid \(.serve.pid))" else empty end),
  (if .retro.due then "Retro due: the last one was \(.retro.lastDays) days ago" else empty end)'

# The repairs of `status --fix`, one JSON line per drift entry: {number, title, fixed, line}. Only a
# closed ticket is set Done; what else drifted needs a human's judgement and is left, saying why.
# Fails when a repair failed.
status_fix() {
  local entry n title kind why rc=0
  while IFS= read -r entry; do
    n=$(jq -r .number <<<"$entry") title=$(jq -r .title <<<"$entry") kind=$(jq -r .kind <<<"$entry")
    why=$(jq -r .why <<<"$entry")
    case $kind in
      closed)
        if (item_set "$n" Status Done) >/dev/null; then
          jq -nc --argjson n "$n" --arg t "$title" '{number: $n, title: $t, fixed: true,
            line: "fixed: #\($n) \($t): closed, Status set to Done"}'
        else
          rc=1
          jq -nc --argjson n "$n" --arg t "$title" '{number: $n, title: $t, fixed: false,
            line: "not fixed: #\($n) \($t): could not set the Status Done"}'
        fi
        ;;
      open-done)
        jq -nc --argjson n "$n" --arg t "$title" --arg w "$why" '{number: $n, title: $t, fixed: false,
          line: "left: #\($n) \($t): \($w); a human decides whether it is finished (close it) or not (move it back)"}' ;;
      needs-human-ready)
        jq -nc --argjson n "$n" --arg t "$title" --arg w "$why" '{number: $n, title: $t, fixed: false,
          line: "left: #\($n) \($t): \($w); a human takes it, or moves it back out of Ready"}' ;;
      reverted)
        if (item_set "$n" Status "In review") >/dev/null; then
          jq -nc --argjson n "$n" --arg t "$title" '{number: $n, title: $t, fixed: true,
            line: "fixed: #\($n) \($t): a pull request is open, Status set to In review"}'
        else
          rc=1
          jq -nc --argjson n "$n" --arg t "$title" '{number: $n, title: $t, fixed: false,
            line: "not fixed: #\($n) \($t): could not set the Status In review"}'
        fi
        ;;
      *)
        jq -nc --argjson n "$n" --arg t "$title" --arg w "$why" '{number: $n, title: $t, fixed: false,
          line: "left: #\($n) \($t): \($w); a human decides whether to resume it or move it back to Ready"}' ;;
    esac
  done < <(jq -c '.drift[]' <<<"$1")
  return "$rc"
}
# The goals of docs/vision.md under $1 (the root) as [{id, title}], null when there is no file.
vision_goals() {
  local file=$1/docs/vision.md
  [ -f "$file" ] || { echo null; return 0; }
  md_section "$file" Goals | sed -nE 's/^[-*][[:space:]]+\**(G[0-9]+)\**[[:space:]]*[:.-]?[[:space:]]*(.*)$/\1\t\2/p' |
    jq -Rsc 'split("\n") | map(select(. != "") | split("\t") | {id: .[0], title: ((.[1] // "") | gsub("\\*\\*"; "") | .[:80])})'
}

# The hierarchy report ($1 the root): one more GitHub call. It never fails the report: an unreadable answer is a `note`.
hierarchy_report() {
  local slug answer
  slug=$(repo_slug)
  answer=$(jq -nc --arg q "$HIERARCHY_QUERY" --arg o "${slug%%/*}" --arg n "${slug#*/}" '{query: $q, variables: {owner: $o, name: $n}}' |
    gh_retry api graphql --input - 2>/dev/null) && jq -e '.data.repository.milestones' >/dev/null 2>&1 <<<"$answer" ||
    { echo '{"goals": null, "noGoal": null, "milestones": [], "drift": [], "note": "could not be read"}'; return 0; }
  jq -c --argjson g "$(vision_goals "$1")" "$HIERARCHY_DEF"' hierarchy($g)' <<<"$answer"
}

# What only this machine knows (#319): whether `serve` runs here, and when the last retro ran. $1 the git common dir,
# $2 now in seconds. The retro mark starts at the first status, so a new repository is not told a retro is due.
# Prints {serve: {running, pid}, retro: {lastDays, due}}.
local_facts() {
  local common=$1 now_s=$2 pid="" mark last
  pid=$(cat "$common/senior-mode/serve/serve.pid" 2>/dev/null) || pid=""
  if ! [[ $pid =~ ^[0-9]+$ ]] || ! kill -0 "$pid" 2>/dev/null || [[ $(ps -o args= -p "$pid" 2>/dev/null) != *senior-mode* ]]; then
    pid=""
  fi
  mark=$common/senior-mode/retro-last
  if ! last=$(cat "$mark" 2>/dev/null) || ! [[ $last =~ ^[0-9]+$ ]]; then
    mkdir -p "$common/senior-mode" && printf '%s\n' "$now_s" >"$mark" 2>/dev/null
    last=$now_s
  fi
  jq -nc --arg pid "$pid" --argjson days $(((now_s - last) / 86400)) \
    '{serve: {running: ($pid != ""), pid: (if $pid == "" then null else ($pid | tonumber) end)},
      retro: {lastDays: $days, due: ($days >= 7)}}'
}

# One status report. $1 json|text, $2 --since duration or "", $3 true to move the "last time" mark,
# $4 true to repair the drift (--fix), $5 true to publish the health of the Project (--publish).
status_once() {
  local json=$1 since=$2 save=$3 fix=${4:-false} publish=${5:-false} root cache now_s now since_iso head data out wip audit results fixed trees locals
  local lines="" rc=0 health="" drift specs parallel
  root=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repository"
  cache=$root/.claude/senior-mode/status-seen
  now_s=$(date +%s)
  now=$(iso_time "$now_s")
  if [ -n "$since" ]; then
    since_iso=$(iso_time $((now_s - $(duration_seconds "$since"))))
    head="Done in the last $since"
  elif [ -s "$cache" ]; then
    since_iso=$(sed -n 1p "$cache")
    head="Done since last time"
  else
    since_iso=$(iso_time $((now_s - 604800)))
    head="Done in the last 7d"
  fi
  data=$(board_data true) || return 1
  wip=$(config_get wip)
  [[ $wip =~ ^[1-9][0-9]*$ ]] || die "wip must be a positive whole number, not $wip"
  if audit_enabled; then audit=true; else audit=false; fi
  # The local branches count too: a ticket worked on and not pushed yet has a branch.
  locals=$(local_branches)
  out=$(jq -c --arg now "$now" --arg since "$since_iso" --arg repo "$(repo_slug)" --argjson wip "$wip" \
    --argjson audit "$audit" --argjson locals "$locals" --argjson process "$(process_summary)" --argjson customized "$(customization_summary)" "$PICK_DEF$DRIFT_DEF$DECISIONS_DEF$STATUS_JQ" <<<"$data") ||
    die "could not build the status"
  trees=$(ticket_trees "$root")
  out=$(jq -c --argjson t "$trees" '.inProgress |= map(. + {worktree: ($t[.number | tostring])})' <<<"$out")
  # A ticket the hygiene repair takes is not also drift that waits for a human.
  out=$(jq -c --argjson h "$(hygiene_report "$data" "$trees" "$now" "$locals")" '. + {hygiene: $h}
    | .drift |= map(select(.kind != "stale" or (.number as $n | $h.orphans | all(.number != $n))))' <<<"$out") || return 1
  # The spec drift reads git, and GitHub only for the pull requests of the commits it needs; it never fails the report.
  specs=$(spec_drift 2>/dev/null) || specs='{"drift": [], "note": "could not be read"}'
  out=$(jq -c --argjson s "$specs" '. + {specDrift: $s.drift, specDriftNote: $s.note}' <<<"$out") || return 1
  out=$(jq -c --argjson h "$(hierarchy_report "$root")" '. + {hierarchy: $h}' <<<"$out") || return 1
  # The maintenance budget (#351): the gardening slots in use and the open gardening tickets (the ones serve files and the others).
  parallel=$(config_get autonomy.parallel)
  out=$(jq -c --argjson m "$(jq -c --arg l "$(workflow_label "" gardening)" --argjson parallel "$parallel" \
    --argjson reserved "$(maintenance_reserved "$parallel")" --argjson max "$(config_get maintenance.maxOpen)" \
    '{reservedSlots: $reserved, parallel: $parallel, maxOpen: $max,
      slotsUsed: ([.items[] | select(.open and .status == "In progress" and (.labels | index($l)))] | length),
      open: ([.items[] | select(.open and (.labels | index($l)))] | length)}' <<<"$data")" '. + {maintenance: $m}' <<<"$out") || return 1
  out=$(jq -c --argjson l "$(local_facts "$(git rev-parse --path-format=absolute --git-common-dir)" "$now_s")" '. + $l' <<<"$out") || return 1
  # The report is out before --fix touches anything.
  [ "$json" = true ] || jq -r --arg head "$head" "$HYGIENE_DEF$STATUS_TEXT_JQ" <<<"$out"
  if [ "$fix" = true ]; then
    results=$(status_fix "$out") || rc=1
    fixed=$(jq -sc '[.[] | select(.fixed)]' <<<"$results")
    lines=$(jq -r '.line' <<<"$results")
    out=$(jq -c --argjson f "$fixed" '. + {fixed: ($f | map({number, title}))}' <<<"$out")
    results=$(status_hygiene_fix "$out") || rc=1
    fixed=$(jq -sc '[.[] | select(.fixed) | {kind, id}]' <<<"$results")
    lines=$(printf '%s\n%s' "$lines" "$(jq -r '.line' <<<"$results")" | sed '/^$/d')
    out=$(jq -c --argjson f "$fixed" '.hygiene.fixed = $f' <<<"$out")
  fi
  if [ "$publish" = true ]; then
    # What --fix repaired is not drift any more.
    drift=$(jq -c '(.fixed // []) as $f | .drift | map(select(.number as $n | $f | all(.number != $n)))' <<<"$out")
    if health=$(health_publish "$data" "$drift" "$now"); then
      out=$(jq -c --argjson h "$health" '. + {health: ($h | del(.body))}' <<<"$out")
    else
      rc=1
    fi
  fi
  if [ "$json" = true ]; then
    printf '%s\n' "$out"
  else
    [ -z "$lines" ] || printf '\n%s\n' "$lines"
    [ -z "$health" ] || jq -r '"\nProject status update posted: \(.label): \(.rule)"' <<<"$health"
  fi
  if [ "$save" = true ]; then
    # The directory ignores itself, so the mark never dirties the tree that `check` records.
    mkdir -p "$(dirname "$cache")"
    echo '*' >"$(dirname "$cache")/.gitignore"
    printf '%s\n' "$now" >"$cache"
  fi
  # The report is out; --fix also tidies the repository (#225). Its text goes to stderr under --json.
  if [ "$fix" = true ]; then
    if [ "$json" = true ]; then "$SELF" clean >&2 || echo "senior-mode: clean failed" >&2; else "$SELF" clean || echo "senior-mode: clean failed" >&2; fi
  fi
  return "$rc"
}

# senior-mode status [--json] [--since <dur>] [--watch [secs]] [--fix] [--publish]
# A plain run reports what is new since the previous plain run and moves that mark; --json, --since
# and --watch only read it. --fix repairs the board drift once, so it does not mix with --watch.
# --publish also posts the health of the Project (On track, At risk or Off track, #177) as a Project status
# update; nothing else posts it but `retro`. (`senior-mode publish`, another command, sets commit statuses.)
status() {
  local json=false since="" watch=false secs=30 fix=false publish=false
  while [ $# -gt 0 ]; do
    case $1 in
      --json) json=true ;;
      --fix) fix=true ;;
      --publish) publish=true ;;
      --since)
        [ -n "${2:-}" ] || usage
        since=$2
        duration_seconds "$since" >/dev/null
        shift
        ;;
      --watch)
        watch=true
        if [[ ${2:-} =~ ^[1-9][0-9]*$ ]]; then
          secs=$2
          shift
        fi
        ;;
      *) usage ;;
    esac
    shift
  done
  if [ "$watch" = true ]; then
    [ "$json" = false ] || die "status --watch cannot print JSON"
    [ "$fix" = false ] || die "status --watch cannot --fix: a repair runs once, on purpose"
    [ "$publish" = false ] || die "status --watch cannot --publish: an update is posted once, on purpose"
    while :; do
      if [ -t 1 ]; then printf '\033[H\033[2J'; else echo; fi
      status_once false "$since" false || echo "GitHub did not answer; trying again in ${secs}s"
      sleep "$secs"
    done
  fi
  if [ "$json" = false ] && [ -z "$since" ]; then
    status_once false "" true "$fix" "$publish" || exit 1
  else
    status_once "$json" "$since" false "$fix" "$publish" || exit 1
  fi
}
