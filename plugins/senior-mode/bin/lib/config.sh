# shellcheck shell=bash
# Validation of .claude/senior-mode.json against plugins/senior-mode/schema/senior-mode.schema.json (#317).

# What a generated .claude/senior-mode.json names in `$schema`, so that an editor completes and checks it.
CONFIG_SCHEMA_URL=https://raw.githubusercontent.com/Sycatle/senior-mode/main/plugins/senior-mode/schema/senior-mode.schema.json

# The jq program that walks a document along a schema. It understands the subset of JSON Schema that the schema
# of the plugin uses (type, enum, minimum, maximum, minLength, pattern, required, properties,
# additionalProperties, items) and two annotations: `deprecated` with `x-replacedBy` on a property, and
# `x-deprecatedValues` ({value: use}) on a string. It emits {level, path, message}: an unknown key names the
# closest known one, a value outside its domain says what is allowed. CONFIG_DEFS holds the definitions
# (`closest` serves other callers too).
# shellcheck disable=SC2016 # a jq program, not shell
CONFIG_DEFS='
def lev($s; $t):
  ($s | explode) as $a | ($t | explode) as $b
  | reduce range(0; $a | length) as $i ([range(0; ($b | length) + 1)];
      . as $prev
      | reduce range(0; $b | length) as $j ([$i + 1];
          . + [[$prev[$j + 1] + 1, .[$j] + 1, $prev[$j] + (if $a[$i] == $b[$j] then 0 else 1 end)] | min]))
  | .[-1];
def closest($key; $cands):
  ($key | ascii_downcase) as $k
  | ([$cands[] | {c: ., d: lev($k; ascii_downcase)}] | sort_by(.d) | first) as $best
  | if $best != null and $best.d <= ([1, (($key | length) / 3 | floor)] | max) then $best.c else null end;
def at($path; $k): if $path == "" then $k else "\($path).\($k)" end;
def tname: if type == "number" and . == floor then "integer" else type end;
def typeok($t):
  if $t == "integer" then type == "number" and . == floor
  elif $t == "number" then type == "number"
  else type == $t end;
def show: tojson | if length > 60 then .[0:57] + "..." else . end;
def walk_schema($s; $path):
  . as $v
  | if ($s.type // null) != null and (([$s.type] | flatten | any(. as $t | $v | typeok($t))) | not) then
      {level: "error", path: $path, message: "expected \([$s.type] | flatten | join(" or ")), got \($v | tname) (\($v | show))"}
    else
      (if ($s.enum // null) != null and (($s.enum | index([$v])) == null) then
        (if ($v | type) == "string" then closest($v; [$s.enum[] | strings]) else null end) as $c
        | {level: "error", path: $path, message: "\($v | show) is not one of \($s.enum | map(tojson) | join(", "))\(if $c then ", did you mean \($c | tojson)" else "" end)"}
      elif ($s["x-deprecatedValues"] // null) != null and ($v | type) == "string" and ($s["x-deprecatedValues"][$v] // null) != null then
        {level: "warning", path: $path, message: "\($v | tojson) is deprecated, use \($s["x-deprecatedValues"][$v] | tojson)"}
      else empty end),
      (if ($v | type) == "number" and ($s.minimum // null) != null and $v < $s.minimum then
        {level: "error", path: $path, message: "\($v) is below the minimum \($s.minimum)"} else empty end),
      (if ($v | type) == "number" and ($s.maximum // null) != null and $v > $s.maximum then
        {level: "error", path: $path, message: "\($v) is above the maximum \($s.maximum)"} else empty end),
      (if ($v | type) == "string" and ($s.minLength // null) != null and ($v | length) < $s.minLength then
        {level: "error", path: $path, message: "must not be empty"} else empty end),
      (if ($v | type) == "string" and ($s.pattern // null) != null and ($v | test($s.pattern) | not) then
        {level: "error", path: $path, message: "\($v | show) does not match \($s.pattern)"} else empty end),
      (if ($v | type) == "object" then
        ($s.required // [] | .[] | select(. as $r | $v | has($r) | not)
          | {level: "error", path: at($path; .), message: "missing required key"}),
        ($s.properties // {}) as $props
        | ($v | to_entries[]) as $e
        | if $props[$e.key] != null then
            (if $props[$e.key].deprecated == true then
              {level: "warning", path: at($path; $e.key), message: "deprecated\(if $props[$e.key]["x-replacedBy"] then ", use \($props[$e.key]["x-replacedBy"])" else "" end)"}
            else empty end),
            ($e.value | walk_schema($props[$e.key]; at($path; $e.key)))
          elif $s.additionalProperties == false then
            closest($e.key; $props | keys) as $c
            | {level: "error", path: at($path; $e.key), message: "unknown key\(if $c then ", did you mean \($c)" else "" end)"}
          elif ($s.additionalProperties | type) == "object" then
            $e.value | walk_schema($s.additionalProperties; at($path; $e.key))
          else empty end
      elif ($v | type) == "array" and ($s.items // null) != null then
        range(0; $v | length) as $i | $v[$i] | walk_schema($s.items; "\($path)[\($i)]")
      else empty end)
    end;
'
CONFIG_WALK=$CONFIG_DEFS'walk_schema($schema[0]; "")'

# The schema that ships with the plugin.
config_schema_file() {
  printf '%s\n' "$(dirname "$SELF")/../schema/senior-mode.schema.json"
}

# The findings of a JSON document against a schema (the plugin's by default), one {level, path, message} per line.
config_findings() { # document [schema]
  jq -c --slurpfile schema "${2:-$(config_schema_file)}" "$CONFIG_WALK" "$1" ||
    die "cannot read $1 against the schema"
}

# --- Layers, process profiles and overrides (#307) ---------------------------------------------------------------
#
# The configuration merges in layers, lowest first: the plugin defaults, the process profile, the organization
# (a file the v1.4 reader will fill: <git common dir>/senior-mode/organization.json), the repository
# (.claude/senior-mode.json) and a local untracked file (.claude/senior-mode.local.json of the main worktree).
# A higher layer replaces a lower one key by key; the lists of the safety base (`protected`, `secrets`,
# `envGuard.forbidden`) are the union of the layers, so a layer can add to them and none can remove an entry.
# What the daemon and its sessions read comes from the base branch, never from a pull request's head
# (config_from_base): the repository layer, the project's profiles, the override files and the ADRs of a lift.
# An invalid merged config does not replace the last valid one (config_effective).

CONFIG_OVERRIDES=.claude/senior-mode/overrides
# The locked base (ADR 0027): the profile's `gates`. Lifting one takes an accepted ADR of the repository listed in
# `process.lifts`; of these only the independent review has a lift that the code honours today.
CONFIG_GATES='["secretScan","protectedZones","bashGuard","noForcePush","checkGreen","review","trustGate"]'
CONFIG_LIFTABLE='["review"]'
# shellcheck disable=SC2016 # a jq program, not shell
CONFIG_MERGE='
def uniq: reduce .[] as $x ([]; if index([$x]) then . else . + [$x] end);
def merge2($b):
  . as $a
  | ($a * $b)
  | reduce [["protected"], ["secrets"], ["envGuard", "forbidden"]][] as $p (.;
      (try ($a | getpath($p)) catch null) as $x | (try ($b | getpath($p)) catch null) as $y
      | if ($x | type) == "array" and ($y | type) == "array" then setpath($p; ($x + $y) | uniq) else . end);
'

# Whether this process reads what the daemon reads: the base branch. serve sets it, and so does every session
# that a run or serve launches (SENIOR_MODE_RUN).
config_from_base() {
  [ "${SENIOR_MODE_CONFIG_SOURCE:-}" = base ] || [ -n "${SENIOR_MODE_RUN:-}" ]
}

plugin_root() {
  printf '%s\n' "$(dirname "$SELF")/.."
}

# The file $1 (a path from the repository root): its blob on the base branch when the daemon reads, else the
# working tree's regular file. Fails when it is absent.
repo_read() {
  local rel=$1 root base
  root=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
  if config_from_base && base=$(default_branch 2>/dev/null); then
    git show "$base:$rel" 2>/dev/null
  else
    [ -f "$root/$rel" ] && [ ! -L "$root/$rel" ] || return 1
    cat "$root/$rel"
  fi
}

# The regular files under the directory $1, as paths from the repository root, one per line, from the same source.
repo_list() {
  local dir=$1 root base
  root=$(git rev-parse --show-toplevel 2>/dev/null) || return 0
  if config_from_base && base=$(default_branch 2>/dev/null); then
    git ls-tree -r "$base" -- "$dir/" 2>/dev/null | awk -F'\t' '$1 ~ /^100/ { print $2 }'
  else
    (cd "$root" && find "$dir" -type f ! -type l 2>/dev/null | sort) || true
  fi
}

# The text of the repository layer.
config_repo_text() {
  local text="" file
  if config_from_base; then text=$(repo_read .claude/senior-mode.json) || text=""; fi
  if [ -z "$text" ]; then
    file=$(config_file) || return 1
    text=$(<"$file")
  fi
  printf '%s\n' "$text"
}

# The profile $1 with its chain of `extends`, as {name, origin, chain, description, config, gates}. A project
# profile (.claude/senior-mode/profiles/<name>.json) shadows a shipped one of the same name, and may extend it.
# On failure prints the reason and returns 1. $2 true also validates each file against profile.schema.json.
profile_load() { # name validate [plugin_only] [depth]
  local name=$1 validate=$2 plugin_only=${3:-false} depth=${4:-0} text="" origin file parent pj errs
  [[ $name =~ ^[a-z][a-z0-9-]*$ ]] || { echo "the profile name '$name' is not valid (lowercase letters, digits and dashes)"; return 1; }
  [ "$depth" -lt 5 ] || { echo "profile '$name': the chain of extends is too deep (a cycle?)"; return 1; }
  if [ "$plugin_only" != true ] && text=$(repo_read ".claude/senior-mode/profiles/$name.json"); then
    origin=project
  else
    file=$(plugin_root)/profiles/$name.json
    [ -f "$file" ] || {
      echo "unknown process profile '$name': the plugin ships $(cd "$(plugin_root)/profiles" && ls | sed 's/\.json$//' | paste -sd, - | sed 's/,/, /g'); a project profile is .claude/senior-mode/profiles/$name.json"
      return 1
    }
    text=$(<"$file")
    origin=plugin
  fi
  jq -e 'type == "object"' <<<"$text" >/dev/null 2>&1 || { echo "profile '$name' is not a JSON object"; return 1; }
  if [ "$validate" = true ]; then
    errs=$(profile_findings "$text") || { echo "profile '$name' cannot be read"; return 1; }
    errs=$(jq -r 'select(.level == "error") | "\(.path): \(.message)"' <<<"$errs" | head -n 1)
    [ -z "$errs" ] || { echo "profile '$name': $errs"; return 1; }
  fi
  parent=$(jq -r '.extends // empty' <<<"$text")
  if [ -n "$parent" ]; then
    pj=$(profile_load "$parent" "$validate" "$([ "$parent" = "$name" ] && echo true || echo false)" $((depth + 1))) || { echo "$pj"; return 1; }
  else
    pj='{"chain":[],"config":{},"gates":{}}'
  fi
  jq -nc --arg n "$name" --arg o "$origin" --argjson t "$text" --argjson p "$pj" '{name: $n, origin: $o,
    chain: ([$n] + $p.chain), description: ($t.description // ""),
    config: ($p.config * ($t.config // {})), gates: ($p.gates * ($t.gates // {}))}'
}

# The findings of a profile file: its own schema, then its `config` block against the schema of the configuration
# (a profile does not choose a profile).
profile_findings() { # text
  config_findings <(printf '%s' "$1") "$(plugin_root)/schema/profile.schema.json"
  jq -c '(.config // {}) | del(.process) | select(. != {})' <<<"$1" |
    config_findings /dev/stdin | jq -c '. + {path: ("config." + .path)}'
  ! jq -e '(.config // {}) | has("process")' <<<"$1" >/dev/null ||
    jq -nc '{level: "error", path: "config.process", message: "a profile cannot set process: it is the repository that chooses the profile and lifts a gate"}'
}

# The state of the ADR at the path $1 of the repository: its front matter `status`, or empty when it is absent.
adr_status() {
  local text
  text=$(repo_read "$1") || { echo missing; return 0; }
  awk 'NR == 1 && $0 != "---" { exit } NR > 1 && $0 == "---" { exit } NR > 1 && /^status:/ { sub(/^status:[ \t]*/, ""); gsub(/["\047\r ]/, ""); print; exit }' <<<"$text"
}

# Everything about the configuration of this repository, as one JSON object: {layers, merged, findings, profile,
# lifted}. `layers` lists the five layers lowest first ({name, source, present, config}); `merged` is their merge
# with `process` set to {profile, lifts, gates}, where `gates` says which locked gates stand (all of them, but a
# lift that the profile asks and an accepted ADR of the repository backs); `findings` are the problems, from
# the invalid JSON of a layer to a lift without its ADR; `lifted` lists the lifts that hold. --validate also
# reads every layer and profile file against its schema.
config_resolve() { # [--validate]
  local validate=false root common n t j findings='[]' out name prof pre layers merged gates lifted='[]' g adr st base lifts
  local -A layer=() present=() text=()
  [ "${1:-}" != --validate ] || validate=true
  root=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repository"
  common=$(git rev-parse --path-format=absolute --git-common-dir)
  text[repository]=$(config_repo_text) || return 1
  text[organization]=$(cat "$common/senior-mode/organization.json" 2>/dev/null) || text[organization]=""
  text[local]=$(cat "$(dirname "$common")/.claude/senior-mode.local.json" 2>/dev/null) || text[local]=""
  for n in repository organization local; do
    t=${text[$n]}
    layer[$n]='{}'
    present[$n]=false
    [ -n "$t" ] || continue
    present[$n]=true
    if j=$(jq -c 'if type == "object" then . else error("not an object") end' <<<"$t" 2>/dev/null); then
      layer[$n]=$j
      if [ "$n" != repository ] && jq -e '.process | type == "object" and has("lifts")' <<<"$j" >/dev/null 2>&1; then
        layer[$n]=$(jq -c 'del(.process.lifts)' <<<"$j")
        findings=$(jq -c --arg l "$n" '. + [{level: "warning", layer: $l, path: "process.lifts", message: "ignored: a lift is read from the repository layer only"}]' <<<"$findings")
      fi
      if [ "$validate" = true ]; then
        out=$(config_findings <(printf '%s' "$j"))
        findings=$(jq -sc --arg l "$n" --argjson f "$findings" '$f + map(. + {layer: $l})' <<<"$out")
      fi
    else
      findings=$(jq -c --arg l "$n" '. + [{level: "error", layer: $l, path: "", message: "not a JSON object"}]' <<<"$findings")
    fi
  done
  pre=$(jq -nc --argjson o "${layer[organization]}" --argjson r "${layer[repository]}" --argjson l "${layer[local]}" '$o * $r * $l')
  name=$(jq -r '(.process.profile // "strict") | if type == "string" then . else "strict" end' <<<"$pre")
  if ! prof=$(profile_load "$name" "$validate"); then
    findings=$(jq -c --arg m "$prof" '. + [{level: "error", layer: "profile", path: "process.profile", message: $m}]' <<<"$findings")
    name=strict
    prof=$(profile_load strict false) || prof='{"name":"strict","origin":"plugin","chain":["strict"],"description":"","config":{},"gates":{}}'
  fi
  base=""
  ! config_from_base || base=" on $(default_branch 2>/dev/null || echo the base branch)"
  layers=$(jq -nc --argjson d "$DEFAULTS" --argjson p "$prof" --argjson o "${layer[organization]}" --argjson r "${layer[repository]}" \
    --argjson l "${layer[local]}" --argjson op "${present[organization]}" --argjson rp "${present[repository]}" \
    --argjson lp "${present[local]}" --arg common "$common" --arg base "$base" '[
    {name: "defaults", source: "the plugin defaults", present: true, config: $d},
    {name: "profile", source: "profile \($p.name) (\($p.origin))", present: true, config: $p.config},
    {name: "organization", source: "\($common)/senior-mode/organization.json", present: $op, config: $o},
    {name: "repository", source: ".claude/senior-mode.json\($base)", present: $rp, config: $r},
    {name: "local", source: ".claude/senior-mode.local.json", present: $lp, config: $l}]')
  merged=$(jq -c "$CONFIG_MERGE"'reduce .[] as $l ({}; merge2($l.config))' <<<"$layers")
  # The locked base: a profile that sets a gate to false is a lift, and a lift needs the repository's own ADR.
  gates=$(jq -nc --argjson g "$CONFIG_GATES" '$g | map({key: ., value: true}) | from_entries')
  lifts=$(jq -c '.process.lifts // []' <<<"${layer[repository]}")
  for g in $(jq -r '.gates | to_entries[] | select(.value == false) | .key' <<<"$prof"); do
    if ! jq -e --arg g "$g" 'index($g)' <<<"$CONFIG_LIFTABLE" >/dev/null; then
      findings=$(jq -c --arg g "$g" --arg p "$name" --arg l "$(jq -r 'join(", ")' <<<"$CONFIG_LIFTABLE")" '. + [{level: "error", layer: "profile", path: "process.profile", message: "profile \($p) lifts the locked gate \($g), which cannot be lifted in this version (only \($l) can)"}]' <<<"$findings")
      continue
    fi
    adr=$(jq -r --arg g "$g" '[.[] | select(type == "object" and .rule == $g) | .adr][0] // empty' <<<"$lifts")
    if [ -z "$adr" ]; then
      findings=$(jq -c --arg g "$g" --arg p "$name" '. + [{level: "error", layer: "repository", path: "process.lifts", message: "profile \($p) lifts the locked gate \($g): lifting needs an accepted ADR of this repository, named as {\"rule\": \"\($g)\", \"adr\": \"docs/adr/NNNN-title.md\"} in process.lifts"}]' <<<"$findings")
    elif ! [[ $adr =~ ^[A-Za-z0-9._/-]+\.md$ ]] || [[ $adr == *..* || $adr == /* ]]; then
      findings=$(jq -c --arg g "$g" --arg a "$adr" '. + [{level: "error", layer: "repository", path: "process.lifts", message: "the ADR path \($a) of the lift of \($g) is not a path inside the repository"}]' <<<"$findings")
    else
      st=$(adr_status "$adr")
      if [ "$st" != accepted ]; then
        findings=$(jq -c --arg g "$g" --arg a "$adr" --arg s "${st:-without a status}" '. + [{level: "error", layer: "repository", path: "process.lifts", message: "the lift of \($g) names \($a), which is \(if $s == "missing" then "not found (the daemon reads the base branch)" else "\($s), not accepted" end)"}]' <<<"$findings")
      else
        gates=$(jq -c --arg g "$g" '.[$g] = false' <<<"$gates")
        lifted=$(jq -c --arg g "$g" --arg a "$adr" --arg p "$name" '. + [{rule: $g, adr: $a, profile: $p}]' <<<"$lifted")
      fi
    fi
  done
  # A lift that no profile asks for does nothing: say so, so that it is not taken for a protection or a risk.
  findings=$(jq -c --argjson lifted "$lifted" --argjson lifts "$lifts" '. + [$lifts[] | select(type == "object" and (.rule | type) == "string")
    | select(.rule as $r | $lifted | any(.rule == $r) | not)
    | {level: "warning", layer: "repository", path: "process.lifts", message: "the lift of \(.rule) lifts nothing: the profile keeps the gate"}]' <<<"$findings")
  merged=$(jq -c --arg n "$name" --argjson g "$gates" '.process = ((.process // {}) + {profile: $n, gates: $g})' <<<"$merged")
  jq -nc --argjson layers "$layers" --argjson merged "$merged" --argjson findings "$findings" --argjson lifted "$lifted" \
    --argjson prof "$prof" '{layers: $layers, merged: $merged, findings: $findings, lifted: $lifted,
    profile: {name: $prof.name, origin: $prof.origin, chain: $prof.chain, description: $prof.description}}'
}

# The merged configuration that the code reads, as JSON. Read by a person it is the layers as they are on disk.
# Read by the daemon (config_from_base) it is validated first: a valid one is kept as the snapshot
# <git common dir>/senior-mode/config.valid.json; an invalid one (a bad key, an unknown profile, a lift without
# its ADR) leaves the snapshot in force, with one line on stderr per distinct fault, and says so again when a valid
# one returns. With no snapshot yet, the keys stand but the process falls back to the plugin's strict profile.
# shellcheck disable=SC2016 # jq programs, not shell
config_effective() {
  local res errors common snap marker merged commit new fp say file root cache key
  local strict='.process = {profile: "strict", gates: ($g | map({key: ., value: true}) | from_entries)}'
  if ! config_from_base; then
    # The common case: no organization or local file, no project profile, nothing under `process`.
    root=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repository"
    common=$(git rev-parse --path-format=absolute --git-common-dir)
    file=$(config_file) || return 1
    if [ ! -e "$common/senior-mode/organization.json" ] && [ ! -e "$(dirname "$common")/.claude/senior-mode.local.json" ] &&
      [ ! -e "$root/.claude/senior-mode/profiles" ] && jq -e 'has("process") | not' "$file" >/dev/null; then
      jq -c --argjson d "$DEFAULTS" --argjson g "$CONFIG_GATES" "(\$d * .) | $strict" "$file"
      return
    fi
    config_resolve | jq -c .merged
    return
  fi
  common=$(git rev-parse --path-format=absolute --git-common-dir)
  snap=$common/senior-mode/config.valid.json
  marker=$common/senior-mode/config.invalid
  commit=$(git rev-parse -q --verify "$(default_branch 2>/dev/null || echo HEAD)^{commit}" 2>/dev/null) || commit=""
  # The result only changes with the base branch or an untracked layer: it is kept under that key, so that the
  # many reads of a daemon cost one file read.
  cache=$common/senior-mode/config.cache.json
  key=$(sha256 "$commit$(cat "$common/senior-mode/organization.json" "$(dirname "$common")/.claude/senior-mode.local.json" 2>/dev/null)")
  if [ -f "$cache" ] && [ "$(jq -r .key "$cache" 2>/dev/null)" = "$key" ]; then
    jq -c .config "$cache"
    return
  fi
  res=$(config_resolve --validate) || return 1
  errors=$(jq -c '[.findings[] | select(.level == "error")]' <<<"$res")
  if [ "$errors" = '[]' ]; then
    merged=$(jq -c .merged <<<"$res")
    new=$(jq -nc --arg c "$commit" --argjson m "$merged" '{commit: $c, config: $m}')
    if [ "$new" != "$(cat "$snap" 2>/dev/null)" ]; then
      mkdir -p "$common/senior-mode"
      printf '%s\n' "$new" >"$snap.tmp.$$" && mv "$snap.tmp.$$" "$snap"
    fi
    if [ -f "$marker" ]; then
      rm -f "$marker"
      echo "senior-mode: config: valid again, the new config is in force" >&2
    fi
    config_cache_put "$cache" "$key" "$merged"
    printf '%s\n' "$merged"
    return
  fi
  if [ -f "$snap" ]; then
    merged=$(jq -c .config "$snap")
    say="keeping the last valid config (commit $(jq -r '.commit[0:7]' "$snap"))"
  else
    merged=$(jq -c --argjson g "$CONFIG_GATES" ".merged | $strict" <<<"$res")
    say="no valid config yet: the keys stand, the process is the plugin's strict profile"
  fi
  fp=$(sha256 "$errors")
  if [ "$(cat "$marker" 2>/dev/null)" != "$fp" ]; then
    mkdir -p "$common/senior-mode"
    printf '%s' "$fp" >"$marker"
    echo "senior-mode: config: invalid ($(jq -r '.[0] | "\(.path): \(.message)"' <<<"$errors")); $say" >&2
  fi
  config_cache_put "$cache" "$key" "$merged"
  printf '%s\n' "$merged"
}

config_cache_put() { # file key merged
  mkdir -p "$(dirname "$1")"
  jq -nc --arg k "$2" --argjson c "$3" '{key: $k, config: $c}' >"$1.tmp.$$" && mv "$1.tmp.$$" "$1"
}

# Prints a config value (strings raw, anything else as JSON), falling back to DEFAULTS: the optional keys
# read as empty (`[]` for a list, an empty line for a string) when absent; any other key is an error. The value is
# the merge of the layers (config_effective).
config_get() {
  local key=$1 merged path value
  merged=$(config_effective) || return 1
  path=$(jq -nc --arg k "$key" '$k | split(".")')
  value=$(jq -c --argjson p "$path" 'getpath($p)' <<<"$merged" 2>/dev/null) ||
    die "unknown config key: $key"
  [ "$value" != null ] || die "unknown config key: $key"
  jq -r 'if type == "string" then . else tojson end' <<<"$value"
}

# `senior-mode config explain <key>`: the value of the key, the layer that won, and what each layer says.
# shellcheck disable=SC2016 # a jq program, not shell
config_explain() {
  local key=${1:-} res
  [ -n "$key" ] || usage
  res=$(config_resolve --validate)
  jq -e --arg k "$key" '(try (.merged | getpath($k | split("."))) catch null) != null' <<<"$res" >/dev/null ||
    die "unknown config key: $key"
  jq -r --arg k "$key" '
    def pad($n): (. + (" " * $n))[0:$n];
    ($k | split(".")) as $p
    | ([["protected"], ["secrets"], ["envGuard", "forbidden"]] | index([$p]) != null) as $union
    | . as $r
    | ($r.layers | map(. + {v: (try (.config | getpath($p)) catch null)})) as $L
    | ([$L[] | select(.present and .v != null)] | last) as $win
    | "\($k) = \($r.merged | getpath($p) | tojson)",
      (if $union then "winner: every layer (a safety list is the union of its layers: a layer adds to it, none removes)"
       elif $win == null then "winner: computed (the gates of the profile stay locked unless process.lifts names an accepted ADR)"
       else "winner: \($win.name) (\($win.source))" end),
      "layers, highest first:",
      ($L | reverse | .[] | "  \(.name | pad(13)) "
        + (if (.present | not) then "no file"
           elif .v == null then "not set"
           else (.v | tojson | if length > 70 then .[0:67] + "..." else . end)
             + (if $union then "  adds" elif .name == $win.name then "  wins" else "  shadowed by \($win.name)" end) end)),
      "why: a higher layer replaces a lower one (local, repository, organization, profile, defaults; objects merge key by key)",
      ($r.findings[] | select(.level == "error") | "note: the config is invalid: \(.path): \(.message)")' <<<"$res"
}

# The files under .claude/senior-mode/overrides, as "<path under it>\t<replace|append>\t<plugin file it targets>".
# `skills/review/SKILL.md` replaces the plugin's file of that name; `skills/review/SKILL.append.md` adds to it.
override_files() {
  local f rel base dir mode target
  while IFS= read -r f; do
    rel=${f#"$CONFIG_OVERRIDES/"}
    base=${rel##*/}
    dir=${rel%"$base"}
    mode=replace target=$rel
    if [[ $base == *.append.* ]]; then
      mode=append target=$dir${base/.append./.}
    elif [[ $base == *.append ]]; then
      mode=append target=$dir${base%.append}
    fi
    printf '%s\t%s\t%s\n' "$rel" "$mode" "$target"
  done < <(repo_list "$CONFIG_OVERRIDES")
}

# Whether $1 is a plugin file that may be overridden: skills, agents and templates, never the hooks or the CLI
# (the bash guard and the secret scan are the safety base).
override_target_ok() {
  [[ $1 =~ ^(skills|agents|templates)/[A-Za-z0-9._/-]+$ ]] && [[ $1 != *..* ]]
}

# The text of the plugin file $1 (from the plugin root) with the project's override: the replacement instead of the
# plugin's text, then the addition after it. Fails when there is neither the plugin file nor a replacement.
override_content() {
  local target=$1 plugin base dir add out
  override_target_ok "$target" || return 1
  plugin=$(plugin_root)/$target
  base=${target##*/}
  dir=${target%"$base"}
  if [[ $base == *.* ]]; then add=$dir${base%.*}.append.${base##*.}; else add=$dir$base.append; fi
  if out=$(repo_read "$CONFIG_OVERRIDES/$target"); then
    :
  elif [ -f "$plugin" ]; then
    out=$(<"$plugin")
  else
    return 1
  fi
  if add=$(repo_read "$CONFIG_OVERRIDES/$add"); then out=$out$'\n\n'$add; fi
  printf '%s\n' "$out"
}

# The path of a plugin file from the plugin root, when it is under it.
override_rel() {
  local root
  root=$(cd "$(plugin_root)" && pwd)
  [[ $1 == "$root"/* ]] && printf '%s\n' "${1#"$root"/}"
}

# Whether the project overrides the plugin file $1 (replace or append).
override_has() {
  override_files | awk -F'\t' -v t="$1" '$3 == t { found = 1 } END { exit !found }'
}

# The findings on the override files, as {level, path, message} lines: a file that targets nothing names the
# closest plugin file, and a file outside skills, agents and templates is refused.
# shellcheck disable=SC2016 # a jq program, not shell
override_findings() {
  local rel mode target cands="" best
  while IFS=$'\t' read -r rel mode target; do
    [ -n "$rel" ] || continue
    if ! override_target_ok "$target"; then
      jq -nc --arg p "overrides/$rel" '{level: "error", path: $p, message: "only files under skills/, agents/ and templates/ can be overridden: the hooks and the CLI are the safety base"}'
    elif [ ! -f "$(plugin_root)/$target" ]; then
      [ -n "$cands" ] || cands=$(cd "$(plugin_root)" && find skills agents templates -type f | sort | jq -Rsc 'split("\n") | map(select(length > 0))')
      best=$(jq -nr --arg k "$target" --argjson c "$cands" "$CONFIG_DEFS"'closest($k; $c) // empty')
      jq -nc --arg p "overrides/$rel" --arg t "$target" --arg b "$best" '{level: "error", path: $p,
        message: "no such plugin file: \($t)\(if $b != "" then ", did you mean \($b)" else "" end)"}'
    fi
  done < <(override_files)
}

# What a session is told at its start about the overrides of the skills and agents it will use, read from the same
# source as the config: the text to follow instead of (replace) or after (append) the plugin's own. Never fails.
overrides_context() {
  local rel mode target body lines shown=0 more=0 src
  while IFS=$'\t' read -r rel mode target; do
    case $target in skills/* | agents/*) override_target_ok "$target" || continue ;; *) continue ;; esac
    if [ "$shown" -ge 8 ]; then
      more=$((more + 1))
      continue
    fi
    body=$(repo_read "$CONFIG_OVERRIDES/$rel") || continue
    if [ "$shown" -eq 0 ]; then
      src="the working tree"
      ! config_from_base || src="the base branch"
      echo
      echo "Project overrides of the plugin's skills and agents (read from $src); they bind the skill or agent they name:"
    fi
    shown=$((shown + 1))
    if [ "$mode" = replace ]; then
      echo "- $target: use the text below INSTEAD of the plugin's own for this file."
    else
      echo "- $target: apply the text below IN ADDITION to the plugin's own, after it."
    fi
    lines=$(wc -l <<<"$body")
    head -n 120 <<<"$body"
    [ "$lines" -le 120 ] || echo "  (cut after 120 lines: senior-mode override show $target prints it all)"
  done < <(override_files)
  [ "$more" -eq 0 ] || echo "- and $more more override files: senior-mode override list"
  return 0
}

# `senior-mode override list` | `override show <plugin file>`.
override() {
  case ${1:-} in
    list)
      [ $# -eq 1 ] || usage
      override_files | awk -F'\t' '{ printf "%-44s %-8s %s\n", $3, $2, ".claude/senior-mode/overrides/" $1 }'
      ;;
    show)
      [ $# -eq 2 ] || usage
      override_target_ok "$2" || die "not an overridable plugin file: $2 (skills/, agents/ or templates/ from the plugin root)"
      override_content "$2" || die "no such plugin file or override: $2"
      ;;
    *) usage ;;
  esac
}

# The process of this repository as the status shows it: {profile, lifted: [{rule, adr, profile}], problems}.
process_summary() {
  local res
  res=$(config_resolve 2>/dev/null) || { echo '{"profile":"strict","lifted":[],"problems":[]}'; return 0; }
  jq -c '{profile: .profile.name, lifted: .lifted, problems: [.findings[] | select(.level == "error") | "\(.path): \(.message)"]}' <<<"$res"
}

# `senior-mode config validate [--json]`: the findings on the configuration of this repository, every layer, the
# profile, the lifts and the override files. Errors (an unknown key with the closest known one, a value out of its
# domain, a lift without its ADR) exit 1; a deprecated key or value is a warning.
config_validate() {
  local json=false res all
  [ $# -eq 0 ] || { [ $# -eq 1 ] && [ "$1" = --json ]; } || usage
  [ "${1:-}" != --json ] || json=true
  res=$(config_resolve --validate)
  all=$(jq -sc --argjson f "$(jq -c .findings <<<"$res")" '$f + .' <<<"$(override_findings)")
  if $json; then
    jq -c '{valid: (map(select(.level == "error")) | length == 0), findings: .}' <<<"$all"
  else
    jq -r '.[] | "\(.level): \(if (.layer // "repository") != "repository" then "\(.layer): " else "" end)\(if .path == "" then "(file)" else .path end): \(.message)"' <<<"$all"
  fi
  ! jq -e 'any(.level == "error")' <<<"$all" >/dev/null
}
