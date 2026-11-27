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

# Protected zones: the preset's globs are written when the key is absent, a user's list is never touched.
for zone in '**/migrations/**' '**/auth/**' '**/payments/**' '.env*' '.github/workflows/**' 'Dockerfile*' '.claude/secret-allowlist' '.claude/ratchet-baseline.json' '.claude/architecture-baseline.json'; do
  jq -e --arg z "$zone" '.protected | index($z)' "$d/.claude/senior-mode.json" >/dev/null ||
    fail "node preset does not protect $zone: $(cfg "$d" '.protected')"
done
jq '.protected = ["only/mine/**"]' "$d/.claude/senior-mode.json" >"$work/c" && mv "$work/c" "$d/.claude/senior-mode.json"
setup "$d"
[ "$(cfg "$d" '.protected | join(",")')" = "only/mine/**" ] || fail "user's protected list overwritten: $(cfg "$d" '.protected')"
jq '.protected = []' "$d/.claude/senior-mode.json" >"$work/c" && mv "$work/c" "$d/.claude/senior-mode.json"
setup "$d"
[ "$(cfg "$d" '.protected | length')" = 0 ] || fail "an empty protected list, chosen on purpose, was refilled"
jq 'del(.protected)' "$d/.claude/senior-mode.json" >"$work/c" && mv "$work/c" "$d/.claude/senior-mode.json"
setup "$d"
[ "$(cfg "$d" '.protected | length')" -gt 0 ] || fail "protected not written back when the key is absent"

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
[ "$(check_run "$d" typecheck)" = "npx --no -- next typegen && npm run typecheck" ] ||
  fail "typecheck without next typegen: $(check_run "$d" typecheck)"
[ "$(check_run "$d" build)" = "npm run build" ] || fail "next build not through the script"
[ "$(check_run "$d" e2e)" = "npm run test:e2e" ] || fail "e2e script not used: $(check_run "$d" e2e)"
[ -z "$(check_run "$d" test)" ] || fail "npm's placeholder test script taken as tests"
grep -q "missing: lint, test" "$work/out" || fail "missing tools not reported: $(cat "$work/out")"

# Next.js awareness: the middleware (proxy since Next 16) is a protected zone, written when the config has no list yet.
# Only a Next.js project gets it; a list already in the config, even an empty one, is never touched.
for zone in 'middleware.*' 'src/middleware.*' 'proxy.*' 'src/proxy.*'; do
  jq -e --arg z "$zone" '.protected | index($z)' "$d/.claude/senior-mode.json" >/dev/null ||
    fail "Next.js project does not protect $zone: $(cfg "$d" '.protected')"
done
[ "$(check_run "$d" e2e)" = "npm run test:e2e" ] || fail "framework awareness changed the e2e command"
jq '.protected = ["only/mine/**"]' "$d/.claude/senior-mode.json" >"$work/c" && mv "$work/c" "$d/.claude/senior-mode.json"
setup "$d"
[ "$(cfg "$d" '.protected | join(",")')" = "only/mine/**" ] || fail "user's protected list overwritten: $(cfg "$d" '.protected')"
jq '.protected = []' "$d/.claude/senior-mode.json" >"$work/c" && mv "$work/c" "$d/.claude/senior-mode.json"
setup "$d"
[ "$(cfg "$d" '.protected | length')" = 0 ] || fail "an empty protected list, chosen on purpose, was refilled"
jq 'del(.protected)' "$d/.claude/senior-mode.json" >"$work/c" && mv "$work/c" "$d/.claude/senior-mode.json"
setup "$d"
jq -e '.protected | index("middleware.*")' "$d/.claude/senior-mode.json" >/dev/null || fail "protected not written back when the key is absent"
d=$(project dev-next '{"devDependencies": {"next": "16"}}' package-lock.json)
setup "$d"
jq -e '.protected | index("src/middleware.*")' "$d/.claude/senior-mode.json" >/dev/null || fail "next as a devDependency not recognised"

# Route types (#112): next typegen before typecheck from Next.js 15.5, not before, not twice.
for pair in '^15.5.0:npx --no -- next typegen && npx --no -- tsc --noEmit' 'latest:npx --no -- next typegen && npx --no -- tsc --noEmit' \
  '~15.4.2:npx --no -- tsc --noEmit' '14:npx --no -- tsc --noEmit'; do
  d=$(project "typegen-${pair%%:*}" "{\"dependencies\": {\"next\": \"${pair%%:*}\", \"typescript\": \"5\"}}" package-lock.json tsconfig.json)
  setup "$d"
  [ "$(check_run "$d" typecheck)" = "${pair#*:}" ] || fail "next ${pair%%:*}: $(check_run "$d" typecheck)"
done
d=$(project typegen-script '{"scripts": {"typecheck": "next typegen && tsc --noEmit"}, "dependencies": {"next": "16"}}' package-lock.json)
setup "$d"
[ "$(check_run "$d" typecheck)" = "npm run typecheck" ] || fail "typegen added twice: $(check_run "$d" typecheck)"

# Plain JavaScript: named as such, and no typecheck is expected.
d=$(project js '{"scripts": {"lint": "eslint ."}}' package-lock.json)
setup "$d"
[ "$(cfg "$d" .preset)" = node ] || fail "node preset not chosen for JavaScript: $(cfg "$d" .preset)"
grep -q "^preset: node (JavaScript)$" "$work/out" || fail "JavaScript not reported: $(cat "$work/out")"
grep -q "^missing: test, build " "$work/out" || fail "typecheck expected from JavaScript: $(cat "$work/out")"
[ "$(cfg "$d" '.protected // [] | map(select(test("middleware")))| length')" = 0 ] || fail "middleware protected without Next.js"

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

# The install command of a new worktree (#110): the lockfile's, frozen; npm install without one. It is
# stored with the commands, and `--command install=` replaces it.
install_of() { # name lockfile -> install command stored for a project with that lockfile
  local dir
  dir=$(project "inst-$1" '{"dependencies": {"a": "1"}}' ${2:+"$2"})
  setup "$dir"
  cfg "$dir" '.commands.install'
}
[ "$(install_of npm package-lock.json)" = "npm ci" ] || fail "npm: $(install_of npm package-lock.json)"
[ "$(install_of pnpm pnpm-lock.yaml)" = "pnpm install --frozen-lockfile" ] || fail "pnpm: $(install_of pnpm pnpm-lock.yaml)"
[ "$(install_of yarn yarn.lock)" = "yarn install --frozen-lockfile" ] || fail "yarn: $(install_of yarn yarn.lock)"
[ "$(install_of bun bun.lock)" = "bun install --frozen-lockfile" ] || fail "bun: $(install_of bun bun.lock)"
[ "$(install_of bunb bun.lockb)" = "bun install --frozen-lockfile" ] || fail "bun.lockb: $(install_of bunb bun.lockb)"
[ "$(install_of none)" = "npm install" ] || fail "no lockfile: $(install_of none)"
d=$(project berry '{"dependencies": {"a": "1"}}' yarn.lock .yarnrc.yml)
setup "$d"
[ "$(cfg "$d" .commands.install)" = "yarn install --immutable" ] || fail "yarn berry: $(cfg "$d" .commands.install)"
[ -z "$(check_run "$d" install)" ] || fail "install became a check"
(cd "$d" && "$cli" setup repo --command install="make deps") >/dev/null 2>&1 || fail "--command install refused"
[ "$(cfg "$d" .commands.install)" = "make deps" ] || fail "--command install not stored: $(cfg "$d" .commands.install)"

# #638: no test script, but node:test suites (here under tooling/ of a pnpm workspace): `node --test` is proposed, as the
# command and the test check. A test file of another runner (no node:test import) proposes nothing.
d=$(project nodetest '{"name": "ws", "private": true, "scripts": {"lint": "eslint ."}}' pnpm-lock.yaml)
mkdir -p "$d/tooling/lib" "$d/node_modules/dep"
printf "import test from 'node:test';\ntest('a', () => {});\n" >"$d/tooling/lib/a.test.mjs"
printf "import test from 'node:test';\ntest('b', () => {});\n" >"$d/node_modules/dep/b.test.mjs"
setup "$d"
[ "$(cfg "$d" .commands.test)" = "node --test" ] || fail "node:test suites: no node --test command: $(cfg "$d" .commands.test)"
[ "$(check_run "$d" test)" = "node --test" ] || fail "node:test suites: no test check: $(check_run "$d" test)"
d=$(project nodetest-dep '{"name": "ws"}' pnpm-lock.yaml)
mkdir -p "$d/node_modules/dep"
printf "import test from 'node:test';\n" >"$d/node_modules/dep/b.test.mjs"
setup "$d"
[ "$(cfg "$d" '.commands.test // "none"')" = none ] || fail "a test file of node_modules gave a test command: $(cfg "$d" .commands.test)"
d=$(project jesttest '{"name": "app"}' pnpm-lock.yaml)
printf "describe('a', () => { it('b', () => {}); });\n" >"$d/a.test.js"
setup "$d"
[ "$(cfg "$d" '.commands.test // "none"')" = none ] || fail "a jest file gave node --test: $(cfg "$d" .commands.test)"
d=$(project scripttest '{"name": "app", "scripts": {"test": "vitest run"}}' pnpm-lock.yaml)
printf "import test from 'node:test';\n" >"$d/a.test.mjs"
setup "$d"
[ "$(cfg "$d" .commands.test)" = "pnpm run test" ] || fail "the test script lost to node --test: $(cfg "$d" .commands.test)"

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

# A coverage command per test runner, lcov at coverage/lcov.info; the project's own script is kept (#494).
d=$(project covvitest '{"scripts": {"test": "vitest run"}, "devDependencies": {"vitest": "2"}}' pnpm-lock.yaml)
setup "$d"
[ "$(cfg "$d" .commands.coverage)" = "pnpm exec vitest run --coverage --coverage.reporter=lcov" ] || fail "vitest coverage command: $(cfg "$d" .commands.coverage)"
[ "$(cfg "$d" .ratchet.coverage.report)" = coverage/lcov.info ] || fail "report not named: $(cfg "$d" .ratchet.coverage.report)"
[ -z "$(check_run "$d" coverage)" ] || fail "coverage became a check"
coverage_read "$d" "$(printf 'SF:src/a.ts\nLF:10\nLH:5\nend_of_record')"
d=$(project covjest '{"scripts": {"test": "jest"}, "devDependencies": {"jest": "29"}}')
setup "$d"
[ "$(cfg "$d" .commands.coverage)" = "npx --no -- jest --coverage --coverageReporters=lcov" ] || fail "jest coverage command: $(cfg "$d" .commands.coverage)"
d=$(project covother '{"scripts": {"test": "mocha"}}')
setup "$d"
[ "$(cfg "$d" .commands.coverage)" = "npx --no -- c8 --reporter=lcov npm run test" ] || fail "c8 coverage command: $(cfg "$d" .commands.coverage)"
d=$(project covscript '{"scripts": {"test": "vitest run", "test:coverage": "vitest run --coverage"}, "devDependencies": {"vitest": "2"}}')
setup "$d"
[ "$(cfg "$d" .commands.coverage)" = "npm run test:coverage" ] || fail "the project's coverage script lost: $(cfg "$d" .commands.coverage)"
d=$(project covown '{"scripts": {"test": "vitest run"}, "devDependencies": {"vitest": "2"}}')
mkdir -p "$d/.claude" && echo '{"commands": {"coverage": "make cov"}}' >"$d/.claude/senior-mode.json"
setup "$d"
[ "$(cfg "$d" .commands.coverage)" = "make cov" ] || fail "an existing coverage command was replaced: $(cfg "$d" .commands.coverage)"
[ "$(cfg "$d" '.ratchet.coverage.report // "none"')" = none ] || fail "a report was named for the project's own command"
setup "$d" --command coverage="make other"
[ "$(cfg "$d" .commands.coverage)" = "make other" ] || fail "--command coverage not stored: $(cfg "$d" .commands.coverage)"

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

# The node pack (#728): a new project gets tsconfig strict and the ESLint rules written, the packs are named.
d=$(project packnew '{"name": "app", "devDependencies": {"typescript": "5"}}')
setup "$d"
[ "$(jq -r '.compilerOptions.strict' "$d/tsconfig.json")" = true ] || fail "tsconfig.json not strict: $(cat "$d/tsconfig.json" 2>&1)"
for want in '"@typescript-eslint/no-explicit-any": "error"' 'complexity: ["error", 15]' '"max-lines-per-function": ["error", 60]'; do
  grep -qF -- "$want" "$d/eslint.config.mjs" || fail "eslint.config.mjs without '$want': $(cat "$d/eslint.config.mjs" 2>&1)"
done
grep -qF "rules: complexity: written to eslint.config.mjs" "$work/out" || fail "pack not reported: $(cat "$work/out")"
[ "$(cfg "$d" '.rules.packs | join(",")')" = node ] || fail "packs not named: $(cfg "$d" .rules)"
[ "$(cfg "$d" .commands.typecheck)" = "npx --no -- tsc --noEmit" ] || fail "the written tsconfig is not detected: $(cfg "$d" .commands)"
cp "$d/.claude/senior-mode.json" "$work/before"
cp "$d/eslint.config.mjs" "$work/eslint.before"
setup "$d"
cmp -s "$work/before" "$d/.claude/senior-mode.json" || fail "second run changed the config"
cmp -s "$work/eslint.before" "$d/eslint.config.mjs" || fail "second run changed the ESLint config"
grep -qF "rules: complexity: covered by your config" "$work/out" || fail "written rules not covered on the second run: $(cat "$work/out")"
# A project with its own tsconfig and ESLint config: nothing is written over them.
d=$(project packown '{"name": "app", "devDependencies": {"typescript": "5", "eslint": "9"}}' tsconfig.json)
echo '{"compilerOptions": {"target": "es2022"}}' >"$d/tsconfig.json"
echo 'export default [{ rules: { semi: "error" } }];' >"$d/eslint.config.js"
cp "$d/tsconfig.json" "$work/tsconfig.before"
setup "$d"
cmp -s "$work/tsconfig.before" "$d/tsconfig.json" || fail "setup changed tsconfig.json"
[ ! -e "$d/eslint.config.mjs" ] || fail "setup wrote a second ESLint config"
grep -qF "rules: tsconfig strict: proposed" "$work/out" || fail "tsconfig not proposed: $(cat "$work/out")"
# Adoption: an ESLint config without complexity is listed proposed and left alone; with it, covered.
d=$(project adoptno '{"name": "app", "devDependencies": {"typescript": "5", "eslint": "9"}}')
echo '{"compilerOptions": {"strict": true}}' >"$d/tsconfig.json"
echo 'export default [{ rules: { "max-lines-per-function": ["error", 60] } }];' >"$d/eslint.config.js"
cp "$d/eslint.config.js" "$work/eslint.before"
adopt_report "$d"
# shellcheck disable=SC2016 # the backticks of the markdown report
for want in '`complexity`: proposed' '`max-lines-per-function`: covered by your config' '`tsconfig strict`: covered by your config' '`@typescript-eslint/no-explicit-any`: proposed'; do
  grep -qF -- "$want" "$work/body" || fail "adoption report without '$want': $(cat "$work/body")"
done
cmp -s "$work/eslint.before" "$d/eslint.config.js" || fail "adopt changed the ESLint config"
grep -qx "eslint.config.js\|eslint.config.mjs\|tsconfig.json" "$work/changed" && fail "the adoption pull request changes a project file: $(cat "$work/changed")"
d=$(project adoptyes '{"name": "app", "devDependencies": {"eslint": "9"}}')
echo 'export default [{ rules: { complexity: ["error", 10] } }];' >"$d/eslint.config.js"
adopt_report "$d"
# shellcheck disable=SC2016 # the backticks of the markdown report
grep -qF -- '`complexity`: covered by your config' "$work/body" || fail "complexity not covered: $(cat "$work/body")"
# The a11y lint plugin is proposed to a UI project, not to another.
d=$(project uireact '{"name": "app", "dependencies": {"react": "19"}, "devDependencies": {"eslint": "9"}}')
echo 'export default [];' >"$d/eslint.config.js"
setup "$d"
grep -qF "rules: a11y lint (eslint-plugin-jsx-a11y): proposed" "$work/out" || fail "a11y plugin not proposed to a react project: $(cat "$work/out")"
d=$(project uivue '{"name": "app", "dependencies": {"vue": "3"}, "devDependencies": {"eslint": "9"}}')
echo 'import vue from "eslint-plugin-vuejs-accessibility"; export default [];' >"$d/eslint.config.js"
setup "$d"
grep -qF "rules: a11y lint (eslint-plugin-vuejs-accessibility): covered by your config" "$work/out" || fail "a11y plugin of a vue project: $(cat "$work/out")"
d=$(project nonui '{"name": "app", "dependencies": {"express": "5"}, "devDependencies": {"eslint": "9"}}')
echo 'export default [];' >"$d/eslint.config.js"
setup "$d"
grep -q "a11y" "$work/out" && fail "a11y plugin proposed to a project that has no UI: $(cat "$work/out")"

[ "$failures" -eq 0 ] && echo "setup-node: all cases pass"
exit "$failures"
