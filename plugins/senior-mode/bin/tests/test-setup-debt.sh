#!/usr/bin/env bash
# Tests for the debt tickets of `senior-mode setup repo --adopt --debt` (#424, spec 409 section 7): the baselines and the
# dormant zones of a legacy project become gardening tickets, ranked by findings times churn, within maintenance.maxOpen, one
# per fingerprint. Offline: gh is a stub that keeps the issues in $FIX/issues.json; the repository is a real one with a
# bare origin of its own at <work>/github.com/acme/app.git (so that the slug is acme/app).
# shellcheck disable=SC2016 # jq programs and stub bodies, not expanded here
set -u
cli=$(cd "$(dirname "$0")/.." && pwd)/senior-mode
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

mkdir -p "$work/stub" "$work/fix"
cat >"$work/stub/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$GH_LOG"
jqf="" prev=""
for a in "$@"; do [ "$prev" = --jq ] && jqf=$a; prev=$a; done
respond() { if [ -n "$jqf" ]; then jq -r "$jqf"; else cat; fi; }
case "$*" in
  "pr list"*"--state merged"*) echo '[]' | respond ;;
  "pr list"*) if [ -f "$FIX/open-pr" ]; then jq -nc --arg u "$(cat "$FIX/open-pr")" '[{url: $u}]' | respond; else echo '[]' | respond; fi ;;
  "pr create"*) echo "https://github.com/acme/app/pull/12" | tee "$FIX/open-pr" ;;
  "api repos/acme/app --jq"*) echo '{"allow_rebase_merge": true, "allow_squash_merge": true, "allow_merge_commit": false, "default_branch": "main"}' | respond ;;
  "label list"*) echo '[]' | respond ;;
  "issue list"*) cat "$FIX/issues.json" | respond ;;
  "issue create"*)
    t="" bf="" prev=""
    for a in "$@"; do [ "$prev" = --title ] && t=$a; [ "$prev" = --body-file ] && bf=$a; prev=$a; done
    n=$(jq '[500, (.[].number + 1)] | max' "$FIX/issues.json")
    jq --argjson n "$n" --arg t "$t" --rawfile b "$bf" '. + [{number: $n, title: $t, body: $b, labels: []}]' "$FIX/issues.json" >"$FIX/i" && mv "$FIX/i" "$FIX/issues.json"
    echo "https://github.com/acme/app/issues/$n" ;;
  "api repos/acme/app/issues/"*"/labels"*)
    n=$(sed -E 's#^api repos/acme/app/issues/([0-9]+)/labels.*#\1#' <<<"$*")
    l=$(sed -E 's#.*labels\[\]=([^ ]+).*#\1#' <<<"$*")
    jq --argjson n "$n" --arg l "$l" 'map(if .number == $n then .labels += [{name: $l}] else . end)' "$FIX/issues.json" >"$FIX/i" && mv "$FIX/i" "$FIX/issues.json" ;;
  "api repos/acme/app/issues/"*"/sub_issues"*) echo '[]' | respond ;;
  "api -X POST repos/acme/app/issues/"*"/sub_issues"*) echo "$*" >>"$FIX/sub-issues" ;;
  "api repos/acme/app/issues/"[0-9]*" --jq .id") echo 1 ;;
  "project item-add"*) echo "ITEM_$(sed -E 's#.*/issues/([0-9]+).*#\1#' <<<"$*")" ;;
  "project item-edit"*) ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$work/stub/gh"
export PATH="$work/stub:$PATH" GH_LOG="$work/gh.log" FIX="$work/fix" SENIOR_MODE_RETRY_DELAY=0 XDG_DATA_HOME="$work/xdg"

origin="$work/github.com/acme/app.git"
repo="$work/repo"
git init -q --bare -b main "$origin"
git init -q -b main "$repo"
git -C "$repo" remote add origin "$origin"
g() { git -C "$repo" -c core.hooksPath=/dev/null -c user.name=t -c user.email=t@t "$@"; }
epic='{"number": 7, "title": "Maintenance", "body": "", "labels": [{"name": "maintenance"}]}'
fields='{"Status": {"id": "F_S", "options": {"Backlog": "o0", "Ready": "o1"}},
  "Priority": {"id": "F_P", "options": {"P1 next": "p1", "P2 later": "p2"}}, "Size": {"id": "F_Z", "options": {"S": "z1", "M": "z2"}}, "Paths": {"id": "F_Paths"}}'
cfg() { # <kind> <maxOpen>
  jq -n --argjson f "$fields" --arg k "$1" --argjson m "$2" '{language: "en", adopt: {kind: $k}, commands: {test: "true"},
    project: {id: "PVT_1", owner: "acme", number: 3, fields: $f}, maintenance: {maxOpen: $m}}' >"$repo/.claude/senior-mode.json"
}
issues() { jq -r '[.[] | select(.number >= 500) | .title] | join("\n")' "$FIX/issues.json"; }
fps() { jq -r '[.[] | select(.number >= 500) | .body | split("\n")[] | select(startswith("debt-id: ")) | sub("^debt-id: debt:"; "")] | sort | join(" ")' "$FIX/issues.json"; }
adopt() { : >"$GH_LOG"; (cd "$repo" && "$cli" setup repo "$@") >"$work/out" 2>"$work/err"; }
reset() { echo "[$epic]" >"$FIX/issues.json"; rm -f "$FIX/sub-issues"; }

# A legacy project: eight directories at depth 2 with three lint findings each and i+1 changes over 12 months for src/d<i>,
# so the order by findings times churn is d8 down to d1; src/old has not changed for two years and nothing imports it.
mkdir -p "$repo/.claude" "$repo/src/old"
for i in 1 2 3 4 5 6 7 8; do
  mkdir -p "$repo/src/d$i"
  echo "export const v$i = 0" >"$repo/src/d$i/a.ts"
done
for f in a b c; do echo "export const $f = 1" >"$repo/src/old/$f.ts"; done
cfg legacy 5
g add -A
old="@$(date -d "2 years ago" +%s) +0000"
GIT_AUTHOR_DATE=$old GIT_COMMITTER_DATE=$old g commit -q -m "chore: start"
for i in 1 2 3 4 5 6 7 8; do
  for k in $(seq "$i"); do
    echo "// $k" >>"$repo/src/d$i/a.ts"
    g commit -q -am "feat: d$i $k"
  done
done
lintb() { # <first dir> <last dir>
  jq -nc --argjson a "$1" --argjson b "$2" '{version: 1, lint: {total: (($b - $a + 1) * 3), files: ([range($a; $b + 1)] | map({key: "src/d\(.)/a.ts", value: {"no-var": 3}}) | from_entries)}}'
}
lintb 1 8 >"$repo/.claude/ratchet-baseline.json"
g add -A
g commit -q -m "chore: baseline"
g push -q origin main

# The first run: 8 directories of debt, maintenance.maxOpen 5, so 5 tickets, the most findings times churn first.
reset
adopt --adopt --debt || fail "adopt --debt failed: $(cat "$work/err")"
[ "$(issues | wc -l)" = 5 ] || fail "not five tickets: $(issues)"
[ "$(issues | head -n 1)" = 'chore(lint): fix no-var findings in src/d8' ] || fail "the first ticket is not src/d8: $(issues)"
[ "$(fps)" = "lint:src/d4 lint:src/d5 lint:src/d6 lint:src/d7 lint:src/d8" ] || fail "wrong directories or fingerprints: $(fps)"
{ [ "$(wc -l <"$FIX/sub-issues")" = 5 ] && grep -q 'issues/7/sub_issues' "$FIX/sub-issues"; } || fail "the tickets are not under the maintenance epic: $(cat "$FIX/sub-issues" 2>&1)"
[ "$(jq '[.[] | select(.number >= 500 and (.labels | map(.name) | index("gardening")))] | length' "$FIX/issues.json")" = 5 ] || fail "not labelled gardening"
body=$(jq -r '.[] | select(.title | endswith("src/d8")) | .body' "$FIX/issues.json")
grep -qF 'The baseline lists 3 lint findings in `src/d8`' <<<"$body" || fail "the body does not say what the baseline holds: $body"
grep -qE 'Given the baseline lists 3 lint findings in `src/d8`.*when every `no-var` finding in `src/d8` is fixed, then .*check --update-baseline' <<<"$body" || fail "no Given/When/Then on the baseline: $body"
grep -qx 'filed-by: agent' <<<"$body" || fail "not filed as an agent's ticket, so ready would skip it"
grep -q 'F_Paths.*src/d8/\*\*' "$GH_LOG" || fail "the directory is not the Paths: $(grep -c . "$GH_LOG") calls"
grep -q -- '--single-select-option-id z1' "$GH_LOG" || fail "not size S"
grep -q -- '--single-select-option-id p2' "$GH_LOG" || fail "not P2"
# The adoption pull request records maintenance.debt for serve.
git -C "$origin" show docs/adopt-senior-mode:.claude/senior-mode.json | jq -e '.maintenance.debt == true' >/dev/null || fail "maintenance.debt is not in the adoption pull request"

# Five open gardening tickets and maxOpen 5: nothing more.
adopt --adopt --debt || fail "second adopt failed: $(cat "$work/err")"
[ "$(issues | wc -l)" = 5 ] || fail "a ticket filed at the cap: $(issues)"
grep -q 'maintenance.maxOpen is 5: none filed' "$work/out" || fail "the cap is not said: $(cat "$work/out")"

# A ticket with the fingerprint is open: none is filed for it. maxOpen 7 with d8 open: d3 and d2 come next.
cfg legacy 7
reset
jq -n --argjson e "$epic" '[$e, {number: 600, title: "something", body: "debt-id: debt:lint:src/d8\n", labels: [{name: "gardening"}]}]' >"$FIX/issues.json"
adopt --adopt --debt || fail "adopt with an open fingerprint failed: $(cat "$work/err")"
[ "$(jq '[.[] | select((.body // "") | contains("debt-id: debt:lint:src/d8"))] | length' "$FIX/issues.json")" = 1 ] || fail "a second ticket for an open fingerprint: $(fps)"
[ "$(fps)" = "lint:src/d2 lint:src/d3 lint:src/d4 lint:src/d5 lint:src/d6 lint:src/d7 lint:src/d8" ] || fail "within maxOpen 7 with d8 open: expected d7 down to d2 filed: $(fps)"

# Fixed directories leave the baseline (d8 and d7): nothing is ticketed for them, and the dead zone, ranked last, waits for room.
lintb 1 6 >"$repo/.claude/ratchet-baseline.json"
cfg legacy 6
reset
adopt --adopt --debt || fail "adopt after a lowered baseline failed: $(cat "$work/err")"
[ "$(fps)" = "lint:src/d1 lint:src/d2 lint:src/d3 lint:src/d4 lint:src/d5 lint:src/d6" ] ||
  fail "a directory that left the baseline is still ticketed: $(fps)"

# Coverage and architecture: the least covered file of its directory, the most repeated violation; the dead zone last, in Backlog,
# for the owner: not an agent's ticket, needs-human, and nothing picks it.
jq -nc '{version: 1, coverage: {total: 40, files: {"src/d2/a.ts": 30, "src/d5/a.ts": 95}}}' >"$repo/.claude/ratchet-baseline.json"
jq -nc '{violations: [{rule: "ui-not-api", file: "src/d3/a.ts", count: 2}, {rule: "ui-not-db", file: "src/d3/a.ts"}]}' >"$repo/.claude/architecture-baseline.json"
cfg legacy 10
reset
adopt --adopt --debt || fail "adopt with coverage and architecture failed: $(cat "$work/err")"
[ "$(issues | tr '\n' '|')" = 'chore(coverage): characterize src/d2/a.ts|chore(architecture): fix ui-not-api violation in src/d3/a.ts|chore(dead): confirm and remove unused code in src/old|' ] ||
  fail "wrong tickets, ranked by missing coverage times churn (src/d5 is above the bar): $(issues)"
[ "$(issues | tail -n 1)" = 'chore(dead): confirm and remove unused code in src/old' ] || fail "the dead zone is not last: $(issues)"
dead=$(jq -c '.[] | select(.title | startswith("chore(dead)"))' "$FIX/issues.json")
jq -e '.labels | map(.name) | index("needs-human") and index("gardening")' <<<"$dead" >/dev/null || fail "dead zone ticket without needs-human: $dead"
jq -r .body <<<"$dead" | grep -qx 'filed-by: agent' && fail "the dead zone ticket is an agent's, ready could take it"
grep -q 'Given `src/old` has had no change in 12 months' <(jq -r .body <<<"$dead") || fail "the dead ticket has no criterion: $dead"
# Not a ticket for the files a baseline lists at the bar or above.
jq -e 'map(select(.title | contains("src/d5"))) | length == 0' "$FIX/issues.json" >/dev/null || fail "a ticket for a file above the coverage bar"

# A dry run files nothing and says which; an evergreen project files none.
reset
adopt --dry-run --debt || fail "dry run failed: $(cat "$work/err")"
grep -q 'would file: chore(architecture)' "$work/out" || fail "the dry run does not say which: $(cat "$work/out")"
[ -z "$(issues)" ] || fail "a dry run filed: $(issues)"
cfg evergreen 5
adopt --dry-run --debt || fail "evergreen dry run failed"
grep -q 'evergreen project, no debt ticket filed' "$work/out" || fail "evergreen not said: $(cat "$work/out")"
[ -z "$(issues)" ] || fail "tickets for an evergreen project: $(issues)"
# --debt goes with --adopt or --dry-run.
adopt --debt && fail "--debt alone is accepted"
# No open epic: nothing filed, and it is said.
cfg legacy 5
echo '[]' >"$FIX/issues.json"
adopt --adopt --debt
grep -q 'no open epic labelled maintenance' "$work/err" || fail "the missing epic is not said: $(cat "$work/err")"

[ "$failures" -eq 0 ] && echo "setup-debt: all cases pass"
exit "$failures"
