#!/usr/bin/env bash
# Tests for the node preset of `senior-mode setup repo`: detection and commands from
# package.json. Offline: nothing is installed or run; evals/run.sh runs a real project.
set -u
cli=$(cd "$(dirname "$0")/.." && pwd)/senior-mode
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }
project() { # name package.json [lockfile...]
  local dir="$work/$1"
  git init -q -b main "$dir"
  printf '%s\n' "$2" >"$dir/package.json"
  shift 2
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

# An ESLint project on pnpm, with a tsconfig but no typecheck script.
d=$(project eslint '{"scripts": {"lint": "eslint . && prettier --check .", "test": "vitest run",
  "build": "tsc -p tsconfig.build.json"}, "devDependencies": {"eslint": "9", "prettier": "3", "typescript": "5"}}' pnpm-lock.yaml tsconfig.json)
setup "$d"
[ "$(cfg "$d" .preset)" = node ] || fail "node preset not chosen: $(cfg "$d" .preset)"
grep -q "^preset: node (TypeScript)$" "$work/out" || fail "TypeScript not reported: $(cat "$work/out")"
[ "$(check_run "$d" lint)" = "pnpm run lint" ] || fail "existing lint script not used: $(check_run "$d" lint)"
[ "$(check_run "$d" typecheck)" = "pnpm exec tsc --noEmit" ] || fail "no tsc fallback: $(check_run "$d" typecheck)"
[ "$(check_run "$d" test)" = "pnpm run test" ] || fail "test script not used"
[ "$(check_run "$d" build)" = "pnpm run build" ] || fail "build script not used"
[ -z "$(check_run "$d" e2e)" ] || fail "e2e check without an e2e script"
grep -qi biome "$d/package.json" && fail "package.json changed"
[ "$(jq -r '.packages["."]["release-type"]' "$d/release-please-config.json")" = node ] ||
  fail "release-please not set up for a node package"
[ "$(jq -r '.packages["."]["initial-version"]' "$d/release-please-config.json")" = 0.1.0 ] ||
  fail "first release not 0.1.0 without a package.json version"
grep -q "first release follows" "$work/out" && fail "version notice without a package.json version"
# A package.json version is the last release: the next one bumps it, never repeats it.
v=$(project versioned '{"version": "2.4.1", "scripts": {"test": "vitest run"}}')
setup "$v"
[ "$(jq -r '."."' "$v/.release-please-manifest.json")" = 2.4.1 ] || fail "manifest not seeded from package.json"
[ "$(jq -r '.packages["."]["initial-version"]' "$v/release-please-config.json")" = 0.1.0 ] ||
  fail "initial-version taken from package.json, which would release it again"
grep -q "first release follows 2.4.1" "$work/out" || fail "seeded version not reported: $(cat "$work/out")"
# npm init's 1.0.0 with no release tag: the user learns how to start lower.
v=$(project npminit '{"version": "1.0.0"}')
setup "$v"
grep -q 'first release follows 1.0.0.*"0.0.0"' "$work/out" || fail "no way to start below 1.0.0 given: $(cat "$work/out")"

# Run again: same config.
cp "$d/.claude/senior-mode.json" "$work/before"
setup "$d"
cmp -s "$work/before" "$d/.claude/senior-mode.json" || fail "second run changed the config"

# A Next.js app on npm, scripts named the usual way, the default npm test script, an e2e script.
d=$(project next '{"scripts": {"typecheck": "tsc --noEmit", "test": "echo \"Error: no test specified\" && exit 1",
  "build": "next build", "test:e2e": "playwright test"}, "dependencies": {"next": "16"}}' package-lock.json tsconfig.json)
setup "$d"
[ "$(cfg "$d" .framework)" = next ] || fail "Next.js not recorded"
grep -q "^preset: node (TypeScript, next)$" "$work/out" || fail "Next.js not reported: $(cat "$work/out")"
[ "$(check_run "$d" typecheck)" = "npm run typecheck" ] || fail "typecheck script not used"
[ "$(check_run "$d" build)" = "npm run build" ] || fail "next build not through the script"
[ "$(check_run "$d" e2e)" = "npm run test:e2e" ] || fail "e2e script not used: $(check_run "$d" e2e)"
[ -z "$(check_run "$d" test)" ] || fail "npm's placeholder test script taken as tests"
grep -q "missing: lint, test" "$work/out" || fail "missing tools not reported: $(cat "$work/out")"

# Plain JavaScript: named as such, and no typecheck is expected.
d=$(project js '{"scripts": {"lint": "eslint ."}}' package-lock.json)
setup "$d"
[ "$(cfg "$d" .preset)" = node ] || fail "node preset not chosen for JavaScript: $(cfg "$d" .preset)"
grep -q "^preset: node (JavaScript)$" "$work/out" || fail "JavaScript not reported: $(cat "$work/out")"
grep -q "^missing: test, build " "$work/out" || fail "typecheck expected from JavaScript: $(cat "$work/out")"

# A preset stored under its former name becomes node.
jq '.preset = "typescript"' "$d/.claude/senior-mode.json" >"$work/c" && mv "$work/c" "$d/.claude/senior-mode.json"
setup "$d"
[ "$(cfg "$d" .preset)" = node ] || fail "stored typescript preset not migrated: $(cfg "$d" .preset)"

# A tsconfig without typescript installed: no tsc fallback (npx would fetch another package).
d=$(project notsc '{"scripts": {"lint": "eslint ."}}' package-lock.json tsconfig.json)
setup "$d"
[ -z "$(check_run "$d" typecheck)" ] || fail "tsc fallback without typescript: $(check_run "$d" typecheck)"

# typescript declared but not installed: the fallback never downloads a package, it fails.
for pair in package-lock.json:'npx --no -- tsc --noEmit' bun.lock:'bun run tsc --noEmit'; do
  d=$(project "tsc-${pair%%:*}" '{"devDependencies": {"typescript": "5"}}' "${pair%%:*}" tsconfig.json)
  setup "$d"
  [ "$(check_run "$d" typecheck)" = "${pair#*:}" ] || fail "tsc fallback may download: $(check_run "$d" typecheck)"
done

# Lockfiles pick the package manager.
for pair in yarn.lock:yarn bun.lock:bun bun.lockb:bun; do
  d=$(project "pm-${pair%%:*}" '{"scripts": {"lint": "biome check ."}}' "${pair%%:*}")
  setup "$d"
  [ "$(check_run "$d" lint)" = "${pair#*:} run lint" ] || fail "${pair%%:*}: wrong runner: $(check_run "$d" lint)"
done

# Commands given or stored earlier win over detection.
d=$(project override '{"scripts": {"lint": "eslint ."}}' package-lock.json)
setup "$d" --command lint="make lint" --command e2e="npm run e2e"
[ "$(check_run "$d" lint)" = "make lint" ] || fail "--command lost to detection"
[ "$(check_run "$d" e2e)" = "npm run e2e" ] || fail "e2e not accepted as a node command"
setup "$d"
[ "$(check_run "$d" lint)" = "make lint" ] || fail "stored command replaced by detection on rerun"

# Without package.json: generic preset, e2e is not one of its commands.
d="$work/plain"
git init -q -b main "$d"
setup "$d"
[ "$(cfg "$d" .preset)" = generic ] || fail "generic preset not kept for a plain repository"
(cd "$d" && "$cli" setup repo --command e2e=x) 2>/dev/null && fail "generic preset accepts e2e"

[ "$failures" -eq 0 ] && echo "setup-node: all cases pass"
exit "$failures"
