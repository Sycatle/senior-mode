# shellcheck shell=bash
# Validation of .claude/senior-mode.json against plugins/senior-mode/schema/senior-mode.schema.json (#317).

# What a generated .claude/senior-mode.json names in `$schema`, so that an editor completes and checks it.
CONFIG_SCHEMA_URL=https://raw.githubusercontent.com/Sycatle/senior-mode/main/plugins/senior-mode/schema/senior-mode.schema.json

# The jq program that walks a document along a schema. It understands the subset of JSON Schema that the schema
# of the plugin uses (type, enum, minimum, maximum, minLength, pattern, properties, additionalProperties, items)
# and two annotations: `deprecated` with `x-replacedBy` on a property, and `x-deprecatedValues` ({value: use})
# on a string. It emits {level, path, message}: an unknown key names the closest known one, a value outside
# its domain says what is allowed.
# shellcheck disable=SC2016 # a jq program, not shell
CONFIG_WALK='
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
walk_schema($schema[0]; "")
'

# The schema that ships with the plugin.
config_schema_file() {
  printf '%s\n' "$(dirname "$SELF")/../schema/senior-mode.schema.json"
}

# The findings of a JSON document against a schema (the plugin's by default), one {level, path, message} per line.
config_findings() { # document [schema]
  jq -c --slurpfile schema "${2:-$(config_schema_file)}" "$CONFIG_WALK" "$1" ||
    die "cannot read $1 against the schema"
}

# `senior-mode config validate [--json]`: the findings of the configuration of this repository. Errors (an unknown
# key with the closest known one, a value out of its domain) exit 1; a deprecated key or value is a warning.
config_validate() {
  local json=false file out
  [ $# -eq 0 ] || { [ $# -eq 1 ] && [ "$1" = --json ]; } || usage
  [ "${1:-}" != --json ] || json=true
  file=$(config_file)
  out=$(config_findings "$file")
  if $json; then
    jq -sc '{valid: (map(select(.level == "error")) | length == 0), findings: .}' <<<"$out"
  else
    jq -r '"\(.level): \(if .path == "" then "(file)" else .path end): \(.message)"' <<<"$out"
  fi
  ! jq -e 'select(.level == "error")' <<<"$out" >/dev/null
}
