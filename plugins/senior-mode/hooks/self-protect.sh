#!/usr/bin/env bash
# PreToolUse on Edit, Write, MultiEdit, NotebookEdit and Bash: during an autonomous run
# (SENIOR_MODE_RUN=1), denies changes to the files that guard the run, `.github/workflows/**`,
# `.claude/**` and `.githooks/**` at the repository root, and the git hooks and config (spec 0001
# §10, self-protection; #116), so an
# agent cannot weaken its own barriers. Outside a run it does nothing. Prints a deny decision, or
# nothing to allow.
# A guardrail for honest mistakes, not a sandbox, like guard-bash.sh: a Bash command is read as
# written, so `bash -c "..."`, variables and scripts are not followed; a `cd` with a literal path earlier in
# the command is (both the cwd and where it went are checked).
# Also, in a session with SENIOR_MODE_ROLE=ticket, run or not, denies changes to the red tests: the files
# listed in <git common dir>/senior-mode/runs/<ticket>/red-tests (one path per line from the repository
# root, written when the test-author session of an M ticket is done; the ticket is read in the branch,
# `feat/<n>-slug`), which a separate session wrote and the implementer must make pass unchanged (spec 131, #191).
[ "${SENIOR_MODE_RUN:-}" = 1 ] || [ "${SENIOR_MODE_ROLE:-}" = ticket ] || exit 0
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
# per-worktree config.worktree (extensions.worktreeConfig) lives in the common dir or under worktrees/. The refs,
# packed-refs, HEAD, the objects, info/, modules/ and the worktrees/ admin dirs are not removed or overwritten
# by hand either.
common=$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
reds=() list=""
if [ "${SENIOR_MODE_ROLE:-}" = ticket ] && [[ $(git -C "$cwd" symbolic-ref --short -q HEAD) =~ ^[^/]+/([0-9]+)(-|$) ]]; then
  list=$common/senior-mode/runs/${BASH_REMATCH[1]}/red-tests
  [ -f "$list" ] && mapfile -t reds <"$list"
fi

deny() { # path as written
  jq -nc --arg r "senior-mode: during a run, $1 belongs to the project's own guard rails (workflows, .claude/, .githooks/, the git hooks and config) and an agent does not change them. Do not work around this: leave that change out, say in the pull request that a human has to make it, and carry on with the rest." \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
  exit 0
}

deny_discard() { # what
  [ "${SENIOR_MODE_RUN:-}" = 1 ] || return 0
  jq -nc --arg r "senior-mode: during a run, $1 discards branches, reflogs or objects that cannot be brought back, and an agent does not do that. Do not work around this: leave it out, say in the pull request what a human should clean up, and carry on with the rest." \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
  exit 0
}

deny_red() { # path as written
  jq -nc --arg r "senior-mode: $1 is one of the red tests of this ticket, written by a separate test-author session from the acceptance criteria. The implementer makes them pass and does not edit, move or delete them (you may add tests of your own). Do not work around this: if a red test is wrong, leave it as it is, say so in the pull request and let a human decide." \
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

# Where a relative path may point: the cwd, and every directory a `cd` earlier in the command went to (a
# subshell or a failed `cd` is not told apart, so each is tried).
bases=("$cwd") cur=$cwd
whole=false # the command removes or moves what it is given, a directory with what is in it

# Denies a path, as written, that is under a protected directory of the repository.
check() {
  local b
  [ -n "$1" ] || return 0
  if [[ $1 == /* ]]; then check_path "$1" "$1"; else for b in "${bases[@]}"; do check_path "$b/$1" "$1"; done; fi
}
check_path() { # absolute-or-relative path, as written
  local p=$1 r rel rest
  p=$(normalize "$p")
  if [ ${#reds[@]} -gt 0 ]; then
    [ "$p" = "$list" ] && deny_red "$2"
    for r in "$root" "$here"; do
      for rel in "${reds[@]}"; do
        [ -n "$rel" ] || continue
        [ "$p" = "$r/$rel" ] && deny_red "$2"
        # A directory that holds a red test goes with it (`rm -r tests`, `mv tests old`).
        $whole && [[ $r/$rel == "$p"/* ]] && deny_red "$2"
      done
    done
  fi
  [ "${SENIOR_MODE_RUN:-}" = 1 ] || return 0
  # An unexpanded glob directly under the common dir (`rm -rf .git/*`) reaches the hooks and the config.
  rest=${p#"$common"/}
  [[ -n $common && $p == "$common"/* && ${rest%%/*} == *[\*\?\[]* ]] && deny "$2"
  [[ -n $common && ($p == "$common" || $p == "$common"/hooks || $p == "$common"/hooks/* || $p == "$common"/config ||
    $p == "$common"/config.worktree || $p == "$common"/worktrees || $p == "$common"/worktrees/* ||
    $p == "$common"/refs || $p == "$common"/refs/* || $p == "$common"/objects || $p == "$common"/objects/* || $p == "$common"/HEAD || $p == "$common"/packed-refs ||
    $p == "$common"/info || $p == "$common"/info/* || $p == "$common"/modules || $p == "$common"/modules/*) ]] && deny "$2"
  for r in "$root" "$here"; do
    [[ $p == "$r"/* ]] || continue
    rel=${p#"$r"/}
    # In a linked worktree `.git` is a file: nothing is under it. In a main checkout the git dir is the common
    # dir, whose protected files are listed above; the rest (index.lock, rebase-merge, MERGE_HEAD) is recovery.
    [[ $rel == .git/* && -f $r/.git ]] && deny "$2"
    case $rel in
      # Agents with `memory: project` keep their findings there; it guards nothing.
      .claude/agent-memory/*) ;;
      .git | .github | .github/workflows | .github/workflows/* | .claude | .claude/* | .githooks | .githooks/*) deny "$2" ;;
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
    cd | pushd)
      # Later relative paths are read from there too; `cd`, `cd -` and a variable are not followed.
      a=${paths[0]:-}
      if [[ -n $a && $a != *[\$~]* && $a != Q ]]; then
        [[ $a == /* ]] || a=$cur/$a
        cur=$(normalize "$a")
        bases+=("$cur")
      fi
      ;;
    tee | rm | rmdir | unlink | touch | truncate | shred | mv | chmod | chown | chgrp)
      ! [[ $cmd =~ ^(rm|rmdir|unlink|shred|mv)$ ]] || whole=true
      for a in ${paths[@]+"${paths[@]}"}; do check "$a"; done
      whole=false
      ;;
    cp | install | ln) check "$last"; check "$into" ;;
    sed | perl) ! $inplace || for a in ${paths[@]+"${paths[@]}"}; do check "$a"; done ;;
    dd) for a in ${args[@]+"${args[@]}"}; do [[ $a == of=* ]] && check "${a#of=}"; done ;;
    git)
      # The subcommand is the first word that is not an option or an option's value (-C dir, -c k=v).
      sub="" skip=false rest=()
      for a in ${args[@]+"${args[@]}"}; do
        if [ -n "$sub" ]; then rest+=("$a"); continue; fi
        if $skip; then skip=false; continue; fi
        case $a in
          -C | -c) skip=true ;;
          -*) ;;
          *) sub=$a ;;
        esac
      done
      case $sub in
        rm | mv) whole=true ;;
      esac
      case $sub in rm | mv | checkout | restore) for a in ${paths[@]+"${paths[@]}"}; do check "$a"; done ;; esac
      whole=false
      # Refs and objects discarded by command: update-ref -d on a branch or HEAD, a reflog expired or
      # deleted, unreachable objects pruned at once. git takes `--pr=now` for `--prune=now`: so does this.
      # A dry run of reflog expire or prune (`--dry-run`, `--d`, `-n`) discards nothing.
      del=false hit=false first="" prev="" dry=false
      for a in ${rest[@]+"${rest[@]}"}; do
        [[ $a =~ ^--d(r(y(-(r(un?)?)?)?)?)?$ || ($sub == prune && $a =~ ^-[a-zA-Z]*n[a-zA-Z]*$) ]] && dry=true
      done
      for a in ${rest[@]+"${rest[@]}"}; do
        case $sub in
          update-ref)
            [[ $a =~ ^-[a-zA-Z]*d[a-zA-Z]*$ ]] && del=true
            [[ $a == HEAD || $a == refs/heads/* ]] && hit=true
            ;;
          reflog) [[ -n $first || $a == -* ]] || { first=$a; [[ $a =~ ^(expire|delete)$ ]] && ! $dry && deny_discard "git reflog $a"; } ;;
          gc) [[ $a =~ ^--p(r(u(n(e)?)?)?)?=(now|all)$ ]] && deny_discard "git gc $a" ;;
          prune)
            [[ $a =~ ^--exp(i(r(e)?)?)?=(now|all)$ ]] && ! $dry && deny_discard "git prune $a"
            [[ $prev =~ ^--exp(i(r(e)?)?)?$ && $a =~ ^(now|all)$ ]] && ! $dry && deny_discard "git prune $prev $a"
            ;;
        esac
        prev=$a
      done
      $del && $hit && deny_discard "git update-ref -d on a branch or HEAD"
      ;;
  esac
done < <(tr ';|&()`' '\n' <<<"$command")
exit 0
