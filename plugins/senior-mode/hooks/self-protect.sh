#!/usr/bin/env bash
# PreToolUse on Edit, Write, MultiEdit, NotebookEdit and Bash: during an autonomous run
# (SENIOR_MODE_RUN=1), denies changes to the files that guard the run, `.github/workflows/**`,
# `.claude/**` and `.githooks/**` at the repository root, and the git hooks and config (spec 0001
# §10, self-protection; #116), so an
# agent cannot weaken its own barriers. Outside a run it does nothing. Prints a deny decision, or
# nothing to allow.
# A guardrail for honest mistakes, not a sandbox, like guard-bash.sh: a Bash command is read as
# written, so `bash -c "..."`, variables, a `cd` earlier in the command and scripts are not followed.
[ "${SENIOR_MODE_RUN:-}" = 1 ] || exit 0
set -o pipefail
input=$(cat)
# One jq call for the fields; the unit separator, not whitespace, keeps empty fields.
IFS=$'\x1f' read -r event tool cwd path < <(jq -r '[.hook_event_name, .tool_name, .cwd,
  .tool_input.file_path // .tool_input.notebook_path] | map(. // "" | tostring) | join("\u001f")' <<<"$input")
[ "$event" = PreToolUse ] || exit 0

root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || exit 0
# git resolves symlinks in the root, Claude Code sends paths as reached from the cwd: try both.
here=$(cd "$cwd/$(git -C "$cwd" rev-parse --show-cdup)" 2>/dev/null && pwd) || here=$root
# The git hooks and config (core.hooksPath) of every worktree live in the common dir (#116); the
# per-worktree config.worktree (extensions.worktreeConfig) lives in the common dir or under worktrees/.
common=$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)

deny() { # path as written
  jq -nc --arg r "senior-mode: during a run, $1 belongs to the project's own guard rails (workflows, .claude/, .githooks/, the git hooks and config) and an agent does not change them. Do not work around this: leave that change out, say in the pull request that a human has to make it, and carry on with the rest." \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
  exit 0
}

# Absolute path without . and .. segments, no filesystem access (realpath -m is GNU only).
normalize() {
  local -a segs out=()
  local s IFS=/
  read -ra segs <<<"$1"
  for s in "${segs[@]}"; do
    case $s in
      "" | .) ;;
      ..) [ ${#out[@]} -eq 0 ] || unset "out[${#out[@]}-1]" ;;
      *) out+=("$s") ;;
    esac
  done
  printf '/%s\n' "${out[*]}"
}

# Denies a path, as written, that is under a protected directory of the repository.
check() {
  local p=$1 r rel rest
  [ -n "$p" ] || return 0
  [[ $p == /* ]] || p=$cwd/$p
  p=$(normalize "$p")
  # An unexpanded glob directly under the common dir (`rm -rf .git/*`) reaches the hooks and the config.
  rest=${p#"$common"/}
  [[ -n $common && $p == "$common"/* && ${rest%%/*} == *[\*\?\[]* ]] && deny "$1"
  [[ -n $common && ($p == "$common" || $p == "$common"/hooks || $p == "$common"/hooks/* || $p == "$common"/config ||
    $p == "$common"/config.worktree || $p == "$common"/worktrees/*/config.worktree) ]] && deny "$1"
  for r in "$root" "$here"; do
    [[ $p == "$r"/* ]] || continue
    rel=${p#"$r"/}
    case $rel in
      # Agents with `memory: project` keep their findings there; it guards nothing.
      .claude/agent-memory/*) ;;
      .git | .github | .github/workflows | .github/workflows/* | .claude | .claude/* | .githooks | .githooks/*) deny "$1" ;;
    esac
  done
}

if [ "$tool" != Bash ]; then
  case $tool in Edit | Write | MultiEdit | NotebookEdit) check "$path" ;; esac
  exit 0
fi

# Quoted text is data (commit messages, echo), never a target: replace it before parsing. A quoted
# single word (a path) is unquoted instead. Outside quotes a backslash is dropped as the shell does
# (`.g\it`, `.git\/hooks`); an escaped space or quote becomes `Q`, so it neither splits a word nor opens a
# quote. A backslash-newline continues the line, `>|` is one operator.
command=$(jq -r '.tool_input.command // "" | gsub("\\\\\n"; " ") | gsub(">\\|"; ">")
  | gsub("\"(?<w>[^\"\\\\\\s$`]*)\"|'"'"'(?<v>[^'"'"'\\s]*)'"'"'|(?<g>\"(\\\\.|[^\"\\\\])*\"|'"'"'[^'"'"']*'"'"')|\\\\(?<c>[^\\n \"'"'"'])|\\\\(?<e>[ \"'"'"'])"; .w // .v // .g // .c // (if .e then "Q" else "" end))
  | gsub("\"(\\\\.|[^\"\\\\])*\""; "Q") | gsub("'"'"'[^'"'"']*'"'"'"; "Q")' <<<"$input")

redirect='^[^>]*>>?(.*)$'
while IFS= read -r segment; do
  read -ra w <<<"$segment"
  # Redirections: `> f`, `>> f`, `2> f`, `x>f`; `>&2` duplicates a descriptor.
  for ((j = 0; j < ${#w[@]}; j++)); do
    [[ ${w[j]} =~ $redirect ]] || continue
    target=${BASH_REMATCH[1]:-${w[j + 1]:-}}
    [[ $target == '&'* ]] || check "$target"
  done
  i=0
  while [[ ${w[i]:-} == *=* || ${w[i]:-} =~ ^(command|exec)$ ]]; do i=$((i + 1)); done
  # sudo, env, xargs... run what follows: go on to the command they run, options and values included.
  if [[ ${w[i]##*/} =~ ^(sudo|doas|env|xargs|nohup|time|nice)$ ]]; then
    while [ "$i" -lt "${#w[@]}" ] &&
      ! [[ ${w[i]##*/} =~ ^(tee|rm|rmdir|unlink|touch|truncate|shred|mv|chmod|chown|chgrp|cp|install|ln|sed|perl|dd|git)$ ]]; do
      i=$((i + 1))
    done
  fi
  cmd=${w[i]:-}
  cmd=${cmd##*/}
  [ -n "$cmd" ] || continue
  args=("${w[@]:i+1}")
  paths=() inplace=false last="" into=""
  prev=""
  for a in ${args[@]+"${args[@]}"}; do
    if [[ $a == -* ]]; then
      [[ $a =~ ^-[a-zA-Z]*i || $a == --in-place* ]] && inplace=true
      [[ $a == --target-directory=* ]] && into=${a#*=}
    else
      [[ $prev == -t || $prev == --target-directory ]] && into=$a
      paths+=("$a")
      last=$a
    fi
    prev=$a
  done
  case $cmd in
    tee | rm | rmdir | unlink | touch | truncate | shred | mv | chmod | chown | chgrp) for a in ${paths[@]+"${paths[@]}"}; do check "$a"; done ;;
    cp | install | ln) check "$last"; check "$into" ;;
    sed | perl) ! $inplace || for a in ${paths[@]+"${paths[@]}"}; do check "$a"; done ;;
    dd) for a in ${args[@]+"${args[@]}"}; do [[ $a == of=* ]] && check "${a#of=}"; done ;;
    git)
      # The subcommand is the first word that is not an option or an option's value (-C dir, -c k=v).
      sub="" skip=false
      for a in ${args[@]+"${args[@]}"}; do
        if $skip; then skip=false; continue; fi
        case $a in
          -C | -c) skip=true ;;
          -*) ;;
          *) sub=$a; break ;;
        esac
      done
      case $sub in rm | mv | checkout | restore) for a in ${paths[@]+"${paths[@]}"}; do check "$a"; done ;; esac
      ;;
  esac
done < <(tr ';|&()`' '\n' <<<"$command")
exit 0
