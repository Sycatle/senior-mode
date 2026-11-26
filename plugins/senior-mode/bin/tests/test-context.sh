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
  *"pr list"*) [ -z "${GH_PRS_FAIL:-}" ] || exit 1; printf '%s\n' "${GH_PRS:-[]}" ;;
  *"pr view"*) cat "$GH_DIR/pr-$(sed -E 's/.*pr view ([0-9]+).*/\1/' <<<"$*").json" 2>/dev/null || exit 1 ;;
  *"api graphql"*"--input"*) printf '%s\n' "${GH_BOARD:-}" ;;
  *"api graphql"*) printf '%s\n' "${GH_PATHS:-}" ;;
esac
STUB
chmod +x "$work/stub/gh"
mkdir -p "$work/prs"
export PATH="$work/stub:$PATH" GH_LOG="$work/gh.log" GH_DIR="$work/prs"
# shellcheck disable=SC2016 # backticks are Markdown in the issue body
export GH_ISSUE='{"number":12,"title":"Let people log in","state":"OPEN","projectItems":[{"status":{"name":"In progress"}}],"body":"## What this gives\nLogin.\n\nSpec: `docs/specs/0003-login.md` §2.\n\n## Acceptance criteria\n- Given a user with an account, when they log in, then they see their dashboard.\n- Given a wrong password, when they log in, then they see an error.\n\n## Technical detail\nSessions."}'

issue12=$GH_ISSUE
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

# Every successful load writes the ticket to the git directory (#354); without it, GitHub down says the details are not loaded.
cache=$repo/.git/senior-mode/ticket/12.json
[ -f "$cache" ] || fail "no ticket cache after a load"
jq -e '.number == 12 and .title == "Let people log in"' "$cache" >/dev/null || fail "ticket cache is not the ticket: $(cat "$cache")"
mv "$cache" "$work/12.json"
GH_FAIL=1 context "$repo"
if ! grep -q "#12" <<<"$out" || ! grep -qi "not loaded" <<<"$out"; then fail "GitHub down: $out"; fi
grep -qF "GitHub unreachable: related tickets and review findings omitted" <<<"$out" || fail "GitHub down, no cache, no notice: $out"
grep -qF "Given a wrong password" <<<"$out" && fail "criteria without a cache: $out"
mv "$work/12.json" "$cache"
GH_FAIL=1 context "$repo"
for want in "#12 Let people log in" "In progress" "docs/specs/0003-login.md (accepted)" "Given a wrong password" "GitHub unreachable: related tickets and review findings omitted"; do
  grep -qF "$want" <<<"$out" || fail "GitHub down, from the cache: missing '$want' in: $out"
done
grep -qi "not loaded" <<<"$out" && fail "details not loaded though cached: $out"
context "$repo"
grep -qF "GitHub unreachable" <<<"$out" && fail "unreachable notice with GitHub up: $out"

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
# A `convention` note opens the briefing's project block, under `Project conventions`, before the ADRs (spec 409 section 4).
[ "$(pos "Project conventions")" -lt "$(pos aa-conv)" ] || fail "no Project conventions heading before the note: $out"
for pair in "aa-conv 0010-sessions" "0010-sessions 0100-auth" "0100-auth cc-deep" "cc-deep Current ticket"; do
  a=${pair%% *} b=${pair#* }
  [ "$(pos "$a")" -lt "$(pos "$b")" ] || fail "'$a' should come before '$b': $out"
done
# Ranked by the literal prefix of the overlap, then pitfalls, then the newest verified, then the name.
for pair in "cc-deep bb-pit" "bb-pit dd-newer" "dd-newer ff-old"; do
  a=${pair%% *} b=${pair#* }
  [ "$(pos "$a")" -lt "$(pos "$b")" ] || fail "'$a' should be ranked before '$b': $out"
done
first=$out
context "$repo"
[ "$out" = "$first" ] || fail "two runs differ"

# The age of a note, and `stale` past knowledge.staleMonths.
grep -qF "verified $(date -u -d '83 days ago' +%F) (83 days ago)" <<<"$out" || fail "age of the 83 days old note: $out"
grep -F "aa-conv" <<<"$out" | grep -q stale && fail "a fresh note is stale: $out"
grep -F "ff-old" <<<"$out" | grep -q ", stale" || fail "an 8 months old note is not stale: $out"
echo '{"knowledge":{"staleMonths":12}}' >"$repo/.claude/senior-mode.json"
context "$repo"
grep -F "ff-old" <<<"$out" | grep -q stale && fail "knowledge.staleMonths is not read: $out"

# The budget: the router and the ticket stay, the lowest ranked items go first, the last line says so.
echo '{}' >"$repo/.claude/senior-mode.json"
context "$repo"
full=$(wc -c <<<"$out")
[ "$full" -le 8000 ] || fail "default budget (2000 tokens) exceeded: $full bytes"
grep -q "omitted" <<<"$out" && fail "an omission line when everything fits: $out"
echo "{\"context\":{\"budget\":$(((full - 130) / 4))}}" >"$repo/.claude/senior-mode.json"
context "$repo"
[ "$(wc -c <<<"$out")" -le "$(((full - 130) / 4 * 4))" ] || fail "the briefing is over its budget: $(wc -c <<<"$out") bytes"
for want in "senior-mode is active" "#12 Let people log in" "Given a user with an account" "Given a wrong password" "docs/adr/0010-sessions.md" "docs/knowledge/cc-deep.md"; do
  grep -qF "$want" <<<"$out" || fail "'$want' dropped by the budget: $out"
done
grep -qF "docs/knowledge/ff-old.md" <<<"$out" && fail "the lowest ranked note is kept: $out"
tail -n 1 <<<"$out" | grep -Eq '^[0-9]+ items? omitted .*the scout agent has the rest\.$' || fail "no omission line last: $out"
echo '{"context":{"budget":1}}' >"$repo/.claude/senior-mode.json"
context "$repo"
for want in "senior-mode is active" "#12 Let people log in" "Given a wrong password"; do
  grep -qF "$want" <<<"$out" || fail "'$want' dropped by a tiny budget: $out"
done
grep -qE "docs/(adr|knowledge)/|docs/specs/0100" <<<"$out" && fail "items kept under a tiny budget: $out"
tail -n 1 <<<"$out" | grep -Eq '^8 items omitted ' || fail "tiny budget: $(tail -n 1 <<<"$out")"
echo '{}' >"$repo/.claude/senior-mode.json"

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

# Two tickets of one repository share the start of the briefing, up to the first section that depends on Paths.
printf '%s\n' '# Vision' '' '## Goals' '' '- G1: people log in' '' '## Non-goals' '' '- No mobile app' >"$repo/docs/vision.md"
git -C "$repo" switch -q -c feat/13-billing
# shellcheck disable=SC2016 # backticks are Markdown in the issue body
GH_ISSUE='{"number":13,"title":"Round money","state":"OPEN","projectItems":[],"body":"Spec: `docs/specs/0003-login.md`.\n\n## Acceptance criteria\n- Given a total, then it is rounded."}'
GH_PATHS='{"data":{"repository":{"issue":{"projectItems":{"nodes":[{"project":{"id":"P"},"fieldValueByName":{"text":"src/billing/**"}}]}}}}}' context "$repo"
start() { sed -n '1,/^\(Project conventions\|ADRs\|Specs\|Knowledge notes\|Current ticket\)/p' <<<"$1" | sed '$d'; }
billing=$out
git -C "$repo" switch -q feat/12-login
context "$repo"
[ "$(start "$out")" = "$(start "$billing")" ] || fail "the start of two briefings differs"
grep -qF "No mobile app" <<<"$(start "$out")" || fail "the vision is not in the stable start: $(start "$out")"
grep -qF "ee-billing" <<<"$billing" || fail "the billing ticket lacks its note: $billing"
grep -qF "ee-billing" <<<"$out" && fail "the login briefing has the billing note: $out"
rm -f "$repo/docs/vision.md"
printf -- '---\nid: 0003\nstatus: accepted\n---\n' >"$repo/docs/specs/0003-login.md"
unset GH_PATHS

# The history of the Paths and the related work (#349, #354).
gc() { # file subject [date]: commits a change of the file on the current branch
  local d=${3:-$(date -u +%FT%TZ)}
  mkdir -p "$(dirname "$repo/$1")"
  echo "$2" >>"$repo/$1"
  git -C "$repo" add "$1"
  GIT_AUTHOR_DATE=$d GIT_COMMITTER_DATE=$d git -C "$repo" -c user.name=t -c user.email=t@t commit -q -m "$2"
}
git -C "$repo" switch -q main
gc src/auth/ancient.ts 'Revert "feat(auth): ancient login (#20)"' "$(date -u -d '120 days ago' +%FT12:00:00Z)"
for n in 31 32 33 34 35 36 37; do gc "src/auth/f$n.ts" "feat(auth): change $n (#$n)"; done
gc src/billing/r.ts "feat(billing): rounding (#38)"
gc src/auth/tidy.ts "chore(auth): tidy up"
gc src/auth/cookie.ts 'Revert "feat(auth): opaque cookie (#39)"'
git -C "$repo" switch -q feat/12-login
today=$(date -u +%F)
export GH_ISSUE=$issue12
echo '{"project":{"id":"P"}}' >"$repo/.claude/senior-mode.json"
printf 'The slug covered-slug is explained here.\n' >"$repo/docs/knowledge/zz-covered.md"
mkdir -p "$repo/docs"
printf '%s\n' '# Decision log' '' '- 2026-11-01 #12: Q1 -> A1' '- 2026-11-02 #325: Q2 -> A2' '- 2026-11-03 #99: Other -> X' \
  '- 2026-11-04 #12: Q3 -> A3' '- 2026-11-05 #325: Q4 -> A4' '- 2026-11-06 #120: Near miss -> no' >"$repo/docs/decisions.md"
pr() { # number body files-json comments-json reviews-json
  jq -nc --argjson n "$1" --arg b "$2" --argjson f "$3" --argjson c "$4" --argjson r "$5" \
    '{number: $n, body: $b, files: ($f | map({path: .})), comments: ($c | map({body: .})), reviews: ($r | map({body: .}))}'
}
GH_PRS=$(jq -sc '.' < <(
  pr 37 $'## Decision\n\n- Tokens stay opaque\n\n## Notes\nx' '["src/auth/f37.ts"]' '["Nit. <!-- finding: unchecked-input -->","<!-- finding: covered-slug -->"]' '[]'
  pr 36 $'### Decisions\nKeep cookies httpOnly\n' '["src/auth/f36.ts"]' '[]' '["<!-- finding: unchecked-input -->\n<!-- finding: covered-slug -->"]'
  pr 34 'No heading here' '["src/auth/f34.ts"]' '["<!-- finding: single-slug -->"]' '[]'
  pr 33 $'## Decision\n## Next\nx' '["src/auth/f33.ts"]' '[]' '[]'
  pr 38 'Billing' '["src/billing/r.ts"]' '["<!-- finding: billing-slug -->"]' '[]'
  pr 40 'Billing again' '["src/billing/r.ts"]' '["<!-- finding: billing-slug -->"]' '[]'
))
export GH_PRS
jq -nc '{body: "## Decision\nFetched by number"}' >"$work/prs/pr-35.json"
board() { # number state status paths
  jq -nc --argjson n "$1" --arg st "$2" --arg s "$3" --arg p "$4" '{id: "I\($n)", updatedAt: "2026-11-01T00:00:00Z", isArchived: false,
    fieldValues: {nodes: ([{}, {name: $s, field: {name: "Status"}}] + (if $p == "" then [] else [{text: $p, field: {name: "Paths"}}] end))},
    content: {number: $n, title: "Ticket \($n)", state: $st, labels: {nodes: []}, blockedBy: {nodes: []}, authorAssociation: "OWNER"}}'
}
GH_BOARD=$(jq -sc '{data: {node: {items: {pageInfo: {hasNextPage: false}, nodes: .}}, repository: {}}}' < <(
  board 12 OPEN "In progress" "src/auth/**"
  board 50 OPEN Ready "src/auth/session/**"
  board 51 OPEN Backlog "src/auth/**"
  board 52 OPEN Ready "src/billing/**"
  board 53 CLOSED Done "src/auth/**"
  board 54 OPEN Backlog ""
  board 55 OPEN Backlog "src/auth/**"
  board 56 OPEN Backlog "src/auth/**"
  board 57 OPEN Backlog "src/auth/**"
  board 58 OPEN Backlog "src/auth/**"
  board 59 OPEN Backlog "src/auth/**"
))
export GH_BOARD
export GH_PATHS='{"data":{"repository":{"issue":{"parent":{"number":325,"title":"Long-lived projects"},"projectItems":{"nodes":[{"project":{"id":"P"},"fieldValueByName":{"text":"src/auth/**"}}]}}}}}'

context "$repo"
for want in "Epic: #325 Long-lived projects" "Recurring review findings" "- unchecked-input (on pull requests #36, #37)" "Reverted in the last 90 days:" \
  "- $today feat(auth): opaque cookie (#39)" "History of these Paths" "- #37 $today feat(auth): change 37 | decision: Tokens stay opaque" \
  "- #36 $today feat(auth): change 36 | decision: Keep cookies httpOnly" "- #35 $today feat(auth): change 35 | decision: Fetched by number" \
  "- #34 $today feat(auth): change 34" "- #33 $today feat(auth): change 33" "Open tickets on these Paths:" "- #50 Ticket 50 (Ready)" "- #51 Ticket 51 (Backlog)" \
  "- #57 Ticket 57" "Framing decisions of this ticket or its epic" "- 2026-11-05 #325: Q4 -> A4" "- 2026-11-04 #12: Q3 -> A3" "- 2026-11-02 #325: Q2 -> A2"; do
  grep -qF -- "$want" <<<"$out" || fail "history: missing '$want' in: $out"
done
for not in "covered-slug" "single-slug" "billing-slug" "ancient login" "change 32" "change 31" "rounding" "tidy up" "#38" "#52" "#53" "#54" "#58" "#59" "#12 Ticket" \
  "Q1 ->" "Other -> X" "Near miss" "GitHub unreachable"; do
  grep -qF -- "$not" <<<"$out" && fail "history: '$not' should not be in: $out"
done
grep -F -- "#34 $today" <<<"$out" | grep -q "decision:" && fail "a decision for a pull request with no Decision heading: $out"
grep -F -- "#33 $today" <<<"$out" | grep -q "decision:" && fail "a decision for an empty Decision heading: $out"
[ "$(grep -c -- '^- #[0-9]* 20' <<<"$out")" -eq 5 ] || fail "history is not 5 commits: $out"
prev=Knowledge
for next in "Recurring review" "Reverted in" "History of" "Open tickets" "Framing decisions" "Current ticket"; do
  [ "$(pos "$prev")" -lt "$(pos "$next")" ] || fail "'$prev' should come before '$next': $out"
  prev=$next
done
[ "$(pos "Epic: #325")" -gt "$(pos "Current ticket")" ] || fail "the epic is not part of the ticket: $out"
first=$out
context "$repo"
[ "$out" = "$first" ] || fail "two runs with history differ"

# The budget drops the related work first, then the history, before the notes and the ADRs.
full=$(wc -c <<<"$out")
echo "{\"project\":{\"id\":\"P\"},\"context\":{\"budget\":$(((full - 330) / 4))}}" >"$repo/.claude/senior-mode.json"
context "$repo"
[ "$(wc -c <<<"$out")" -le "$(((full - 330) / 4 * 4))" ] || fail "history: the briefing is over its budget: $(wc -c <<<"$out") bytes"
grep -qF -- "Framing decisions" <<<"$out" && fail "the lowest class is kept first: $out"
for want in "docs/adr/0010-sessions.md" "- #37 $today" "Recurring review findings" "Given a wrong password" "Epic: #325"; do
  grep -qF -- "$want" <<<"$out" || fail "history: '$want' dropped before the lowest class: $out"
done
tail -n 1 <<<"$out" | grep -Eq '^[0-9]+ items? omitted ' || fail "history: no omission line last: $out"
echo '{"project":{"id":"P"}}' >"$repo/.claude/senior-mode.json"

# GitHub down: git and files only, from the cache, one line says what is missing, exit 0.
GH_FAIL=1 context "$repo"
for want in "#12 Let people log in" "Epic: #325 Long-lived projects" "Given a wrong password" "- #37 $today feat(auth): change 37" "- #33 $today feat(auth): change 33" \
  "- $today feat(auth): opaque cookie (#39)" "- 2026-11-05 #325: Q4 -> A4" "GitHub unreachable: related tickets and review findings omitted"; do
  grep -qF -- "$want" <<<"$out" || fail "offline history: missing '$want' in: $out"
done
for not in "decision: " "unchecked-input" "Open tickets on these Paths" "not loaded"; do
  grep -qF -- "$not" <<<"$out" && fail "offline history: '$not' should not be in: $out"
done
[ "$(grep -c "GitHub unreachable" <<<"$out")" -eq 1 ] || fail "offline: not exactly one notice: $out"
# A failure of the pull requests alone is GitHub failing too.
GH_PRS='' context "$repo"
grep -qF -- "- #37 $today" <<<"$out" || fail "an empty answer loses the history: $out"
# No Paths, no history.
GH_PATHS='' context "$repo"
grep -qF "History of these Paths" <<<"$out" && fail "history without Paths: $out"
rm -f "$repo/docs/decisions.md" "$repo/docs/knowledge/zz-covered.md"
echo '{}' >"$repo/.claude/senior-mode.json"
unset GH_PRS GH_BOARD GH_PATHS

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
