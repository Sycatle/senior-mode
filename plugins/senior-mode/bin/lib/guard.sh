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
  [ $# -eq 2 ] && [ "$1" = record ] && [[ $2 =~ ^[0-9]+$ ]] || usage
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
