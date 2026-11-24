#!/usr/bin/env bash
# Tests for `senior-mode context` (SessionStart). Offline: gh is a stub answering from $GH_ISSUE.
set -u
cli=$(cd "$(dirname "$0")/.." && pwd)/senior-mode
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

mkdir -p "$work/stub"
cat >"$work/stub/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$GH_LOG"
[ -z "${GH_FAIL:-}" ] || exit 1
case "$*" in
  *"issue view"*) printf '%s\n' "$GH_ISSUE" ;;
  *"api graphql"*) printf '%s\n' "${GH_PATHS:-}" ;;
esac
STUB
chmod +x "$work/stub/gh"
export PATH="$work/stub:$PATH" GH_LOG="$work/gh.log"
# shellcheck disable=SC2016 # backticks are Markdown in the issue body
export GH_ISSUE='{"number":12,"title":"Let people log in","state":"OPEN","projectItems":[{"status":{"name":"In progress"}}],"body":"## What this gives\nLogin.\n\nSpec: `docs/specs/0003-login.md` §2.\n\n## Acceptance criteria\n- Given a user with an account, when they log in, then they see their dashboard.\n- Given a wrong password, when they log in, then they see an error.\n\n## Technical detail\nSessions."}'

repo="$work/repo"
git init -q -b main "$repo"
mkdir -p "$repo/.claude" "$repo/docs/specs"
printf -- '---\nid: 0003\nstatus: accepted\n---\n' >"$repo/docs/specs/0003-login.md"
git -C "$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "chore: start"
git -C "$repo" remote add origin https://github.com/o/r.git

context() { # dir -> $out; fails the test on a non-zero exit
  (cd "$1" && "$cli" context) >"$work/out" 2>"$work/err" || fail "context exited non-zero in $1: $(cat "$work/err")"
  out=$(cat "$work/out")
}

context "$work"
grep -q "senior-mode" <<<"$out" || fail "no router outside a repository: $out"
grep -q "Current ticket" <<<"$out" && fail "ticket outside a repository"

git -C "$repo" switch -q -c feat/12-login
context "$repo"
grep -q "/senior-mode:setup" <<<"$out" || fail "no setup hint without config: $out"
grep -q "Current ticket" <<<"$out" && fail "ticket without config: $out"

echo '{}' >"$repo/.claude/senior-mode.json"
git -C "$repo" switch -q main
: >"$GH_LOG"
context "$repo"
grep -q "Current ticket" <<<"$out" && fail "ticket on the default branch: $out"
[ -s "$GH_LOG" ] && fail "calls GitHub on the default branch"

git -C "$repo" switch -q feat/12-login
context "$repo"
for want in "#12 Let people log in" "In progress" "docs/specs/0003-login.md (accepted)" \
  "Given a user with an account" "Given a wrong password" "feat/12-login"; do
  grep -qF "$want" <<<"$out" || fail "missing '$want' in: $out"
done
grep -q "setup" <<<"$out" && fail "setup hint with a config: $out"
[ "$(wc -l <<<"$out")" -le 16 ] || fail "more than 16 lines: $(wc -l <<<"$out")"

GH_FAIL=1 context "$repo"
if ! grep -q "#12" <<<"$out" || ! grep -qi "not loaded" <<<"$out"; then fail "GitHub down: $out"; fi

# The vision (#342): its goal ids and non-goals come right after the router, before the ticket, so the start of
# the briefing is the same for every ticket; without the file nothing is added.
mkdir -p "$repo/docs"
printf '%s\n' '# Vision' '' '## Goals' '' '- G1: people log in in one click' '- G2: invoices are legally compliant' '' \
  '## Non-goals' '' '- No native mobile app' '- No on-premise edition' '' '## Constraints' '' '- EU hosting only' >"$repo/docs/vision.md"
context "$repo"
for want in "G1: people log in in one click" "G2: invoices are legally compliant" "No native mobile app" "No on-premise edition"; do
  grep -qF "$want" <<<"$out" || fail "vision line '$want' missing: $out"
done
grep -qF "EU hosting only" <<<"$out" && fail "a Constraints line leaked into the briefing: $out"
[ "$(grep -n "G1:" <<<"$out" | cut -d: -f1)" -lt "$(grep -n "Current ticket" <<<"$out" | cut -d: -f1)" ] || fail "vision after the ticket: $out"
git -C "$repo" switch -q main
context "$repo"
grep -qF "No native mobile app" <<<"$out" || fail "vision missing on the default branch: $out"
grep -q "Current ticket" <<<"$out" && fail "ticket on the default branch with a vision: $out"
git -C "$repo" switch -q feat/12-login
rm -rf "$repo/docs/vision.md"
context "$repo"
grep -qi "vision" <<<"$out" && fail "vision mentioned with no file: $out"

# The specs, ADRs and notes that govern the ticket's Paths (#338): from the board field Paths, else the spec's.
mkdir -p "$repo/docs/adr" "$repo/docs/knowledge"
adr() { printf -- '---\nid: %s\ntitle: %s\nstatus: %s\n%s---\n' "$1" "$2" "$3" "$4" >"$repo/docs/adr/$1-$5.md"; }
adr 0010 "Sessions are stateless" accepted 'paths: ["src/auth/session/**"]
' sessions
adr 0011 "Old session store" superseded 'paths: ["src/auth/**"]
' old-store
adr 0012 "Errors are values" accepted '' errors
adr 0013 "Billing rounding" accepted 'paths: ["src/billing/**"]
' billing
printf -- '---\nid: 100\ntitle: Authentication\nstatus: accepted\npaths: ["src/auth/**"]\n---\n' >"$repo/docs/specs/0100-auth.md"
printf -- '---\nid: 101\ntitle: Old authentication\nstatus: superseded\npaths: ["src/auth/**"]\n---\n' >"$repo/docs/specs/0101-old-auth.md"
note() { # slug paths kind days-ago heading
  printf -- '---\npaths: %s\nverified: %s\norigin: "#1"\nkind: %s\n---\n\n# %s\n\nBody.\n' "$2" "$(date -u -d "$4 days ago" +%F)" "$3" "$5" >"$repo/docs/knowledge/$1.md"
}
note aa-conv '["src/auth/**"]' convention 83 "Tokens are opaque"
note bb-pit '["src/auth/**"]' pitfall 30 "Logout must clear the cookie twice"
note cc-deep '["src/auth/session/token.ts"]' howto 40 "Rotating the signing key"
note dd-newer '["src/auth/**"]' context 10 "Why sessions expire at midnight"
note ee-billing '["src/billing/**"]' pitfall 5 "Money rounds half to even"
note ff-old '["src/auth/**"]' context 240 "The legacy login flow"
printf -- '---\nid: 3\nstatus: accepted\nadrs: ["0012"]\n---\n' >"$repo/docs/specs/0003-login.md"
export GH_PATHS='{"data":{"repository":{"issue":{"projectItems":{"nodes":[{"project":{"id":"P"},"fieldValueByName":{"text":"src/auth/**"}}]}}}}}'

context "$repo"
for want in "docs/specs/0100-auth.md" "docs/adr/0010-sessions.md" "docs/adr/0012-errors.md" "docs/knowledge/aa-conv.md" \
  "docs/knowledge/bb-pit.md" "docs/knowledge/cc-deep.md" "docs/knowledge/dd-newer.md"; do
  grep -qF "$want" <<<"$out" || fail "'$want' not in the briefing: $out"
done
for not in "0101-old-auth" "0011-old-store" "0013-billing" "ee-billing"; do
  grep -qF "$not" <<<"$out" && fail "'$not' is in the briefing: $out"
done
pos() { grep -nF -- "$1" <<<"$out" | head -n 1 | cut -d: -f1; }
for pair in "0010-sessions 0100-auth" "0100-auth cc-deep" "cc-deep Current ticket"; do
  a=${pair%% *} b=${pair#* }
  [ "$(pos "$a")" -lt "$(pos "$b")" ] || fail "'$a' should come before '$b': $out"
done
# Ranked by the literal prefix of the overlap, then pitfalls, then the newest verified, then the name.
for pair in "cc-deep bb-pit" "bb-pit dd-newer" "dd-newer aa-conv" "aa-conv ff-old"; do
  a=${pair%% *} b=${pair#* }
  [ "$(pos "$a")" -lt "$(pos "$b")" ] || fail "'$a' should be ranked before '$b': $out"
done
first=$out
context "$repo"
[ "$out" = "$first" ] || fail "two runs differ"

# With no Paths, the briefing holds the router, the ticket and its spec (the spec's adrs are not listed either).
GH_PATHS='' context "$repo"
grep -qF "docs/adr/" <<<"$out" && fail "an ADR with no Paths: $out"
grep -qF "docs/knowledge/" <<<"$out" && fail "a note with no Paths: $out"
grep -qF "docs/specs/0003-login.md (accepted)" <<<"$out" || fail "the ticket's spec is missing with no Paths: $out"
# The Paths of the spec stand in for the board's.
printf -- '---\nid: 3\nstatus: accepted\npaths: ["src/billing/**"]\n---\n' >"$repo/docs/specs/0003-login.md"
GH_PATHS='' context "$repo"
grep -qF "docs/knowledge/ee-billing.md" <<<"$out" || fail "the spec's paths are not used: $out"
grep -qF "docs/adr/0013-billing.md" <<<"$out" || fail "the ADR of the spec's paths is missing: $out"
grep -qF "aa-conv" <<<"$out" && fail "a note outside the spec's paths: $out"

printf -- '---\nid: 0003\nstatus: accepted\n---\n' >"$repo/docs/specs/0003-login.md"
unset GH_PATHS

git -C "$repo" switch -q -c spike-oauth
context "$repo"
grep -q "Current ticket" <<<"$out" && fail "ticket on a branch without an issue number: $out"

# A run session has no human: the router says what to do instead of asking.
grep -qi "nobody answers" <<<"$out" && fail "unattended rule outside a run: $out"
SENIOR_MODE_RUN=1 context "$work"
for want in "nobody answers" "recommended option" "needs-human"; do
  grep -qF "$want" <<<"$out" || fail "run session router lacks '$want': $out"
done
SENIOR_MODE_RUN=1 context "$repo"
grep -qF "nobody answers" <<<"$out" || fail "run session rule lost on a ticket branch: $out"

[ "$failures" -eq 0 ] && echo "context: all cases pass"
exit "$failures"
