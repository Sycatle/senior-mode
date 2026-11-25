# shellcheck shell=bash
# An atomic lease on a git ref (spec 327, section 8): refs/senior-mode/leases/<name> is a chain of commits with the empty
# tree whose message is JSON {worker, expires, renewed, reason}. Claim creates the ref (POST git/refs fails if it exists);
# renew, takeover and release add a child commit by fast-forward (PATCH git/refs with force false), so racing workers get
# one winner and the history is the audit trail. Expiry is decided in GitHub server time (the `Date` header of the answers).
LEASE_GRACE=30
LEASE_EMPTY_TREE=4b825dc642cb6eb9a060e54bf8d69288fbee4904

lease_ttl() {
  local v=${SENIOR_MODE_LEASE_TTL:-}
  [ -n "$v" ] || { declare -F config_get >/dev/null && v=$(config_get serve.leaseTtl 2>/dev/null); } || true
  case ${v:-} in '' | *[!0-9]*) v=600 ;; esac
  echo "$v"
}

lease_worker() {
  local w=${SENIOR_MODE_WORKER:-}
  [ -n "$w" ] || { declare -F config_get >/dev/null && w=$(config_get serve.worker 2>/dev/null); } || true
  echo "${w:-$(hostname)}"
}

# One API call with the response headers: sets LEASE_STATUS, LEASE_BODY and LEASE_DATE (server epoch). The body of a
# failed call is kept, as gh_retry would drop it. Calls: lease_api <method> <path> [<json body>].
lease_api() {
  local method=$1 path=$2 body=${3:-} out rc attempt head
  for attempt in 1 2 3; do
    rc=0
    if [ -n "$body" ]; then
      out=$(gh_bound api -i -X "$method" "$path" --input - <<<"$body" 2>/dev/null) || rc=$?
    else
      out=$(gh_bound api -i -X "$method" "$path" 2>/dev/null) || rc=$?
    fi
    out=${out//$'\r'/}
    head=${out%%$'\n\n'*}
    LEASE_BODY=${out#*$'\n\n'}
    LEASE_STATUS=$(sed -n '1s/^HTTP[^ ]* \([0-9]*\).*/\1/p' <<<"$head")
    LEASE_DATE=$(sed -n 's/^[Dd]ate: *//p' <<<"$head" | head -n1)
    [ -z "$LEASE_DATE" ] || LEASE_DATE=$(date -u -d "$LEASE_DATE" +%s 2>/dev/null) || LEASE_DATE=""
    case ${LEASE_STATUS:-} in 5??) sleep $((attempt * ${SENIOR_MODE_RETRY_DELAY:-1})) ;; *) break ;; esac
  done
  [ -n "${LEASE_STATUS:-}" ]
}

lease_ok() { case ${LEASE_STATUS:-} in 2??) return 0 ;; *) return 1 ;; esac; }

lease_local_now() { echo "${SENIOR_MODE_NOW:-$(date +%s)}"; }

# Reads the lease <name>: sets LEASE_SHA, LEASE_JSON and LEASE_NOW (server time). 0 read; 1 no such ref; 2 GitHub did not
# answer; 3 the local clock is off from the server by more than a quarter of the TTL ("clock" on stderr).
lease_read() {
  local ref=senior-mode/leases/$1 offset
  LEASE_SHA="" LEASE_JSON="" LEASE_SLUG=$(repo_slug)
  lease_api GET "repos/$LEASE_SLUG/git/ref/$ref" || { echo "lease: GitHub did not answer" >&2; return 2; }
  [ -n "$LEASE_DATE" ] || { echo "lease: no Date header in the answer" >&2; return 2; }
  offset=$((LEASE_DATE - $(lease_local_now)))
  LEASE_NOW=$LEASE_DATE
  if [ "${offset#-}" -gt $(($(lease_ttl) / 4)) ]; then
    echo "lease: clock is ${offset}s off from GitHub; nothing is claimed (clock)" >&2
    return 3
  fi
  [ "$LEASE_STATUS" != 404 ] || return 1
  lease_ok || { echo "lease: HTTP $LEASE_STATUS reading $ref" >&2; return 2; }
  LEASE_SHA=$(jq -r '.object.sha' <<<"$LEASE_BODY")
  lease_api GET "repos/$LEASE_SLUG/git/commits/$LEASE_SHA" && lease_ok || { echo "lease: cannot read the lease commit" >&2; return 2; }
  LEASE_JSON=$(jq -r '.message' <<<"$LEASE_BODY")
  jq -e . >/dev/null 2>&1 <<<"$LEASE_JSON" || { echo "lease: $ref is not a lease" >&2; return 2; }
}

# A lease commit with the empty tree: prints its sha. lease_commit <reason> <parent sha or empty>.
lease_commit() {
  local reason=$1 parent=$2 msg parents
  msg=$(jq -nc --arg w "$(lease_worker)" --argjson e "$((LEASE_NOW + $(lease_ttl)))" --argjson r "$LEASE_NOW" --arg why "$reason" \
    '{worker: $w, expires: $e, renewed: $r, reason: $why}')
  [ "$reason" != release ] || msg=$(jq -c --argjson n "$LEASE_NOW" '.expires = $n' <<<"$msg")
  lease_api POST "repos/$LEASE_SLUG/git/trees" '{"tree":[]}' && lease_ok || return 1
  parents=$(jq -nc --arg p "$parent" 'if $p == "" then [] else [$p] end')
  lease_api POST "repos/$LEASE_SLUG/git/commits" \
    "$(jq -nc --arg m "$msg" --arg t "$LEASE_EMPTY_TREE" --argjson p "$parents" '{message: $m, tree: $t, parents: $p}')" && lease_ok || return 1
  jq -r '.sha' <<<"$LEASE_BODY"
}

# Moves the ref to a child commit of the current one: 0 moved, 1 the fast-forward was refused or failed.
lease_advance() {
  local sha
  sha=$(lease_commit "$2" "$LEASE_SHA") || return 1
  lease_api PATCH "repos/$LEASE_SLUG/git/refs/senior-mode/leases/$1" "$(jq -nc --arg s "$sha" '{sha: $s, force: false}')" && lease_ok
}

lease_field() { jq -r ".$1" <<<"$LEASE_JSON"; }

lease_held_by_me() {
  [ "$(lease_field worker)" = "$(lease_worker)" ] && [ "$(lease_field reason)" != release ]
}

lease_expired() { [ "$LEASE_NOW" -gt $(($(lease_field expires) + LEASE_GRACE)) ]; }

# Claims <name>: 0 claimed; 1 held by a live or unreleased lease (nothing changed); 2 refused, the local clock is off.
lease_claim() {
  local name=$1 rc=0 sha
  lease_read "$name" || rc=$?
  case $rc in
    0)
      if [ "$(lease_field reason)" != release ]; then echo "lease $name: held by $(lease_field worker)"; return 1; fi
      lease_advance "$name" claim || { echo "lease $name: held (lost the race)"; return 1; } ;;
    1)
      sha=$(lease_commit claim "") || { echo "lease $name: cannot create the commit" >&2; return 1; }
      lease_api POST "repos/$LEASE_SLUG/git/refs" "$(jq -nc --arg r "refs/senior-mode/leases/$name" --arg s "$sha" '{ref: $r, sha: $s}')" && lease_ok ||
        { echo "lease $name: held (lost the race)"; return 1; } ;;
    3) return 2 ;;
    *) return 1 ;;
  esac
}

# Renews <name> for its holder: 0 renewed; 1 refused (not the holder, released, taken over, or the API failed).
lease_renew() {
  local rc=0
  lease_read "$1" || rc=$?
  [ "$rc" -eq 0 ] || { [ "$rc" -eq 3 ] && return 2; return 1; }
  lease_held_by_me || { echo "lease $1: not held by $(lease_worker)" >&2; return 1; }
  lease_advance "$1" renew || { echo "lease $1: renewal refused" >&2; return 1; }
}

# Takes over <name> once expires plus the grace is past in server time: 0 taken; 1 live, released or lost the race.
lease_takeover() {
  local rc=0
  lease_read "$1" || rc=$?
  [ "$rc" -eq 0 ] || { [ "$rc" -eq 3 ] && return 2; return 1; }
  [ "$(lease_field reason)" != release ] || { echo "lease $1: released, claim it" >&2; return 1; }
  lease_expired || { echo "lease $1: still held by $(lease_field worker)" >&2; return 1; }
  lease_advance "$1" takeover || { echo "lease $1: takeover lost the race" >&2; return 1; }
}

# Releases <name> for its holder: the ref stays, in a released state a claim takes at once.
lease_release() {
  local rc=0
  lease_read "$1" || rc=$?
  [ "$rc" -eq 0 ] || { [ "$rc" -eq 3 ] && return 2; return 1; }
  lease_held_by_me || { echo "lease $1: not held by $(lease_worker)" >&2; return 1; }
  lease_advance "$1" release || { echo "lease $1: release refused" >&2; return 1; }
}

# The number of takeover commits in the history of <name>.
lease_takeovers() {
  local sha n=0
  lease_read "$1" || [ "$LEASE_SHA" ] || { echo 0; return 0; }
  sha=$LEASE_SHA
  while [ -n "$sha" ]; do
    lease_api GET "repos/$LEASE_SLUG/git/commits/$sha" && lease_ok || break
    [ "$(jq -r '.message | fromjson | .reason' <<<"$LEASE_BODY")" != takeover ] || n=$((n + 1))
    sha=$(jq -r '.parents[0].sha // empty' <<<"$LEASE_BODY")
  done
  echo "$n"
}
