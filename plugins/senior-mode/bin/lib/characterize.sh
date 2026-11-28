# shellcheck shell=bash
# Characterization tests (#422, spec 409 section 6): before an agent changes code that has no tests, it pins what the code does
# today, in a first commit `test(<scope>): characterize <unit>` that passes on the unmodified code. `untested` lists the files
# that need it, `start` says which ones, `untested --check` and `ready` refuse a branch that skips it or edits what it pinned.

CHARACTERIZE_CODE_RE='\.(c|cc|cpp|cs|go|h|hpp|java|js|jsx|kt|mjs|cjs|php|py|rb|rs|sh|swift|ts|tsx)$'
CHARACTERIZE_SUBJECT_RE='^test(\([^)]*\))?: characterize '

# Why the file $2 needs no characterization (preset $1; $3 the `characterize.exempt` globs as JSON), or nothing: docs, what is
# not source code, a test, a generated file, types or constants with no logic, a glob of the project.
characterize_exempt() {
  local preset=$1 f=$2 base=${2##*/} g
  if [[ $f == docs/* || $base == *.md ]]; then echo "docs"; return 0; fi
  if ! [[ $base =~ $CHARACTERIZE_CODE_RE ]]; then echo "not source code"; return 0; fi
  if test_file "$preset" "$f"; then echo "a test file"; return 0; fi
  if ! diff_countable "$f"; then echo "generated file"; return 0; fi
  case ${base,,} in
    *.d.ts | types.* | type.* | *.types.* | constants.* | consts.* | *.constants.* | enums.* | *.enum.*)
      echo "types or constants, no logic"
      return 0
      ;;
  esac
  while IFS= read -r g; do
    # shellcheck disable=SC2053 # $g is a glob
    if [ -n "$g" ] && [[ $f == $g ]]; then echo "characterize.exempt ($g)"; return 0; fi
  done < <(jq -r 'if type == "array" then .[] | strings else empty end' <<<"$3" 2>/dev/null)
  return 1
}

# The coverage of the file $2 in the ratchet baseline of the ref $1 (percent), nothing when the baseline has none.
characterize_coverage() {
  git show "$1:.claude/ratchet-baseline.json" 2>/dev/null | jq -r --arg f "$2" '.coverage.files[$f] // empty' 2>/dev/null || true
}

# Whether a test file of the ref $1 (preset $2) mentions the unit of the file $3 by name: its path without extension, or its
# base name when that says something (not index, main, mod, lib).
characterize_imported() {
  local ref=$1 preset=$2 f=$3 key stem hit
  stem=${f##*/}
  stem=${stem%.*}
  key=$stem
  case $stem in index | main | mod | lib | __init__) key=$(basename "$(dirname "$f")")/$stem ;; esac
  while IFS= read -r hit; do
    ! test_file "$preset" "${hit#*:}" || return 0
  done < <(git grep -lwF -e "$key" "$ref" 2>/dev/null || true)
  return 1
}

# What the file $2 is for characterization, at the ref $1: `exempt <why>`, `covered <why>` or `untested <why>`.
# $3 the preset, $4 characterize.below, $5 the exempt globs as JSON.
characterize_status() {
  local ref=$1 f=$2 preset=$3 below=$4 why cov
  if why=$(characterize_exempt "$preset" "$f" "$5"); then echo "exempt $why"; return 0; fi
  cov=$(characterize_coverage "$ref" "$f")
  if [[ $cov =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    if awk -v c="$cov" -v b="$below" 'BEGIN { exit !(c + 0 >= b + 0) }'; then
      echo "covered at $cov%"
    else
      echo "untested $cov% covered, under characterize.below ($below%)"
    fi
    return 0
  fi
  if characterize_imported "$ref" "$preset" "$f"; then echo "covered a test mentions it"; else echo "untested no coverage data and no test mentions it"; fi
}

# The commits of base..HEAD whose subject is a characterization one, oldest first, as `<sha> <subject>`.
characterize_commits() {
  git log --reverse --format='%H %s' "$1..HEAD" 2>/dev/null | grep -E "^[0-9a-f]+ ${CHARACTERIZE_SUBJECT_RE#^}" || true
}

# The characterization commit that pins the file $3 before the branch changes it, as `<sha> <subject>`, nothing when none does.
# $1 the base ref, $2 the preset. A commit pins a file when a test file it adds or changes mentions the unit.
characterize_pin() {
  local base=$1 preset=$2 f=$3 stem sha subject t first
  stem=${f##*/}
  stem=${stem%.*}
  first=$(git log --reverse --format=%H "$base..HEAD" -- "$f" 2>/dev/null | head -n 1)
  while read -r sha subject; do
    [ -n "$sha" ] || continue
    [ -z "$first" ] || git merge-base --is-ancestor "$sha" "$first" || continue
    while IFS= read -r t; do
      test_file "$preset" "$t" || continue
      if git show "$sha:$t" 2>/dev/null | grep -qwF -e "$stem"; then
        echo "$sha $subject"
        return 0
      fi
    done < <(git diff-tree --no-commit-id --name-only -r --diff-filter=AM "$sha")
  done < <(characterize_commits "$base")
  return 1
}

# The pinned assertions a later commit of base..HEAD edits (a line of a test file of a characterization commit that is removed
# or changed), as `<short sha> <file>` lines; only for a refactor, a branch with a `refactor` commit: a behaviour change edits
# the assertions its criteria name, which the review reads.
characterize_pinned_edits() {
  local base=$1 preset=$2 first sha subject t
  local -a pinned=()
  git log --format=%s "$base..HEAD" | grep -qE '^refactor(\([^)]*\))?!?: ' || return 0
  first=$(characterize_commits "$base" | head -n 1 | cut -d' ' -f1)
  [ -n "$first" ] || return 0
  while read -r sha subject; do
    while IFS= read -r t; do
      test_file "$preset" "$t" && pinned+=("$t")
    done < <(git diff-tree --no-commit-id --name-only -r --diff-filter=AM "$sha")
  done < <(characterize_commits "$base")
  [ ${#pinned[@]} -gt 0 ] || return 0
  while read -r sha; do
    [ "$sha" != "$first" ] || continue
    git merge-base --is-ancestor "$first" "$sha" || continue
    for t in $(printf '%s\n' "${pinned[@]}" | sort -u); do
      if git diff -U0 --no-color "$sha^" "$sha" -- "$t" 2>/dev/null | grep -qE '^-[^-]|^-$'; then
        echo "$(git rev-parse --short "$sha") $t"
      fi
    done
  done < <(git log --reverse --format=%H "$base..HEAD")
}

# senior-mode untested [--changed] [--check] [<path or glob>...]: the existing files that have no tests and so need a
# characterization commit before they change (spec 409 section 6). The candidates are the files the branch changes (--changed)
# and the tracked files matching the globs; a file with coverage at or above characterize.below (default 50) in the ratchet
# baseline of the base branch, or with no coverage data but a test that mentions it, is covered. Prints `untested <file>: <why>`
# and `exempt <file>: <why>` (docs, generated, types or constants, characterize.exempt), nothing for a covered file. With
# --changed or --check, on a branch with a `refactor(...)` commit, each untested file also says `characterized` (the commit) or
# `missing`; --check fails on a missing one and on a refactor that edits a pinned assertion. A branch with no refactor commit
# (a feature, a bug) needs no characterization commit: its untested files are only listed.
untested() {
  local changed=false check=false a root base preset below exempt f line status why pin bad=0 g refactor=false
  local -a globs=() files=()
  while [ $# -gt 0 ]; do
    a=$1
    shift
    case $a in
      --changed) changed=true ;;
      --check) check=true ;;
      -*) usage ;;
      *) globs+=("$a") ;;
    esac
  done
  [ "$changed" = true ] || [ ${#globs[@]} -gt 0 ] || [ "$check" = true ] || usage
  [ "$check" = false ] || changed=true
  root=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repository"
  cd "$root"
  base=$(default_branch) || base=HEAD
  preset=$(project_preset "$root")
  # Only a refactor must pin what it changes; a feature or a bug changes behaviour, and its own tests say what it should do (ADR 0034).
  ! git log --format=%s "$base..HEAD" 2>/dev/null | grep -qE '^refactor(\([^)]*\))?!?: ' || refactor=true
  below=$(config_get characterize.below 2>/dev/null) || below=50
  [[ $below =~ ^[0-9]+$ ]] || below=50
  exempt=$(config_get characterize.exempt 2>/dev/null) || exempt='[]'
  [ "$changed" != true ] || while IFS= read -r f; do [ -z "$f" ] || files+=("$f"); done < <(changed_files "$root" 2>/dev/null || true)
  for g in ${globs[@]+"${globs[@]}"}; do
    while IFS= read -r f; do [ -z "$f" ] || files+=("$f"); done < <(git ls-files -- ":(glob)$g" "$g" 2>/dev/null | head -n 200)
  done
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    # Code that exists on the base: a new file has nothing to pin.
    git cat-file -e "$base:$f" 2>/dev/null || continue
    line=$(characterize_status "$base" "$f" "$preset" "$below" "$exempt")
    status=${line%% *}
    why=${line#* }
    case $status in
      exempt) echo "exempt $f: $why" ;;
      untested)
        if [ "$changed" = true ] && [ "$refactor" = true ]; then
          if pin=$(characterize_pin "$base" "$preset" "$f"); then
            echo "characterized $f: ${pin%% *} ${pin#* }"
          else
            echo "missing $f: untested ($why) and no commit \`test(<scope>): characterize <unit>\` pins it before it changes"
            bad=1
          fi
        else
          echo "untested $f: $why"
        fi
        ;;
    esac
  done < <(printf '%s\n' ${files[@]+"${files[@]}"} | sort -u)
  if [ "$changed" = true ]; then
    while read -r line; do
      [ -n "$line" ] || continue
      echo "pinned ${line#* }: ${line%% *} edits a pinned assertion in a refactor, which leaves the characterization tests untouched"
      bad=1
    done < <(characterize_pinned_edits "$base" "$preset")
  fi
  [ "$check" = false ] || [ "$bad" -eq 0 ]
}

# What stops the pull request $2 of $1 (owner/name) from being ready on account of a refactor that edits the assertions a
# characterization commit pinned, or nothing (the same rule as `untested --check`, read through the API). $3 is its REST
# object (unused) and $4 its changed files as `<path>\t<lines>` lines. The commits are only read when the pull request
# changes a test file. Starts with "not ready: " when the pull request is at fault.
characterize_blocker() {
  local slug=$1 pr=$2 files=$4 root preset f commits first="" sha subject c edited pinned="[]" bad=""
  root=$(git rev-parse --show-toplevel 2>/dev/null) || root=$PWD
  preset=$(project_preset "$root")
  while IFS= read -r f; do
    [ -z "$f" ] || ! diff_countable "$f" || ! test_file "$preset" "$f" || break
    f=""
  done < <(cut -f1 <<<"$files")
  [ -n "$f" ] || return 0
  commits=$(gh_retry api "repos/$slug/pulls/$pr/commits" --paginate --jq '.[] | [.sha, (.commit.message | split("\n")[0])] | @tsv') || {
    echo "its commits could not be read"
    return 0
  }
  grep -qE $'\trefactor(\\([^)]*\\))?!?: ' <<<"$commits" || return 0
  grep -qE $'\ttest(\\([^)]*\\))?: characterize ' <<<"$commits" || return 0
  while IFS=$'\t' read -r sha subject; do
    if [[ $subject =~ $CHARACTERIZE_SUBJECT_RE ]]; then
      first=${first:-$sha}
      c=$(gh_retry api "repos/$slug/commits/$sha" --jq '[.files[]?.filename]') || {
        echo "the commit $sha could not be read"
        return 0
      }
      pinned=$(jq -c --argjson c "$c" '. + $c | unique' <<<"$pinned")
    elif [ -n "$first" ]; then
      edited=$(gh_retry api "repos/$slug/commits/$sha" --jq '.' | jq -r --argjson p "$pinned" \
        '[.files[]? | select(.filename as $f | $p | index($f)) | select((.patch // "") | test("(^|\n)-")) | .filename] | join(", ")') || {
        echo "the commit $sha could not be read"
        return 0
      }
      [ -z "$edited" ] || bad+=${bad:+, }"${sha:0:7} ($edited)"
    fi
  done <<<"$commits"
  [ -z "$bad" ] || echo "not ready: a refactor edits what a characterization commit pinned: $bad; a refactor leaves the characterization tests as they are (change them in a separate behaviour commit)"
}

# What `start` says of the files the ticket's Paths ($2, a comma separated list of globs, from the worktree $3) will change: the
# untested ones, to be characterized first, and the exempt ones with their reason. Says nothing when there is nothing to say.
characterize_notice() {
  local g out
  local -a globs=()
  while IFS= read -r g; do [ -z "$g" ] || globs+=("$g"); done < <(tr -d "[]\"'" <<<"$2" | tr ', ' '\n\n')
  [ ${#globs[@]} -gt 0 ] || return 0
  out=$(cd "$3" && untested "${globs[@]}" 2>/dev/null) || true
  [ -n "$out" ] || return 0
  printf '%s\n' "$out"
  ! grep -q '^untested ' <<<"$out" ||
    echo "characterize: pin what the untested files do today in a first commit \`test(<scope>): characterize <unit>\`, passing on the unmodified code (skill tdd)"
}
