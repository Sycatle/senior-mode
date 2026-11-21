#!/usr/bin/env bash
# PreToolUse on Read, Grep, Glob and Bash: denies the agent reading secrets (spec 0001 §10): .env files
# (not .env.example, .sample, .template), private keys, .npmrc, .netrc, cloud credential files, the
# `secrets` globs of .claude/senior-mode.json, and Bash commands that dump them or the environment.
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

# Built-in names, by file name; /proc/<pid>/environ is the environment of a process.
is_secret() {
  case ${1##*/} in
    .env*.example | .env*.sample | .env*.template | *.pub) return 1 ;;
    .env | .env.* | *.pem | *.key | id_rsa* | id_ed25519* | *.p12 | *.pfx | .npmrc | .netrc | \
      credentials*.json | service-account*.json) return 0 ;;
  esac
  [[ $1 == /proc/*/environ ]]
}

# The `secrets` globs of the nearest .claude/senior-mode.json, read once and only when needed.
root=$cwd
extras=()
extras_loaded=false
load_extras() {
  $extras_loaded && return 0
  extras_loaded=true
  while [ ! -f "$root/.claude/senior-mode.json" ]; do
    [ -n "$root" ] && [ "$root" != / ] || return 0
    root=${root%/*}
  done
  mapfile -t extras < <(jq -r '(.secrets // []) | if type == "array" then .[] | strings else empty end' \
    "$root/.claude/senior-mode.json" 2>/dev/null)
}
# A glob without a slash matches the file name; one with a slash matches the path from the repository
# root, `**/` standing for any directories.
is_extra() {
  load_extras
  local p=$1 rel pat
  [[ $p == /* || $p == "~"* ]] || p=$cwd/$p
  rel=${p#"$root"/}
  for pat in ${extras[@]+"${extras[@]}"}; do
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
check_path() {
  [ -n "$1" ] || return 0
  if is_secret "$1" || is_extra "$1"; then deny_file "$1"; fi
}
# A glob is checked as written and with its stars removed: `.env*` reads `.env`, `**/*.pem` reads `.pem`.
check_glob() {
  check_path "$1"
  check_path "${1//\*/}"
}

case $tool in
  Read) check_path "$file" ;;
  Grep)
    check_path "$path"
    check_glob "$glob"
    ;;
  Glob)
    check_path "$path"
    check_glob "$pattern"
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
