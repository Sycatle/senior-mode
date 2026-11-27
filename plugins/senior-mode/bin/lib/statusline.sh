# shellcheck shell=bash
# One line for Claude Code's status line (spec 0001 §20): the ticket of the branch, the last check
# recorded for it and, during a run, a mark. Offline and fast; prints nothing where senior-mode is not
# set up, and never fails. Claude Code sends the session as JSON on stdin; its directory is used.
statusline() {
  local input="" dir root branch ticket record state="no check" parts
  [ -t 0 ] || input=$(cat)
  dir=$(jq -r '.workspace.current_dir // .cwd // empty' <<<"$input" 2>/dev/null) || dir=""
  [ -z "$dir" ] || cd "$dir" 2>/dev/null || return 0
  root=$(git rev-parse --show-toplevel 2>/dev/null) || return 0
  [ -f "$root/.claude/senior-mode.json" ] || return 0
  branch=$(git symbolic-ref --short -q HEAD) || branch=$(git rev-parse --short HEAD 2>/dev/null) || return 0
  ticket=$(workflow_branch_issue "$branch")
  parts=${ticket:+#$ticket}
  parts=${parts:-$branch}
  record=$(check_record "$(git rev-parse HEAD 2>/dev/null)") || true
  if [ -f "$record" ]; then
    if [ -n "$(worktree_status 2>/dev/null)" ]; then
      state="check stale"
    elif [ "$(sed -n 1p "$record")" = success ]; then
      state="check ok"
    else
      state="check FAILED"
    fi
  fi
  parts+=" · $state"
  [ -z "${SENIOR_MODE_RUN:-}" ] || parts+=" · run in progress"
  printf '%s\n' "$parts"
}

# The command of the status line setup writes. A plugin cannot ship a status line, and the plugin's
# directory changes with every version, so the command looks the script up each time: the install
# path in Claude Code's plugin registry, else the newest version in its plugin cache; nothing is
# printed when the plugin is not installed.
# shellcheck disable=SC2016 # a command for the project's settings, not for this shell
STATUSLINE_COMMAND='b=$(jq -r '\''[.plugins | to_entries[] | select(.key | startswith("senior-mode@")) | .value[].installPath] | last // empty'\'' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null)/bin/senior-mode; [ -x "$b" ] || b=$(ls -d "$HOME"/.claude/plugins/cache/*/senior-mode/*/bin/senior-mode 2>/dev/null | sort -V | tail -1); [ -x "$b" ] && exec "$b" statusline; exit 0'

# Writes the status line of the project into .claude/settings.json. A status line of the project's
# own is kept; ours is refreshed. A project setting hides the user's own status line in this project.
setup_statusline() {
  local root file current out=0
  root=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repository"
  file=$root/.claude/settings.json
  mkdir -p "$root/.claude"
  [ -f "$file" ] || echo '{}' >"$file"
  jq empty "$file" 2>/dev/null || die "invalid .claude/settings.json; fix or remove it, then run setup again"
  current=$(jq -r '.statusLine.command // empty' "$file")
  if [ -n "$current" ] && ! grep -q 'senior-mode' <<<"$current"; then
    echo "statusline: yours kept; to add senior-mode's, call \`senior-mode statusline\` from your command"
    return 0
  fi
  # shellcheck disable=SC2016 # a jq program, not shell
  json_update "$file" '.statusLine = {type: "command", command: $c}' --arg c "$STATUSLINE_COMMAND" || out=$?
  [ "$out" -ne 1 ] || die "could not update .claude/settings.json"
  if [ "$out" -eq 2 ]; then
    echo "statusline: already set in .claude/settings.json"
  else
    echo "statusline: set in .claude/settings.json (ticket, last check, run in progress)"
  fi
}
