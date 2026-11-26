# shellcheck shell=bash
# The repo map of the briefing (spec 325 §8.1, #362): the top-level symbols and signatures of the files of a ticket's
# Paths and of the files they import, most referenced first, at most `context.repoMapTokens` tokens (bytes / 4).
# The index of a tree (symbols, imports, reference counts) is built once per tree and kept in
# `senior-mode/repomap/<tree-sha>` of the git directory; the Paths only select from it. The symbols come from Universal
# Ctags when it is installed and answers, else from a deterministic regex per language (TypeScript and JavaScript,
# Python, Go, Rust, bash). The index reads the committed tree (HEAD), never the working directory.

REPOMAP_HEAD='Repo map (top-level symbols of these Paths and of the files they import, most referenced first):'
REPOMAP_GLOBS=('*.ts' '*.tsx' '*.js' '*.jsx' '*.mjs' '*.py' '*.go' '*.rs' '*.sh' '*.bash')

# The source files of a tree on the input (one path per line), vendored code left out.
REPOMAP_AWK_FILES='/(^|\/)(node_modules|vendor|dist|build|target)\//{ next }
/\.(ts|tsx|js|jsx|mjs|py|go|rs|sh|bash)$/'

# Lines that may declare a top-level symbol or an import: a loose prefilter for `git grep`, the awk programs decide.
REPOMAP_PRE_SYMBOL='^(export|default|declare|async|abstract|function|class|interface|type|enum|const|let|var|namespace|def|func|fn|pub|struct|trait|mod|union|static|unsafe|extern)[[:space:]*]|^[A-Za-z_][A-Za-z0-9_:.-]*[[:space:]]*\(\)'
REPOMAP_PRE_IMPORT='(^|[^A-Za-z0-9_])(from|import|require|use|mod|source)[[:space:](]|^[[:space:]]*\.[[:space:]]|^[[:space:]]*"[^"]+"[[:space:]]*$|shellcheck[[:space:]]+source='

# `git grep -n` lines on the input (`HEAD:file:line:text`), the known files in the file $fl: `S<TAB>file<TAB>line<TAB>name<TAB>signature`
# for each top-level declaration.
REPOMAP_AWK_SYMBOLS='BEGIN { while ((getline l < fl) > 0) known[l] = 1 }
{
  rest = substr($0, 6)
  if (!match(rest, /:[0-9]+:/)) next
  file = substr(rest, 1, RSTART - 1); lno = substr(rest, RSTART + 1, RLENGTH - 2); text = substr(rest, RSTART + RLENGTH)
  if (!(file in known)) next
  ext = file; sub(/.*\./, "", ext)
  t = text; name = ""
  if (ext ~ /^(ts|tsx|js|jsx|mjs)$/) {
    while (sub(/^(export|default|declare|async|abstract)[ \t]+/, "", t)) ;
    if (match(t, /^(function\*?|class|interface|type|enum|const enum|const|let|var|namespace)[ \t]+[A-Za-z_$][A-Za-z0-9_$]*/)) {
      name = substr(t, 1, RLENGTH); sub(/.*[ \t*]/, "", name)
    }
  } else if (ext == "py") {
    if (match(t, /^(async[ \t]+)?(def|class)[ \t]+[A-Za-z_][A-Za-z0-9_]*/)) {
      name = substr(t, 1, RLENGTH); sub(/.*[ \t]/, "", name)
      if (name ~ /^_[^_]/) name = ""
    }
  } else if (ext == "go") {
    if (match(t, /^func[ \t]+(\([^)]*\)[ \t]*)?[A-Za-z_][A-Za-z0-9_]*/)) {
      name = substr(t, 1, RLENGTH); sub(/^func[ \t]+(\([^)]*\)[ \t]*)?/, "", name)
    } else if (match(t, /^(type|const|var)[ \t]+[A-Za-z_][A-Za-z0-9_]*/)) {
      name = substr(t, 1, RLENGTH); sub(/.*[ \t]/, "", name)
    }
  } else if (ext == "rs") {
    sub(/^pub(\([^)]*\))?[ \t]+/, "", t)
    while (sub(/^(async|unsafe|extern([ \t]+"[^"]*")?)[ \t]+/, "", t)) ;
    if (t ~ /^const[ \t]+(fn|unsafe|async)[ \t]/) sub(/^const[ \t]+/, "", t)
    while (sub(/^(async|unsafe|extern([ \t]+"[^"]*")?)[ \t]+/, "", t)) ;
    if (match(t, /^(fn|struct|enum|trait|type|mod|union|static|const)[ \t]+[A-Za-z_][A-Za-z0-9_]*/)) {
      name = substr(t, 1, RLENGTH); sub(/.*[ \t]/, "", name)
    }
  } else {
    if (match(t, /^function[ \t]+[A-Za-z_][A-Za-z0-9_:.-]*/)) {
      name = substr(t, 1, RLENGTH); sub(/.*[ \t]/, "", name)
    } else if (match(t, /^[A-Za-z_][A-Za-z0-9_:.-]*[ \t]*\(\)/)) {
      name = substr(t, 1, RLENGTH); sub(/[ \t]*\(\)$/, "", name)
    }
  }
  if (name == "") next
  sig = text; gsub(/\t/, " ", sig)
  sub(/[ \t]+$/, "", sig); sub(/[ \t]*\{$/, "", sig)
  if (ext == "py") sub(/:$/, "", sig)
  printf "S\t%s\t%d\t%s\t%s\n", file, lno, name, substr(sig, 1, 120)
}'

# Universal Ctags tags on the input (`name<TAB>file<TAB>/^source line$/;"<TAB>kind<TAB>fields`): the same rows as
# above, for the tags that have no scope (top level).
REPOMAP_AWK_CTAGS='BEGIN { FS = "\t" }
/^!/ { next }
{
  if (!match($0, /;"\t/)) next
  fields = substr($0, RSTART + 3)
  if (fields ~ /(^|\t)(scope|class|struct|interface|enum|namespace|function|module|method|trait|impl|union|package|object|variable|type|member):/) next
  name = $1; file = $2
  pat = substr($0, length(name) + length(file) + 3, RSTART - length(name) - length(file) - 3)
  sub(/^\/\^?/, "", pat); sub(/\$?\/$/, "", pat)
  gsub(/\\\//, "/", pat); gsub(/\\\\/, "\\", pat)
  gsub(/\t/, " ", pat); sub(/^[ ]+/, "", pat); sub(/[ ]+$/, "", pat); sub(/[ ]*\{$/, "", pat)
  lno = 0
  if (match(fields, /(^|\t)line:[0-9]+/)) { lno = substr(fields, RSTART, RLENGTH); sub(/.*:/, "", lno) }
  printf "S\t%s\t%d\t%s\t%s\n", file, lno, name, substr(pat, 1, 120)
}'

# `git grep -n` lines of imports on the input, the known files in the file $fl: `I<TAB>file<TAB>imported file` for each
# import that resolves to a file of the tree: relative TypeScript and JavaScript imports and requires, Python imports
# (relative, or from a parent directory of the file), Go imports ending in a directory of the tree, Rust `mod` and
# `use crate::`, `self::`, `super::`, and bash `source`, `.` and `# shellcheck source=` by file name.
REPOMAP_AWK_IMPORTS='function dir(f,   d) { d = f; if (!sub(/\/[^\/]*$/, "", d)) d = ""; return d }
function pj(d, p) { return d == "" ? p : d "/" p }
function norm(p,   n, a, i, k, o) {
  n = split(p, a, "/"); k = 0
  for (i = 1; i <= n; i++) {
    if (a[i] == "" || a[i] == ".") continue
    if (a[i] == "..") { if (k > 0) k--; continue }
    o[++k] = a[i]
  }
  p = ""
  for (i = 1; i <= k; i++) p = p (i > 1 ? "/" : "") o[i]
  return p
}
function add(f, c) { if ((c in known) && c != f && !((f SUBSEP c) in seen)) { seen[f SUBSEP c] = 1; print "I\t" f "\t" c; return 1 } return 0 }
function cands(f, base, list,   n, a, i) {
  n = split(list, a, " ")
  for (i = 1; i <= n; i++) if (add(f, base a[i])) return
}
BEGIN {
  while ((getline l < fl) > 0) {
    known[l] = 1
    b = l; sub(/.*\//, "", b); byname[b] = byname[b] "\n" l
    if (l ~ /\.go$/ && l !~ /_test\.go$/) { d = dir(l); gof[d] = gof[d] "\n" l }
  }
}
{
  rest = substr($0, 6)
  if (!match(rest, /:[0-9]+:/)) next
  f = substr(rest, 1, RSTART - 1); text = substr(rest, RSTART + RLENGTH)
  if (!(f in known)) next
  ext = f; sub(/.*\./, "", ext)
  d = dir(f)
  if (ext ~ /^(ts|tsx|js|jsx|mjs)$/) {
    if (!match(text, /(from|import|require[ \t]*\()[ \t]*[\047"]\.[^\047"]*[\047"]/)) next
    s = substr(text, RSTART, RLENGTH); sub(/^[^\047"]*[\047"]/, "", s); sub(/[\047"].*$/, "", s)
    base = norm(pj(d, s)); stem = base
    sub(/\.(js|mjs|jsx)$/, "", stem)
    if (!add(f, base)) cands(f, base, ".ts .tsx .js .jsx .mjs /index.ts /index.tsx /index.js")
    if (stem != base) cands(f, stem, ".ts .tsx")
  } else if (ext == "py") {
    if (match(text, /^from[ \t]+\.*[A-Za-z0-9_.]*[ \t]+import/)) {
      s = substr(text, 6, RLENGTH - 5); sub(/[ \t]+import$/, "", s); gsub(/[ \t]/, "", s)
    } else if (match(text, /^import[ \t]+[A-Za-z0-9_.]+/)) {
      s = substr(text, 7, RLENGTH - 6); gsub(/[ \t]/, "", s)
    } else next
    dots = 0
    while (substr(s, dots + 1, 1) == ".") dots++
    s = substr(s, dots + 1); gsub(/\./, "/", s)
    if (s == "") next
    if (dots > 0) {
      b = d
      for (i = 1; i < dots; i++) b = dir(b)
      cands(f, norm(pj(b, s)), ".py /__init__.py")
    } else {
      b = d
      while (1) {
        if (add(f, norm(pj(b, s)) ".py") || add(f, norm(pj(b, s)) "/__init__.py")) break
        if (b == "") break
        b = dir(b)
      }
    }
  } else if (ext == "go") {
    if (!match(text, /"[^"]+"/)) next
    q = substr(text, RSTART + 1, RLENGTH - 2)
    while (q != "") {
      if (q in gof) {
        if (q != d) { n = split(gof[q], a, "\n"); for (i = 2; i <= n; i++) add(f, a[i]) }
        break
      }
      if (!sub(/^[^\/]*\//, "", q)) break
    }
  } else if (ext == "rs") {
    if (match(text, /^[ \t]*(pub(\([^)]*\))?[ \t]+)?mod[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]*;/)) {
      s = substr(text, 1, RLENGTH); sub(/[ \t]*;$/, "", s); sub(/.*[ \t]/, "", s)
      stem = f; sub(/\.rs$/, "", stem)
      cands(f, pj(d, s), ".rs /mod.rs")
      if (f !~ /\/(mod|lib|main)\.rs$/ && f !~ /^(mod|lib|main)\.rs$/) cands(f, pj(stem, s), ".rs /mod.rs")
    } else if (match(text, /^[ \t]*(pub(\([^)]*\))?[ \t]+)?use[ \t]+(crate|self|super)::[A-Za-z_][A-Za-z0-9_]*/)) {
      s = substr(text, 1, RLENGTH); sub(/.*::/, "", s)
      if (text ~ /use[ \t]+crate::/) {
        b = d
        while (b != "" && b !~ /(^|\/)src$/) b = dir(b)
        if (b == "") b = d
      } else if (text ~ /use[ \t]+super::/) b = dir(d)
      else b = d
      cands(f, pj(b, s), ".rs /mod.rs")
    }
  } else {
    if (match(text, /shellcheck[ \t]+source=[^ \t]+/)) { s = substr(text, RSTART, RLENGTH); sub(/.*source=/, "", s) }
    else if (match(text, /^[ \t]*(source|\.)[ \t]+[^ \t]+/)) { s = substr(text, RSTART, RLENGTH); sub(/^[ \t]*(source|\.)[ \t]+/, "", s) }
    else next
    gsub(/[\047")]/, "", s); sub(/.*\//, "", s)
    if (s == "" || !(s in byname)) next
    n = split(byname[s], a, "\n"); best = ""; bl = -1
    for (i = 2; i <= n; i++) {
      c = a[i]; if (c !~ /\.(sh|bash)$/) continue
      p = 0; m = length(c) < length(f) ? length(c) : length(f)
      while (p < m && substr(c, p + 1, 1) == substr(f, p + 1, 1)) p++
      if (p > bl) { bl = p; best = c }
    }
    if (best != "") add(f, best)
  }
}'

# The reference counts: the `git grep -o` lines `HEAD:file:token` of every identifier on the input, the known files in
# $fl, the symbol rows in $sy: `R<TAB>name<TAB>number of files other than those that define it which use it`, for the
# defined names.
REPOMAP_AWK_REFS='BEGIN {
  while ((getline l < fl) > 0) known[l] = 1
  FS = "\t"
  while ((getline l < sy) > 0) { split(l, a, "\t"); def[a[4] SUBSEP a[2]] = 1; want[a[4]] = 1 }
  FS = " "
}
{
  rest = substr($0, 6)
  if (!match(rest, /:[^:]*$/)) next
  file = substr(rest, 1, RSTART - 1); tok = substr(rest, RSTART + 1)
  if (!(tok in want) || !(file in known) || ((tok SUBSEP file) in def) || ((tok SUBSEP file) in seen)) next
  seen[tok SUBSEP file] = 1; n[tok]++
}
END { for (t in n) print "R\t" t "\t" n[t] }'

# The index of the tree of HEAD of the repository $1, on the output: the `S` rows (symbols, sorted by file and line),
# the `I` rows (imports) and the `R` rows (reference counts). Nothing when there is no source file. Fails without a commit.
repomap_build() {
  local root=$1 tmp files
  local -a git=(git -C "$root" -c core.quotepath=false)
  tmp=$(mktemp -d) || return 1
  "${git[@]}" ls-tree -r -z --name-only HEAD 2>/dev/null | tr '\0' '\n' | LC_ALL=C awk "$REPOMAP_AWK_FILES" | LC_ALL=C sort >"$tmp/files" || { rm -rf "$tmp"; return 1; }
  if [ -s "$tmp/files" ]; then
    if ! repomap_ctags "$root" "$tmp" >"$tmp/symbols" 2>/dev/null || [ ! -s "$tmp/symbols" ]; then
      "${git[@]}" grep -n -I -E -e "$REPOMAP_PRE_SYMBOL" HEAD -- "${REPOMAP_GLOBS[@]}" 2>/dev/null |
        LC_ALL=C awk -v fl="$tmp/files" "$REPOMAP_AWK_SYMBOLS" >"$tmp/symbols" || : >"$tmp/symbols"
    fi
    LC_ALL=C sort -t $'\t' -k2,2 -k3,3n -k4,4 "$tmp/symbols" || true
    "${git[@]}" grep -n -I -E -e "$REPOMAP_PRE_IMPORT" HEAD -- "${REPOMAP_GLOBS[@]}" 2>/dev/null |
      LC_ALL=C awk -v fl="$tmp/files" "$REPOMAP_AWK_IMPORTS" | LC_ALL=C sort || true
    if [ -s "$tmp/symbols" ]; then
      "${git[@]}" grep -I -o -E -e '[A-Za-z_][A-Za-z0-9_]*' HEAD -- "${REPOMAP_GLOBS[@]}" 2>/dev/null |
        LC_ALL=C awk -v fl="$tmp/files" -v sy="$tmp/symbols" "$REPOMAP_AWK_REFS" | LC_ALL=C sort || true
    fi
  fi
  rm -rf "$tmp"
}

# The `S` rows from Universal Ctags, when it is installed and answers: it reads an export of HEAD (the tree the index is
# named after) with the files of $2/files. Fails otherwise.
repomap_ctags() {
  local root=$1 tmp=$2
  command -v ctags >/dev/null 2>&1 || return 1
  ctags --version 2>/dev/null | grep -q 'Universal Ctags' || return 1
  mkdir "$tmp/tree" || return 1
  git -C "$root" archive HEAD | tar -x -C "$tmp/tree" 2>/dev/null || return 1
  (cd "$tmp/tree" && ctags -L - -f - --sort=no --fields=+nS <"$tmp/files") 2>/dev/null |
    LC_ALL=C awk "$REPOMAP_AWK_CTAGS" || true
}

# The repo map of the Paths $2 (a JSON array of globs) of the repository $1 within $3 tokens, as lines `- file: signature`
# in rank order: the symbols of the files of the Paths and of the files they import; the more files other than their own
# reference a symbol, the higher; then the longer the literal prefix of the Paths it sits under (what is imported has none).
# The index is read from `senior-mode/repomap/<tree-sha>` of the git directory, built there when the tree has none.
repomap_lines() {
  local root=$1 tp=$2 limit=$(($3 * 4 - ${#REPOMAP_HEAD} - 1)) tree dir index prefixes
  [ "$limit" -gt 0 ] || return 0
  tree=$(git -C "$root" rev-parse --verify -q 'HEAD^{tree}') || return 0
  dir=$(git -C "$root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 0
  dir=$dir/senior-mode/repomap
  index=$dir/$tree
  if [ ! -f "$index" ]; then
    mkdir -p "$dir" 2>/dev/null || return 0
    repomap_build "$root" >"$index.tmp.$$" && mv -f "$index.tmp.$$" "$index" 2>/dev/null || { rm -f "$index.tmp.$$"; return 0; }
    # shellcheck disable=SC2012 # the names are tree shas
    (cd "$dir" && ls -t | tail -n +6 | xargs -r rm -f) 2>/dev/null || true
  fi
  prefixes=$(jq -r "$PATHS_DEF"'.[] | gstatic | if . == "" then "." else . end' <<<"$tp" 2>/dev/null) || return 0
  PRE=$prefixes LC_ALL=C awk -F'\t' '
    function score(f,   i, s, m) {
      m = -1
      for (i = 1; i <= np; i++) {
        if (pre[i] == "." || f == pre[i] || index(f, pre[i] "/") == 1) { s = (pre[i] == "." ? 0 : length(pre[i])) + 1; if (s > m) m = s }
      }
      return m
    }
    BEGIN { np = split(ENVIRON["PRE"], pre, "\n") }
    $1 == "S" { ns++; sf[ns] = $2; sl[ns] = $3; sn[ns] = $4; sg[ns] = $5 }
    $1 == "I" { imp[$2] = imp[$2] "\n" $3 }
    $1 == "R" { refs[$2] = $3 }
    END {
      for (f in imp) if (score(f) > 0) { n = split(imp[f], a, "\n"); for (i = 2; i <= n; i++) imported[a[i]] = 1 }
      for (i = 1; i <= ns; i++) {
        f = sf[i]; s = score(f)
        if (s <= 0) { if (f in imported) s = 0; else continue }
        printf "%d\t%d\t%s\t%d\t- %s: %s\n", refs[sn[i]] + 0, s, f, sl[i], f, sg[i]
      }
    }' "$index" |
    LC_ALL=C sort -t $'\t' -k1,1nr -k2,2nr -k3,3 -k4,4n |
    LC_ALL=C awk -F'\t' -v lim="$limit" '{ b += length($5) + 1; if (b > lim) exit; print $5 }' || true
}
