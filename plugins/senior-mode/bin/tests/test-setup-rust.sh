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

# cargo llvm-cov writes lcov at lcov.info; the project's own command is kept (#494).
d=$(project covrust Cargo.toml Cargo.lock)
setup "$d"
[ "$(cfg "$d" .commands.coverage)" = "cargo llvm-cov --lcov --output-path lcov.info" ] || fail "rust coverage command: $(cfg "$d" .commands.coverage)"
[ "$(cfg "$d" .ratchet.coverage.report)" = lcov.info ] || fail "report not named: $(cfg "$d" .ratchet.coverage.report)"
[ -z "$(check_run "$d" coverage)" ] || fail "coverage became a check"
coverage_read "$d" "$(printf 'SF:src/lib.rs\nLF:10\nLH:5\nend_of_record')"
d=$(project covown Cargo.toml)
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

# The rust pack (#733): listed, never written; the packs are named in the config.
d=$(project packnew Cargo.toml)
setup "$d"
for want in "rules: clippy -D warnings: covered by your config" "rules: cognitive_complexity: proposed" "rules: too_many_lines: proposed" "rules: rustfmt: covered by your config"; do
  grep -qF "$want" "$work/out" || fail "pack line '$want' missing: $(cat "$work/out")"
done
[ "$(cfg "$d" '.rules.packs | join(",")')" = rust ] || fail "packs not named: $(cfg "$d" .rules)"
d=$(project packold Cargo.toml main.rs)
printf '[package]\nname = "app"\n\n[lints.clippy]\ncognitive_complexity = "warn"\n' >"$d/Cargo.toml"
cp "$d/Cargo.toml" "$work/cargo.before"
adopt_report "$d"
# shellcheck disable=SC2016 # the backticks of the markdown report
for want in '`cognitive_complexity`: covered by your config' '`too_many_lines`: proposed' '`clippy -D warnings`: covered by your config' '`rustfmt`: covered by your config'; do
  grep -qF -- "$want" "$work/body" || fail "adoption report without '$want': $(cat "$work/body")"
done
cmp -s "$work/cargo.before" "$d/Cargo.toml" || fail "adopt changed Cargo.toml"
grep -qx "Cargo.toml\|clippy.toml" "$work/changed" && fail "the adoption pull request changes a project file: $(cat "$work/changed")"

[ "$failures" -eq 0 ] && echo "setup-rust: all cases pass"
exit "$failures"
