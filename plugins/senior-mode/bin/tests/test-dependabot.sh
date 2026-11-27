#!/usr/bin/env bash
# Tests for the judgement of a Dependabot pull request (lib/dependabot.sh, #721, part 1 of #680). Offline: gh and npm are
# stubs on the PATH. dependabot_assess <pr> prints one JSON line {verdict: ready|wait|human, major, packages, until|reason}.
# The commit trailer is `updated-dependencies:` with, per package, dependency-name, dependency-version and update-type;
# the age of a version is its publish time in `npm view <name> time --json`; the clock is SENIOR_MODE_NOW.
set -u
here=$(cd "$(dirname "$0")" && pwd)
SELF=$here/../senior-mode
LIB=$here/../lib
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

# shellcheck disable=SC1090,SC1091 # the modules are definitions only
for m in common config guard dependabot; do . "$LIB/$m.sh"; done

repo=$work/repo
git init -q -b main "$repo"
git -C "$repo" remote add origin https://github.com/o/r.git
mkdir -p "$repo/.claude" "$work/bin"
config() { printf '%s\n' "$1" >"$repo/.claude/senior-mode.json"; }
config '{"preset":"generic"}'
cd "$repo" || exit 1

NOW=1795000000 # 2026-11-18T09:46:40Z
export SENIOR_MODE_NOW=$NOW
at() { date -u -d "@$((NOW - $1 * 86400))" +%Y-%m-%dT%H:%M:%S.123Z; } # an instant n days ago

# gh: the commit messages and the files of pull request 7 are read from $work/msg and $work/files.
cat >"$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
case $2 in
  */pulls/7/commits) cat "$WORK/msg" ;;
  */pulls/7/files) cat "$WORK/files" ;;
  *) exit 1 ;;
esac
STUB
# npm view <name> time --json: $work/npm-<name with / as _> holds the answer.
cat >"$work/bin/npm" <<'STUB'
#!/usr/bin/env bash
cat "$WORK/npm-${2//\//_}" 2>/dev/null || exit 1
STUB
chmod +x "$work/bin/gh" "$work/bin/npm"
export WORK=$work PATH=$work/bin:$PATH
printf 'package.json\npnpm-lock.yaml\n' >"$work/files"

trailer() { # name version update...: one package of the trailer
  printf -- '- dependency-name: %s\n  dependency-type: direct:production\n  update-type: version-update:semver-%s\n  dependency-version: %s\n' "$1" "$3" "$2"
}
message() { # package lines...: a Dependabot commit message
  printf 'chore(deps): bump things\n\nBumps things.\n\n---\nupdated-dependencies:\n%s\n...\n\nSigned-off-by: dependabot[bot] <support@github.com>\n' "$*" >"$work/msg"
}
published() { jq -nc --arg v "$2" --arg t "$3" '{created: "2020-01-01T00:00:00.000Z", ($v): $t}' >"$work/npm-${1//\//_}"; }
assess() { dependabot_assess 7 >"$work/out" 2>"$work/err" || fail "assess failed: $(cat "$work/err")"; }
field() { jq -r "$1" "$work/out"; }
human() { [ "$(field .verdict)" = human ] && jq -r .reason "$work/out" | grep -q -- "$1"; } # a human verdict whose reason names $1

# Two packages published 10 days ago: ready.
message "$(trailer lodash 4.17.21 patch)
$(trailer @types/node 22.1.0 minor)"
published lodash 4.17.21 "$(at 10)"
published @types/node 22.1.0 "$(at 10)"
assess
[ "$(field .verdict)" = ready ] || fail "two old versions: $(cat "$work/out")"
[ "$(field '.packages | length')" -eq 2 ] && [ "$(field .major)" = false ] || fail "packages: $(cat "$work/out")"
[ "$(field '.packages[0].ageDays | floor')" -eq 10 ] || fail "age of a package: $(cat "$work/out")"

# One version published 2 days ago, release age 7 days: wait, until it turns 7 days old.
published lodash 4.17.21 "$(at 2)"
assess
[ "$(field .verdict)" = wait ] || fail "a young version: $(cat "$work/out")"
want=$(date -u -d "@$((NOW - 2 * 86400 + 7 * 86400))" +%Y-%m-%dT%H:%M:%SZ)
[ "$(field .until)" = "$want" ] || fail "until is $(field .until), not $want"

# A major bump: human, naming the package; the same for a bump of a package whose age is unknown.
message "$(trailer left-pad 2.0.0 major)"
published left-pad 2.0.0 "$(at 30)"
assess
human left-pad || fail "a major: $(cat "$work/out")"
[ "$(field .major)" = true ] || fail "a major is not flagged: $(cat "$work/out")"
message "$(trailer ghost 1.0.1 patch)"
assess
human ghost || fail "an unknown release age: $(cat "$work/out")"

# A changed file in a protected zone: human, naming the file.
message "$(trailer lodash 4.17.21 patch)"
published lodash 4.17.21 "$(at 10)"
config '{"preset":"generic","protected":["pnpm-lock.yaml"]}'
assess
human pnpm-lock.yaml || fail "a protected file: $(cat "$work/out")"

# serve.dependabot.minReleaseDays is the release age used; a value below 0 fails config validate naming the key.
config '{"preset":"generic","serve":{"dependabot":{"minReleaseDays":3}}}'
published lodash 4.17.21 "$(at 2)"
assess
[ "$(field .verdict)" = wait ] && [ "$(field .minReleaseDays)" -eq 3 ] || fail "3 days, a 2-day-old version: $(cat "$work/out")"
want=$(date -u -d "@$((NOW - 2 * 86400 + 3 * 86400))" +%Y-%m-%dT%H:%M:%SZ)
[ "$(field .until)" = "$want" ] || fail "until with 3 days is $(field .until), not $want"
published lodash 4.17.21 "$(at 4)"
assess
[ "$(field .verdict)" = ready ] || fail "3 days, a 4-day-old version: $(cat "$work/out")"
(cd "$repo" && "$SELF" config validate) >"$work/out" 2>&1 || fail "minReleaseDays 3 is refused: $(cat "$work/out")"
config '{"preset":"generic","serve":{"dependabot":{"minReleaseDays":-1}}}'
(cd "$repo" && "$SELF" config validate) >"$work/out" 2>&1 && fail "minReleaseDays -1 passes"
grep -q '^error: serve.dependabot.minReleaseDays: -1 is below the minimum 0$' "$work/out" || fail "the key is not named: $(cat "$work/out")"

exit "$failures"
