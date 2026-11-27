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

# A package that already has a version is the last release: the manifest holds it (project or poetry table).
d=$(project versioned 'pyproject.toml=[build-system]
requires = ["hatchling"]
[project] # metadata
name = "app"
version = "0.7.2"
dependencies = ["pytest>=8"]')
setup "$d"
[ "$(jq -r '."."' "$d/.release-please-manifest.json")" = 0.7.2 ] || fail "manifest not seeded from pyproject.toml: $(cat "$d/.release-please-manifest.json")"
[ "$(jq -r '.packages["."]["initial-version"]' "$d/release-please-config.json")" = 0.1.0 ] || fail "initial-version taken from pyproject.toml"
grep -q "first release follows 0.7.2 (pyproject.toml)" "$work/out" || fail "seeded version not reported: $(cat "$work/out")"
d=$(project poetry-versioned 'pyproject.toml=[tool.poetry]
name = "app"
version = "2.0.1"')
setup "$d"
[ "$(jq -r '."."' "$d/.release-please-manifest.json")" = 2.0.1 ] || fail "manifest not seeded from [tool.poetry]"
d=$(project dynamic 'pyproject.toml=[project]
name = "app"
dynamic = ["version"]')
setup "$d"
[ "$(jq -r '."."' "$d/.release-please-manifest.json")" = 0.0.0 ] || fail "a dynamic version was invented"

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
for g in '**/migrations/**' '**/auth/**' '**/security/**' '.github/workflows/**' 'Dockerfile*' 'infra/**' '.claude/secret-allowlist' '.claude/ratchet-baseline.json' '.claude/architecture-baseline.json' '.claude/senior-mode.json'; do
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

# coverage run + coverage xml, Cobertura at coverage.xml; the project's own command is kept (#494).
d=$(project covpytest 'pyproject.toml=[project]
name = "app"
dependencies = ["pytest>=8"]' uv.lock)
setup "$d"
[ "$(cfg "$d" .commands.coverage)" = "uv run coverage run -m pytest && uv run coverage xml" ] || fail "python coverage command: $(cfg "$d" .commands.coverage)"
[ "$(cfg "$d" .ratchet.coverage.report)" = coverage.xml ] || fail "report not named: $(cfg "$d" .ratchet.coverage.report)"
[ -z "$(check_run "$d" coverage)" ] || fail "coverage became a check"
coverage_read "$d" '<?xml version="1.0"?><coverage line-rate="0.5"><packages><package name="a"><classes><class name="a" filename="a.py" line-rate="0.5"><lines/></class></classes></package></packages></coverage>'
d=$(project covplain 'pyproject.toml=[project]
name = "app"')
setup "$d"
[ "$(cfg "$d" .commands.coverage)" = "coverage run -m unittest && coverage xml" ] || fail "python coverage without pytest: $(cfg "$d" .commands.coverage)"
d=$(project covown 'pyproject.toml=[project]
name = "app"')
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

# The python pack (#733): listed, never written; the packs are named in the config.
d=$(project packnew 'pyproject.toml=[project]
name = "app"')
setup "$d"
for want in "rules: mypy strict: proposed" "rules: ruff BLE: proposed" "rules: ruff T20: proposed" "rules: ruff C90: proposed" "rules: ruff PLR: proposed" "rules: ruff format: proposed"; do
  grep -qF "$want" "$work/out" || fail "pack line '$want' missing: $(cat "$work/out")"
done
[ "$(cfg "$d" '.rules.packs | join(",")')" = python ] || fail "packs not named: $(cfg "$d" .rules)"
[ ! -e "$d/ruff.toml" ] && [ ! -e "$d/mypy.ini" ] || fail "the pack wrote a tool config"
d=$(project packold 'pyproject.toml=[project]
name = "app"
[tool.ruff.lint]
select = ["E", "BLE001"]
[tool.mypy]
strict = true' 'src/app.py=print(1)' uv.lock)
cp "$d/pyproject.toml" "$work/pyproject.before"
adopt_report "$d"
# shellcheck disable=SC2016 # the backticks of the markdown report
for want in '`mypy strict`: covered by your config' '`ruff BLE`: covered by your config' '`ruff T20`: proposed' '`ruff PLR`: proposed' '`ruff format`: covered by your config'; do
  grep -qF -- "$want" "$work/body" || fail "adoption report without '$want': $(cat "$work/body")"
done
cmp -s "$work/pyproject.before" "$d/pyproject.toml" || fail "adopt changed pyproject.toml"
grep -qx "pyproject.toml\|ruff.toml\|mypy.ini" "$work/changed" && fail "the adoption pull request changes a project file: $(cat "$work/changed")"

[ "$failures" -eq 0 ] && echo "setup-python: all cases pass"
exit "$failures"
