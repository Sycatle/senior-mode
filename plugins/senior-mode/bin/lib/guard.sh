# shellcheck shell=bash
# The secret scan of `check` (#143, spec 130): the lines added by <base>...HEAD against the patterns of the
# plugin (`secret-patterns`). Prints `file:line: kind` for each finding, never the value; exit 1 when there
# is one. A value whose sha256 is in `.claude/secret-allowlist` of the base, with a reason, is lifted: a
# branch cannot allowlist its own secret. Runs as its own process (`senior-mode secret-scan`).
secret_scan() {
  local base patterns allow added kind mode re n value raw findings flags path line sep=$'\x1f'
  base=$(default_branch) || {
    echo "skipped: no base branch"
    return 0
  }
  patterns=$(dirname "$SELF")/../secret-patterns
  [ -f "$patterns" ] || die "secret patterns not found: $patterns"
  allow=$(git show "$base:.claude/secret-allowlist" 2>/dev/null |
    grep -E '^[0-9a-f]{64}[[:space:]]+[^[:space:]]' | cut -c1-64) || true
  added=$(mktemp)
  # The copy holds the secrets of the diff: it goes away whatever way this process ends.
  # shellcheck disable=SC2064 # expand now: $added is local and gone when the trap runs
  trap "rm -f '$added'" EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  # The added lines as <file> <line> <text>. A "+++ " line is a file header only before the first hunk.
  git -c core.quotePath=false diff -U0 --no-color --no-ext-diff --no-textconv --no-renames --no-prefix \
    "$base...HEAD" | awk -v s="$sep" '
    /^diff / { header = 1; next }
    header && /^\+\+\+ / { file = substr($0, 5); sub(/\t$/, "", file); next }
    /^@@ / { header = 0; if (match($0, /\+[0-9]+/)) n = substr($0, RSTART + 1, RLENGTH - 1) + 0; next }
    !header && /^\+/ { printf "%s%s%d%s%s\n", file, s, n, s, substr($0, 2); n++ }' >"$added" ||
    die "cannot compare with $base"
  # One grep and one awk per pattern, not one process per matching line: grep -n gives the number of the line
  # of $added, awk drops what is not a secret, and only a finding costs a hash. A finding is <n> <kind>.
  raw=$(
    while IFS=$'\t' read -r kind mode re; do
      case $kind in "" | "#"*) continue ;; esac
      flags=(-noE)
      [ "$mode" != assign ] || flags=(-i -noE)
      cut -d "$sep" -f 3- "$added" | { grep "${flags[@]}" -- "$re" || true; } | awk -v mode="$mode" -v kind="$kind" -v s="$sep" '
        { i = index($0, ":"); n = substr($0, 1, i - 1); m = substr($0, i + 1); v = m }
        mode == "assign" {
          # The value, not the name. A name only looks like a secret when its value holds letters and
          # digits and is neither a placeholder nor a dotted identifier (process.env.TOKEN_1).
          sub(/^[^:=]*[:=][ \t]*["'"'"']?/, "", v)
          if (v !~ /[0-9]/ || v !~ /[A-Za-z]/ || v ~ /^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)+$/) next
          if (tolower(v) ~ /example|changeme|placeholder|your|dummy|sample|xxxx/) next
        }
        mode == "url" {
          # A password is not reported when the whole of it is one template form (${X}, $(X), $X, {X}, {{X}},
          # %(x)s, %s, <x>, ***) or, below, a placeholder word, digits kept: a short password, or Secret123, is a
          # real one, and so is one that merely contains a template (Zq9{x}). X is an identifier. A password that
          # is only $name or {name} stays a template. No {n,m} interval: mawk, BSD awk and busybox do not all read it.
          pw = m
          sub(/^[^:]*:\/\/[^:\/@]*:/, "", pw)
          sub(/@.*/, "", pw)
          if (pw ~ /^([$][{][A-Za-z_][A-Za-z0-9_]*[}]|[$][(][A-Za-z_][A-Za-z0-9_]*[)]|[$][A-Za-z_][A-Za-z0-9_]*|[{][A-Za-z_][A-Za-z0-9_]*[}]|[{][{][A-Za-z_][A-Za-z0-9_]*[}][}]|%[(][A-Za-z_][A-Za-z0-9_]*[)]s|(%s)+|<[A-Za-z_][A-Za-z0-9_-]*>|[*][*][*]+)$/) next
          w = tolower(pw)
          gsub(/[_-]/, "", w)
          if (w ~ /^(pass(word|wd)?|secret|example|changeme|changeit|placeholder|dummy|sample|test(ing)?|user(name)?|(your|my)(pass(word|wd)?|secret)?(here)?)$/ || w ~ /^xxx+$/) next
        }
        { printf "%s%s%s%s%s\n", n, s, kind, s, (mode == "block" ? "" : v) }'
    done <"$patterns" |
      while IFS=$sep read -r n kind value; do
        # Only a block needs its lines: the whole key, so that the header, public text, lifts nothing but itself.
        if [ -z "$value" ]; then
          IFS=$sep read -r path line _ < <(sed -n "${n}p" "$added")
          value=$(awk -F"$sep" -v p="$path" -v l="$line" '
            $1 == p && $2 + 0 >= l {
              if (c && $2 + 0 != prev + 1) exit
              prev = $2 + 0
              printf "%s%s", (c++ ? "\n" : ""), $3
              if ($3 ~ /-----END /) exit
            }' "$added")
        fi
        [ -z "$allow" ] || ! grep -qxF "$(sha256 "$value")" <<<"$allow" || continue
        printf '%s%s%s\n' "$n" "$sep" "$kind"
      done
  )
  [ -n "$raw" ] || return 0
  findings=$(awk -F"$sep" '
    NR == FNR { if (!(($1 SUBSEP $2) in seen)) { seen[$1, $2] = 1; k[$1, ++c[$1]] = $2 }; next }
    FNR in c { for (j = 1; j <= c[FNR]; j++) printf "%s:%s: %s\n", $1, $2, k[FNR, j] }' \
    <(printf '%s\n' "$raw") "$added" | sort -t: -k1,1 -k2,2n | uniq) || true
  printf '%s\n' "$findings"
  echo "a value is lifted by \"<sha256 of the value> <reason>\" in .claude/secret-allowlist on $base (printf %s <value> | sha256sum)"
  return 1
}

# The dependency audit of `check` (#142, spec 130): the audit tool of each lockfile at the repository root
# (pnpm-lock.yaml or package-lock.json, requirements.txt, go.sum, Cargo.lock), its JSON read into advisories.
# A high or critical advisory fails, naming package, advisory and fixed version; any other is a warning, an
# advisory with no severity too (pip-audit, govulncheck and cargo audit give none; Dependabot covers it).
# A missing tool, or one that gives no usable answer, fails: nothing was audited. Runs as its own process
# (`senior-mode audit`).
audit_scan() {
  local root rc=0 found=false eco err
  audit_enabled || {
    echo "skipped: off (audit: false)"
    return 0
  }
  root=$(git rev-parse --show-toplevel)
  err=$(mktemp)
  # shellcheck disable=SC2064 # expand now: $err is local and gone when the trap runs
  trap "rm -f '$err'" EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  for eco in pnpm:pnpm-lock.yaml npm:package-lock.json pip:requirements.txt go:go.sum cargo:Cargo.lock; do
    [ -f "$root/${eco#*:}" ] || continue
    # pnpm's lockfile wins over a leftover package-lock.json.
    [ "${eco%%:*}" != npm ] || [ ! -f "$root/pnpm-lock.yaml" ] || continue
    found=true
    audit_one "$root" "${eco%%:*}" "$err" || rc=1
  done
  [ "$found" = true ] || echo "skipped: no lockfile (package-lock.json, pnpm-lock.yaml, requirements.txt, go.sum, Cargo.lock)"
  return "$rc"
}

# Audits the project at $1 with the tool of ecosystem $2 (stderr to the file $3). The filter turns the
# tool's JSON (all of it, as an array of documents) into [{severity, package, advisory, fixed}]; it fails on
# a document that is not that tool's report, so an error answer is never read as a clean audit.
# shellcheck disable=SC2016 # jq programs, not shell
audit_one() {
  local root=$1 eco=$2 err=$3 bin hint filter maxrc=1 out rc=0 adv reason line limit=${SENIOR_MODE_AUDIT_TIMEOUT:-600}
  local argv=() bound=()
  case $eco in
    npm)
      bin=npm hint="install Node.js from https://nodejs.org" argv=(npm audit --json)
      # via lists the advisories (objects) and the packages vulnerable through another (strings).
      filter='[.[0].vulnerabilities | to_entries[].value as $v | $v.via[] | select(type == "object")
        | {severity, package: .name, advisory: ((.url // .title) | split("/") | last),
           fixed: ($v.fixAvailable | if type == "object" then (if .name == $v.name then .version else "\(.name) \(.version)" end)
             elif . == true then "a newer version (npm audit fix)" else "" end)}]'
      ;;
    pnpm)
      bin=pnpm hint="run npm install -g pnpm" argv=(pnpm audit --json)
      filter='[.[0].advisories | to_entries[].value | {severity, package: .module_name,
        advisory: (.github_advisory_id // (.url | split("/") | last)),
        fixed: (if (.patched_versions // "") | IN("", "<0.0.0") then "" else .patched_versions end)}]'
      ;;
    pip)
      # pip-audit before 2.7 printed the list of dependencies itself.
      bin=pip-audit hint="run pipx install pip-audit (or pip install pip-audit)" argv=(pip-audit -r requirements.txt -f json)
      # A dependency it skipped (a local path, -e, not on the index) has a skip_reason and no vulns.
      filter='[(.[0] | if type == "array" then . else .dependencies end)[] | . as $d
        | ((.vulns // [])[] | {severity: null, package: $d.name, advisory: .id, fixed: ((.fix_versions // []) | join(", "))}),
          (select(.skip_reason) | {severity: null, package: $d.name, skipped: .skip_reason})]'
      ;;
    go)
      # govulncheck -json exits 0 whatever it finds. A finding whose first frame names a function is a
      # vulnerability the code calls; the others only require or import the module.
      bin=govulncheck hint="run go install golang.org/x/vuln/cmd/govulncheck@latest" argv=(govulncheck -json ./...)
      maxrc=0
      filter='[.[] | select(.finding) | .finding | select(.trace[0].function)
        | {severity: null, package: .trace[0].module, advisory: .osv, fixed: (.fixed_version // "")}]'
      ;;
    cargo)
      bin=cargo-audit hint="run cargo install cargo-audit --locked" argv=(cargo audit --json)
      filter='[.[0].vulnerabilities.list[] | {severity: null, package: .package.name, advisory: .advisory.id,
        fixed: ((.versions.patched // []) | join(", "))}]'
      ;;
  esac
  command -v "$bin" >/dev/null || {
    echo "$bin not installed: $hint"
    return 1
  }
  # A tool that hangs (a registry that does not answer) would hang `check` and the pre-push hook with it.
  ! command -v timeout >/dev/null || bound=(timeout "$limit")
  out=$(cd "$root" && ${bound[@]+"${bound[@]}"} "${argv[@]}" 2>"$err") || rc=$?
  if [ -n "$out" ] && [ "$rc" -le "$maxrc" ] &&
    adv=$(jq -sc "$filter | map(.severity |= (if . == null then null else ascii_downcase end)) | unique" <<<"$out" 2>/dev/null); then
    :
  else
    if [ "$rc" -eq 124 ] && [ ${#bound[@]} -gt 0 ]; then
      echo "${argv[*]}: timed out after $limit s (SENIOR_MODE_AUDIT_TIMEOUT), nothing was audited"
      return 1
    fi
    echo "${argv[*]}: no usable answer (exit $rc)"
    # What the tool says of itself: an error object on stdout (npm, pnpm), else its last words on stderr.
    reason=$({ jq -r '(.error // empty) | if type == "object" then (.summary // .message // empty) else . end' <<<"$out" 2>/dev/null
      tail -n 3 "$err"; } | { grep -v '^[[:space:]]*$' || true; } | head -n 3)
    reason=${reason:-the tool gave no output (offline?)}
    echo "  ${reason//$'\n'/$'\n'  }"
    return 1
  fi
  # A dependency a tool skipped is a warning with its reason; any other line names the advisory.
  line='def line: if .skipped then "not audited: \(.package) (\(.skipped))"
    else "\(.severity // "no severity"): \(.package) \(.advisory), "
      + (if .fixed == "" then "no fixed version" else "fixed in \(.fixed)" end) end;'
  jq -r "$line"'.[] | select(.severity | IN("high", "critical") | not) | "warning: " + line' <<<"$adv" |
    audit_cap 20 "warning: ... " warnings
  # Blocking lines come last, whole up to a generous cap: `check` shows the end of a failure.
  jq -r "$line"'.[] | select(.severity | IN("high", "critical")) | line' <<<"$adv" | audit_cap 100 "... " "blocking advisories"
  [ "$(jq '[.[] | select(.severity | IN("high", "critical"))] | length' <<<"$adv")" -eq 0 ]
}

# Prints at most $1 lines of stdin, then "<$2><n> more <$3>".
audit_cap() {
  local n=$1 more=$2 what=$3 total=0 line
  while IFS= read -r line; do
    total=$((total + 1))
    [ "$total" -gt "$n" ] || printf '%s\n' "$line"
  done
  [ "$total" -le "$n" ] || echo "$more$((total - n)) more $what"
  return 0
}

# The registry dependencies a manifest declares, one name per line, from its text on stdin; $1 is its file name.
# Local, git and URL dependencies are left out: no registry holds them. An npm alias (x: "npm:real@1") names the
# real package; a PyPI name is normalized (PEP 503); a Go module is the path `require` names, indirect ones left out.
# shellcheck disable=SC2016 # jq and awk programs, not shell
deps_names() {
  case $1 in
    package.json)
      jq -r '[.dependencies, .devDependencies, .optionalDependencies, .peerDependencies | objects | to_entries[]
        | select(.value | type == "string")
        | if (.value | startswith("npm:")) then .value[4:] | sub("@[^@/]*$"; "")
          elif (.value | test("^(workspace|file|link|git|git\\+[a-z]+|github|gitlab|bitbucket|https?|portal|patch):|^[./~]")) then empty
          else .key end] | unique[]' 2>/dev/null || true
      ;;
    requirements*.txt)
      awk '{ sub(/[ \t]#.*/, ""); sub(/^#.*/, "") }
        /^[ \t]*-/ || /:\/\// { next }
        match($0, /^[ \t]*[A-Za-z0-9][A-Za-z0-9._-]*/) { n = substr($0, RSTART, RLENGTH); gsub(/[ \t]/, "", n); print n }'
      ;;
    pyproject.toml)
      # [project] dependencies and optional-dependencies (arrays of PEP 508 strings), and Poetry's dependency tables.
      awk 'function name(s) { if (match(s, /^[A-Za-z0-9][A-Za-z0-9._-]*/)) print substr(s, RSTART, RLENGTH) }
        function strings(line,   q) { while (match(line, /"[^"]*"|'"'"'[^'"'"']*'"'"'/)) {
            q = substr(line, RSTART + 1, RLENGTH - 2); if (q !~ /:\/\//) name(q); line = substr(line, RSTART + RLENGTH) } }
        /^[ \t]*\[/ { sect = $0; gsub(/[ \t]/, "", sect); arr = 0; next }
        arr { strings($0); if ($0 ~ /\]/) arr = 0; next }
        (sect == "[project]" && /^[ \t]*dependencies[ \t]*=/) || sect == "[project.optional-dependencies]" {
          if (!/=/) next
          v = $0; sub(/^[^=]*=/, "", v); strings(v); if (v ~ /\[/ && v !~ /\]/) arr = 1; next }
        sect ~ /^\[tool\.poetry\.((group\.[^.]+\.)?dependencies|dev-dependencies)\]$/ && /=/ {
          if (/(path|git|url)[ \t]*=/) next
          k = $0; sub(/[ \t]*=.*/, "", k); gsub(/["'"'"' \t]/, "", k); if (k != "python") name(k) }'
      ;;
    Cargo.toml)
      # [dependencies], [dev-dependencies], [build-dependencies], [target.*.dependencies], [workspace.dependencies],
      # and the [dependencies.<name>] form. A path or git dependency is left out; `package = "x"` renames.
      awk 'function out() { if (pend != "" && !local) print pend; pend = ""; local = 0 }
        /^[ \t]*\[/ { out(); h = $0; gsub(/[ \t\[\]]/, "", h); tab = 0
          if (h ~ /(^|\.)((dev|build)-)?dependencies$/) tab = 1
          else if (match(h, /(^|\.)((dev|build)-)?dependencies\./)) { pend = substr(h, RSTART + RLENGTH); local = 0 }
          next }
        pend != "" { if (/^[ \t]*(path|git)[ \t]*=/) local = 1
          if (/^[ \t]*package[ \t]*=/) { p = $0; sub(/^[^=]*=[ \t]*"/, "", p); sub(/".*/, "", p); pend = p }
          next }
        tab && /=/ {
          k = $0; sub(/[ \t]*=.*/, "", k); gsub(/["'"'"' \t]/, "", k)
          if (k ~ /\.workspace$/ || /workspace[ \t]*=[ \t]*true/ || /(path|git)[ \t]*=/) next
          if (match($0, /package[ \t]*=[ \t]*"[^"]*"/)) { k = substr($0, RSTART, RLENGTH); sub(/^[^"]*"/, "", k); sub(/"$/, "", k) }
          print k }
        END { out() }'
      ;;
    go.mod)
      awk '/^[ \t]*\/\// { next }
        /^require[ \t]*\(/ { blk = 1; next }
        blk && /^[ \t]*\)/ { blk = 0; next }
        /\/\/[ \t]*indirect/ { next }
        blk && NF >= 2 { print $1; next }
        /^require[ \t]/ && NF >= 3 { print $2 }'
      ;;
  esac
}

# The ecosystem of a manifest file name: npm, pypi, crates or go; nothing for another file.
deps_ecosystem() {
  case $1 in
    package.json) echo npm ;;
    requirements*.txt | pyproject.toml) echo pypi ;;
    Cargo.toml) echo crates ;;
    go.mod) echo go ;;
  esac
}

# The dependencies the branch adds, as "<ecosystem> <name>" lines: those of the manifests it changes (at HEAD) that
# the same manifest did not declare where the branch left $1.
deps_added() {
  local from=$1 path file eco
  git -c core.quotePath=false diff --name-only --no-renames --diff-filter=AM "$from" HEAD | while IFS= read -r path; do
    file=${path##*/}
    eco=$(deps_ecosystem "$file")
    [ -n "$eco" ] || continue
    comm -23 <(git show "HEAD:$path" 2>/dev/null | deps_names "$file" | deps_normal "$eco" | sort -u) \
      <(git show "$from:$path" 2>/dev/null | deps_names "$file" | deps_normal "$eco" | sort -u) | sed "s/^/$eco /"
  done | sort -u
}

# PyPI names compare as PEP 503 says (case and runs of -_. do not matter); other names are kept as they are.
deps_normal() {
  if [ "$1" = pypi ]; then tr 'A-Z' 'a-z' | sed -E 's/[-_.]+/-/g'; else cat; fi
}

# GETs $1 into the file $2 and prints the HTTP code; fails when the registry could not be reached.
deps_get() {
  curl -sS -L --max-time "${SENIOR_MODE_REGISTRY_TIMEOUT:-15}" -A "senior-mode dependency check" -o "$2" -w '%{http_code}' "$1" 2>/dev/null
}

# What the registry of ecosystem $1 says of package $2, as "<verdict> <created epoch> <weekly downloads>": verdict
# found, missing or offline; a creation date or a download count it does not give is "-". $3 is a scratch file.
# shellcheck disable=SC2016 # jq programs, not shell
deps_lookup() {
  local eco=$1 name=$2 tmp=$3 code created="-" weekly="-" esc v first
  local iso='sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601'
  case $eco in
    npm)
      code=$(deps_get "https://registry.npmjs.org/${name/\//%2F}" "$tmp") || { echo offline; return; }
      [ "$code" != 404 ] || { echo missing; return; }
      [ "$code" = 200 ] || { echo offline; return; }
      created=$(jq -r "(.time.created // empty) | $iso" "$tmp" 2>/dev/null) || created=""
      if [ "$(deps_get "https://api.npmjs.org/downloads/point/last-week/$name" "$tmp")" = 200 ]; then
        weekly=$(jq -r '.downloads // empty' "$tmp" 2>/dev/null) || weekly=""
      fi
      ;;
    pypi)
      code=$(deps_get "https://pypi.org/pypi/$name/json" "$tmp") || { echo offline; return; }
      [ "$code" != 404 ] || { echo missing; return; }
      [ "$code" = 200 ] || { echo offline; return; }
      created=$(jq -r "[.releases[][]?.upload_time_iso_8601 | select(.)] | min // empty | $iso" "$tmp" 2>/dev/null) || created=""
      if [ "$(deps_get "https://pypistats.org/api/packages/$name/recent" "$tmp")" = 200 ]; then
        weekly=$(jq -r '.data.last_week // empty' "$tmp" 2>/dev/null) || weekly=""
      fi
      ;;
    crates)
      code=$(deps_get "https://crates.io/api/v1/crates/$name" "$tmp") || { echo offline; return; }
      [ "$code" != 404 ] || { echo missing; return; }
      [ "$code" = 200 ] || { echo offline; return; }
      created=$(jq -r "(.crate.created_at // empty) | $iso" "$tmp" 2>/dev/null) || created=""
      # crates.io counts the last 90 days: about 13 weeks.
      weekly=$(jq -r '.crate.recent_downloads // empty | . / 13 | floor' "$tmp" 2>/dev/null) || weekly=""
      ;;
    go)
      # The module proxy escapes capitals as !<lower>; it gives no download counts.
      esc=$(sed -E 's/([A-Z])/!\1/g' <<<"$name" | tr 'A-Z' 'a-z')
      code=$(deps_get "https://proxy.golang.org/$esc/@v/list" "$tmp") || { echo offline; return; }
      [[ $code != 404 && $code != 410 ]] || { echo missing; return; }
      [ "$code" = 200 ] || { echo offline; return; }
      # The age of the oldest version; a module with only pseudo-versions has none listed: its latest.
      first=$({ grep -v '^$' "$tmp" || true; } | sort -V | head -n 1)
      v="https://proxy.golang.org/$esc/@latest"
      [ -z "$first" ] || v="https://proxy.golang.org/$esc/@v/$first.info"
      code=$(deps_get "$v" "$tmp") || { echo offline; return; }
      [[ $code != 404 && $code != 410 ]] || { echo missing; return; }
      [ "$code" = 200 ] || { echo offline; return; }
      created=$(jq -r "(.Time // empty) | $iso" "$tmp" 2>/dev/null) || created=""
      ;;
  esac
  echo "found ${created:--} ${weekly:--}"
}

# The popular names within one or two edits of $2 (one for a name of up to five letters), from the list of
# ecosystem $1 in `popular-packages`; nothing when $2 is itself on it.
deps_near() {
  awk -v eco="$1" -v n="$2" '
    function lev(a, b,   i, j, la, lb, c, d, prev, cur) {
      la = length(a); lb = length(b)
      for (j = 0; j <= lb; j++) prev[j] = j
      for (i = 1; i <= la; i++) {
        cur[0] = i
        for (j = 1; j <= lb; j++) {
          c = prev[j - 1] + (substr(a, i, 1) != substr(b, j, 1))
          d = prev[j] + 1; if (d < c) c = d
          d = cur[j - 1] + 1; if (d < c) c = d
          cur[j] = c
        }
        for (j = 0; j <= lb; j++) prev[j] = cur[j]
      }
      return prev[lb]
    }
    BEGIN { max = length(n) > 5 ? 2 : 1 }
    $1 == eco { p[$2] = 1 }
    END {
      if (n in p) exit
      for (q in p) { d = length(q) - length(n); if (d < 0) d = -d; if (d <= max && lev(n, q) <= max) out = out (out == "" ? "" : ", ") q }
      if (out != "") print out
    }' "$(dirname "$SELF")/../popular-packages"
}

# The dependency check of `check` (#302): each dependency the branch adds to a package.json, requirements*.txt,
# pyproject.toml, Cargo.toml or go.mod is looked up on its registry. It fails when the package does not exist (an
# invented name), was first published less than security.minPackageAgeDays days ago, or had fewer than
# security.minWeeklyDownloads downloads last week (Go's proxy gives none). A name one or two edits from a popular
# package is a warning. A registry that cannot be reached leaves its packages unchecked, said as such, never passed.
# Runs as its own process (`senior-mode deps`).
deps_scan() {
  local base from added eco name tmp verdict created weekly days floor now near fails="" warns="" unchecked="" checked=0
  base=$(default_branch) || {
    echo "skipped: no base branch"
    return 0
  }
  from=$(git merge-base "$base" HEAD) || die "cannot compare with $base"
  added=$(deps_added "$from")
  [ -n "$added" ] || {
    echo "skipped: no new dependency"
    return 0
  }
  days=$(config_get security.minPackageAgeDays)
  floor=$(config_get security.minWeeklyDownloads)
  [[ $days =~ ^[1-9][0-9]*$ ]] || die "security.minPackageAgeDays must be a whole number of days from 1, not $days"
  [[ $floor =~ ^[1-9][0-9]*$ ]] || die "security.minWeeklyDownloads must be a whole number from 1, not $floor"
  command -v curl >/dev/null || {
    echo "skipped: curl not installed, so the new dependencies were not checked: $(paste -sd, - <<<"$added" | sed 's/,/, /g')"
    return 0
  }
  tmp=$(mktemp)
  # shellcheck disable=SC2064 # expand now: $tmp is local and gone when the trap runs
  trap "rm -f '$tmp'" EXIT
  now=$(date +%s)
  while read -r eco name; do
    read -r verdict created weekly < <(deps_lookup "$eco" "$name" "$tmp")
    case $verdict in
      offline)
        unchecked+="${unchecked:+, }$eco $name"
        continue
        ;;
      missing) fails+="$eco $name: not on the registry; an invented or mistyped name?"$'\n' ;;
      found)
        if ! [[ $created =~ ^[0-9]+$ ]]; then
          warns+="warning: $eco $name: the registry gives no publication date, its age was not checked"$'\n'
        elif [ $(((now - created) / 86400)) -lt "$days" ]; then
          fails+="$eco $name: first published $(((now - created) / 86400)) days ago, under security.minPackageAgeDays ($days)"$'\n'
        fi
        if [[ $weekly =~ ^[0-9]+$ ]] && [ "$weekly" -lt "$floor" ]; then
          fails+="$eco $name: $weekly downloads last week, under security.minWeeklyDownloads ($floor)"$'\n'
        fi
        ;;
    esac
    checked=$((checked + 1))
    near=$(deps_near "$eco" "$name")
    [ -z "$near" ] || warns+="warning: $eco $name: one or two letters from the popular $near; is it the package you meant?"$'\n'
  done <<<"$added"
  if [ "$checked" -eq 0 ]; then
    echo "skipped: no registry answered, so the new dependencies were not checked: $unchecked"
    return 0
  fi
  [ -z "$unchecked" ] || warns+="warning: not checked, the registry did not answer: $unchecked"$'\n'
  printf '%s' "$warns"
  [ -n "$fails" ] || return 0
  printf '%s' "$fails"
  echo "a dependency that is right after all: wait until it is old enough, or pick a better known package"
  return 1
}

# The machine-wide directory of the lock files `$1` (flock), made on first use: under XDG_RUNTIME_DIR, else
# a private senior-mode-$1-<uid> directory of TMPDIR. Other users share /tmp, so a directory that is a link,
# not ours or open to others is refused.
lock_dir() {
  local dir
  if [ -n "${XDG_RUNTIME_DIR:-}" ]; then
    dir=$XDG_RUNTIME_DIR/senior-mode-$1
  else
    dir=${TMPDIR:-/tmp}/senior-mode-$1-$(id -u)
  fi
  [ -L "$dir" ] || [ -d "$dir" ] || mkdir -m 700 "$dir" 2>/dev/null || [ -d "$dir" ] ||
    die "cannot create the $1 lock directory $dir"
  { [ ! -L "$dir" ] && [ "$(file_owner "$dir")" = "$(id -u)" ] && [ "$(file_mode "$dir")" = 700 ]; } ||
    die "$1 lock directory $dir must be a real directory owned by you with mode 0700; remove it or fix it"
  printf '%s\n' "$dir"
}

# senior-mode e2e-lock -- <command>...: runs the command once one of `e2e.slots` machine-wide slots
# is free (flock), so parallel tickets never run more end-to-end suites at once than the machine
# holds. The command sees its slot number in SENIOR_MODE_E2E_SLOT (for example to pick a port).
e2e_lock() {
  [ "${1:-}" = -- ] && [ $# -ge 2 ] || usage
  shift
  local slots dir i fd waited=false rc
  slots=$(config_get e2e.slots 2>/dev/null) || slots=2
  [[ $slots =~ ^[1-9][0-9]*$ ]] || die "e2e.slots must be a positive number, not $slots"
  command -v flock >/dev/null || die "e2e-lock needs flock (util-linux)"
  dir=$(lock_dir e2e) || exit 1
  while :; do
    for ((i = 1; i <= slots; i++)); do
      exec {fd}>>"$dir/slot-$i"
      if flock -n "$fd"; then
        set +e
        SENIOR_MODE_E2E_SLOT=$i "$@"
        rc=$?
        exit "$rc"
      fi
      exec {fd}>&-
    done
    [ "$waited" = true ] || echo "senior-mode: waiting for a free e2e slot ($slots in use)" >&2
    waited=true
    sleep "${SENIOR_MODE_LOCK_POLL:-2}"
  done
}

# Takes the lowest free slot of 1..$1 for this repository, waiting when all are taken (#153): sets SLOT and
# holds its flock on a descriptor of this shell, so the slot stays taken while this process or anything that
# inherited the descriptor lives, and is free the moment they are gone, whatever way they end. The lock
# files are per repository (its name and the checksum of its path, as `worktree_path`), machine-wide.
slot_acquire() {
  local slots=$1 dir key i fd waited=false common main
  common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || die "not inside a git repository"
  main=$(dirname "$common")
  key=$(basename "$main")-$(printf '%08x' "$(printf '%s' "$main" | cksum | cut -d' ' -f1)")
  dir=$(lock_dir slots) || exit 1
  while :; do
    for ((i = 1; i <= slots; i++)); do
      exec {fd}>>"$dir/$key-$i"
      if flock -n "$fd"; then
        SLOT=$i
        return 0
      fi
      exec {fd}>&-
    done
    [ "$waited" = true ] || echo "senior-mode: waiting for a free slot ($slots in use)" >&2
    waited=true
    sleep "${SENIOR_MODE_LOCK_POLL:-2}"
  done
}

# The environment the project's `slot` command derives for slot $1, as KEY=VALUE lines: the command runs in
# the current directory with SENIOR_MODE_SLOT set; blank lines and `#` comments are skipped. A command that
# fails, a line that is not KEY=VALUE and a SENIOR_MODE_ name (the guards read those) are refused.
slot_env() {
  local cmd out line key
  cmd=$(config_get slot)
  [ -n "$cmd" ] || return 0
  out=$(SENIOR_MODE_SLOT=$1 bash -c "$cmd" </dev/null) || die "the slot command failed: $cmd"
  while IFS= read -r line || [ -n "$line" ]; do
    case $line in "" | "#"*) continue ;; esac
    key=${line%%=*}
    [[ $line == *=* && $key =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "the slot command must print KEY=VALUE lines, not: $line"
    [[ $key != SENIOR_MODE_* ]] || die "the slot command cannot set $key: SENIOR_MODE_ names are reserved"
    printf '%s\n' "$line"
  done <<<"$out"
}

# senior-mode slot -- <command>...: runs the command in a slot of its own, of `autonomy.parallel` per
# repository (SENIOR_MODE_SLOTS when a run has more): SENIOR_MODE_SLOT=N, plus the KEY=VALUE lines of the
# project's `slot` command (a port, a database, a cache directory) exported. `run` starts every session
# through it, so two sessions never share a slot. It takes the process over (exec), the slot stays
# taken with the descriptor until the command and its children are gone.
slot() {
  [ "${1:-}" = -- ] && [ $# -ge 2 ] || usage
  shift
  local slots=${SENIOR_MODE_SLOTS:-} SLOT env line
  unset SENIOR_MODE_SLOTS
  [ -n "$slots" ] || slots=$(config_get autonomy.parallel)
  [[ $slots =~ ^[1-9][0-9]*$ ]] || die "the number of slots (autonomy.parallel) must be a positive number, not $slots"
  command -v flock >/dev/null || die "slot needs flock (util-linux)"
  slot_acquire "$slots"
  env=$(slot_env "$SLOT") || exit 1
  while IFS= read -r line; do
    # shellcheck disable=SC2163 # $line is the whole assignment, NAME=VALUE
    [ -z "$line" ] || export "$line"
  done <<<"$env"
  export SENIOR_MODE_SLOT=$SLOT
  exec "$@"
}

# Files changed on this branch since it left the base (default: the default branch) that match a
# glob of `protected` in the config (spec 0001 §10). Prints them; exit 1 when there is none.
# A glob without a slash matches a name at any depth; with a slash it is anchored at the repository
# root: `*` stays in one path segment, `**/` spans any number of directories, `?` is one character.
# shellcheck disable=SC2016 # a jq program, not shell
protected() {
  local base="" file globs files matches
  while [ $# -gt 0 ]; do
    [ "$1" = --base ] && [ $# -ge 2 ] || usage
    base=$2
    shift 2
  done
  file=$(config_file)
  globs=$(jq -c '.protected // []' "$file")
  jq -e 'type == "array" and all(type == "string")' <<<"$globs" >/dev/null ||
    die "protected in .claude/senior-mode.json must be an array of globs"
  [ "$globs" != "[]" ] || return 1
  [ -n "$base" ] || base=$(default_branch) || die "no default branch found; pass --base <ref>"
  git rev-parse -q --verify "$base^{commit}" >/dev/null || die "unknown ref: $base"
  # --no-renames: a file moved out of a protected zone is listed under its old path too.
  files=$(git -c core.quotePath=false diff --name-only --no-renames "$base...HEAD") ||
    die "cannot compare with $base"
  matches=$(protected_match "$globs" <<<"$files")
  [ -n "$matches" ] || return 1
  printf '%s\n' "$matches"
}

# The file names on stdin that match a glob of the JSON list $1, as `protected` reads them.
# shellcheck disable=SC2016 # a jq program, not shell
protected_match() {
  jq -Rrn --argjson g "$1" '
    def re:
      (if startswith("/") then .[1:] elif contains("/") then . else "**/" + . end) as $g
      | "^" + ([$g | match("\\*\\*/|\\*\\*|\\*|\\?|[^*?]+"; "g").string
          | if . == "**/" then "(.*/)?" elif . == "**" then ".*" elif . == "*" then "[^/]*" elif . == "?" then "[^/]"
            else gsub("(?<c>[.+^$(){}|\\[\\]\\\\])"; "\\" + .c) end] | join("")) + "$";
    ($g | map(re)) as $res
    | inputs | select(. as $f | any($res[]; . as $r | $f | test($r)))'
}

# `senior-mode red-tests record <issue>` (#191): the files of the commits the test-author session made on the
# ticket branch, since the default branch, one path per line from the repository root, in
# <git common dir>/senior-mode/runs/<issue>/red-tests. hooks/self-protect.sh keeps them read-only for a
# session with SENIOR_MODE_ROLE=ticket. Written once: later commits are the implementer's, so run it between
# the two sessions. A deleted file is not a red test.
red_tests() {
  [ $# -eq 2 ] && [[ $1 == record || $1 == verify ]] && [[ $2 =~ ^[0-9]+$ ]] || usage
  [ "$1" = record ] || {
    red_tests_verify "$2"
    return
  }
  local common base list files
  common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || die "not inside a git repository"
  base=$(default_branch) || die "no default branch to compare with"
  list=$common/senior-mode/runs/$2/red-tests
  [ ! -e "$list" ] || die "the red tests of #$2 are already recorded ($list): only the test-author's commits belong in it"
  files=$(git diff -z --no-renames --name-only --diff-filter=AM "$base...HEAD" | tr '\0' '\n')
  [ -n "$files" ] || die "no file committed on this branch since $base: the test-author session has not committed its tests"
  mkdir -p "${list%/*}"
  printf '%s\n' "$files" >"$list.tmp" && mv "$list.tmp" "$list"
  echo "red-tests: $(wc -l <"$list" | tr -d ' ') file(s) recorded for #$2 in $list"
}

# `senior-mode red-tests verify <issue>` (#306): the proof, for a feature or bug ticket the test-author did not
# start, that its tests count. The test files the branch adds or changes since the default branch are carried to a
# worktree at the merge base and the project's test command (commands.test, else the check named test) must fail there;
# on the head it must pass. The files are then listed in <git common dir>/senior-mode/runs/<issue>/red-verified, which
# `run` and `serve` read next to red-tests (red_blocker). Unlike red-tests, that list does not make the files read-only.
red_tests_verify() {
  local n=$1 common base root file cmd preset files="" f mb wt
  common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || die "not inside a git repository"
  root=$(git rev-parse --show-toplevel) || die "not inside a git repository"
  base=$(default_branch) || die "no default branch to compare with"
  file=$(config_file)
  cmd=$(jq -r '.commands.test // ([.checks[]? | select(.name == "test" or .name == "tests")][0].run) // empty' "$file")
  [ -n "$cmd" ] || die "no test command: set commands.test in .claude/senior-mode.json"
  preset=$(project_preset "$root")
  while IFS= read -r -d '' f; do
    ! test_file "$preset" "$f" || files+="$f"$'\n'
  done < <(git diff -z --no-renames --name-only --diff-filter=AM "$base...HEAD")
  [ -n "$files" ] || die "no test file added or changed on this branch since $base: a feature or a bug needs tests that fail without the change"
  mb=$(git merge-base "$base" HEAD) || die "no common ancestor with $base"
  wt=$(mktemp -d)/base
  git worktree add -q --detach "$wt" "$mb" || die "could not open a worktree at $mb"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    mkdir -p "$wt/$(dirname "$f")"
    git show "HEAD:$f" >"$wt/$f"
  done <<<"$files"
  [ ! -d "$root/node_modules" ] || ln -s "$root/node_modules" "$wt/node_modules"
  if (cd "$wt" && bash -c "$cmd") >/dev/null 2>&1; then
    git worktree remove --force "$wt" 2>/dev/null || true
    die "the tests pass on $base without the change: they must fail there (the test command is: $cmd)"
  fi
  git worktree remove --force "$wt" 2>/dev/null || true
  (cd "$root" && bash -c "$cmd") >/dev/null 2>&1 || die "the tests do not pass on the head (the test command is: $cmd)"
  mkdir -p "$common/senior-mode/runs/$n"
  printf '%s' "$files" >"$common/senior-mode/runs/$n/red-verified"
  echo "red-tests: $(grep -c . <<<"$files") test file(s) fail on $base and pass on the head, recorded for #$n"
}

# What stops the pull request $2 of $1 (owner/name) from being ready on account of the red tests of the tickets it closes
# (#306), or nothing: under run and serve, a feature or bug ticket (label type:feature or type:bug; docs, chore and the
# rest are exempt) needs a record, red-tests (test-author) or red-verified (red_tests_verify), in the common git
# directory of the checkout $4; and every file the record lists must be in the pull request. $3 is the pull request
# body. Starts with "not ready: " when the pull request is at fault.
red_blocker() {
  local slug=$1 pr=$2 body=$3 root=$4 n labels kind common rec missing="" f changed
  common=$(git -C "$root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || {
    echo "the red tests could not be read: no git directory"
    return 0
  }
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    labels=$(gh_retry issue view "$n" --repo "$slug" --json labels --jq '[.labels[]?.name] | join(" ")') || {
      echo "the type of #$n could not be read"
      return 0
    }
    case " $labels " in
      *" type:feature "*) kind=feature ;;
      *" type:bug "*) kind=bug ;;
      *) continue ;;
    esac
    rec=$common/senior-mode/runs/$n/red-tests
    [ -f "$rec" ] || rec=$common/senior-mode/runs/$n/red-verified
    if [ ! -f "$rec" ]; then
      missing+=${missing:+, }"#$n ($kind)"
      continue
    fi
    changed=$(gh_retry api "repos/$slug/pulls/$pr/files" --paginate --jq '.[].filename') || {
      echo "its changed files could not be read"
      return 0
    }
    while IFS= read -r f; do
      [ -z "$f" ] || grep -qxF -- "$f" <<<"$changed" || {
        echo "not ready: the red tests of #$n include $f, which the pull request does not carry"
        return 0
      }
    done <"$rec"
  done < <(pr_closed_tickets "$body")
  [ -z "$missing" ] ||
    echo "not ready: no red-tests record for $missing: the added tests must fail on the base and pass on the head (senior-mode red-tests verify <ticket>)"
}
