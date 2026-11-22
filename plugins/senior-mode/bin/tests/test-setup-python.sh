#!/usr/bin/env bash
# Tests for the python preset of `senior-mode setup repo`: detection and commands from the files of
# the project. Offline: no Python tool is installed or run; they are only named in the checks.
set -u
cli=$(cd "$(dirname "$0")/.." && pwd)/senior-mode
preset=$(cd "$(dirname "$0")/../.." && pwd)/presets/python/preset.json
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }
project() { # name file=content... (a bare name makes an empty file)
  local dir="$work/$1" f
  git init -q -b main "$dir"
  shift
  for f in "$@"; do
    mkdir -p "$dir/$(dirname "${f%%=*}")"
    if [[ $f == *=* ]]; then printf '%s\n' "${f#*=}" >"$dir/${f%%=*}"; else : >"$dir/$f"; fi
  done
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

# A uv project with every tool, a build system and a lockfile.
d=$(project uv 'pyproject.toml=[build-system]
requires = ["hatchling"]
[project]
name = "app"
dependencies = ["mypy>=1.10", "pytest>=8"]
[tool.ruff]
line-length = 100' uv.lock)
setup "$d"
[ "$(cfg "$d" .preset)" = python ] || fail "python preset not chosen: $(cfg "$d" .preset)"
grep -q "^preset: python$" "$work/out" || fail "preset not reported: $(cat "$work/out")"
expect "$d" lint "uv run ruff check ."
expect "$d" format "uv run ruff format --check ."
expect "$d" typecheck "uv run mypy ."
expect "$d" test "uv run pytest"
expect "$d" build "uv run python -m build"
[ "$(jq -r '.packages["."]["release-type"]' "$d/release-please-config.json")" = python ] ||
  fail "release-please not set up for a python package"

# The "missing" report is for the node presets: a python project without tests is not told to add scripts.
d=$(project no-tests 'pyproject.toml=[tool.ruff]')
setup "$d"
! grep -q "^missing:" "$work/out" || fail "a missing command reported for python: $(cat "$work/out")"
[ "$(jq -r '.packages["."]["initial-version"]' "$d/release-please-config.json")" = 0.1.0 ] || fail "first release not 0.1.0"
cp "$d/.claude/senior-mode.json" "$work/before"
setup "$d"
cmp -s "$work/before" "$d/.claude/senior-mode.json" || fail "second run changed the config"

# Poetry, flake8 and black, pyright, no build system: no build check.
d=$(project poetry 'pyproject.toml=[tool.poetry]
name = "app"
[tool.poetry.group.dev.dependencies]
flake8 = "^7"
pytest = "^8"
[tool.black]
line-length = 100
[tool.pyright]
include = ["src"]' poetry.lock)
setup "$d"
expect "$d" lint "poetry run flake8"
expect "$d" format "poetry run black --check ."
expect "$d" typecheck "poetry run pyright"
expect "$d" test "poetry run pytest"
[ -z "$(check_run "$d" build)" ] || fail "build check without a build-system: $(check_run "$d" build)"

# requirements.txt only, tools in a file each: no runner prefix; pytest-cov is not pytest, and a
# lockfile of another tool is no runner.
d=$(project reqs 'requirements.txt=ruff==0.5.0
pytest-cov==5.0.0' 'mypy.ini=[mypy]
strict = True' setup.cfg poetry.lock.bak)
setup "$d"
[ "$(cfg "$d" .preset)" = python ] || fail "requirements.txt not detected: $(cfg "$d" .preset)"
expect "$d" lint "ruff check ."
expect "$d" format "ruff format --check ."
expect "$d" typecheck "mypy ."
[ -z "$(check_run "$d" test)" ] || fail "pytest-cov taken as pytest: $(check_run "$d" test)"

# flake8 from setup.cfg, pytest from pytest.ini; black wins over ruff for the format check.
d=$(project cfg 'setup.py=from setuptools import setup; setup()' 'setup.cfg=[flake8]
max-line-length = 100' 'pytest.ini=[pytest]' 'pyproject.toml=[tool.black]
[tool.ruff]')
setup "$d"
expect "$d" lint "ruff check ."
expect "$d" format "black --check ."
expect "$d" test "pytest"
d=$(project setuponly setup.py 'setup.cfg=[flake8]')
setup "$d"
[ "$(cfg "$d" .preset)" = python ] || fail "setup.py not detected: $(cfg "$d" .preset)"
expect "$d" lint "flake8"

# A project that names no tool still gets the preset, and its commit subjects check.
d=$(project bare pyproject.toml)
setup "$d"
[ "$(cfg "$d" .preset)" = python ] || fail "pyproject.toml alone not detected"
[ "$(jq -c '[.checks[].name]' "$d/.claude/senior-mode.json")" = '["commit subjects"]' ] ||
  fail "checks invented for a project without tools: $(cfg "$d" '[.checks[].name]')"

# Detection order: package.json keeps node; a stored preset wins (go.mod and Cargo.toml: their tests).
d=$(project withnode 'package.json={"scripts": {"test": "vitest run"}}' pyproject.toml)
setup "$d"
[ "$(cfg "$d" .preset)" = node ] || fail "package.json lost to pyproject.toml: $(cfg "$d" .preset)"
d=$(project stored pyproject.toml '.claude/senior-mode.json={"preset": "generic"}')
setup "$d"
[ "$(cfg "$d" .preset)" = generic ] || fail "stored preset lost to detection: $(cfg "$d" .preset)"

# Commands given or stored earlier win over detection; e2e is not a python command.
d=$(project override 'pyproject.toml=[tool.ruff]' uv.lock)
setup "$d" --command lint="make lint" --command format="make fmt"
expect "$d" lint "make lint"
expect "$d" format "make fmt"
setup "$d"
expect "$d" lint "make lint"
(cd "$d" && "$cli" setup repo --command e2e=x) 2>/dev/null && fail "python preset accepts e2e"

# Default protected zones: migrations, auth and security, CI, containers and infra; no lockfile.
jq -e '.protected | length > 0' "$preset" >/dev/null || fail "no protected globs in the preset"
for g in '**/migrations/**' '**/auth/**' '**/security/**' '.github/workflows/**' 'Dockerfile*' 'infra/**'; do
  jq -e --arg g "$g" '.protected | index($g)' "$preset" >/dev/null || fail "$g not protected by default"
done
jq -e '.protected | map(test("lock|requirements|pyproject")) | any' "$preset" >/dev/null &&
  fail "a lockfile or manifest is protected by default"

# The install command of a new worktree (#110): uv or poetry when their lockfile exists, else none.
for entry in "uv.lock:uv sync" "poetry.lock:poetry install"; do
  d=$(project "inst-${entry%%.*}" "pyproject.toml=[tool.ruff]" "${entry%%:*}=")
  setup "$d"
  [ "$(cfg "$d" .commands.install)" = "${entry#*:}" ] || fail "${entry%%:*}: install is $(cfg "$d" .commands.install)"
done
d=$(project inst-none "pyproject.toml=[tool.ruff]")
setup "$d"
[ "$(cfg "$d" '.commands.install // "none"')" = none ] || fail "python without a lockfile has an install command"

[ "$failures" -eq 0 ] && echo "setup-python: all cases pass"
exit "$failures"
