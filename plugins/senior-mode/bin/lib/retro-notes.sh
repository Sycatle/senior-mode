# shellcheck shell=bash
# What `retro` finds to tidy in the knowledge (#340, spec 325 section 4): notes to merge or delete, and the drafts the
# agents keep in their project memory. The facts only: the skill turns them into the one pull request
# `docs(knowledge): retro <date>`, so nothing here writes to the repository.

# The notes of $1 (a work tree) as {file, paths, kind, origin, verified}, one JSON object per line. A key that is
# missing, or a `paths` that is not a list of strings, is left out of the object: `check` reports the note.
retro_notes_rows() {
  local f
  [ -d "$1/docs/knowledge" ] || return 0
  while IFS= read -r f; do
    awk -v f="docs/knowledge/$f" 'NR == 1 && $0 != "---" { exit } NR > 1 && $0 == "---" { exit }
      NR > 1 && match($0, /^(paths|kind|origin|verified):[ \t]*/) {
        v = substr($0, RLENGTH + 1); sub(/\r$/, "", v); print f "\t" substr($0, 1, index($0, ":") - 1) "\t" v }' "$1/docs/knowledge/$f"
    printf '%s\tfile\t\n' "docs/knowledge/$f"
  done < <(find "$1/docs/knowledge" -maxdepth 1 -type f -name '*.md' -printf '%f\n' | LC_ALL=C sort) |
    jq -Rnc '[inputs | split("\t")] | group_by(.[0])[] | . as $r | {file: $r[0][0]}
      + ([$r[] | select(.[1] != "file") | {key: .[1], value: (.[2] // "" | gsub("^[\"\u0027]|[\"\u0027]$"; ""))}] | from_entries
        | (if .paths then .paths |= (try fromjson catch null) else . end)
        | with_entries(select(.key != "paths" or (.value | type == "array" and length > 0 and all(type == "string")))))'
}

# The merges, the deletions and the drafts, as JSON. $1 the work tree. A merge is 2 or more notes with the same set of
# `paths` and the same `kind` (the origins combined: the issue numbers of all of them, else the first origin; the
# `verified` date the oldest, as the merged text is not checked again); a deletion is a note none of whose `paths`
# matches a tracked file (it is not merged, however many share the paths).
# shellcheck disable=SC2016 # a jq program, not shell
RETRO_NOTES_JQ='def refs: split(",") | map(gsub("^\\s+|\\s+$"; "") | select(test("^#[0-9]+$")));
  def origin: (map(.origin // "" | refs) | add // [] | unique_by(ltrimstr("#") | tonumber)) as $n
    | if ($n | length) > 0 then $n | join(", ") else (map(.origin // empty) | first // "retro") end;
  ($orphans | map(.file)) as $gone
  | [.[] | select(.paths and .kind and (.file | IN($gone[]) | not))] as $live
  | {notes: length,
     merges: [$live | group_by([(.paths | sort), .kind])[] | select(length >= 2)
       | {kind: .[0].kind, paths: (.[0].paths | sort), notes: map(.file), keep: .[0].file, origin: origin,
          verified: (map(.verified // empty) | sort | first // null)}],
     deletes: [.[] | select(.file | IN($gone[])) | {note: .file, paths, reason: "none of its paths matches a tracked file"}]}'

# The notes of the work tree $1 to merge or delete, as {notes, merges, deletes}.
retro_notes_plan() {
  local root=$1 rows tracked file globs orphans="[]" hit
  rows=$(retro_notes_rows "$root") || return 1
  tracked=$(git -C "$root" -c core.quotePath=false ls-files) || return 1
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    globs=$(jq -c --arg f "$file" 'select(.file == $f) | .paths // empty' <<<"$rows")
    [ -n "$globs" ] || continue
    hit=$(protected_match "$globs" <<<"$tracked" | head -n 1)
    [ -n "$hit" ] || orphans=$(jq -c --arg f "$file" '. + [{file: $f}]' <<<"$orphans")
  done < <(jq -r '.file' <<<"$rows")
  jq -sc --argjson orphans "$orphans" "$RETRO_NOTES_JQ" <<<"$rows"
}

# The drafts in the project memory of the agents: each file of `.claude/agent-memory/<agent>/` of the main checkout
# and of its linked work trees (an agent writes in the checkout its session runs in) except the `MEMORY.md` index of
# the folder, as {agent, file, index, at, bytes}, oldest first.
retro_drafts() {
  local tree
  while IFS= read -r tree; do
    [ -d "$tree/.claude/agent-memory" ] || continue
    find "$tree/.claude/agent-memory" -mindepth 2 -maxdepth 2 -type f ! -name MEMORY.md -printf '%h\t%p\t%T@\t%s\n'
  done < <(git worktree list --porcelain | sed -n 's/^worktree //p') |
    while IFS=$'\t' read -r dir f at bytes; do
      index=""
      [ ! -f "$dir/MEMORY.md" ] || index=$dir/MEMORY.md
      jq -nc --arg a "$(basename "$dir")" --arg f "$f" --arg i "$index" --argjson at "${at%.*}" --argjson b "$bytes" \
        '{agent: $a, file: $f, index: (if $i == "" then null else $i end), at: ($at | todate), bytes: $b}'
    done | jq -sc 'sort_by(.at, .file)'
}

# The facts $1 of `retro` with `knowledge`: {date, notes, merges, deletes, drafts}. What cannot be read is said on
# stderr and leaves the facts as they were.
retro_knowledge() {
  local root plan drafts
  root=$(git rev-parse --show-toplevel 2>/dev/null) && plan=$(retro_notes_plan "$root") && drafts=$(retro_drafts) || {
    echo "retro: could not read the knowledge notes and the agents' drafts" >&2
    printf '%s\n' "$1"
    return 0
  }
  jq -c --argjson p "$plan" --argjson d "$drafts" --arg date "$(date -u +%F)" \
    '. + {knowledge: ($p + {date: $date, drafts: $d})}' <<<"$1"
}

# The knowledge facts in plain words, a jq program for the text report.
# shellcheck disable=SC2016 # a jq program, not shell
RETRO_NOTES_TEXT_JQ='.knowledge as $k | select($k != null)
  | "Knowledge (\($k.notes) notes, \($k.drafts | length) agent drafts)",
    (if ($k.merges | length) + ($k.deletes | length) + ($k.drafts | length) == 0 then "  nothing to tidy" else empty end),
    ($k.merges[] | "  merge: \(.notes | join(", ")) (kind \(.kind), same paths \(.paths | join(" ")); origin \(.origin))"),
    ($k.deletes[] | "  delete: \(.note) (\(.reason))"),
    ($k.drafts[] | "  draft: \(.agent): \(.file) (\(.at))")'
