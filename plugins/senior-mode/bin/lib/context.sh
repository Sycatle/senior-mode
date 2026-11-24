# shellcheck shell=bash
# The briefing of a session (SessionStart hook, spec 0001 §15, spec 325 §3), from stable to variable so the start
# is the same for every ticket: the router, the overrides, the vision, then what governs the ticket's Paths (ADRs,
# specs, knowledge notes), then the ticket with its spec and criteria last. Never fails.

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

# The Paths of the ticket $2 on the board (the text field Paths of its Project item), as a JSON array of globs;
# nothing when GitHub or the field is not there. $1 the repository root.
context_board_paths() {
  local project slug res
  project=$(jq -r '.project.id // empty' "$1/.claude/senior-mode.json" 2>/dev/null) || project=""
  slug=$(repo_slug 2>/dev/null) || return 0
  # shellcheck disable=SC2016 # a GraphQL query, not shell
  res=$(gh_bound api graphql -f owner="${slug%%/*}" -f name="${slug#*/}" -F n="$2" -f query='query($owner: String!, $name: String!, $n: Int!) {
    repository(owner: $owner, name: $name) { issue(number: $n) { projectItems(first: 10) { nodes { project { id }
      fieldValueByName(name: "Paths") { ... on ProjectV2ItemFieldTextValue { text } } } } } } }' 2>/dev/null) || return 0
  # shellcheck disable=SC2016 # a jq program, not shell
  jq -c --arg p "$project" '[.data.repository.issue.projectItems.nodes[]? | select($p == "" or .project.id == $p)
      | .fieldValueByName.text? // empty][0] // "" | gsub("[\\[\\]\"\u0027]"; "") | [split("[,\\s]+"; null)[] | select(length > 0)]' <<<"$res" 2>/dev/null || true
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

# What governs the Paths of a ticket, ranked (spec 325 §3). It reads the `file<TAB>key<TAB>value`
# rows of context_rows on its input and prints the sections (ADRs, then specs, then notes, each from the best ranked).
# The candidates: the accepted ADRs and specs whose `paths` overlap the ticket's Paths (ADR 0017 collision rule, the
# static part of a glob), the accepted ADRs of the `adrs` of the ticket's spec whatever their `paths`, and the
# notes whose `paths` overlap. Ranked ADRs and specs first, then notes; inside a class by the length of the literal
# prefix of the overlap (longest first), `kind: pitfall` first, the newest `verified`, then the file name.
# Arguments: tp (the ticket's Paths, array), spec (its spec file).
# shellcheck disable=SC2016 # a jq program, not shell
CONTEXT_PICK=$PATHS_DEF'
  def unq: gsub("^[\"\u0027]|[\"\u0027]$"; "");
  def arr: (fromjson? // []) | if type == "array" then map(select(type == "string")) else [] end;
  def plen($t; $g): [$t[] as $a | $g[] as $b | ($a | gstatic) as $sa | ($b | gstatic) as $sb
      | select(pclash($sa; $sb)) | ([$sa, $sb] | map(length) | max)] | if length == 0 then null else max end;
  def clip: .[:200];
  [inputs | split("\t") | select(length >= 3) | {f: .[0], k: .[1], v: (.[2:] | join("\t"))}]
  | group_by(.f) | map({key: .[0].f, value: (map({key: .k, value: .v}) | from_entries)}) | from_entries as $files
  | ($files[$spec] // {}) as $sp
  | (if ($tp | length) > 0 then $tp else ($sp.paths // "[]" | arr) end) as $tpaths
  | (($sp.adrs // "[]") | arr | map(tonumber? // empty)) as $linked
  | if ($tpaths | length) == 0 then "" else
    [$files | to_entries[] | .key as $f | .value as $v
      | (if ($f | startswith("docs/adr/")) then "adr" elif ($f | startswith("docs/specs/")) then "spec" else "note" end) as $type
      | select($f != $spec)
      | plen($tpaths; ($v.paths // "[]" | arr)) as $pl
      | ($v.verified // "" | unq) as $ver
      | (($f | capture("^docs/adr/(?<n>[0-9]+)-")? | .n | tonumber) // null) as $num
      | select(if $type == "note" then $pl != null and ($ver | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))
          else ($v.status // "" | unq) == "accepted" and ($pl != null or ($num != null and any($linked[]; . == $num))) end)
      | ($v.kind // "" | unq) as $kind
      | {file: $f, cls: (if $type == "note" then 1 else 0 end), type: $type, plen: ($pl // 0), pit: ($kind == "pitfall"), verified: $ver,
         line: (if $type == "note" then
             "- \($f) [\($kind)] verified \($ver)\(if ($v.heading // "") != "" then ": \($v.heading)" else "" end)"
           else "- \($f) (accepted)\(if ($v.title // "") != "" then ": \($v.title | unq)" else "" end)" end | clip)}]
    | sort_by([.cls, -.plen, (if .pit then 0 else 1 end), (.verified | explode | map(-.)), .file]) as $c
    | def heads: [{t: "adr", h: "ADRs that govern these Paths (accepted):"}, {t: "spec", h: "Specs that govern these Paths (accepted):"},
        {t: "note", h: "Knowledge notes on these Paths (the date says when one was last checked):"}];
      [heads[] | . as $s | [$c[] | select(.type == $s.t) | .line] | select(length > 0) | $s.h + "\n" + join("\n")]
      | if length == 0 then "" else "\n" + join("\n\n") end
    end'

# `senior-mode context`: the briefing, on the output.
context() {
  local root branch issue json spec status criteria head ticket="" tpaths="[]" block
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
  spec=""
  if [ -n "$issue" ]; then
    if ! json=$(gh issue view "$issue" --json number,title,state,body,projectItems 2>/dev/null); then
      ticket="Current ticket: #$issue, branch $branch; details not loaded (GitHub unreachable)."
    else
      ticket=$(jq -r --arg b "$branch" '"Current ticket: #\(.number) \(.title) (\(.state | ascii_downcase), Status: \(.projectItems[0].status.name // "not on the board")), branch \($b)"' <<<"$json")
      spec=$(jq -r .body <<<"$json" | grep -oE 'docs/specs/[A-Za-z0-9._-]+\.md' | head -1) || true
      if [ -n "$spec" ]; then
        status=$(sed -nE 's/^status: *//p' "$root/$spec" 2>/dev/null | head -1) || true
        ticket+=$'\n'"Spec: $spec (${status:-file not found})"
      fi
      criteria=$(jq -r .body <<<"$json" | awk '/^## / { on = /Acceptance criteria/; next } on && /^- /' |
        head -6 | cut -c1-200)
      [ -z "$criteria" ] || ticket+=$'\n'"Acceptance criteria:"$'\n'"$criteria"
      tpaths=$(context_board_paths "$root" "$issue") || tpaths=""
      [ -n "$tpaths" ] || tpaths="[]"
    fi
  fi
  block=""
  if [ -n "$ticket" ]; then
    block=$(context_rows "$root" | jq -Rnr --argjson tp "$tpaths" --arg spec "$spec" "$CONTEXT_PICK" 2>/dev/null) || block=""
  fi
  printf '%s\n' "$head"
  [ -z "$block" ] || printf '%s\n' "$block"
  [ -z "$ticket" ] || printf '\n%s\n' "$ticket"
}
