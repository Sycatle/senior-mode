# The code rules engine of `check` (#720, spec 471 §1): packs of rules read from plugins/senior-mode/rules/<pack>.json,
# run on what the diff adds. A rule is a `pattern` (a matcher run on the added lines) or a `tool` (an outside tool whose
# report an adapter turns into findings). Definitions only: the entry point dispatches `rules-check`.

RULES_MATCHERS="line call comment loop suppression"
RULES_FORMATS="jscpd knip knip-deps deptry vulture staticcheck gotidy cargo-dead udeps"
# The formats whose report is text, not JSON: an empty one is a clean run.
RULES_TEXT_FORMATS=" vulture gotidy "
# The formats that read the text the diff adds (a manifest line, an import line), not only its line numbers.
RULES_TEXT_NEEDED=" knip-deps deptry gotidy udeps "
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
  [ -z "$packs" ] || printf '%s\n' "$packs" | { { grep -qx common <<<"$packs" || [ ! -f "$(rules_dir)/common.json" ]; } || echo common; cat; }
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
    | if (.o | length) == 1 then "warn\t\(.a.f)\t\(.a.s)\t2nd copy of \(.o[0])"
      else "fail\t\(.a.f)\t\(.a.s)\tcopy of a block already at \(.o | join(" and ")); extract it into \(if $shared == "" then "a shared folder (set rules.shared)" else $shared end)" end'
}

# The text the diff adds, as JSON `{file: {line: text}}`: stdin is `file<TAB>added line numbers` per line, $1 the root,
# $2 the merge base. A manifest line that only differs from a base line by a comma is not new (the entry before an
# appended one gains a comma).
rules_added_text() {
  local f ls base
  while IFS=$'\t' read -r f ls; do
    [ -f "$1/$f" ] || continue
    base=""
    ! rules_manifest "$f" || base=$(git -C "$1" show "$2:$f" 2>/dev/null | sed -E 's/^[[:space:]]+//; s/[[:space:]]*,?[[:space:]]*$//')
    awk -v want=" $ls " -v base="$base" 'BEGIN { n = split(want, a, " "); for (i = 1; i <= n; i++) w[a[i]] = 1; n = split(base, b, "\n"); for (i = 1; i <= n; i++) old[b[i]] = 1 }
      (NR in w) { t = $0; sub(/^[ \t]+/, "", t); sub(/[ \t]*,?[ \t]*$/, "", t); if (!(t in old)) print NR "\t" $0 }' "$1/$f" |
      jq -Rs --arg f "$f" '{($f): (split("\n") | map(select(. != "") | split("\t") | {key: .[0], value: (.[1:] | join("\t"))}) | from_entries)}'
  done | jq -s 'add // {}'
}

# Whether the path $1 is a manifest (a file that declares dependencies).
rules_manifest() {
  case ${1##*/} in
    package.json | go.mod | Cargo.toml | pyproject.toml | Pipfile | setup.py | setup.cfg | requirements*.txt) return 0 ;;
  esac
  return 1
}

# The definitions the adapters of dead code and unused dependencies share (jq): $A the added line numbers per file, $T the
# added text per file, $root. `depline` is the line of a manifest the diff adds that names the package.
# shellcheck disable=SC2016 # a jq program, not shell
RULES_JQ_DEFS='
  def rel: (if startswith($root + "/") then .[($root | length + 1):] else . end) | sub("^\\./"; "");
  def isadd($f; $l): any(($A[$f] // [])[]; . == $l);
  def esc: gsub("(?<c>[.+*?()\\[\\]{}|^$\\\\])"; "\\\(.c)");
  def norm: ascii_downcase | gsub("[_.]"; "-");
  def depline($f; $n): ($T[$f] // {}) | to_entries
    | map(select(.value | norm | test("(^|[^a-z0-9@/-])" + ($n | norm | esc) + "($|[^a-z0-9/-])"))) | .[0].key;
'

# The adapters below read the report of a tool on stdin and print `fail<TAB>file<TAB>line<TAB>message` for what the diff
# adds ($1: the added lines per file as JSON, $2: the root, $3: unused here, $4: the added text per file as JSON).

# knip (`--reporter json`, exports, types and files): an export on an added line, a file the diff creates.
# shellcheck disable=SC2016 # a jq program, not shell
rules_knip() {
  jq -r --argjson A "$1" --arg root "$2" --argjson T "$4" "$RULES_JQ_DEFS"'
    ((.files // [])[] | rel as $f | select(isadd($f; 1)) | "fail\t\($f)\t1\tunused file, nothing imports it"),
    ((.issues // [])[] | (.file | rel) as $f
      | ((.exports // []) + (.types // []) + (.nsExports // []) + (.nsTypes // []))[]
      | select(isadd($f; .line)) | "fail\t\($f)\t\(.line)\tunused export \(.name), nothing imports it")'
}

# knip (dependencies): a package that the diff adds to a manifest and no file imports.
# shellcheck disable=SC2016 # a jq program, not shell
rules_knip_deps() {
  jq -r --argjson A "$1" --arg root "$2" --argjson T "$4" "$RULES_JQ_DEFS"'
    (.issues // [])[] | (.file | rel) as $f
    | ((.dependencies // []) + (.devDependencies // []) + (.optionalPeerDependencies // []))[] | .name as $n
    | depline($f; $n) as $l | select($l != null) | "fail\t\($f)\t\($l)\tpackage \($n) is declared and no file imports it"'
}

# deptry (`--json-output`): DEP002, a dependency declared and never used.
# shellcheck disable=SC2016 # a jq program, not shell
rules_deptry() {
  jq -r --argjson A "$1" --arg root "$2" --argjson T "$4" "$RULES_JQ_DEFS"'
    (if type == "array" then . else [] end)[] | select(.error.code == "DEP002") | (.location.file // "pyproject.toml" | rel) as $f | .module as $n
    | depline($f; $n) as $l | select($l != null) | "fail\t\($f)\t\($l)\tpackage \($n) is declared and no file imports it"'
}

# vulture (text, `file:line: message`): a line the diff adds.
# shellcheck disable=SC2016 # a jq program, not shell
rules_vulture() {
  jq -Rr --argjson A "$1" --arg root "$2" "$RULES_JQ_DEFS"'
    capture("^(?<f>[^:]+):(?<l>[0-9]+): (?<m>.*)$") | (.f | rel) as $f | (.l | tonumber) as $l
    | select(isadd($f; $l)) | "fail\t\($f)\t\($l)\t\(.m)"'
}

# staticcheck (`-f json`, one object per line): U1000, a name nothing uses, on an added line.
# shellcheck disable=SC2016 # a jq program, not shell
rules_staticcheck() {
  jq -r --argjson A "$1" --arg root "$2" "$RULES_JQ_DEFS"'
    select(.code == "U1000") | (.location.file | rel) as $f | .location.line as $l
    | select(isadd($f; $l)) | "fail\t\($f)\t\($l)\t\(.message)"'
}

# `go mod tidy -diff` (text, a unified diff of go.mod): a module the tidy removes and the diff adds to go.mod.
# shellcheck disable=SC2016 # a jq program, not shell
rules_gotidy() {
  jq -Rr --argjson A "$1" --arg root "$2" --argjson T "$4" "$RULES_JQ_DEFS"'
    capture("^-[ \\t]+(require[ \\t]+)?(?<n>[^ \\t]+)[ \\t]+v[0-9]") | .n as $n
    | depline("go.mod"; $n) as $l | select($l != null) | "fail\tgo.mod\t\($l)\tmodule \($n) is required and no file imports it"'
}

# cargo check (`--message-format json`, one object per line): a `dead_code` warning on an added line.
# shellcheck disable=SC2016 # a jq program, not shell
rules_cargo_dead() {
  jq -r --argjson A "$1" --arg root "$2" "$RULES_JQ_DEFS"'
    select(.reason == "compiler-message" and .message.code.code == "dead_code") | .message as $m
    | (($m.spans // []) | map(select(.is_primary)) | .[0]) as $s | select($s != null)
    | ($s.file_name | rel) as $f | select(isadd($f; $s.line_start)) | "fail\t\($f)\t\($s.line_start)\t\($m.message)"'
}

# cargo udeps (`--output json`): a crate that the diff adds to a Cargo.toml and no code uses.
# shellcheck disable=SC2016 # a jq program, not shell
rules_udeps() {
  jq -r --argjson A "$1" --arg root "$2" --argjson T "$4" "$RULES_JQ_DEFS"'
    (.unused_deps // {}) | to_entries[] | .value as $v | ($v.manifest_path | rel) as $f
    | (($v.normal // []) + ($v.development // []) + ($v.build // []))[] | . as $n
    | depline($f; $n) as $l | select($l != null) | "fail\t\($f)\t\($l)\tcrate \($n) is declared and no code uses it"'
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
  local okpaths okkey ext out findings="" warns="" lifted="" tool_hit=0 preset n i sev tf tl tm
  local needs install tmp report format shared addedjson addedtext="{}" reads
  local -a rules=() recs=() files=() content=()
  local -A added=() off=() offpaths=() verified=() allow=() allowwhy=() okcfg=()
  local US=$'\x1f'
  root=$(git rev-parse --show-toplevel) || die "not inside a git repository"
  cfg=$(config_effective | jq -c '.rules // {}') || return 1
  preset=$(project_preset "$root")
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
    # A rule that names `presets` is read only by a project of one of them.
    while IFS= read -r r; do rules+=("$r"); done < <(jq -c --arg p "$preset" '.rules[] | select((.presets // []) | length == 0 or index($p))' "$pfile")
  done <<<"$packs"
  errs+=$(rules_off_errors "$cfg")
  [ -z "${errs//$'\n'/}" ] || { printf 'configuration error: %s\n' "${errs%$'\n'}" | sed '2,$s/^/  /'; return 1; }
  # One record per rule, read once: id, kind, tier, match, ext, prodOnly, skip, fix, message and the matcher's fields.
  for r in ${rules[@]+"${rules[@]}"}; do
    recs+=("$(jq -r '[.id, .kind, .tier, (.match // "line"), ((.ext // []) | join(",")), (.prodOnly // false), ((.skip // []) | join("\t")), .fix, (.message // .id),
      (.pattern // ""), (.unless // ""), (.comment // ""), (.code // ""), (.doc // ""), (.min // 2), (.stmt // ""), (.loop // ""), (.style // "brace"), (.never // ""),
      ((.okPaths // []) | join("\t")), (.okKey // "")] | map(tostring) | join("\u001f")' <<<"$r")")
  done
  # A rule may leave the files of `okPaths` alone, which the project replaces with the globs of the config key `okKey`.
  for r in ${recs[@]+"${recs[@]}"}; do
    IFS="$US" read -r _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ okkey <<<"$r"
    [ -z "$okkey" ] || [ -n "${okcfg[$okkey]+x}" ] || okcfg[$okkey]=$(jq -r --arg k "$okkey" '(.[$k] // []) | join("\t")' <<<"$cfg")
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
      IFS="$US" read -r id kind tier match rext prod skip fix msg pat unless comment code doc min stmt loop style never okpaths okkey <<<"$r"
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
      if [ -n "$okpaths" ] || [ -n "$okkey" ]; then
        [ -z "$okkey" ] || [ -z "${okcfg[$okkey]}" ] || okpaths=${okcfg[$okkey]}
        ! rules_under "$f" "$okpaths" || continue
      fi
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
  # The tool rules run once, on the tree, when the diff gives them a file to read (not prose or data); a rule that
  # `reads` the manifests runs when the diff touches one (package.json, go.mod...).
  local -a codefiles=() manifests=()
  for f in ${files[@]+"${files[@]}"}; do
    [[ $RULES_SKIP_EXT == *" $(rules_ext "$f") "* ]] || codefiles+=("$f")
    ! rules_manifest "$f" || manifests+=("$f")
  done
  if [ "${#codefiles[@]}" -gt 0 ] || [ "${#manifests[@]}" -gt 0 ]; then
    i=0
    for r in ${rules[@]+"${rules[@]}"}; do
      IFS="$US" read -r id kind tier _ _ _ _ fix _ <<<"${recs[i]}"
      i=$((i + 1))
      [ "$kind" = tool ] && [ "$tier" = 2 ] || continue
      [ -z "${off[$id]:-}" ] || [ -n "${offpaths[$id]}" ] || continue
      reads=$(jq -r '.reads // "code"' <<<"$r")
      if [ "$reads" = manifest ]; then [ "${#manifests[@]}" -gt 0 ] || continue; else [ "${#codefiles[@]}" -gt 0 ] || continue; fi
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
      if [[ $RULES_TEXT_FORMATS != *" $format "* ]]; then
        jq -e . <<<"$report" >/dev/null 2>&1 || report=$(cat "$tmp/jscpd-report.json" "$tmp/report.json" 2>/dev/null || true)
        if ! jq -e . <<<"$report" >/dev/null 2>&1; then
          rm -rf "$tmp"
          echo "tool failed: $needs printed no report ($id)"
          tool_hit=1
          continue
        fi
      fi
      rm -rf "$tmp"
      if [ "$addedtext" = "{}" ] && [[ $RULES_TEXT_NEEDED == *" $format "* ]]; then
        addedtext=$(for f in ${files[@]+"${files[@]}"}; do printf '%s\t%s\n' "$f" "${added[$f]}"; done | rules_added_text "$root" "$mb")
      fi
      shared=$(jq -r '(.shared // [])[0] // ""' <<<"$cfg")
      shared=${shared%/\*\*}
      shared=${shared%/\*}
      addedjson=$(for f in ${codefiles[@]+"${codefiles[@]}"}; do printf '%s\t%s\n' "$f" "${added[$f]}"; done |
        jq -Rn '[inputs | split("\t") | {key: .[0], value: (.[1] | split(" ") | map(select(. != "") | tonumber))}] | from_entries')
      while IFS=$'\t' read -r sev tf tl tm; do
        [ -n "$sev" ] || continue
        if [ -n "${off[$id]:-}" ] && rules_under "$tf" "${offpaths[$id]}"; then continue; fi
        if [ "$sev" = warn ]; then
          warns+="warning: $tf:$tl: $id: $tm (fix: $fix)"$'\n'
        else
          findings+="$tf:$tl: $id: $tm (fix: $fix)"$'\n'
        fi
      done < <("rules_${format//-/_}" "$addedjson" "$root" "$shared" "$addedtext" <<<"$report")
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
