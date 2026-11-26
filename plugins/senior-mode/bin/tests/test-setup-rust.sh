#!/usr/bin/env bash
# Tests for the rust preset of `senior-mode setup repo`: detection and commands from Cargo.toml.
# Offline: cargo is neither installed nor run; it is only named in the checks.
set -u
cli=$(cd "$(dirname "$0")/.." && pwd)/senior-mode
preset=$(cd "$(dirname "$0")/../.." && pwd)/presets/rust/preset.json
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

d=$(project crate Cargo.toml Cargo.lock)
setup "$d"
[ "$(cfg "$d" .preset)" = rust ] || fail "rust preset not chosen: $(cfg "$d" .preset)"
grep -q "^preset: rust$" "$work/out" || fail "preset not reported: $(cat "$work/out")"
expect "$d" lint "cargo clippy --all-targets -- -D warnings"
expect "$d" format "cargo fmt --check"
expect "$d" test "cargo test"
expect "$d" build "cargo build"
[ "$(jq -r '.packages["."]["release-type"]' "$d/release-please-config.json")" = rust ] ||
  fail "release-please not set up for a rust crate"
[ "$(jq -r '.packages["."]["initial-version"]' "$d/release-please-config.json")" = 0.1.0 ] || fail "first release not 0.1.0"
cp "$d/.claude/senior-mode.json" "$work/before"
setup "$d"
cmp -s "$work/before" "$d/.claude/senior-mode.json" || fail "second run changed the config"

# A crate that already has a version is the last release: the manifest holds it, the next release bumps it.
d=$(project versioned Cargo.toml)
printf '[workspace.package]\nversion = "9.9.9"\n\n[package] # the crate\nname = "app"\nversion = "1.3.0"\n\n[dependencies]\nserde = { version = "1.0.200" }\n' >"$d/Cargo.toml"
setup "$d"
[ "$(jq -r '."."' "$d/.release-please-manifest.json")" = 1.3.0 ] || fail "manifest not seeded from Cargo.toml: $(cat "$d/.release-please-manifest.json")"
[ "$(jq -r '.packages["."]["initial-version"]' "$d/release-please-config.json")" = 0.1.0 ] || fail "initial-version taken from Cargo.toml"
grep -q "first release follows 1.3.0 (Cargo.toml)" "$work/out" || fail "seeded version not reported: $(cat "$work/out")"
d=$(project inherited Cargo.toml)
printf '[package]\nname = "app"\nversion.workspace = true\n' >"$d/Cargo.toml"
setup "$d"
[ "$(jq -r '."."' "$d/.release-please-manifest.json")" = 0.0.0 ] || fail "an inherited version was read: $(cat "$d/.release-please-manifest.json")"

# Detection order: package.json keeps node; Cargo.toml comes before Python files; a stored preset wins.
d=$(project withnode Cargo.toml)
echo '{"scripts": {"test": "vitest run"}}' >"$d/package.json"
setup "$d"
[ "$(cfg "$d" .preset)" = node ] || fail "package.json lost to Cargo.toml: $(cfg "$d" .preset)"
d=$(project withpython Cargo.toml pyproject.toml requirements.txt)
setup "$d"
[ "$(cfg "$d" .preset)" = rust ] || fail "Cargo.toml lost to Python files: $(cfg "$d" .preset)"
d=$(project stored Cargo.toml)
mkdir -p "$d/.claude" && echo '{"preset": "generic"}' >"$d/.claude/senior-mode.json"
setup "$d"
[ "$(cfg "$d" .preset)" = generic ] || fail "stored preset lost to detection: $(cfg "$d" .preset)"

# Commands given or stored earlier win over detection; e2e is not a rust command.
d=$(project override Cargo.toml)
setup "$d" --command test="cargo nextest run"
setup "$d"
expect "$d" test "cargo nextest run"
(cd "$d" && "$cli" setup repo --command e2e=x) 2>/dev/null && fail "rust preset accepts e2e"

# Default protected zones: migrations, auth and security, CI, containers and infra; no lockfile.
jq -e '.protected | length > 0' "$preset" >/dev/null || fail "no protected globs in the preset"
for g in '**/migrations/**' '**/auth/**' '**/security/**' '.github/workflows/**' 'Dockerfile*' 'infra/**' '.claude/secret-allowlist' '.claude/ratchet-baseline.json' '.claude/architecture-baseline.json' '.claude/senior-mode.json'; do
  jq -e --arg g "$g" '.protected | index($g)' "$preset" >/dev/null || fail "$g not protected by default"
done
jq -e '.protected | map(test("Cargo")) | any' "$preset" >/dev/null && fail "Cargo.lock or Cargo.toml is protected by default"

# The install command of a new worktree (#110).
[ "$(cfg "$d" .commands.install)" = "cargo fetch" ] || fail "rust install is $(cfg "$d" .commands.install)"

[ "$failures" -eq 0 ] && echo "setup-rust: all cases pass"
exit "$failures"
