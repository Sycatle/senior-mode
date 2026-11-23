#!/usr/bin/env bash
# PreToolUse on Read, Grep, Glob and Bash: denies the agent reading secrets (spec 0001 §10): .env files
# (not .env.example, .sample, .template), private keys, .npmrc, .netrc, cloud, Terraform and kube credential
# files, the `secrets` globs of .claude/senior-mode.json, and Bash commands that dump them or the environment.
# Also business data (#433): local databases, dumps and backups, or the `data` globs, whose content is denied
# (Read, Grep printing lines, Bash readers, sqlite3, duckdb) while a listing stays allowed.
# Prints a deny decision, or nothing to allow. Active in every repository, run or not.
# A guardrail for honest mistakes, not a sandbox: `bash -c "..."`, scripts and `cat *` are not parsed.
set -o pipefail
input=$(cat)
# One jq call: this runs on every Read and Bash. The unit separator, not whitespace, keeps empty fields.
IFS=$'\x1f' read -r tool cwd file path glob pattern < <(jq -r '[.tool_name, .cwd, .tool_input.file_path,
  .tool_input.path, .tool_input.glob, (if .tool_name == "Glob" then .tool_input.pattern else null end)]
  | map(. // "" | tostring) | join("\u001f")' <<<"$input" 2>/dev/null)

deny() {
  jq -nc --arg r "senior-mode: $1" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
  exit 0
}
deny_file() {
  deny "reading $1 is denied: it is a secret and must not enter the conversation. Ask the human for the value you need, or read .env.example for the names of the variables."
}
deny_env() {
  deny "$1 is denied: it prints secrets into the conversation. Ask the human for the one value you need, or read .env.example for the names of the variables."
}

# Built-in names, by file name, then by path; /proc/<pid>/environ is the environment of a process.
# `secrets.*` leaves source code alone (`secrets.ts` is code that reads them, not a store).
is_secret() {
  case ${1##*/} in
    .env*.example | .env*.sample | .env*.template | *.pub | *.tfvars.example | secrets.*.example | secrets.example.* | \
      secrets.example | secrets.sample | secrets.template | secrets.*.sample | secrets.*.template | \
      secrets.ts | secrets.tsx | secrets.js | secrets.jsx | secrets.mjs | secrets.cjs | secrets.py | secrets.rb | \
      secrets.go | secrets.rs | secrets.java | secrets.kt | secrets.php | secrets.cs | secrets.swift | secrets.sh | \
      secrets.md) return 1 ;;
    .env | .env.* | *.pem | *.key | id_rsa* | id_ed25519* | id_ecdsa* | id_dsa* | *.p12 | *.pfx | .npmrc | .netrc | \
      credentials*.json | service-account*.json | *.tfvars | *.tfstate | *.tfstate.backup | kubeconfig* | secrets.* | \
      .git-credentials | .pgpass) return 0 ;;
  esac
  [[ $1 == /proc/*/environ || $1 == *.aws/credentials || $1 == *.kube/config || $1 == *.docker/config.json ||
    $1 =~ (^|/)\.ssh/id_[^/]*$ ]]
}

# Business and production data (#433): a local database, a dump, a backup. Read only its metadata.
# Without a `data` key these names apply; `*.sql` is left out on purpose (migrations).
data_builtin=('*.sqlite' '*.sqlite3' '*.db' '*.dump' '*.bak' '*.mdb' '*.accdb')

# The `secrets` and `data` globs of the nearest .claude/senior-mode.json, read once and only when needed.
root=$cwd
extras=()
datas=()
extras_loaded=false
load_extras() {
  $extras_loaded && return 0
  extras_loaded=true
  datas=("${data_builtin[@]}")
  while [ ! -f "$root/.claude/senior-mode.json" ]; do
    [ -n "$root" ] && [ "$root" != / ] || return 0
    root=${root%/*}
  done
  mapfile -t extras < <(jq -r '(.secrets // []) | if type == "array" then .[] | strings else empty end' \
    "$root/.claude/senior-mode.json" 2>/dev/null)
  if jq -e 'has("data") and (.data | type == "array")' "$root/.claude/senior-mode.json" >/dev/null 2>&1; then
    mapfile -t datas < <(jq -r '.data[] | strings' "$root/.claude/senior-mode.json")
  fi
}
# A glob without a slash matches the file name; one with a slash matches the path from the repository
# root, `**/` standing for any directories. $1 the path, $2 `data` for the data globs.
is_extra() {
  load_extras
  local p=$1 rel pat list=("${extras[@]+"${extras[@]}"}")
  [ "${2:-}" != data ] || list=("${datas[@]+"${datas[@]}"}")
  [[ $p == /* || $p == "~"* ]] || p=$cwd/$p
  rel=${p#"$root"/}
  for pat in ${list[@]+"${list[@]}"}; do
    pat=${pat#./}
    if [[ $pat == /* ]]; then
      # shellcheck disable=SC2053 # a glob on purpose
      [[ $p == $pat ]] && return 0
    elif [[ $pat == */* ]]; then
      pat=${pat//\*\*\//\*}
      # shellcheck disable=SC2053
      [[ $rel == $pat ]] && return 0
    else
      # shellcheck disable=SC2053
      [[ ${p##*/} == $pat ]] && return 0
    fi
  done
  return 1
}
deny_data() {
  deny "reading $1 is denied: it holds business or production data, which must not enter the conversation. Work from the schema, the types or a synthetic fixture written by hand; its existence, size and date stay readable."
}
# $2 false to check the secrets only (a listing reads names, not content).
check_path() {
  [ -n "$1" ] || return 0
  if is_secret "$1" || is_extra "$1"; then deny_file "$1"; fi
  if [ "${2:-true}" = true ] && is_extra "$1" data; then deny_data "$1"; fi
}
# A glob is checked as written and with its stars removed: `.env*` reads `.env`, `**/*.pem` reads `.pem`.
check_glob() {
  check_path "$1" "${2:-true}"
  check_path "${1//\*/}" "${2:-true}"
}

case $tool in
  Read) check_path "$file" ;;
  Grep)
    # Listing the matching files or counting them reads no content; printing the lines does.
    content=false
    [ "$(jq -r '.tool_input.output_mode // empty' <<<"$input" 2>/dev/null)" != content ] || content=true
    check_path "$path" "$content"
    check_glob "$glob" "$content"
    ;;
  Glob)
    check_path "$path" false
    check_glob "$pattern" false
    ;;
  Bash) ;;
  *) exit 0 ;;
esac
[ "$tool" = Bash ] || exit 0

# Quoted text is data (commit messages, echo): replace it before parsing. A quoted single word (a path)
# is unquoted instead. A backslash-newline continues the line.
command=$(jq -r '.tool_input.command // "" | gsub("\\\\\n"; " ")
  | gsub("\"(?<w>[^\"\\\\\\s;|&()`]*)\"|'"'"'(?<v>[^'"'"'\\s;|&()`]*)'"'"'"; .w // .v)
  | gsub("\"(\\\\.|[^\"\\\\])*\""; "Q") | gsub("'"'"'[^'"'"']*'"'"'"; "Q")' <<<"$input")

# Checks the file arguments of a command that prints files; $1 is true when the first argument that is
# not an option is a search pattern, not a file.
check_args() {
  local want_pattern=$1 a prev=""
  shift
  [[ " $* " =~ \ (-e|-f|--regexp|--file)[\ =] ]] && want_pattern=false
  for a in "$@"; do
    while [[ $a == \<* ]]; do a=${a#<}; done
    if [[ $a == -* || $a == *\>* || $a == "" ]]; then
      prev=$a
      continue
    fi
    if [[ $prev == -e || $prev == --regexp || $prev =~ ^[0-9]*\>\>?$ ]]; then
      prev=$a
      continue
    fi
    if $want_pattern; then
      want_pattern=false
      prev=$a
      continue
    fi
    prev=$a
    check_glob "$a"
  done
}
# True when no argument is a non-option word.
only_options() {
  local a
  for a in "$@"; do [[ $a == -* ]] || return 1; done
}

while IFS= read -r segment; do
  read -ra w <<<"$segment"
  i=0
  while [[ ${w[i]:-} == *=* || ${w[i]:-} == command || ${w[i]:-} == exec || ${w[i]:-} == sudo || ${w[i]:-} == time ]]; do
    i=$((i + 1))
  done
  [ -n "${w[i]:-}" ] || continue
  args=("${w[@]:i+1}")
  case ${w[i]##*/} in
    cat | less | more | head | tail | tac | nl | bat | batcat | strings | xxd | od | hexdump | base64 | awk | sed | source | .)
      check_args false ${args[@]+"${args[@]}"}
      ;;
    grep | egrep | fgrep | rg | ag) check_args true ${args[@]+"${args[@]}"} ;;
    sqlite3 | duckdb) check_args false ${args[@]+"${args[@]}"} ;;
    printenv) deny_env "printenv" ;;
    env) only_options ${args[@]+"${args[@]}"} && deny_env "env, which lists the environment," ;;
    set) [ ${#args[@]} -eq 0 ] && deny_env "set, which lists shell and environment variables," ;;
    export)
      only_options ${args[@]+"${args[@]}"} && [[ " ${args[*]} " != *" -n "* ]] &&
        deny_env "export, which lists the environment,"
      ;;
    declare | typeset)
      only_options ${args[@]+"${args[@]}"} && [[ " ${args[*]} " =~ \ -[a-zA-Z]*[xp] ]] &&
        deny_env "declare, which lists the environment,"
      ;;
  esac
done < <(tr ';|&()`' '\n' <<<"$command")
exit 0
