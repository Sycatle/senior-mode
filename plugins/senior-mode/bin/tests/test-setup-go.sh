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
for g in '**/migrations/**' '**/auth/**' '**/security/**' '.github/workflows/**' 'Dockerfile*' 'infra/**' '.claude/secret-allowlist' '.claude/senior-mode.json'; do
  jq -e --arg g "$g" '.protected | index($g)' "$preset" >/dev/null || fail "$g not protected by default"
done
jq -e '.protected | map(test("go\\.(sum|mod)")) | any' "$preset" >/dev/null && fail "go.sum or go.mod is protected by default"

# The install command of a new worktree (#110).
[ "$(cfg "$d" .commands.install)" = "go mod download" ] || fail "go install is $(cfg "$d" .commands.install)"

[ "$failures" -eq 0 ] && echo "setup-go: all cases pass"
exit "$failures"
