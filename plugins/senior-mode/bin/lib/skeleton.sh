# shellcheck shell=bash
# Red test skeletons (#311): the Given/When/Then criteria of a ticket become failing tests when it is started,
# and the ticket is not ready while one is still unimplemented or skipped.

# What a skeleton still holds when it is not finished: its own marker, or a test switched off.
SKELETON_OPEN_RE='not implemented|\.(skip|todo)\(|(^|[^[:alnum:]_.])x(it|describe)\(|pytest\.(mark\.skip|mark\.xfail|skip)|t\.Skip|#\[ignore|unimplemented!|todo!'

# The Given/When/Then criteria of an issue body $1, one per line: the bullets (`-`, `*`, `1.`, with or without a
# checkbox) that start with "Given", their indented continuation lines folded in. Fenced code is not read.
skeleton_criteria() {
  awk '
    function flush() { if (cur != "") print cur; cur = "" }
    /^[[:space:]]*(```|~~~)/ { flush(); fence = !fence; next }
    fence { next }
    /^[[:space:]]*([-*]|[0-9]+[.)])[[:space:]]+/ {
      flush()
      line = $0
      sub(/^[[:space:]]*([-*]|[0-9]+[.)])[[:space:]]+(\[[ xX]\][[:space:]]+)?/, "", line)
      if (tolower(substr(line, 1, 6)) == "given ") cur = line
      next
    }
    cur != "" && /^[[:space:]]+[^[:space:]]/ { line = $0; sub(/^[[:space:]]+/, "", line); cur = cur " " line; next }
    { flush() }
    END { flush() }' <<<"$1" | sed -E 's/[[:space:]]+/ /g; s/[[:space:]]+$//'
}

# The file of the skeleton of ticket $2 for the preset $1, from the repository root. Its name carries the ticket
# (ticket-<n>, ticket_<n>), which is how `ready` finds it again; every name is a test file of the preset.
skeleton_file() {
  case $1 in
    node) echo "tests/ticket-$2.test.${3:-js}" ;;
    python) echo "tests/test_ticket_$2.py" ;;
    go) echo "tests/ticket_${2}_test.go" ;;
    rust) echo "tests/ticket_$2.rs" ;;
    *) echo "tests/test-ticket-$2.sh" ;;
  esac
}

# The text of the skeleton of ticket $2 for the preset $1 ($3 is ts for vitest, js otherwise), the criteria on
# stdin one per line. Each case fails with "not implemented" and is named after its criterion.
skeleton_render() {
  local preset=$1 n=$2 ext=$3 k=0 c s head="Red skeleton of #$2: one case per acceptance criterion. Replace each body with a real test; the ticket is not ready while one says \"not implemented\" or is skipped."
  case $preset in
    node)
      echo "// $head"
      [ "$ext" != ts ] || echo 'import { expect, it } from "vitest";'
      ;;
    python) echo "# $head" ;;
    go)
      echo "// $head"
      printf '\npackage tests\n\nimport "testing"\n'
      ;;
    rust) echo "// $head" ;;
    *)
      printf '#!/usr/bin/env bash\n# %s\nset -u\nfailures=0\nskeleton() { echo "FAIL: $1: not implemented"; failures=$((failures + 1)); }\n' "$head"
      ;;
  esac
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    k=$((k + 1))
    s=$(slugify "$c" | tr -- - _)
    s=${s:-criterion}
    case $preset in
      node) printf '\nit(%s, () => {\n  expect("not implemented").toBe("implemented");\n});\n' "$(jq -nr --arg s "$c" '$s | @json')" ;;
      python) printf '\n\ndef test_ticket%s_%s_%s():\n    # %s\n    assert False, "not implemented"\n' "$n" "$k" "$s" "$c" ;;
      go) printf '\n// %s\nfunc TestTicket%s_%s_%s(t *testing.T) {\n\tt.Fatal("not implemented")\n}\n' "$c" "$n" "$k" "$s" ;;
      rust) printf '\n// %s\n#[test]\nfn ticket_%s_%s_%s() {\n    panic!("not implemented");\n}\n' "$c" "$n" "$k" "$s" ;;
      *) printf '\n# %s\nskeleton %q\n' "$c" "$c" ;;
    esac
  done
  case $preset in node | python | go | rust) ;; *) printf '\nexit "$failures"\n' ;; esac
}

# The first commit of a ticket branch (#311): the skeleton of the criteria of the body $2 of ticket $1, written and
# committed in the worktree $3. A body with no Given/When/Then criterion, or a skeleton already there, changes
# nothing. A commit that fails (a hook of the project) leaves no file behind; it is said and never stops `start`.
skeleton_commit() {
  local n=$1 body=$2 wt=$3 criteria preset ext=js file count
  criteria=$(skeleton_criteria "$body")
  [ -n "$criteria" ] || return 0
  preset=$(project_preset "$wt")
  if [ "$preset" = node ] && grep -q '"vitest"' "$wt/package.json" 2>/dev/null; then ext=ts; fi
  file=$(skeleton_file "$preset" "$n" "$ext")
  [ ! -e "$wt/$file" ] || return 0
  mkdir -p "$wt/$(dirname "$file")"
  skeleton_render "$preset" "$n" "$ext" <<<"$criteria" >"$wt/$file"
  case $preset in node | python | go | rust) ;; *) chmod +x "$wt/$file" ;; esac
  count=$(grep -c . <<<"$criteria")
  if git -C "$wt" add -- "$file" && git -C "$wt" commit -q -m "test: red skeletons for the acceptance criteria of #$n" -m "Refs #$n" >/dev/null 2>&1; then
    echo "skeleton $file ($count failing case$([ "$count" = 1 ] || echo s), first commit)"
  else
    git -C "$wt" reset -q -- "$file" 2>/dev/null || true
    rm -f "$wt/$file"
    echo "senior-mode: could not commit the test skeletons of #$n; write the tests from its criteria" >&2
  fi
}

# What stops the pull request $2 of $1 (owner/name) from being ready on account of the red skeletons of the tickets it
# closes (#311), or nothing: a file of the pull request named after a ticket (ticket-<n>, ticket_<n>) that still holds
# "not implemented" or a skipped test. $3 is its REST object and $4 its changed files as `<path>\t<lines>` lines.
# Starts with "not ready: " when the pull request is at fault; other phrases say what could not be read.
skeleton_blocker() {
  local slug=$1 pr=$2 pull=$3 files=$4 n f sha text open="" err
  sha=$(jq -r '.head.sha // empty' <<<"$pull")
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      [[ ${f##*/} =~ ticket[-_]${n}([^0-9]|$) ]] || continue
      [ -n "$sha" ] || {
        echo "the head of pull request #$pr could not be read"
        return 0
      }
      # A file the head no longer has (HTTP 404) is not a skeleton any more.
      if ! text=$(gh_retry api -H "Accept: application/vnd.github.raw" "repos/$slug/contents/$f?ref=$sha" 2>&1); then
        err=$text
        [[ $err == *404* ]] || {
          echo "$f could not be read"
          return 0
        }
        continue
      fi
      ! grep -qE "$SKELETON_OPEN_RE" <<<"$text" || open+=${open:+, }"$f (#$n)"
    done < <(cut -f1 <<<"$files")
  done < <(pr_closed_tickets "$(jq -r '.body // ""' <<<"$pull")")
  [ -z "$open" ] || echo "not ready: a red skeleton is still unimplemented or skipped in $open: write the test, or remove the case if its criterion went"
}

# The text the spec $2 (from the root $1) tells of the journey $3: under "Users and journeys", the heading that names
# its id down to the next heading, or the paragraph that does. At most 20 lines.
skeleton_journey_text() {
  awk -v id="$3" '
    function has(l) { return l ~ ("(^|[^[:alnum:]_])" id "([^[:alnum:]_]|$)") }
    /^##[[:space:]]/ { if (out) exit; sec = ($0 ~ /^##[[:space:]]+Users and journeys/); next }
    !sec { next }
    /^#+[[:space:]]/ { if (out) exit; if (has($0)) { out = 1; mode = "h"; print }; next }
    out && mode == "p" && /^[[:space:]]*$/ { exit }
    out { print; next }
    has($0) { out = 1; mode = "p"; print }' "$1/$2" 2>/dev/null | sed -E 's/[[:space:]]+$//' | cat -s | head -n 20
}

# The journeys (spec 328 section 5.3, #464) of the accepted specs whose `paths` overlap the Paths $2 (a JSON array of
# globs) of a ticket, as JSON: [{spec, sid, id, name, test, exists, text}]. $1 is the repository root. `exists` says
# whether the test file is there: in the tree of the ref $3 when there is one, else in the working tree. An empty list
# when the ticket has no Paths or no spec declares a journey on them.
skeleton_journeys() {
  local root=$1 tp=$2 ref=${3:-} spec sid jid test line name exists text out="[]"
  declare -F journeys_specs >/dev/null || {
    echo "[]"
    return 0
  }
  while IFS=$'\t' read -r spec sid jid test; do
    [ -n "$jid" ] || continue
    name=$jid
    line=$(grep -E "[{,][[:space:]]*id:[[:space:]]*\"?$jid\"?[[:space:],}]" "$root/$spec" 2>/dev/null | head -n 1) || line=""
    if [[ $line =~ name:[[:space:]]*\"([^\"]*)\" ]] || [[ $line =~ name:[[:space:]]*([^,\"}]*[^,\"}[:space:]]) ]]; then name=${BASH_REMATCH[1]}; fi
    if [ -n "$ref" ]; then
      git -C "$root" cat-file -e "$ref:$test" 2>/dev/null && exists=true || exists=false
    else
      [ -f "$root/$test" ] && exists=true || exists=false
    fi
    text=$(skeleton_journey_text "$root" "$spec" "$jid")
    out=$(jq -c --arg spec "$spec" --arg sid "$sid" --arg id "$jid" --arg name "$name" --arg test "$test" --argjson exists "$exists" --arg text "$text" \
      '. + [{spec: $spec, sid: $sid, id: $id, name: $name, test: $test, exists: $exists, text: $text}]' <<<"$out")
  done < <(jq -r --argjson tp "$tp" "$PATHS_DEF"'.[] | select(overlap($tp; .globs)) | .spec as $s | .id as $i | .journeys[] | [$s, $i, .id, .test] | @tsv' \
    <<<"$(journeys_specs "$root")")
  printf '%s\n' "$out"
}

# What the test-author is told of the journeys JSON $1: each one with its name, its text and its test file, to be written
# from the journey and not from the code, red first. Nothing when there is none.
# shellcheck disable=SC2016 # a jq program, not shell
skeleton_journeys_brief() {
  jq -r 'if length == 0 then empty else
    "Journeys of this ticket (E2E tests, spec 328 section 5.3): write each test first, from the journey as its spec tells it and not from the code, run it and see it fail for the missing behaviour, and commit it with the other tests:",
    (.[] | "- \(.id) \"\(.name)\" (spec \(.sid)), test file \(.test), "
      + (if .exists then "exists: edit only if the criteria change the journey" else "missing: write it" end)
      + (if .text == "" then "" else "\n" + (.text | split("\n") | map("    " + .) | join("\n")) end)) end' <<<"$1"
}

# The journeys of ticket $1 as a prompt reads them (#464), nothing when the ticket has none or the board does not
# answer: `brief` is the test-author block, `readonly` the sentence that keeps the implementer off the E2E tests.
skeleton_journeys_prompt() {
  local root tp js files
  root=$(git rev-parse --show-toplevel 2>/dev/null) || return 0
  tp=$(context_board "$root" "$1" 2>/dev/null | jq -c '.paths // empty' 2>/dev/null) || return 0
  [ -n "$tp" ] || return 0
  js=$(skeleton_journeys "$root" "$tp") || return 0
  case ${2:-} in
    brief) skeleton_journeys_brief "$js" ;;
    readonly)
      files=$(jq -r 'map(.test) | join(", ")' <<<"$js")
      [ -z "$files" ] || echo "The E2E test of a journey ($files) is read-only for you, like the other red tests: make it pass, never edit it."
      ;;
  esac
}
