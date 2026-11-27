# shellcheck shell=bash
# The decision of the credential broker (spec 328 section 2.2, ADR 0025, #775): which gh, git push and senior-mode verbs a
# sandboxed session may run. A pure function over an allowlist kept as data: no socket and no execution here (#452b).
# A session is a ticket number; its context (ticket, branch, pull request, role, base) is the file
# <serve dir>/broker/<session>.ctx that the daemon writes when it starts the session. Definitions only.

BROKER_DENY_EXIT=126
# gh groups that sandbox.verbs can never name, whatever the sub-command.
BROKER_VERBS_NEVER='auth|repo|api|secret|variable|ssh-key|gpg-key|config|extension|alias|codespace'

broker_dir() {
  printf '%s\n' "${SERVE_DIR:-$(git rev-parse --path-format=absolute --git-common-dir)/senior-mode/serve}"
}

# One line per request in <serve dir>/broker.log: epoch session verb allow|deny exit (the words of the verb joined by `:`).
broker_log() { # session verb decision exit
  mkdir -p "$(broker_dir)"
  printf '%s %s %s %s %s\n' "$(date +%s)" "$1" "${2// /:}" "$3" "$4" | state_append "$(broker_dir)/broker.log"
}

# The verb of an argv as the log and the message name it: `gh pr merge`, `git push`, `senior-mode publish`.
broker_verb() {
  case ${1:-} in
    gh) if [ "${2:-}" = api ]; then echo "gh api"; else echo "gh ${2:-} ${3:-}"; fi ;;
    senior-mode) case ${2:-} in item | issue | red-tests) echo "senior-mode ${2:-} ${3:-}" ;; *) echo "senior-mode ${2:-}" ;; esac ;;
    *) echo "${1:-} ${2:-}" ;;
  esac | sed 's/[[:space:]]*$//; s/[^A-Za-z0-9 ._:-]/?/g'
}

# Reads the context of session $1 into BROKER_TICKET, BROKER_BRANCH, BROKER_PR, BROKER_ROLE, BROKER_BASE.
broker_context() {
  local file json
  [[ $1 =~ ^[0-9]+$ ]] || return 1
  file=$(broker_dir)/broker/$1.ctx
  [ -f "$file" ] || return 1
  json=$(jq -c 'select(type == "object")' "$file" 2>/dev/null) && [ -n "$json" ] || return 1
  BROKER_TICKET=$(jq -r '.ticket // empty' <<<"$json")
  BROKER_BRANCH=$(jq -r '.branch // empty' <<<"$json")
  BROKER_PR=$(jq -r '.pr // empty' <<<"$json")
  BROKER_ROLE=$(jq -r '.role // empty' <<<"$json")
  BROKER_BASE=$(jq -r '.base // empty' <<<"$json")
  [[ $BROKER_TICKET =~ ^[0-9]+$ ]] && [ -n "$BROKER_BRANCH" ] || return 1
  [ -n "$BROKER_BASE" ] || {
    BROKER_BASE=$(default_branch 2>/dev/null) || BROKER_BASE=""
    BROKER_BASE=${BROKER_BASE#origin/}
  }
}

# The extra read-only verbs of sandbox.verbs, one per line, those that are `gh <group> <view|list|status|diff|checks>` and not
# of a group in BROKER_VERBS_NEVER. The schema refuses the others in `config validate`; this keeps them denied anyway.
broker_extra_verbs() {
  config_effective 2>/dev/null | jq -r --arg never "^($BROKER_VERBS_NEVER)\$" '
    (.sandbox.verbs // [])[] | strings
    | select(test("^gh [a-z-]+ (view|list|status|diff|checks)$"))
    | select((split(" ")[1] | test($never)) | not)' 2>/dev/null || true
}

# gh options that name another repository or host, or read a file of the daemon's machine.
broker_gh_option_bad() {
  local a
  for a in "$@"; do
    case $a in
      --repo | --repo=* | -R | -R* | --hostname | --hostname=* | --body-file | --body-file=* | -F | -F* | --web | -w) return 0 ;;
    esac
  done
  return 1
}

# The values of the option $1 (long form, and short form $2 when given) among the arguments $3...
broker_option_values() {
  local long=$1 short=$2 a prev=""
  shift 2
  for a in "$@"; do
    if [ -n "$prev" ]; then
      printf '%s\n' "$a"
      prev=""
      continue
    fi
    case $a in
      "$long" | "$short") [ -n "$a" ] && prev=1 ;;
      "$long="*) printf '%s\n' "${a#*=}" ;;
    esac
  done
  [ -z "$prev" ] || printf '\n'
}

# Every value of the option is $1 (and there is at least one): broker_option_is <value> <long> <short> <args>...
broker_option_is() {
  local want=$1 v n=0
  shift
  while IFS= read -r v; do
    [ "$v" = "$want" ] || return 1
    n=$((n + 1))
  done < <(broker_option_values "$@")
  [ "$n" -gt 0 ]
}

# gh api: a GET on repos/<slug>/{issues,pulls,commits,statuses,check-runs,contents}; or, for the roles that set a status of
# their own, the POST of senior-mode/review (reviewer) or senior-mode/security (reviewer, security) on a commit.
broker_api_allow() { # slug args...
  local slug=$1 method="" ep="" a prev="" fields=0 context="" ncontext=0 lc
  shift
  for a in "$@"; do
    if [ -n "$prev" ]; then
      case $prev in
        method) method=${a^^} ;;
        field)
          fields=$((fields + 1))
          case $a in context=*) context=${a#context=}; ncontext=$((ncontext + 1)) ;; esac
          ;;
        skip) ;;
      esac
      prev=""
      continue
    fi
    case $a in
      -X | --method) prev=method ;;
      --method=*) method=${a#*=}; method=${method^^} ;;
      -f | -F | --field | --raw-field) prev=field ;;
      --field=* | --raw-field=* | -f* | -F*)
        fields=$((fields + 1))
        a=${a#*=}
        case $a in context=*) context=${a#context=}; ncontext=$((ncontext + 1)) ;; esac
        ;;
      -q | --jq | -H | --header | -t | --template | --cache) prev=skip ;;
      --input | --input=* | --hostname | --hostname=*) return 1 ;;
      -*) ;;
      *) [ -z "$ep" ] || return 1; ep=$a ;;
    esac
  done
  [ -z "$prev" ] || return 1
  ep=${ep#/}
  lc=${ep,,}
  case $lc in *..* | *%* | *//* | graphql*) return 1 ;; esac
  [[ ${lc%%\?*} == repos/"${slug,,}"/* ]] || return 1
  local rest=${ep#*/*/*/}
  rest=${rest%%\?*}
  if [ "${method:-$([ "$fields" -gt 0 ] && echo POST || echo GET)}" = GET ]; then
    case ${rest%%/*} in issues | pulls | commits | statuses | check-runs | contents) return 0 ;; esac
    return 1
  fi
  # A status of the session's own: POST repos/<slug>/statuses/<sha> with exactly one context.
  [ "${method:-POST}" = POST ] && [[ ${rest,,} =~ ^statuses/[0-9a-f]{40}$ ]] && [ "$ncontext" -eq 1 ] || return 1
  case $context:$BROKER_ROLE in
    senior-mode/review:reviewer | senior-mode/security:reviewer | senior-mode/security:security) return 0 ;;
  esac
  return 1
}

# broker_allow <session> <argv...>: 0 when the session may run the argv, with BROKER_ARGV set to the argv to run under
# `env` (GH_REPO=<slug> first); 126 when it may not, with `denied: <verb> is not on the sandbox allowlist` on stderr and a
# `deny` line in <serve dir>/broker.log. Every answer is one line of the log.
broker_allow() {
  local session=$1 verb ok=1 slug v
  shift
  BROKER_ARGV=()
  verb=$(broker_verb "$@")
  if broker_context "$session" && slug=$(repo_slug 2>/dev/null) && [ -n "$slug" ]; then
    case ${1:-} in
      gh) broker_allow_gh "$slug" "$@" && ok=0 ;;
      git) broker_allow_git "$@" && ok=0 ;;
      senior-mode) broker_allow_cli "$@" && ok=0 ;;
    esac
    if [ "$ok" -ne 0 ] && [ "${1:-}" = gh ] && ! broker_gh_option_bad "$@"; then
      while IFS= read -r v; do
        [ "gh ${2:-} ${3:-}" = "$v" ] && ok=0
      done < <(broker_extra_verbs)
    fi
  fi
  if [ "$ok" -eq 0 ]; then
    BROKER_ARGV=("GH_REPO=$slug" "$@")
    broker_log "$session" "$verb" allow 0
    return 0
  fi
  echo "denied: $verb is not on the sandbox allowlist" >&2
  broker_log "$session" "$verb" deny "$BROKER_DENY_EXIT"
  return "$BROKER_DENY_EXIT"
}

# The pull request number $1 is the session's own, or any number when the session is a reviewer's and $2 is `any`.
broker_pr_ok() {
  [[ $1 =~ ^[0-9]+$ ]] || return 1
  [ "$1" = "$BROKER_PR" ] && return 0
  [ "${2:-}" = any ] && [ "$BROKER_ROLE" = reviewer ]
}

broker_allow_gh() { # slug argv...
  local slug=$1 group sub
  shift
  group=${2:-} sub=${3:-}
  if [ "$group" = api ]; then
    broker_api_allow "$slug" "${@:3}"
    return
  fi
  broker_gh_option_bad "$@" && return 1
  case "$group $sub" in
    "issue view" | "issue list") return 0 ;;
    "issue comment") [ "${4:-}" = "$BROKER_TICKET" ] ;;
    "pr create")
      broker_option_is "$BROKER_BRANCH" --head -H "${@:4}" || return 1
      [ -z "$(broker_option_values --base -B "${@:4}")" ] || broker_option_is "$BROKER_BASE" --base -B "${@:4}"
      ;;
    "pr view" | "pr diff") broker_pr_ok "${4:-}" any ;;
    "pr checks" | "pr comment" | "pr edit") broker_pr_ok "${4:-}" ;;
    *) return 1 ;;
  esac
}

# git push of the session's branch, plain: `git push [-u] origin <branch>`.
broker_allow_git() {
  [ "${2:-}" = push ] || return 1
  shift 2
  case ${1:-} in -u | --set-upstream) shift ;; esac
  [ $# -eq 2 ] && [ "$1" = origin ] && [ "$2" = "$BROKER_BRANCH" ]
}

# The tip of the session's branch begins with the sha $1 (7 to 40 hexadecimal characters).
broker_tip_is() {
  local tip
  [[ $1 =~ ^[0-9a-f]{7,40}$ ]] || return 1
  tip=$(git rev-parse --verify -q "refs/heads/$BROKER_BRANCH^{commit}" 2>/dev/null ||
    git rev-parse --verify -q "refs/remotes/origin/$BROKER_BRANCH^{commit}" 2>/dev/null) || return 1
  [[ $tip == "$1"* ]]
}

broker_allow_cli() {
  local i flags=""
  shift
  case ${1:-} in
    publish) [ $# -eq 2 ] && broker_tip_is "$2" ;;
    item)
      [ "${2:-}" = set ] && [ "${3:-}" = "$BROKER_TICKET" ] && [ $# -ge 5 ] && [ $(($# % 2)) -eq 1 ] || return 1
      for ((i = 4; i <= $#; i += 2)); do [ "${!i}" = Status ] || return 1; done
      ;;
    issue)
      [ "${2:-}" = create ] || return 1
      flags=" $* "
      [[ $flags == *" --severity "* && $flags == *" --kind "* ]]
      ;;
    red-tests) [ $# -eq 3 ] && [ "$2" = record ] && [ "$3" = "$BROKER_TICKET" ] ;;
    *) return 1 ;;
  esac
}
