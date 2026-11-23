#!/usr/bin/env bash
# PreToolUse on Bash: denies git commands that skip checks, force-push, push to the default branch or
# discard commits of a shared branch, switch the hooks off (core.hooksPath), and gh pr merge --admin
# (spec 0001 §10), the same through the GIT_CONFIG_KEY_<n> environment or a gh alias; in a run, any
# merge and any change to rulesets or branch protection (spec 130).
# Prints a deny decision, or nothing to allow.
# A guardrail for honest mistakes, not a sandbox: `bash -c "..."` and the like are not parsed.
set -o pipefail
input=$(cat)
# Quoted text is data (commit messages, echo), never options: replace it before parsing. A quoted
# single word (a URL, a ref) is unquoted instead. An empty pair touching a word (`--for""ce`) is removed;
# alone it is an argument (`core.hooksPath ""`) and stays, as `Q`. Outside quotes a backslash is dropped
# as the shell does (`--for\ce`, `core.hooksPath\=x`); an escaped space or quote becomes `Q`, so it neither
# splits a word nor opens a quote, and a value made only of them is still an argument. A backslash-newline
# continues the line.
command=$(jq -r '.tool_input.command // "" | gsub("\\\\\n"; " ")
  | gsub("\"(?<w>[^\"\\\\\\s$`]+)\"|'"'"'(?<v>[^'"'"'\\s]+)'"'"'|(?<=\\S)(?:\"\"|'"'"''"'"')|(?:\"\"|'"'"''"'"')(?=\\S)|(?<g>\"(\\\\.|[^\"\\\\])*\"|'"'"'[^'"'"']*'"'"')|\\\\(?<c>[^\\n \"'"'"'])|\\\\(?<e>[ \"'"'"'])"; .w // .v // .g // .c // (if .e then "Q" else "" end))
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

# An assignment that sets core.hooksPath through the environment: GIT_CONFIG_KEY_<n>, or the older
# GIT_CONFIG_PARAMETERS (its quoting is read in the raw command).
check_env() {
  [[ ${1,,} =~ ^git_config_key_[0-9]+=[\"\']?core\.hookspath ]] && deny_skip "GIT_CONFIG_KEY core.hooksPath"
  # Its value is a list of quoted pairs, which the parsed command no longer shows: read the flattened one,
  # and refuse a value that is not a literal ($X, $(..), backticks) since it cannot be read at all.
  if [[ $1 == GIT_CONFIG_PARAMETERS=* ]]; then
    [[ ${1,,} == *hookspath* || $flat == *hookspath* ]] && deny_skip "GIT_CONFIG_PARAMETERS core.hooksPath"
    [[ $flat =~ git_config_parameters=[^[:space:]]*[\$\`] ]] && deny_skip "GIT_CONFIG_PARAMETERS set to a value that is not a literal"
  fi
  return 0
}

check_push() {
  local remote="" dst refs=() a r
  for a in "$@"; do
    case $a in
      --force | --force-with-lease* | --force-if-includes | +*:* | -f) deny_force ;;
      --all | --mirror | --branches) deny "pushing every branch is denied: it includes the default branch." ;;
      --*) ;;
      -*f*) deny_force ;;
      -*) ;;
      *) if [ -z "$remote" ]; then remote=$a; else refs+=("$a"); fi ;;
    esac
  done
  [ ${#refs[@]} -gt 0 ] || refs=("$(current)")
  for r in "${refs[@]}"; do
    [ "${r#+}" = "$r" ] || deny_force
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
        -R | --repo) skip=true ;;
        -*) ;;
        *) gs+=("$a"); [ ${#gs[@]} -lt 2 ] || break ;;
      esac
    done
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
      if [ "$gets" -lt 1 ] || [ "$gets" -ne "$methods" ]; then method=PUT write=true; fi
    fi
    # In a run only `senior-mode run` merges, after its own checks (ADR 0008): the ticket session,
    # which can post its own statuses, must never merge, whatever autonomy.merge says.
    if [ "${SENIOR_MODE_RUN:-}" = 1 ]; then
      $merge && deny "a run session never merges: senior-mode run merges after its own checks, or a human does."
      # A GraphQL mutation sits in quoted text, which $command no longer holds: read the raw one.
      [[ ${gs[0]:-} == api && ($ep =~ pulls/[^/[:space:]]+/merge|/merges || $rawb =~ mergePullRequest|enablePullRequestAutoMerge) ]] &&
        deny "a run session never merges, not through gh api either."
      # The rules that bound the run are the human's (spec 130, #116).
      [[ ($write == true && $ep =~ /rulesets([/?[:space:]\"\']|$)|/branches/[^[:space:]]+/protection) ||
        (${gs[0]:-} == api && $rawb =~ (create|update|delete)(RepositoryRuleset|BranchProtectionRule)) ]] &&
        deny "a run session never changes rulesets or branch protection: say in the pull request what a human should change."
    fi
    # The ruleset lets admins bypass it on purpose (spec 0001 §11); an agent running as an admin must not.
    $merge && [[ " ${w[*]:i+1} " =~ \ --admin[=\ ] ]] &&
      deny "gh pr merge --admin bypasses the required checks and review: a human must do it."
    # Through the API, an admin's merge bypasses the ruleset without any flag.
    [[ $method == PUT && $ep =~ pulls/[^/[:space:]]+/merge([?[:space:]\"\']|$) ]] &&
      deny "merging through gh api can bypass the required checks: use gh pr merge without --admin."
    continue
  fi
  [ "${w[i]##*/}" = git ] 2>/dev/null || continue
  dir=$cwd
  i=$((i + 1))
  while [[ ${w[i]:-} == -* ]]; do
    case ${w[i]} in
      -C) dir=$(cd "$dir" 2>/dev/null && cd "${w[i + 1]}" 2>/dev/null && pwd) || dir=$cwd; i=$((i + 2)) ;;
      -c) [[ ${w[i + 1],,} == core.hookspath=* ]] && deny_skip "core.hooksPath"; i=$((i + 2)) ;;
      --config-env=*) [[ ${w[i],,} == --config-env=core.hookspath=* ]] && deny_skip "core.hooksPath"; i=$((i + 1)) ;;
      --config-env) [[ ${w[i + 1],,} == core.hookspath=* ]] && deny_skip "core.hooksPath"; i=$((i + 2)) ;;
      *) i=$((i + 1)) ;;
    esac
  done
  sub=${w[i]:-}
  args=("${w[@]:i+1}")
  for a in ${args[@]+"${args[@]}"}; do
    [ "$a" = --no-verify ] && deny_skip "--no-verify"
    [[ $sub == commit && $a =~ ^-[a-zA-Z]*n[a-zA-Z]*$ ]] && deny_skip "commit -n"
  done
  case $sub in
    push) check_push ${args[@]+"${args[@]}"} ;;
    config)
      # Setting or unsetting core.hooksPath switches the hooks off as surely as -c does; reading it is fine.
      key=false
      for a in ${args[@]+"${args[@]}"}; do
        if [ "${a,,}" = core.hookspath ]; then key=true
        elif $key && [[ $a != -* ]]; then deny_skip "core.hooksPath"
        fi
      done
      $key && [[ " ${args[*]} " =~ \ (--unset|--unset-all|--replace-all|--add|unset)\  ]] && deny_skip "core.hooksPath"
      ;;
    reset)
      for a in ${args[@]+"${args[@]}"}; do
        [ "$a" = --hard ] || continue
        b=$(current)
        [ -n "$b" ] && is_shared "$b" &&
          deny "reset --hard on $b, a shared branch, is denied: use git revert, or reset a local branch."
      done
      ;;
  esac
done < <(tr ';|&()`' '\n' <<<"$command")
exit 0
