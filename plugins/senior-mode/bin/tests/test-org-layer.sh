#!/usr/bin/env bash
# Tests for the organization layer read from the organization's .github repository (#400). Offline: gh is a stub keeping
# the commits and files of `<owner>/.github` in $FIX (ref-<name> holds a commit, files/<sha>/<path> its files); the cache
# is a temporary XDG_CACHE_HOME. The stub answers a conditional read (If-None-Match) with a 304, as GitHub does.
set -u
cli=$(cd "$(dirname "$0")/.." && pwd)/senior-mode
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

mkdir -p "$work/stub"
cat >"$work/stub/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$GH_LOG"
[ -z "${DOWN:-}" ] || { echo "gh: HTTP 502" >&2; exit 1; }
args=("$@") inm="" prev=""
for a in "$@"; do [ "$prev" = -H ] && case $a in If-None-Match:*) inm=${a#If-None-Match: } ;; esac; prev=$a; done
case "${args[*]}" in
  "api -i repos/"*/commits/*)
    url=${args[2]}
    owner=$(cut -d/ -f2 <<<"$url") repo=$(cut -d/ -f3 <<<"$url") ref=${url##*/commits/}
    [ -f "$FIX/$owner-$repo" ] || { printf 'HTTP/2.0 404 Not Found\r\n\r\n'; echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    sha=$(cat "$FIX/ref-$ref" 2>/dev/null) || { printf 'HTTP/2.0 404 Not Found\r\n\r\n'; echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    if [ "$inm" = "\"e-$sha\"" ]; then printf 'HTTP/2.0 304 Not Modified\r\n\r\n'; echo "gh: HTTP 304" >&2; exit 1; fi
    printf 'HTTP/2.0 200 OK\r\nEtag: "e-%s"\r\nContent-Type: text/plain\r\n\r\n%s' "$sha" "$sha" ;;
  "api repos/"*/contents/*)
    url=${args[1]}
    sha=${url##*ref=} file=${url#repos/*/*/contents/} file=${file%%\?*}
    [ -f "$FIX/files/$sha/$file" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    base64 <"$FIX/files/$sha/$file" ;;
esac
STUB
chmod +x "$work/stub/gh"
export PATH="$work/stub:$PATH" GH_LOG="$work/gh.log" FIX="$work/fix" SENIOR_MODE_RETRY_DELAY=0
export XDG_CACHE_HOME="$work/cache" HOME="$work/home"
mkdir -p "$FIX/files" "$HOME"

A=1111111111111111111111111111111111111111
B=2222222222222222222222222222222222222222
C=3333333333333333333333333333333333333333

repo="$work/repo"
git init -q "$repo"
git -C "$repo" remote add origin git@github.com:acme/app.git
mkdir -p "$repo/.claude"
run() { (cd "$repo" && "$cli" "$@") >"$work/out" 2>"$work/err"; }
get() { (cd "$repo" && "$cli" config get "$1" 2>"$work/err"); }
calls() { grep -c . "$GH_LOG"; }
# A commit of the organization repository: commit <sha> <config.json text> [<ref>...].
commit() {
  local sha=$1 text=$2
  shift 2
  mkdir -p "$FIX/files/$sha/senior-mode"
  printf '%s\n' "$text" >"$FIX/files/$sha/senior-mode/config.json"
  for r in "$@"; do printf '%s' "$sha" >"$FIX/ref-$r"; done
}
reset() {
  rm -rf "$FIX" "$XDG_CACHE_HOME" "$repo/.claude/senior-mode.json" "$repo/.git/senior-mode"
  mkdir -p "$FIX/files"
  touch "$FIX/acme-.github"
  : >"$GH_LOG"
  unset DOWN
}
# Makes the cache of the organization layer old, so that the next read asks GitHub again.
age_cache() { for f in "$XDG_CACHE_HOME"/senior-mode/org/*/state-*.json; do jq -c '.checkedAt = 1 | .failedAt = 0' "$f" >"$f.t" && mv "$f.t" "$f"; done; }

# A: the organization's value applies, explain names the layer and the commit; the repository's value wins and the
# shadowed one is listed.
reset
commit "$A" '{"autonomy": {"parallel": 2}}' HEAD
[ "$(get autonomy.parallel)" = 2 ] || fail "A: the organization value is not read: $(cat "$work/err")"
run config explain autonomy.parallel
{ grep -q '^winner: organization (organization acme/.github/senior-mode@1111111)' "$work/out"; } || fail "A: explain does not name the layer and commit: $(cat "$work/out")"
echo '{"autonomy": {"parallel": 3}}' >"$repo/.claude/senior-mode.json"
[ "$(get autonomy.parallel)" = 3 ] || fail "A: the repository value does not win"
run config explain autonomy.parallel
grep -q 'organization .*2 .*shadowed by repository' "$work/out" || fail "A: the shadowed value is not listed: $(cat "$work/out")"

# B: only the default branch is read, a pull request never; org.ref pinned to a commit reads that commit.
reset
commit "$A" '{"wip": 5}' HEAD
commit "$B" '{"wip": 9}' pr-branch
[ "$(get wip)" = 5 ] || fail "B: the default branch is not read: $(cat "$work/err")"
commit "$C" '{"wip": 7}' v1
echo '{"org": {"ref": "'"$C"'"}}' >"$repo/.claude/senior-mode.json"
printf '%s' "$C" >"$FIX/ref-$C"
[ "$(get wip)" = 7 ] || fail "B: the pinned commit is not read"
grep -q "commits/$C" "$GH_LOG" || fail "B: the pin was not asked for: $(cat "$GH_LOG")"
grep -q 'commits/pr-branch\|pull' "$GH_LOG" && fail "B: a pull request was asked for"

# C: GitHub unreachable. With a cache the cached layer is used and named; with none the layer is empty and nothing fails.
reset
commit "$A" '{"wip": 5}' HEAD
[ "$(get wip)" = 5 ] || fail "C: first read failed"
age_cache
export DOWN=1
[ "$(get wip)" = 5 ] || fail "C: the cached layer is not used: $(cat "$work/err")"
grep -qE '^org layer: cached 1111111, [0-9]+[smhd]$' "$work/err" || fail "C: the cache is not named: $(cat "$work/err")"
reset
export DOWN=1
[ "$(get wip)" = 3 ] || fail "C: no cache: the empty layer does not leave the default: $(cat "$work/err")"
grep -q '^org layer: acme/.github unreachable and no cached copy, empty layer$' "$work/err" || fail "C: no line for the empty layer: $(cat "$work/err")"
unset DOWN

# D: no .github repository, no directory, org.inherit false: nothing changes and nothing fails. A user's own .github applies.
reset
rm -f "$FIX/acme-.github"
[ "$(get wip)" = 3 ] || fail "D: no organization repository changes the config: $(cat "$work/err")"
[ ! -s "$work/err" ] || fail "D: a missing organization repository says something: $(cat "$work/err")"
reset
printf '%s' "$A" >"$FIX/ref-HEAD"
[ "$(get wip)" = 3 ] || fail "D: a missing directory changes the config: $(cat "$work/err")"
[ ! -s "$work/err" ] || fail "D: a missing directory says something: $(cat "$work/err")"
reset
commit "$A" '{"wip": 5}' HEAD
echo '{"org": {"inherit": false}}' >"$repo/.claude/senior-mode.json"
[ "$(get wip)" = 3 ] || fail "D: org.inherit false still reads the organization"
[ "$(calls)" = 0 ] || fail "D: org.inherit false called GitHub: $(cat "$GH_LOG")"
rm "$repo/.claude/senior-mode.json"
git -C "$repo" remote set-url origin https://github.com/jdoe/app.git
touch "$FIX/jdoe-.github"
commit "$A" '{"wip": 6}' HEAD
[ "$(get wip)" = 6 ] || fail "D: <user>/.github does not apply: $(cat "$work/err")"
grep -q 'repos/jdoe/.github/commits/' "$GH_LOG" || fail "D: the user's .github was not read"
git -C "$repo" remote set-url origin git@github.com:acme/app.git

# E: within 10 minutes the second read makes no call; after, one conditional read, and a 304 fetches no file again.
reset
commit "$A" '{"wip": 5, "org": {"inherit": false, "repo": "other"}}' HEAD
get wip >/dev/null
[ "$(calls)" = 2 ] || fail "E: the first read is not one commit read and one file read: $(cat "$GH_LOG")"
get wip >/dev/null
[ "$(calls)" = 2 ] || fail "E: the second read within 10 minutes called GitHub: $(cat "$GH_LOG")"
age_cache
get wip >/dev/null
[ "$(calls)" = 3 ] || fail "E: the later read is not one conditional call: $(cat "$GH_LOG")"
grep -q 'If-None-Match: "e-' "$GH_LOG" || fail "E: the read is not conditional: $(cat "$GH_LOG")"
[ "$(get wip)" = 5 ] || fail "E: a 304 lost the cached layer"
# An org key of the organization's own config.json is ignored.
[ "$(get org.inherit)" = true ] && [ "$(get org.repo)" = .github ] || fail "E: an org key of the organization applies"
commit "$B" '{"wip": 8}' HEAD
age_cache
[ "$(get wip)" = 8 ] || fail "E: a new commit is not read"

# F: the org keys are in the schema.
reset
echo '{"org": {"inherit": true, "repo": ".github", "path": "senior-mode", "ref": "main"}}' >"$repo/.claude/senior-mode.json"
run config validate || fail "F: the org keys are refused: $(cat "$work/out")"
echo '{"org": {"inherit": "no"}}' >"$repo/.claude/senior-mode.json"
run config validate && fail "F: org.inherit \"no\" was accepted"

[ "$failures" -eq 0 ] && echo "org layer: all cases pass"
exit "$failures"
