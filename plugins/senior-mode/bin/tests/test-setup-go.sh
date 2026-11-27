#!/usr/bin/env bash
# Tests for the go preset of `senior-mode setup repo`: detection and commands from go.mod.
# Offline: no Go tool is installed or run; they are only named in the checks.
set -u
cli=$(cd "$(dirname "$0")/.." && pwd)/senior-mode
preset=$(cd "$(dirname "$0")/../.." && pwd)/presets/go/preset.json
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }
project() { # name file...
  local dir="$work/$1" f
  git init -q -b main "$dir"
  shift
  for f in "$@"; do : >"$dir/$f"; done
  echo "$dir"
}
setup() { # dir [args...]
  local dir=$1
  shift
  (cd "$dir" && "$cli" setup repo "$@") >"$work/out" 2>"$work/err" || fail "setup exited non-zero: $(cat "$work/err")"
}
cfg() { jq -r "$2" "$1/.claude/senior-mode.json"; }
check_run() { jq -r --arg n "$2" '.checks[] | select(.name == $n) | .run' "$1/.claude/senior-mode.json"; }
expect() { # dir check command
  [ "$(check_run "$1" "$2")" = "$3" ] || fail "$(basename "$1"): $2 is '$(check_run "$1" "$2")', expected '$3'"
}

# A module without a linter config: vet, test, build.
d=$(project plain go.mod go.sum)
setup "$d"
[ "$(cfg "$d" .preset)" = go ] || fail "go preset not chosen: $(cfg "$d" .preset)"
grep -q "^preset: go$" "$work/out" || fail "preset not reported: $(cat "$work/out")"
expect "$d" lint "go vet ./..."
expect "$d" test "go test ./..."
expect "$d" build "go build ./..."
[ -z "$(check_run "$d" format)" ] || fail "format check on go, which has none"
[ "$(jq -r '.packages["."]["release-type"]' "$d/release-please-config.json")" = go ] ||
  fail "release-please not set up for a go module"
[ "$(jq -r '.packages["."]["initial-version"]' "$d/release-please-config.json")" = 0.1.0 ] || fail "first release not 0.1.0"
cp "$d/.claude/senior-mode.json" "$work/before"
setup "$d"
cmp -s "$work/before" "$d/.claude/senior-mode.json" || fail "second run changed the config"

# golangci-lint joins vet when its config exists, whatever the extension.
for f in .golangci.yml .golangci.yaml .golangci.toml .golangci.json; do
  d=$(project "lint-$f" go.mod "$f")
  setup "$d"
  expect "$d" lint "go vet ./... && golangci-lint run"
done

# The latest vX.Y.Z tag is the last release (highest version, pre-releases ignored); with no tag the module starts at 0.1.0.
d=$(project tagged go.mod)
git -C "$d" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "chore: init"
for t in v1.4.2 v1.10.0 v2.0.0-rc1 other-v3.0.0; do git -C "$d" tag "$t"; done
setup "$d"
[ "$(jq -r '."."' "$d/.release-please-manifest.json")" = 1.10.0 ] || fail "manifest not seeded from the go tags: $(cat "$d/.release-please-manifest.json")"
[ "$(jq -r '.packages["."]["initial-version"]' "$d/release-please-config.json")" = 0.1.0 ] || fail "initial-version taken from a tag"
d=$(project untagged go.mod)
setup "$d"
[ "$(jq -r '."."' "$d/.release-please-manifest.json")" = 0.0.0 ] || fail "manifest not 0.0.0 without a tag"

# Detection order: package.json keeps node; go.mod comes before Cargo.toml and Python files; a stored
# preset wins.
d=$(project withnode go.mod package.json)
echo '{"scripts": {"test": "vitest run"}}' >"$d/package.json"
setup "$d"
[ "$(cfg "$d" .preset)" = node ] || fail "package.json lost to go.mod: $(cfg "$d" .preset)"
d=$(project withpython go.mod requirements.txt pyproject.toml)
setup "$d"
[ "$(cfg "$d" .preset)" = go ] || fail "go.mod lost to Python files: $(cfg "$d" .preset)"
d=$(project withrust go.mod Cargo.toml)
setup "$d"
[ "$(cfg "$d" .preset)" = go ] || fail "go.mod lost to Cargo.toml: $(cfg "$d" .preset)"
d=$(project stored go.mod)
mkdir -p "$d/.claude" && echo '{"preset": "generic"}' >"$d/.claude/senior-mode.json"
setup "$d"
[ "$(cfg "$d" .preset)" = generic ] || fail "stored preset lost to detection: $(cfg "$d" .preset)"

# Commands given or stored earlier win over detection; e2e and format are not go commands.
d=$(project override go.mod)
setup "$d" --command test="go test -race ./..."
setup "$d"
expect "$d" test "go test -race ./..."
(cd "$d" && "$cli" setup repo --command e2e=x) 2>/dev/null && fail "go preset accepts e2e"

# Default protected zones: migrations, auth and security, CI, containers and infra; no lockfile.
jq -e '.protected | length > 0' "$preset" >/dev/null || fail "no protected globs in the preset"
for g in '**/migrations/**' '**/auth/**' '**/security/**' '.github/workflows/**' 'Dockerfile*' 'infra/**' '.claude/secret-allowlist' '.claude/ratchet-baseline.json' '.claude/architecture-baseline.json' '.claude/senior-mode.json'; do
  jq -e --arg g "$g" '.protected | index($g)' "$preset" >/dev/null || fail "$g not protected by default"
done
jq -e '.protected | map(test("go\\.(sum|mod)")) | any' "$preset" >/dev/null && fail "go.sum or go.mod is protected by default"

# The install command of a new worktree (#110).
[ "$(cfg "$d" .commands.install)" = "go mod download" ] || fail "go install is $(cfg "$d" .commands.install)"

# The coverage report: the config names the file (#494); the ratchet reads it once the command wrote it.
coverage_read() { # dir report-content
  local rep
  rep=$(cfg "$1" '.ratchet.coverage.report // empty')
  [ -n "$rep" ] || { fail "$(basename "$1"): no ratchet.coverage.report"; return; }
  mkdir -p "$1/$(dirname "$rep")"
  printf '%s\n' "$2" >"$1/$rep"
  (cd "$1" && "$cli" ratchet --init) >"$work/out" 2>&1 || fail "$(basename "$1"): the ratchet does not read $rep: $(cat "$work/out")"
  jq -e '.coverage.total == 50' "$1/.claude/ratchet-baseline.json" >/dev/null 2>&1 || fail "$(basename "$1"): coverage of $rep not 50: $(cat "$1/.claude/ratchet-baseline.json" 2>/dev/null)"
}

# go test -coverprofile, converted to Cobertura at coverage.xml; the project's own command is kept (#494).
d=$(project covgo go.mod)
setup "$d"
[ "$(cfg "$d" .commands.coverage)" = "go test -coverprofile=coverage.out ./... && gocover-cobertura < coverage.out > coverage.xml" ] || fail "go coverage command: $(cfg "$d" .commands.coverage)"
[ "$(cfg "$d" .ratchet.coverage.report)" = coverage.xml ] || fail "report not named: $(cfg "$d" .ratchet.coverage.report)"
[ -z "$(check_run "$d" coverage)" ] || fail "coverage became a check"
coverage_read "$d" '<?xml version="1.0"?><coverage line-rate="0.5"><packages><package name="a"><classes><class name="a" filename="a.py" line-rate="0.5"><lines/></class></classes></package></packages></coverage>'
d=$(project covown go.mod)
mkdir -p "$d/.claude" && echo '{"commands": {"coverage": "make cov"}}' >"$d/.claude/senior-mode.json"
setup "$d"
[ "$(cfg "$d" .commands.coverage)" = "make cov" ] || fail "an existing coverage command was replaced: $(cfg "$d" .commands.coverage)"

# `setup repo --adopt` on an existing project, against a local bare origin and a stubbed gh: the body of the pull
# request goes to $work/body, the files the pull request changes to $work/changed (#733).
adopt_report() { # dir
  local d=$1 o g
  o="$work/$(basename "$1")/github.com/acme/app.git"
  g=(git -C "$1" -c core.hooksPath=/dev/null -c user.name=t -c user.email=t@t)
  mkdir -p "$work/stub"
  cat >"$work/stub/gh" <<'STUB'
#!/usr/bin/env bash
jqf="" prev="" body=""
for a in "$@"; do [ "$prev" = --jq ] && jqf=$a; [ "$prev" = --body ] && printf '%s\n' "$a" >"$BODY"; prev=$a; done
respond() { if [ -n "$jqf" ]; then jq -r "$jqf"; else cat; fi; }
case "$*" in
  "pr list"*) echo '[]' | respond ;;
  "pr create"*) echo "https://github.com/acme/app/pull/12" ;;
  "api repos/acme/app --jq"*) echo '{"allow_rebase_merge": true, "allow_squash_merge": true, "allow_merge_commit": false, "default_branch": "main"}' | respond ;;
  "label list"*) echo '[]' | respond ;;
  *) exit 1 ;;
esac
STUB
  chmod +x "$work/stub/gh"
  git init -q --bare -b main "$o"
  git -C "$d" remote add origin "$o"
  "${g[@]}" add -A && "${g[@]}" commit -q -m "chore: start" && "${g[@]}" push -q origin main
  (cd "$d" && PATH="$work/stub:$PATH" BODY="$work/body" SENIOR_MODE_RETRY_DELAY=0 XDG_DATA_HOME="$work/xdg" "$cli" setup repo --adopt) >"$work/out" 2>"$work/err" ||
    fail "adopt failed: $(cat "$work/err")"
  git -C "$o" diff --name-only main docs/adopt-senior-mode >"$work/changed" 2>/dev/null || : >"$work/changed"
}

# The go pack (#733): listed, never written; the packs are named in the config.
d=$(project packnew go.mod)
setup "$d"
for want in "rules: go vet: covered by your config" "rules: staticcheck: proposed" "rules: errcheck: proposed" "rules: gocognit: proposed" "rules: funlen: proposed" "rules: gofmt: proposed"; do
  grep -qF "$want" "$work/out" || fail "pack line '$want' missing: $(cat "$work/out")"
done
[ "$(cfg "$d" '.rules.packs | join(",")')" = go ] || fail "packs not named: $(cfg "$d" .rules)"
[ ! -e "$d/.golangci.yml" ] || fail "the pack wrote .golangci.yml"
d=$(project packold go.mod main.go)
printf 'linters:\n  enable:\n    - errcheck\n    - funlen\n' >"$d/.golangci.yml"
cp "$d/.golangci.yml" "$work/golangci.before"
adopt_report "$d"
# shellcheck disable=SC2016 # the backticks of the markdown report
for want in '`errcheck`: covered by your config' '`funlen`: covered by your config' '`gocognit`: proposed' '`staticcheck`: proposed' '`gofmt`: proposed'; do
  grep -qF -- "$want" "$work/body" || fail "adoption report without '$want': $(cat "$work/body")"
done
cmp -s "$work/golangci.before" "$d/.golangci.yml" || fail "adopt changed .golangci.yml"
grep -qx "\.golangci\.yml" "$work/changed" && fail "the adoption pull request changes .golangci.yml"

[ "$failures" -eq 0 ] && echo "setup-go: all cases pass"
exit "$failures"
