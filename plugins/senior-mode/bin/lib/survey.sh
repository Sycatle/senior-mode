# shellcheck shell=bash
# The architecture survey of `setup repo --adopt` on a legacy project (#419, spec 409 section 4). The CLI measures
# (`senior-mode survey`, JSON), the architect agent reads the facts and writes drafts into `.claude/survey/`, and the CLI
# checks the drafts against the limits and writes the accepted ones into the adoption pull request. Nothing binds before
# the owner merges it, and a rerun never rewrites a file: it adds the new findings.
#
# Drafts: map.md (the prose of docs/architecture.md), notes/<slug>.md and risks/<slug>.md (knowledge notes), adrs/<slug>.md
# (retroactive ADRs), rules.json (architecture.rules), protected.json (globs proposed for `protected`).

# Thresholds of the risk signals: starting values, constants until a real repository needs another (spec 409, open questions).
SURVEY_CHURN_TOUCHES=15
SURVEY_FIX_PERCENT=30
SURVEY_TODO_MAX=10
SURVEY_GRAPH_FILES=2000
SURVEY_SRC_RE='\.(ts|tsx|js|jsx|mjs|cjs|mts|cts|vue|svelte|py|go|rs|java|kt|rb|php|cs|swift|c|cc|cpp|h|hpp|scala)$'
SURVEY_TEST_RE='(\.(test|spec)\.[a-z]+$|(^|/)(tests?|__tests__|spec)/|_test\.(go|py|rs)$|(^|/)test_[^/]*\.py$)'

# The directory of a file at most two levels deep, `.` for a file at the root.
survey_zone() {
  local d
  d=$(dirname "$1")
  [ "$d" != . ] || { echo .; return; }
  awk -F/ -v d="$d" 'BEGIN { print (NF >= 2 ? $1 "/" $2 : d) }' <<<"$d"
}

# The import edges between zones, as `from<TAB>to<TAB>count` rows: the relative, aliased and module imports of
# import_targets (check.sh) that resolve to a tracked file, in at most SURVEY_GRAPH_FILES files.
survey_edges() { # root files
  local root=$1 files=$2 f lang line spec c v dest n=0 ARCH_ALIASES="" ARCH_BASEURL="" ARCH_GOMOD="" cfg cleaned
  local -A tracked=()
  while IFS= read -r f; do tracked[$f]=1; done <<<"$files"
  for cfg in tsconfig.json jsconfig.json; do
    [ -f "$root/$cfg" ] || continue
    cleaned=$(sed -E 's#^[[:space:]]*//.*$##' "$root/$cfg")
    ARCH_BASEURL=$(jq -r '.compilerOptions.baseUrl // empty' <<<"$cleaned" 2>/dev/null) || ARCH_BASEURL=""
    ARCH_ALIASES=$(jq -r '(.compilerOptions.paths // {}) | to_entries[] | [.key, (.value[0] // "")] | @tsv' <<<"$cleaned" 2>/dev/null) || ARCH_ALIASES=""
    break
  done
  [ ! -f "$root/go.mod" ] || ARCH_GOMOD=$(sed -n 's/^module[[:space:]]\{1,\}//p' "$root/go.mod" | head -n 1 | tr -d '\r"')
  while IFS= read -r f; do
    case $f in
      *.ts | *.tsx | *.js | *.jsx | *.mjs | *.cjs | *.mts | *.cts | *.vue | *.svelte) lang=js ;;
      *.py) lang=py ;;
      *.go) lang=go ;;
      *) continue ;;
    esac
    [ -f "$root/$f" ] || continue
    n=$((n + 1))
    [ "$n" -le "$SURVEY_GRAPH_FILES" ] || break
    while IFS=$'\t' read -r line spec; do
      [ -n "$spec" ] || continue
      while IFS= read -r c; do
        [ -n "$c" ] || continue
        dest=""
        while IFS= read -r v; do
          [ -z "${tracked[$v]:-}" ] || { dest=$v; break; }
        done < <(path_variants "$c")
        [ -z "$dest" ] || printf '%s\t%s\n' "$(survey_zone "$f")" "$(survey_zone "$dest")"
      done < <(import_targets "$f" "$spec" "$lang")
    done < <(import_specs "$root/$f" "$lang")
  done <<<"$files"
}

# The measures of the repository $1 as JSON: stack, commands, one row per zone (churn and fixes over 12 months, test
# adjacency, TODO density, imports) with the risk signals, and the coverage report.
survey_measure() { # root
  local root=$1 files src zones commits age cfg="$1/.claude/senior-mode.json" cov manifests edges churn todo
  files=$(git -C "$root" -c core.quotePath=false ls-files)
  src=$(grep -E "$SURVEY_SRC_RE" <<<"$files" || true)
  commits=$(git -C "$root" rev-list --no-merges --count HEAD 2>/dev/null || echo 0)
  age=$(git -C "$root" log --max-parents=0 --format=%ct HEAD 2>/dev/null | sort -n | head -n 1)
  age=$(( ($(date +%s) - ${age:-$(date +%s)}) / 86400 ))
  manifests=$(for m in package.json go.mod Cargo.toml pyproject.toml requirements.txt pom.xml build.gradle Gemfile composer.json; do
    ! git -C "$root" ls-files --error-unmatch "$m" >/dev/null 2>&1 || echo "$m"
  done | jq -Rnc '[inputs]')
  cov=$(grep -E '(^|/)(lcov\.info|cobertura[^/]*\.xml|coverage\.xml|clover\.xml)$' <<<"$files" | head -n 1 || true)
  [ -n "$cov" ] || cov=$(cd "$root" && find . -maxdepth 3 \( -name lcov.info -o -name 'cobertura*.xml' -o -name coverage.xml \) -not -path './node_modules/*' 2>/dev/null | head -n 1 | sed 's#^\./##' || true)
  edges=$(survey_edges "$root" "$src" | LC_ALL=C sort | uniq -c | awk '{ print $2 "\t" $3 "\t" $1 }')
  churn=$(git -C "$root" -c core.quotePath=false log --since='12 months ago' --no-merges --name-only --format='@%s' 2>/dev/null |
    awk 'function zone(p,  n, a, d) { n = split(p, a, "/"); if (n == 1) return "."; if (n == 2) return a[1]; return a[1] "/" a[2] }
      /^@/ { fix = (tolower(substr($0, 2)) ~ /^(fix|hotfix|bugfix)([(:!]|$)|(^| )(fix|fixes|fixed|bug)( |$)/); delete seen; next }
      NF { z = zone($0); if (!(z in seen)) { seen[z] = 1; t[z]++; f[z] += fix } }
      END { for (z in t) print z "\t" t[z] "\t" f[z] }')
  todo=$(git -C "$root" -c core.quotePath=false grep -I -c -E 'TODO|FIXME|HACK|XXX' -- . 2>/dev/null | awk -F: -v re="$SURVEY_SRC_RE" '$1 ~ re { print $1 "\t" $NF }' || true)
  zones=$(jq -Rn --argjson cm "$SURVEY_CHURN_TOUCHES" --argjson fp "$SURVEY_FIX_PERCENT" --argjson tm "$SURVEY_TODO_MAX" \
    --arg src "$SURVEY_SRC_RE" --arg test "$SURVEY_TEST_RE" \
    --rawfile files <(printf '%s\n' "$files") --rawfile churn <(printf '%s\n' "$churn") --rawfile todo <(printf '%s\n' "$todo") \
    --rawfile edges <(printf '%s\n' "$edges") '
    def zone: split("/") | if length == 1 then "." elif length == 2 then .[0] else .[0] + "/" + .[1] end;
    def rows($t): $t | split("\n") | map(select(length > 0) | split("\t"));
    (rows($files) | map(.[0])) as $all
    | ($all | map(select(test($src)))) as $code
    | (rows($churn) | map({key: .[0], value: {touches: (.[1] | tonumber), fixes: (.[2] | tonumber)}}) | from_entries) as $ch
    | (rows($todo) | map({z: (.[0] | zone), n: (.[1] | tonumber)}) | group_by(.z) | map({key: .[0].z, value: (map(.n) | add)}) | from_entries) as $td
    | (rows($edges) | map({f: .[0], t: .[1], n: (.[2] | tonumber)})) as $ed
    | ($all | map(select(test($src) or test($test))) | map(zone) | unique) as $zs
    | [$zs[] as $z
      | ($code | map(select(zone == $z))) as $zc
      | ($zc | map(select(test($test))) | length) as $tests
      | (($zc | length) - $tests) as $srcn
      | ($ch[$z] // {touches: 0, fixes: 0}) as $c
      | ($ed | map(select(.f == $z and .t != $z)) | map({key: .t, value: .n}) | from_entries) as $out
      | ($ed | map(select(.t == $z and .f != $z) | .n) | add // 0) as $in
      | {path: $z, files: $srcn, tests: $tests, touches: $c.touches, fixes: $c.fixes, todo: ($td[$z] // 0),
         imports: $out, importedBy: $in}
      | select(.files > 0 or .tests > 0)
      | .signals = ([
          (if .touches >= $cm and (.fixes * 100 / .touches) >= $fp then "high churn and fixes" else empty end),
          (if .files >= 3 and .tests == 0 then "no tests" else empty end),
          (if .files > 0 and .touches == 0 and .importedBy == 0 then "dormant: no change in 12 months, nothing imports it" else empty end),
          (if .todo >= $tm then "TODO density" else empty end)])] | sort_by(.path)') || zones='[]'
  jq -nc --arg name "$(basename "$root")" --arg date "$(date -u +%F)" --argjson commits "$commits" --argjson age "$age" \
    --argjson files "$(printf '%s\n' "$files" | grep -c . || true)" --argjson srcn "$(printf '%s\n' "$src" | grep -c . || true)" \
    --argjson manifests "$manifests" --arg cov "$cov" --argjson zones "${zones:-[]}" \
    --argjson cfg "$(jq -c '{preset, framework, commands, kind: .adopt.kind}' "$cfg" 2>/dev/null || echo '{}')" \
    --argjson langs "$(printf '%s\n' "$src" | sed -E 's/.*\.//' | grep -v '^$' | sort | uniq -c | awk '{ print $2 "\t" $1 }' | jq -Rnc '[inputs | split("\t") | {key: .[0], value: (.[1] | tonumber)}] | from_entries')" '
    {project: $name, date: $date, commits: $commits, ageDays: $age, files: $files, sourceFiles: $srcn, languages: $langs,
     manifests: $manifests, preset: $cfg.preset, framework: $cfg.framework, commands: ($cfg.commands // {}),
     coverageReport: (if $cov == "" then null else $cov end), zones: $zones}'
}

# `senior-mode survey`: the measures of the repository, as JSON, for the architect agent to interpret.
survey_cmd() {
  local root
  [ $# -eq 0 ] || usage
  root=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repository"
  survey_measure "$root"
}

# The zones that carry a signal, as the lines the dry run and the pull request show.
survey_measures_md() { # measures-json
  jq -r '"- \(.commits) commits over \(.ageDays) days, \(.sourceFiles) source files, coverage report: \(.coverageReport // "none")",
    (.zones[] | select(.signals | length > 0)
      | "- `\(.path)`: \(.files) files, \(.tests) tests, \(.touches) changes of which \(.fixes) fixes, \(.todo) TODO — \(.signals | join("; "))")' <<<"$1"
}

# The raw value of the front matter key $2 of the draft $1, quotes kept; nothing when absent.
survey_fm() { # file key
  knowledge_fm "$1" "$2" 2>/dev/null || true
}

# The body of a draft: what follows the front matter.
survey_body() { # file
  awk 'NR == 1 && $0 == "---" { fm = 1; next } fm && $0 == "---" { fm = 0; next } !fm' "$1" | sed '/./,$!d'
}

# A JSON list of strings from the raw value $1 of a front matter key; `[]` when it is not one.
survey_list() { # raw
  jq -c 'if type == "array" then map(select(type == "string" and length > 0)) else [] end' <<<"${1:-[]}" 2>/dev/null || echo '[]'
}

# The slug of a draft file name: lowercase words joined by dashes.
survey_slug() { # file
  basename "$1" .md | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9]\{1,\}/-/g; s/^-//; s/-$//'
}

# The ADR body $1 with its `## Why` section replaced by $2 (added at the end when it has none).
survey_set_why() { # body text
  awk -v why="$2" '
    /^##[[:space:]]+Why[[:space:]]*$/ { print; print ""; print why; print ""; skip = 1; seen = 1; next }
    skip && /^##[[:space:]]/ { skip = 0 }
    !skip { print }
    END { if (!seen) { print ""; print "## Why"; print ""; print why } }' <<<"$1"
}

# One knowledge note from the draft $1 into the tree $2 as docs/knowledge/$3.md, front matter set by the CLI (`verified`
# the survey day, `origin: "survey"`). Prints the checkbox line of the pull request, or why it was not written.
# $4 is the default kind, $5 true to write.
survey_note() { # draft tree slug kind apply
  local draft=$1 tree=$2 slug=$3 kind=$4 apply=$5 max paths raw k body n title note=docs/knowledge/$3.md
  max=$(config_get knowledge.maxLines)
  [[ $max =~ ^[1-9][0-9]*$ ]] || max=40
  raw=$(survey_fm "$draft" paths)
  paths=$(survey_list "$raw")
  k=$(survey_fm "$draft" kind | tr -d "\"' ")
  [[ $k =~ ^(pitfall|convention|howto|context)$ ]] || k=$kind
  body=$(survey_body "$draft")
  title=$(sed -n 's/^#[[:space:]]\{1,\}//p' <<<"$body" | head -n 1)
  [ "$paths" != '[]' ] || { echo "- not written: $note (the draft has no \`paths\`)"; return 1; }
  [ -n "$title" ] || { echo "- not written: $note (the draft has no heading)"; return 1; }
  n=$(printf '%s\n' "$body" | grep -c '')
  [ "$n" -le "$max" ] || { echo "- not written: $note (body of $n lines, over knowledge.maxLines $max)"; return 1; }
  if [ "$apply" = true ]; then
    mkdir -p "$tree/docs/knowledge"
    printf -- '---\npaths: %s\nverified: %s\norigin: "survey"\nkind: %s\n---\n\n%s\n' \
      "$(knowledge_list <<<"$paths")" "$(date -u +%F)" "$k" "$body" >"$tree/$note"
  fi
  echo "- [ ] \`$note\` — $k: $title"
}

# The notes of the drafts (notes/, then risks/) into the tree: at most survey.maxNotes together, the rest listed.
survey_notes() { # tree stage apply
  local tree=$1 stage=$2 apply=$3 max d f slug kind line written=0 rest="" skipped="" out="" title
  max=$(config_get survey.maxNotes)
  [[ $max =~ ^[1-9][0-9]*$ ]] || die "survey.maxNotes must be a positive whole number, not $max"
  for d in notes risks; do
    [ -d "$stage/$d" ] || continue
    kind=context
    [ "$d" != risks ] || kind=pitfall
    while IFS= read -r f; do
      slug=$(survey_slug "$f")
      [ "$d" != risks ] || [[ $slug == risk-* ]] || slug=risk-$slug
      [ -n "$slug" ] || continue
      if [ -e "$tree/docs/knowledge/$slug.md" ]; then
        skipped+="- \`docs/knowledge/$slug.md\`"$'\n'
        continue
      fi
      if [ "$written" -ge "$max" ]; then
        title=$(sed -n 's/^#[[:space:]]\{1,\}//p' "$f" | head -n 1)
        rest+="- \`docs/knowledge/$slug.md\`${title:+: $title}"$'\n'
        continue
      fi
      if line=$(survey_note "$f" "$tree" "$slug" "$kind" "$apply"); then written=$((written + 1)); fi
      out+="$line"$'\n'
    done < <(find "$stage/$d" -maxdepth 1 -type f -name '*.md' | LC_ALL=C sort)
  done
  [ -z "$out" ] || printf '### Notes (%s of at most %s)\n\n%s\n' "$written" "$max" "$out"
  [ -z "$rest" ] || printf 'Not written, over `survey.maxNotes` (%s): a later run proposes them.\n\n%s\n' "$max" "$rest"
  [ -z "$skipped" ] || printf 'Already there, kept as they are:\n\n%s\n' "$skipped"
}

# The retroactive ADRs of the drafts into the tree, numbered after the highest existing one, at most survey.maxAdrs.
survey_adrs() { # tree stage apply
  local tree=$1 stage=$2 apply=$3 max f slug conf evid body paths title next status why file written=0 out="" rest="" skipped=""
  [ -d "$stage/adrs" ] || return 0
  max=$(config_get survey.maxAdrs)
  [[ $max =~ ^[1-9][0-9]*$ ]] || die "survey.maxAdrs must be a positive whole number, not $max"
  next=$(find "$tree/docs/adr" -maxdepth 1 -type f -name '[0-9]*-*.md' -printf '%f\n' 2>/dev/null | sed -E 's/^([0-9]+)-.*/\1/' | sort -n | tail -n 1)
  next=$(( 10#${next:-0} + 1 ))
  while IFS= read -r f; do
    slug=$(survey_slug "$f")
    [ -n "$slug" ] || continue
    if compgen -G "$tree/docs/adr/[0-9]*-$slug.md" >/dev/null; then
      skipped+="- \`docs/adr/*-$slug.md\`"$'\n'
      continue
    fi
    title=$(survey_fm "$f" title | sed -E "s/^[\"']//; s/[\"']\$//")
    [ -n "$title" ] || title=$(survey_body "$f" | sed -n 's/^#[[:space:]]\{1,\}//p' | head -n 1)
    body=$(survey_body "$f" | sed '1{/^#[[:space:]]\{1,\}[^#]/d}' | sed '/./,$!d')
    if [ -z "$title" ] || ! grep -qE '^##[[:space:]]+Decision' <<<"$body"; then
      out+="- not written: \`docs/adr/*-$slug.md\` (the draft needs a title and a \`## Decision\` section)"$'\n'
      continue
    fi
    if [ "$written" -ge "$max" ]; then
      rest+="- \`docs/adr/*-$slug.md\`: $title"$'\n'
      continue
    fi
    conf=$(survey_fm "$f" confidence | tr -d "\"' ")
    paths=$(survey_list "$(survey_fm "$f" paths)")
    evid=$(survey_list "$(survey_fm "$f" evidence)")
    # high needs a stated reason with evidence; without it the decision is medium, and a reason with no evidence is never invented.
    [[ $conf =~ ^(high|medium|low)$ ]] || conf=low
    [ "$conf" != high ] || [ "$evid" != '[]' ] || conf=medium
    status=accepted
    [ "$conf" != low ] || status=proposed
    why=""
    [ "$conf" = high ] || { why="Not documented, owner to fill."; body=$(survey_set_why "$body" "$why"); }
    file=$(printf '%04d-%s.md' "$next" "$slug")
    if [ "$apply" = true ]; then
      mkdir -p "$tree/docs/adr"
      printf -- '---\nid: %04d\ntitle: %s\nstatus: %s\nretroactive: true\nconfidence: %s\npaths: %s\nevidence: %s\n---\n\n# %s\n\n%s\n' \
        "$next" "$(jq -nr --arg t "$title" '$t | @json')" "$status" "$conf" "$(knowledge_list <<<"$paths")" "$(jq -c . <<<"$evid")" "$title" "$body" >"$tree/docs/adr/$file"
    fi
    out+="- [ ] \`docs/adr/$file\` — confidence $conf, $status: $title"$'\n'
    next=$((next + 1))
    written=$((written + 1))
  done < <(find "$stage/adrs" -maxdepth 1 -type f -name '*.md' | LC_ALL=C sort)
  [ -z "$out" ] || printf '### Retroactive ADRs (%s of at most %s)\n\nA `low` ADR is `proposed` and binds no agent until you set `accepted`; a reason with no evidence is written "not documented".\n\n%s\n' "$written" "$max" "$out"
  [ -z "$rest" ] || printf 'Not written, over `survey.maxAdrs` (%s):\n\n%s\n' "$max" "$rest"
  [ -z "$skipped" ] || printf 'Already there, kept as they are:\n\n%s\n' "$skipped"
}

# The architecture rules of rules.json into the config of the tree: at most survey.maxRules new ones, each valid on its own,
# none whose id exists. Then the baseline of the violations that exist, with the code of `--knowledge`.
survey_rules() { # tree stage apply
  local tree=$1 stage=$2 apply=$3 max rules have new="[]" i n rule id errs written=0 out="" rest="" cfg=$1/.claude/senior-mode.json
  [ -f "$stage/rules.json" ] || return 0
  max=$(config_get survey.maxRules)
  [[ $max =~ ^[1-9][0-9]*$ ]] || die "survey.maxRules must be a positive whole number, not $max"
  rules=$(jq -c 'if type == "array" then . else [] end' "$stage/rules.json" 2>/dev/null) || rules='[]'
  have=$(jq -c '[.architecture.rules // [] | .[].id]' "$cfg" 2>/dev/null) || have='[]'
  n=$(jq 'length' <<<"$rules")
  for ((i = 0; i < n; i++)); do
    rule=$(jq -c ".[$i]" <<<"$rules")
    id=$(jq -r '.id // empty' <<<"$rule")
    if [ -n "$id" ] && jq -e --arg i "$id" 'index($i)' <<<"$have" >/dev/null; then
      out+="- already there: rule \`$id\`"$'\n'
      continue
    fi
    errs=$(architecture_rules_errors "[$rule]")
    if [ -n "$errs" ]; then
      out+="- not written: $(head -n 1 <<<"$errs")"$'\n'
      continue
    fi
    if [ "$written" -ge "$max" ]; then
      rest+="- rule \`$id\`: $(jq -r '.why // ""' <<<"$rule")"$'\n'
      continue
    fi
    new=$(jq -c --argjson r "$rule" '. + [$r]' <<<"$new")
    out+="- [ ] rule \`$id\`: $(jq -r '.why // "no reason given"' <<<"$rule")"$'\n'
    written=$((written + 1))
  done
  if [ "$apply" = true ] && [ "$new" != "[]" ]; then
    [ -f "$cfg" ] || { mkdir -p "$tree/.claude"; echo '{}' >"$cfg"; }
    jq --argjson n "$new" '.architecture.rules = ((.architecture.rules // []) + $n)' "$cfg" >"$cfg.tmp" && mv "$cfg.tmp" "$cfg"
  fi
  [ -z "$out" ] || printf '### Architecture rules (%s of at most %s)\n\n%s\n' "$written" "$max" "$out"
  [ -z "$rest" ] || printf 'Not written, over `survey.maxRules` (%s):\n\n%s\n' "$max" "$rest"
  if [ "$apply" = true ] && [ "$new" != "[]" ]; then
    printf 'Baseline: the violations that exist are frozen, so only new ones fail.\n\n- %s\n\n' "$(knowledge_baseline "$tree" true | sed 's/^wrote: /wrote /' | tr '\n' ' ')"
  fi
}

# The map of map.md as docs/architecture.md when the file is absent or still our template (setup just placed it); the
# block of `architecture --write` follows. A file the project edited is kept.
survey_map() { # tree stage apply
  local tree=$1 stage=$2 apply=$3 file=$1/docs/architecture.md t same=false
  [ -s "$stage/map.md" ] || return 0
  if [ -e "$file" ]; then
    for t in "$(cd "$(dirname "$SELF")/.." && pwd)"/templates/*/architecture.md; do
      ! cmp -s "$t" "$file" || same=true
    done
    if [ "$same" = false ]; then
      printf '### Architecture map\n\nAlready there, kept as it is: `docs/architecture.md` is the project'"'"'s own; the drafted map stays in `.claude/survey/map.md`.\n\n'
      return 0
    fi
  fi
  if [ "$apply" = true ]; then
    mkdir -p "$tree/docs"
    cp "$stage/map.md" "$file"
  fi
  printf '### Architecture map\n\n- [ ] `docs/architecture.md` — the prose of the map; the block of `senior-mode architecture --write` follows it\n\n'
}

# The globs proposed for `protected`: listed for the owner, never applied.
survey_protected() { # stage
  local globs
  [ -f "$1/protected.json" ] || return 0
  globs=$(jq -c 'if type == "array" then map(select(type == "string" and length > 0)) else [] end' "$1/protected.json" 2>/dev/null) || return 0
  [ "$globs" != '[]' ] || return 0
  printf '### Proposal: protected zones\n\nSecurity-sensitive paths the survey found. Not applied: add the ones you agree with to `protected` in `.claude/senior-mode.json`, then rerun `senior-mode setup github`.\n\n- [ ] `"protected": %s`\n\n' "$globs"
}

# The survey of the tree $1, from the drafts of the checkout $2: prints the report (the body of the adoption pull request
# and the dry run) and, when $3 is true, writes the files into $1.
survey_apply() { # tree root apply
  local tree=$1 root=$2 apply=$3 stage=$2/.claude/survey measures notes adrs rules map prot part
  measures=$(survey_measure "$tree")
  printf '## Survey\n\nMeasured on the default branch by `senior-mode survey`; nothing here binds before you merge this pull request. Edit or delete a file to correct it; the merge is the validation.\n\n### Measures\n\n%s\n\n' "$(survey_measures_md "$measures")"
  if [ ! -d "$stage" ]; then
    printf 'No drafts in `.claude/survey/`: the architect agent reads `senior-mode survey` and writes them, then `setup repo --adopt` runs again.\n'
    return 0
  fi
  map=$(survey_map "$tree" "$stage" "$apply")
  notes=$(survey_notes "$tree" "$stage" "$apply")
  adrs=$(survey_adrs "$tree" "$stage" "$apply")
  rules=$(survey_rules "$tree" "$stage" "$apply")
  prot=$(survey_protected "$stage")
  for part in "$map" "$notes" "$adrs" "$rules" "$prot"; do
    [ -z "$part" ] || printf '%s\n\n' "$part"
  done
  # The block follows the map only on the run that wrote the map: a file the project edited is never touched.
  if [ "$apply" = true ] && [ -s "$stage/map.md" ] && cmp -s "$stage/map.md" "$tree/docs/architecture.md"; then
    (cd "$tree" && architecture_cmd --write >/dev/null) || true
  fi
}
