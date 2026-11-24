# shellcheck shell=bash
# Packages of a monorepo (spec 327 §10, #323): `setup repo` finds the npm, pnpm and yarn workspaces, the Cargo
# workspace and the Go modules of a repository and records them under `packages` in .claude/senior-mode.json.
# `check` then runs only the packages a diff affects (#418): packages_select.

# Lexically normalizes the relative path $1 ("a/b/../c" is "a/c", the root is "."); nothing when it leaves the root.
packages_norm() {
  local part out=() IFS=/
  for part in $1; do
    case $part in
      "" | .) ;;
      ..) [ ${#out[@]} -gt 0 ] || return 0; unset 'out[${#out[@]}-1]' ;;
      *) out+=("$part") ;;
    esac
  done
  [ ${#out[@]} -gt 0 ] && echo "${out[*]}" || echo .
}

# The directories of the repository $1 that match the glob patterns that follow and hold the file $2, one per line; a
# pattern that starts with ! removes its matches. A directory under node_modules, vendor or a dot directory is no package.
packages_expand() { # root file pattern...
  local root=$1 file=$2 pat dir
  shift 2
  (
    cd "$root" || exit 0
    shopt -s globstar nullglob
    for pat in "$@"; do
      pat=${pat#./}
      pat=${pat%/}
      [ "${pat:0:1}" != "!" ] || continue
      # shellcheck disable=SC2086 # the pattern is a glob
      for dir in $pat/; do
        dir=${dir%/}
        case /$dir/ in */node_modules/* | */vendor/* | */.*/*) continue ;; esac
        [ ! -f "$dir/$file" ] || echo "$dir"
      done
    done | sort -u | while IFS= read -r dir; do
      for pat in "$@"; do
        # shellcheck disable=SC2254 # the pattern is a glob
        case $pat in "!"*) case $dir in ${pat#!./} | ${pat#!}) continue 2 ;; esac ;; esac
      done
      echo "$dir"
    done
  )
}

# The workspace patterns of a node project: `workspaces` of its package.json (a list, or an object with `packages`),
# and `packages` of pnpm-workspace.yaml.
packages_node_patterns() {
  local root=$1
  [ ! -f "$root/package.json" ] || jq -r '(.workspaces | if type == "array" then . else (.packages // []) end)[]?' "$root/package.json" 2>/dev/null || true
  [ ! -f "$root/pnpm-workspace.yaml" ] || awk '
    /^packages:/ { on = 1; next }
    /^[^ \t#-]/ { on = 0 }
    on && /^[ \t]*-/ { s = $0; sub(/^[ \t]*-[ \t]*/, "", s); sub(/[ \t]*#.*/, "", s); gsub(/^["\047]|["\047]$/, "", s); if (s != "") print s }
  ' "$root/pnpm-workspace.yaml"
}

# One JSON line per package of a node workspace: {dir, ids, preset, commands, needs}. A dependency counts when it
# names another package of the workspace.
packages_node() {
  local root=$1 dir pats=() p
  while IFS= read -r p; do pats+=("$p"); done < <(packages_node_patterns "$root")
  [ ${#pats[@]} -gt 0 ] || return 0
  while IFS= read -r dir; do
    node_detect "$root/$dir" "$root" | jq -c --arg dir "$dir" --slurpfile m "$root/$dir/package.json" '
      {dir: $dir, ids: ["node:" + ($m[0].name // $dir)], preset: "node", commands: (.commands | del(.install)),
       needs: [$m[0] | [.dependencies, .devDependencies, .peerDependencies, .optionalDependencies]
         | map(objects | keys[]) | .[] | "node:" + .]}' 2>/dev/null || true
  done < <(packages_expand "$root" package.json "${pats[@]}")
}

# The quoted strings of the array `key` in the TOML table `table` of the file $1.
toml_strings() { # file table key
  awk -v table="$2" -v key="$3" '
    /^\[/ { s = $0; sub(/[ \t]*#.*/, "", s); gsub(/[ \t]/, "", s); on = (s == "[" table "]"); open = 0 }
    on {
      line = $0; sub(/[ \t]*#.*/, "", line)
      if (!open && line ~ "^[ \t]*" key "[ \t]*=") { open = 1; sub(/^[^=]*=/, "", line) } else if (!open) next
      while (match(line, /"[^"]*"/)) { print substr(line, RSTART + 1, RLENGTH - 2); line = substr(line, RSTART + RLENGTH) }
      if (line ~ /\]/ || $0 ~ /\]/) open = 0
    }' "$1"
}

# The path dependencies of a member's Cargo.toml, one `path <p>` or `workspace <name>` line each.
cargo_path_deps() {
  awk '
    /^\[/ {
      s = $0; sub(/[ \t]*#.*/, "", s); gsub(/[ \t]/, "", s)
      on = (s ~ /dependencies/ && s !~ /^\[workspace/); sub_name = ""
      if (match(s, /dependencies\.[^.\]]+\]$/)) { sub_name = substr(s, RSTART + 13, RLENGTH - 14) }
      next
    }
    on {
      line = $0; sub(/[ \t]*#.*/, "", line)
      name = sub_name
      if (name == "") { name = line; sub(/[ \t]*[=.].*/, "", name); gsub(/^[ \t]+/, "", name) }
      if (match(line, /path[ \t]*=[ \t]*"[^"]*"/)) { p = substr(line, RSTART, RLENGTH); sub(/^[^"]*"/, "", p); sub(/"$/, "", p); print "path " p }
      else if (line ~ /workspace[ \t]*=[ \t]*true/ && name != "") print "workspace " name
    }' "$1"
}

# One JSON line per member of a Cargo workspace. Path dependencies come from the manifests (`cargo metadata` is not needed);
# a `workspace = true` dependency takes the path of the root's [workspace.dependencies].
packages_cargo() {
  local root=$1 dir pats=() p kind val wsdeps dep
  grep -qs '^\[workspace\]' "$root/Cargo.toml" || return 0
  while IFS= read -r p; do pats+=("$p"); done < <(toml_strings "$root/Cargo.toml" workspace members)
  while IFS= read -r p; do pats+=("!$p"); done < <(toml_strings "$root/Cargo.toml" workspace exclude)
  [ ${#pats[@]} -gt 0 ] || return 0
  wsdeps=$(awk '
    /^\[/ { s = $0; gsub(/[ \t]/, "", s); on = (s == "[workspace.dependencies]"); next }
    on && match($0, /path[ \t]*=[ \t]*"[^"]*"/) { p = substr($0, RSTART, RLENGTH); sub(/^[^"]*"/, "", p); sub(/"$/, "", p)
      n = $0; sub(/[ \t]*[=.].*/, "", n); print n " " p }' "$root/Cargo.toml")
  while IFS= read -r dir; do
    local needs=()
    while read -r kind val; do
      [ -n "$kind" ] || continue
      if [ "$kind" = workspace ]; then
        val=$(awk -v n="$val" '$1 == n { print $2 }' <<<"$wsdeps")
        [ -n "$val" ] || continue
        dep=$(packages_norm "$val")
      else
        dep=$(packages_norm "$dir/$val")
      fi
      [ -z "$dep" ] || needs+=("cargo:$dep")
    done < <(cargo_path_deps "$root/$dir/Cargo.toml")
    rust_detect | jq -c --arg dir "$dir" --argjson needs "$(printf '%s\n' ${needs[@]+"${needs[@]}"} | jq -R . | jq -sc 'map(select(. != ""))')" '
      {dir: $dir, ids: ["cargo:" + $dir], preset: "rust", commands: (.commands | del(.install)), needs: $needs}'
  done < <(packages_expand "$root" Cargo.toml "${pats[@]}")
}

# The directories of the go.mod files of the repository: the `use` of its go.work, else every go.mod it tracks.
packages_go_dirs() {
  local root=$1
  if [ -f "$root/go.work" ]; then
    awk '
      { sub(/\/\/.*/, "") }
      $1 == "use" && $2 == "(" { blk = 1; next }
      blk && $1 == ")" { blk = 0; next }
      blk && NF { gsub(/"/, "", $1); print $1; next }
      $1 == "use" && NF > 1 { gsub(/"/, "", $2); print $2 }' "$root/go.work" | while IFS= read -r d; do
      d=$(packages_norm "$d")
      [ -z "$d" ] || [ ! -f "$root/$d/go.mod" ] || echo "$d"
    done | sort -u
    return 0
  fi
  git -C "$root" ls-files --cached --others --exclude-standard -- ':(glob)**/go.mod' 'go.mod' 2>/dev/null |
    grep -vE '(^|/)(vendor|node_modules|testdata)/' | sed -E 's#(^|/)go\.mod$##; s#^$#.#' | sort -u
}

# One JSON line per Go module: its path and the replaced directories are its ids; what it requires or replaces is what
# it needs. Every module has its own commands, install included: Go installs once per module.
packages_go() {
  local root=$1 dir dirs=() kind val mod needs
  while IFS= read -r dir; do dirs+=("$dir"); done < <(packages_go_dirs "$root")
  if [ ! -f "$root/go.work" ]; then [ ${#dirs[@]} -ge 2 ] || return 0; else [ ${#dirs[@]} -ge 1 ] || return 0; fi
  for dir in "${dirs[@]}"; do
    mod=""
    needs=()
    while IFS=$'\t' read -r kind val; do
      case $kind in
        module) mod=$val ;;
        require) needs+=("go:$val") ;;
        replace) case $val in ./* | ../* | /*) needs+=("godir:$(packages_norm "$dir/$val")") ;; esac ;;
      esac
    done < <(awk '
      function rep(start,   i) { for (i = start; i <= NF; i++) if ($i == "=>") { print "replace\t" $(i + 1); return } }
      { sub(/\/\/.*/, ""); gsub(/"/, "") }
      blk == "" && $1 == "module" { print "module\t" $2; next }
      $1 == ")" { blk = ""; next }
      blk == "" && ($1 == "require" || $1 == "replace") && $2 == "(" { blk = $1; next }
      blk == "require" && NF { print "require\t" $1; next }
      blk == "replace" && NF { rep(1); next }
      $1 == "require" { print "require\t" $2; next }
      $1 == "replace" { rep(2) }' "$root/$dir/go.mod" 2>/dev/null)
    go_detect "$root/$dir" | jq -c --arg dir "$dir" --arg mod "$mod" --argjson needs "$(printf '%s\n' ${needs[@]+"${needs[@]}"} | jq -R . | jq -sc 'map(select(. != ""))')" '
      {dir: $dir, ids: (["godir:" + $dir] + (if $mod != "" then ["go:" + $mod] else [] end)), preset: "go",
       commands: .commands, needs: $needs}'
  done
}

# The packages of the project at $1 as {dir: {preset, commands, deps}}, deps being the directories of the other
# packages each one depends on; {} when the project is no monorepo.
packages_detect() {
  local root=$1
  { packages_node "$root"; packages_cargo "$root"; packages_go "$root"; } | jq -sc '
    (map(. as $p | .ids[] | {key: ., value: $p.dir}) | from_entries) as $m
    | map(. as $p | {key: .dir, value: {preset, commands, deps: ([.needs[] | $m[.] // empty] | unique - [$p.dir])}})
    | sort_by(.key) | from_entries'
}

# The install commands to run in a worktree at $1, one `<dir><TAB><command>` line each: the root's, then, for Go, the
# one of every module (a node or Cargo workspace installs once, at the root).
install_plan() {
  local root=$1 cmd file=$1/.claude/senior-mode.json
  cmd=$(install_command "$root")
  [ -z "$cmd" ] || printf '.\t%s\n' "$cmd"
  [ ! -f "$file" ] || jq -r '(.packages // {}) | to_entries[]
    | select(.key != "." and .value.preset == "go" and (.value.commands.install // "") != "")
    | "\(.key)\t\(.value.commands.install)"' "$file" 2>/dev/null || true
}

# The dependencies between the packages of the base commit $2, as {dir: [dir]}: its manifests are read again, so that
# the graph of a pull request is the union of its base's and its head's (a dependency it adds cannot hide).
packages_base_graph() { # root commit
  local root=$1 mb=$2 tmp f
  tmp=$(mktemp -d)
  git -C "$tmp" init -q
  while IFS= read -r f; do
    mkdir -p "$tmp/$(dirname "$f")"
    git -C "$root" show "$mb:$f" >"$tmp/$f" 2>/dev/null || true
  done < <(git -C "$root" ls-tree -r --name-only "$mb" 2>/dev/null | grep -E '(^|/)(package\.json|pnpm-workspace\.yaml|Cargo\.toml|go\.mod|go\.work)$' || true)
  packages_detect "$tmp" | jq -c 'map_values(.deps)'
  rm -rf "$tmp"
}

# The packages `check` runs, from the project $1 and its config file $2, as JSON {total, all, why, run}: every package
# when $3 is true (`check --all`), when the changed files cannot be told or are none, or when one lies outside every
# package (a root config, a lockfile, a workflow): `all` is then true and the checks run as they are; else the packages that own a changed file and their dependents,
# transitively, over the union of the recorded, head and base dependencies. A file belongs to the deepest package.
packages_select() { # root config all
  local root=$1 file=$2 all=$3 files mb base graph="{}"
  if [ "$all" = true ]; then
    jq -c '(.packages // {} | keys) as $k | {total: ($k | length), all: true, why: "check --all", run: $k}' "$file"
    return 0
  fi
  if base=$(default_branch) && mb=$(git -C "$root" merge-base "$base" HEAD) && files=$(changed_files "$root" deleted); then
    graph=$(jq -sc 'reduce .[] as $g ({}; reduce ($g | keys[]) as $k (.; .[$k] = ((.[$k] // []) + $g[$k] | unique)))' \
      <(jq -c '(.packages // {}) | map_values(.deps // [])' "$file") \
      <(packages_detect "$root" | jq -c 'map_values(.deps)') <(packages_base_graph "$root" "$mb")) || graph="{}"
  else
    files=""
    mb=""
  fi
  jq -nc --argjson pk "$(jq -c '.packages // {}' "$file")" --argjson g "$graph" --arg mb "$mb" \
    --argjson files "$(jq -R . <<<"$files" | jq -sc 'map(select(. != ""))')" '
    ($pk | keys) as $keys
    | def all($why): {total: ($keys | length), all: true, why: $why, run: $keys};
    ([$files[] | . as $f | [$keys[] | select(. as $k | $k == "." or $f == $k or ($f | startswith($k + "/")))] | sort_by(length) | last] ) as $own
    | if $mb == "" then all("the changed files cannot be told")
      elif ($files | length) == 0 then all("no changed file")
      elif any($own[]; . == null) then all("a changed file lies outside every package: " + $files[[range(0; $own | length) | select($own[.] == null)][0]])
      else
        def step($a): ($a + [$keys[] | select(. as $k | any(($g[$k] // [])[]; . as $d | any($a[]; . == $d)))]) | unique;
        ($own | unique | until(step(.) == .; step(.))) as $run
        | {total: ($keys | length), all: false, why: "", run: $run}
      end'
}

# The packages of a selection $1 as "3 of 12 packages: api, shared, web": the last component of each directory, the
# whole directory when two share it.
packages_say() {
  jq -r '.run as $r | ($r | map(split("/") | last) | group_by(.) | map(select(length > 1) | .[0])) as $dup
    | "\($r | length) of \(.total) packages: \($r | map(if (split("/") | last) as $b | $dup | index($b) then . else split("/") | last end) | join(", "))"' <<<"$1"
}
