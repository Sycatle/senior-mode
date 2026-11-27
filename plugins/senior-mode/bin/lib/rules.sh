# The code rules engine of `check` (#720, spec 471 §1): packs of rules read from plugins/senior-mode/rules/<pack>.json,
# run on what the diff adds. A rule is a `pattern` (a matcher run on the added lines) or a `tool` (an outside tool whose
# report an adapter turns into findings). Definitions only: the entry point dispatches `rules-check`.

RULES_MATCHERS="line call comment loop suppression"
RULES_FORMATS="jscpd"
# The files no rule reads unless it lists their extension in `ext`: prose, data, lock files.
RULES_SKIP_EXT=" md mdx txt json lock yaml yml svg "

# The matchers, one awk program run on a file with the rule in the environment (R_*): it prints the 1-based number of
# each line it reports, then a tab and a detail for the matchers that have one. R_ADDED holds the numbers of the added lines.
#  line         a pattern on an added line (R_UNLESS: a pattern that excuses the line)
#  call         a pattern ending with an opening bracket, then the text up to its closing bracket, across lines: reported
#               unless that text matches R_UNLESS
#  comment      R_MIN or more consecutive added comment lines (R_COMMENT) whose text reads as code (R_CODE); R_DOC lines excluded
#  loop         an added line matching R_PATTERN inside a loop: a statement loop (R_STMT, its header does not count) or an
#               inline one (R_LOOP: map, forEach, a comprehension); R_STYLE brace follows the brackets, indent the indentation
#  suppression  an added line matching R_PATTERN: `never` when it matches R_NEVER, else `ref:<n>` or `noref` by the
#               `-- #<n>: reason` of the line or the line above
# shellcheck disable=SC2016 # an awk program, not shell
RULES_AWK='
function indent(s,   t) { t = s; sub(/[^ \t].*$/, "", t); return length(t) }
function count(s, re,   t) { t = s; return gsub(re, "&", t) }
BEGIN {
  m = ENVIRON["R_MATCH"]; pat = ENVIRON["R_PATTERN"]; unless = ENVIRON["R_UNLESS"]
  n = split(ENVIRON["R_ADDED"], a, " "); for (i = 1; i <= n; i++) add[a[i] + 0] = 1
}
{ line[NR] = $0 }
END {
  if (m == "line") {
    for (i = 1; i <= NR; i++) if ((i in add) && line[i] ~ pat && (unless == "" || line[i] !~ unless)) print i
  } else if (m == "call") {
    for (i = 1; i <= NR; i++) {
      if (!(i in add) || !match(line[i], pat)) continue
      s = RSTART + RLENGTH - 1; o = substr(line[i], s, 1); c = (o == "(" ? ")" : (o == "{" ? "}" : "]"))
      text = substr(line[i], s); depth = 0; args = ""; j = i; done = 0
      while (!done) {
        for (k = 1; k <= length(text); k++) {
          ch = substr(text, k, 1)
          if (ch == o) depth++
          else if (ch == c && --depth == 0) { text = substr(text, 1, k); done = 1; break }
        }
        args = args text " "
        if (done || j >= NR || j - i >= 30) break
        j++; text = line[j]
      }
      if (unless == "" || args !~ unless) print i
    }
  } else if (m == "comment") {
    cm = ENVIRON["R_COMMENT"]; code = ENVIRON["R_CODE"]; doc = ENVIRON["R_DOC"]; min = ENVIRON["R_MIN"] + 0; if (min < 1) min = 2
    run = 0
    for (i = 1; i <= NR + 1; i++) {
      ok = 0
      if (i <= NR && (i in add) && line[i] ~ cm && (doc == "" || line[i] !~ doc)) { t = line[i]; sub(cm, "", t); if (t ~ code) ok = 1 }
      if (ok) { if (run == 0) start = i; run++ } else { if (run >= min) print start; run = 0 }
    }
  } else if (m == "loop") {
    stmt = ENVIRON["R_STMT"]; lp = ENVIRON["R_LOOP"]; style = ENVIRON["R_STYLE"]; sp = 0; d = 0
    for (i = 1; i <= NR; i++) {
      l = line[i]
      if (l ~ /^[ \t]*$/) continue
      isstmt = (stmt != "" && l ~ stmt); isinl = (lp != "" && l ~ lp)
      if (style == "indent") {
        ind = indent(l)
        while (sp > 0 && ind <= st[sp]) sp--
        inloop = (sp > 0 || isinl)
        if (isstmt) st[++sp] = ind
      } else {
        before = d; d = before + count(l, "[({]") - count(l, "[)}]")
        inloop = (sp > 0 || isinl)
        if (isstmt || isinl) st[++sp] = before
        while (sp > 0 && d <= st[sp]) sp--
      }
      if ((i in add) && inloop && l ~ pat && (unless == "" || l !~ unless)) print i
    }
  } else if (m == "suppression") {
    never = ENVIRON["R_NEVER"]
    for (i = 1; i <= NR; i++) {
      if (!(i in add)) continue
      if (never != "" && line[i] ~ never) { print i "\tnever"; continue }
      if (line[i] !~ pat) continue
      ref = ""
      for (q = 0; q <= 1 && ref == ""; q++) {
        cand = line[i - q]
        if (match(cand, "--[[:space:]]+#[0-9]+:[[:space:]]*[^[:space:]]")) { s = substr(cand, RSTART, RLENGTH); match(s, "#[0-9]+"); ref = substr(s, RSTART + 1, RLENGTH - 1) }
      }
      print i "\t" (ref == "" ? "noref" : "ref:" ref)
    }
  }
}'

# Whether the path $1 matches the glob $2 (`**` is any run of characters, `*` too: folders are not special).
rules_glob() {
  local g=${2//\*\*/\*}
  # shellcheck disable=SC2053 # a glob on purpose
  [[ $1 == $g || /$1 == $g ]]
}

# The packs of the project at $1 with the rules configuration $2: `rules.packs`, else the preset's.
rules_packs() {
  local root=$1 cfg=$2 packs preset
  packs=$(jq -r '(.packs // [])[]' <<<"$cfg")
  if [ -z "$packs" ]; then
    preset=$(cd "$(dirname "$SELF")/.." && pwd)/presets/$(project_preset "$root")/preset.json
    [ ! -f "$preset" ] || packs=$(jq -r '(.rules.packs // [])[]' "$preset")
  fi
  # `common` holds the rules of every language: any pack brings it.
  [ -z "$packs" ] || printf '%s\n' "$packs" | { grep -qx common <<<"$packs" || echo common; cat; }
}

# Whether `check` has a code rules step in the project at $1.
rules_enabled() {
  local cfg
  cfg=$(config_effective 2>/dev/null | jq -c '.rules // {}') || return 1
  [ -n "$(rules_packs "$1" "$cfg")" ]
}

# The configuration errors of the pack file $2 (named $1), one per line, naming the pack and the entry.
# shellcheck disable=SC2016 # a jq program, not shell
rules_pack_errors() {
  jq -r --arg p "$1" --arg matchers "$RULES_MATCHERS" --arg formats "$RULES_FORMATS" '
    ($matchers | split(" ")) as $m | ($formats | split(" ")) as $f
    | (.rules // []) | to_entries[] | .key as $i | .value as $r
    | ("pack \($p), entry \($i + 1)" + (if ($r.id | type) == "string" then " (\($r.id))" else "" end)) as $w
    | (if ($r.id | type) != "string" or $r.id == "" then "\($w): id is missing" else empty end),
      (if ($r.tier == 2 or $r.tier == 3) | not then "\($w): tier is missing or not 2 or 3" else empty end),
      (if ($r.fix | type) != "string" or $r.fix == "" then "\($w): fix is missing" else empty end),
      (if ($r.kind == "pattern" or $r.kind == "tool") | not then "\($w): unknown kind \($r.kind | tojson)" else empty end),
      (if $r.kind == "pattern" then
         (if ($r.pattern | type) != "string" or $r.pattern == "" then "\($w): pattern is missing" else empty end),
         (if ($r.match // "line") as $x | $m | index($x) | not then "\($w): unknown match \($r.match | tojson)" else empty end)
       elif $r.kind == "tool" then
         (if ($r.run | type) != "string" or $r.run == "" then "\($w): run is missing" else empty end),
         (if ($r.format // "") as $x | $f | index($x) | not then "\($w): unknown format \($r.format | tojson)" else empty end)
       else empty end)' "$2"
}

# The `rules.off` entries without a reason, one error per line.
rules_off_errors() {
  jq -r '(.off // {}) | to_entries[] | select((.value.why | type) != "string" or .value.why == "") | "rules.off.\(.key): why is missing"' <<<"$1"
}

# The ext of the path $1.
rules_ext() {
  local b=${1##*/}
  [[ $b == *.* ]] && printf '%s\n' "${b##*.}" || true
}

# The state of the tool of the rule $1 ({out} is replaced by the directory $2): the report on stdout, the exit code ignored.
rules_tool_report() {
  local rule=$1 out=$2 root=$3 cmd
  cmd=$(jq -r '.run' <<<"$rule")
  cmd=${cmd//\{out\}/$out}
  (cd "$root" && bash -c "$cmd" 2>/dev/null) || true
}

# The findings of the jscpd report on stdin, as `warn|fail<TAB>file<TAB>line<TAB>message`: a block the diff adds ($1: the
# added lines per file as JSON) that has one copy elsewhere is a warning, two or more a failure (the rule of three).
# $2: the root, $3: the folder to extract into.
# shellcheck disable=SC2016 # a jq program, not shell
rules_jscpd() {
  jq -r --argjson A "$1" --arg root "$2" --arg shared "$3" '
    def rel: if startswith($root + "/") then .[($root | length + 1):] else . end;
    def loc: "\(.f):\(.s)";
    def isadd: . as $x | any(($A[$x.f] // [])[]; . >= $x.s and . <= $x.e);
    [(.duplicates // [])[]
      | {f: (.firstFile.name | rel), s: .firstFile.start, e: .firstFile.end} as $a
      | {f: (.secondFile.name | rel), s: .secondFile.start, e: .secondFile.end} as $b
      | ({a: $a, b: $b}, {a: $b, b: $a})]
    | map(select(.a | isadd) | select((.b | isadd | not) or ((.b | loc) < (.a | loc))))
    | group_by(.a | loc) | .[]
    | {a: .[0].a, o: ([.[].b | loc] | unique)}
    | if (.o | length) == 1 then "warn\t\(.a.f)\t\(.a.s)\tduplication: 2nd copy of \(.o[0])"
      else "fail\t\(.a.f)\t\(.a.s)\tduplication: copy of a block already at \(.o | join(" and ")); extract it into \(if $shared == "" then "a shared folder (set rules.shared)" else $shared end)" end'
}

# The directory of the rule packs ($SENIOR_MODE_RULES_DIR for the tests).
rules_dir() { printf '%s\n' "${SENIOR_MODE_RULES_DIR:-$(cd "$(dirname "$SELF")/.." && pwd)/rules}"; }

# Whether the path $1 is under one of the globs of the tab-separated list $2.
rules_under() {
  local g
  while IFS= read -r g; do
    [ -z "$g" ] || ! rules_glob "$1" "$g" || return 0
  done <<<"${2//$'\t'/$'\n'}"
  return 1
}

# The code rules step (`senior-mode rules-check`): the packs of the project run on the lines the branch adds or changes
# against the merge base. Prints `off  <id>: <why>` for a rule turned off, one `file:line: rule-id: message (fix: ...)`
# per finding (`warning: ` lines do not fail), and fails on a configuration error or a tool that is not installed.
# A tier 3 rule is not run here.
rules_check() {
  local root cfg packs pack pfile errs="" b mb f line r id why kind tier match rext prod skip fix msg pat unless comment code doc min stmt loop style never
  local ext out findings="" warns="" lifted="" tool_hit=0 preset n i sev tf tl tm
  local needs install tmp report format shared addedjson
  local -a rules=() recs=() files=() content=()
  local -A added=() off=() offpaths=() verified=() allow=() allowwhy=()
  local US=$'\x1f'
  root=$(git rev-parse --show-toplevel) || die "not inside a git repository"
  cfg=$(config_effective | jq -c '.rules // {}') || return 1
  packs=$(rules_packs "$root" "$cfg")
  [ -n "$packs" ] || { echo "skipped: no rule packs (rules.packs is empty and the preset names none)"; return 0; }
  while IFS= read -r pack; do
    pfile=$(rules_dir)/$pack.json
    if [ ! -f "$pfile" ] || ! jq -e '.rules | type == "array"' "$pfile" >/dev/null 2>&1; then
      errs+="pack $pack: no valid pack file (rules/$pack.json with a \"rules\" list)"$'\n'
      continue
    fi
    n=$(rules_pack_errors "$pack" "$pfile")
    if [ -n "$n" ]; then
      errs+="$n"$'\n'
      continue
    fi
    while IFS= read -r r; do rules+=("$r"); done < <(jq -c '.rules[]' "$pfile")
  done <<<"$packs"
  errs+=$(rules_off_errors "$cfg")
  [ -z "${errs//$'\n'/}" ] || { printf 'configuration error: %s\n' "${errs%$'\n'}" | sed '2,$s/^/  /'; return 1; }
  # One record per rule, read once: id, kind, tier, match, ext, prodOnly, skip, fix, message and the matcher's fields.
  for r in ${rules[@]+"${rules[@]}"}; do
    recs+=("$(jq -r '[.id, .kind, .tier, (.match // "line"), ((.ext // []) | join(",")), (.prodOnly // false), ((.skip // []) | join("\t")), .fix, (.message // .id),
      (.pattern // ""), (.unless // ""), (.comment // ""), (.code // ""), (.doc // ""), (.min // 2), (.stmt // ""), (.loop // ""), (.style // "brace"), (.never // "")] | map(tostring) | join("\u001f")' <<<"$r")")
  done
  while IFS="$US" read -r id why; do
    off[$id]=$why
    offpaths[$id]=$(jq -r --arg i "$id" '.off[$i].paths // [] | join("\t")' <<<"$cfg")
  done < <(jq -r '(.off // {}) | to_entries[] | [.key, .value.why] | join("\u001f")' <<<"$cfg")
  for r in ${recs[@]+"${recs[@]}"}; do
    id=${r%%"$US"*}
    [ -z "${off[$id]:-}" ] || echo "off  $id: ${off[$id]}"
  done
  b=$(default_branch) && mb=$(git merge-base "$b" HEAD) || { echo "skipped: no base branch to compare with"; return 0; }
  while IFS=$'\t' read -r f line; do [ "$f" = /dev/null ] || added[$f]+="$line "; done < <(ratchet_changed_lines "$root" "$mb")
  for f in "${!added[@]}"; do [ ! -f "$root/$f" ] || files+=("$f"); done
  [ "${#files[@]}" -eq 0 ] || mapfile -t files < <(printf '%s\n' "${files[@]}" | LC_ALL=C sort)
  preset=$(project_preset "$root")
  for f in ${files[@]+"${files[@]}"}; do
    mapfile -t content <"$root/$f"
    ext=$(rules_ext "$f")
    # The `senior-mode: allow <rule-id> -- #n: reason` the diff adds lifts that rule's finding on the next line.
    allow=() allowwhy=()
    for line in ${added[$f]}; do
      if [[ ${content[line - 1]:-} =~ senior-mode:[[:space:]]*allow[[:space:]]+([a-z0-9-]+) ]]; then
        allow[$((line + 1)):${BASH_REMATCH[1]}]=1
        allowwhy[$((line + 1)):${BASH_REMATCH[1]}]=$(sed -nE 's/.*--[[:space:]]+(#[0-9]+:[[:space:]]*.*)$/\1/p' <<<"${content[line - 1]}")
      fi
    done
    for r in ${recs[@]+"${recs[@]}"}; do
      IFS="$US" read -r id kind tier match rext prod skip fix msg pat unless comment code doc min stmt loop style never <<<"$r"
      [ "$kind" = pattern ] && [ "$tier" = 2 ] || continue
      # An off rule is skipped everywhere, or only under its paths.
      if [ -n "${off[$id]:-}" ] && { [ -z "${offpaths[$id]}" ] || rules_under "$f" "${offpaths[$id]}"; }; then continue; fi
      if [ -n "$rext" ]; then
        [[ ,$rext, == *,$ext,* ]] || continue
      else
        [[ $RULES_SKIP_EXT != *" $ext "* ]] || continue
      fi
      if [ "$prod" = true ] && { test_file "$preset" "$f" || test_file x "$f"; }; then continue; fi
      [ -z "$skip" ] || ! rules_under "$f" "$skip" || continue
      out=$(R_MATCH=$match R_ADDED=${added[$f]} R_PATTERN=$pat R_UNLESS=$unless R_COMMENT=$comment R_CODE=$code R_DOC=$doc R_MIN=$min \
        R_STMT=$stmt R_LOOP=$loop R_STYLE=$style R_NEVER=$never awk "$RULES_AWK" "$root/$f")
      [ -n "$out" ] || continue
      while IFS=$'\t' read -r line n; do
        [ -n "$line" ] || continue
        if [ "$match" = suppression ]; then
          case $n in
            never) findings+="$f:$line: $id: $msg (fix: $fix)"$'\n' ;;
            noref) findings+="$f:$line: $id: no issue and reason on the line or the line above (fix: $fix)"$'\n' ;;
            ref:*)
              n=${n#ref:}
              [ -n "${verified[$n]:-}" ] || verified[$n]=$(rules_issue_state "$n")
              case ${verified[$n]} in
                missing) findings+="$f:$line: $id: #$n not found (fix: $fix)"$'\n' ;;
                unknown) warns+="warning: $f:$line: $id: #$n not verified"$'\n' ;;
              esac
              ;;
          esac
          continue
        fi
        if [ -n "${allow[$line:$id]:-}" ]; then
          lifted+="warning: $f:$line: $id lifted by senior-mode: allow${allowwhy[$line:$id]:+ (${allowwhy[$line:$id]})}"$'\n'
          continue
        fi
        findings+="$f:$line: $id: $msg (fix: $fix)"$'\n'
      done <<<"$out"
    done
  done
  # The tool rules run once, on the tree, when the diff gives them a file to read.
  if [ "${#files[@]}" -gt 0 ]; then
    i=0
    for r in ${rules[@]+"${rules[@]}"}; do
      IFS="$US" read -r id kind tier _ _ _ _ fix _ <<<"${recs[i]}"
      i=$((i + 1))
      [ "$kind" = tool ] && [ "$tier" = 2 ] || continue
      [ -z "${off[$id]:-}" ] || [ -n "${offpaths[$id]}" ] || continue
      needs=$(jq -r '.needs // (.run | split(" ")[0])' <<<"$r")
      install=$(jq -r '.install // "install it"' <<<"$r")
      if ! command -v "$needs" >/dev/null 2>&1; then
        echo "tool missing: $needs (install: $install; or turn the rule off with rules.off.$id and a why)"
        tool_hit=1
        continue
      fi
      format=$(jq -r '.format' <<<"$r")
      tmp=$(mktemp -d)
      report=$(rules_tool_report "$r" "$tmp" "$root")
      jq -e . <<<"$report" >/dev/null 2>&1 || report=$(cat "$tmp/jscpd-report.json" 2>/dev/null || true)
      rm -rf "$tmp"
      if ! jq -e . <<<"$report" >/dev/null 2>&1; then
        echo "tool failed: $needs printed no report ($id)"
        tool_hit=1
        continue
      fi
      shared=$(jq -r '(.shared // [])[0] // ""' <<<"$cfg")
      shared=${shared%/\*\*}
      shared=${shared%/\*}
      addedjson=$(for f in "${files[@]}"; do printf '%s\t%s\n' "$f" "${added[$f]}"; done |
        jq -Rn '[inputs | split("\t") | {key: .[0], value: (.[1] | split(" ") | map(select(. != "") | tonumber))}] | from_entries')
      while IFS=$'\t' read -r sev tf tl tm; do
        [ -n "$sev" ] || continue
        if [ -n "${off[$id]:-}" ] && rules_under "$tf" "${offpaths[$id]}"; then continue; fi
        if [ "$sev" = warn ]; then
          warns+="warning: $tf:$tl: $tm (fix: $fix)"$'\n'
        else
          findings+="$tf:$tl: $id: $tm (fix: $fix)"$'\n'
        fi
      done < <("rules_$format" "$addedjson" "$root" "$shared" <<<"$report")
    done
  fi
  printf '%s%s' "$warns" "$lifted"
  printf '%s' "$findings"
  [ -z "$findings" ] && [ "$tool_hit" -eq 0 ]
}

# `missing` when the issue $1 does not exist, `unknown` when gh cannot tell, else `ok`.
rules_issue_state() {
  local out
  command -v gh >/dev/null 2>&1 || { echo unknown; return; }
  if out=$(gh issue view "$1" --json number 2>&1); then
    echo ok
  elif grep -qiE 'could not resolve to an issue|not found|HTTP 404' <<<"$out"; then
    echo missing
  else
    echo unknown
  fi
}
