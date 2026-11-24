#!/usr/bin/env bash
# Tests for `senior-mode doctor` (#316): gh and claude are stubs, nothing touches the network.
set -u
bin=$(cd "$(dirname "$0")/.." && pwd)
cli=$bin/senior-mode
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

stubs="$work/stubs"
mkdir -p "$stubs"
cat >"$stubs/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "--version "*) echo "gh version 2.65.0 (2025-01-06)" ;;
  "auth status")
    [ "${GH_STUB_AUTH:-ok}" = ok ] || { echo "You are not logged into any GitHub hosts. To log in, run: gh auth login" >&2; exit 1; }
    echo "github.com"
    echo "  - Token scopes: ${GH_STUB_SCOPES:-'repo', 'project', 'workflow'}"
    ;;
  "api repos/o/r/rulesets") [ "${GH_STUB_RULESETS:-1}" != fail ] || exit 1; echo "${GH_STUB_RULESETS:-1}" ;;
  *) exit 1 ;;
esac
EOF
cat >"$stubs/claude" <<'EOF'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "--version ") echo "2.1.311 (Claude Code)" ;;
  "auth status") echo "{\"loggedIn\": ${CLAUDE_STUB_LOGGED:-true}, \"authMethod\": \"claude.ai\"}" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$stubs/gh" "$stubs/claude"

repo="$work/repo"
git init -q -b main "$repo"
git -C "$repo" remote add origin git@github.com:o/r.git
mkdir -p "$repo/.claude" "$repo/.githooks" "$repo/docs/adr"
for h in pre-push commit-msg; do
  printf '#!/bin/sh\n# senior-mode hook\nexit 0\n' >"$repo/.githooks/$h"
  chmod +x "$repo/.githooks/$h"
done
git -C "$repo" config core.hooksPath .githooks
good='{"preset":"generic","github":{"protection":"ruleset"},"project":{"owner":"o","number":3,"id":"P","fields":{"Status":{"id":"S"},"Priority":{"id":"P"},"Size":{"id":"Z"},"Severity":{"id":"V"}}}}'
config() { printf '%s\n' "$1" >"$repo/.claude/senior-mode.json"; }
doctor() { (cd "$repo" && PATH="$stubs:$PATH" "$cli" doctor "$@") >"$work/out" 2>"$work/err"; }
expect_fail() { # case what fix
  doctor && fail "$1: doctor exited 0"
  grep -q "$2" "$work/out" || fail "$1: '$2' not in the output: $(cat "$work/out")"
  grep -q "fix: $3" "$work/out" || fail "$1: the fix '$3' is not printed: $(cat "$work/out")"
}

# A: everything in place: exit 0, every line ok, nothing overridden.
config "$good"
doctor || fail "A: doctor failed: $(cat "$work/out" "$work/err")"
for c in 'gh auth' 'claude login' 'git hooks' config 'board fields' ruleset; do
  grep -q "ok .*$c" "$work/out" || fail "A: $c is not ok: $(cat "$work/out")"
done
grep -q 'senior-mode plugin' "$work/out" || fail "A: no version line: $(cat "$work/out")"
grep -q 'nothing overridden' "$work/out" || fail "A: customization not said: $(cat "$work/out")"
doctor --json && [ "$(jq -r '.ok' "$work/out")" = true ] && [ "$(jq -r '.customization.nothing' "$work/out")" = true ] || fail "A: --json wrong: $(cat "$work/out")"
doctor --bogus && fail "A: an unknown option was accepted"

# B: gh and claude.
GH_STUB_AUTH=no expect_fail "B1" 'gh is not logged in' 'gh auth login'
GH_STUB_SCOPES="'repo', 'gist'" expect_fail "B2" 'lacks the scope project' 'gh auth refresh -s repo -s project'
GH_STUB_SCOPES="'repo', 'read:project'" expect_fail "B3" 'lacks the scope project' 'gh auth refresh'
CLAUDE_STUB_LOGGED=false expect_fail "B4" 'not logged in' 'claude auth login'
doctor --json
[ "$(jq -r '[.checks[] | select(.level == "fail")] | length' "$work/out")" = 0 ] || fail "B5: the stubs leaked between cases"

# C: git hooks.
rm "$repo/.githooks/pre-push"
expect_fail "C1" 'pre-push missing' 'senior-mode setup repo'
printf '#!/bin/sh\nexit 0\n' >"$repo/.githooks/pre-push"
chmod +x "$repo/.githooks/pre-push"
expect_fail "C2" "pre-push is not senior-mode's" 'senior-mode setup repo'
printf '#!/bin/sh\n# senior-mode hook\n' >"$repo/.githooks/pre-push"
rm "$repo/.githooks/commit-msg"
doctor || fail "C3: a missing commit-msg fails: $(cat "$work/out")"
grep -q 'warn .*commit-msg missing' "$work/out" || fail "C3: no warning: $(cat "$work/out")"
printf '#!/bin/sh\n# senior-mode hook\n' >"$repo/.githooks/commit-msg"
chmod +x "$repo/.githooks/commit-msg"

# D: config validity: the unknown key and its closest, a deprecated value as a warning only.
config "$(jq -c '.autonomy = {"maxTicket": 3}' <<<"$good")"
expect_fail "D1" 'did you mean maxTickets' 'edit .claude/senior-mode.json: maxTickets'
config "$(jq -c '.preset = "typescript"' <<<"$good")"
doctor || fail "D2: a deprecated value fails: $(cat "$work/out")"
grep -q 'warn .*"typescript" is deprecated' "$work/out" || fail "D2: no warning: $(cat "$work/out")"
rm "$repo/.claude/senior-mode.json"
expect_fail "D3" 'no .claude/senior-mode.json' '/senior-mode:setup'

# E: the board and the ruleset.
config "$(jq -c 'del(.project.fields.Size)' <<<"$good")"
expect_fail "E1" 'lacks the fields Size' 'senior-mode setup github'
config "$good"
GH_STUB_RULESETS=0 expect_fail "E2" 'no active senior-mode ruleset' 'senior-mode setup github'
GH_STUB_RULESETS=fail doctor || fail "E3: an unreadable ruleset fails"
grep -q 'warn .*could not read the rulesets' "$work/out" || fail "E3: no warning: $(cat "$work/out")"

config "$(jq -c '.github.protection = "local"' <<<"$good")"
doctor || fail "E4: github.protection local fails"
grep -q 'warn .*github.protection is local' "$work/out" || fail "E4: no warning for local: $(cat "$work/out")"
config "$good"

# F: customization: a lift names its ADR, a refused one fails; overrides and layer values are listed.
printf -- '---\nid: 0016\nstatus: proposed\n---\n' >"$repo/docs/adr/0016-lift.md"
config "$(jq -c '.process = {profile: "fast", lifts: [{rule: "review", adr: "docs/adr/0016-lift.md"}]}' <<<"$good")"
expect_fail "F1" 'proposed, not accepted' 'make the ADR of the lift'
printf -- '---\nid: 0016\nstatus: accepted\n---\n' >"$repo/docs/adr/0016-lift.md"
mkdir -p "$repo/.claude/senior-mode/overrides/skills/review"
echo "extra" >"$repo/.claude/senior-mode/overrides/skills/review/SKILL.append.md"
config "$(jq -c '.wip = 2 | .process = {profile: "fast", lifts: [{rule: "review", adr: "docs/adr/0016-lift.md"}]}' <<<"$good")"
doctor || fail "F2: an accepted lift fails: $(cat "$work/out")"
grep -q 'profile: fast (plugin, extends strict)' "$work/out" || fail "F2: profile missing: $(cat "$work/out")"
grep -q 'LIFTED review: docs/adr/0016-lift.md (accepted' "$work/out" || fail "F2: lift missing: $(cat "$work/out")"
grep -q 'override skills/review/SKILL.md (append)' "$work/out" || fail "F2: override missing: $(cat "$work/out")"
grep -q 'repository: wip = 2' "$work/out" || fail "F2: layer value missing: $(cat "$work/out")"
grep -q 'nothing overridden' "$work/out" && fail "F2: says nothing is overridden"
echo '{"wip": 3}' >"$repo/.claude/senior-mode.local.json"
doctor
grep -q 'local: wip = 3' "$work/out" || fail "F3: the local layer is not listed: $(cat "$work/out")"

[ "$failures" -eq 0 ] && echo "doctor: all cases pass"
exit "$failures"
