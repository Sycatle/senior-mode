# shellcheck shell=bash
# Where the result of `check` is kept for a commit, until `publish` sends it (ADR 0006).
check_record() {
  printf '%s/%s\n' "$(git rev-parse --git-path senior-mode/checks)" "$1"
}

# How many full logs of failed checks are kept; the oldest go first.
CHECK_LOGS_KEEP=20

# Keeps the output file $2 of the failed check $1 as a log of its own, under senior-mode/check-logs of the git
# directory (#294), removes the oldest logs past CHECK_LOGS_KEEP, and prints the path of the new one. Prints
# nothing when the log cannot be written: the tail shown is then all there is.
check_log_keep() {
  local dir slug log f i=0
  dir=$(git rev-parse --path-format=absolute --git-path senior-mode/check-logs) || return 0
  slug=$(slugify "$1")
  log=$dir/$(date -u +%Y%m%d-%H%M%S)-$$-${slug:-check}.log
  { mkdir -p "$dir" && cp "$2" "$log"; } 2>/dev/null || return 0
  while IFS= read -r f; do
    i=$((i + 1))
    [ "$i" -le "$CHECK_LOGS_KEEP" ] || rm -f "$dir/$f"
  done < <(ls -1t "$dir" 2>/dev/null)
  printf '%s\n' "$log"
}

# Whether `check` audits the dependencies (`audit`, on by default); anything but a boolean is an error.
audit_enabled() {
  local value
  value=$(config_get audit)
  [[ $value =~ ^(true|false)$ ]] || die "audit must be true or false, not $value"
  [ "$value" = true ]
}

# The paths a push changes, from the lines git gives a pre-push hook on stdin (<ref> <sha> <remote ref>
# <remote sha>): what the remote does not have yet. Prints nothing and fails when they cannot all be told
# (no ref, a deletion, a remote commit this clone does not have, a new branch with no base): the caller then
# runs everything.
pushed_paths() {
  local sha rsha from found=false
  while read -r _ sha _ rsha; do
    [[ $sha =~ ^0+$ ]] && return 1
    if [[ $rsha =~ ^0+$ ]]; then
      from=$(default_branch) && from=$(git merge-base "$sha" "$from") || return 1
    else
      git cat-file -e "$rsha^{commit}" 2>/dev/null || return 1
      from=$rsha
    fi
    git -c core.quotePath=false diff --name-only --no-renames "$from" "$sha" || return 1
    found=true
  done
  $found
}

# The drift between the accepted specs and the code (#169). For each docs/specs/*.md whose front matter says
# `status: accepted`: the commits (first parent only, so a merge counts once) that touched its `paths` since
# the spec file last changed and carry no `Spec-Unchanged: <reason>` line, neither in their message nor in the
# body of a pull request they belong to. The pull requests of a commit are the ones GitHub associates with it
# (`associatedPullRequests`), whatever the merge method and the subject; they are read in batched GraphQL calls
# (50 commits each, one alias per commit), only for the commits that need one. Prints
# {"drift": [{spec, id, title, commits: [{sha, pr, subject}]}], "note": null|"<why>"}, `pr` being the merged
# pull request of the commit, or null. When the pull requests cannot be read (no gh, offline) the drift is left
# out and the note says so: a guess would blame commits that are fine.
spec_drift() {
  local root spec fm title id globs g since sha msg subject slug owner name q resp i j prn ok note="" rows="" key
  local -a specs=() pathspec=() shas=() need=() chunk=() spec_order=()
  local -A spec_shas=() msg_ok=() sha_pr=() sha_subject=() pr_ok=() meta=()
  local unchanged='^[[:space:]]*Spec-Unchanged:[[:space:]]*[^[:space:]]'
  root=$(git rev-parse --show-toplevel) || return 1
  mapfile -t specs < <(git -C "$root" ls-files -- 'docs/specs/*.md')
  for spec in "${specs[@]}"; do
    fm=$(awk 'NR == 1 && $0 != "---" { exit } NR > 1 && $0 == "---" { exit } NR > 1 { print }' "$root/$spec" 2>/dev/null) || continue
    [ "$(sed -n 's/^status:[[:space:]]*//p' <<<"$fm" | tr -d "\"' \r")" = accepted ] || continue
    globs=$(sed -n 's/^paths:[[:space:]]*\[\(.*\)\][[:space:]]*$/\1/p' <<<"$fm")
    pathspec=()
    while IFS= read -r g; do
      g=$(tr -d "\"'\r" <<<"$g" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
      [ -z "$g" ] || pathspec+=(":(glob)$g")
    done < <(tr ',' '\n' <<<"$globs")
    [ "${#pathspec[@]}" -gt 0 ] || continue
    since=$(git -C "$root" log -1 --format=%H -- "$spec") && [ -n "$since" ] || continue
    mapfile -t shas < <(git -C "$root" log --first-parent --format=%H "$since..HEAD" -- "${pathspec[@]}" 2>/dev/null)
    [ "${#shas[@]}" -gt 0 ] || continue
    id=$(sed -n 's/^id:[[:space:]]*//p' <<<"$fm" | tr -d "\"'\r" | head -n 1)
    title=$(sed -n 's/^title:[[:space:]]*//p' <<<"$fm" | tr -d '\r' | head -n 1)
    meta[$spec]="$id"$'\t'"$title"
    spec_order+=("$spec")
    spec_shas[$spec]="${shas[*]}"
    for sha in "${shas[@]}"; do
      [ -z "${sha_subject[$sha]+x}" ] || continue
      msg=$(git -C "$root" log -1 --format=%B "$sha")
      subject=$(head -n 1 <<<"$msg")
      sha_subject[$sha]=$subject
      if grep -qiE "$unchanged" <<<"$msg"; then msg_ok[$sha]=1; fi
    done
  done
  for sha in "${!sha_subject[@]}"; do
    [ -n "${msg_ok[$sha]:-}" ] || need+=("$sha")
  done
  if [ "${#need[@]}" -gt 0 ]; then
    mapfile -t need < <(printf '%s\n' "${need[@]}" | sort)
    slug=$(repo_slug 2>/dev/null) || slug=""
    if [ -z "$slug" ] || ! command -v gh >/dev/null; then
      note="pull requests not read: no GitHub remote or no gh"
    else
      owner=${slug%%/*} name=${slug#*/}
      for ((i = 0; i < ${#need[@]}; i += 50)); do
        chunk=("${need[@]:i:50}")
        # shellcheck disable=SC2016 # GraphQL variables, not shell
        q='query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) {'
        for j in "${!chunk[@]}"; do
          q+=" c$j: object(oid: \"${chunk[j]}\") { ... on Commit { associatedPullRequests(first: 5) { nodes { number state body } } } }"
        done
        q+=' } }'
        if resp=$(jq -nc --arg q "$q" --arg o "$owner" --arg n "$name" '{query: $q, variables: {owner: $o, name: $n}}' |
          gh_retry api graphql --input - 2>/dev/null) && jq -e '.data.repository' <<<"$resp" >/dev/null 2>&1; then
          while IFS=$'\t' read -r j ok prn; do
            sha=${chunk[j]}
            sha_pr[$sha]=${prn:-}
            [ "$ok" != 1 ] || pr_ok[$sha]=1
          done < <(jq -r '.data.repository | to_entries[] | (.value.associatedPullRequests.nodes // []) as $n
            | [(.key[1:] | tonumber), ($n | any(.[]; (.body // "") | test("(^|\\n)[ \\t]*Spec-Unchanged:[ \\t]*[^ \\t\\n]"; "i")) | if . then 1 else 0 end),
              ([$n[] | select(.state == "MERGED")][0] // $n[0] // {} | .number // "")] | @tsv' <<<"$resp")
        else
          note="pull requests not read: GitHub did not answer"
          break
        fi
      done
    fi
  fi
  if [ -z "$note" ]; then
    for spec in "${spec_order[@]}"; do
      for sha in ${spec_shas[$spec]}; do
        [ -z "${msg_ok[$sha]:-}" ] && [ -z "${pr_ok[$sha]:-}" ] || continue
        key=${meta[$spec]}
        rows+=$(printf '%s\t%s\t%s\t%s\t%s' "$spec" "$key" "${sha:0:7}" "${sha_pr[$sha]:-}" "${sha_subject[$sha]}")$'\n'
      done
    done
  fi
  jq -Rsc --arg note "$note" 'split("\n") | map(select(length > 0) | split("\t")) | group_by(.[0])
    | {drift: map({spec: .[0][0], id: .[0][1], title: .[0][2],
        commits: map({sha: .[3], pr: (if .[4] == "" then null else (.[4] | tonumber) end), subject: (.[5:] | join("\t"))})}),
       note: (if $note == "" then null else $note end)}' <<<"$rows"
}

# The warning of `check` about the spec drift: a line per drifting spec, and a note when it could not be told.
# Never fails: the drift is advice, not a gate.
spec_drift_warn() {
  local out
  out=$(spec_drift 2>/dev/null) || return 0
  jq -r '(.drift[] | "warn  spec drift: \(.spec): \(.commits | length) \(if (.commits | length) == 1 then "commit" else "commits" end) under its paths since it last changed, with no Spec-Unchanged (senior-mode status lists them)"),
    (if .note then "note: spec drift not checked: \(.note)" else empty end)' <<<"$out" 2>/dev/null || true
}

# The lines of the section `## <heading>` of the Markdown file $1, up to the next `## ` heading.
md_section() {
  awk -v h="$2" '/^## / { on = ($0 ~ ("^## " h "[[:space:]]*$")); next } on' "$1"
}

# The check of docs/vision.md (#342, spec 325 §6.3): `## Goals` with entries G1, G2... (a list item that starts
# with the id, bold or not, each id once), `## Non-goals`, at most `vision.maxLines` lines. With no file there is
# nothing to check. Prints every problem, one per line, and fails when there is one.
vision_check() {
  local root file max lines ids dup problems=""
  root=$(git rev-parse --show-toplevel) || die "not inside a git repository"
  file=$root/docs/vision.md
  [ -f "$file" ] || { echo "skipped: no docs/vision.md"; return 0; }
  max=$(config_get vision.maxLines)
  [[ $max =~ ^[1-9][0-9]*$ ]] || die "vision.maxLines must be a positive whole number, not $max"
  lines=$(wc -l <"$file")
  [ "$lines" -le "$max" ] || problems+="docs/vision.md has $lines lines, more than vision.maxLines ($max)"$'\n'
  if ! grep -qE '^## Goals[[:space:]]*$' "$file"; then
    problems+="docs/vision.md has no '## Goals' section"$'\n'
  else
    ids=$(md_section "$file" Goals | sed -nE 's/^[-*][[:space:]]+\**(G[0-9]+)([^0-9].*)?$/\1/p')
    [ -n "$ids" ] || problems+="docs/vision.md: '## Goals' has no entry G1, G2... (a list item that starts with its id, such as '- G1: ...')"$'\n'
    dup=$(sort <<<"$ids" | uniq -d | head -n 1)
    [ -z "$dup" ] || problems+="docs/vision.md: goal $dup is listed twice"$'\n'
  fi
  grep -qE '^## Non-goals[[:space:]]*$' "$file" || problems+="docs/vision.md has no '## Non-goals' section"$'\n'
  [ -z "$problems" ] || { printf '%s' "$problems"; return 1; }
}

# What the briefing says of docs/vision.md (#342): its goal entries and its non-goals, each line cut at 200
# characters and at most 20 of each. Nothing when the file is not there.
vision_brief() {
  local file=$1/docs/vision.md goals nongoals
  [ -f "$file" ] || return 0
  goals=$(md_section "$file" Goals | grep -E '^[-*][[:space:]]+\**G[0-9]+' | cut -c1-200 | head -n 20) || true
  nongoals=$(md_section "$file" Non-goals | grep -vE '^[[:space:]]*$' | cut -c1-200 | head -n 20) || true
  echo
  echo "Vision (docs/vision.md), owned by a human:"
  [ -z "$goals" ] || printf 'Goals:\n%s\n' "$goals"
  [ -z "$nongoals" ] || printf 'Non-goals (an idea that contradicts one is quoted and asked, never framed):\n%s\n' "$nongoals"
}

# The check of the knowledge notes (#333, spec 325 §2): each docs/knowledge/<slug>.md has a kebab-case name, a
# front matter with `paths` (a non-empty list of globs), `verified` (YYYY-MM-DD, not in the future), `origin` (`#n`,
# `#n, #m`, `retro`, `survey` or a docs/spikes/ path) and `kind` (pitfall, convention, howto or context), and a body of at most
# `knowledge.maxLines` lines (default 40). With no docs/knowledge directory there is nothing to check. Prints
# every problem, one per line with the file and the key, and fails when there is one. Freshness (#345, spec 325 §5): a
# glob that matches no file of the tree and a `verified` older than `knowledge.staleMonths` (default 6) are
# `warning:` lines that never fail; a file the branch deletes or renames that a note's `paths` match, while the note
# is not in the diff, is a problem.
knowledge_check() {
  local root dir max f name file fm body n today key raw val problems="" warns="" slug_re='^[a-z0-9]+(-[a-z0-9]+)*\.md$'
  local months cutoff tree base mb deleted="" touched="" globs vdate g gone d
  root=$(git rev-parse --show-toplevel) || die "not inside a git repository"
  dir=$root/docs/knowledge
  [ -d "$dir" ] || { echo "skipped: no docs/knowledge"; return 0; }
  max=$(config_get knowledge.maxLines)
  [[ $max =~ ^[1-9][0-9]*$ ]] || die "knowledge.maxLines must be a positive whole number, not $max"
  months=$(config_get knowledge.staleMonths)
  [[ $months =~ ^[1-9][0-9]*$ ]] || die "knowledge.staleMonths must be a positive whole number, not $months"
  today=$(date -u +%Y-%m-%d)
  cutoff=$(date -u -d "$months months ago" +%Y-%m-%d)
  tree=$(git -C "$root" ls-files -co --exclude-standard)
  if base=$(default_branch) && mb=$(git -C "$root" merge-base "$base" HEAD 2>/dev/null); then
    deleted=$(git -C "$root" -c core.quotePath=false diff --name-only --no-renames --diff-filter=D "$mb")
    touched=$(changed_files "$root" deleted) || touched=""
  fi
  while IFS= read -r f; do
    name=docs/knowledge/$f
    file=$dir/$f
    globs="" vdate=""
    [[ $f =~ $slug_re ]] || problems+="$name: file name is not a kebab-case slug (lowercase words joined by dashes)"$'\n'
    fm=$(awk 'NR == 1 && $0 != "---" { exit } NR > 1 && $0 == "---" { exit } NR > 1 { print }' "$file")
    body=$(awk 'NR == 1 && $0 == "---" { fm = 1; next } fm && $0 == "---" { fm = 0; next } !fm' "$file" | sed '/./,$!d')
    n=0
    [ -z "$body" ] || n=$(printf '%s\n' "$body" | grep -c '')
    [ "$n" -le "$max" ] || problems+="$name: body has $n lines, over knowledge.maxLines ($max)"$'\n'
    for key in paths verified origin kind; do
      if ! grep -q "^$key:" <<<"$fm"; then
        problems+="$name: missing key $key"$'\n'
        continue
      fi
      raw=$(sed -n "s/^$key:[[:space:]]*//p" <<<"$fm" | head -n 1 | tr -d '\r')
      val=$(tr -d "\"'" <<<"$raw")
      case $key in
        paths)
          if ! jq -e 'type == "array" and all(.[]; type == "string")' <<<"$raw" >/dev/null 2>&1; then
            problems+="$name: paths must be a list of globs, like [\"src/billing/**\"], not $raw"$'\n'
          elif [ "$(jq 'length' <<<"$raw")" -eq 0 ]; then
            problems+="$name: paths is empty, a note is about some files"$'\n'
          else
            globs=$raw
          fi
          ;;
        verified)
          if ! [[ $val =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || [ "$(date -u -d "$val" +%Y-%m-%d 2>/dev/null)" != "$val" ]; then
            problems+="$name: verified must be a date, YYYY-MM-DD, not $raw"$'\n'
          elif [[ $val > $today ]]; then
            problems+="$name: verified $val is in the future"$'\n'
          else
            vdate=$val
          fi
          ;;
        origin)
          [[ $val =~ ^(#[0-9]+(,[[:space:]]*#[0-9]+)*|retro|survey|docs/spikes/[^[:space:]]+)$ ]] ||
            problems+="$name: origin must be #<n> (or several, #<n>, #<m>), retro, survey or a docs/spikes/ path, not $raw"$'\n'
          ;;
        kind)
          [[ $val =~ ^(pitfall|convention|howto|context)$ ]] ||
            problems+="$name: kind must be pitfall, convention, howto or context, not $raw"$'\n'
          ;;
      esac
    done
    if [ -n "$vdate" ] && [[ $vdate < $cutoff ]]; then
      warns+="warning: $name: verified $vdate, more than $months months ago (knowledge.staleMonths): re-read it against its paths"$'\n'
    fi
    [ -n "$globs" ] || continue
    while IFS= read -r g; do
      [ -n "$(protected_match "$(jq -nc --arg g "$g" '[$g]')" <<<"$tree")" ] ||
        warns+="warning: $name: paths glob $g matches no file"$'\n'
    done < <(jq -r '.[]' <<<"$globs")
    [ -n "$deleted" ] || continue
    gone=$(protected_match "$globs" <<<"$deleted")
    if [ -n "$gone" ] && ! grep -qxF "$name" <<<"$touched"; then
      while IFS= read -r d; do
        problems+="$name: $d is deleted or renamed by this branch but matches its paths, and the note is not updated"$'\n'
      done <<<"$gone"
    fi
  done < <(find "$dir" -maxdepth 1 -type f -name '*.md' -printf '%f\n' | LC_ALL=C sort)
  printf '%s' "$warns"
  [ -z "$problems" ] || { printf '%s' "$problems"; return 1; }
}

# The path $1 without its `.` and `..` segments; a `..` past the root is dropped.
path_norm() {
  local seg out=() parts
  IFS=/ read -ra parts <<<"$1"
  for seg in "${parts[@]}"; do
    case $seg in
      '' | .) ;;
      ..) [ "${#out[@]}" -eq 0 ] || out=("${out[@]:0:${#out[@]}-1}") ;;
      *) out+=("$seg") ;;
    esac
  done
  (IFS=/ && printf '%s\n' "${out[*]}")
}

# The imports of the file $1 in the language $2 (js, py or go), as `line<TAB>specifier` rows. A Python
# specifier is dotted, with its leading dots when relative, and `from a import b` gives `a` and `a.b`.
import_specs() {
  local q="'" re
  case $2 in
    js)
      re="(from[[:space:]]*|import[[:space:]]*\\(?[[:space:]]*|require[[:space:]]*\\([[:space:]]*)[\"$q][^\"$q]+[\"$q]"
      grep -noE "$re" "$1" | sed -E "s/^([0-9]+):.*[\"$q]([^\"$q]+)[\"$q]\$/\\1\\t\\2/" || true
      ;;
    py)
      awk '
        function emit(spec) { if (spec != "") print NR "\t" spec }
        function names(list, mod,    a, n, i, nm) {
          sub(/#.*$/, "", list); gsub(/[()]/, "", list)
          n = split(list, a, ",")
          for (i = 1; i <= n; i++) {
            nm = a[i]; sub(/[[:space:]]+as[[:space:]].*$/, "", nm); gsub(/^[[:space:]]+|[[:space:]]+$/, "", nm)
            if (mod == "") emit(nm)
            else if (nm ~ /^[A-Za-z_][A-Za-z0-9_]*$/) emit(mod (mod ~ /\.$/ ? "" : ".") nm)
          }
        }
        /^[[:space:]]*from[[:space:]]+[.A-Za-z0-9_]+[[:space:]]+import[[:space:]]/ {
          line = $0; sub(/^[[:space:]]*from[[:space:]]+/, "", line)
          mod = line; sub(/[[:space:]].*$/, "", mod); emit(mod)
          sub(/^[^[:space:]]+[[:space:]]+import[[:space:]]+/, "", line); names(line, mod)
        }
        /^[[:space:]]*import[[:space:]]+[A-Za-z_]/ { line = $0; sub(/^[[:space:]]*import[[:space:]]+/, "", line); names(line, "") }' "$1"
      ;;
    go)
      awk '
        /^[[:space:]]*import[[:space:]]*\(/ { blk = 1; next }
        blk && /^[[:space:]]*\)/ { blk = 0; next }
        (blk || /^[[:space:]]*import[[:space:]]+([A-Za-z_.]+[[:space:]]+)?"/) && match($0, /"[^"]+"/) {
          print NR "\t" substr($0, RSTART + 1, RLENGTH - 2) }' "$1"
      ;;
  esac
}

# The repository paths the import $2 of the file $1 (language $3) can name, one per line: a relative specifier from
# the directory of the file, an alias or a `baseUrl` import as the tsconfig says, a dotted Python module from the
# root, a Go import below the module path. $ARCH_ALIASES (`pattern<TAB>target` rows), $ARCH_BASEURL and $ARCH_GOMOD
# are set by architecture_check, which this runs under.
import_targets() {
  local file=$1 spec=$2 lang=$3 pat target rest dots mod i
  case $lang in
    js)
      if [[ $spec == .* ]]; then
        path_norm "$(dirname "$file")/$spec"
        return
      fi
      while IFS=$'\t' read -r pat target; do
        [ -n "$pat" ] || continue
        if [[ $pat == *'*' ]]; then
          [[ $spec == "${pat%\*}"* ]] || continue
          rest=${spec#"${pat%\*}"}
          path_norm "$ARCH_BASEURL/${target%\*}$rest"
        elif [ "$pat" = "$spec" ]; then
          path_norm "$ARCH_BASEURL/$target"
        fi
      done <<<"$ARCH_ALIASES"
      [ -z "$ARCH_BASEURL" ] || path_norm "$ARCH_BASEURL/$spec"
      ;;
    py)
      dots=${spec%%[!.]*}
      mod=${spec#"$dots"}
      mod=${mod//./\/}
      if [ -n "$dots" ]; then
        rest=$(dirname "$file")
        for ((i = 1; i < ${#dots}; i++)); do rest=$(dirname "$rest"); done
        path_norm "$rest/$mod"
      else
        path_norm "$mod"
      fi
      ;;
    go)
      [ -n "$ARCH_GOMOD" ] || return 0
      if [ "$spec" = "$ARCH_GOMOD" ]; then echo .; elif [[ $spec == "$ARCH_GOMOD/"* ]]; then path_norm "${spec#"$ARCH_GOMOD/"}"; fi
      ;;
  esac
}

# The names a path $1 can have as an import: itself, as a directory, with each extension, as the index of a directory.
path_variants() {
  local e
  printf '%s\n' "$1" "$1/"
  for e in ts tsx js jsx mjs cjs mts cts vue svelte py go; do printf '%s.%s\n' "$1" "$e"; done
  for e in ts tsx js jsx; do printf '%s/index.%s\n' "$1" "$e"; done
  printf '%s/__init__.py\n' "$1"
}

# What is wrong with the architecture rules $1 (a JSON list), one problem per line; nothing when they are fine.
# shellcheck disable=SC2016 # a jq program, not shell
architecture_rules_errors() {
  jq -r '
    def kinds: ["forbidImport", "maxLines", "banned"];
    def str: type == "string" and length > 0;
    if type != "array" then "architecture.rules must be a list of rules"
    else
      (to_entries[] | .key as $i | .value as $r
        | if ($r | type) != "object" then "architecture.rules[\($i)] must be an object"
          else (if ($r.id | str) then "rule \($r.id)" else "architecture.rules[\($i)]" end) as $l
            | (if ($r.id | str) then empty else "\($l): needs an id" end),
              (($r | keys) - (kinds + ["id", "paths", "why"]) | .[] | "\($l): unknown kind or key \"\(.)\" (a rule has an id and exactly one of \(kinds | join(", ")))"),
              ([kinds[] | select(. as $k | $r | has($k))]) as $k
              | (if ($k | length) == 0 and ((($r | keys) - ["id", "paths", "why"]) | length) == 0
                  then "\($l): has no kind (one of \(kinds | join(", ")))"
                  elif ($k | length) > 1 then "\($l): has several kinds (\($k | join(", "))), a rule has exactly one" else empty end),
              (if ($r | has("forbidImport")) and (($r.forbidImport | type) != "object" or ($r.forbidImport.from | str | not) or ($r.forbidImport.to | str | not))
                then "\($l): forbidImport needs a from and a to glob" else empty end),
              (if ($r | has("maxLines")) and (($r.maxLines | type) != "number" or $r.maxLines < 1 or ($r.maxLines | floor) != $r.maxLines)
                then "\($l): maxLines must be a positive whole number" else empty end),
              (if ($r | has("banned")) and ($r.banned | str | not) then "\($l): banned must be a regular expression" else empty end),
              (if ($r | has("maxLines") or has("banned")) and (($r.paths | type) != "array" or ($r.paths | length) == 0 or ($r.paths | any(.[]; str | not)))
                then "\($l): needs paths, a non-empty list of globs" else empty end)
          end),
      ([.[] | select(type == "object") | .id | select(str)] | group_by(.) | .[] | select(length > 1) | "rule \(.[0]): the id is used twice")
    end' <<<"$1"
}

# The violations of the architecture rules $2 (a JSON list, already valid) in the repository $1, as
# `rule<TAB>file<TAB>line<TAB>message` rows. A `forbidImport` rule reads the imports of the files under `from`
# (JavaScript and TypeScript, Python, Go) and resolves them; `maxLines` and `banned` read the files `paths` matches.
# Fails (after printing why) when a `banned` expression is not a regular expression.
architecture_violations() {
  local root=$1 rules=$2 files i n id kind from to why msg globs matched f line spec lang recs c v max re hits
  local ARCH_ALIASES="" ARCH_BASEURL="" ARCH_GOMOD="" cfg cleaned
  files=$(git -C "$root" -c core.quotePath=false ls-files -co --exclude-standard)
  for cfg in tsconfig.json jsconfig.json; do
    [ -f "$root/$cfg" ] || continue
    cleaned=$(sed -E 's#^[[:space:]]*//.*$##' "$root/$cfg")
    ARCH_BASEURL=$(jq -r '.compilerOptions.baseUrl // empty' <<<"$cleaned" 2>/dev/null) || ARCH_BASEURL=""
    ARCH_ALIASES=$(jq -r '(.compilerOptions.paths // {}) | to_entries[] | [.key, (.value[0] // "")] | @tsv' <<<"$cleaned" 2>/dev/null) || ARCH_ALIASES=""
    break
  done
  [ ! -f "$root/go.mod" ] || ARCH_GOMOD=$(sed -n 's/^module[[:space:]]\{1,\}//p' "$root/go.mod" | head -n 1 | tr -d '\r"')
  n=$(jq 'length' <<<"$rules")
  for ((i = 0; i < n; i++)); do
    id=$(jq -r ".[$i].id" <<<"$rules")
    why=$(jq -r ".[$i].why // empty" <<<"$rules")
    why=${why:+ ($why)}
    kind=$(jq -r ".[$i] | if has(\"forbidImport\") then \"forbidImport\" elif has(\"maxLines\") then \"maxLines\" else \"banned\" end" <<<"$rules")
    if [ "$kind" = forbidImport ]; then
      from=$(jq -c ".[$i].forbidImport | [.from]" <<<"$rules")
      to=$(jq -c ".[$i].forbidImport | [.to]" <<<"$rules")
      recs=$(mktemp)
      while IFS= read -r f; do
        [ -f "$root/$f" ] || continue
        case $f in
          *.ts | *.tsx | *.js | *.jsx | *.mjs | *.cjs | *.mts | *.cts | *.vue | *.svelte) lang=js ;;
          *.py) lang=py ;;
          *.go) lang=go ;;
          *) continue ;;
        esac
        while IFS=$'\t' read -r line spec; do
          while IFS= read -r c; do
            [ -n "$c" ] || continue
            while IFS= read -r v; do printf '%s\t%s\t%s\t%s\n' "$f" "$line" "$spec" "$v"; done < <(path_variants "$c")
          done < <(import_targets "$f" "$spec" "$lang")
        done < <(import_specs "$root/$f" "$lang")
      done < <(protected_match "$from" <<<"$files") >"$recs"
      matched=$(cut -f4 "$recs" | sort -u | protected_match "$to")
      awk -F'\t' 'BEGIN { while ((getline l < ARGV[1]) > 0) ok[l] = 1; ARGV[1] = "" } ($4 in ok) { print $1 "\t" $2 "\t" $3 }' \
        <(printf '%s\n' "$matched") "$recs" | LC_ALL=C sort -u |
        while IFS=$'\t' read -r f line spec; do
          printf '%s\t%s\t%s\timports %s, which resolves under %s%s\n' "$id" "$f" "$line" "$spec" "$(jq -r '.[0]' <<<"$to")" "$why"
        done
      rm -f "$recs"
    else
      globs=$(jq -c ".[$i].paths" <<<"$rules")
      if [ "$kind" = maxLines ]; then max=$(jq -r ".[$i].maxLines" <<<"$rules"); else re=$(jq -r ".[$i].banned" <<<"$rules"); fi
      while IFS= read -r f; do
        [ -f "$root/$f" ] && grep -Iq . "$root/$f" 2>/dev/null || continue
        if [ "$kind" = maxLines ]; then
          line=$(awk 'END { print NR }' "$root/$f")
          [ "$line" -le "$max" ] || printf '%s\t%s\t%s\t%s\n' "$id" "$f" "$((max + 1))" "has $line lines, over the limit of $max$why"
        else
          hits=$(grep -nIE -e "$re" -- "$root/$f" 2>&1) || {
            [ $? -ne 2 ] || { echo "rule $id: banned is not a valid regular expression: $re" >&2; return 2; }
            continue
          }
          while IFS= read -r msg; do
            printf '%s\t%s\t%s\t%s\n' "$id" "$f" "${msg%%:*}" "matches banned /$re/: $(cut -c1-80 <<<"${msg#*:}" | sed 's/^[[:space:]]*//')$why"
          done <<<"$hits"
        fi
      done < <(protected_match "$globs" <<<"$files")
    fi
  done
}

# The architecture rules of the config (`architecture.rules`, #337, spec 325 §6.2) as a check. The violations that
# .claude/architecture-baseline.json lists ({"violations": [{"rule", "file", "count"}]}, count 1 when absent: how many
# of the rule's violations the file may keep) are tolerated; any other fails, naming rule, file and line. A baseline
# entry that no longer violates, or less than it allows, is a warning. A rule with no id, an unknown kind or a missing
# part is a configuration error. With --update-baseline the baseline is rewritten without what is fixed, and no
# violation is ever added to it: the new ones are refused (exit 1).
architecture_check() {
  local root rules errs base update=false rows bad="" key line rule file cnt allowed count out
  local -A found=() allow=() first=()
  [ "${1:-}" != --update-baseline ] || update=true
  root=$(git rev-parse --show-toplevel) || die "not inside a git repository"
  rules=$(config_get architecture.rules 2>/dev/null) || rules='[]'
  if [ "$rules" = "[]" ] && [ "$update" = false ]; then
    echo "skipped: no architecture.rules"
    return 0
  fi
  errs=$(architecture_rules_errors "$rules")
  base=$root/.claude/architecture-baseline.json
  if [ -f "$base" ]; then
    errs+=${errs:+$'\n'}$(jq -r 'if (type == "object" and (.violations | type) == "array"
        and all(.violations[]; type == "object" and (.rule | type) == "string" and (.file | type) == "string"
          and ((.count // 1) | type == "number" and . >= 1 and floor == .)))
      then empty else ".claude/architecture-baseline.json must be {\"violations\": [{\"rule\", \"file\", \"count\"}]}" end' "$base" 2>&1 ||
      echo ".claude/architecture-baseline.json is not valid JSON")
  fi
  if [ -n "$errs" ]; then
    printf 'configuration error: %s\n' "$errs"
    return 1
  fi
  if [ "$update" = true ] && [ ! -f "$base" ]; then
    echo "no .claude/architecture-baseline.json: --update-baseline only removes entries, it cannot create the file"
    return 1
  fi
  rows=$(architecture_violations "$root" "$rules") || return 1
  while IFS=$'\t' read -r rule file line _; do
    [ -n "$rule" ] || continue
    key=$rule$'\t'$file
    found[$key]=$((${found[$key]:-0} + 1))
  done <<<"$rows"
  if [ -f "$base" ]; then
    while IFS=$'\t' read -r rule file cnt; do
      allow[$rule$'\t'$file]=$cnt
    done < <(jq -r '.violations[] | [.rule, .file, (.count // 1)] | @tsv' "$base")
  fi
  # Entries to keep (lowered to what is left) and the warnings about the ones that are too generous.
  out=""
  for key in "${!allow[@]}"; do
    allowed=${allow[$key]}
    count=${found[$key]:-0}
    IFS=$'\t' read -r rule file <<<"$key"
    if [ "$count" -eq 0 ]; then
      echo "warning: architecture baseline: $rule in $file no longer violates, remove it (senior-mode check --update-baseline)"
    else
      [ "$count" -ge "$allowed" ] || echo "warning: architecture baseline: $rule in $file has $count violations, the baseline allows $allowed (senior-mode check --update-baseline)"
      out+=$(jq -nc --arg r "$rule" --arg f "$file" --argjson c "$((count < allowed ? count : allowed))" '{rule: $r, file: $f, count: $c}')$'\n'
    fi
  done
  # Violations beyond the baseline: every violation of a rule in a file that has more than the baseline allows.
  while IFS=$'\t' read -r rule file line msg; do
    [ -n "$rule" ] || continue
    key=$rule$'\t'$file
    [ "${found[$key]}" -gt "${allow[$key]:-0}" ] || continue
    bad+="$rule: $file:$line: $msg${allow[$key]:+ (the baseline allows ${allow[$key]})}"$'\n'
  done <<<"$rows"
  if [ "$update" = true ]; then
    jq -s '{violations: (. | sort_by(.rule, .file))}' <<<"$out" >"$base.tmp" && mv "$base.tmp" "$base"
    echo "architecture baseline: rewritten with $(printf '%s' "$out" | grep -c '^' || true) entries; a new violation is never added to it"
  fi
  [ -z "$bad" ] || { printf '%s' "$bad"; return 1; }
}

# The context the agents load, kept lean and true (#314, #335): each tracked CLAUDE.md within
# `context.claudeMdLines` lines (default 80), each tracked SKILL.md within 3072 bytes, and the `paths` of an ADR
# front matter, when it has one, a list of strings (`paths: ["src/billing/**"]`). Those fail. A path cited
# in a CLAUDE.md between backticks that no longer exists is a warning. Runs as its own process
# (`senior-mode context-hygiene`).
context_hygiene() {
  local root max f n fm raw bad="" tok
  root=$(git rev-parse --show-toplevel)
  max=$(config_get context.claudeMdLines 2>/dev/null) || max=""
  [ -n "$max" ] && [ "$max" != null ] || max=80
  [[ $max =~ ^[1-9][0-9]*$ ]] || die "context.claudeMdLines must be a whole number from 1, not $max"
  while IFS= read -r f; do
    [ -f "$root/$f" ] || continue
    n=$(wc -l <"$root/$f")
    [ "$n" -le "$max" ] || bad+="$f: $n lines, over context.claudeMdLines ($max)"$'\n'
    # Paths between backticks with a slash inside (a bare name like `lib/` or `x.sh` is shorthand, not a
    # path): no space, no glob, no placeholder; relative to the root or to the file.
    while IFS= read -r tok; do
      [ -e "$root/$tok" ] || [ -e "$root/$(dirname "$f")/$tok" ] || echo "warning: $f cites $tok, which does not exist"
    done < <(grep -oE '`[^` ]+`' "$root/$f" | tr -d '`' | grep -E '^[A-Za-z0-9_.][A-Za-z0-9_.-]*/[A-Za-z0-9_./-]*[A-Za-z0-9_-]$' |
      grep -v '://' | sort -u)
  done < <(git -C "$root" ls-files -- 'CLAUDE.md' '**/CLAUDE.md')
  while IFS= read -r f; do
    n=$(wc -c <"$root/$f" 2>/dev/null) || continue
    [ "$n" -le 3072 ] || bad+="$f: $n bytes, over 3072"$'\n'
  done < <(git -C "$root" ls-files -- 'SKILL.md' '**/SKILL.md')
  while IFS= read -r f; do
    fm=$(awk 'NR == 1 && $0 != "---" { exit } NR > 1 && $0 == "---" { exit } NR > 1 { print }' "$root/$f" 2>/dev/null) || continue
    grep -q '^paths:' <<<"$fm" || continue
    raw=$(sed -n 's/^paths:[[:space:]]*//p' <<<"$fm" | head -n 1)
    jq -e 'type == "array" and all(.[]; type == "string")' <<<"$raw" >/dev/null 2>&1 ||
      bad+="$f: paths must be a list of strings, like [\"src/billing/**\"], not $raw"$'\n'
  done < <(git -C "$root" ls-files -- 'docs/adr/*.md')
  [ -z "$bad" ] || {
    printf '%s' "$bad"
    return 1
  }
}

# The warning of `check` about suppressions the branch adds (#437): a lint or type check silenced, a test
# skipped. One line per added line, `file:line` and the text. Never fails: review judges each one, and a
# suppression with its reason written next to it is legitimate. Markdown is prose, not code: left out.
SUPPRESSION_RE='eslint-disable|@ts-ignore|@ts-expect-error|#[[:space:]]*noqa|#[[:space:]]*type:[[:space:]]*ignore|#\[allow\(|//[[:space:]]*nolint|\.skip\(|(^|[^[:alnum:]_.])x(it|describe)\(|@pytest\.mark\.skip|t\.Skip\('
suppressions_warn() {
  local base
  base=$(default_branch) || return 0
  git -c core.quotePath=false diff -U0 --no-color --no-ext-diff --no-textconv --no-renames --no-prefix \
    "$base...HEAD" -- . ':(exclude)*.md' 2>/dev/null | awk -v re="$SUPPRESSION_RE" '
    /^diff / { header = 1; next }
    header && /^\+\+\+ / { file = substr($0, 5); sub(/\t$/, "", file); next }
    /^@@ / { header = 0; if (match($0, /\+[0-9]+/)) n = substr($0, RSTART + 1, RLENGTH - 1) + 0; next }
    !header && /^\+/ {
      text = substr($0, 2)
      if (text ~ re) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", text); printf "warn  suppression added: %s:%d: %s\n", file, n, substr(text, 1, 120) }
      n++
    }' || true
}

# Whether the path $2 is a test file of the preset $1 (#306): the files whose added cases `check` reads for assertions
# and that `red-tests verify` carries to the base. The generic preset has the usual folders and names.
test_file() {
  local base=${2##*/}
  case $1 in
    node) [[ $base =~ \.(test|spec)\.[cm]?[jt]sx?$ ]] || [[ $2 == */__tests__/* || $2 == __tests__/* ]] && [[ $base =~ \.[cm]?[jt]sx?$ ]] ;;
    python) [[ $base == test_*.py || $base == *_test.py ]] ;;
    go) [[ $base == *_test.go ]] ;;
    rust) [[ $2 == tests/*.rs || $2 == */tests/*.rs ]] ;;
    *) [[ $2 == test/* || $2 == tests/* || $2 == */test/* || $2 == */tests/* || $base == test-* || $base == *_test.* || $base == *.test.* ]] ;;
  esac
}

# The test cases the branch adds that assert nothing (#306), as `file:line: text` lines. Per preset, a case starts at a
# line that matches CASE and runs to the next one; it asserts when a line of it matches ASSERT. A case is added when its
# first line is. A preset with no known syntax (generic) is not read.
assertion_free_tests() {
  local base root preset case_re assert_re skip_re="^$" f added
  base=$(default_branch) || return 0
  root=$(git rev-parse --show-toplevel) || return 0
  preset=$(project_preset "$root")
  case $preset in
    node)
      case_re='^[[:space:]]*(it|test)(\.[a-zA-Z]+)*[([]'
      assert_re='expect|assert|[.]should|fail[(]|toMatchSnapshot|t[.](is|true|false|deepEqual|throws|notThrows|snapshot)[(]'
      skip_re='[.](todo|skip)[(]'
      ;;
    python)
      case_re='^[[:space:]]*(async[[:space:]]+)?def[[:space:]]+test'
      assert_re='assert|pytest[.](raises|fail|warns)|[.]fail[(]'
      ;;
    go)
      case_re='^func[[:space:]]+Test[A-Za-z0-9_]*[(]'
      assert_re='t[.](Error|Errorf|Fatal|Fatalf|Fail|FailNow)[(]|assert[.]|require[.]|cmp[.]Diff'
      ;;
    rust)
      case_re='^[[:space:]]*#\[(tokio::)?test'
      assert_re='assert|panic!|unreachable!|should_panic|[.]unwrap[(]|[.]expect[(]|[)][?]'
      ;;
    *) return 0 ;;
  esac
  while IFS= read -r -d '' f; do
    test_file "$preset" "$f" || continue
    added=$(git -c core.quotePath=false diff -U0 --no-color --no-ext-diff --no-renames "$base...HEAD" -- "$f" |
      sed -nE 's/^@@ -[0-9,]+ \+([0-9]+)(,([0-9]+))? @@.*/\1 \3/p' | awk '{ c = ($2 == "" ? 1 : $2); for (i = 0; i < c; i++) printf "%d ", $1 + i }')
    git show "HEAD:$f" 2>/dev/null | CASE_RE=$case_re ASSERT_RE=$assert_re SKIP_RE=$skip_re ADDED=$added FILE=$f awk '
      BEGIN { n = split(ENVIRON["ADDED"], a, " "); for (i = 1; i <= n; i++) add[a[i]] = 1 }
      { line[NR] = $0 }
      END {
        for (i = 1; i <= NR; i++) if (line[i] ~ ENVIRON["CASE_RE"] && line[i] !~ ENVIRON["SKIP_RE"]) starts[++k] = i
        for (j = 1; j <= k; j++) {
          s = starts[j]; e = (j < k ? starts[j + 1] - 1 : NR)
          if (!(s in add)) continue
          ok = 0
          for (i = s; i <= e && !ok; i++) if (line[i] ~ ENVIRON["ASSERT_RE"]) ok = 1
          if (ok) continue
          text = line[s]; if (text ~ /^[[:space:]]*#\[/ && s < NR) text = line[s + 1]
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", text)
          printf "%s:%d: %s\n", ENVIRON["FILE"], s, substr(text, 1, 100)
        }
      }'
  done < <(git diff -z --no-renames --name-only --diff-filter=AM "$base...HEAD" 2>/dev/null)
}

# The files the branch changes against the default branch, committed or not (new files included, deleted ones left
# out unless $2 is `deleted`), one per line from the repository root. Fails when there is no default branch to compare with.
changed_files() {
  local base mb filter=(--diff-filter=d)
  [ "${2:-}" != deleted ] || filter=()
  base=$(default_branch) && mb=$(git -C "$1" merge-base "$base" HEAD) || return 1
  {
    git -C "$1" -c core.quotePath=false diff --name-only --no-renames ${filter[@]+"${filter[@]}"} "$mb" || return 1
    git -C "$1" -c core.quotePath=false ls-files --others --exclude-standard
  } | LC_ALL=C sort -u
}

# The command $1 with each {files} replaced by the paths $2..., quoted for the shell.
files_subst() {
  local cmd=$1 out="" rest q
  shift
  q=$(printf '%q ' "$@")
  rest=$cmd
  while [[ $rest == *'{files}'* ]]; do
    out+=${rest%%'{files}'*}${q% }
    rest=${rest#*'{files}'}
  done
  printf '%s\n' "$out$rest"
}

# The jobs of the project's own CI that cover a check, as JSON ([{context, covers}]): those of workflow.ci.jobs when
# ci.mode is existing (ADR 0022), none otherwise. $1 is the config file.
ci_jobs() {
  [ "$(jq -r '.ci.mode // "local"' "$1")" = existing ] || { echo '[]'; return 0; }
  jq -c '.workflow.ci.jobs // []' "$1"
}

# What the project's CI says of the jobs $2 on the commit $1, one line per job: state (success, pending or failure),
# the job's context and the URL of the run that decided it. A job with no run on the commit yet is pending with no URL.
# A context matches a check run or a status named like it or like its job (`ci / lint`, `lint`). A matrix of runs is
# as bad as its worst.
ci_job_states() {
  local sha=$1 jobs=$2 slug runs="[]" statuses="[]"
  if slug=$(repo_slug 2>/dev/null); then
    runs=$(gh_retry api "repos/$slug/commits/$sha/check-runs" --jq '[.check_runs[] | {name, status, conclusion, url: .html_url}]' 2>/dev/null) || runs="[]"
    statuses=$(gh_retry api "repos/$slug/commits/$sha/status" --jq '[.statuses[] | {name: .context, state, url: .target_url}]' 2>/dev/null) || statuses="[]"
  fi
  jq -nr --argjson jobs "$jobs" --argjson runs "$runs" --argjson st "$statuses" '
    ($runs | map({name, url, s: (if .status != "completed" then "pending"
        elif (.conclusion | IN("success", "neutral", "skipped")) then "success" else "failure" end)})
      + ($st | map({name, url, s: (if .state == "success" then "success" elif .state == "pending" then "pending" else "failure" end)}))) as $all
    | $jobs[] | .context as $c | ($c | split(" / ") | last) as $j
    | [$all[] | select(.name == $c or .name == $j or (.name | endswith(" / \($j)")))] as $m
    | (if ($m | length) == 0 then "pending" elif any($m[]; .s == "failure") then "failure"
        elif any($m[]; .s == "pending") then "pending" else "success" end) as $s
    | "\($s)\t\($c)\t\(([$m[] | select(.s == $s)] | first | .url) // "")"'
}

# Runs the built-in secret scan and dependency audit, then the configured checks, from the repository
# root, each with the time it took. On a clean tree, records the result for HEAD. With --pre-push (the
# hook's stdin is the pushed refs) the checks get the changed paths in SENIOR_MODE_CHANGED_FILES, so one that
# can narrow itself to them does; that run is not recorded, because publish needs a full one. With --ci-only (ADR 0022,
# ci.mode existing) the checks that a job of the project's CI covers are not run again: the state of that job on HEAD
# is read instead (ok, `wait <context>` with status 2 while it runs or has not started, FAIL with the URL of its run);
# the result recorded for publish is that of the checks run here, publish reads the jobs again. With --changed (#339)
# each check that has a `changed` variant (`checks[].changed`, or the preset's) runs on the files the branch changed
# against the default branch, committed or not; the others run in full, and each line says which; that run is not
# recorded either, and the push gate (--pre-push, publish) refuses it. With `packages` in the config (#323), a run
# limited to what the diff affects (#418, packages_select) replaces each check named like a command of the packages by
# the command of every selected package, run in its directory, and says "3 of 12 packages" in the recorded description;
# --all, a file outside every package or --pre-push run the checks as they are. With --update-baseline only the
# architecture baseline is rewritten (see architecture_check).
check() {
  local file root count i name cmd output passed=0 failed="" state description names cmds started took scope="" log rundir runtmp ci_only=false jobs="[]" job
  local waiting="" ci_failed="" st url free pre_push=false changed=false update=false a label vext vcmd preset nbuiltin vc
  local changed_list="" sel all=false pk="" pkdesc="" pdir pcmd found idx
  local -a bases=()
  local -A variant=()
  for a in "$@"; do
    case $a in
      --pre-push) pre_push=true ;;
      --ci-only) ci_only=true ;;
      --changed) changed=true ;;
      --all) all=true ;;
      --update-baseline) update=true ;;
      *) usage ;;
    esac
  done
  [ "$pre_push" = false ] || [ "$changed" = false ] || die "check --changed is not for the push gate: --pre-push runs the full check"
  if [ "$update" = true ]; then
    [ $# -eq 1 ] || usage
    architecture_check --update-baseline
    return
  fi
  file=$(config_file)
  unset SENIOR_MODE_CHANGED_FILES
  [ "$ci_only" = false ] || jobs=$(ci_jobs "$file")
  if [ "$pre_push" = true ]; then
    scope=$(mktemp)
    if pushed_paths >"$scope"; then
      export SENIOR_MODE_CHANGED_FILES=$scope
    else
      rm -f "$scope"
      scope=""
    fi
  fi
  root=$(git rev-parse --show-toplevel)
  count=$(jq '.checks // [] | length' "$file")
  [ "$count" -gt 0 ] || die "no checks in .claude/senior-mode.json; run /senior-mode:setup"
  # Without its dependencies a node project fails typecheck and build with errors that do not say so (#110).
  if deps_missing "$root"; then
    echo "FAIL  dependencies not installed: run $(install_command "$root")"
    rm -f "$scope"
    return 1
  fi
  # The secret scan is not configurable: it runs first, on every preset. The dependency audit follows, and
  # `audit: false` turns it off (ADR 0015). The new dependencies are looked up on their registries (#302). The
  # `config` step reads the configuration against its schema (#317); the context hygiene follows (#314).
  names=("secret scan" "dependency audit" "new dependencies" "config" "context hygiene")
  cmds=("$(printf '%q' "$SELF") secret-scan" "$(printf '%q' "$SELF") audit" "$(printf '%q' "$SELF") deps" "$(printf '%q' "$SELF") config validate"
    "$(printf '%q' "$SELF") context-hygiene")
  # docs/vision.md is checked when it exists (#342), the knowledge notes when docs/knowledge does (#333), the
  # architecture rules when the config has some (#337).
  if [ -f "$root/docs/vision.md" ]; then
    names+=("vision")
    cmds+=("$(printf '%q' "$SELF") vision-check")
  fi
  if [ -d "$root/docs/knowledge" ]; then
    names+=("knowledge")
    cmds+=("$(printf '%q' "$SELF") knowledge-check")
  fi
  if [ "$(config_get architecture.rules 2>/dev/null || echo '[]')" != "[]" ]; then
    names+=("architecture")
    cmds+=("$(printf '%q' "$SELF") architecture-check")
  fi
  # docs/architecture.md is compared with the map once it holds the generated block (#347).
  if grep -qE '^<!-- senior-mode:architecture sha=[0-9a-f]+ -->$' "$root/docs/architecture.md" 2>/dev/null; then
    names+=("architecture.md")
    cmds+=("$(printf '%q' "$SELF") architecture --check")
  fi
  nbuiltin=${#names[@]}
  bases=("${names[@]}")
  if [ "$changed" = true ]; then
    if changed_list=$(changed_files "$root"); then
      preset=$(project_preset "$root")
    else
      echo "note: --changed: the changed files cannot be told (no default branch to compare with), every check runs in full"
      changed=false
    fi
  fi
  # The packages a diff affects (#418); the push gate runs everything.
  if [ "$(jq '.packages // {} | length' "$file")" -gt 0 ] && [ "$pre_push" = false ]; then
    pk=$(packages_select "$root" "$file" "$all")
    pkdesc=$(packages_say "$pk")
    echo "packages: $pkdesc$(jq -r 'if .why != "" then " (every package: \(.why))" else "" end' <<<"$pk")"
    pkdesc="; $pkdesc"
    [ "$(jq -r '.all' <<<"$pk")" = false ] || pk=""
  fi
  for ((i = 0; i < count; i++)); do
    name=$(jq -r ".checks[$i].name" "$file")
    if [ -n "$pk" ] && jq -e --arg n "$name" '[.packages[].commands[$n]] | any(. != null)' "$file" >/dev/null; then
      found=false
      while IFS=$'\t' read -r pdir pcmd; do
        found=true
        names+=("$name [$pdir]")
        bases+=("$name")
        cmds+=("cd $(printf '%q' "$pdir") && $pcmd")
      done < <(jq -r --arg n "$name" --argjson pk "$pk" '.packages as $p | $pk.run[] | select($p[.].commands[$n] != null) | [., $p[.].commands[$n]] | @tsv' "$file")
      if [ "$found" = false ]; then
        names+=("$name")
        bases+=("$name")
        cmds+=("echo 'skipped: no affected package has a $name command'")
      fi
      continue
    fi
    names+=("$name")
    bases+=("$name")
    cmds+=("$(jq -r ".checks[$i].run" "$file")")
    idx=$((${#names[@]} - 1))
    [ "$changed" = true ] || continue
    vc=$(jq -r ".checks[$i].changed // empty" "$file")
    if [ -n "$vc" ]; then
      [[ $vc == *'{files}'* ]] || die "checks[$i].changed ($name) must hold the {files} placeholder"
      variant[$idx]=$'.\t'$vc
    elif [[ $name =~ ^(lint|test)$ ]]; then
      vc=$(preset_changed "$root" "$preset" "$name" "$(jq -r ".checks[$i].run" "$file")") || vc=""
      [ -z "$vc" ] || variant[$idx]=$vc
    fi
  done
  count=${#names[@]}
  # Parallel sessions run `check` at the same time (#295): this run has a directory of its own, mktemp's name
  # being unique, for its output and for the TMPDIR its checks see, so that no two runs share a temp path.
  rundir=$(mktemp -d)
  output=$rundir/output
  mkdir "$rundir/tmp"
  for ((i = 0; i < count; i++)); do
    name=${names[i]}
    cmd=${cmds[i]}
    job=$(jq -r --arg n "${bases[i]}" '[.[] | select(.covers | index($n))][0].context // empty' <<<"$jobs")
    if [ -n "$job" ]; then
      passed=$((passed + 1))
      echo "skip  $name: covered by $job (ci-only)"
      continue
    fi
    label=$name
    if [ -n "${variant[$i]:-}" ]; then
      vext=${variant[$i]%%$'\t'*}
      vcmd=${variant[$i]#*$'\t'}
      mapfile -t sel < <(grep -E "$vext" <<<"$changed_list" || true)
      if [ "${#sel[@]}" -eq 0 ]; then
        passed=$((passed + 1))
        echo "skip  $name [changed]: no changed file to check"
        continue
      fi
      cmd=$(files_subst "$vcmd" "${sel[@]}")
      label="$name [changed: ${#sel[@]} file$([ "${#sel[@]}" -eq 1 ] || echo s)]"
    elif [ "$changed" = true ]; then
      label="$name [full]"
    fi
    started=$(now_ms)
    runtmp=$rundir/tmp
    # End-to-end suites are heavy: parallel tickets share e2e.slots of them per machine. Their lock is
    # machine-wide, so only the suite gets the private TMPDIR, not the lock (its fallback directory is in TMPDIR).
    if [ "${bases[i]}" = e2e ]; then
      cmd="$(printf '%q' "$SELF") e2e-lock -- env TMPDIR=$(printf '%q' "$runtmp") bash -c $(printf '%q' "$cmd")"
      runtmp=${TMPDIR:-/tmp}
    fi
    # Git exports GIT_DIR to hooks, absolute in a linked worktree: a check that runs git on a test
    # fixture would write into this repository.
    if (cd "$root" && for v in $(git rev-parse --local-env-vars); do unset "$v"; done && export TMPDIR=$runtmp && bash -c "$cmd") \
      >"$output" 2>&1; then
      took=$(since_ms "$started")
      passed=$((passed + 1))
      # A check with nothing to do says so on its first line; show why instead of a bare ok.
      if [[ $(head -n 1 "$output") == "skipped: "* ]]; then
        echo "skip  $label: $(head -n 1 "$output" | cut -c10-) ($took)"
      else
        echo "ok    $label ($took)"
      fi
      # A warning of a passing check (an advisory with no severity) is shown, not lost.
      { grep '^warning: ' "$output" || true; } | sed 's/^/      /'
    else
      took=$(since_ms "$started")
      failed="${failed:+$failed, }$name"
      echo "FAIL  $label ($took)"
      # The audit lists every blocking advisory (it caps them itself); another check shows its last lines.
      tail -n "$([ "$name" = "dependency audit" ] && echo 300 || echo 20)" "$output" | sed 's/^/      /'
      log=$(check_log_keep "$name" "$output")
      [ -z "$log" ] || echo "      full log: $log"
    fi
  done
  rm -rf "$rundir"
  rm -f "$scope"
  spec_drift_warn
  suppressions_warn
  # An added test case with no assertion (#306): a warning locally, an error in a run or serve session.
  free=$(assertion_free_tests)
  if [ -n "$free" ] && [ "${SENIOR_MODE_RUN:-}" = 1 ]; then
    echo "FAIL  assertion-free tests (a test case that asserts nothing proves nothing)"
    sed 's/^/      /' <<<"$free"
    failed="${failed:+$failed, }assertion-free tests"
  elif [ -n "$free" ]; then
    sed 's/^/warn  test case with no assertion: /' <<<"$free"
  fi
  if [ -z "$failed" ]; then
    state=success description="$passed/$count checks passed"
  else
    state=failure description="failed: $failed"
  fi
  description=${description:0:$((140 - ${#pkdesc}))}$pkdesc
  description=${description:0:140}
  # The jobs of the project's CI that cover checks, on this commit.
  if [ "$jobs" != "[]" ]; then
    while IFS=$'\t' read -r st job url; do
      case $st in
        success) echo "ok    $job (CI)" ;;
        pending)
          echo "wait  $job"
          waiting+="${waiting:+, }$job"
          ;;
        *)
          echo "FAIL  $job${url:+: $url}"
          ci_failed+="${ci_failed:+, }$job"
          ;;
      esac
    done < <(ci_job_states "$(git rev-parse HEAD)" "$jobs")
  fi
  if [ -n "$scope" ]; then
    echo "note: narrowed to the pushed paths, result not recorded for publishing"
  elif [ "$changed" = true ]; then
    echo "note: --changed run, result not recorded for publishing"
  elif [ -z "$(git status --porcelain)" ]; then
    mkdir -p "$(dirname "$(check_record x)")"
    printf '%s\n%s\n' "$state" "$description" >"$(check_record "$(git rev-parse HEAD)")"
  else
    echo "note: uncommitted changes, result not recorded for publishing"
  fi
  echo "$description"
  [ -z "$ci_failed" ] || return 1
  [ "$state" = success ] || return 1
  [ -z "$waiting" ] || return 2
}

# Open pull requests that contain a commit, with the issues each closes (for the security status).
# shellcheck disable=SC2016 # a GraphQL query, not shell
ASSOC_QUERY='query($owner: String!, $name: String!, $sha: GitObjectID!) { repository(owner: $owner, name: $name) {
  object(oid: $sha) { ... on Commit { associatedPullRequests(first: 10) { nodes { number state
    closingIssuesReferences(first: 20) { nodes { number } } } } } } } }'

# What `publish` says of senior-mode/security on a commit, as "<state> <description>" (ADR 0015): success
# "not required" only when no protected zone of the base branch is touched and no ticket the pull
# request closes is L; pending in every other case, also when that cannot be read. The globs come from
# the base branch, so a branch cannot lift its own zone.
security_verdict() {
  local sha=$1 base globs files zones slug answer issues n size
  GIT_TERMINAL_PROMPT=0 git_bound fetch -q origin 2>/dev/null || true # the base as it is now; offline, the last fetch stands
  base=$(default_branch) || { echo "pending required: no default branch to compare with"; return; }
  if git cat-file -e "$base:.claude/senior-mode.json" 2>/dev/null; then
    globs=$(git show "$base:.claude/senior-mode.json" | jq -c '.protected // []') || globs=null
  else
    globs=$(config_get protected 2>/dev/null) || globs='[]'
  fi
  jq -e 'type == "array" and all(type == "string")' <<<"$globs" >/dev/null ||
    { echo "pending required: protected is not a list of globs"; return; }
  files=$(git -c core.quotePath=false diff --name-only --no-renames "$base...$sha") ||
    { echo "pending required: cannot compare with $base"; return; }
  zones=$(protected_match "$globs" <<<"$files")
  [ -z "$zones" ] || { echo "pending required: protected zone ($(paste -sd, - <<<"$zones" | sed 's/,/, /g'))"; return; }
  slug=$(repo_slug)
  answer=$(jq -nc --arg q "$ASSOC_QUERY" --arg o "${slug%%/*}" --arg n "${slug#*/}" --arg s "$sha" \
    '{query: $q, variables: {owner: $o, name: $n, sha: $s}}' | gh_retry api graphql --input -) || answer=""
  if [ -z "$answer" ] || ! issues=$(jq -r '[.data.repository.object.associatedPullRequests.nodes[] | select(.state == "OPEN")]
    | if length == 0 then error("no open pull request") else [.[].closingIssuesReferences.nodes[].number] | unique | .[] end' \
    <<<"$answer" 2>/dev/null); then
    echo "pending required: no open pull request found for this commit, so its tickets are unknown"
    return
  fi
  for n in $issues; do
    size=$( (item_get "$n" Size) 2>/dev/null) || size=""
    [ -n "$size" ] || { echo "pending required: the Size of #$n is unknown"; return; }
    [ "$size" != L ] || { echo "pending required: closes the L ticket #$n"; return; }
  done
  echo "success not required: no protected zone, not L"
}

# Publishes the recorded check result of a commit as the status senior-mode/ci, and senior-mode/security
# when the pull request does not need the security pass. A due pass is left pending, and a status the
# security agent already set on the commit is never overwritten.
publish() {
  local sha record state description slug verdict current jobs st job url pending="" failed=""
  sha=$(git rev-parse --verify "${1:-HEAD}^{commit}" 2>/dev/null) || die "unknown commit: ${1:-HEAD}"
  record=$(check_record "$sha")
  [ -f "$record" ] || die "no check result for ${sha:0:7}; run senior-mode check on a clean tree first"
  state=$(sed -n 1p "$record")
  description=$(sed -n 2p "$record")
  slug=$(repo_slug)
  # With the project's own CI (ci.mode existing), the status also holds its jobs as they are now: a failed one fails it
  # with the URL of its run, one still running or not started leaves it pending (never failed).
  jobs=$(ci_jobs "$(config_file)")
  if [ "$jobs" != "[]" ]; then
    while IFS=$'\t' read -r st job url; do
      case $st in
        pending) pending+="${pending:+, }$job" ;;
        failure) failed+="${failed:+, }$job${url:+ ($url)}" ;;
      esac
    done < <(ci_job_states "$sha" "$jobs")
    if [ "$state" != failure ] && [ -n "$failed" ]; then
      state=failure description="failed: $failed"
    elif [ "$state" = success ] && [ -n "$pending" ]; then
      state=pending description="wait $pending"
    fi
    description=${description:0:140}
  fi
  gh_retry api "repos/$slug/statuses/$sha" -f state="$state" -f context=senior-mode/ci \
    -f description="$description" >/dev/null ||
    die "could not publish the status of ${sha:0:7}; push the commit first"
  echo "senior-mode/ci = $state on ${sha:0:7}: $description"
  verdict=$(security_verdict "$sha")
  state=${verdict%% *} description=${verdict#* }
  # Only publish's own words are replaced: a success "not required", a pending "required: ...". Any
  # other state of the context is the security agent's (or a person's) and stays.
  current=$(gh_retry api "repos/$slug/commits/$sha/status" --jq '[.statuses[] | select(.context == "senior-mode/security")
    | select(((.state == "success" and (.description // "" | startswith("not required")))
      or (.state == "pending" and (.description // "" | startswith("required:")))) | not) | .state][0] // empty') || die "could not read the security status of ${sha:0:7}"
  [ -z "$current" ] || { echo "senior-mode/security = $current on ${sha:0:7}: left as it is"; return 0; }
  gh_retry api "repos/$slug/statuses/$sha" -f state="$state" -f context=senior-mode/security \
    -f description="${description:0:140}" >/dev/null || die "could not publish the security status of ${sha:0:7}"
  echo "senior-mode/security = $state on ${sha:0:7}: $description"
}
