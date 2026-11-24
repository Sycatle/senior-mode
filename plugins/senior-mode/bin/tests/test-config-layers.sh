#!/usr/bin/env bash
# Tests for the configuration layers, the overrides and the process profiles (#307). Offline.
set -u
bin=$(cd "$(dirname "$0")/.." && pwd)
cli=$bin/senior-mode
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

git init -q --bare -b main "$work/origin.git"
repo="$work/repo"
git clone -q "$work/origin.git" "$repo" 2>/dev/null
git -C "$repo" config user.email t@example.com
git -C "$repo" config user.name t
git -C "$repo" checkout -q -b main
mkdir -p "$repo/.claude" "$repo/docs/adr"
config() { printf '%s\n' "$1" >"$repo/.claude/senior-mode.json"; }
run() { (cd "$repo" && "$cli" "$@") >"$work/out" 2>"$work/err"; }
base_run() { (cd "$repo" && SENIOR_MODE_CONFIG_SOURCE=base "$cli" "$@") >"$work/out" 2>"$work/err"; }
adr() { printf -- '---\nid: %s\ntitle: lift\nstatus: %s\n---\nbody\n' "$1" "$2" >"$repo/docs/adr/$1-lift.md"; }
publish() { git -C "$repo" add -A && git -C "$repo" commit -qm "$1" && git -C "$repo" push -q origin main 2>/dev/null; }
reset_layers() { rm -rf "$repo/.git/senior-mode" "$repo/.claude/senior-mode.local.json" "$repo/.claude/senior-mode"; }

config '{"wip": 4}'
publish base

# A: explain names the winning layer and the shadowed values.
run config explain wip || fail "A: explain failed: $(cat "$work/err")"
{ grep -q '^wip = 4$' "$work/out" && grep -q '^winner: repository' "$work/out"; } || fail "A: wrong winner: $(cat "$work/out")"
grep -q 'defaults .*1 .*shadowed by repository' "$work/out" || fail "A: the default is not shown as shadowed: $(cat "$work/out")"
echo '{"wip": 7}' >"$repo/.claude/senior-mode.local.json"
run config explain wip
{ grep -q '^winner: local' "$work/out" && grep -q 'repository .*4 .*shadowed by local' "$work/out"; } || fail "A: the local file does not win: $(cat "$work/out")"
[ "$(cd "$repo" && "$cli" config get wip)" = 7 ] || fail "A: config get ignores the local layer"
mkdir -p "$repo/.git/senior-mode"
echo '{"wip": 2, "language": "fr"}' >"$repo/.git/senior-mode/organization.json"
run config explain language
grep -q '^winner: organization' "$work/out" || fail "A: the organization layer is not read: $(cat "$work/out")"
run config explain nope.key && fail "A: an unknown key was explained"
grep -q 'unknown config key' "$work/err" || fail "A: unknown key not named: $(cat "$work/err")"
reset_layers

# B: a profile that lifts a locked gate needs an accepted ADR of the repository, named in the config.
config '{"wip": 4, "process": {"profile": "fast"}}'
[ "$(cd "$repo" && "$cli" config get process.gates.review)" = true ] || fail "B: the review gate is lifted without an ADR"
run config validate && fail "B: a lift without an ADR was accepted"
grep -q 'lifting needs an accepted ADR' "$work/out" || fail "B: the refusal has no reason: $(cat "$work/out")"
config '{"wip": 4, "process": {"profile": "fast", "lifts": [{"rule": "review", "adr": "docs/adr/0016-lift.md"}]}}'
run config validate && fail "B: a lift naming a missing ADR was accepted"
grep -q 'not found' "$work/out" || fail "B: missing ADR not said: $(cat "$work/out")"
adr 0016 proposed
run config validate && fail "B: a lift naming a proposed ADR was accepted"
grep -q 'proposed, not accepted' "$work/out" || fail "B: proposed ADR not said: $(cat "$work/out")"
[ "$(cd "$repo" && "$cli" config get process.gates.review)" = true ] || fail "B: the gate is lifted by a proposed ADR"
adr 0016 accepted
run config validate || fail "B: an accepted ADR is refused: $(cat "$work/out")"
[ "$(cd "$repo" && "$cli" config get process.gates.review)" = false ] || fail "B: the accepted lift does not hold"
[ "$(cd "$repo" && "$cli" config get process.gates.secretScan)" = true ] || fail "B: a gate that nothing lifts is open"
[ "$(cd "$repo" && "$cli" config get process.profile)" = fast ] || fail "B: the profile is not fast"
# Another layer cannot carry a lift, and a gate that cannot be lifted is refused.
config '{"wip": 4}'
echo '{"process": {"profile": "fast", "lifts": [{"rule": "review", "adr": "docs/adr/0016-lift.md"}]}}' >"$repo/.claude/senior-mode.local.json"
[ "$(cd "$repo" && "$cli" config get process.gates.review)" = true ] || fail "B: a local file lifted a gate"
run config validate
grep -q 'repository layer only' "$work/out" || fail "B: the local lift is not flagged: $(cat "$work/out")"
rm -f "$repo/.claude/senior-mode.local.json"
mkdir -p "$repo/.claude/senior-mode/profiles"
echo '{"extends": "strict", "gates": {"secretScan": false}}' >"$repo/.claude/senior-mode/profiles/open.json"
config '{"process": {"profile": "open", "lifts": [{"rule": "secretScan", "adr": "docs/adr/0016-lift.md"}]}}'
run config validate && fail "B: the secret scan was lifted"
grep -q 'secretScan' "$work/out" || fail "B: the refusal does not name the gate: $(cat "$work/out")"
[ "$(cd "$repo" && "$cli" config get process.gates.secretScan)" = true ] || fail "B: the secret scan gate is open"
config '{"process": {"profile": "nope"}}'
run config validate && fail "B: an unknown profile was accepted"
grep -q "unknown process profile 'nope'" "$work/out" || fail "B: unknown profile not named: $(cat "$work/out")"
reset_layers

# C: a custom profile derived from strict.
mkdir -p "$repo/.claude/senior-mode/profiles"
echo '{"extends": "strict", "description": "team", "config": {"wip": 2, "autonomy": {"maxTickets": 1}}}' >"$repo/.claude/senior-mode/profiles/team.json"
config '{"process": {"profile": "team"}}'
run config validate || fail "C: a custom profile is refused: $(cat "$work/out")"
[ "$(cd "$repo" && "$cli" config get wip)" = 2 ] || fail "C: the profile's config is not applied"
[ "$(cd "$repo" && "$cli" config get autonomy.maxTickets)" = 1 ] || fail "C: the profile's nested config is not applied"
[ "$(cd "$repo" && "$cli" config get autonomy.sessionTimeout)" = "$(cd "$repo" && jq -r .autonomy.sessionTimeout <<<"$(bash -c '. "$1"; printf "%s" "$DEFAULTS"' _ "$bin/lib/common.sh")")" ] ||
  fail "C: the objects do not merge key by key"
[ "$(cd "$repo" && "$cli" config get process.gates.review)" = true ] || fail "C: a profile derived from strict opens the review"
config '{"wip": 6, "process": {"profile": "team"}}'
run config explain wip
{ grep -q '^winner: repository' "$work/out" && grep -q 'profile .*2 .*shadowed by repository' "$work/out"; } || fail "C: the repository does not win over the profile: $(cat "$work/out")"
echo '{"extends": "team", "config": {"wopp": 1}}' >"$repo/.claude/senior-mode/profiles/team.json"
run config validate && fail "C: an unknown key in a profile was accepted"
echo '{"extends": "team"}' >"$repo/.claude/senior-mode/profiles/team.json"
run config validate && fail "C: a profile that extends itself was accepted"
reset_layers

# D: overrides replace or append, only for skills, agents and templates, and a session is told of them.
config '{"wip": 4}'
mkdir -p "$repo/.claude/senior-mode/overrides/skills/review" "$repo/.claude/senior-mode/overrides/agents" "$repo/.claude/senior-mode/overrides/hooks"
echo "PROJECT-APPEND-RULE" >"$repo/.claude/senior-mode/overrides/skills/review/SKILL.append.md"
echo "PROJECT-REPLACED-REVIEWER" >"$repo/.claude/senior-mode/overrides/agents/reviewer.md"
run override list || fail "D: override list failed: $(cat "$work/err")"
{ grep -q 'skills/review/SKILL.md .*append' "$work/out" && grep -q 'agents/reviewer.md .*replace' "$work/out"; } || fail "D: list is wrong: $(cat "$work/out")"
run override show skills/review/SKILL.md
{ grep -q 'PROJECT-APPEND-RULE' "$work/out" && grep -q '^name: review' "$work/out"; } || fail "D: append lost the plugin text or the addition: $(head -5 "$work/out")"
run override show agents/reviewer.md
{ grep -q 'PROJECT-REPLACED-REVIEWER' "$work/out" && ! grep -q '^name: reviewer' "$work/out"; } || fail "D: replace kept the plugin text: $(head -5 "$work/out")"
run override show hooks/hooks.json && fail "D: a hook was shown as overridable"
run context
{ grep -q 'PROJECT-APPEND-RULE' "$work/out" && grep -q 'PROJECT-REPLACED-REVIEWER' "$work/out"; } || fail "D: the session context lacks the overrides: $(cat "$work/out")"
run config validate || fail "D: valid overrides are refused: $(cat "$work/out")"
echo x >"$repo/.claude/senior-mode/overrides/skills/reveiw.md"
echo x >"$repo/.claude/senior-mode/overrides/hooks/guard.sh"
run config validate && fail "D: stray override files were accepted"
grep -q 'did you mean skills/review/SKILL.md' "$work/out" || grep -q 'did you mean skills/review' "$work/out" || fail "D: closest file not offered: $(cat "$work/out")"
grep -q 'hooks/guard.sh.*safety base' "$work/out" || fail "D: a hook override is not refused: $(cat "$work/out")"
reset_layers

# E: the daemon reads the base branch, never the working tree or a head; an invalid config keeps the last valid one.
config '{"wip": 4}'
publish "wip 4"
config '{"wip": 9}'
[ "$(cd "$repo" && "$cli" config get wip)" = 9 ] || fail "E: a person does not read the working tree"
[ "$(cd "$repo" && SENIOR_MODE_CONFIG_SOURCE=base "$cli" config get wip)" = 4 ] || fail "E: the base mode read the working tree"
[ "$(cd "$repo" && SENIOR_MODE_RUN=1 "$cli" config get wip)" = 4 ] || fail "E: a run reads something else than the base"
config '{"wip": 4, "process": {"profile": "fast", "lifts": [{"rule": "review", "adr": "docs/adr/0016-lift.md"}]}}'
[ "$(cd "$repo" && SENIOR_MODE_CONFIG_SOURCE=base "$cli" config get process.gates.review)" = true ] || fail "E: a lift that is not on the base branch holds"
git -C "$repo" checkout -q -- .claude/senior-mode.json
rm -f "$repo/docs/adr/0016-lift.md"
config '{"wip": 4, "process": {"profile": "fast", "lifts": [{"rule": "review", "adr": "docs/adr/0016-lift.md"}]}}'
adr 0016 accepted
publish "lift"
[ "$(cd "$repo" && SENIOR_MODE_CONFIG_SOURCE=base "$cli" config get process.gates.review)" = false ] || fail "E: a lift with its ADR on the base does not hold"
config '{"wip": 5, "wipp": 1}'
publish "bad key"
base_run config get wip
[ "$(cat "$work/out")" = 4 ] || fail "E: the last valid config is not kept: $(cat "$work/out") $(cat "$work/err")"
grep -q 'keeping the last valid config' "$work/err" || fail "E: nothing said on stderr: $(cat "$work/err")"
base_run config get wip
[ ! -s "$work/err" ] || fail "E: the fault is said twice: $(cat "$work/err")"
config '{"wip": 5}'
publish "fixed"
base_run config get wip
{ [ "$(cat "$work/out")" = 5 ] && grep -q 'valid again' "$work/err"; } || fail "E: the new config is not taken: $(cat "$work/out") $(cat "$work/err")"
reset_layers

# F: status carries one line on a customized process; a lift is flagged.
config '{"wip": 4, "process": {"profile": "fast", "lifts": [{"rule": "review", "adr": "docs/adr/0016-lift.md"}]}}'
summary=$(cd "$repo" && bash -c '. "$1/lib/common.sh"; . "$1/lib/config.sh"; SELF=$2; LIB=$1/lib; process_summary' _ "$bin" "$cli")
[ "$(jq -r '.profile' <<<"$summary")" = fast ] && [ "$(jq -r '.lifted[0].rule' <<<"$summary")" = review ] ||
  fail "F: the process summary is wrong: $summary"
reset_layers

[ "$failures" -eq 0 ] && echo "config layers: all cases pass"
exit "$failures"
