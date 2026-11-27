# shellcheck shell=bash
# Where the result of `check` is kept for a commit, until `publish` sends it (ADR 0006).
check_record() {
  printf '%s/%s\n' "$(git rev-parse --git-path senior-mode/checks)" "$1"
}

# What the Claude Code sandbox puts in the tree to keep a path read-only (#640): an empty file or directory at each
# of these paths, untracked, that `git status` then reports.
SANDBOX_MOUNTS=(.bashrc .bash_profile .zshrc .zprofile .profile .gitconfig .gitmodules .ripgreprc .mcp.json
  .vscode .idea .claude/commands .claude/agents .claude/skills)

# `git status --porcelain` without the sandbox's mount points: an untracked entry at one of SANDBOX_MOUNTS that
# holds no byte is not a change. One with content is the user's own file and is kept.
worktree_status() {
  local line path m root
  root=$(git rev-parse --show-toplevel 2>/dev/null) || return 0
  git status --porcelain | while IFS= read -r line; do
    if [ "${line:0:2}" = "??" ]; then
      path=${line:3}
      path=${path%/}
      for m in "${SANDBOX_MOUNTS[@]}"; do
        [ "$path" = "$m" ] || continue
        if [ -d "$root/$path" ]; then
          [ -z "$(find "$root/$path" -type f -size +0 2>/dev/null | head -n 1)" ] || break
        else
          [ ! -s "$root/$path" ] || break
        fi
        continue 2
      done
    fi
    printf '%s\n' "$line"
  done
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

# The failure of a check as one line per finding (#478, spec 474 §8): the `file:line[:col]` lines of the output $1, as
# `<file>:<line> <check $2> <message>`, 10 at most then `… <n> more`, then `fix: <command $3>` when there is one. An output with
# no such line is its last 20 lines. Every line is indented for the check report.
check_findings() {
  local out=$1 name=$2 fix=${3:-} re='^([^[:space:]:]+):([0-9]+)(:[0-9]+)?:?[[:space:]]+([^[:space:]].*)$' line n=0 total
  total=$(grep -cE '^[^[:space:]:]+:[0-9]+(:[0-9]+)?:?[[:space:]]+[^[:space:]]' "$out" || true)
  if [ "${total:-0}" -eq 0 ]; then
    tail -n 20 "$out" | sed 's/^/      /'
  else
    while IFS= read -r line; do
      [[ $line =~ $re ]] || continue
      n=$((n + 1))
      [ "$n" -le 10 ] || break
      printf '      %s:%s %s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "$name" "${BASH_REMATCH[4]}"
    done <"$out"
    [ "$total" -le 10 ] || echo "      … $((total - 10)) more"
  fi
  [ -z "$fix" ] || echo "      fix: $fix"
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

# The commits of the branch (those the default branch lacks) that carry a Claude trailer (#634): a `Co-Authored-By:` line naming
# Claude or an anthropic.com address, or the `Generated with Claude Code` line. One line per commit, `<short sha> <subject>`; fails
# when there is one. Enabled by `commit.coAuthor: false` (the check does not run otherwise). Runs as its own process
# (`senior-mode commit-trailers`).
commit_trailers() {
  local base found="" sha
  base=$(default_branch) || return 0
  while IFS= read -r sha; do
    git log -1 --format=%B "$sha" | grep -qiE '^[[:space:]]*co-authored-by:.*(claude|@anthropic\.com)|generated with \[?claude code' ||
      continue
    found+=$(git log -1 --format='%h %s' "$sha")$'\n'
  done < <(git rev-list "$base..HEAD")
  [ -z "$found" ] || {
    echo "commit.coAuthor is false and these commits of the branch carry a Claude trailer (reword them):"
    printf '%s' "$found"
    return 1
  }
}

# The foreign keys of a Prisma schema read on stdin, one line each: model, column (the first of `fields`), line, 1 when the model has
# an index that starts with that column (`@@index`, `@@unique`, `@@id` or `@unique` / `@id` on the field), else 0 (#744).
fk_prisma_scan() {
  awk '
    function trim(x) { sub(/^[ \t]+/, "", x); sub(/[ \t]+$/, "", x); return x }
    function firstof(list,   c) { c = list; sub(/,.*/, "", c); sub(/\(.*/, "", c); return trim(c) }
    function close_model(   k) { for (k = 1; k <= n; k++) printf "%s\t%s\t%d\t%d\n", model, fkcol[k], fkline[k], (fkcol[k] in idx) ? 1 : 0; inmodel = 0 }
    { line = $0; sub(/\/\/.*$/, "", line) }
    line ~ /^[ \t]*model[ \t]+[A-Za-z0-9_]+[ \t]*\{/ { model = line; sub(/^[ \t]*model[ \t]+/, "", model); sub(/[ \t]*\{.*/, "", model); n = 0; inmodel = 1; split("", idx); next }
    inmodel && line ~ /^[ \t]*\}/ { close_model(); next }
    !inmodel { next }
    line ~ /@@(index|unique|id)\(/ { if (match(line, /\[[^]]*\]/)) idx[firstof(substr(line, RSTART + 1, RLENGTH - 2))] = 1; next }
    line ~ /[^@]@(unique|id)([^A-Za-z]|$)/ { f = line; sub(/^[ \t]+/, "", f); sub(/[ \t].*/, "", f); idx[f] = 1 }
    line ~ /@relation\(/ && match(line, /fields:[ \t]*\[[^]]*\]/) {
      list = substr(line, RSTART, RLENGTH); sub(/^[^\[]*\[/, "", list); sub(/\]$/, "", list)
      n++; fkcol[n] = firstof(list); fkline[n] = NR
    }'
}

# The foreign keys and the indexes of SQL read on stdin (#744), one line each: `F`, table, column, line for a foreign key
# (`REFERENCES` on a column, `FOREIGN KEY (...)`, in CREATE TABLE or ALTER TABLE ... ADD), `I`, table, column for what starts
# an index (CREATE INDEX, PRIMARY KEY, UNIQUE). Table names are lower case, without quotes or schema.
fk_sql_scan() {
  awk '
    function clean(x) { gsub(/["`]/, "", x); sub(/^[ \t\n]+/, "", x); sub(/[ \t\n]+$/, "", x); return x }
    function tname(x) { x = clean(x); sub(/.*\./, "", x); return tolower(x) }
    function firstcol(list,   c) { c = list; sub(/[,)].*/, "", c); c = clean(c); sub(/[ \t\n(].*/, "", c); return c }
    function lastword(x,   a, k) { k = split(x, a, /[ \t\n]+/); return a[k] }
    function lineof(p,   k) { for (k = nl; k >= 1; k--) if (pos[k] <= p) return ln[k]; return ln[1] }
    function element(table, e, startp,   l, c, col) {
      if (match(e, /[^ \t\n]/)) { startp += RSTART - 1; e = substr(e, RSTART) } else return
      l = tolower(e)
      if (l ~ /^constraint[ \t\n]/) { sub(/^[^ \t\n]+[ \t\n]+[^ \t\n]+[ \t\n]+/, "", e); l = tolower(e) }
      if (l ~ /^foreign[ \t\n]+key/) { i = index(e, "("); printf "F\t%s\t%s\t%d\n", table, firstcol(substr(e, i + 1)), lineof(startp); return }
      if (l ~ /^(primary[ \t\n]+key|unique)[ \t\n]*\(/) { i = index(e, "("); printf "I\t%s\t%s\n", table, tolower(firstcol(substr(e, i + 1))); return }
      if (l ~ /^(check|exclude|like|period|primary|unique|foreign)/) return
      if (match(e, /^"[^"]*"|^`[^`]*`/)) c = substr(e, 1, RLENGTH); else { match(e, /^[^ \t\n]+/); c = substr(e, 1, RLENGTH) }
      col = clean(c)
      if (l ~ /[ \t\n]references[ \t\n]/) printf "F\t%s\t%s\t%d\n", table, col, lineof(startp)
      if (l ~ /primary[ \t\n]+key|[ \t\n]unique([ \t\n,]|$)/) printf "I\t%s\t%s\n", table, tolower(col)
    }
    # One element of a CREATE TABLE body, or one action of an ALTER TABLE (only ADD counts).
    function item(table, e, startp, alter) {
      if (alter) {
        if (tolower(e) !~ /^[ \t\n]*add[ \t\n]/) return
        sub(/^[ \t\n]*[Aa][Dd][Dd][ \t\n]+/, "", e)
        sub(/^[Cc][Oo][Ll][Uu][Mm][Nn][ \t\n]+/, "", e)
        sub(/^[Ii][Ff][ \t\n]+[Nn][Oo][Tt][ \t\n]+[Ee][Xx][Ii][Ss][Tt][Ss][ \t\n]+/, "", e)
      }
      element(table, e, startp)
    }
    # The elements of s from offset p, split at the commas of depth 0, up to the closing parenthesis of a body (or the end).
    function elements(table, s, p, top, alter,   depth, start, ch, last) {
      depth = 0; start = p
      for (;; p++) {
        ch = (p <= length(s)) ? substr(s, p, 1) : ""
        if (ch == "(") depth++
        else if (ch == ")") depth--
        last = (ch == "") || (!top && depth < 0)
        if (last || (ch == "," && depth == 0)) { item(table, substr(s, start, p - start), start, alter); start = p + 1 }
        if (last) break
      }
    }
    function process(s,   l, t, rest, p, i) {
      l = tolower(s)
      if (match(l, /^[ \t\n]*create[ \t\n]+(unique[ \t\n]+)?index/)) {
        if (match(l, /[ \t\n]on[ \t\n]+(only[ \t\n]+)?[^ \t\n(]+/)) {
          t = tname(lastword(substr(s, RSTART, RLENGTH))); rest = substr(s, RSTART + RLENGTH); i = index(rest, "(")
          if (i) printf "I\t%s\t%s\n", t, tolower(firstcol(substr(rest, i + 1)))
        }
      } else if (match(l, /^[ \t\n]*create[ \t\n]+((unlogged|temporary|temp)[ \t\n]+)?table[ \t\n]+(if[ \t\n]+not[ \t\n]+exists[ \t\n]+)?[^ \t\n(]+/)) {
        t = tname(lastword(substr(s, 1, RSTART + RLENGTH - 1))); rest = RSTART + RLENGTH; i = index(substr(s, rest), "(")
        if (i) elements(t, s, rest + i, 0, 0)
      } else if (match(l, /^[ \t\n]*alter[ \t\n]+table[ \t\n]+(if[ \t\n]+exists[ \t\n]+)?(only[ \t\n]+)?[^ \t\n(]+/)) {
        t = tname(lastword(substr(s, 1, RSTART + RLENGTH - 1)))
        elements(t, s, RSTART + RLENGTH, 1, 1)
      }
    }
    { line = $0; sub(/--.*$/, "", line); nl++; ln[nl] = NR; pos[nl] = length(buf) + 1; buf = buf line "\n"
      if (line ~ /;/) { process(buf); buf = ""; nl = 0 } }
    END { if (buf != "") process(buf) }'
}

# The rule of #744 (tier 2): a foreign key the branch adds to a Prisma schema (`@relation` with `fields`) or to a SQL migration
# (`REFERENCES`, `FOREIGN KEY`) needs an index that starts with its column: `@@index`, `@@unique`, `@@id` (Prisma, in the model),
# CREATE INDEX, PRIMARY KEY or UNIQUE (SQL, in any migration of the tree). A key the base already had is not reported. Prints
# `<file>:<line> <message>` and fails when there is one. Runs as its own process (`senior-mode fk-check`).
fk_check() {
  local base f model table col line indexed found=0 i
  local -a files=()
  local -A had=() idx=()
  base=$(default_branch) || {
    echo "skipped: no base branch"
    return 0
  }
  mapfile -t files < <(git -c core.quotePath=false diff --name-only --no-renames --diff-filter=d "$base...HEAD" | grep -E '\.(prisma|sql)$' || true)
  [ "${#files[@]}" -gt 0 ] || {
    echo "skipped: no schema or migration change"
    return 0
  }
  for f in "${files[@]}"; do
    if [[ $f == *.prisma ]]; then
      had=()
      while IFS=$'\t' read -r model col _; do had["$model.$col"]=1; done < <(git show "$base:$f" 2>/dev/null | fk_prisma_scan)
      while IFS=$'\t' read -r model col line indexed; do
        [ "$indexed" = 0 ] && [ -z "${had["$model.$col"]:-}" ] || continue
        echo "$f:$line $model.$col is a foreign key with no index (add @@index([$col]) to the model)"
        found=1
      done < <(git show "HEAD:$f" | fk_prisma_scan)
    fi
  done
  if printf '%s\n' "${files[@]}" | grep -q '\.sql$'; then
    # The indexes of the whole tree: an earlier migration may already hold the one a new key needs.
    while IFS=$'\t' read -r i table col; do
      [ "$i" != I ] || idx["$table.${col,,}"]=1
    done < <(
      while IFS= read -r f; do
        git show "HEAD:$f"
        echo ";"
      done < <(git ls-tree -r --name-only HEAD | grep '\.sql$' || true) | fk_sql_scan
    )
    for f in "${files[@]}"; do
      [[ $f == *.sql ]] || continue
      had=()
      while IFS=$'\t' read -r i table col _; do [ "$i" = F ] && had["$table.${col,,}"]=1; done < <(git show "$base:$f" 2>/dev/null | fk_sql_scan)
      while IFS=$'\t' read -r i table col line; do
        [ "$i" = F ] || continue
        [ -z "${had["$table.${col,,}"]:-}" ] && [ -z "${idx["$table.${col,,}"]:-}" ] || continue
        echo "$f:$line $table.$col is a foreign key with no index (CREATE INDEX ON $table ($col))"
        found=1
      done < <(git show "HEAD:$f" | fk_sql_scan)
    done
  fi
  [ "$found" -eq 0 ]
}

# Whether the branch changes a Prisma schema or a SQL migration, which is when the foreign key rule runs.
fk_applies() {
  local base
  base=$(default_branch) || return 1
  git -c core.quotePath=false diff --name-only --no-renames --diff-filter=d "$base...HEAD" 2>/dev/null | grep -qE '\.(prisma|sql)$'
}

# The linter of the migrations (#747, tier 2): `performance.migrations.linter` (`squawk`, `django-migration-linter`), else
# `django-migration-linter` for a Django project (a `manage.py` at the root), else none.
migrations_linter() {
  local linter root
  linter=$(config_get performance.migrations.linter 2>/dev/null) || linter=""
  if [ -z "$linter" ]; then
    root=$(git rev-parse --show-toplevel) || return 0
    [ ! -f "$root/manage.py" ] || linter=django-migration-linter
  fi
  printf '%s\n' "$linter"
}

# The migrations the branch adds or changes, one path per line: `performance.migrations.paths`, else the Django migration modules
# or the SQL files of a `migrations` folder.
migrations_changed() {
  local base globs
  base=$(default_branch) || return 0
  globs=$(config_get performance.migrations.paths 2>/dev/null) || globs=""
  if [ -z "$globs" ] || [ "$globs" = null ]; then
    if [ "$(migrations_linter)" = django-migration-linter ]; then globs='["**/migrations/*.py"]'; else globs='["**/migrations/**/*.sql"]'; fi
  fi
  git -c core.quotePath=false diff --name-only --no-renames --diff-filter=d "$base...HEAD" 2>/dev/null | protected_match "$globs" || true
}

# The step `migrations` (#747): the linter of the project on the migrations the branch adds or changes, and on those only.
# squawk prints `<file>:<line>:<column>: <level>: <rule>`; django-migration-linter lints the migrations by name. With no linter,
# or one that is not installed, it says `not measured` and passes: the reviewer applies the expand/contract checklist.
migrations_check() {
  local linter files f
  local -a names=()
  linter=$(migrations_linter)
  mapfile -t files < <(migrations_changed)
  [ "${#files[@]}" -gt 0 ] && [ -n "${files[0]}" ] || {
    echo "skipped: no migration change"
    return 0
  }
  if [ -z "$linter" ]; then
    echo "skipped: not measured, set performance.migrations.linter (squawk or django-migration-linter); the reviewer applies the expand/contract checklist"
    return 0
  fi
  command -v "$linter" >/dev/null 2>&1 || {
    echo "skipped: not measured, $linter is not installed"
    return 0
  }
  case $linter in
    squawk) squawk "${files[@]}" ;;
    django-migration-linter)
      for f in "${files[@]}"; do names+=(--include-name "$(basename "$f" .py)"); done
      django-migration-linter "${names[@]}" .
      ;;
  esac
}

# The hot paths the specs name (#758): for each `docs/specs/*.md` with a `## Hot paths` section, one line per list item that holds two
# backticked spans, the path (a glob) and the benchmark, `<spec>\t<line>\t<path>\t<benchmark>\t<the spec's paths, a JSON list>`.
hot_entries() {
  local root spec fm globs
  root=$(git rev-parse --show-toplevel) || return 0
  while IFS= read -r spec; do
    grep -qE '^## Hot paths[[:space:]]*$' "$root/$spec" 2>/dev/null || continue
    fm=$(awk 'NR == 1 && $0 != "---" { exit } NR > 1 && $0 == "---" { exit } NR > 1 { print }' "$root/$spec")
    globs=$(sed -n 's/^paths:[[:space:]]*\[\(.*\)\][[:space:]]*$/\1/p' <<<"$fm" | tr ',' '\n' | tr -d "\"'\r[:space:]" | jq -Rnc '[inputs | select(length > 0)]')
    awk -v spec="$spec" -v globs="$globs" '
      /^## / { on = ($0 ~ /^## Hot paths[ \t]*$/); next }
      on && /^[-*][ \t]+`[^`]+`.*`[^`]+`/ { split($0, a, "`"); printf "%s\t%d\t%s\t%s\t%s\n", spec, NR, a[2], a[4], globs }' "$root/$spec"
  done < <(git -C "$root" ls-files -- 'docs/specs/*.md')
}

# The files the branch adds or changes, one per line.
branch_changed() {
  local base
  base=$(default_branch) || return 0
  git -c core.quotePath=false diff --name-only --no-renames --diff-filter=d "$base...HEAD" 2>/dev/null || true
}

# The hot paths the branch's changed files fall under, as the lines of hot_entries: under the `paths` of the spec when $1 is `spec`,
# under the glob of the hot path itself otherwise.
hot_touched() {
  local changed spec line path bench globs row
  changed=$(branch_changed)
  [ -n "$changed" ] || return 0
  while IFS=$'\t' read -r spec line path bench globs; do
    row=$spec$'\t'$line$'\t'$path$'\t'$bench$'\t'$globs
    if [ "$1" = spec ]; then
      [ "$globs" != "[]" ] || continue
      [ -z "$(protected_match "$globs" <<<"$changed")" ] || printf '%s\n' "$row"
    else
      [ -z "$(protected_match "$(jq -nc --arg p "$path" '[$p]')" <<<"$changed")" ] || printf '%s\n' "$row"
    fi
  done < <(hot_entries)
}

# The step `hot paths` (#758, tier 2): each hot path of a spec whose `paths` the branch's diff falls under names a benchmark that
# exists, that is its name appears in a tracked file that is not Markdown. Without `performance.bench.command` it says
# `bench: not measured` and passes. Prints `<spec>:<line> <message>` per hot path with no benchmark.
hot_paths_check() {
  local rows spec line path bench globs miss=0 cmd
  rows=$(hot_touched spec)
  [ -n "$rows" ] || {
    echo "skipped: no hot path to check"
    return 0
  }
  cmd=$(config_get performance.bench.command 2>/dev/null) || cmd=""
  [ -n "$cmd" ] || {
    echo "skipped: bench: not measured, set performance.bench.command"
    return 0
  }
  while IFS=$'\t' read -r spec line path bench globs; do
    git grep -qF -e "$bench" -- . ':(exclude)*.md' && continue
    echo "$spec:$line hot path $path has no benchmark named $bench"
    miss=1
  done <<<"$rows"
  [ "$miss" -eq 0 ]
}

# One run of the benchmark command $2 in the directory $1 (`{out}` is a file it may write; else its output is read): the JSON
# object of benchmark name to median, on stdout.
bench_run() {
  local dir=$1 cmd=$2 out
  out=$(mktemp)
  (cd "$dir" && bash -c "${cmd//\{out\}/$out}" </dev/null) >"$out.stdout" || {
    rm -f "$out" "$out.stdout"
    return 1
  }
  if [ -s "$out" ]; then cat "$out"; else cat "$out.stdout"; fi
  rm -f "$out" "$out.stdout"
}

# The percent the benchmark values $1 and $2 differ by, over the smaller one.
bench_spread() {
  awk -v a="$1" -v b="$2" 'BEGIN { m = (a < b ? a : b); d = (a < b ? b - a : a - b); printf "%.1f", (m > 0 ? d * 100 / m : (d > 0 ? 100000 : 0)) }'
}

# The step `perf` (#761, tier 3): when the diff falls under a hot path of a spec, the benchmark command runs twice on the merge base
# and twice on the head in the same slot, and each benchmark the touched hot paths name is compared: the mean of the two medians,
# slower on the head by more than `performance.bench.threshold` percent (default 10) fails, naming the benchmark, both medians and
# the change. Two runs of one commit that differ by more than the threshold are `unstable`: the pull request gets `needs-human`,
# an issue is filed for the benchmark and the step fails, it never passes. Without `performance.bench.command`: `bench: not measured`.
perf_check() {
  local rows cmd threshold base mb root wt dep dcmd i r name spec line a1 a2 h1 h2 am hm change sa sh bad=0
  local -a benches=() runs=()
  rows=$(hot_touched path)
  [ -n "$rows" ] || {
    echo "skipped: no diff under a hot path"
    return 0
  }
  cmd=$(config_get performance.bench.command 2>/dev/null) || cmd=""
  [ -n "$cmd" ] || {
    echo "skipped: bench: not measured, set performance.bench.command"
    return 0
  }
  threshold=$(config_get performance.bench.threshold 2>/dev/null) || threshold=10
  root=$(git rev-parse --show-toplevel) || return 1
  base=$(default_branch) && mb=$(git merge-base "$base" HEAD) || {
    echo "skipped: no base branch to compare with"
    return 0
  }
  wt=$(worktree_path "$root" "bench-${mb:0:12}")
  git worktree remove --force "$wt" 2>/dev/null || true
  git worktree add -q --detach "$wt" "$mb" || die "no worktree of the merge base ${mb:0:7} to run the benchmarks in"
  while IFS=$'\t' read -r dep dcmd; do
    (cd "$wt/$dep" && bash -c "$dcmd" </dev/null) >/dev/null 2>&1 || true
  done < <(install_plan "$wt")
  # Interleaved, so a drift of the machine touches both sides alike: base, head, base, head.
  for i in 1 2; do
    r=$(bench_run "$wt" "$cmd") || bad=1
    runs+=("$r")
    r=$(bench_run "$root" "$cmd") || bad=1
    runs+=("$r")
  done
  git worktree remove --force "$wt" 2>/dev/null || true
  [ "$bad" -eq 0 ] || {
    echo "FAIL: the benchmark command failed on the merge base or the head"
    return 1
  }
  bad=0
  while IFS=$'\t' read -r spec line _ name _; do
    [[ " ${benches[*]:-} " == *" $spec:$line:$name "* ]] || benches+=("$spec:$line:$name")
  done <<<"$rows"
  for i in "${benches[@]}"; do
    spec=${i%%:*} line=${i#*:} name=${line#*:} line=${line%%:*}
    a1=$(jq -r --arg n "$name" '.[$n] // empty' <<<"${runs[0]}")
    h1=$(jq -r --arg n "$name" '.[$n] // empty' <<<"${runs[1]}")
    a2=$(jq -r --arg n "$name" '.[$n] // empty' <<<"${runs[2]}")
    h2=$(jq -r --arg n "$name" '.[$n] // empty' <<<"${runs[3]}")
    if [ -z "$a1" ] || [ -z "$h1" ] || [ -z "$a2" ] || [ -z "$h2" ]; then
      echo "$spec:$line benchmark $name is not in the output of the benchmark command"
      bad=1
      continue
    fi
    sa=$(bench_spread "$a1" "$a2")
    sh=$(bench_spread "$h1" "$h2")
    if awk -v x="$sa" -v y="$sh" -v t="$threshold" 'BEGIN { exit !(x > t || y > t) }'; then
      echo "$spec:$line benchmark $name is unstable: two runs of one commit differ by ${sa}% (base) and ${sh}% (head), more than $threshold%"
      perf_unstable "$name" "$a1 $a2" "$h1 $h2" "$threshold"
      bad=1
      continue
    fi
    am=$(awk -v a="$a1" -v b="$a2" 'BEGIN { printf "%.4g", (a + b) / 2 }')
    hm=$(awk -v a="$h1" -v b="$h2" 'BEGIN { printf "%.4g", (a + b) / 2 }')
    change=$(awk -v a="$am" -v h="$hm" 'BEGIN { printf "%+.1f", (a > 0 ? (h - a) * 100 / a : 0) }')
    if awk -v c="$change" -v t="$threshold" 'BEGIN { exit !(c > t) }'; then
      echo "$spec:$line benchmark $name is slower: median $am on the base, $hm on the head ($change%, more than $threshold%)"
      bad=1
    else
      echo "ok $name: median $am on the base, $hm on the head ($change%)"
    fi
  done
  [ "$bad" -eq 0 ]
}

# An unstable benchmark (#761): `needs-human` on the pull request of the commit, and an issue for the benchmark $1 (base runs $2, head
# runs $3, threshold $4). Never stops the check: the step fails whatever happens here.
perf_unstable() {
  local slug pr
  slug=$(repo_slug 2>/dev/null) || return 0
  pr=$(gh_retry api "repos/$slug/commits/$(git rev-parse HEAD)/pulls" --jq '[.[] | select(.state == "open")][0].number // empty' 2>/dev/null) || pr=""
  [ -z "$pr" ] || gh_retry api "repos/$slug/issues/$pr/labels" -f 'labels[]=needs-human' >/dev/null || true
  gh_retry api "repos/$slug/issues" -f title="perf: benchmark $1 is unstable" \
    -f body="Two runs of the benchmark \`$1\` on one commit differ by more than $4%: base $2, head $3${pr:+ (pull request #$pr)}. A benchmark that cannot be trusted gates nothing: make it deterministic, or give it a quiet slot." >/dev/null || true
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
# recorded either, and the push gate (--pre-push, publish) refuses it; it is what the pre-push hook runs (#827), and the checks
# get the changed paths, deleted files included, in SENIOR_MODE_CHANGED_FILES as with --pre-push. With `packages` in the config (#323), a run
# limited to what the diff affects (#418, packages_select) replaces each check named like a command of the packages by
# the command of every selected package, run in its directory, and says "3 of 12 packages" in the recorded description;
# --all, a file outside every package or --pre-push run the checks as they are. With --update-baseline only the
# baselines are rewritten (see architecture_check, ratchet_update).
# The configuration errors of the `tier` keys of the checks of the config file $1, one per line: a tier is 2 or 3, and
# the built-in checks (secret scan, dependency audit) are tier 2 and cannot be moved.
check_tier_errors() {
  jq -r '.checks // [] | to_entries[] | select(.value | has("tier")) | .key as $i | .value
    | if (.name == "secret scan" or .name == "dependency audit") then "checks[\($i)].tier: \(.name) is a built-in check of tier 2, it cannot take a tier"
      elif (.tier != 2 and .tier != 3) then "checks[\($i)].tier must be 2 or 3, not \(.tier | tojson)"
      else empty end' "$1"
}

# The lockfiles that take part in the key of the check cache (#479): a change to one of them misses it.
CHECK_LOCKFILES=(package-lock.json pnpm-lock.yaml yarn.lock bun.lock bun.lockb Cargo.lock go.sum poetry.lock uv.lock
  requirements.txt Gemfile.lock composer.lock)

# Where the successes of checks are kept: the common git directory, so that every worktree shares them (#479).
check_cache_dir() {
  local dir
  dir=$(git rev-parse --path-format=absolute --git-common-dir) || return 1
  printf '%s/senior-mode/cache\n' "$dir"
}

# The cache key of the check $1 run as the command $2 from the repository $5, for the globs $3 (a JSON array, its `inputs`)
# and the configuration file $4: the hash of the name, the command, the blob ids of the tracked files the globs match,
# the configuration and the lockfiles. Prints nothing and fails when a file the globs match has uncommitted changes
# (or is untracked): the result of such a run is neither looked up nor kept.
check_cache_key() {
  local name=$1 cmd=$2 inputs=$3 file=$4 root=$5 g l
  local -a spec=() locks=()
  while IFS= read -r g; do spec+=(":(glob)$g"); done < <(jq -r '.[]' <<<"$inputs")
  [ "${#spec[@]}" -gt 0 ] || return 1
  [ -z "$(git -C "$root" status --porcelain --untracked-files=all -- "${spec[@]}")" ] || return 1
  for l in "${CHECK_LOCKFILES[@]}"; do locks+=(":(glob)**/$l"); done
  {
    printf '%s\0%s\0' "$name" "$cmd"
    git -C "$root" ls-files -s -- "${spec[@]}"
    git -C "$root" hash-object "$file"
    git -C "$root" ls-files -s -- "${locks[@]}"
  } | sha256sum | cut -d' ' -f1
}

# Where the heavy runs (tier 3) of the commits are kept, `<sha>.state` and `<sha>.log`: the common git directory, so that every
# worktree sees them (#717, spec 474 §4).
heavy_dir() {
  local dir
  dir=$(git rev-parse --path-format=absolute --git-common-dir) || return 1
  printf '%s/senior-mode/heavy\n' "$dir"
}

# Sets the status senior-mode/heavy of the commit $1 to the state $2 with the description $3 (140 characters at most) and
# keeps both in the state file of the commit, which says the commit has a heavy run.
heavy_set() {
  local sha=$1 state=$2 description=${3:0:140} dir
  dir=$(heavy_dir) && mkdir -p "$dir" || return 1
  gh_retry api "repos/$(repo_slug)/statuses/$sha" -f state="$state" -f context=senior-mode/heavy \
    -f description="$description" >/dev/null || return 1
  printf '%s\t%s\n' "$state" "$description" >"$dir/$sha.state.$$" && mv -f "$dir/$sha.state.$$" "$dir/$sha.state"
}

# Carries the finished heavy result of the commit $1 over to $2 when `git range-diff` shows the same patches (a rebase).
# Fails, and sets nothing, otherwise.
heavy_carry() {
  local old state base ob nb rd dir
  old=$(git rev-parse --verify "$1^{commit}" 2>/dev/null) || return 1
  dir=$(heavy_dir) || return 1
  [ -f "$dir/$old.state" ] || return 1
  state=$(cut -f1 "$dir/$old.state")
  [[ $state =~ ^(success|failure)$ ]] || return 1
  base=$(default_branch) || return 1
  ob=$(git merge-base "$old" "$2") && nb=$(git merge-base "$base" "$2") &&
    rd=$(git range-diff --no-color "$ob..$old" "$nb..$2" 2>/dev/null) && [ -n "$rd" ] || return 1
  printf '%s\n' "$rd" | awk 'NF && $3 != "=" { bad = 1 } END { exit (bad || NR == 0) }' || return 1
  heavy_set "$2" "$state" "carried over from ${old:0:7}: git range-diff shows the same patches" || return 1
  echo "senior-mode/heavy = $state on ${2:0:7}: carried over from ${old:0:7}"
}

# What `publish` does about the heavy tier on the commit $1 (#717): nothing without a tier 3 check or when the commit already
# has a heavy run; the result of SENIOR_MODE_HEAVY_FROM (the previous head, set by serve after a rebase) when git range-diff
# shows the same patches; else senior-mode/heavy pending at once and `check --tier 3 --publish <sha>` started detached, under a
# slot, so that the caller never waits for it.
heavy_start() {
  local sha=$1 dir
  [ "$(jq '[.checks // [] | .[] | select(.tier == 3)] | length' "$(config_file)")" -gt 0 ] || [ -n "$(config_get performance.bench.command 2>/dev/null)" ] || return 0
  dir=$(heavy_dir) || return 0
  [ ! -e "$dir/$sha.state" ] || return 0
  if [ -n "${SENIOR_MODE_HEAVY_FROM:-}" ] && heavy_carry "$SENIOR_MODE_HEAVY_FROM" "$sha"; then
    return 0
  fi
  heavy_set "$sha" pending "tier 3 checks running" || die "could not publish the heavy status of ${sha:0:7}"
  (cd "$(git rev-parse --show-toplevel)" && nohup "$SELF" slot -- "$SELF" check --tier 3 --publish "$sha" \
    </dev/null >>"$dir/$sha.log" 2>&1 &)
  echo "senior-mode/heavy = pending on ${sha:0:7}: tier 3 checks running, log $dir/$sha.log"
}

# Puts the heavy report of the commit $2 on its pull request $1 as the one comment marked <!-- senior-mode:heavy -->: the
# existing one is replaced; with $4 = only-existing no comment is created (a pass leaves nothing but a stale report to fix).
heavy_comment() {
  local pr=$1 slug id body="<!-- senior-mode:heavy -->
$3"
  slug=$(repo_slug) || return 0
  id=$(gh_retry api "repos/$slug/issues/$pr/comments" --jq '[.[] | select(.body | startswith("<!-- senior-mode:heavy -->"))][0].id // empty' 2>/dev/null) || id=""
  if [ -n "$id" ]; then
    gh_retry api -X PATCH "repos/$slug/issues/comments/$id" -f body="$body" >/dev/null || true
  elif [ "${4:-}" != only-existing ]; then
    gh_retry api "repos/$slug/issues/$pr/comments" -f body="$body" >/dev/null || true
  fi
}

# `check --tier 3 --publish <sha>` (#717): the heavy run of the commit $1, in a worktree of it with its dependencies installed,
# then senior-mode/heavy set to success, or to failure with the names of the failed checks, and on failure the compact
# `file:line` lines of the failures and the path of the full log as a comment of the pull request. Always returns 0: the
# result is the status.
heavy_run() {
  local sha=$1 root wt log dir rc=1 description pr dep cmd report
  root=$(git rev-parse --show-toplevel) || return 1
  dir=$(heavy_dir) || return 1
  log=$dir/$sha.log
  wt=$(worktree_path "$root" "heavy-${sha:0:12}")
  git worktree remove --force "$wt" 2>/dev/null || true
  if git worktree add -q --detach "$wt" "$sha" >>"$log" 2>&1; then
    while IFS=$'\t' read -r dep cmd; do
      (cd "$wt/$dep" && bash -c "$cmd" </dev/null) >>"$log" 2>&1 || true
    done < <(install_plan "$wt")
    (cd "$wt" && "$SELF" check --tier 3) >>"$log" 2>&1 && rc=0
    git worktree remove --force "$wt" 2>/dev/null || true
  else
    echo "failed: no worktree of ${sha:0:7} to run the heavy checks in" >>"$log"
  fi
  description=$(tail -n 1 "$log")
  if [ "$rc" -eq 0 ]; then
    heavy_set "$sha" success "$description" || true
  else
    [[ $description == "failed: "* ]] || description="failed: tier 3 run, see $log"
    heavy_set "$sha" failure "$description" || true
  fi
  pr=$(gh_retry api "repos/$(repo_slug)/commits/$sha/pulls" --jq '[.[] | select(.state == "open")][0].number // empty' 2>/dev/null) || pr=""
  [ -n "$pr" ] || return 0
  if [ "$rc" -eq 0 ]; then
    heavy_comment "$pr" "$sha" "Tier 3 checks passed on \`${sha:0:7}\`: $description" only-existing
  else
    report=$(grep -E '^(FAIL  |      )' "$log" || true)
    heavy_comment "$pr" "$sha" "Tier 3 checks failed on \`${sha:0:7}\`: ${description#failed: }

\`\`\`
$report
\`\`\`
Log: \`$log\`"
  fi
  return 0
}

check() {
  local file root count i name cmd output passed=0 failed="" state description names cmds started took scope="" log rundir runtmp ci_only=false jobs="[]" job
  local flaky="" fl waiting="" ci_failed="" st url free pre_push=false changed=false update=false a label vext vcmd preset nbuiltin vc
  local changed_list="" changed_scope="" sel all=false pk="" pkdesc="" pdir pcmd found idx argc=$# tier_only="" tier run2=true run3=false tier_errors urc=0 no_cache=false ckey inp cdir publish_sha=""
  local -a bases=()
  local -A variant=()
  while [ $# -gt 0 ]; do
    case $1 in
      --pre-push) pre_push=true ;;
      --ci-only) ci_only=true ;;
      --changed) changed=true ;;
      --all) all=true ;;
      --no-cache) no_cache=true ;;
      --update-baseline) update=true ;;
      --tier)
        [ $# -ge 2 ] || usage
        tier_only=$2
        shift
        ;;
      --publish)
        [ $# -ge 2 ] || usage
        publish_sha=$2
        shift
        ;;
      *) usage ;;
    esac
    shift
  done
  [[ -z $tier_only || $tier_only =~ ^[23]$ ]] || die "check --tier takes 2 or 3, not $tier_only"
  [ -z "$tier_only" ] || [ "$all" = false ] || die "check --tier and --all are exclusive: --all runs tiers 2 and 3"
  # Tier 2 is the push gate and the default; tier 3 is the heavy tier, run by --tier 3 or with --all (spec 474 §2).
  [ -z "$publish_sha" ] || [ "$tier_only" = 3 ] || die "check --publish goes with --tier 3"
  [ "$tier_only" != 3 ] || run2=false
  { [ "$tier_only" = 3 ] || [ "$all" = true ]; } && run3=true
  [ "$pre_push" = false ] || [ "$changed" = false ] || die "check --changed is not for the push gate: --pre-push runs the full check"
  if [ -n "$publish_sha" ]; then
    publish_sha=$(git rev-parse --verify "$publish_sha^{commit}" 2>/dev/null) || die "unknown commit: $publish_sha"
    heavy_run "$publish_sha"
    return
  fi
  if [ "$update" = true ]; then
    [ "$argc" -eq 1 ] || usage
    root=$(git rev-parse --show-toplevel) || die "not inside a git repository"
    # Each baseline that exists is rewritten; with neither, the architecture message says it cannot create one.
    if [ -f "$root/$RATCHET_FILE" ]; then
      ratchet_update || urc=1
      [ ! -f "$root/.claude/architecture-baseline.json" ] || architecture_check --update-baseline || urc=1
    else
      architecture_check --update-baseline || urc=1
    fi
    return "$urc"
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
  tier_errors=$(check_tier_errors "$file")
  [ -z "$tier_errors" ] || { rm -f "$scope"; die "$tier_errors"; }
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
  # The code rules of the project's packs run on the diff (#720), after the dependency audit's steps.
  if rules_enabled "$root"; then
    names+=("code rules")
    cmds+=("$(printf '%q' "$SELF") rules-check")
  fi
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
  # The journeys of the accepted specs, before the e2e check (#795).
  if [ "$(journeys_specs "$root" | jq 'length')" -gt 0 ]; then
    names+=("journeys")
    cmds+=("SENIOR_MODE_OUTER_TMPDIR=$(printf '%q' "${TMPDIR:-/tmp}") $(printf '%q' "$SELF") journeys-check")
    [ "$all" = false ] || cmds[${#cmds[@]}-1]+=" --all"
  fi
  if [ "$(config_get commit.coAuthor 2>/dev/null)" = false ]; then
    names+=("commit trailers")
    cmds+=("$(printf '%q' "$SELF") commit-trailers")
  fi
  if [ "$(config_get architecture.rules 2>/dev/null || echo '[]')" != "[]" ]; then
    names+=("architecture")
    cmds+=("$(printf '%q' "$SELF") architecture-check")
  fi
  # The ratchet of lint and coverage, once the project has a baseline (#420).
  if [ -f "$root/$RATCHET_FILE" ]; then
    names+=("ratchet")
    cmds+=("$(printf '%q' "$SELF") ratchet-check")
  fi
  # docs/architecture.md is compared with the map once it holds the generated block (#347).
  if grep -qE '^<!-- senior-mode:architecture sha=[0-9a-f]+ -->$' "$root/docs/architecture.md" 2>/dev/null; then
    names+=("architecture.md")
    cmds+=("$(printf '%q' "$SELF") architecture --check")
  fi
  # A foreign key with no index, when the branch changes a Prisma schema or a SQL migration (#744).
  if fk_applies; then
    names+=("foreign keys")
    cmds+=("$(printf '%q' "$SELF") fk-check")
  fi
  # The linter of the migrations, when the branch adds or changes one (#747).
  if [ -n "$(migrations_changed)" ]; then
    names+=("migrations")
    cmds+=("$(printf '%q' "$SELF") migrations-check")
  fi
  # Each hot path of a spec the diff falls under has a benchmark (#758).
  if [ -n "$(hot_touched spec)" ]; then
    names+=("hot paths")
    cmds+=("$(printf '%q' "$SELF") hot-paths-check")
  fi
  if [ "$run2" = false ]; then
    names=()
    cmds=()
  fi
  # The benchmarks of the hot paths the diff touches, compared with the base (#761).
  if [ "$run3" = true ] && [ -n "$(hot_touched path)" ]; then
    names+=("perf")
    cmds+=("$(printf '%q' "$SELF") perf-check")
  fi
  nbuiltin=${#names[@]}
  bases=("${names[@]}")
  if [ "$changed" = true ]; then
    if changed_list=$(changed_files "$root"); then
      preset=$(project_preset "$root")
      # The checks that narrow themselves to the paths of a push read them from here as well (#827), deleted files included.
      if changed_scope=$(mktemp) && changed_files "$root" deleted >"$changed_scope"; then
        export SENIOR_MODE_CHANGED_FILES=$changed_scope
      else
        rm -f "$changed_scope"
        changed_scope=""
      fi
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
    tier=$(jq -r ".checks[$i].tier // 2" "$file")
    if [ "$tier" = 3 ] && [ "$run3" = false ]; then
      echo "heavy: $name runs after the push"
      continue
    fi
    [ "$tier" = 3 ] || [ "$run2" = true ] || continue
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
      [[ $vc == *'{files}'* ]] || { rm -f "$changed_scope"; die "checks[$i].changed ($name) must hold the {files} placeholder"; }
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
    # A check that declares `inputs` is skipped when an earlier success had the same key (#479). A run narrowed to the
    # changed paths, or a `changed` variant, proves less than a full one: it neither reads nor writes the cache.
    ckey=""
    if [ "$no_cache" = false ] && [ "$i" -ge "$nbuiltin" ] && [ -z "${SENIOR_MODE_CHANGED_FILES:-}" ] && [ -z "${variant[$i]:-}" ]; then
      inp=$(jq -c --arg n "${bases[i]}" '[.checks[]? | select(.name == $n) | .inputs // empty][0] // empty' "$file")
      [ -z "$inp" ] || ckey=$(check_cache_key "${bases[i]}" "$cmd" "$inp" "$file" "$root") || ckey=""
      cdir=$(check_cache_dir) || ckey=""
    fi
    if [ -n "$ckey" ] && [ -f "$cdir/$ckey" ]; then
      passed=$((passed + 1))
      echo "ok    $label (cached)"
      continue
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
      # Only a success is kept.
      if [ -n "$ckey" ] && mkdir -p "$cdir" 2>/dev/null; then
        printf '%s\n' "$name" >"$cdir/$ckey.$$" && mv -f "$cdir/$ckey.$$" "$cdir/$ckey"
      fi
      # A warning of a passing check (an advisory with no severity, a rule turned off) is shown, not lost.
      { grep -E '^(warning: |off  )' "$output" || true; } | sed 's/^/      /'
      fl=$(sed -n 's/^warning: flaky: \([^ ]*\) .*/\1/p' "$output" | paste -sd, -)
      [ -z "$fl" ] || flaky+="${flaky:+,}$fl"
    else
      took=$(since_ms "$started")
      failed="${failed:+$failed, }$name"
      echo "FAIL  $label ($took)"
      # The audit lists every blocking advisory (it caps them itself); another check shows one line per finding, else its last lines.
      if [ "$name" = "dependency audit" ]; then
        tail -n 300 "$output" | sed 's/^/      /'
      else
        check_findings "$output" "${bases[i]}" "$(jq -r --arg n "${bases[i]}" '[.checks[]? | select(.name == $n) | .fix // empty][0] // empty' "$file")"
      fi
      log=$(check_log_keep "$name" "$output")
      [ -z "$log" ] || echo "      full log: $log"
    fi
  done
  rm -rf "$rundir"
  rm -f "$scope" "$changed_scope"
  free=""
  if [ "$run2" = true ]; then
    spec_drift_warn
    suppressions_warn
    # An added test case with no assertion (#306): a warning locally, an error in a run or serve session.
    free=$(assertion_free_tests)
  fi
  if [ -n "$free" ] && [ "${SENIOR_MODE_RUN:-}" = 1 ]; then
    echo "FAIL  assertion-free tests (a test case that asserts nothing proves nothing)"
    sed 's/^/      /' <<<"$free"
    failed="${failed:+$failed, }assertion-free tests"
  elif [ -n "$free" ]; then
    sed 's/^/warn  test case with no assertion: /' <<<"$free"
  fi
  if [ -z "$failed" ]; then
    state=success description="$passed/$count checks passed${flaky:+; flaky: $flaky}"
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
  if [ "$run2" = false ]; then
    echo "note: tier 3 run, result not recorded for publishing"
  elif [ -n "$scope" ]; then
    echo "note: narrowed to the pushed paths, result not recorded for publishing"
  elif [ "$changed" = true ]; then
    echo "note: --changed run, result not recorded for publishing"
  elif [ -z "$(worktree_status)" ]; then
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
  heavy_start "$sha"
  ui_report "$sha"
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
