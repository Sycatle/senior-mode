#!/usr/bin/env bash
# Tests for the monorepo detection of `senior-mode setup repo` (#323): packages of a pnpm or npm workspace, a Cargo
# workspace and a Go repository, their commands and deps, a second run, the install plan.
# Offline: no package manager is run; the manifests are only read.
set -u
cli=$(cd "$(dirname "$0")/.." && pwd)/senior-mode
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }
project() { # name
  git init -q -b main "$work/$1"
  echo "$work/$1"
}
put() { # file content
  mkdir -p "$(dirname "$1")"
  printf '%s\n' "$2" >"$1"
}
setup() { # dir
  (cd "$1" && "$cli" setup repo) >"$work/out" 2>"$work/err" || fail "setup exited non-zero: $(cat "$work/err")"
}
pk() { jq -c "$2" "$1/.claude/senior-mode.json"; }
expect() { # dir filter expected
  [ "$(pk "$1" "$2")" = "$3" ] || fail "$(basename "$1"): $2 is $(pk "$1" "$2"), expected $3"
}

# A pnpm workspace: packages by glob and by name, deps from the manifests, commands through the workspace's package manager.
d=$(project pnpm)
put "$d/package.json" '{"name": "root", "private": true}'
: >"$d/pnpm-lock.yaml"
put "$d/pnpm-workspace.yaml" $'packages:\n  - "packages/*"\n  - apps/web # the site\n  - "!packages/skip"\n'
put "$d/packages/shared/package.json" '{"name": "@x/shared", "scripts": {"lint": "eslint .", "test": "vitest"}}'
put "$d/packages/api/package.json" '{"name": "@x/api", "dependencies": {"@x/shared": "workspace:*", "left-pad": "1"}, "scripts": {"test": "vitest"}}'
put "$d/packages/skip/package.json" '{"name": "@x/skip"}'
put "$d/apps/web/package.json" '{"name": "@x/web", "devDependencies": {"@x/shared": "workspace:*", "@x/api": "workspace:*"}, "scripts": {"build": "next build"}}'
put "$d/apps/other/package.json" '{"name": "@x/other"}'
setup "$d"
expect "$d" '.packages | keys' '["apps/web","packages/api","packages/shared"]'
expect "$d" '.packages["packages/api"]' '{"preset":"node","commands":{"test":"pnpm run test"},"deps":["packages/shared"]}'
expect "$d" '.packages["apps/web"].deps' '["packages/api","packages/shared"]'
expect "$d" '.packages["packages/shared"].commands' '{"lint":"pnpm run lint","test":"pnpm run test"}'
expect "$d" '.packages["packages/shared"].deps' '[]'
grep -q "^packages: apps/web, packages/api, packages/shared$" "$work/out" || fail "packages not reported: $(cat "$work/out")"
# The commands are the package's own: install stays at the root, once.
expect "$d" '[.packages[].commands.install] | map(select(. != null))' '[]'
[ "$(cd "$d" && "$cli" config validate >/dev/null 2>&1; echo $?)" = 0 ] || fail "config validate refuses packages"
plan=$(bash -c 'cd "$1" && . "$2"/lib/common.sh && . "$2"/lib/setup.sh && . "$2"/lib/packages.sh && install_plan "$1"' _ "$d" "$(dirname "$cli")" 2>&1)
[ "$plan" = $'.\tpnpm install --frozen-lockfile' ] || fail "install plan of a node workspace: $plan"

# A second run changes nothing; a command the project changed is kept, a dependency added to a manifest is read again.
cp "$d/.claude/senior-mode.json" "$work/before.json"
setup "$d"
cmp -s "$work/before.json" "$d/.claude/senior-mode.json" || fail "second run changed the config"
jq '.packages["packages/api"].commands.test = "pnpm run test:unit"' "$d/.claude/senior-mode.json" >"$work/c.json" && cp "$work/c.json" "$d/.claude/senior-mode.json"
put "$d/packages/shared/package.json" '{"name": "@x/shared", "dependencies": {"@x/api": "1"}, "scripts": {"lint": "eslint .", "test": "vitest"}}'
setup "$d"
expect "$d" '.packages["packages/api"].commands.test' '"pnpm run test:unit"'
expect "$d" '.packages["packages/shared"].deps' '["packages/api"]'

# npm workspaces: `workspaces` of package.json, as a list and as an object.
d=$(project npm)
put "$d/package.json" '{"name": "root", "workspaces": ["libs/*"]}'
put "$d/libs/a/package.json" '{"name": "a", "scripts": {"test": "jest"}}'
put "$d/libs/b/package.json" '{"name": "b", "dependencies": {"a": "*"}}'
setup "$d"
expect "$d" '.packages | keys' '["libs/a","libs/b"]'
expect "$d" '.packages["libs/b"].deps' '["libs/a"]'
expect "$d" '.packages["libs/a"].commands' '{"test":"npm run test"}'
d=$(project npm-object)
put "$d/package.json" '{"name": "root", "workspaces": {"packages": ["libs/*"]}}'
put "$d/libs/a/package.json" '{"name": "a"}'
setup "$d"
expect "$d" '.packages | keys' '["libs/a"]'

# A Cargo workspace: members by glob, an exclude, path dependencies directly, through a table and through the workspace.
d=$(project cargo)
put "$d/Cargo.toml" $'[workspace]\nmembers = [\n  "crates/*", # all\n]\nexclude = ["crates/old"]\n\n[workspace.dependencies]\nshared = { path = "crates/shared" }\n'
put "$d/crates/shared/Cargo.toml" $'[package]\nname = "shared"\n'
put "$d/crates/api/Cargo.toml" $'[package]\nname = "api"\n\n[dependencies]\nshared = { workspace = true }\nserde = "1"\n'
put "$d/crates/cli/Cargo.toml" $'[package]\nname = "cli"\n\n[dependencies.api]\npath = "../api"\n\n[dev-dependencies]\nshared = { path = "../shared" }\n\n[lib]\npath = "src/lib.rs"\n'
put "$d/crates/old/Cargo.toml" $'[package]\nname = "old"\n'
setup "$d"
expect "$d" '.packages | keys' '["crates/api","crates/cli","crates/shared"]'
expect "$d" '.packages["crates/api"].deps' '["crates/shared"]'
expect "$d" '.packages["crates/cli"].deps' '["crates/api","crates/shared"]'
expect "$d" '.packages["crates/cli"].preset' '"rust"'
expect "$d" '.packages["crates/cli"].commands | keys' '["build","format","lint","test"]'
plan=$(bash -c 'cd "$1" && . "$2"/lib/common.sh && . "$2"/lib/setup.sh && . "$2"/lib/packages.sh && install_plan "$1"' _ "$d" "$(dirname "$cli")" 2>&1)
[ "$plan" = $'.\tcargo fetch' ] || fail "install plan of a Cargo workspace: $plan"
cp "$d/.claude/senior-mode.json" "$work/before.json"
setup "$d"
cmp -s "$work/before.json" "$d/.claude/senior-mode.json" || fail "second run changed the Cargo config"

# Go: two modules with no go.work, one requiring the other through a replace, and the install of each module.
d=$(project go)
put "$d/lib/go.mod" $'module example.com/lib\n\ngo 1.22\n'
put "$d/svc/go.mod" $'module example.com/svc\n\ngo 1.22\n\nrequire (\n\texample.com/lib v0.0.0\n)\n\nreplace example.com/lib => ../lib\n'
put "$d/tools/vendor/x/go.mod" $'module example.com/vendored\n'
put "$d/svc/.golangci.yml" 'linters: {}'
setup "$d"
expect "$d" '.packages | keys' '["lib","svc"]'
expect "$d" '.packages.svc.deps' '["lib"]'
expect "$d" '.packages.lib.deps' '[]'
expect "$d" '.packages.svc.commands.lint' '"go vet ./... && golangci-lint run"'
expect "$d" '.packages.lib.commands.install' '"go mod download"'
plan=$(bash -c 'cd "$1" && . "$2"/lib/common.sh && . "$2"/lib/setup.sh && . "$2"/lib/packages.sh && install_plan "$1"' _ "$d" "$(dirname "$cli")" 2>&1)
[ "$plan" = $'lib\tgo mod download\nsvc\tgo mod download' ] || fail "install plan of Go modules: $plan"
cp "$d/.claude/senior-mode.json" "$work/before.json"
setup "$d"
cmp -s "$work/before.json" "$d/.claude/senior-mode.json" || fail "second run changed the Go config"

# A go.work lists the modules, and the requirement of a module on another is a dependency without any replace.
d=$(project gowork)
put "$d/go.work" $'go 1.22\n\nuse (\n\t./a\n\t./b\n)\n'
put "$d/a/go.mod" $'module example.com/a\n'
put "$d/b/go.mod" $'module example.com/b\n\nrequire example.com/a v0.1.0\n'
put "$d/c/go.mod" $'module example.com/c\n'
setup "$d"
expect "$d" '.packages | keys' '["a","b"]'
expect "$d" '.packages.b.deps' '["a"]'

# A Go repository with the root module and a second one: both are packages, the root installs once.
d=$(project go-root)
put "$d/go.mod" $'module example.com/root\n'
put "$d/tools/go.mod" $'module example.com/tools\n\nrequire example.com/root v0.0.0\n'
setup "$d"
expect "$d" '.packages | keys' '[".","tools"]'
expect "$d" '.packages.tools.deps' '["."]'
plan=$(bash -c 'cd "$1" && . "$2"/lib/common.sh && . "$2"/lib/setup.sh && . "$2"/lib/packages.sh && install_plan "$1"' _ "$d" "$(dirname "$cli")" 2>&1)
[ "$plan" = $'.\tgo mod download\ntools\tgo mod download' ] || fail "install plan of a Go root with a module: $plan"

# No workspace, no packages key: a plain node project, a single Go module, a Cargo project, an empty workspaces list.
d=$(project plain-node)
put "$d/package.json" '{"name": "app", "workspaces": []}'
put "$d/sub/package.json" '{"name": "sub"}'
setup "$d"
expect "$d" 'has("packages")' false
d=$(project plain-go)
put "$d/go.mod" $'module example.com/one\n'
setup "$d"
expect "$d" 'has("packages")' false
d=$(project plain-cargo)
put "$d/Cargo.toml" $'[package]\nname = "one"\n'
setup "$d"
expect "$d" 'has("packages")' false
! grep -q '^packages:' "$work/out" || fail "packages reported for a repository with none"

[ "$failures" -eq 0 ] && echo "setup-packages: all cases pass"
exit "$failures"
