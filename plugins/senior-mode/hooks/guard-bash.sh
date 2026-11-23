#!/usr/bin/env bash
# PreToolUse on Bash: denies git commands that skip checks, force-push, push to the default branch or
# discard commits of a shared branch, switch the hooks off (core.hooksPath), and gh pr merge --admin
# (spec 0001 §10), the same through the GIT_CONFIG_KEY_<n> environment, another config file, an include,
# an editor, a git or gh alias; in a run, any merge and any change to rulesets or branch protection
# (spec 130).
# Prints a deny decision, or nothing to allow.
# A guardrail for honest mistakes, not a sandbox: `bash -c "..."`, `eval` and the like are not parsed, and
# a variable that stands for a whole word is not followed (`git push origin $B`, `gh api -X $M ...`), nor is a
# `cd` earlier in the command. git takes an unambiguous abbreviation of a long option: so does this guard.
set -o pipefail
input=$(cat)
# Quoted text is data (commit messages, echo), never options: replace it before parsing. A quoted
# single word (a URL, a ref) is unquoted instead, and so is a quoted variable (`"$EP"`, `--for"$x"ce`)
# or a quoted word with variables in it (`"core.hooks${x}Path"`), which the checks below must still see.
# An empty pair touching a word (`--for""ce`) is removed; alone it is an argument (`core.hooksPath ""`)
# and stays, as `Q`. Outside quotes a backslash is dropped as the shell does (`--for\ce`,
# `core.hooksPath\=x`); an escaped space or quote becomes `Q`, so it neither splits a word nor opens a
# quote, and a value made only of them is still an argument. A backslash-newline continues the line.
command=$(jq -r '.tool_input.command // "" | gsub("\\\\\n"; " ")
  | gsub("\"(?<x>(?:\\$(?:\\{[^}\"\\\\\\s]*\\}|[A-Za-z_][A-Za-z0-9_]*))+)\"|\"(?<w>[^\"\\\\\\s$`]+)\"|\"(?<y>(?:[^\"\\\\\\s$`;|&()<>]|\\$(?:\\{[^}\"\\\\\\s]*\\}|[A-Za-z_][A-Za-z0-9_]*))+)\"|'"'"'(?<v>[^'"'"'\\s]+)'"'"'|(?<=\\S)(?:\"\"|'"'"''"'"')|(?:\"\"|'"'"''"'"')(?=\\S)|(?<g>\"(\\\\.|[^\"\\\\])*\"|'"'"'[^'"'"']*'"'"')|\\\\(?<c>[^\\n \"'"'"'])|\\\\(?<e>[ \"'"'"'])"; .x // .w // .y // .v // .g // .c // (if .e then "Q" else "" end))
  | gsub("\"(\\\\.|[^\"\\\\])*\""; "Q") | gsub("'"'"'[^'"'"']*'"'"'"; "Q")' <<<"$input")
cwd=$(jq -r '.cwd // empty' <<<"$input")
raw=$(jq -r '.tool_input.command // ""' <<<"$input")
# The gh api checks read the endpoint, not the text of a body, header or filter: drop the values of
# the options that take one, keeping what is quoted in the endpoint (`"repos/$R/pulls/$N/merge"`).
# Only plain quoting is parsed this way: with a backslash, `$'..'`, `$".."` or a command substitution
# the stripper and the shell can disagree on where a value ends, so the whole command is read
# instead (a false positive beats a bypass).
raw_ep=$(jq -r '.tool_input.command // "" | gsub("\\\\\n"; " ")
  | gsub("(?<f>\\s(-f|-F|-H|-q|-t|--field|--raw-field|--header|--jq|--template|--input)(\\s+|=)?)(\"(\\\\.|[^\"\\\\])*\"|'"'"'[^'"'"']*'"'"'|[^\\s\"'"'"'])+"; "\(.f)V")' <<<"$input")
# The raw text without its backslashes: the shell reads `me\rge` as `merge`, so do the endpoint checks.
rawb=${raw//\\/}
ep=$raw_ep untrusted=false
case ${raw//\\$'\n'/ } in *\\* | *\$\'* | *\$\"* | *\$\(* | *\`*) ep=$rawb untrusted=true ;; esac
# The command with its quotes and backslashes removed, in lower case: for what the words may have lost.
flat=${raw,,} flat=${flat//[\"\'\\]/}

# git accepts an unambiguous abbreviation of a long option (`--no-verif`, `--forc`, `--ha`): a word that is a
# prefix of a denied option, with at least $3 characters after the `--` (what git needs, tested), is that
# option. gh does not abbreviate (cobra): `gh pr merge --admi` is an unknown flag, so it is left alone.
abbr() { # word option min
  local n=${1%%=*}
  [[ $n == --* && ${#n} -ge $(($3 + 2)) && $2 == "$n"* ]]
}
re_noverify='--no-v(e(r(i(fy?)?)?)?)?([^[:alnum:]-]|$)'
re_force='--for(c(e[-[:alnum:]]*)?)?([^[:alnum:]]|$)'
re_pushf='(^|[[:space:]!=])push[[:space:]]([^;&|]*[[:space:]])?-[a-z]*f[a-z]*([[:space:]]|$)'
re_commitn='(^|[[:space:]!=])commit[[:space:]]([^;&|]*[[:space:]])?-[a-z]*n[a-z]*([[:space:]]|$)'
alias_bad() {
  [[ $flat == *--no-verify* || $flat == *--force* || $flat == *core.hookspath* ||
    $flat =~ $re_noverify || $flat =~ $re_force || $flat =~ $re_pushf || $flat =~ $re_commitn ]]
}
# A git setting handed over as key=value (-c, --config-env): the hooks path, another file pulled in by an
# include, or an alias that runs what is denied here (its value is quoted text, so read in $flat).
check_kv() {
  [[ $1 == *=* ]] || return 0
  local k=${1%%=*}
  split_key "$k" && deny_skip "a config key split by a variable"
  k=${k,,}
  case $k in
    core.hookspath) deny_skip "core.hooksPath" ;;
    include.path | includeif.*.path) deny_skip "$k" ;;
    alias.*) alias_bad && deny_skip "an alias that runs a denied option" ;;
  esac
  return 0
}
# A variable inside a config key (`core.hooks${x}Path`) hides it: true when the key, with the variables left
# open, can be core.hooksPath or include.path and a variable shares a dot-separated part with literal text.
# A part that is only a variable (`core.$k`, `$s.hooksPath`, `"$key"`) is a value the guard does not follow.
# shellcheck disable=SC2016 # a sed program, not shell
var_glob() { sed -E 's/\$(\{[^}]*\}|[A-Za-z_][A-Za-z0-9_]*)/*/g' <<<"$1"; }
split_key() { # word
  local p=${1,,}
  [[ $p == *\$* ]] || return 1
  p=$(var_glob "$p")
  [[ $p =~ (^|\.)[^.]*(\*[^.*]|[^.*]\*)[^.]*(\.|$) ]] || return 1
  # shellcheck disable=SC2053 # $p is a glob: the variables left open
  [[ core.hookspath == $p || include.path == $p ]]
}
# A word split by a variable (`--for${x}ce`, `pu${x}sh`) hides what it says from this guard; a variable
# alone (`$sub`, `"$sub"`) is a value the guard does not follow, as documented.
# An endpoint built from a variable and ending in the merge or protection path (`"$BASE/merge"`): where
# the pull request is, is not read, but what is done to it is.
re_vmerge='\$[^[:space:]]*/merges?([^[:alnum:]_.-]|$)'
re_vprot='\$[^[:space:]]*/protection([^[:alnum:]_.-]|$)'
check_split() { # word [option|command]
  local n=${1%%=*}
  [[ $n == *\$* ]] || return 0
  if [ "$2" = option ]; then [[ $n == --* ]] || return 0
  else [[ $n =~ ^(\$([A-Za-z_][A-Za-z0-9_]*|\{[^}]*\}))+$ ]] && return 0
  fi
  deny "a word split by a variable ($1) hides the option or command from the guard: write it out."
}

deny() {
  jq -nc --arg r "senior-mode: $1" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
  exit 0
}
deny_skip() { deny "skipping checks is denied ($1); fix what the check reports instead."; }
deny_force() { deny "force-push is denied: it rewrites history others may have fetched. Push new commits instead."; }

current() { git -C "$dir" symbolic-ref --short -q HEAD; }
is_default() {
  local head
  head=$(git -C "$dir" symbolic-ref --short -q refs/remotes/origin/HEAD)
  for b in ${head:+${head#origin/}} ${head:-main master}; do [ "$1" = "$b" ] && return 0; done
  return 1
}
is_shared() {
  is_default "$1" || git -C "$dir" rev-parse -q --verify "refs/remotes/origin/$1" >/dev/null ||
    git -C "$dir" rev-parse -q --verify "$1@{upstream}" >/dev/null 2>&1
}

# An assignment that sets core.hooksPath, an include or an alias through the environment: GIT_CONFIG_KEY_<n>,
# or the older GIT_CONFIG_PARAMETERS (its quoting is read in the raw command); or that points git to another
# global or system config file, which can hold any of them.
check_env() {
  if [[ ${1,,} =~ ^git_config_nosystem=(.*)$ ]]; then
    case ${BASH_REMATCH[1]//[\"\']/} in "" | 0 | false | no | off) ;; *) deny_skip "GIT_CONFIG_NOSYSTEM: it drops the system config, where a policy such as core.hooksPath may sit" ;; esac
  fi
  [[ ${1,,} =~ ^git_config_(global|system)= ]] && deny_skip "${1%%=*}: another config file"
  [[ ${1,,} =~ ^git_config_key_[0-9]+=(.*)$ ]] && split_key "${BASH_REMATCH[1]//[\"\']/}" && deny_skip "GIT_CONFIG_KEY split by a variable"
  [[ ${1,,} =~ ^git_config_key_[0-9]+=[\"\']?core\.hookspath ]] && deny_skip "GIT_CONFIG_KEY core.hooksPath"
  [[ ${1,,} =~ ^git_config_key_[0-9]+=[\"\']?(include\.path|includeif\.[^=]*\.path) ]] && deny_skip "GIT_CONFIG_KEY include.path"
  [[ ${1,,} =~ ^git_config_key_[0-9]+=[\"\']?alias\. ]] && alias_bad && deny_skip "GIT_CONFIG_KEY alias that runs a denied option"
  # Its value is a list of quoted pairs, which the parsed command no longer shows: read the flattened one,
  # and refuse a value that is not a literal ($X, $(..), backticks) since it cannot be read at all. The
  # value is read whole in the raw command, spaces inside its quotes included.
  if [[ $1 == GIT_CONFIG_PARAMETERS=* ]]; then
    [[ ${1,,} == *hookspath* || $flat == *hookspath* ]] && deny_skip "GIT_CONFIG_PARAMETERS core.hooksPath"
    [[ $flat =~ (include|includeif\.[^[:space:]]*)\.path ]] && deny_skip "GIT_CONFIG_PARAMETERS include.path"
    [[ $flat == *alias.* ]] && alias_bad && deny_skip "GIT_CONFIG_PARAMETERS alias that runs a denied option"
    local re='GIT_CONFIG_PARAMETERS=(\"([^\"\\]|\\.)*\"|'"'"'[^'"'"']*'"'"'|[^[:space:]\"'"'"'])+' rest=$raw
    while [[ $rest =~ $re ]]; do
      [[ ${BASH_REMATCH[0]} == *[\$\`]* ]] && deny_skip "GIT_CONFIG_PARAMETERS set to a value that is not a literal"
      rest=${rest#*"${BASH_REMATCH[0]}"}
    done
  fi
  return 0
}

# A pushed ref whose name a variable splits (`ma${x}in`) can be the default branch: the value is not followed,
# so deny when the name, with the variables left open, can be one. A name that is only a variable is a value
# the guard does not follow, as documented.
var_default() { # ref, as written: [+]src:dst
  [[ $1 == *\$* ]] || return 1
  local p b head
  p=$(var_glob "${1#+}")
  p=${p##*:}
  p=${p#refs/heads/}
  [[ -n ${p//\*/} ]] || return 1
  head=$(git -C "$dir" symbolic-ref --short -q refs/remotes/origin/HEAD)
  for b in ${head:+${head#origin/}} ${head:-main master}; do
    # shellcheck disable=SC2053 # $p is a glob: the variables left open
    [[ $b == $p ]] && return 0
  done
  return 1
}

check_push() {
  local remote="" dst refs=() a r
  for a in "$@"; do
    case $a in
      --force-with-lease* | +*:* | -f) deny_force ;;
      --*)
        abbr "$a" --force 3 && deny_force
        abbr "$a" --force-with-lease 3 && deny_force
        abbr "$a" --force-if-includes 3 && deny_force
        abbr "$a" --all 2 || abbr "$a" --mirror 1 || abbr "$a" --branches 1 &&
          deny "pushing every branch is denied: it includes the default branch."
        ;;
      -*f*) deny_force ;;
      -*) ;;
      *) if [ -z "$remote" ]; then remote=$a; else refs+=("$a"); fi ;;
    esac
  done
  [ ${#refs[@]} -gt 0 ] || refs=("$(current)")
  for r in "${refs[@]}"; do
    [ "${r#+}" = "$r" ] || deny_force
    var_default "$r" && deny "pushing to the default branch is denied: a variable splits the name of the ref ($r), so write it out."
    dst=${r##*:}
    [ "$dst" = HEAD ] && dst=$(current)
    dst=${dst#refs/heads/}
    is_default "$dst" && deny "pushing to the default branch ($dst) is denied: open a pull request from a branch."
  done
}

while IFS= read -r segment; do
  read -ra w <<<"$segment"
  # Leading words that only set up the command: assignments, export, wrappers. A git setting handed
  # over through the environment switches the hooks off as surely as -c does.
  i=0
  while [[ ${w[i]:-} == *=* || ${w[i]:-} =~ ^(command|exec|export|declare|typeset|readonly)$ || (i -gt 0 && ${w[i]:-} == -*) ]]; do
    check_env "${w[i]:-}"
    i=$((i + 1))
  done
  # env, sudo, xargs... run what follows: look for the gh or git behind them, options and values included.
  if [[ ${w[i]##*/} =~ ^(env|sudo|doas|xargs|nohup|time|nice)$ ]]; then
    while [ "$i" -lt "${#w[@]}" ] && ! [[ ${w[i]##*/} =~ ^(gh|git)$ ]]; do
      check_env "${w[i]:-}"
      i=$((i + 1))
    done
  fi
  if [ "${w[i]##*/}" = gh ] 2>/dev/null; then
    # The command and subcommand are the first two words that are not options (-R takes a value).
    gs=() skip=false
    for a in "${w[@]:i+1}"; do
      if $skip; then skip=false; continue; fi
      case $a in
        -R | --repo | -X | --method) skip=true ;;
        -*) ;;
        *) gs+=("$a"); [ ${#gs[@]} -lt 2 ] || break ;;
      esac
    done
    # The words that name the command, not the endpoint of `gh api` (`repos/$R/pulls` is a path, not a split word).
    check_split "${gs[0]:-}" command
    [ "${gs[0]:-}" = api ] || check_split "${gs[1]:-}" command
    for a in "${w[@]:i+1}"; do check_split "$a" option; done
    # An alias is a command this guard cannot read: `gh alias set pm "pr merge --admin"`.
    [[ ${gs[0]:-} == alias && ${gs[1]:-} =~ ^(set|import)$ ]] &&
      deny "gh alias set or import is denied: an alias hides the command it runs from the guard, so run the command itself."
    merge=false
    [ "${gs[0]:-} ${gs[1]:-}" = "pr merge" ] && merge=true
    # Quoted paths ("repos/$R/...") are no longer in $command: the API checks read the raw one.
    api_opts=" ${w[*]:i+2} " write=false method=""
    if [ "${gs[0]:-}" = api ]; then
      if [[ $api_opts =~ \ (-X|--method)[\ =]?([A-Za-z]+)\  ]]; then
        method=${BASH_REMATCH[2]^^}
        [ "$method" = GET ] || write=true
      elif [[ $api_opts =~ \ (-f|-F|--field|--raw-field|--input)[\ =] ]]; then
        write=true
      fi
    fi
    # Where the quoting is not plain, the words above may have lost the method (`-X "PUT"` after an
    # escaped quote): fail closed, a write unless every method option in the command says GET.
    if [[ ${gs[0]:-} == api && $untrusted == true ]]; then
      opt='(^|[[:space:]])(-x|--method)'
      methods=$(grep -oE "$opt" <<<"$flat" | wc -l) gets=$(grep -oE "${opt}[[:space:]=]?get([[:space:]]|\$)" <<<"$flat" | wc -l)
      if [ "$methods" -eq 0 ]; then
        # No method option at all: gh api is a GET unless a field or an input makes it a POST.
        write=false
        [[ $flat =~ (^|[[:space:]])(-[a-zA-Z]*[fF]|--field|--raw-field|--input) ]] && write=true
      elif [ "$gets" -ne "$methods" ]; then method=PUT write=true
      fi
    fi
    # The endpoint is a variable alone (`gh api -X PUT "$EP"`): where a write goes cannot be read.
    if [[ ${gs[0]:-} == api && $write == true ]]; then
      skip=false seen=false
      for a in "${w[@]:i+1}"; do
        if ! $seen; then [ "$a" = api ] && seen=true; continue; fi
        if $skip; then skip=false; continue; fi
        case $a in
          -X | --method | -H | --header | -f | -F | --field | --raw-field | -q | --jq | -t | --template | --input | --hostname | --cache | -p | --preview) skip=true ;;
          -*) ;;
          *)
            [[ $a =~ ^(\$([A-Za-z_][A-Za-z0-9_]*|\{[^}]*\}))+$ ]] &&
              deny "gh api with a write method and the endpoint in a variable is denied: the guard cannot read where it goes. Write the endpoint out."
            break
            ;;
        esac
      done
    fi
    # In a run only `senior-mode run` merges, after its own checks (ADR 0008): the ticket session,
    # which can post its own statuses, must never merge, whatever autonomy.merge says.
    if [ "${SENIOR_MODE_RUN:-}" = 1 ]; then
      $merge && deny "a run session never merges: senior-mode run merges after its own checks, or a human does."
      # A GraphQL mutation sits in quoted text, which $command no longer holds: read the raw one.
      [[ ${gs[0]:-} == api && ($ep =~ pulls/[^/[:space:]]+/merge|/merges || $ep =~ $re_vmerge || $rawb =~ mergePullRequest|enablePullRequestAutoMerge) ]] &&
        deny "a run session never merges, not through gh api either."
      # The rules that bound the run are the human's (spec 130, #116).
      [[ ($write == true && ($ep =~ /rulesets([^[:alnum:]_.-]|$)|/branches/[^[:space:]]+/protection || $ep =~ $re_vprot)) ||
        (${gs[0]:-} == api && $rawb =~ (create|update|delete)(RepositoryRuleset|BranchProtectionRule)) ]] &&
        deny "a run session never changes rulesets or branch protection: say in the pull request what a human should change."
    fi
    # The ruleset lets admins bypass it on purpose (spec 0001 §11); an agent running as an admin must not.
    $merge && [[ " ${w[*]:i+1} " =~ \ --admin[=\ ] ]] &&
      deny "gh pr merge --admin bypasses the required checks and review: a human must do it."
    # Through the API, an admin's merge bypasses the ruleset without any flag.
    [[ $method == PUT && ($ep =~ pulls/[^/[:space:]]+/merge([^[:alnum:]_.-]|$) || $ep =~ $re_vmerge) ]] &&
      deny "merging through gh api can bypass the required checks: use gh pr merge without --admin."
    continue
  fi
  [ "${w[i]##*/}" = git ] 2>/dev/null || continue
  dir=$cwd
  i=$((i + 1))
  while [[ ${w[i]:-} == -* ]]; do
    case ${w[i]} in
      -C) dir=$(cd "$dir" 2>/dev/null && cd "${w[i + 1]}" 2>/dev/null && pwd) || dir=$cwd; i=$((i + 2)) ;;
      -c) check_kv "${w[i + 1]:-}"; i=$((i + 2)) ;;
      --config-env=*) check_kv "${w[i]#*=}"; i=$((i + 1)) ;;
      --config-env) check_kv "${w[i + 1]:-}"; i=$((i + 2)) ;;
      *) check_split "${w[i]}" option; i=$((i + 1)) ;;
    esac
  done
  sub=${w[i]:-}
  args=("${w[@]:i+1}")
  check_split "$sub" command
  for a in ${args[@]+"${args[@]}"}; do
    check_split "$a" option
    abbr "$a" --no-verify 4 && deny_skip "--no-verify"
    [[ $sub == commit && $a =~ ^-[a-zA-Z]*n[a-zA-Z]*$ ]] && deny_skip "commit -n"
  done
  case $sub in
    push) check_push ${args[@]+"${args[@]}"} ;;
    config)
      # Setting or unsetting core.hooksPath switches the hooks off as surely as -c does; reading it is fine.
      # So does an include (another file), an alias that runs a denied option, or an editor, which can write
      # any key. Another file with --file is no different: the key decides.
      key="" k=""
      for a in ${args[@]+"${args[@]}"}; do
        [[ $a =~ ^-[a-zA-Z]*e[a-zA-Z]*$ ]] || abbr "$a" --edit 2 && deny "git config --edit is denied: an editor can write any key, core.hooksPath included."
        k=${a,,}
        if [ -z "$key" ]; then
          case $k in
            core.hookspath) key=hooks ;;
            include.path | includeif.*.path) key=include ;;
            alias.*) key="alias" ;;
            *) split_key "$k" && key="split" ;;
          esac
        elif [[ $a != -* ]]; then
          case $key in
            hooks) deny_skip "core.hooksPath" ;;
            split) deny_skip "a config key split by a variable" ;;
            include) deny_skip "include.path: it pulls in a file this guard cannot read" ;;
            alias) alias_bad && deny_skip "an alias that runs a denied option" ;;
          esac
        fi
      done
      if [ "$key" = hooks ] || [ "$key" = split ]; then
        for a in ${args[@]+"${args[@]}"}; do
          abbr "$a" --unset-all 5 || abbr "$a" --replace-all 3 || abbr "$a" --add 1 || [ "$a" = unset ] && deny_skip "core.hooksPath"
        done
      fi
      ;;
    reset)
      for a in ${args[@]+"${args[@]}"}; do
        abbr "$a" --hard 1 || continue
        b=$(current)
        [ -n "$b" ] && is_shared "$b" &&
          deny "reset --hard on $b, a shared branch, is denied: use git revert, or reset a local branch."
      done
      ;;
  esac
done < <(tr ';|&()`' '\n' <<<"$command")
exit 0
