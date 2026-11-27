#!/usr/bin/env bash
# Tests for the dependency check of `senior-mode check` (#302): the dependencies a branch adds to its manifests,
# looked up on their registries. Offline: curl is a stub answering from $FIX/<url with / as _> files (first line
# the HTTP code, then the body); a URL with no file fails as an unreachable host does.
set -u
cli=$(cd "$(dirname "$0")/.." && pwd)/senior-mode
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

mkdir -p "$work/stub" "$work/fix"
cat >"$work/stub/curl" <<'STUB'
#!/usr/bin/env bash
out="" url=""
while [ $# -gt 0 ]; do
  case $1 in
    -o) out=$2; shift ;;
    -w | -A | --max-time) shift ;;
    -*) ;;
    *) url=$1 ;;
  esac
  shift
done
echo "$url" >>"$CURL_LOG"
f=$FIX/$(printf %s "$url" | tr -c 'A-Za-z0-9.-' '_')
[ -f "$f" ] || { echo "curl: (6) Could not resolve host" >&2; exit 6; }
tail -n +2 "$f" >"$out"
head -n 1 "$f" | tr -d '\n'
STUB
chmod +x "$work/stub/curl"
export PATH="$work/stub:$PATH" FIX="$work/fix" CURL_LOG="$work/curl.log"

# reg <url> <code> [<body>]: what the registry answers at that URL.
reg() { printf '%s\n%s\n' "$2" "${3:-}" >"$FIX/$(printf %s "$1" | tr -c 'A-Za-z0-9.-' '_')"; }
# ago <days>: an ISO time that many days ago, with milliseconds as npm gives it.
ago() { date -u -d "@$(($(date +%s) - $1 * 86400))" +%Y-%m-%dT%H:%M:%S.000Z; }
npm() { # npm <name> <age days> <weekly downloads>
  reg "https://registry.npmjs.org/${1/\//%2F}" 200 "{\"time\": {\"created\": \"$(ago "$2")\"}}"
  reg "https://api.npmjs.org/downloads/point/last-week/$1" 200 "{\"downloads\": $3}"
}
pypi() {
  reg "https://pypi.org/pypi/$1/json" 200 "{\"releases\": {\"1.0\": [{\"upload_time_iso_8601\": \"$(ago "$2")\"}], \"0.1\": []}}"
  reg "https://pypistats.org/api/packages/$1/recent" 200 "{\"data\": {\"last_week\": $3}}"
}
crate() { reg "https://crates.io/api/v1/crates/$1" 200 "{\"crate\": {\"created_at\": \"$(ago "$2" | sed 's/Z$/+00:00/')\", \"recent_downloads\": $3}}"; }

git_() { git -C "$repo" -c user.name=t -c user.email=t@t "$@"; }
# A run starts with no verdict kept (#827); crun keeps what an earlier one left.
run() { rm -rf "$repo/.git/senior-mode/scan-cache"; crun "$@"; }
crun() { : >"$CURL_LOG"; (cd "$repo" && "$cli" "$@") >"$work/out" 2>&1; }
has() { grep -qF -- "$1" "$work/out" || fail "$2: no '$1' in: $(cat "$work/out")"; }

repo="$work/repo"
git init -q -b main "$repo"
mkdir -p "$repo/.claude"
echo '{"checks":[{"name":"lint","run":"true"}]}' >"$repo/.claude/senior-mode.json"
echo '{"name": "app", "dependencies": {"lodash": "^4"}}' >"$repo/package.json"
# Installed, so that check does not stop at missing dependencies.
echo node_modules >"$repo/.gitignore"
mkdir -p "$repo/node_modules"
git_ add -A
git_ commit -q -m "chore: base"
git_ checkout -q -b feat/1-deps

# Nothing added: nothing looked up.
run deps || fail "no new dependency: fails: $(cat "$work/out")"
has "skipped: no new dependency" "no new dependency"
[ ! -s "$CURL_LOG" ] || fail "no new dependency: a registry was asked: $(cat "$CURL_LOG")"

# npm: a missing, a young and an unused package fail; a typo of a popular one warns; an old dependency, a local
# one and a version bump are not looked up; an alias is looked up under its real name.
cat >"$repo/package.json" <<'EOF'
{"name": "app", "dependencies": {"lodash": "^4.1", "expresss": "^1", "ghost-pkg": "1", "brand-new-pkg": "1", "@acme/tiny": "1",
  "my-alias": "npm:left-pad@1", "local": "file:../local"}, "devDependencies": {"vitest": "^2"}}
EOF
git_ commit -qam "feat: deps"
npm expresss 400 90000
npm brand-new-pkg 5 900
npm @acme/tiny 400 3
npm left-pad 3000 100000
npm vitest 900 5000000
reg https://registry.npmjs.org/ghost-pkg 404 '{"error": "Not found"}'
run deps && fail "npm: bad dependencies pass"
has "npm ghost-pkg: not on the registry" "missing"
has "npm brand-new-pkg: first published 5 days ago, under security.minPackageAgeDays (30)" "young"
has "npm @acme/tiny: 3 downloads last week, under security.minWeeklyDownloads (50)" "unused"
has "warning: npm expresss: one or two letters from the popular express" "typo"
grep -q "left-pad\|vitest" "$work/out" && fail "npm: a sound dependency is reported: $(cat "$work/out")"
grep -q "registry.npmjs.org/@acme%2Ftiny" "$CURL_LOG" || fail "npm: a scoped name is not escaped: $(cat "$CURL_LOG")"
grep -q "lodash\|local\|my-alias" "$CURL_LOG" && fail "npm: an old, local or alias name was looked up: $(cat "$CURL_LOG")"

# In check: its own line, failed, with the reasons.
run check && fail "check passes with bad dependencies"
grep -q "^FAIL  new dependencies ([0-9.]*s)$" "$work/out" || fail "check: not reported: $(cat "$work/out")"
has "npm ghost-pkg: not on the registry" "check"

# The thresholds come from the config.
jq '.security = {"minPackageAgeDays": 3, "minWeeklyDownloads": 2}' "$repo/.claude/senior-mode.json" >"$work/c" && mv "$work/c" "$repo/.claude/senior-mode.json"
reg https://registry.npmjs.org/ghost-pkg 200 "{\"time\": {\"created\": \"$(ago 900)\"}}"
reg https://api.npmjs.org/downloads/point/last-week/ghost-pkg 200 '{"downloads": 70}'
run deps || fail "config: lower thresholds still fail: $(cat "$work/out")"
has "warning: npm expresss" "config: the warning stays"
jq '.security.minPackageAgeDays = 0' "$repo/.claude/senior-mode.json" >"$work/c" && mv "$work/c" "$repo/.claude/senior-mode.json"
run deps && fail "config: an age of 0 is accepted"
has "minPackageAgeDays must be a whole number of days from 1" "config: age 0"
echo '{"checks":[{"name":"lint","run":"true"}]}' >"$repo/.claude/senior-mode.json"

# Offline: nothing answers, so nothing is passed as checked; one registry down leaves its packages unchecked.
rm -f "$FIX"/*
run deps || fail "offline: fails: $(cat "$work/out")"
grep -q "^skipped: no registry answered, so the new dependencies were not checked: .*npm ghost-pkg" "$work/out" ||
  fail "offline: not said: $(cat "$work/out")"
run check || fail "offline: check fails: $(cat "$work/out")"
grep -q "^skip  new dependencies: no registry answered" "$work/out" || fail "offline: check shows no skip: $(cat "$work/out")"
npm expresss 400 90000
npm brand-new-pkg 400 900
npm @acme/tiny 400 3000
npm left-pad 3000 100000
npm vitest 900 5000000
run deps || fail "half offline: fails: $(cat "$work/out")"
has "warning: not checked, the registry did not answer: npm ghost-pkg" "half offline"

# PyPI, crates.io and Go: names read from requirements, pyproject (PEP 621 and Poetry), Cargo.toml and go.mod.
git_ checkout -q main
git_ checkout -q -b feat/2-more
printf 'Requests==2.31  # http\n-r other.txt\ngit+https://example.com/x.git\nflask_Login>=0.6\n' >"$repo/requirements.txt"
cat >"$repo/pyproject.toml" <<'EOF'
[project]
name = "app"
dependencies = [
  "numpyy>=1",
  "rich",
]

[tool.poetry.dependencies]
python = "^3.11"
pendulum = "^3"
mylib = { path = "../mylib" }
EOF
cat >"$repo/Cargo.toml" <<'EOF'
[package]
name = "app"

[dependencies]
serde = { version = "1", features = ["derive"] }
local = { path = "../local" }
renamed = { package = "rand", version = "0.8" }
shared.workspace = true

[dependencies.tokio]
version = "1"

[target.'cfg(unix)'.dev-dependencies]
nix = "0.27"
EOF
cat >"$repo/go.mod" <<'EOF'
module example.com/app

go 1.22

require github.com/gin-gonic/gin v1.9.0

require (
	github.com/BurntSushi/toml v1.3.2
	golang.org/x/text v0.14.0 // indirect
)
EOF
git_ add -A
git_ commit -qm "feat: more deps"
for p in requests flask-login numpyy rich pendulum; do pypi "$p" 900 100000; done
for c in serde rand tokio nix; do crate "$c" 900 1300000; done
reg https://proxy.golang.org/github.com/gin-gonic/gin/@v/list 200 "$(printf 'v1.9.0\nv1.10.0\nv1.1.0')"
reg https://proxy.golang.org/github.com/gin-gonic/gin/@v/v1.1.0.info 200 "{\"Time\": \"$(ago 2000 | sed 's/\.000//')\"}"
reg https://proxy.golang.org/github.com/!burnt!sushi/toml/@v/list 200 ""
reg https://proxy.golang.org/github.com/!burnt!sushi/toml/@latest 200 "{\"Time\": \"$(ago 3)\"}"
run deps && fail "other registries: a young Go module passes"
has "go github.com/BurntSushi/toml: first published 3 days ago" "go: young"
has "warning: pypi numpyy: one or two letters from the popular numpy" "pypi: typo"
want="pypi.org/pypi/requests/json pypi.org/pypi/flask-login/json pypi.org/pypi/numpyy/json pypi.org/pypi/rich/json pypi.org/pypi/pendulum/json
crates.io/api/v1/crates/serde crates.io/api/v1/crates/rand crates.io/api/v1/crates/tokio crates.io/api/v1/crates/nix"
for u in $want; do grep -q "$u" "$CURL_LOG" || fail "not looked up: $u: $(cat "$CURL_LOG")"; done
grep -qE "other|example.com|mylib|python|/local|shared|golang.org/x/text" "$CURL_LOG" &&
  fail "a local, indirect or non-registry dependency was looked up: $(cat "$CURL_LOG")"
[ "$(grep -c . "$work/out")" -eq 3 ] || fail "other registries: more findings than expected: $(cat "$work/out")"

# The lookup is kept 24 h (#827): the same dependencies on the same lockfiles are not looked up again, a changed
# lockfile, other dependencies or an older verdict are, and a failure, or a registry that did not answer, is never kept.
git_ checkout -q main
git_ checkout -q -b feat/3-cache
echo '{"name": "app", "dependencies": {"lodash": "^4", "left-pad": "1"}}' >"$repo/package.json"
echo '{"lockfileVersion": 3}' >"$repo/package-lock.json"
git_ add -A
git_ commit -qm "feat: left-pad"
rm -f "$FIX"/*
run deps
crun deps
grep -q "left-pad" "$CURL_LOG" || fail "cache: an unanswered lookup was kept: $(cat "$CURL_LOG")"
npm left-pad 3000 100000
run deps || fail "cache: first lookup fails: $(cat "$work/out")"
grep -q "left-pad" "$CURL_LOG" || fail "cache: the first lookup did not ask the registry"
rm -f "$FIX"/*
crun deps || fail "cache: the same lookup fails: $(cat "$work/out")"
[ ! -s "$CURL_LOG" ] || fail "cache: a registry was asked for a lookup of an hour ago: $(cat "$CURL_LOG")"
has "skipped: looked up clean 0 h ago, same lockfiles and dependencies" "cache: said"
crun check || fail "cache: check fails: $(cat "$work/out")"
grep -q "^skip  new dependencies: looked up clean" "$work/out" || fail "cache: check shows no skip: $(cat "$work/out")"
[ ! -s "$CURL_LOG" ] || fail "cache: check asked a registry: $(cat "$CURL_LOG")"
echo '{"lockfileVersion": 2}' >"$repo/package-lock.json"
crun deps
grep -q "left-pad" "$CURL_LOG" || fail "cache: a changed lockfile reuses the lookup"
npm left-pad 3000 100000
run deps || fail "cache: lookup fails: $(cat "$work/out")"
cache=$(ls "$repo"/.git/senior-mode/scan-cache/deps-*)
sed -i "1s/.*/$(($(date +%s) - 86500))/" "$cache"
crun deps || fail "cache: an old verdict fails the run: $(cat "$work/out")"
grep -q "left-pad" "$CURL_LOG" || fail "cache: a lookup of more than 24 h was reused"
sed -i "1s/.*/$(($(date +%s) - 82800))/" "$cache"
crun deps || fail "cache: a verdict of 23 h fails the run: $(cat "$work/out")"
[ ! -s "$CURL_LOG" ] || fail "cache: a verdict of 23 h was not reused: $(cat "$CURL_LOG")"
# A failure is not kept: a package that is missing is looked up, and fails, each time.
echo '{"name": "app", "dependencies": {"lodash": "^4", "left-pad": "1", "ghost-pkg": "1"}}' >"$repo/package.json"
git_ commit -qam "feat: ghost"
reg https://registry.npmjs.org/ghost-pkg 404 '{"error": "Not found"}'
run deps && fail "cache: a missing package passes"
crun deps && fail "cache: a missing package passes on the second run"
grep -q "ghost-pkg" "$CURL_LOG" || fail "cache: a failure was kept: $(cat "$CURL_LOG")"
has "npm ghost-pkg: not on the registry" "cache: failure said again"

[ "$failures" -eq 0 ] && echo "deps: all cases pass"
exit "$failures"
