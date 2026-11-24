#!/usr/bin/env bash
# Tests for `senior-mode setup detect` and `setup answers`. Offline: gh is a stub.
set -u
cli=$(cd "$(dirname "$0")/.." && pwd)/senior-mode
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

mkdir -p "$work/stub" "$work/home"
cat >"$work/stub/gh" <<'STUB'
#!/usr/bin/env bash
jqf="" prev=""
for a in "$@"; do [ "$prev" = --jq ] && jqf=$a; prev=$a; done
respond() { if [ -n "$jqf" ]; then jq -r "$jqf"; else cat; fi; }
case "$*" in
  "api repos/acme/app --jq"*) echo "{\"owner\": {\"type\": \"${OWNER_TYPE:-User}\"}, \"private\": ${PRIVATE:-true}}" | respond ;;
  "api user --jq"*) echo "{\"login\": \"acme\", \"plan\": {\"name\": \"${PLAN:-free}\"}}" | respond ;;
  "api orgs/acme --jq"*) echo "{\"plan\": {\"name\": \"${PLAN:-free}\"}}" | respond ;;
  *) echo "gh: unexpected call: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$work/stub/gh"
export PATH="$work/stub:$PATH" HOME="$work/home" SENIOR_MODE_RETRY_DELAY=0 LANG=C LC_ALL=C

repo="$work/app"
git init -q -b main "$repo"
git -C "$repo" remote add origin git@github.com:acme/app.git
sm() { (cd "$repo" && "$cli" "$@"); }

# Detection: stack, visibility, plan, language.
cat >"$repo/package.json" <<'JSON'
{"scripts": {"test": "vitest"}, "dependencies": {"next": "14.2.0"}, "devDependencies": {"typescript": "5.0.0"}}
JSON
printf 'Le projet est pour les clients. Il faut que les tests passent dans la CI.\n' >"$repo/CLAUDE.md"
out=$(sm setup detect) || fail "detect failed"
grep -q '^stack: node (next, TypeScript)$' <<<"$out" || fail "stack not detected: $out"
grep -q '^repository: private, owned by a user, plan free$' <<<"$out" || fail "visibility and plan not detected: $out"
grep -q '^branch rules: not enforced' <<<"$out" || fail "free private repository not flagged: $out"
grep -q '^language: fr (from the project CLAUDE.md)$' <<<"$out" || fail "language not read from CLAUDE.md: $out"
[ ! -e "$repo/.claude/senior-mode.json" ] || fail "detect wrote the config"
out=$(PRIVATE=false sm setup detect --json)
jq -e '.github.visibility == "public" and .github.rulesets == "yes" and .stack.preset == "node"' <<<"$out" >/dev/null || fail "public repository: $out"
out=$(OWNER_TYPE=Organization PLAN=team sm setup detect --json)
jq -e '.github.ownerType == "Organization" and .github.plan == "team" and .github.rulesets == "yes"' <<<"$out" >/dev/null || fail "paid organization: $out"
sm setup detect --bogus >/dev/null 2>&1 && fail "detect accepted an unknown option"

# Dry run: the summary, nothing written.
out=$(sm setup answers --dry-run) || fail "dry run failed: $out"
for want in '^Detected' '^Your answers' 'process: strict \(recommended\)' 'language: fr \(recommended\)' 'agents alone: no \(recommended\)' \
  '^Defaults' 'risky changes: you decide' 'Dry run: nothing written'; do
  grep -Eq "$want" <<<"$out" || fail "summary lacks $want: $out"
done
[ ! -e "$repo/.claude/senior-mode.json" ] || fail "dry run wrote the config"

# Recommended answers: the config only holds the language and the autonomy.
sm setup answers >"$work/out" 2>&1 || fail "answers failed: $(cat "$work/out")"
[ "$(jq -c '{language, process, merge: .autonomy.merge}' "$repo/.claude/senior-mode.json")" = '{"language":"fr","process":null,"merge":false}' ] ||
  fail "recommended answers: $(cat "$repo/.claude/senior-mode.json")"
sm config validate >"$work/out" 2>&1 || fail "config not valid: $(cat "$work/out")"
before=$(cat "$repo/.claude/senior-mode.json")
sm setup answers >/dev/null 2>&1
[ "$before" = "$(cat "$repo/.claude/senior-mode.json")" ] || fail "a rerun changed the config"

# Explicit answers: fast with its ADR, English, agents alone. The existing keys stay.
echo '{"preset": "node", "wip": 2}' >"$repo/.claude/senior-mode.json"
mkdir -p "$repo/docs/adr"
echo '---
id: 0007
status: accepted
---' >"$repo/docs/adr/0007-something.md"
sm setup answers --strictness fast --language en --autonomy alone >"$work/out" 2>&1 || fail "fast answers failed: $(cat "$work/out")"
grep -q 'written: docs/adr/0008-lift-independent-review.md' "$work/out" || fail "ADR not written: $(cat "$work/out")"
[ "$(jq -c '[.language, .wip, .process.profile, .process.lifts[0].rule, .process.lifts[0].adr, .autonomy.merge]' "$repo/.claude/senior-mode.json")" = \
  '["en",2,"fast","review","docs/adr/0008-lift-independent-review.md",true]' ] || fail "fast answers: $(cat "$repo/.claude/senior-mode.json")"
grep -q '^status: accepted$' "$repo/docs/adr/0008-lift-independent-review.md" || fail "ADR not accepted"
sm config validate >"$work/out" 2>&1 || fail "fast config not valid: $(cat "$work/out")"
[ "$(sm config get process.gates.review)" = false ] || fail "the review gate is not lifted"
sm setup answers >"$work/out" 2>&1
[ ! -e "$repo/docs/adr/0009-lift-independent-review.md" ] || fail "a rerun wrote a second ADR"
grep -q 'process: fast' "$work/out" || fail "a rerun lost the stored answer: $(cat "$work/out")"

# Back to strict: no process key, the other keys stay.
sm setup answers --strictness strict >/dev/null 2>&1 || fail "strict answer failed"
jq -e 'has("process") | not' "$repo/.claude/senior-mode.json" >/dev/null || fail "strict kept process: $(cat "$repo/.claude/senior-mode.json")"
[ "$(jq -r .wip "$repo/.claude/senior-mode.json")" = 2 ] || fail "strict dropped a key"

# A bad answer is refused, and an invalid config is not overwritten.
sm setup answers --strictness lax >/dev/null 2>&1 && fail "accepted an unknown strictness"
sm setup answers --language de >/dev/null 2>&1 && fail "accepted an unknown language"
echo '{bad' >"$repo/.claude/senior-mode.json"
sm setup answers >/dev/null 2>&1 && fail "wrote over an invalid config"

[ "$failures" -eq 0 ] && echo "ok" || exit 1
