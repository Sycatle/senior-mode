# shellcheck shell=bash
# The ratchet of legacy code (#420, spec 409 §5): the debt a project already has in lint findings and coverage is
# measured once in `.claude/ratchet-baseline.json` and frozen; code the branch adds or touches meets the bar, and the
# baseline only improves. The architecture rules keep their own baseline (architecture.sh, check.sh).

RATCHET_FILE=.claude/ratchet-baseline.json

# The lint command of the ratchet: `ratchet.lint.command`, else the preset's, in a machine format. Nothing for a
# preset that has none.
ratchet_lint_command() { # root
  local cmd
  cmd=$(config_get ratchet.lint.command 2>/dev/null) || cmd=""
  if [ -z "$cmd" ]; then
    case $(project_preset "$1") in
      node) cmd="npx --no-install eslint . --format json" ;;
      python) cmd="ruff check --output-format json ." ;;
      go) cmd="golangci-lint run --out-format json" ;;
      rust) cmd="cargo clippy --message-format json" ;;
    esac
  fi
  printf '%s\n' "$cmd"
}

# The lint findings of the tree $1 as `file<TAB>rule<TAB>line`, read from the output of the lint command: ESLint,
# ruff, golangci-lint, clippy (JSON lines), or a list of {"file", "rule", "line"} for any other tool. Fails, with the
# reason on stdout, when the output is none of these.
# shellcheck disable=SC2016 # a jq program, not shell
ratchet_lint() {
  local root=$1 cmd out
  cmd=$(ratchet_lint_command "$root")
  [ -n "$cmd" ] || { echo "no lint command with a machine format: set ratchet.lint.command"; return 1; }
  out=$(cd "$root" && bash -c "$cmd" 2>/dev/null) || true
  jq -rs --arg root "$root/" '
    def rel: (if startswith($root) then .[($root | length):] else . end) | ltrimstr("./");
    . as $d
    | (if ($d | length) == 0 then error("empty")
       elif ($d[0] | type) == "array" then
         $d[0][] | if type != "object" then error("shape")
           elif has("messages") then .filePath as $f | .messages[] | [($f | rel), (.ruleId // "parse-error"), .line]
           elif has("filename") and has("code") then [(.filename | rel), (.code // "syntax"), .location.row]
           elif has("file") and has("rule") and has("line") then [(.file | rel), .rule, .line]
           else error("shape") end
       elif ($d[0] | type) == "object" and ($d[0] | has("Issues")) then
         ($d[0].Issues // [])[] | [(.Pos.Filename | rel), .FromLinter, .Pos.Line]
       elif ($d | all(type == "object" and has("reason"))) then
         $d[] | select(.reason == "compiler-message") | .message | select(.code.code != null) | .code.code as $c
           | (.spans[]? | select(.is_primary)) | [(.file_name | rel), $c, .line_start]
       else error("shape") end)
    | @tsv' <<<"$out" 2>/dev/null || { echo "the output of \`$cmd\` is not a lint report in a known machine format: set ratchet.lint.command"; return 1; }
}

# The coverage of the tree $1 as JSON {total, files}, percent of lines from `ratchet.coverage.report` (lcov or
# Cobertura). Fails, with the reason on stdout, when there is none to read.
ratchet_coverage() {
  local root=$1 rep rows
  rep=$(config_get ratchet.coverage.report 2>/dev/null) || rep=""
  [ -n "$rep" ] || { echo "no coverage report: set ratchet.coverage.report"; return 1; }
  [ -f "$root/$rep" ] || { echo "the coverage report $rep does not exist: run the tests with coverage first"; return 1; }
  if grep -q '^SF:' "$root/$rep"; then
    rows=$(awk -v root="$root/" '
      /^SF:/ { f = substr($0, 4); if (index(f, root) == 1) f = substr(f, length(root) + 1); sub(/^\.\//, "", f) }
      /^LF:/ { lf[f] += substr($0, 4) }
      /^LH:/ { lh[f] += substr($0, 4) }
      END {
        for (f in lf) if (lf[f] > 0) { printf "F\t%s\t%.1f\n", f, 100 * lh[f] / lf[f]; tf += lf[f]; th += lh[f] }
        if (tf > 0) printf "T\t%.1f\n", 100 * th / tf
      }' "$root/$rep")
  elif grep -q '<coverage' "$root/$rep"; then
    rows=$(sed 's/>/>\n/g' "$root/$rep" | awk -v root="$root/" '
      function attr(s, n) { if (match(s, "[ \t]" n "=\"[^\"]*\"")) return substr(s, RSTART + length(n) + 3, RLENGTH - length(n) - 4); return "" }
      /<coverage[ \t]/ { r = attr($0, "line-rate"); if (r != "") printf "T\t%.1f\n", 100 * r }
      /<class[ \t]/ { f = attr($0, "filename"); r = attr($0, "line-rate")
        if (f != "" && r != "") { if (index(f, root) == 1) f = substr(f, length(root) + 1); sub(/^\.\//, "", f); printf "F\t%s\t%.1f\n", f, 100 * r } }')
  else
    echo "the coverage report $rep is neither lcov nor Cobertura"
    return 1
  fi
  jq -nRc '[inputs | split("\t")] | {total: ([.[] | select(.[0] == "T") | .[1] | tonumber] | last),
    files: ([.[] | select(.[0] == "F") | {key: .[1], value: (.[2] | tonumber)}] | from_entries)} | select(.total != null)' <<<"$rows" |
    grep . || { echo "the coverage report $rep holds no line coverage"; return 1; }
}

# The serious and critical axe violations of the journey tests as JSON {"<journey>": {"<rule>": n}}, read from the
# reports of the axe helper (presets/node/e2e/axe.ts), one file per journey in `ratchet.a11y.report` (a directory,
# default test-results/a11y). A journey with a report and no violation maps to {}. Fails, with the reason on stdout,
# when there is no report to read.
# shellcheck disable=SC2016 # a jq program, not shell
ratchet_a11y() {
  local root=$1 dir f out='{}'
  dir=$(config_get ratchet.a11y.report 2>/dev/null) || dir=""
  dir=${dir:-test-results/a11y}
  [ -d "$root/$dir" ] || { echo "no a11y report in $dir: run the journey tests first"; return 1; }
  for f in "$root/$dir"/*.json; do
    [ -f "$f" ] || continue
    out=$(jq -c --arg j "$(basename "$f" .json)" --slurpfile d "$f" '
      .[$j] = ($d[0] | map(select(.impact == "serious" or .impact == "critical")) | group_by(.rule)
        | map({key: .[0].rule, value: length}) | from_entries)' <<<"$out") || { echo "$dir/$(basename "$f") is not an a11y report"; return 1; }
  done
  printf '%s\n' "$out"
}

# What is wrong with the baseline $1 (a JSON text), one problem per line.
# shellcheck disable=SC2016 # a jq program, not shell
ratchet_baseline_errors() {
  jq -r '
    def cnt: type == "number" and . >= 1 and floor == .;
    def lintok: type == "object" and (.total | type) == "number" and (.files | type) == "object"
      and ([.files[] | type == "object" and ([.[] | cnt] | all)] | all);
    def covok: type == "object" and (.total | type) == "number" and (.files | type) == "object"
      and ([.files[] | type == "number"] | all);
    def a11yok: type == "object" and (.total | type) == "number" and (.journeys | type) == "object"
      and ([.journeys[] | type == "object" and ([.[] | cnt] | all)] | all);
    if type != "object" or .version != 1 then "must be an object with \"version\": 1"
    elif (.lint != null and (.lint | lintok | not))
      then "lint must be {\"total\": n, \"files\": {\"<file>\": {\"<rule>\": n}}}, counts of at least 1"
    elif (.coverage != null and (.coverage | covok | not))
      then "coverage must be {\"total\": percent, \"files\": {\"<file>\": percent}}"
    elif (.a11y != null and (.a11y | a11yok | not))
      then "a11y must be {\"total\": n, \"journeys\": {\"<journey>\": {\"<rule>\": n}}}, counts of at least 1"
    else empty end' <<<"$1" 2>/dev/null || echo "is not valid JSON"
}

# What a hand edit of the baseline $1 does against the one of the base branch $2 (JSON), one problem per line: a
# count that rises, a file or rule that enters, a coverage that falls. Nothing when it only improves.
# shellcheck disable=SC2016 # a jq program, not shell
ratchet_baseline_worse() {
  jq -rn --argjson n "$1" --argjson o "$2" '
    ($o.lint.files // {}) as $of | ($n.lint.files // {}) as $nf | ($o.coverage.files // {}) as $oc | ($n.coverage.files // {}) as $nc
    | ($o.a11y.journeys // {}) as $oa | ($n.a11y.journeys // {}) as $na
    | (if (($n.lint.total // 0) > ($o.lint.total // 0)) then "lint.total rises from \($o.lint.total // 0) to \($n.lint.total)" else empty end),
      ($nf | to_entries[] | .key as $f
        | if ($of | has($f) | not) then "lint: \($f) enters the baseline"
          else .value | to_entries[] | select(.value > ($of[$f][.key] // 0))
            | "lint: \($f) \(.key) rises from \($of[$f][.key] // 0) to \(.value)" end),
      (if (($n.a11y.total // 0) > ($o.a11y.total // 0)) then "a11y.total rises from \($o.a11y.total // 0) to \($n.a11y.total)" else empty end),
      ($na | to_entries[] | .key as $j
        | if ($oa | has($j) | not) then "a11y: \($j) enters the baseline"
          else .value | to_entries[] | select(.value > ($oa[$j][.key] // 0))
            | "a11y: \($j) \(.key) rises from \($oa[$j][.key] // 0) to \(.value)" end),
      (if ($n.coverage != null and $o.coverage != null and $n.coverage.total < $o.coverage.total)
        then "coverage.total falls from \($o.coverage.total) to \($n.coverage.total)" else empty end),
      (if $o.coverage != null then ($nc | to_entries[]) as $e
        | (if ($oc | has($e.key) | not) then "coverage: \($e.key) enters the baseline"
           elif $e.value < $oc[$e.key] then "coverage: \($e.key) falls from \($oc[$e.key]) to \($e.value)" else empty end)
       else empty end)' 2>&1
}

# The lines the branch adds or changes against the merge base $2 of the repository $1, as `file<TAB>line`
# (untracked files: every line).
ratchet_changed_lines() { # root merge-base
  local f
  git -C "$1" -c core.quotePath=false diff -U0 --no-color --no-ext-diff --no-textconv --no-renames --no-prefix "$2" | awk '
    /^diff / { header = 1; next }
    header && /^\+\+\+ / { f = substr($0, 5); sub(/\t$/, "", f); next }
    /^@@ / { header = 0
      if (match($0, /\+[0-9]+(,[0-9]+)?/)) { split(substr($0, RSTART + 1, RLENGTH - 1), a, ","); d = (a[2] == "" ? 1 : a[2]); for (i = 0; i < d; i++) printf "%s\t%d\n", f, a[1] + i } }'
  while IFS= read -r f; do
    awk -v f="$f" '{ printf "%s\t%d\n", f, NR }' "$1/$f"
  done < <(git -C "$1" -c core.quotePath=false ls-files --others --exclude-standard)
}

# The ratchet as a check (`senior-mode ratchet-check`). With no baseline there is nothing to hold the code to but the
# full bar, which the project's own checks apply. Otherwise: the baseline may not be worse than the base branch's;
# a new file has no lint finding and covers `ratchet.patchCoverage`; a touched file has no finding on a line the
# diff adds or changes, no more findings per rule than the baseline, and no less coverage; a touched file better
# than its entry is `baseline stale` until `check --update-baseline`. Untouched files are never read.
ratchet_check() {
  local root base b mb baseline old errs worse findings="" lint_why cov="" cov_why patch bad="" stale="" key f rule line n a c
  local -A cnt=() allow=() touched=() added=() chg=() rep=() lines=()
  root=$(git rev-parse --show-toplevel) || die "not inside a git repository"
  base=$root/$RATCHET_FILE
  [ -f "$base" ] || { echo "skipped: no $RATCHET_FILE (no baseline: full bar)"; return 0; }
  baseline=$(cat "$base")
  errs=$(ratchet_baseline_errors "$baseline")
  [ -z "$errs" ] || { echo "configuration error: $RATCHET_FILE $errs"; return 1; }
  b=$(default_branch) && mb=$(git merge-base "$b" HEAD) || { echo "skipped: no base branch to compare with"; return 0; }
  if old=$(git show "$b:$RATCHET_FILE" 2>/dev/null); then
    errs=$(ratchet_baseline_errors "$old")
    [ -n "$errs" ] || worse=$(ratchet_baseline_worse "$baseline" "$old")
    [ -z "$worse" ] || { printf 'ratchet baseline worse than on %s: %s\n' "$b" "$worse" | sed '2,$s/^/  /'; return 1; }
  fi
  while IFS= read -r f; do touched[$f]=1; done < <(changed_files "$root" deleted)
  while IFS= read -r f; do added[$f]=1; done < <(git -C "$root" -c core.quotePath=false diff --name-only --diff-filter=A --no-renames "$mb"
    git -C "$root" -c core.quotePath=false ls-files --others --exclude-standard)
  while IFS=$'\t' read -r f line; do chg[$f$'\t'$line]=1; done < <(ratchet_changed_lines "$root" "$mb")
  if jq -e '.lint != null' <<<"$baseline" >/dev/null; then
    if findings=$(ratchet_lint "$root"); then
      while IFS=$'\t' read -r f rule line; do
        [ -n "$f" ] || continue
        cnt[$f$'\t'$rule]=$((${cnt[$f$'\t'$rule]:-0} + 1))
        lines[$f$'\t'$rule]+="$line "
        [ -n "${touched[$f]:-}" ] || continue
        if [ -n "${added[$f]:-}" ]; then
          bad+="$f:$line: $rule: a new file has no finding, whatever the baseline says"$'\n'
          rep[$f$'\t'$rule$'\t'$line]=1
        elif [ -n "${chg[$f$'\t'$line]:-}" ]; then
          bad+="$f:$line: $rule: a finding on a line the branch changes"$'\n'
          rep[$f$'\t'$rule$'\t'$line]=1
        fi
      done <<<"$findings"
      while IFS=$'\t' read -r f rule n; do allow[$f$'\t'$rule]=$n; done < <(jq -r '.lint.files | to_entries[] | .key as $f | .value | to_entries[] | [$f, .key, .value] | @tsv' <<<"$baseline")
      for key in "${!cnt[@]}" "${!allow[@]}"; do
        IFS=$'\t' read -r f rule <<<"$key"
        [ -n "${touched[$f]:-}" ] && [ -z "${added[$f]:-}" ] || continue
        c=${cnt[$key]:-0}
        a=${allow[$key]:-0}
        if [ "$c" -gt "$a" ]; then
          n=0
          for line in ${lines[$key]}; do [ -z "${rep[$f$'\t'$rule$'\t'$line]:-}" ] || n=1; done
          [ "$n" -eq 0 ] || continue
          for line in $(printf '%s\n' ${lines[$key]} | sort -n | tail -n "$((c - a))"); do
            bad+="$f:$line: $rule: $c findings in the file, the baseline allows $a"$'\n'
          done
        elif [ "$c" -lt "$a" ]; then
          stale+="$f: $rule has $c findings, the baseline says $a"$'\n'
        fi
        unset "cnt[$key]" "allow[$key]"
      done
    else
      lint_why=$findings
      echo "warning: ratchet: lint: not measured: $lint_why"
    fi
  fi
  if jq -e '.coverage != null' <<<"$baseline" >/dev/null; then
    if cov=$(ratchet_coverage "$root"); then
      patch=$(config_get ratchet.patchCoverage 2>/dev/null) || patch=80
      local tj aj
      tj=$(printf '%s\n' "${!touched[@]}" | jq -R . | jq -sc .)
      aj=$(printf '%s\n' "${!added[@]}" | jq -R . | jq -sc .)
      while IFS=$'\t' read -r key f; do
        case $key in fail) bad+="$f"$'\n' ;; stale) stale+="$f"$'\n' ;; esac
      done < <(jq -rn --argjson m "$cov" --argjson b "$baseline" --argjson t "$tj" --argjson a "$aj" --argjson p "${patch:-80}" '
        $t[] as $f | ($m.files[$f]) as $c | ($b.coverage.files[$f]) as $o
        | if $c == null then empty
          elif ($a | index($f)) then (if $c < $p then "fail\t\($f): coverage \($c)% of a new file, \($p)% required" else empty end)
          elif $o == null then empty
          elif $c < $o then "fail\t\($f): coverage \($c)% below the baseline \($o)%"
          elif $c > $o then "stale\t\($f): coverage \($c)%, the baseline says \($o)%"
          else empty end')
    else
      cov_why=$cov
      echo "warning: ratchet: coverage: not measured: $cov_why"
    fi
  fi
  [ -z "$stale" ] || bad+="baseline stale: run senior-mode check --update-baseline"$'\n'"$(sed 's/^/  /' <<<"${stale%$'\n'}")"$'\n'
  [ -z "$bad" ] || { printf '%s' "$bad"; return 1; }
}

# `check --update-baseline` for the ratchet: lowers a lint entry to what is left (deleting it at zero) and raises a
# coverage entry to what is measured, from the tree. Refuses, writing nothing, when a file got worse or a finding is
# not in the baseline.
ratchet_update() {
  local root base baseline findings cov="" a11y out bad
  root=$(git rev-parse --show-toplevel) || die "not inside a git repository"
  base=$root/$RATCHET_FILE
  baseline=$(cat "$base")
  out=$baseline
  if jq -e '.lint != null' <<<"$baseline" >/dev/null; then
    findings=$(ratchet_lint "$root") || { echo "ratchet: lint: not measured: $findings"; return 1; }
    bad=$(jq -rn --argjson b "$baseline" --rawfile f <(printf '%s\n' "$findings") '
      [$f | split("\n")[] | select(. != "") | split("\t")] as $r
      | ($r | group_by(.[0] + "\t" + .[1]) | map({file: .[0][0], rule: .[0][1], n: length})) as $m
      | $m[] | select(.n > ($b.lint.files[.file][.rule] // 0))
      | "\(.file): \(.rule) has \(.n) findings, the baseline allows \($b.lint.files[.file][.rule] // 0)"')
    [ -z "$bad" ] || { printf 'ratchet baseline: refused, a file got worse or a finding is new:\n%s\n' "$bad" | sed '2,$s/^/  /'; return 1; }
    out=$(jq -c --rawfile f <(printf '%s\n' "$findings") '
      ([$f | split("\n")[] | select(. != "") | split("\t")] | group_by(.[0] + "\t" + .[1])
        | map({file: .[0][0], rule: .[0][1], n: length})) as $m
      | .lint.files |= (to_entries | map(.key as $k | .value |= (to_entries | map(select(.key as $r | any($m[]; .file == $k and .rule == $r))
          | .key as $r | .value = ([$m[] | select(.file == $k and .rule == $r) | .n] | first)) | from_entries))
        | map(select(.value | length > 0)) | from_entries)
      | .lint.total = ([.lint.files[][]] | add // 0)' <<<"$out")
  fi
  if jq -e '.coverage != null' <<<"$baseline" >/dev/null; then
    if cov=$(ratchet_coverage "$root"); then
      bad=$(jq -rn --argjson b "$baseline" --argjson m "$cov" '$b.coverage.files | to_entries[] | select($m.files[.key] != null and $m.files[.key] < .value)
        | "\(.key): coverage \($m.files[.key])%, the baseline says \(.value)%"')
      [ -z "$bad" ] || { printf 'ratchet baseline: refused, a file got worse:\n%s\n' "$bad" | sed '2,$s/^/  /'; return 1; }
      out=$(jq -c --argjson m "$cov" '.coverage.files |= with_entries(.value = ([.value, ($m.files[.key] // .value)] | max))
        | .coverage.total = ([.coverage.total, $m.total] | max)' <<<"$out")
    else
      echo "ratchet: coverage: not measured: $cov"
    fi
  fi
  if jq -e '.a11y != null' <<<"$baseline" >/dev/null; then
    if a11y=$(ratchet_a11y "$root"); then
      bad=$(jq -rn --argjson b "$baseline" --argjson m "$a11y" '$m | to_entries[] | .key as $j | .value | to_entries[]
        | select(.value > ($b.a11y.journeys[$j][.key] // 0))
        | "\($j): \(.key) has \(.value) serious violations, the baseline allows \($b.a11y.journeys[$j][.key] // 0)"')
      [ -z "$bad" ] || { printf 'ratchet baseline: refused, a journey got worse or a violation is new:\n%s\n' "$bad" | sed '2,$s/^/  /'; return 1; }
      out=$(jq -c --argjson m "$a11y" '
        .a11y.journeys |= (to_entries | map(.key as $j | if ($m | has($j))
            then .value |= (to_entries | map(select($m[$j][.key] != null) | .value = $m[$j][.key]) | from_entries) else . end)
          | map(select(.value | length > 0)) | from_entries)
        | .a11y.total = ([.a11y.journeys[][]] | add // 0)' <<<"$out")
    else
      echo "ratchet: a11y: not measured: $a11y"
    fi
  fi
  jq '.' <<<"$out" >"$base.tmp" && mv "$base.tmp" "$base"
  echo "ratchet baseline: rewritten ($(jq -r '.lint.total // 0' "$base") lint findings, coverage $(jq -r '.coverage.total // "not recorded"' "$base"))"
}

# `senior-mode ratchet [--init]`: what the baseline holds and what the tree measures, for lint, coverage and the
# architecture rules. --init freezes the current lint findings and coverage as the baseline, once.
# shellcheck disable=SC2016 # a jq program, not shell
ratchet_cmd() {
  local root base findings cov a11y lint_ok=false cov_ok=false a11y_ok=false init=false n
  [ $# -eq 0 ] || { [ "$1" = --init ] && [ $# -eq 1 ]; } || usage
  [ $# -eq 0 ] || init=true
  root=$(git rev-parse --show-toplevel) || die "not inside a git repository"
  base=$root/$RATCHET_FILE
  if [ "$init" = false ] && [ ! -f "$base" ]; then
    echo "no baseline: full bar"
    return 0
  fi
  if findings=$(ratchet_lint "$root"); then lint_ok=true; fi
  if cov=$(ratchet_coverage "$root"); then cov_ok=true; fi
  if a11y=$(ratchet_a11y "$root"); then a11y_ok=true; fi
  if [ "$init" = true ]; then
    [ ! -e "$base" ] || die "$RATCHET_FILE exists: only check --update-baseline lowers it"
    [ "$lint_ok" = true ] || [ "$cov_ok" = true ] || [ "$a11y_ok" = true ] || die "nothing to freeze: lint: not measured: $findings; coverage: not measured: $cov; a11y: not measured: $a11y"
    jq -n --arg d "$(date -u +%F)" --arg f "$findings" --argjson l "$lint_ok" --argjson c "$([ "$cov_ok" = true ] && echo "$cov" || echo null)" --argjson a "$([ "$a11y_ok" = true ] && echo "$a11y" || echo null)" '
      { version: 1, createdAt: $d }
      + (if $l then ([$f | split("\n")[] | select(. != "") | split("\t")] | group_by(.[0]) as $g
          | {lint: {total: ($g | map(length) | add // 0),
              files: ($g | map({key: .[0][0], value: (group_by(.[1]) | map({key: .[0][1], value: length}) | from_entries)}) | from_entries)}}) else {} end)
      + (if $c != null then {coverage: $c} else {} end)
      + (if $a != null then {a11y: {total: ([$a[][]] | add // 0), journeys: ($a | map_values(select(length > 0)))}} else {} end)' >"$base.tmp" && mv "$base.tmp" "$base"
    echo "ratchet baseline: $RATCHET_FILE written"
    return 0
  fi
  if jq -e '.lint != null' "$base" >/dev/null; then
    if [ "$lint_ok" = true ]; then
      echo "lint: $(jq '.lint.total' "$base") findings in $(jq '.lint.files | length' "$base") files in the baseline, $(grep -c . <<<"$findings" || true) measured"
    else echo "lint: not measured: $findings"; fi
  fi
  if jq -e '.coverage != null' "$base" >/dev/null; then
    if [ "$cov_ok" = true ]; then echo "coverage: $(jq '.coverage.total' "$base")% in the baseline, $(jq '.total' <<<"$cov")% measured"
    else echo "coverage: not measured: $cov"; fi
  fi
  if jq -e '.a11y != null' "$base" >/dev/null; then
    if [ "$a11y_ok" = true ]; then echo "a11y: $(jq '.a11y.total' "$base") serious violations in the baseline, $(jq '[.[][]] | add // 0' <<<"$a11y") measured"
    else echo "a11y: not measured: $a11y"; fi
  fi
  if [ -f "$root/.claude/architecture-baseline.json" ]; then
    n=$(jq '[.violations[] | (.count // 1)] | add // 0' "$root/.claude/architecture-baseline.json" 2>/dev/null) || n="?"
    echo "architecture: $n violations in the baseline"
  else
    echo "architecture: no baseline"
  fi
}
