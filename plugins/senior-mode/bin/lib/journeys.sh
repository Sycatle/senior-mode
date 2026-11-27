# shellcheck shell=bash
# User journeys declared in the front matter of the accepted specs (spec 328 section 5, ADR 0025): the `journeys` step of `check`.

# The accepted specs that declare journeys, as JSON: [{spec, id, globs, journeys: [{id, test}]}]. $1 is the repository root.
# A journey is one line of the `journeys:` list, `- { id: J1, name: "...", test: "e2e/x.spec.ts" }`; `globs` are the `paths` of the spec.
# shellcheck disable=SC2016 # a jq program, not shell
journeys_specs() {
  local root=$1 spec fm status sid globs line jid jtest rows="" re_id re_test
  re_id='[{,][[:space:]]*id:[[:space:]]*"?([^",}]*)"?'
  re_test='[{,][[:space:]]*test:[[:space:]]*"?([^",}]*)"?'
  while IFS= read -r spec; do
    fm=$(awk 'NR == 1 && $0 != "---" { exit } NR > 1 && $0 == "---" { exit } NR > 1 { print }' "$root/$spec" 2>/dev/null) || continue
    status=$(sed -n 's/^status:[[:space:]]*//p' <<<"$fm" | tr -d "\"' \r")
    [ "$status" = accepted ] || continue
    sid=$(sed -n 's/^id:[[:space:]]*//p' <<<"$fm" | tr -d "\"'\r" | head -n 1)
    [ -n "$sid" ] || sid=$(basename "$spec" .md)
    globs=$(sed -n 's/^paths:[[:space:]]*\[\(.*\)\][[:space:]]*$/\1/p' <<<"$fm" | tr -d "\"'\r" |
      jq -Rc 'split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))')
    while IFS= read -r line; do
      [[ $line =~ ^[[:space:]]*-[[:space:]]*\{ ]] || continue
      jid="" jtest=""
      [[ $line =~ $re_id ]] && jid=${BASH_REMATCH[1]}
      [[ $line =~ $re_test ]] && jtest=${BASH_REMATCH[1]}
      rows+=$(printf '%s\t%s\t%s\t%s\t%s' "$spec" "$sid" "${globs:-[]}" "$jid" "$jtest")$'\n'
    done < <(awk '/^journeys:/ { on = 1; next } on && /^[^[:space:]-]/ { on = 0 } on' <<<"$fm")
  done < <(git -C "$root" ls-files --cached --others --exclude-standard -- 'docs/specs/*.md')
  jq -Rsc 'split("\n") | map(select(length > 0) | split("\t")) | group_by(.[0])
    | map({spec: .[0][0], id: .[0][1], globs: (.[0][2] | fromjson), journeys: map({id: .[3], test: .[4]})})' <<<"$rows"
}

# The declaration errors of the specs JSON $1, one per line naming the spec: a journey with no id, an id declared twice,
# a test that is empty, absolute or has a `..` segment.
# shellcheck disable=SC2016 # a jq program, not shell
journeys_errors() {
  jq -r '.[] | .id as $s | .journeys as $j
    | ($j[] | select(.id == "") | "spec \($s): a journey has no id"),
      ($j | group_by(.id)[] | select(length > 1 and .[0].id != "") | "spec \($s): journey \(.[0].id) is declared twice"),
      ($j[] | select(.id != "" and (.test == "" or (.test | startswith("/")) or (.test | test("(^|/)\\.\\.(/|$)"))))
        | "spec \($s): journey \(.id) test \(.test | tojson) must be a relative path with no ..")' <<<"$1"
}

# The journeys the diff selects, as `<spec id><TAB><journey id><TAB><test file>` rows: those of a spec when a changed file matches
# a glob of its `paths`, and a journey whose test file changed. $1 is the repository root, $2 the specs JSON, $3 `true` for every
# journey (`check --all`). When the changed files cannot be told (no default branch), every journey is selected.
journeys_select() {
  local root=$1 specs=$2 all=${3:-false} changed="" s globs hit
  if [ "$all" = false ] && ! changed=$(changed_files "$root"); then
    echo "note: journeys: the changed files cannot be told, every journey is selected" >&2
    all=true
  fi
  while IFS= read -r s; do
    globs=$(jq -c '.globs' <<<"$s")
    hit=false
    if [ "$all" = true ]; then
      hit=true
    elif [ "$globs" != "[]" ] && [ -n "$changed" ] && [ -n "$(protected_match "$globs" <<<"$changed" | head -n 1)" ]; then
      hit=true
    fi
    while IFS=$'\t' read -r sid jid jtest; do
      if [ "$hit" = true ] || grep -qxF -- "$jtest" <<<"$changed"; then
        printf '%s\t%s\t%s\n' "$sid" "$jid" "$jtest"
      fi
    done < <(jq -r '.id as $s | .journeys[] | [$s, .id, .test] | @tsv' <<<"$s")
  done < <(jq -c '.[]' <<<"$specs")
}

# Whether the test file $2 (from the root $1) exists and carries the journey id $3 as a word in it, a test title.
journey_has_test() {
  [ -f "$1/$2" ] && grep -qE "(^|[^[:alnum:]_])$3([^[:alnum:]_]|\$)" "$1/$2"
}

# Runs the command $1 under the `e2e` lock, as the check named e2e does: the lock is machine-wide, so it is taken with the TMPDIR
# `check` had before it gave the step a private one (SENIOR_MODE_OUTER_TMPDIR), and the command gets the private one back.
journeys_exec() {
  TMPDIR=${SENIOR_MODE_OUTER_TMPDIR:-${TMPDIR:-/tmp}} "$SELF" e2e-lock -- env TMPDIR="${TMPDIR:-/tmp}" bash -c "$1"
}

# One `warning: flaky: <id>` line per journey of the test files $@ (JOURNEYS_OF), what `check` puts in its summary.
# Each is also appended to .git/senior-mode/journeys-flaky.jsonl, which `retro` counts.
journeys_flaky() {
  local f id common log
  common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) && log=$common/senior-mode/journeys-flaky.jsonl || log=""
  for f in "$@"; do
    for id in ${JOURNEYS_OF[$f]//,/}; do
      printf 'warning: flaky: %s (passed on the second run)\n' "$id"
      [ -z "$log" ] || { mkdir -p "${log%/*}" && jq -nc --arg ts "$(iso_time "$(date +%s)")" --arg j "$id" '{ts: $ts, journey: $j}' >>"$log"; } 2>/dev/null || true
    done
  done
}

# Runs the test files $2... of the journeys through the e2e command $1 (spec 328 section 5.2, steps 3 and 4); the array JOURNEYS_OF maps
# each file to the ids of its journeys. With `{files}` in the command it gets the files, else the whole suite runs
# once. A run that fails is run once more: one file at a time when the command takes files (a file that fails alone fails the
# check; when none does, the run was flaky and every file of it is reported), the same command again otherwise. A pass on the
# second run prints `warning: flaky: J1`, a second failure prints `journey J1 failed: <file>` and returns 1.
journeys_run() {
  local cmd=$1 f ids failed=() rc=0 with_files=false
  shift
  [[ $cmd == *'{files}'* ]] && with_files=true
  if [ "$with_files" = true ]; then
    journeys_exec "$(files_subst "$cmd" "$@")" && return 0
    for f in "$@"; do
      journeys_exec "$(files_subst "$cmd" "$f")" || failed+=("$f")
    done
    if [ "${#failed[@]}" -eq 0 ]; then
      journeys_flaky "$@"
      return 0
    fi
  else
    journeys_exec "$cmd" && return 0
    if journeys_exec "$cmd"; then
      journeys_flaky "$@"
      return 0
    fi
    failed=("$@")
  fi
  for f in "${failed[@]}"; do
    ids=${JOURNEYS_OF[$f]}
    printf 'journey %s failed: %s\n' "$ids" "$f"
  done
  return 1
}

# `senior-mode journeys-check [--all]`: the `journeys` step of `check` (spec 328 section 5.2). The accepted specs' declarations are
# validated; the journeys the diff selects must each have their test file with the journey id in it. `journeys.required: false`
# turns a missing test into a warning.
journeys_check() {
  local all=false root specs errors required=true sel sid jid jtest msg rc=0 e2e
  local -a files=()
  local -A JOURNEYS_OF=()
  case ${1:-} in
    "") ;;
    --all) all=true ;;
    *) usage ;;
  esac
  root=$(git rev-parse --show-toplevel) || die "not inside a git repository"
  specs=$(journeys_specs "$root")
  errors=$(journeys_errors "$specs")
  if [ -n "$errors" ]; then
    echo "$errors"
    return 1
  fi
  [ "$(config_get journeys.required 2>/dev/null || echo true)" != false ] || required=false
  sel=$(journeys_select "$root" "$specs" "$all")
  if [ -z "$sel" ]; then
    echo "skipped: no journey on the touched paths"
    return 0
  fi
  while IFS=$'\t' read -r sid jid jtest; do
    if journey_has_test "$root" "$jtest" "$jid"; then
      [ -n "${JOURNEYS_OF[$jtest]:-}" ] || files+=("$jtest")
      JOURNEYS_OF[$jtest]+="${JOURNEYS_OF[$jtest]:+, }$jid"
      continue
    fi
    msg="journey $jid of spec $sid has no test at $jtest"
    if [ "$required" = true ]; then
      echo "$msg"
      rc=1
    else
      echo "warning: $msg"
    fi
  done <<<"$sel"
  [ "$rc" -eq 0 ] || return 1
  [ "${#files[@]}" -gt 0 ] || return 0
  e2e=$(config_get commands.e2e 2>/dev/null) || e2e=""
  if [ -z "$e2e" ]; then
    echo "journeys declared and no e2e command: senior-mode setup repo --command e2e=..."
    return 1
  fi
  (cd "$root" && journeys_run "$e2e" "${files[@]}")
}

# Whether the test file $3 carries the journey id $4 as it is on the base ref $2 (the working tree when $2 is empty); $1 is the root.
journey_test_at() {
  local text
  if [ -n "$2" ]; then
    text=$(git -C "$1" show "$2:$3" 2>/dev/null) || return 1
  else
    text=$(cat "$1/$3" 2>/dev/null) || return 1
  fi
  grep -qE "(^|[^[:alnum:]_])$4([^[:alnum:]_]|\$)" <<<"$text"
}

# The state of the journeys of the accepted specs, as JSON (spec 328 section 5.2, kept up to date): `declared`, `withTest` (those
# whose test file is on the base branch with the id in it), `missingTests` [{spec, id, test}], `noPaths` [{spec, id}] (a journey whose
# spec `paths` match no tracked file) and `orphans` [{id, file}] (a test title of an e2e file with a `J<n>` id that no spec declares;
# looked for only once a journey is declared). $1 is the repository root. Declared 0 and nothing else: a project with no journeys.
# shellcheck disable=SC2016 # a jq program, not shell
journeys_report() {
  local root=$1 specs base="" s globs files hits pattern q=$'"\'`' sid jid jtest missing="" nopaths="" orphans="" with=0 declared=0 ids
  local -a tfiles=()
  specs=$(journeys_specs "$root")
  [ "$specs" != "[]" ] || {
    echo '{"declared":0,"withTest":0,"missingTests":[],"noPaths":[],"orphans":[]}'
    return 0
  }
  base=$(cd "$root" && default_branch 2>/dev/null) || base=""
  files=$(git -C "$root" ls-files)
  while IFS= read -r s; do
    globs=$(jq -c '.globs' <<<"$s")
    sid=$(jq -r '.id' <<<"$s")
    hits=""
    [ "$globs" = "[]" ] || [ -z "$files" ] || hits=$(protected_match "$globs" <<<"$files" | head -n 1)
    while IFS=$'\t' read -r jid jtest; do
      declared=$((declared + 1))
      if journey_test_at "$root" "$base" "$jtest" "$jid"; then
        with=$((with + 1))
      else
        missing+=$(printf '%s\t%s\t%s' "$sid" "$jid" "$jtest")$'\n'
      fi
      [ -n "$hits" ] || nopaths+=$(printf '%s\t%s' "$sid" "$jid")$'\n'
    done < <(jq -r '.journeys[] | [.id, .test] | @tsv' <<<"$s")
  done < <(jq -c '.[]' <<<"$specs")
  ids=$(jq -c '[.[].journeys[].id]' <<<"$specs")
  mapfile -t tfiles < <(grep -E '(^|/)(e2e|cypress|playwright)/|\.(spec|test|cy)\.[cm]?[jt]sx?$' <<<"$files" | head -n 300)
  if [ "${#tfiles[@]}" -gt 0 ]; then
    pattern="(test|it|describe)(\.[a-z]+)?\([[:space:]]*[$q]([^$q]*[^[:alnum:]_$q])?J[0-9]+"
    orphans=$(cd "$root" && grep -HoE -- "$pattern" "${tfiles[@]}" 2>/dev/null | sed -E 's/^([^:]+):.*(J[0-9]+)$/\2\t\1/' | sort -u) || orphans=""
  fi
  jq -nc --argjson d "$declared" --argjson w "$with" --argjson ids "$ids" --arg m "$missing" --arg n "$nopaths" --arg o "$orphans" '
    def rows($t): $t | split("\n") | map(select(length > 0) | split("\t"));
    {declared: $d, withTest: $w,
     missingTests: [rows($m)[] | {spec: .[0], id: .[1], test: .[2]}],
     noPaths: [rows($n)[] | {spec: .[0], id: .[1]}],
     orphans: [rows($o)[] | select(.[0] as $i | $ids | index($i) | not) | {id: .[0], file: .[1]}]}'
}

# The `journeys` block of the retro data $1 (`senior-mode retro`): the journeys declared, those with a test and the flaky runs
# of the period, from the git common dir $2 and the period $3 (start) and $4 (end, or empty). Nothing is added to a project with
# no journeys and no flaky run.
# shellcheck disable=SC2016 # a jq program, not shell
retro_journeys() {
  local top report flaky
  top=$(git rev-parse --show-toplevel 2>/dev/null) || {
    printf '%s\n' "$1"
    return 0
  }
  report=$(journeys_report "$top")
  flaky=$([ ! -f "$2/senior-mode/journeys-flaky.jsonl" ] || jq -cR 'fromjson? | select(type == "object")' "$2/senior-mode/journeys-flaky.jsonl" 2>/dev/null |
    jq -sc --arg since "$3" --arg until "${4:-9999}" '[.[] | select((.ts | type) == "string" and .ts >= $since and .ts < $until)] | length')
  jq -c --argjson r "$report" --argjson f "${flaky:-0}" 'if $r.declared == 0 and $f == 0 then . else
    . + {journeys: {declared: $r.declared, withTest: $r.withTest, flaky: $f}} end' <<<"$1"
}

# shellcheck disable=SC2016 # a jq program, not shell
RETRO_JOURNEYS_TEXT_JQ='(.journeys // empty) | "Journeys: \(.declared) declared, \(.withTest) with a test, \(.flaky) flaky in the period"'
