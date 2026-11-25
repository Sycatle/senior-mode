#!/usr/bin/env bash
# Tests for the lease module (lib/lease.sh, spec 327 section 8, #414): an atomic lease on a git ref. Offline: gh is a stub
# of the REST git database with create-if-absent (POST git/refs) and fast-forward-only (PATCH git/refs, force false) refs,
# and a `Date` header on every answer that is the server's clock ($work/server/now). The local clock is SENIOR_MODE_NOW.
#
# Interface under test (functions of lib/lease.sh, run in the repository, worker name in SENIOR_MODE_WORKER):
#   lease_claim <name>      0 claimed; 1 held (message "held" on stderr, nothing changed); 2 refused, message "clock"
#   lease_renew <name>      0 renewed by the holder; 1 refused (not the holder, or the lease was taken over)
#   lease_takeover <name>   0 taken over; 1 refused (lease live or lost the race)
#   lease_release <name>    0 released by the holder; 1 refused
#   lease_takeovers <name>  prints the number of takeover commits in the ref's history
# <name> is `ticket-12`: the ref is refs/senior-mode/leases/<name>. The lease is a commit with the empty tree whose message
# is JSON {worker, expires, renewed, reason}; serve.leaseTtl defaults to 600, the grace is 30 s.
set -u
here=$(cd "$(dirname "$0")" && pwd)
lib=$here/../lib
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

server=$work/server
mkdir -p "$server/refs" "$server/obj" "$work/stub"
cat >"$work/stub/gh" <<'STUB'
#!/usr/bin/env bash
# gh api for the git database: refs (create-if-absent, fast-forward-only), commits, the empty tree. Locked: one request at a time.
set -u
[ "${1:-}" = api ] || { echo "gh stub: only api" >&2; exit 1; }
shift
method=GET include=0 input="" path="" jqf=""
declare -A f
parents=()
while [ $# -gt 0 ]; do
  case $1 in
    -X | --method) method=$2; shift ;;
    -i | --include) include=1 ;;
    --input) input=$2; shift ;;
    --jq | -q) jqf=$2; shift ;;
    -f | -F | --field | --raw-field)
      k=${2%%=*}; v=${2#*=}
      case $k in parents\[\]) parents+=("$v") ;; *) f[$k]=$v ;; esac
      shift ;;
    -H | --header) shift ;;
    -*) ;;
    *) path=$1 ;;
  esac
  shift
done
if [ -n "$input" ]; then
  body=$(cat)
  for k in ref sha message tree force; do v=$(jq -r --arg k "$k" '.[$k] // empty' <<<"$body"); [ -z "$v" ] || f[$k]=$v; done
  while IFS= read -r p; do [ -z "$p" ] || parents+=("$p"); done < <(jq -r '.parents[]? // empty' <<<"$body")
fi
exec 9>"$GH_SERVER/lock"
flock 9
now=$(cat "$GH_SERVER/now")
echo "$method $path" >>"$GH_SERVER/log"
reply() { # status json
  if [ "$include" = 1 ]; then
    printf 'HTTP/2.0 %s\r\nDate: %s\r\nContent-Type: application/json\r\n\r\n' "$1" "$(LC_ALL=C date -u -d "@$now" '+%a, %d %b %Y %H:%M:%S GMT')"
  fi
  if [ -n "$jqf" ]; then jq -r "$jqf" <<<"$2"; else printf '%s\n' "$2"; fi
  [ "${1%% *}" -lt 400 ] || { [ "$include" = 1 ] || echo "gh: $(jq -r .message <<<"$2") (HTTP ${1%% *})" >&2; exit 1; }
  exit 0
}
refkey() { printf '%s' "$1" | tr '/' '_'; }
is_ancestor() { # ancestor descendant
  local c=$2
  while [ -n "$c" ]; do
    [ "$c" != "$1" ] || return 0
    c=$(jq -r '.parents[0].sha // empty' "$GH_SERVER/obj/$c")
  done
  return 1
}
case "$method $path" in
  "POST repos/"*/git/trees) reply "201 Created" '{"sha":"4b825dc642cb6eb9a060e54bf8d69288fbee4904"}' ;;
  "POST repos/"*/git/commits)
    sha=$(printf '%s' "${f[message]:-}${parents[*]:-}$now$RANDOM$RANDOM" | sha1sum | cut -d' ' -f1)
    jq -n --arg s "$sha" --arg m "${f[message]:-}" --arg t "${f[tree]:-}" '$ARGS.positional as $p | {sha: $s, message: $m, tree: {sha: $t}, parents: [$p[] | {sha: .}]}' --args "${parents[@]:-}" |
      sed 's/{"sha":""}//' >"$GH_SERVER/obj/$sha"
    jq -c '.parents |= map(select(.sha != ""))' "$GH_SERVER/obj/$sha" >"$GH_SERVER/obj/$sha.tmp" && mv "$GH_SERVER/obj/$sha.tmp" "$GH_SERVER/obj/$sha"
    reply "201 Created" "$(cat "$GH_SERVER/obj/$sha")" ;;
  "GET repos/"*/git/commits/*) sha=${path##*/}; [ -e "$GH_SERVER/obj/$sha" ] || reply "404 Not Found" '{"message":"Not Found"}'; reply "200 OK" "$(cat "$GH_SERVER/obj/$sha")" ;;
  "GET repos/"*/git/ref/* | "GET repos/"*/git/refs/*)
    ref=${path#*/git/ref/}; ref=${ref#refs/}; ref=refs/${ref#refs/}
    [ -e "$GH_SERVER/refs/$(refkey "$ref")" ] || reply "404 Not Found" '{"message":"Not Found"}'
    reply "200 OK" "$(jq -n --arg r "$ref" --arg s "$(cat "$GH_SERVER/refs/$(refkey "$ref")")" '{ref: $r, object: {sha: $s, type: "commit"}}')" ;;
  "POST repos/"*/git/refs)
    ref=${f[ref]:-}
    [[ $ref == refs/* ]] || reply "422 Unprocessable Entity" '{"message":"Invalid ref"}'
    [ ! -e "$GH_SERVER/refs/$(refkey "$ref")" ] || reply "422 Unprocessable Entity" '{"message":"Reference already exists"}'
    [ -e "$GH_SERVER/obj/${f[sha]:-}" ] || reply "422 Unprocessable Entity" '{"message":"Object does not exist"}'
    printf '%s' "${f[sha]}" >"$GH_SERVER/refs/$(refkey "$ref")"
    echo "write $ref ${f[sha]}" >>"$GH_SERVER/log"
    reply "201 Created" "$(jq -n --arg r "$ref" --arg s "${f[sha]}" '{ref: $r, object: {sha: $s}}')" ;;
  "PATCH repos/"*/git/refs/*)
    ref=${path#*/git/refs/}; ref=refs/${ref#refs/}
    [ -e "$GH_SERVER/refs/$(refkey "$ref")" ] || reply "422 Unprocessable Entity" '{"message":"Reference does not exist"}'
    [ -e "$GH_SERVER/obj/${f[sha]:-}" ] || reply "422 Unprocessable Entity" '{"message":"Object does not exist"}'
    [ "${f[force]:-false}" = false ] || reply "422 Unprocessable Entity" '{"message":"force is not allowed"}'
    is_ancestor "$(cat "$GH_SERVER/refs/$(refkey "$ref")")" "${f[sha]}" || reply "422 Unprocessable Entity" '{"message":"Update is not a fast forward"}'
    printf '%s' "${f[sha]}" >"$GH_SERVER/refs/$(refkey "$ref")"
    echo "write $ref ${f[sha]}" >>"$GH_SERVER/log"
    reply "200 OK" "$(jq -n --arg r "$ref" --arg s "${f[sha]}" '{ref: $r, object: {sha: $s}}')" ;;
  *) reply "404 Not Found" '{"message":"stub: not implemented"}' ;;
esac
STUB
chmod +x "$work/stub/gh"
export PATH="$work/stub:$PATH" GH_SERVER="$server" SENIOR_MODE_RETRY_DELAY=0

repo=$work/repo
git init -q "$repo"
git -C "$repo" remote add origin https://github.com/acme/app.git
mkdir -p "$repo/.claude"

T0=1800000000
set_server() { echo "$1" >"$server/now"; }
set_server $T0
ref_file=$server/refs/refs_senior-mode_leases_ticket-12
ref_sha() { cat "$ref_file" 2>/dev/null; }
commit_json() { cat "$server/obj/$1"; }
field() { jq -r ".message | fromjson | .$2" "$server/obj/$1"; } # sha field
writes() { grep -c '^write ' "$server/log" 2>/dev/null || echo 0; }

# lease <worker> <local clock> <function> args... : runs a lease function as that worker, the local clock as given.
lease() {
  local w=$1 now=$2
  shift 2
  (cd "$repo" && SENIOR_MODE_WORKER=$w SENIOR_MODE_NOW=$now bash -c '. "$1/common.sh"; . "$1/lease.sh"; shift; "$@"' _ "$lib" "$@") 2>"$work/err"
}

[ -r "$lib/lease.sh" ] || fail "lib/lease.sh does not exist"

# 1. Two workers claim a ref that does not exist at the same moment: one wins, the other reads that it is held.
lease A $T0 lease_claim ticket-12 >"$work/outA" 2>&1 &
pa=$!
lease B $T0 lease_claim ticket-12 >"$work/outB" 2>&1 &
pb=$!
wait $pa; ra=$?
wait $pb; rb=$?
[ "$(((ra == 0) + (rb == 0)))" -eq 1 ] || fail "race: not exactly one claim succeeded (A=$ra B=$rb)"
loser=B loser_rc=$rb winner=A
[ "$rb" -eq 0 ] && { loser=A loser_rc=$ra winner=B; }
[ "$loser_rc" -eq 1 ] || fail "race: the loser exited $loser_rc, wanted 1 (held)"
grep -qi held "$work/out$loser" || fail "race: the loser does not say the lease is held: $(cat "$work/out$loser")"
[ -n "$(ref_sha)" ] || fail "race: no ref was created"
[ "$(writes)" -eq 1 ] || fail "race: $(writes) ref writes, wanted 1 (the loser makes no change)"
claim1=$(ref_sha)
[ "$(field "$claim1" worker)" = "$winner" ] || fail "race: the ref is not the winner's: $(commit_json "$claim1")"
[ "$(field "$claim1" reason)" = claim ] || fail "race: reason is not claim"
[ "$(field "$claim1" expires)" -eq $((T0 + 600)) ] || fail "race: expires is not server time + 600: $(field "$claim1" expires)"
[ "$(jq -r '.tree.sha' "$server/obj/$claim1")" = 4b825dc642cb6eb9a060e54bf8d69288fbee4904 ] || fail "claim: the commit does not have the empty tree"
rm -f "$ref_file" "$server/log" # start the next cases from a known holder

# 2. Renew: the holder moves expires forward in server time by fast-forward; another worker is refused.
lease A $T0 lease_claim ticket-12 || fail "renew: A could not claim ($(cat "$work/err"))"
c1=$(ref_sha)
set_server $((T0 + 200))
lease B $((T0 + 200)) lease_renew ticket-12 && fail "renew: B renewed A's lease"
[ "$(ref_sha)" = "$c1" ] || fail "renew: a refused renewal moved the ref"
lease B $((T0 + 200)) lease_claim ticket-12 && fail "renew: B claimed a held lease"
[ "$(ref_sha)" = "$c1" ] || fail "renew: a refused claim moved the ref"
lease A $((T0 + 200)) lease_renew ticket-12 || fail "renew: the holder was refused ($(cat "$work/err"))"
c2=$(ref_sha)
[ "$c2" != "$c1" ] || fail "renew: the ref did not move"
[ "$(jq -r '.parents[0].sha' "$server/obj/$c2")" = "$c1" ] || fail "renew: the new commit is not a child of the old one (not a fast-forward)"
[ "$(field "$c2" expires)" -eq $((T0 + 800)) ] || fail "renew: expires $(field "$c2" expires), wanted $((T0 + 800))"
[ "$(field "$c2" renewed)" -eq $((T0 + 200)) ] || fail "renew: renewed $(field "$c2" renewed), wanted $((T0 + 200))"
[ "$(field "$c2" reason)" = renew ] || fail "renew: reason is not renew"
[ "$(field "$c2" worker)" = A ] || fail "renew: worker is not A"

# 3. Takeover: only once expires + 30 s is past in server time; one takeover wins; the old holder is refused after it.
set_server $((T0 + 800 + 30))
lease B $((T0 + 830)) lease_takeover ticket-12 && fail "takeover: at expires + grace exactly the lease is still live"
set_server $((T0 + 800 + 31))
lease B $((T0 + 831)) lease_takeover ticket-12 >/dev/null 2>&1 &
pb=$!
lease C $((T0 + 831)) lease_takeover ticket-12 >/dev/null 2>&1 &
pc=$!
wait $pb; rb=$?
wait $pc; rc=$?
[ "$(((rb == 0) + (rc == 0)))" -eq 1 ] || fail "takeover: not exactly one takeover succeeded (B=$rb C=$rc)"
t1=$(ref_sha)
[ "$(jq -r '.parents[0].sha' "$server/obj/$t1")" = "$c2" ] || fail "takeover: not a fast-forward from the expired lease"
[ "$(field "$t1" reason)" = takeover ] || fail "takeover: reason is not takeover"
new_holder=$(field "$t1" worker)
case $new_holder in B | C) ;; *) fail "takeover: holder is $new_holder" ;; esac
[ "$(field "$t1" expires)" -eq $((T0 + 831 + 600)) ] || fail "takeover: expires $(field "$t1" expires), wanted $((T0 + 1431))"
lease A $((T0 + 831)) lease_renew ticket-12 && fail "takeover: the old holder renewed after the takeover"
[ "$(ref_sha)" = "$t1" ] || fail "takeover: the refused renewal moved the ref"
[ "$(lease A $((T0 + 831)) lease_takeovers ticket-12)" = 1 ] || fail "takeover: counted $(lease A $((T0 + 831)) lease_takeovers ticket-12) takeovers in the history, wanted 1"
lease A $((T0 + 831)) lease_takeover ticket-12 && fail "takeover: a live lease was taken over"

# 4. Clocks: expiry is decided in server time. A local clock 90 s off gives the same result as a correct one.
rm -f "$ref_file" "$server/log"
for skew in 90 -90; do
  rm -f "$ref_file"
  set_server $T0
  lease A $((T0 + skew)) lease_claim ticket-12 || fail "clock $skew: claim refused ($(cat "$work/err"))"
  [ "$(field "$(ref_sha)" expires)" -eq $((T0 + 600)) ] || fail "clock $skew: expires is not in server time: $(field "$(ref_sha)" expires)"
  # Live in server time (630 is the limit), whatever the local clock says.
  set_server $((T0 + 630))
  lease B $((T0 + 630 + skew)) lease_takeover ticket-12 && fail "clock $skew: a live lease was taken over"
  # Expired in server time.
  set_server $((T0 + 631))
  lease B $((T0 + 631 + skew)) lease_takeover ticket-12 || fail "clock $skew: an expired lease was not taken over ($(cat "$work/err"))"
done
# A skew over a quarter of the TTL (150 s): nothing is claimed and the reason is the clock.
for skew in 160 -160; do
  rm -f "$ref_file"
  set_server $T0
  lease A $((T0 + skew)) lease_claim ticket-12 && fail "clock $skew: a claim was accepted with a skew over a quarter of the TTL"
  grep -qi clock "$work/err" || fail "clock $skew: the refusal does not say clock: $(cat "$work/err")"
  [ -z "$(ref_sha)" ] || fail "clock $skew: a ref was created"
done

# 5. Release: the ref ends released and a new claim takes it at once, by fast-forward.
rm -f "$ref_file"
set_server $T0
lease A $T0 lease_claim ticket-12 || fail "release: claim failed"
r0=$(ref_sha)
lease B $T0 lease_release ticket-12 && fail "release: B released A's lease"
[ "$(ref_sha)" = "$r0" ] || fail "release: a refused release moved the ref"
lease A $T0 lease_release ticket-12 || fail "release: the holder was refused ($(cat "$work/err"))"
r1=$(ref_sha)
[ -n "$r1" ] || fail "release: the ref is gone"
[ "$(field "$r1" reason)" = release ] || fail "release: reason is not release"
[ "$(jq -r '.parents[0].sha' "$server/obj/$r1")" = "$r0" ] || fail "release: not a fast-forward"
lease A $T0 lease_renew ticket-12 && fail "release: the releaser renewed a released lease"
lease B $T0 lease_claim ticket-12 || fail "release: a new claim was not accepted at once ($(cat "$work/err"))"
r2=$(ref_sha)
[ "$(field "$r2" worker)" = B ] && [ "$(field "$r2" reason)" = claim ] || fail "release: the new claim is not B's: $(commit_json "$r2")"
[ "$(jq -r '.parents[0].sha' "$server/obj/$r2")" = "$r1" ] || fail "release: the new claim is not a child of the release"

exit "$failures"
