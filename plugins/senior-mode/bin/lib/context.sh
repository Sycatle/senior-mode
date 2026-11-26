# shellcheck shell=bash
# The briefing of a session (SessionStart hook, spec 0001 §15, spec 325 §3), from stable to variable so the start
# is the same for every ticket: the router, the overrides, the vision, then what governs the ticket's Paths (ADRs,
# specs, knowledge notes), then the history of those Paths (recurring findings, reverts, then the repo map of
# repomap.sh, then the merged commits), the related
# work (open tickets, framing decisions), then the ticket with its spec and criteria last. It fits `context.budget`
# tokens (bytes / 4): the router and the ticket are never dropped, the lowest ranked items go first. Without GitHub it
# is built from files, git and the ticket cache, and says so. Never fails.

# The router: what a session is told whatever the repository.
context_router() {
  cat <<'ROUTER'
senior-mode is active: framing, specs and ADRs, test-driven delivery, atomic Conventional Commits, GitHub Project board.
The user needs /senior-mode:frame, /senior-mode:go and /senior-mode:status; "go" or "enchaîne" runs /senior-mode:go. A plain request to change the product ("je veux", "on devrait", "I want") is enough: size it with triage and frame it, no command needed. Disciplines load by themselves; ask the scout agent for codebase facts.
A secret seen by accident in a tool output is never repeated in a reply, a file, a commit, an issue or a pull request: report it so a human rotates it.
ROUTER
  # Spec 0001 §10, "Sessions without a human": the one rule, stated where a run session starts.
  [ -z "${SENIOR_MODE_RUN:-}" ] || echo "Unattended run: nobody answers questions. Take the recommended option for reversible choices; never accept an L spec or an ADR, never touch a protected zone: label needs-human and stop with a report."
}

# What the board says of the ticket $2: {paths, parent}, the text field Paths of its Project item as a JSON array of
# globs and its parent epic ({number, title} or null). Nothing when the field is not there or the repository has no
# remote; fails when GitHub does not answer. $1 the repository root.
context_board() {
  local project slug res
  project=$(jq -r '.project.id // empty' "$1/.claude/senior-mode.json" 2>/dev/null) || project=""
  slug=$(repo_slug 2>/dev/null) || return 0
  # shellcheck disable=SC2016 # a GraphQL query, not shell
  res=$(gh_bound api graphql -f owner="${slug%%/*}" -f name="${slug#*/}" -F n="$2" -f query='query($owner: String!, $name: String!, $n: Int!) {
    repository(owner: $owner, name: $name) { issue(number: $n) { parent { number title } projectItems(first: 10) { nodes { project { id }
      fieldValueByName(name: "Paths") { ... on ProjectV2ItemFieldTextValue { text } } } } } } }' 2>/dev/null) || return 1
  # shellcheck disable=SC2016 # a jq program, not shell
  jq -c --arg p "$project" '([.data.repository.issue.projectItems.nodes[]? | select($p == "" or .project.id == $p)
      | .fieldValueByName.text? // empty][0] // "" | gsub("[\\[\\]\"\u0027]"; "") | [split("[,\\s]+"; null)[] | select(length > 0)]) as $paths
    | {paths: $paths, parent: (.data.repository.issue.parent // null | if . then {number, title} else null end)}' <<<"$res" 2>/dev/null || true
}

# The ticket $2 as the briefing reads it: the JSON of `gh issue view` plus its `paths` and `parent` (context_board),
# written to `senior-mode/ticket/<n>.json` of the git directory at each successful load. Exit status 0 when GitHub
# answered; 1 with the cached JSON when it did not; 2 when it did not and there is no cache. $1 the repository root.
context_load() {
  local json board dir
  dir=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || dir=""
  dir=$dir/senior-mode/ticket
  if json=$(gh_bound issue view "$2" --json number,title,state,body,projectItems 2>/dev/null) && board=$(context_board "$1" "$2") &&
    json=$(jq -c --argjson b "${board:-null}" '. + {paths: ($b.paths // []), parent: ($b.parent // null)}' <<<"$json" 2>/dev/null); then
    { mkdir -p "$dir" && printf '%s\n' "$json" >"$dir/$2.json.tmp" && mv -f "$dir/$2.json.tmp" "$dir/$2.json"; } 2>/dev/null || true
    printf '%s\n' "$json"
    return 0
  fi
  if [ -f "$dir/$2.json" ] && jq -c 'select(.number != null)' "$dir/$2.json" 2>/dev/null; then return 1; fi
  return 2
}

# The front matter of the specs, ADRs and notes under $1, as `file<TAB>key<TAB>value` rows (the keys the briefing
# reads), and for a note the first heading of its body as the key `heading`.
context_rows() {
  local files
  mapfile -t files < <(cd "$1" && find docs/specs docs/adr docs/knowledge -maxdepth 1 -type f -name '*.md' 2>/dev/null | LC_ALL=C sort)
  [ "${#files[@]}" -gt 0 ] || return 0
  (cd "$1" && awk '
    FNR == 1 { fm = ($0 == "---"); body = 0; head = 0; next }
    fm && $0 == "---" { fm = 0; body = 1; next }
    fm && match($0, /^(id|title|status|paths|adrs|kind|verified):[ \t]*/) {
      v = substr($0, RLENGTH + 1); sub(/\r$/, "", v)
      print FILENAME "\t" substr($0, 1, index($0, ":") - 1) "\t" v; next }
    body && !head && /^# / { head = 1; print FILENAME "\theading\t" substr($0, 3) }' "${files[@]}")
}

# The key decision of a pull request body: the first line under its `Decision` or `Decisions` heading, a list marker
# dropped; none when there is no such heading or another heading follows at once.
# shellcheck disable=SC2016 # a jq program, not shell
CONTEXT_DECISION='def decision: (. // "" | gsub("\r"; "") | split("\n")) as $l
  | ([range(0; $l | length) | select($l[.] | test("^#{1,6}[ \t]+Decisions?[ \t]*$"; "i"))][0]) as $i
  | if $i == null then "" else ([$l[$i + 1:][] | select(test("\\S"))][0] // "")
      | if test("^\\s*#") then "" else sub("^\\s*([-*]\\s+)?"; "") | sub("\\s+$"; "") end end;'

# What happened on the Paths $2 (a JSON array of globs) and what else is open or decided around them (spec 325 §3,
# inputs 4 and 5), as the JSON array of candidates {cls, type, line} that follows the notes in the ranking: class 2 the
# recurring review findings then the reverts, class 3 the merged commits, class 4 the open tickets that overlap and the
# framing decisions. $3 the ticket, $4 its epic (or nothing), $5 `live` when GitHub answered for the ticket (without it,
# or when it stops answering, the history comes from git alone: no decision of a pull request, no finding, no related
# ticket) and the status is 1. $1 the repository root. A finding is a marker `<!-- finding: <slug> -->` in a comment or
# a review of 2 or more merged pull requests whose files overlap the Paths, that no knowledge note mentions.
context_extras() {
  local root=$1 tp=$2 issue=$3 epic=$4 live=$5 base day subject n slug prs info board prlist dec file project
  local -a ps=() rows=() nums=() days=() subs=()
  local ok=0
  mapfile -t ps < <(jq -r "$PATHS_DEF"'.[] | gstatic | if . == "" then "." else . end' <<<"$tp")
  [ "${#ps[@]}" -gt 0 ] || return 0
  base=$(default_branch 2>/dev/null) || base=HEAD
  if [ "$live" = live ]; then
    ok=1
    if prs=$(gh_bound pr list --state merged --limit 50 --json number,body,files,comments,reviews 2>/dev/null); then
      # shellcheck disable=SC2016 # a jq program, not shell
      info=$(jq -c --argjson tp "$tp" "$PATHS_DEF$CONTEXT_DECISION"'
        def touches: [.files[]?.path] as $f | any($f[]; . as $p | any($tp[] | gstatic; . as $s | $s == "" or $p == $s or ($p | startswith($s + "/"))));
        {decisions: ([.[] | {key: (.number | tostring), value: (.body | decision)}] | from_entries),
         findings: ([.[] | select(touches) | .number as $n
            | [(.comments[]?.body), (.reviews[]?.body)] | map(. // "" | scan("<!-- finding: ([A-Za-z0-9._:-]+) -->") | .[0]) | unique[] | {slug: ., pr: $n}]
           | group_by(.slug) | map({slug: .[0].slug, prs: (map(.pr) | sort)}) | map(select(.prs | length >= 2))
           | sort_by([-(.prs | length), .slug]))}' <<<"$prs" 2>/dev/null) || info=""
    else
      info=""
    fi
    [ -n "$info" ] || { info='{"decisions":{},"findings":[]}'; ok=0; }
  else
    info='{"decisions":{},"findings":[]}'
  fi
  # Recurring findings: no note under docs/knowledge mentions the slug, by name or in its text.
  while IFS= read -r slug; do
    [ -n "$slug" ] || continue
    [ ! -e "$root/docs/knowledge/$slug.md" ] || continue
    ! grep -rqF -- "$slug" "$root/docs/knowledge" 2>/dev/null || continue
    rows+=("2	finding	- $slug (on pull requests $(jq -r --arg s "$slug" '.findings[] | select(.slug == $s) | .prs | map("#\(.)") | join(", ")' <<<"$info"))")
  done < <(jq -r '.findings[].slug' <<<"$info")
  while IFS=$'\t' read -r day subject; do
    [[ $subject =~ ^Revert\ \"(.*)\"$ ]] || continue
    rows+=("2	revert	- $day ${BASH_REMATCH[1]}")
  done < <(git -C "$root" log "$base" --since='90 days ago' -n 5 --format='%cs%x09%s' -- "${ps[@]}" 2>/dev/null || true)
  while IFS=$'\t' read -r day subject; do
    [[ $subject != 'Revert "'* ]] || continue
    [[ $subject =~ ^.*\(#([0-9]+)\) ]] || continue
    n=${BASH_REMATCH[1]}
    nums+=("$n") days+=("$day") subs+=("${subject% \(#$n\)}")
    [ "${#nums[@]}" -lt 5 ] || break
  done < <(git -C "$root" log "$base" -n 200 --format='%cs%x09%s' -- "${ps[@]}" 2>/dev/null || true)
  for n in "${!nums[@]}"; do
    dec=$(jq -r --arg n "${nums[n]}" '.decisions[$n] // empty' <<<"$info")
    if [ "$live" = live ] && [ "$ok" = 1 ] && ! jq -e --arg n "${nums[n]}" '.decisions | has($n)' <<<"$info" >/dev/null; then
      dec=$(gh_bound pr view "${nums[n]}" --json body 2>/dev/null | jq -r "$CONTEXT_DECISION"'.body | decision' 2>/dev/null) || dec=""
    fi
    rows+=("3	history	- #${nums[n]} ${days[n]} ${subs[n]}${dec:+ | decision: $dec}")
  done
  if [ "$ok" = 1 ]; then
    project=$(jq -r '.project.id // empty' "$root/.claude/senior-mode.json" 2>/dev/null) || project=""
    if [ -n "$project" ]; then
      # shellcheck disable=SC2016 # a jq program, not shell
      if board=$(board_data false 2>/dev/null) && prlist=$(jq -r --argjson tp "$tp" --argjson me "$issue" "$PATHS_DEF"'
          def plen($b): [$tp[] as $a | $b[] as $c | ($a | gstatic) as $sa | ($c | gstatic) as $sc
            | select(pclash($sa; $sc)) | ([$sa, $sc] | map(length) | max)] | max;
          [.items[] | select(.open and (.archived | not) and .number != $me) | . as $i | ($i | globs) as $g
            | select(($g | length) > 0 and overlap($tp; $g))
            | {n: .number, t: .title, s: (.status // ""), l: plen($g)}]
          | sort_by([-.l, .n])[:5][] | "4\trelated\t- #\(.n) \(.t)\(if .s != "" then " (\(.s))" else "" end)"' <<<"$board" 2>/dev/null); then
        while IFS= read -r file; do
          [ -z "$file" ] || rows+=("$file")
        done <<<"$prlist"
      else
        ok=0
      fi
    fi
  fi
  if [ -f "$root/docs/decisions.md" ]; then
    # The log is oldest first: the 3 newest by date (a stable sort keeps the file order of a day), newest first.
    while IFS= read -r file; do
      rows+=("4	decision	$file")
    done < <(grep -E "^- [0-9]{4}-[0-9]{2}-[0-9]{2} #(${issue}${epic:+|$epic}):" "$root/docs/decisions.md" | sort -s -t' ' -k2,2 | tail -n 3 | tac || true)
  fi
  printf '%s\n' "${rows[@]}" | jq -Rnc '[inputs | split("\t") | select(length >= 3) | {cls: (.[0] | tonumber), type: .[1], line: (.[2:] | join("\t") | .[:200])}]'
  [ "$ok" = 1 ] || [ "$live" != live ] || return 1
}

# The first lines of the `Project conventions` block (spec 409 §4) as briefing rows: the workflow the project follows,
# its architecture rules, then its own CLAUDE.md and lint configuration. Nothing for a project that recorded neither
# a `workflow` nor rules. $1 the repository root.
# shellcheck disable=SC2016 # a jq program, not shell
context_conventions() {
  local root=$1 cfg=$1/.claude/senior-mode.json lint="" f
  [ -f "$cfg" ] || { echo '[]'; return 0; }
  for f in .eslintrc .eslintrc.js .eslintrc.cjs .eslintrc.json eslint.config.js eslint.config.mjs eslint.config.ts biome.json biome.jsonc .prettierrc \
    ruff.toml .ruff.toml .golangci.yml .golangci.yaml rustfmt.toml .rubocop.yml .editorconfig; do
    [ ! -f "$root/$f" ] || lint+="${lint:+, }$f"
  done
  jq -c --arg claude "$([ -f "$root/CLAUDE.md" ] && echo yes)" --arg lint "$lint" '
    ((.workflow // {}) | [(if .integration then "branches start from \(.integration)" else empty end),
      (if .branch.pattern then "branch \(.branch.pattern)" else empty end), (if .commit.format then "commits \(.commit.format)" else empty end),
      (if .merge then "merge \(.merge)" else empty end)] | join(", ")) as $wf
    | ([.architecture.rules // [] | .[].id] | .[:8] | join(", ")) as $rules
    | if $wf == "" and $rules == "" then []
      else [(if $wf != "" then "- workflow: \($wf)" else empty end),
        (if $rules != "" then "- architecture rules, enforced by check: \($rules)" else empty end),
        (if $claude != "" then "- CLAUDE.md: the project'"'"'s own instructions" else empty end),
        (if $lint != "" then "- lint and format configuration: \($lint)" else empty end)]
        | map({cls: -1, type: "convention", line: .}) end' "$cfg" 2>/dev/null || echo '[]'
}

# What governs the Paths of a ticket, ranked and cut to a size (spec 325 §3). It reads the `file<TAB>key<TAB>value`
# rows of context_rows on its input and prints {omit, block} as JSON: `block` the sections (ADRs, then specs, then
# notes, each from the best ranked), `omit` the line that says how many items the size left out (empty when none).
# The candidates: the accepted ADRs and specs whose `paths` overlap the ticket's Paths (ADR 0017 collision rule, the
# static part of a glob), the accepted ADRs of the `adrs` of the ticket's spec whatever their `paths`, and the
# notes whose `paths` overlap. Ranked ADRs and specs first, then notes; inside a class by the length of the literal
# prefix of the overlap (longest first), `kind: pitfall` first, the newest `verified`, then the file name. Items are
# taken in that order until $limit bytes (the room the router and the ticket leave) is full.
# The candidates of context_extras (extra, already ranked) come after the notes, in their order, and go first when the
# size is short. Arguments: tp (the ticket's Paths, array), spec (its spec file), extra, now (epoch), cutoff (date a
# note is stale before), limit (bytes), budget (tokens, for the omission line), rmhead (the heading of the repo map).
# shellcheck disable=SC2016 # a jq program, not shell
CONTEXT_PICK=$PATHS_DEF'
  def unq: gsub("^[\"\u0027]|[\"\u0027]$"; "");
  def arr: (fromjson? // []) | if type == "array" then map(select(type == "string")) else [] end;
  def plen($t; $g): [$t[] as $a | $g[] as $b | ($a | gstatic) as $sa | ($b | gstatic) as $sb
      | select(pclash($sa; $sb)) | ([$sa, $sb] | map(length) | max)] | if length == 0 then null else max end;
  def ago($v): try (($now - (($v + "T00:00:00Z") | fromdateiso8601)) / 86400 | floor) catch null;
  def clip: .[:200];
  [inputs | split("\t") | select(length >= 3) | {f: .[0], k: .[1], v: (.[2:] | join("\t"))}]
  | group_by(.f) | map({key: .[0].f, value: (map({key: .k, value: .v}) | from_entries)}) | from_entries as $files
  | ($files[$spec] // {}) as $sp
  | (if ($tp | length) > 0 then $tp else ($sp.paths // "[]" | arr) end) as $tpaths
  | (($sp.adrs // "[]") | arr | map(tonumber? // empty)) as $linked
  | if ($tpaths | length) == 0 then {omit: "", block: ""} else
    [$files | to_entries[] | .key as $f | .value as $v
      | (if ($f | startswith("docs/adr/")) then "adr" elif ($f | startswith("docs/specs/")) then "spec" else "note" end) as $type
      | select($f != $spec)
      | plen($tpaths; ($v.paths // "[]" | arr)) as $pl
      | ($v.verified // "" | unq) as $ver
      | (($f | capture("^docs/adr/(?<n>[0-9]+)-")? | .n | tonumber) // null) as $num
      | select(if $type == "note" then $pl != null and ago($ver) != null
          else ($v.status // "" | unq) == "accepted" and ($pl != null or ($num != null and any($linked[]; . == $num))) end)
      | ($v.kind // "" | unq) as $kind
      | (if $type == "note" and $kind == "convention" then "convention" else $type end) as $type
      | {file: $f, cls: (if $type == "convention" then -1 elif $type == "note" then 1 else 0 end), type: $type, plen: ($pl // 0), pit: ($kind == "pitfall"), verified: $ver,
         line: (if $type == "note" or $type == "convention" then
             "- \($f) [\($kind)] verified \($ver) (\(ago($ver) | if . == 1 then "1 day ago" else "\(.) days ago" end))\(if $ver < $cutoff then ", stale" else "" end)\(if ($v.heading // "") != "" then ": \($v.heading)" else "" end)"
           else "- \($f) (accepted)\(if ($v.title // "") != "" then ": \($v.title | unq)" else "" end)" end | clip)}]
    | (($extra | map(select(.cls < 0))) + sort_by([.cls, -.plen, (if .pit then 0 else 1 end), (.verified | explode | map(-.)), .file])
        + ($extra | map(select(.cls >= 0)))) as $c
    | def heads: [{t: "convention", h: "Project conventions (they win over senior-mode defaults, never over security, review or tests):"},
        {t: "adr", h: "ADRs that govern these Paths (accepted):"}, {t: "spec", h: "Specs that govern these Paths (accepted):"},
        {t: "note", h: "Knowledge notes on these Paths (the date says how far to trust one):"},
        {t: "finding", h: "Recurring review findings on these Paths (no knowledge note covers them):"},
        {t: "revert", h: "Reverted in the last 90 days:"}, {t: "repomap", h: $rmhead}, {t: "history", h: "History of these Paths (merged, most recent first):"},
        {t: "related", h: "Open tickets on these Paths:"}, {t: "decision", h: "Framing decisions of this ticket or its epic (newest first):"}];
      def block($n): [heads[] | . as $s | [$c[:$n][] | select(.type == $s.t) | .line] | select(length > 0) | $s.h + "\n" + join("\n")]
        | if length == 0 then "" else "\n" + join("\n\n") end;
      def omit($n): ($c | length) - $n | if . == 0 then "" else "\(.) item\(if . == 1 then "" else "s" end) omitted to fit context.budget (\($budget) tokens); the scout agent has the rest." end;
      def cost($n): (block($n) | if . == "" then 0 else utf8bytelength + 1 end) + (omit($n) | if . == "" then 0 else utf8bytelength + 1 end);
      ([range($c | length; -1; -1) | select(cost(.) <= $limit)] | first // 0) as $n
      | {omit: omit($n), block: block($n)}
    end'

# The checkpoint of the open pull request of the branch $1 (#346), as the lines a resumed session reads before the ticket;
# nothing when there is no pull request, no block, or GitHub does not answer. Cut to 2500 bytes, the plan of the block last.
context_checkpoint() {
  local prs inner
  prs=$(gh_bound pr list --head "$1" --state open --json body 2>/dev/null) || return 0
  inner=$(checkpoint_inner "$(jq -r '.[0].body // ""' <<<"$prs" 2>/dev/null)") || return 0
  [ -n "$inner" ] || return 0
  printf 'Resumed from checkpoint (the draft pull request of this branch; go on from it instead of exploring again):\n%s\n' \
    "$(sed '/^$/d' <<<"$inner" | head -c 2500)"
}

# `senior-mode context`: the briefing, on the output.
context() {
  local root branch issue json spec status criteria head ticket="" tpaths="[]" budget months cutoff fixed res block omit resumed=""
  local rc rows epic epic_text extras="[]" offline=0 rmtokens rmrows
  head=$(context_router)
  root=$(git rev-parse --show-toplevel 2>/dev/null) || { printf '%s\n' "$head"; return 0; }
  if [ ! -f "$root/.claude/senior-mode.json" ]; then
    printf '%s\n' "$head" "This repository is not set up for senior-mode; /senior-mode:setup adopts it."
    return 0
  fi
  head=$(printf '%s\n' "$head"; overrides_context || true; vision_brief "$root" || true)
  branch=$(git symbolic-ref --short -q HEAD) || branch=""
  issue=""
  [ -z "$branch" ] || issue=$(workflow_branch_issue "$branch") || issue=""
  spec="" epic="" rc=0
  if [ -n "$issue" ]; then
    json=$(context_load "$root" "$issue") || rc=$?
    [ "$rc" -eq 0 ] || offline=1
    if [ "$rc" -eq 2 ]; then
      ticket="Current ticket: #$issue, branch $branch; details not loaded (GitHub unreachable)."
    else
      ticket=$(jq -r --arg b "$branch" '"Current ticket: #\(.number) \(.title) (\(.state | ascii_downcase), Status: \(.projectItems[0].status.name // "not on the board")), branch \($b)"' <<<"$json")
      spec=$(jq -r .body <<<"$json" | grep -oE 'docs/specs/[A-Za-z0-9._-]+\.md' | head -1) || true
      if [ -n "$spec" ]; then
        status=$(sed -nE 's/^status: *//p' "$root/$spec" 2>/dev/null | head -1) || true
        ticket+=$'\n'"Spec: $spec (${status:-file not found})"
      fi
      epic_text=$(jq -r '.parent | if . then "#\(.number) \(.title)" else empty end' <<<"$json")
      [ -z "$epic_text" ] || ticket+=$'\n'"Epic: $epic_text"
      epic=$(jq -r '.parent.number // empty' <<<"$json")
      # The headings and list markers that `ready` accepts (ready_missing, #611): any heading level, `Acceptance criteria`, `Acceptance`
      # or `Criteria`, a bullet or a numbered list.
      criteria=$(jq -r .body <<<"$json" | awk '/^#+/ { h = tolower($0); sub(/^#+[ \t]*/, "", h); sub(/[ \t:]+$/, "", h)
          on = (h ~ /^acceptance criteria/ || h == "acceptance" || h == "criteria"); next }
        on && /^([-*]|[0-9]+[.)])[ \t]+[^ \t]/' | head -6 | cut -c1-200)
      [ -z "$criteria" ] || ticket+=$'\n'"Acceptance criteria:"$'\n'"$criteria"
      tpaths=$(jq -c '.paths // []' <<<"$json")
    fi
  fi
  block="" omit=""
  if [ -n "$ticket" ]; then
    rows=$(context_rows "$root")
    if [ "$tpaths" = "[]" ] && [ -n "$spec" ]; then
      tpaths=$(awk -F'\t' -v f="$spec" '$1 == f && $2 == "paths" { print $3; exit }' <<<"$rows" |
        jq -Rc 'fromjson? // [] | if type == "array" then map(select(type == "string")) else [] end' 2>/dev/null) || tpaths="[]"
      [ -n "$tpaths" ] || tpaths="[]"
    fi
    if [ "$tpaths" != "[]" ] && [ -n "$issue" ]; then
      extras=$(context_extras "$root" "$tpaths" "$issue" "$epic" "$([ "$rc" -eq 0 ] && echo live || echo cache)") || offline=1
      [ -n "$extras" ] || extras="[]"
    fi
    [ "$rc" -ne 0 ] || resumed=$(context_checkpoint "$branch")
    [ "$offline" -eq 0 ] || ticket+=$'\n'"GitHub unreachable: related tickets and review findings omitted"
    if [ "$tpaths" != "[]" ]; then
      rmtokens=$(config_get context.repoMapTokens 2>/dev/null) || rmtokens=""
      [[ $rmtokens =~ ^[1-9][0-9]*$ ]] || rmtokens=400
      # After the findings and reverts (class 2), before the history (class 3): spec 325 §3.
      rmrows=$(repomap_lines "$root" "$tpaths" "$rmtokens" | jq -Rnc '[inputs | {cls: 2, type: "repomap", line: .}]' 2>/dev/null) || rmrows=""
      [ -z "$rmrows" ] || [ "$rmrows" = "[]" ] ||
        extras=$(jq -c --argjson r "$rmrows" '[.[] | select(.cls <= 2)] + $r + [.[] | select(.cls > 2)]' <<<"$extras" 2>/dev/null) || extras="[]"
    fi
    [ "$tpaths" = "[]" ] ||
      extras=$(jq -c --argjson c "$(context_conventions "$root")" '$c + .' <<<"$extras" 2>/dev/null) || extras="[]"
    budget=$(config_get context.budget 2>/dev/null) || budget=""
    [[ $budget =~ ^[1-9][0-9]*$ ]] || budget=2000
    months=$(config_get knowledge.staleMonths 2>/dev/null) || months=""
    [[ $months =~ ^[1-9][0-9]*$ ]] || months=6
    cutoff=$(date -u -d "$months months ago" +%F)
    fixed=$(printf '%s\n\n%s\n\n%s\n' "$head" "$resumed" "$ticket" | LC_ALL=C wc -c)
    res=$(jq -Rnc --argjson tp "$tpaths" --arg spec "$spec" --argjson extra "$extras" --argjson now "$(date -u +%s)" --arg cutoff "$cutoff" \
      --argjson limit "$((budget * 4 - fixed))" --argjson budget "$budget" --arg rmhead "$REPOMAP_HEAD" "$CONTEXT_PICK" <<<"$rows" 2>/dev/null) || res=""
    if [ -n "$res" ]; then
      block=$(jq -r .block <<<"$res")
      omit=$(jq -r .omit <<<"$res")
    fi
  fi
  printf '%s\n' "$head"
  [ -z "$block" ] || printf '%s\n' "$block"
  [ -z "$resumed" ] || printf '\n%s\n' "$resumed"
  [ -z "$ticket" ] || printf '\n%s\n' "$ticket"
  [ -z "$omit" ] || printf '%s\n' "$omit"
}
