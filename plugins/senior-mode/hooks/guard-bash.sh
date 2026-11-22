#!/usr/bin/env bash
# PreToolUse on Bash: denies git commands that skip checks, force-push, push to the default branch or
# discard commits of a shared branch, and gh pr merge --admin (spec 0001 §10). Prints a deny
# decision, or nothing to allow.
# A guardrail for honest mistakes, not a sandbox: `bash -c "..."` and the like are not parsed.
set -o pipefail
input=$(cat)
# Quoted text is data (commit messages, echo), never options: replace it before parsing. A quoted
# single word (a URL, a ref) is unquoted instead. A backslash-newline continues the line.
command=$(jq -r '.tool_input.command // "" | gsub("\\\\\n"; " ")
  | gsub("\"(?<w>[^\"\\\\\\s$`]*)\"|'"'"'(?<v>[^'"'"'\\s]*)'"'"'"; .w // .v)
  | gsub("\"(\\\\.|[^\"\\\\])*\""; "Q") | gsub("'"'"'[^'"'"']*'"'"'"; "Q")' <<<"$input")
cwd=$(jq -r '.cwd // empty' <<<"$input")
raw=$(jq -r '.tool_input.command // ""' <<<"$input")

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
  i=0
  while [[ ${w[i]:-} == *=* || ${w[i]:-} == command || ${w[i]:-} == exec ]]; do i=$((i + 1)); done
  if [ "${w[i]##*/}" = gh ] 2>/dev/null; then
    # In a run only `senior-mode run` merges, after its own checks (ADR 0008): the ticket session,
    # which can post its own statuses, must never merge, whatever autonomy.merge says.
    if [ "${SENIOR_MODE_RUN:-}" = 1 ]; then
      [[ " ${w[*]:i+1} " =~ \ pr\ (.*\ )?merge\  ]] &&
        deny "a run session never merges: senior-mode run merges after its own checks, or a human does."
      # A GraphQL mutation sits in quoted text, which $command no longer holds: read the raw one.
      [[ ${w[i + 1]:-} == api && $raw =~ pulls/[0-9]+/merge|/merges|mergePullRequest|enablePullRequestAutoMerge ]] &&
        deny "a run session never merges, not through gh api either."
    fi
    # The ruleset lets admins bypass it on purpose (spec 0001 §11); an agent running as an admin must not.
    [[ " ${w[*]:i+1} " =~ \ pr\ (.*\ )?merge\  && " ${w[*]:i+1} " =~ \ --admin[=\ ] ]] &&
      deny "gh pr merge --admin bypasses the required checks and review: a human must do it."
    # Through the API, an admin's merge bypasses the ruleset without any flag.
    [[ ${w[i + 1]:-} == api && " ${w[*]:i+2} " =~ pulls/[0-9]+/merge[\ ?] &&
      " ${w[*]:i+2} " =~ \ (-X|--method)[\ =]?PUT\  ]] &&
      deny "merging through gh api can bypass the required checks: use gh pr merge without --admin."
    continue
  fi
  [ "${w[i]##*/}" = git ] 2>/dev/null || continue
  dir=$cwd
  i=$((i + 1))
  while [[ ${w[i]:-} == -* ]]; do
    case ${w[i]} in
      -C) dir=$(cd "$dir" 2>/dev/null && cd "${w[i + 1]}" 2>/dev/null && pwd) || dir=$cwd; i=$((i + 2)) ;;
      -c) [[ ${w[i + 1]} == core.hooksPath=* ]] && deny_skip "core.hooksPath"; i=$((i + 2)) ;;
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
