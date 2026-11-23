# shellcheck shell=bash
# What `clean` says it did (or would do) with something it removes: runs $2... and reports on $1. The counters
# and rc belong to `clean`.
clean_act() {
  local what=$1 err
  shift
  if [ "$CLEAN_DRY" = true ]; then
    echo "would remove $what"
    CLEAN_REMOVED=$((CLEAN_REMOVED + 1))
  elif err=$("$@" 2>&1 </dev/null); then
    echo "removed $what"
    CLEAN_REMOVED=$((CLEAN_REMOVED + 1))
  else
    echo "kept $what: could not remove it: $(head -n 1 <<<"$err")"
    CLEAN_KEPT=$((CLEAN_KEPT + 1))
    CLEAN_RC=1
  fi
}

# Whether the branch $1 can go, from the pull requests $CLEAN_PRS keyed by branch (the open one, else the
# latest). Sets CLEAN_WHY (the reason it can go, empty when it stays), CLEAN_OID (the head of its pull
# request) and CLEAN_KEEP (the reason it stays though it could go: a ticket In progress). The state of the
# pull request on GitHub decides, never git ancestry: a squash or rebase merge leaves no ancestry. A branch
# with no pull request at all goes only when its ticket is closed.
clean_state() {
  local rec n st oid at issue state
  CLEAN_WHY="" CLEAN_OID="" CLEAN_KEEP=""
  rec=$(jq -r --arg b "$1" '.[$b] // empty | "\(.number) \(.state) \(.headRefOid) \(.mergedAt // .closedAt // "")"' <<<"$CLEAN_PRS")
  if [ -n "$rec" ]; then
    read -r n st oid at <<<"$rec"
    CLEAN_OID=$oid
    case $st in
      MERGED) CLEAN_WHY="pull request #$n merged" ;;
      CLOSED) CLEAN_WHY="pull request #$n closed" ;;
    esac
  elif [[ $1 =~ ^[a-z]+/([0-9]+)(-|$) ]]; then
    issue=${BASH_REMATCH[1]}
    state=$(gh_retry issue view "$issue" --repo "$CLEAN_SLUG" --json state 2>/dev/null | jq -r .state 2>/dev/null) || state=""
    [ "$state" != CLOSED ] || CLEAN_WHY="issue #$issue closed, no pull request"
  fi
  if [ -n "$CLEAN_WHY" ]; then
    CLEAN_KEEP=$(clean_guard "$1")
    [ -z "$CLEAN_KEEP" ] || CLEAN_WHY=""
  fi
}

# Why the branch $1 must stay though its pull request ended; nothing when it may go. Only the branches
# `start`, `frame start` and `run` make are candidates (`feat|fix|chore/<n>-...`, `docs/<slug>` with a slug of
# lower-case letters, digits and single hyphens, 40 characters at most, `docs/run-<stamp>`): a `dev`, a
# `staging`, a `release/*`, a `docs/next.v2` is reported, never deleted. The base of any pull request, open, closed or
# merged, stays (deleting it would close the pull requests stacked on it), and so does a protected branch
# and a ticket In progress.
clean_guard() {
  local n
  n=$(jq -r --arg b "$1" '.[$b] // empty' <<<"$CLEAN_BASES")
  if [ -n "$n" ]; then
    echo "base of pull request #$n"
  elif jq -e --arg b "$1" 'any(.[]; . == $b)' <<<"$CLEAN_PROTECTED" >/dev/null; then
    echo "protected"
  elif [[ $1 =~ ^(feat|fix|chore)/([0-9]+)(-|$) ]]; then
    ! jq -e --argjson n "${BASH_REMATCH[2]}" 'index($n)' <<<"$CLEAN_PROGRESS" >/dev/null || echo "ticket #${BASH_REMATCH[2]} is In progress"
  elif [[ ! $1 =~ ^docs/[a-z0-9]+(-[a-z0-9]+)*$ ]] || [ ${#1} -gt 45 ]; then
    echo "not a branch senior-mode makes"
  elif [ "$CLEAN_PROT_KNOWN" != true ]; then
    # Could it be protected? Unknown: a docs/ branch is kept, as everything that is not a ticket's.
    echo "protected branches could not be read"
  fi
}

# Why the commits of the local branch $1 are not safe to lose, with $2 the head of its pull request: they are
# on no remote branch and not in the default branch, and not in the pull request either (a merged pull
# request whose branch GitHub deleted still holds them). Prints nothing when they are safe. When origin could
# not be fetched (CLEAN_STALE) the remote-tracking refs may name branches that are gone, so they prove
# nothing: only the default branch and the pull request do, and the rest is unknown, hence kept.
clean_unpushed() {
  local tip count
  tip=$(git rev-parse -q --verify "refs/heads/$1^{commit}") || return 0
  if [ "$CLEAN_STALE" = true ]; then
    count=$(git rev-list --count "$tip" --not ${CLEAN_BASE:+"$CLEAN_BASE"})
  else
    count=$(git rev-list --count "$tip" --not --remotes ${CLEAN_BASE:+"$CLEAN_BASE"})
  fi
  [ "$count" -gt 0 ] || return 0
  [ "$tip" != "$2" ] || return 0
  if [ -n "$2" ] && git cat-file -e "$2^{commit}" 2>/dev/null && git merge-base --is-ancestor "$tip" "$2"; then
    return 0
  fi
  if [ "$CLEAN_STALE" = true ]; then
    echo "$count commit$([ "$count" -eq 1 ] || echo s) not in ${CLEAN_BASE:-the default branch} or its pull request, and origin could not be fetched: whether they are pushed is unknown"
  else
    echo "$count commit$([ "$count" -eq 1 ] || echo s) on no remote branch and not in ${CLEAN_BASE:-the default branch}"
  fi
}

# senior-mode clean [--dry-run] [--days N] (#225): removes what is finished, lists what it keeps and why.
#  - the worktrees and local branches of a pull request merged or closed, or of a closed ticket with no
#    pull request, wherever the worktree is (`git worktree list`);
#  - the remote branches of a pull request merged or closed more than N days ago;
#  - the run directories, the probe date and its log under <git common dir>/senior-mode older than N days;
#  - then `git worktree prune`.
# N is --days, else `hygiene.days` (default 14). It never removes the main worktree, the current one, a
# worktree with uncommitted changes, a branch with commits on no remote branch and not in the default
# branch (nor in its pull request), nor anything of a ticket In progress: those are listed with the reason
# and the exit status stays 0. --dry-run prints what would go and changes nothing.
clean() {
  local CLEAN_DRY=false CLEAN_STALE=false CLEAN_PROT_KNOWN=true CLEAN_REMOVED=0 CLEAN_KEPT=0 CLEAN_RC=0 CLEAN_PRS CLEAN_BASES CLEAN_PROTECTED CLEAN_SLUG CLEAN_PROGRESS CLEAN_BASE CLEAN_WHY CLEAN_OID CLEAN_KEEP
  local days="" prot common main here defname prs board mins cutoff why path branch flags sha ref rec n st oid at d f first=true
  local -A seen=()
  while [ $# -gt 0 ]; do
    case $1 in
      --dry-run) CLEAN_DRY=true ;;
      --days)
        [[ ${2:-} =~ ^[1-9][0-9]*$ ]] || die "clean --days needs a positive number"
        days=$2
        shift
        ;;
      *) usage ;;
    esac
    shift
  done
  days=${days:-$(config_get hygiene.days)}
  [[ $days =~ ^[1-9][0-9]*$ ]] || die "hygiene.days must be a positive whole number, not $days"
  common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || die "not inside a git repository"
  main=$(dirname "$common")
  here=$(readlink -f "$(git rev-parse --show-toplevel)")
  CLEAN_SLUG=$(repo_slug)
  CLEAN_BASE=$(default_branch) || CLEAN_BASE=""
  defname=${CLEAN_BASE#origin/}
  prs=$(gh_retry pr list --repo "$CLEAN_SLUG" --state all --limit 1000 \
    --json number,state,headRefName,baseRefName,headRefOid,mergedAt,closedAt,isCrossRepository) ||
    die "cannot read the pull requests from GitHub; nothing was removed"
  CLEAN_PRS=$(jq -c '[.[] | select(.isCrossRepository != true)] | group_by(.headRefName)
    | map({key: .[0].headRefName, value: ((map(select(.state == "OPEN")) | first) // max_by(.number))}) | from_entries' <<<"$prs") ||
    die "GitHub answered something that is not a list of pull requests"
  # Every pull request counts for the bases, fork or not: a branch is a base whoever opened the pull request.
  CLEAN_BASES=$(jq -c 'map({key: .baseRefName, value: .number}) | from_entries' <<<"$prs") || die "GitHub answered something that is not a list of pull requests"
  if prot=$(gh_retry api "repos/$CLEAN_SLUG/branches?protected=true&per_page=100" --paginate --jq '.[].name' 2>/dev/null); then
    CLEAN_PROTECTED=$(jq -Rsc 'split("\n") | map(select(length > 0))' <<<"$prot")
  else
    CLEAN_PROTECTED='[]' CLEAN_PROT_KNOWN=false
    echo "senior-mode: could not read the protected branches; every branch that is not a ticket's (feat, fix, chore) is kept" >&2
  fi
  board=$(board_data false) || die "cannot read the board, so what is In progress is unknown; nothing was removed"
  CLEAN_PROGRESS=$(jq -c '[.items[] | select(.open and .status == "In progress") | .number]' <<<"$board")
  mins=$((days * 1440))
  cutoff=$(iso_time $(($(date +%s) - days * 86400)))
  # A tracking ref of a branch deleted on origin would count its commits as pushed. Read-only for the
  # work tree and the branches, so a dry run does it too.
  if ! git fetch -q --prune origin 2>/dev/null; then
    CLEAN_STALE=true
    echo "senior-mode: could not fetch origin; the tracking branches may be stale, so a branch is kept unless its commits are in the default branch or its pull request" >&2
  fi
  [ "$CLEAN_DRY" = true ] || git worktree prune

  # Worktrees, wherever they are. The first one is the main worktree.
  while IFS=$'\037' read -r path branch flags; do
    if [ "$first" = true ]; then
      first=false
      [ -z "$branch" ] || seen[$branch]=1
      continue
    fi
    [ -n "$branch" ] || continue
    if [ "$(readlink -f "$path")" = "$here" ]; then
      seen[$branch]=1
      continue
    fi
    clean_state "$branch"
    seen[$branch]=1
    if [ -n "$CLEAN_KEEP" ]; then
      echo "kept worktree $path ($branch): $CLEAN_KEEP"
      CLEAN_KEPT=$((CLEAN_KEPT + 1))
      continue
    fi
    [ -n "$CLEAN_WHY" ] || continue
    why=""
    if [ -d "$path" ] && [ -n "$(git -C "$path" status --porcelain 2>/dev/null)" ]; then
      why="uncommitted changes"
    elif [[ $flags == *locked* ]]; then
      why="locked"
    else
      why=$(clean_unpushed "$branch" "$CLEAN_OID")
    fi
    if [ -n "$why" ]; then
      echo "kept worktree $path ($branch): $why"
      CLEAN_KEPT=$((CLEAN_KEPT + 1))
      continue
    fi
    if [ "$CLEAN_DRY" = true ] || [ ! -d "$path" ]; then
      clean_act "worktree $path ($branch, $CLEAN_WHY)" true
    else
      clean_act "worktree $path ($branch, $CLEAN_WHY)" git worktree remove "$path"
    fi
    [ -z "$(git worktree list --porcelain | awk -v p="$path" '$0 == "worktree " p')" ] || [ "$CLEAN_DRY" = true ] || continue
    clean_act "branch $branch ($CLEAN_WHY)" git branch -D "$branch"
  done < <(git worktree list --porcelain | awk '/^worktree /{if (p != "") print p "\037" b "\037" f; p = substr($0, 10); b = ""; f = ""}
    /^branch refs\/heads\//{b = substr($0, 19)} /^(locked|prunable)/{f = f $1 " "} END{if (p != "") print p "\037" b "\037" f}')

  # Local branches with no worktree.
  while IFS= read -r branch; do
    [ -z "${seen[$branch]:-}" ] && [ "$branch" != "$defname" ] || continue
    clean_state "$branch"
    if [ -n "$CLEAN_KEEP" ]; then
      echo "kept branch $branch: $CLEAN_KEEP"
      CLEAN_KEPT=$((CLEAN_KEPT + 1))
      continue
    fi
    [ -n "$CLEAN_WHY" ] || continue
    why=$(clean_unpushed "$branch" "$CLEAN_OID")
    if [ -n "$why" ]; then
      echo "kept branch $branch: $why"
      CLEAN_KEPT=$((CLEAN_KEPT + 1))
      continue
    fi
    clean_act "branch $branch ($CLEAN_WHY)" git branch -D "$branch"
  done < <(git for-each-ref --format='%(refname:short)' refs/heads)

  # Remote branches whose pull request was merged or closed more than N days ago, and whose tip is still
  # the head of that pull request.
  if f=$(git ls-remote --heads origin 2>/dev/null); then
    while read -r sha ref; do
      branch=${ref#refs/heads/}
      [ "$branch" != "$defname" ] || continue
      rec=$(jq -r --arg b "$branch" '.[$b] // empty | select(.state != "OPEN")
        | "\(.number) \(.state) \(.headRefOid) \(.mergedAt // .closedAt // "")"' <<<"$CLEAN_PRS")
      [ -n "$rec" ] || continue
      read -r n st oid at <<<"$rec"
      [[ $at < $cutoff ]] || continue
      why=$(clean_guard "$branch")
      if [ -n "$why" ]; then
        echo "kept remote branch $branch: $why"
        CLEAN_KEPT=$((CLEAN_KEPT + 1))
        continue
      fi
      if [ "$sha" != "$oid" ]; then
        echo "kept remote branch $branch: it has commits its pull request #$n does not"
        CLEAN_KEPT=$((CLEAN_KEPT + 1))
        continue
      fi
      clean_act "remote branch $branch (pull request #$n ${st,,} ${at%%T*})" \
        git push -q --force-with-lease="refs/heads/$branch:$sha" origin ":refs/heads/$branch"
    done <<<"$f"
  else
    echo "senior-mode: could not list the branches of origin; remote branches left alone" >&2
  fi

  # Files of the runs. A directory counts as old when nothing in it changed for N days.
  for d in "$common"/senior-mode/runs/*/; do
    d=${d%/}
    [ -d "$d" ] && [ ! -L "$d" ] && [ -z "$(find "$d" -mmin "-$mins" -print -quit)" ] || continue
    clean_act "run $d (no activity for $days days)" rm -rf "$d"
  done
  for f in "$common/senior-mode/probe" "$common/senior-mode/probe.log"; do
    [ -f "$f" ] && [ ! -L "$f" ] && [ -z "$(find "$f" -mmin "-$mins" -print -quit)" ] || continue
    clean_act "file $f (older than $days days)" rm -f "$f"
  done

  if [ "$CLEAN_DRY" = true ]; then
    echo "would run: git worktree prune"
    echo "clean (dry run): $CLEAN_REMOVED to remove, $CLEAN_KEPT kept; nothing changed"
  else
    git worktree prune
    echo "clean: $CLEAN_REMOVED removed, $CLEAN_KEPT kept"
  fi
  return "$CLEAN_RC"
}
