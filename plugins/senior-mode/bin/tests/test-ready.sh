#!/usr/bin/env bash
# Tests for `senior-mode ready [--pr <n>] [--dry-run]`: tickets become Ready by rule (#154). Offline: gh is a
# stub that serves the board and the pull requests from $FIX and logs what it is asked.
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
  "api graphql --input -")
    q=$(cat)
    # The Size of a ticket (item_get) or the board.
    if grep -q 'issues(states: OPEN' <<<"$q"; then
      if [ -f "$FIX/orphans.json" ]; then cat "$FIX/orphans.json"; else echo '{"data": {"repository": {"issues": {"pageInfo": {"hasNextPage": false}, "nodes": []}}}}'; fi
    elif grep -q projectItems <<<"$q"; then cat "$FIX/item-$(jq -r '.variables.number' <<<"$q").json"; else cat "$FIX/board.json"; fi ;;
  "pr view "*) n=$(sed -E 's#^pr view ([0-9]+) .*#\1#' <<<"$*"); respond <"$FIX/pr-$n.json" ;;
  "api -H Accept: application/vnd.github.raw repos/acme/app/contents/"*)
    f=${4#repos/acme/app/contents/}; f=$FIX/content-$(sed 's#[/?].*##; s#^$#x#' <<<"$f")-$(basename "${f%%\?*}")
    if [ -f "$f" ]; then cat "$f"; else echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi ;;
  "api repos/acme/app/pulls/"*"/files"*) respond <"$FIX/files-$(sed -E 's#.*/pulls/([0-9]+)/files.*#\1#' <<<"$*").json" ;;
  "api repos/acme/app/pulls/"*"/commits"*) respond <"$FIX/commits-$(sed -E 's#.*/pulls/([0-9]+)/commits.*#\1#' <<<"$*").json" ;;
  "api repos/acme/app/commits/"*) respond <"$FIX/commit-${2##*/}.json" ;;
  "api repos/acme/app/pulls/"*) respond <"$FIX/pull-${2##*/}.json" ;;
  "issue view "*) n=$(sed -E 's#^issue view ([0-9]+) .*#\1#' <<<"$*")
    if [ -f "$FIX/issue-$n.json" ]; then respond <"$FIX/issue-$n.json"; else echo '{"body": ""}'; fi ;;
  "project item-add"*) echo "ITEM_$(sed -E 's#.*/issues/([0-9]+).*#\1#' <<<"$*")" ;;
  "project item-edit"*) ;;
  "api repos/acme/app/issues/"*"/labels"*) echo '[]' ;;
  "api repos/acme/app/issues/"*"/comments"*) echo '{}' ;;
  "issue view "*) f="$FIX/issue-$(sed -E 's#^issue view ([0-9]+) .*#\1#' <<<"$*").json"; if [ -f "$f" ]; then cat "$f"; else echo '{"labels": []}'; fi ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$work/stub/gh"
export PATH="$work/stub:$PATH" GH_LOG="$work/gh.log" FIX="$work/fix" SENIOR_MODE_RETRY_DELAY=0

repo="$work/repo"
git init -q "$repo"
git -C "$repo" remote add origin git@github.com:acme/app.git
mkdir -p "$repo/.claude"
config() { # protected-globs-json
  jq -n --argjson p "$1" '{protected: $p, project: {id: "PVT_1", owner: "acme", number: 3, fields: {
    Status: {id: "F_S", options: {Backlog: "o1", Ready: "o2"}}}}}' >"$repo/.claude/senior-mode.json"
}
config '["auth/**"]'

criteria=$'## Context\n\nx\n\n## Acceptance criteria\n\n- Given a, when b, then c.\n'
# item <number> <status> <priority|-> <size|-> <severity|-> <paths|-> <labels json> <body> [state]
items="[]"
item() {
  local fields='[]'
  [ "$2" = - ] || fields=$(jq -c --arg v "$2" '. + [{name: $v, field: {name: "Status"}}]' <<<"$fields")
  [ "$3" = - ] || fields=$(jq -c --arg v "$3" '. + [{name: $v, field: {name: "Priority"}}]' <<<"$fields")
  [ "$4" = - ] || fields=$(jq -c --arg v "$4" '. + [{name: $v, field: {name: "Size"}}]' <<<"$fields")
  [ "$5" = - ] || fields=$(jq -c --arg v "$5" '. + [{name: $v, field: {name: "Severity"}}]' <<<"$fields")
  [ "$6" = - ] || fields=$(jq -c --arg v "$6" '. + [{text: $v, field: {name: "Paths"}}]' <<<"$fields")
  items=$(jq -c --argjson n "$1" --argjson f "$fields" --argjson l "$7" --arg b "$8" --arg s "${9:-OPEN}" \
    '. + [{fieldValues: {nodes: $f}, content: {authorAssociation: "OWNER", number: $n, state: $s, body: $b, labels: {nodes: ($l | map({name: .}))}}}]' <<<"$items")
}
board() { jq -nc --argjson i "$items" '{data: {node: {items: {pageInfo: {hasNextPage: false}, nodes: $i}}}}' >"$FIX/board.json"; }
pr() { # number state branch body
  jq -nc --arg s "$2" --arg h "$3" --arg b "$4" '{state: $s, headRefName: $h, body: $b}' >"$FIX/pr-$1.json"
}
ready() { : >"$GH_LOG"; (cd "$repo" && "$cli" ready "$@") >"$work/out" 2>"$work/err"; }
logged() { grep -qF -- "$1" "$GH_LOG"; }
said() { grep -qE -- "$1" "$work/out"; }
labelled() { grep -qF "api repos/acme/app/issues/$1/labels -f labels[]=needs-human" "$GH_LOG"; }
agent=$'\nfiled-by: agent\n'

# A: a merged framing pull request. #10 passes; #11 lacks criteria and Paths; #12 lacks Size and Priority;
# #13 is Ready already; #14 already waits for a human; #15 is closed; #16 is not Backlog-bound (no Status);
# #17 is M in a protected zone: a framed ticket only needs the Definition of Ready.
item 10 Backlog "P1 next" S - "docs/**, plugins/x" '[]' "$criteria"
item 11 Backlog "P1 next" S - - '[]' $'## Context\n\nonly prose\n'
item 12 Backlog - - - "docs/**" '[]' "$criteria"
item 13 Ready "P1 next" S - "docs/**" '[]' "$criteria"
item 14 Backlog - - - - '["needs-human"]' ""
item 15 Backlog "P1 next" S - "docs/**" '[]' "$criteria" CLOSED
item 17 Backlog "P2 later" M - '["auth/**"]' '[]' "$criteria"
item 99 Backlog "P1 next" S - "docs/**" '[]' "$criteria"
board
pr 100 MERGED docs/wave "Framing: #10 #11 #12 #13 #14 #15 #17 and #18 (not on the board); this is #100."
ready --pr 100 || fail "A: ready failed: $(cat "$work/err")"
logged "project item-add 3 --owner acme --url https://github.com/acme/app/issues/10" || fail "A: #10 not touched"
grep -c 'item-edit.*--single-select-option-id o2' "$GH_LOG" | grep -qx 2 || fail "A: expected #10 and #17 set Ready: $(cat "$GH_LOG")"
said '^#10 Status = Ready' || fail "A: #10 not reported Ready: $(cat "$work/out")"
said '^#17 Status = Ready' || fail "A: framed #17 (M, protected paths) not Ready: $(cat "$work/out")"
labelled 11 || fail "A: #11 not labelled needs-human"
labelled 12 || fail "A: #12 not labelled needs-human"
logged 'api repos/acme/app/issues/11/comments' || fail "A: no comment on #11"
grep -F 'issues/11/comments' "$GH_LOG" | grep -q 'acceptance criteria' || fail "A: comment on #11 does not name the criteria"
grep -F 'issues/11/comments' "$GH_LOG" | grep -q 'Paths' || fail "A: comment on #11 does not name Paths"
grep -F 'issues/12/comments' "$GH_LOG" | grep -q 'Size, Priority' || fail "A: comment on #12 does not name Size and Priority: $(grep 'issues/12/comments' "$GH_LOG")"
said '^#11 needs-human: .*acceptance criteria.*Paths' || fail "A: #11 report: $(cat "$work/out")"
# The summary (#610): considered, what became of them, and the open tickets skipped by reason.
said '^ready: 4 considered, 2 set Ready, 2 needs-human; skipped 5: 2 named in the pull request but not an open ticket of the board, 1 needs-human, 1 not Backlog, 1 not named in the pull request$' ||
  fail "A: no summary: $(cat "$work/out")"
for n in 13 14 15 99 18; do
  grep -q "issues/${n}[/ ]" "$GH_LOG" && fail "A: #$n was touched: $(grep "issues/$n" "$GH_LOG")"
done
[ "$(grep -c 'project item-add' "$GH_LOG")" -eq 2 ] || fail "A: only #10 and #17 are set Ready: $(cat "$GH_LOG")"

# B: --dry-run reads and says, writes nothing.
ready --pr 100 --dry-run || fail "B: dry run failed: $(cat "$work/err")"
logged "item-add" && fail "B: dry run set a Status"
logged "/labels" && fail "B: dry run labelled"
logged "/comments" && fail "B: dry run commented"
said '^#10 would be Ready' || fail "B: dry run does not say #10 would be Ready: $(cat "$work/out")"
said '^#11 would get needs-human: .*acceptance criteria' || fail "B: dry run does not say what #11 lacks: $(cat "$work/out")"
said '^ready: 4 considered, 2 would be Ready, 2 would get needs-human; skipped 5: ' || fail "B: no dry-run summary: $(cat "$work/out")"

# C: not a merged framing pull request.
pr 101 OPEN docs/wave "#10"
ready --pr 101 && fail "C: an open pull request accepted"
grep -q 'not merged' "$work/err" || fail "C: open pull request not explained: $(cat "$work/err")"
pr 102 MERGED feat/10-thing "Closes #10"
ready --pr 102 && fail "C: a merged feature pull request accepted"
grep -q 'framing' "$work/err" || fail "C: non-framing pull request not explained: $(cat "$work/err")"
ready --pr abc 2>/dev/null && fail "C: --pr abc accepted"
ready --bogus 2>/dev/null && fail "C: an unknown option accepted"

# D: without --pr, the Backlog tickets an agent filed. They become Ready only when S, not high or critical
# security and outside the protected zones (and they pass the Definition of Ready).
items="[]"
item 20 Backlog "P2 later" S low "docs/**" '["security"]' "$criteria$agent"
item 21 Backlog "P2 later" M - "docs/**" '[]' "$criteria$agent"
item 22 Backlog "P0 now" S high "docs/**" '["security"]' "$criteria$agent"
item 23 Backlog "P2 later" S - "auth/login.ts" '[]' "$criteria$agent"
item 24 Backlog "P1 next" S - "docs/**" '[]' "$criteria"
item 25 Ready "P1 next" S - "docs/**" '[]' "$criteria$agent"
item 26 Backlog "P2 later" S critical "docs/**" '[]' "$criteria$agent"
item 27 Backlog "P2 later" S - "auth/**/x.ts" '[]' "$criteria$agent"
item 28 Backlog "P2 later" S - "src/*.ts" '[]' "$criteria$agent"
item 29 Backlog "P2 later" S - - '[]' "$criteria$agent"
board
ready || fail "D: ready failed: $(cat "$work/err")"
said '^#20 Status = Ready' || fail "D: a small, low-risk agent ticket not Ready: $(cat "$work/out")"
said '^#28 Status = Ready' || fail "D: an agent ticket outside the zones not Ready: $(cat "$work/out")"
grep -c 'item-edit.*--single-select-option-id o2' "$GH_LOG" | grep -qx 2 || fail "D: only #20 and #28 become Ready: $(cat "$GH_LOG")"
said '^#21 needs-human: .*size M' || fail "D: an M agent ticket: $(cat "$work/out")"
said '^#22 needs-human: .*high security' || fail "D: a high security agent ticket: $(cat "$work/out")"
said '^#26 needs-human: .*critical security' || fail "D: a critical security agent ticket: $(cat "$work/out")"
said '^#23 needs-human: .*protected zone.*auth/login.ts' || fail "D: an agent ticket in a protected zone: $(cat "$work/out")"
said '^#27 needs-human: .*protected zone' || fail "D: a Paths glob that reaches a protected zone: $(cat "$work/out")"
said '^#29 needs-human: .*Paths' || fail "D: an agent ticket without Paths: $(cat "$work/out")"
for n in 21 22 23 26 27 29; do labelled "$n" || fail "D: #$n not labelled needs-human"; done
for n in 20 24 25 28; do labelled "$n" && fail "D: #$n labelled needs-human"; done
grep -qE "issues/24[/ ]" "$GH_LOG" && fail "D: #24 (not filed by an agent, in no framing pull request) was touched"
grep -qE "issues/25[/ ]" "$GH_LOG" && fail "D: #25 (already Ready) was touched"

# E: Paths is not on the board (the field does not exist yet): it counts as missing, nothing fails.
items="[]"
item 30 Backlog "P1 next" S - - '[]' "$criteria"
board
pr 103 MERGED docs/wave "#30"
ready --pr 103 || fail "E: a board without Paths fails: $(cat "$work/err")"
said '^#30 needs-human: .*Paths' || fail "E: a missing Paths field is not reported: $(cat "$work/out")"

# F: the protected zones are those of the default branch, not of a branch that edits them.
git -C "$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "chore: init"
git -C "$repo" branch -M main
git -C "$repo" update-ref refs/remotes/origin/main HEAD
git -C "$repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
git -C "$repo" add -A && git -C "$repo" -c user.name=t -c user.email=t@t commit -q -m "chore: config"
git -C "$repo" update-ref refs/remotes/origin/main HEAD
config '[]'
items="[]"
item 40 Backlog "P2 later" S - "auth/login.ts" '[]' "$criteria$agent"
board
ready || fail "F: ready failed: $(cat "$work/err")"
said '^#40 needs-human: .*protected zone' || fail "F: a branch lifted its own protected zone: $(cat "$work/out")"

# G: the trust gate (#427). An issue is Ready-eligible when it has no `triage` and its author is a collaborator
# (OWNER, MEMBER, COLLABORATOR) or a collaborator qualified it with the label `qualified`; nothing else is touched.
assoc() { items=$(jq -c --argjson n "$1" --arg a "$2" 'map(if .content.number == $n then .content.authorAssociation = $a else . end)' <<<"$items"); }
items="[]"
item 50 Backlog "P2 later" S - "docs/**" '[]' "$criteria$agent"
item 51 Backlog "P2 later" S - "docs/**" '[]' "$criteria$agent"
item 52 Backlog "P2 later" S - "docs/**" '["triage"]' "$criteria$agent"
item 53 Backlog "P2 later" S - "docs/**" '["qualified"]' "$criteria$agent"
item 54 Backlog "P2 later" S - "docs/**" '["triage", "qualified"]' "$criteria$agent"
item 55 Backlog "P2 later" S - "docs/**" '[]' "$criteria$agent"
item 56 Backlog "P2 later" S - "docs/**" '[]' "$criteria$agent"
item 57 Backlog "P2 later" S - "docs/**" '[]' "$criteria$agent"
item 58 Backlog "P2 later" S - "docs/**" '[]' "$criteria$agent"
assoc 51 NONE
assoc 53 FIRST_TIME_CONTRIBUTOR
assoc 54 NONE
assoc 55 CONTRIBUTOR
assoc 56 MEMBER
assoc 57 COLLABORATOR
items=$(jq -c 'map(if .content.number == 58 then del(.content.authorAssociation) else . end)' <<<"$items")
board
ready || fail "G: ready failed: $(cat "$work/err")"
for n in 50 53 56 57; do said "^#$n Status = Ready" || fail "G: #$n (a collaborator's, or qualified) not Ready: $(cat "$work/out")"; done
grep -c 'item-edit.*--single-select-option-id o2' "$GH_LOG" | grep -qx 4 || fail "G: only #50, #53, #56 and #57 become Ready: $(cat "$GH_LOG")"
for n in 51 52 54 55 58; do
  grep -qE "issues/${n}[/ ]" "$GH_LOG" && fail "G: #$n (untrusted) was touched: $(grep "issues/$n" "$GH_LOG")"
  said "^#$n " && fail "G: #$n (untrusted) was reported: $(cat "$work/out")"
done
[ "$(grep -c 'project item-add' "$GH_LOG")" -eq 4 ] || fail "G: the untrusted tickets reached the board: $(cat "$GH_LOG")"
# A framing pull request that names an untrusted ticket does not make it Ready either.
pr 110 MERGED docs/wave "#51 #52 #50"
ready --pr 110 || fail "G: ready --pr failed: $(cat "$work/err")"
said '^#50 Status = Ready' || fail "G: #50 not Ready through a framing pull request: $(cat "$work/out")"
said '^#5[12] ' && fail "G: a framing pull request made an untrusted ticket Ready: $(cat "$work/out")"

# H: an open pull request that is no framing one is a delivery: one commit per ticket it closes (#297) and
# its changed lines within the size budget of its tickets (#303; S 300, M 800, L 2000, a batch sums them).
size() { # ticket size
  jq -nc --arg s "$2" '{data: {repository: {issue: {projectItems: {nodes: [{project: {id: "PVT_1"},
    fieldValues: {nodes: ($s | if . == "" then [] else [{name: ., field: {name: "Size"}}] end)}}]}}}}}' >"$FIX/item-$1.json"
}
delivery() { # pull-request closes-text commit-messages... : the pull request, its commits, no file yet
  local n=$1 body=$2
  shift 2
  pr "$n" OPEN "feat/$n-x" "$body"
  jq -nc --arg b "$body" '{number: 0, body: $b}' >"$FIX/pull-$n.json"
  printf '%s\n' "$@" | jq -R '{commit: {message: .}}' | jq -sc . >"$FIX/commits-$n.json"
}
changes() { # pull-request path:lines...
  local n=$1 f
  shift
  for f in "$@"; do jq -nc --arg p "${f%%:*}" --argjson c "${f##*:}" '{filename: $p, changes: $c}'; done | jq -sc . >"$FIX/files-$n.json"
}
for n in 301 302 303; do size $n S; done
size 304 M
# One ticket, 250 lines of an S budget of 300 (a lockfile, a fixture and generated code are not counted): ready.
delivery 300 "Closes #301" "feat: a"
changes 300 src/a.sh:250 package-lock.json:9000 tests/fixtures/big.json:5000 src/api.generated.ts:700 pnpm-lock.yaml:40
ready --pr 300 || fail "H: a pull request within its budget is not ready: $(cat "$work/out")"
said '^pull request #300 is ready$' || fail "H: no ready line: $(cat "$work/out")"
logged "pulls/300/commits" && fail "H: the commits of a single-ticket pull request were read"
# 400 lines of 300: not ready, by how much.
changes 300 src/a.sh:250 src/b.sh:150
ready --pr 300 && fail "H: a pull request over its budget is ready"
said 'pull request #300 is not ready: 400 changed lines, 100 over the size budget of 300' || fail "H: the excess is not said: $(cat "$work/out")"
# A single-ticket pull request needs no Refs: its one commit may say anything.
changes 300 src/a.sh:10
ready --pr 300 || fail "H: a single-ticket pull request needs no reference: $(cat "$work/out")"
# An M ticket has 800; limits.diffLines overrides one size and keeps the others.
delivery 305 "Closes #304" "feat: m"
changes 305 src/a.sh:700
ready --pr 305 || fail "H: an M pull request of 700 lines is not ready: $(cat "$work/out")"
jq '.limits = {diffLines: {M: 600}}' "$repo/.claude/senior-mode.json" >"$work/c" && mv "$work/c" "$repo/.claude/senior-mode.json"
ready --pr 305 && fail "H: limits.diffLines.M = 600 not applied"
said '100 over the size budget of 600' || fail "H: the configured budget is not said: $(cat "$work/out")"
ready --pr 300 || fail "H: the S budget was lost with a partial limits.diffLines: $(cat "$work/out")"
config '["auth/**"]'
# A batch closing three tickets: one commit per ticket, named when one is missing.
delivery 310 $'Closes #301\nCloses #302\nCloses #303' $'feat: a\n\nRefs #301' $'feat: b\n\nCloses #302'
changes 310 src/a.sh:100
ready --pr 310 && fail "H: a batch with a ticket without a commit is ready"
said 'pull request #310 is not ready: it closes 3 tickets and no commit references #303' || fail "H: the missing ticket is not named: $(cat "$work/out")"
said '#301|#302,' && fail "H: a referenced ticket is named as missing: $(cat "$work/out")"
delivery 310 $'Closes #301\nCloses #302\nCloses #303' $'feat: a\n\nRefs #301' $'feat: b\n\nCloses #302' $'feat: c\n\nRefs #303'
ready --pr 310 || fail "H: a batch with one commit per ticket is not ready: $(cat "$work/out")"
# A hotfix (#322) is held to the S budget, whatever its Size; its incident note is not counted.
size 306 M
echo '{"labels": [{"name": "hotfix"}]}' >"$FIX/issue-306.json"
delivery 307 "Closes #306" "fix: m"
changes 307 src/a.sh:400 docs/incidents/2026-11-24-306-down.md:60
ready --pr 307 && fail "H: a hotfix over the S budget is ready"
said 'pull request #307 is not ready: 400 changed lines, 100 over the size budget of 300 \(limits.diffLines: #306 S hotfix\)' || fail "H: the hotfix budget is not said: $(cat "$work/out")"
changes 307 src/a.sh:250 docs/incidents/2026-11-24-306-down.md:60
ready --pr 307 || fail "H: a hotfix within the S budget is not ready: $(cat "$work/out")"
rm -f "$FIX/issue-306.json"
# #3010 is not #301: a reference is the whole number.
delivery 311 $'Closes #301\nCloses #302' $'feat: a\n\nRefs #3010' $'feat: b\n\nRefs #302'
changes 311 src/a.sh:1
ready --pr 311 && fail "H: Refs #3010 counted for #301"
said "no commit references #301 " || fail "H: #301 not named: $(cat "$work/out" "$work/err")"
# The budgets of a batch add up: three S tickets hold 900 lines, and 901 is one too many.
delivery 312 $'Closes #301\nCloses #302\nCloses #303' 'Refs #301' 'Refs #302' 'Refs #303'
changes 312 src/a.sh:900
ready --pr 312 || fail "H: a batch at the sum of its budgets is not ready: $(cat "$work/out")"
changes 312 src/a.sh:901
ready --pr 312 && fail "H: a batch over the sum of its budgets is ready"
said '1 over the size budget of 900 \(limits.diffLines: #301 S, #302 S, #303 S\)' || fail "H: the batch budget is not said: $(cat "$work/out")"
# A ticket whose Size is unknown cannot be checked; it is not called ready.
size 301 ""
delivery 313 "Closes #301" "feat: a"
changes 313 src/a.sh:1
ready --pr 313 && fail "H: a ticket without a Size is ready"
said 'cannot be checked: the Size of #301 is unknown' || fail "H: unknown Size not said: $(cat "$work/out")"
# A framing pull request is still read as before.
pr 314 OPEN docs/wave "#10"
ready --pr 314 && fail "H: an open framing pull request accepted"
grep -q 'not merged' "$work/err" || fail "H: open framing pull request not explained: $(cat "$work/err")"

# I: the Self-review table (#356). Each acceptance criterion of a closed ticket needs a row with evidence;
# a missing row or an empty evidence is named. A ticket without criteria needs none.
size 401 S
size 402 S
printf '{"body": "## Why\\nx\\n\\n## Acceptance criteria\\n- Given a, then b.\\n- Given c, then d.\\n  more of d\\n\\n## Out of scope\\n- not this\\n"}' >"$FIX/issue-401.json"
printf '{"body": "## Acceptance criteria\\n\\n- Given e, then f.\\n"}' >"$FIX/issue-402.json"
delivery 400 "Closes #401" "feat: a"
changes 400 src/a.sh:10
ready --pr 400 && fail "I: a pull request without a Self-review table is ready"
said 'pull request #400 is not ready: the Self-review table has no row with evidence for #401.1, #401.2 ' || fail "I: the gaps are not named: $(cat "$work/out")"
delivery 400 $'Closes #401\n\n## Self-review\n\n| Criterion | Evidence |\n|---|---|\n| 1 Given a | test_a passes |\n| 2 Given c | - |\n' "feat: a"
ready --pr 400 && fail "I: an empty evidence is accepted"
said 'for #401.2 ' || fail "I: the criterion without evidence is not named: $(cat "$work/out")"
said '#401.1' && fail "I: a criterion with evidence is named: $(cat "$work/out")"
delivery 400 $'Closes #401\n\n## Self-review\n\n| Criterion | Evidence |\n|---|---|\n| #401.1 Given a | test_a passes |\n| #401.2 Given c | `make test`: 12 passed |\n' "feat: a"
ready --pr 400 || fail "I: a full Self-review table is not ready: $(cat "$work/out")"
# A batch: rows are #<ticket>.<k>; a bare number is ambiguous and does not count.
delivery 410 $'Closes #401\nCloses #402\n\n## Self-review\n| # | Evidence |\n|---|---|\n| #401.1 | t1 |\n| #401.2 | t2 |\n| 1 | t3 |\n' 'Refs #401' 'Refs #402'
changes 410 src/a.sh:10
ready --pr 410 && fail "I: a batch with a missing ticket row is ready"
said 'for #402.1 ' || fail "I: the batch gap is not named: $(cat "$work/out")"

# J: a spike (#321) ends in a note, an ADR or framed tickets, never in code: its pull request changes docs/ only.
spike() { jq -nc '{labels: [{name: "type:spike"}]}' >"$FIX/issue-$1.json"; }
size 330 S
size 331 S
spike 330
delivery 320 "Closes #330" "docs: what we learned"
changes 320 docs/spikes/oauth.md:40 docs/adr/0040-oauth.md:30
ready --pr 320 || fail "J: a spike pull request that changes docs/ only is not ready: $(cat "$work/out")"
changes 320 docs/spikes/oauth.md:40 src/a.sh:10 .github/workflows/x.yml:3
ready --pr 320 && fail "J: a spike pull request that changes code is ready"
said 'pull request #320 is not ready: #330 is a spike and its pull request changes code outside docs/ \(src/a.sh, .github/workflows/x.yml\)' ||
  fail "J: the code a spike changed is not named: $(cat "$work/out")"
changes 320 docs-old/a.md:1
ready --pr 320 && fail "J: docs-old/ passed for docs/"
changes 320 README.md:1
ready --pr 320 && fail "J: a file at the root passed for docs/"
delivery 321 "Closes #331" "feat: code"
changes 321 src/a.sh:10
ready --pr 321 || fail "J: a pull request of a ticket that is no spike is held to docs/: $(cat "$work/out")"
delivery 322 $'Closes #330\nCloses #331' $'docs: note\n\nRefs #330' $'feat: code\n\nCloses #331'
changes 322 docs/spikes/oauth.md:40 src/a.sh:10
ready --pr 322 && fail "J: a batch with a spike and code is ready"
said '#330 is a spike' || fail "J: the spike of a batch is not named: $(cat "$work/out")"

# K: red skeletons (#311). A file of the pull request named after a ticket that still says "not implemented", or
# that skips a test, keeps the ticket from being ready; a finished one, or one the head no longer has, does not.
size 341 S
printf '{"body": "## Acceptance criteria\\n- Given a, then b.\\n"}' >"$FIX/issue-341.json"
skeleton_pr() { # pull-request files...
  local n=$1
  shift
  delivery "$n" "Closes #341" "feat: a"
  jq -nc --arg b "Closes #341" '{number: 0, body: $b, head: {sha: "abc123"}}' >"$FIX/pull-$n.json"
  changes "$n" "$@"
}
content() { printf '%s\n' "$2" >"$FIX/content-${1%%/*}-${1##*/}"; }
selfreview=$'\n\n## Self-review\n\n| Criterion | Evidence |\n|---|---|\n| 1 Given a | t |\n'
skeleton_pr 340 src/a.sh:10 tests/ticket-341.test.ts:12
content tests/ticket-341.test.ts 'it("Given a, then b", () => { expect("not implemented").toBe("implemented"); });'
ready --pr 340 && fail "K: an unimplemented skeleton is ready"
said 'pull request #340 is not ready: a red skeleton is still unimplemented or skipped in tests/ticket-341.test.ts \(#341\)' ||
  fail "K: the skeleton is not named: $(cat "$work/out")"
content tests/ticket-341.test.ts 'it.skip("Given a, then b", () => { expect(1).toBe(1); });'
ready --pr 340 && fail "K: a skipped skeleton is ready"
content tests/ticket-341.test.ts 'it("Given a, then b", () => { expect(add(1, 1)).toBe(2); });'
delivery 340 $'Closes #341'"$selfreview" "feat: a"
jq -nc --arg b $'Closes #341'"$selfreview" '{number: 0, body: $b, head: {sha: "abc123"}}' >"$FIX/pull-340.json"
ready --pr 340 || fail "K: a finished skeleton is not ready: $(cat "$work/out")"
# Another ticket's number is no match: ticket-3410 is not the skeleton of #341.
content tests/ticket-3410.test.ts 'it("x", () => { expect("not implemented").toBe("implemented"); });'
changes 340 src/a.sh:10 tests/ticket-3410.test.ts:12
ready --pr 340 || fail "K: the skeleton of #3410 held #341: $(cat "$work/out")"
# A skeleton the head no longer has is not read.
changes 340 src/a.sh:10 tests/ticket-341.test.ts:0 tests/ticket_341_test.go:3
ready --pr 340 || fail "K: a removed skeleton held the ticket: $(cat "$work/out")"

# L: the hierarchy (#358). With hierarchy.enforce a ticket needs a parent epic under a milestone with a Goal: line,
# unless it carries an exempt label (security, hotfix) or sits under the maintenance epic.
config '[]'
cp "$repo/.claude/senior-mode.json" "$work/config.plain"
parented() { # <number> <parent json>
  items=$(jq -c --argjson n "$1" --argjson p "$2" 'map(if .content.number == $n then .content.parent = $p else . end)' <<<"$items")
}
epic() { # <number> <labels json> <milestone json>
  jq -nc --argjson n "$1" --argjson l "$2" --argjson m "$3" '{number: $n, labels: {nodes: ($l | map({name: .}))}, milestone: $m}'
}
goal='{"title": "v1.0", "description": "Release gate.\nGoal: G1\n"}'
nogoal='{"title": "v2.0", "description": "Things we would like."}'
items="[]"
item 30 Backlog "P2 later" S - "docs/**" '[]' "$criteria$agent"
item 31 Backlog "P2 later" S - "docs/**" '[]' "$criteria$agent"
item 32 Backlog "P2 later" S - "docs/**" '[]' "$criteria$agent"
item 33 Backlog "P2 later" S - "docs/**" '[]' "$criteria$agent"
item 34 Backlog "P2 later" S - "docs/**" '["hotfix"]' "$criteria$agent"
item 35 Backlog "P2 later" S low "docs/**" '["security"]' "$criteria$agent"
item 36 Backlog "P2 later" S - "docs/**" '[]' "$criteria$agent"
parented 31 "$(epic 200 '["epic"]' "$goal")"
parented 32 "$(epic 201 '[]' "$nogoal")"
parented 33 "$(epic 202 '["maintenance"]' null)"
parented 36 "$(epic 203 '[]' null)"
board
jq '.hierarchy = {enforce: true}' "$work/config.plain" >"$repo/.claude/senior-mode.json"
ready || fail "L: ready failed: $(cat "$work/err")"
labelled 30 || fail "L: an orphan was not labelled needs-human"
grep -F 'issues/30/comments' "$GH_LOG" | grep -q 'no parent epic' || fail "L: the comment does not name the missing link: $(grep 'issues/30/comments' "$GH_LOG")"
labelled 32 || fail "L: an epic whose milestone has no goal was accepted"
grep -F 'issues/32/comments' "$GH_LOG" | grep -q 'v2.0' || fail "L: the comment does not name the milestone: $(grep 'issues/32/comments' "$GH_LOG")"
labelled 36 || fail "L: an epic with no milestone was accepted"
for n in 31 33 34 35; do
  said "^#$n Status = Ready" || fail "L: #$n (goal, maintenance, exempt label) is not Ready: $(cat "$work/out")"
  labelled "$n" && fail "L: #$n got needs-human"
done
ready --dry-run || fail "L: dry run failed"
said '^#30 would get needs-human: .*no parent epic' || fail "L: dry run does not say #30 is an orphan: $(cat "$work/out")"
# hierarchy.exempt replaces the default list.
jq '.hierarchy = {enforce: true, exempt: ["chore"]}' "$work/config.plain" >"$repo/.claude/senior-mode.json"
ready --dry-run || fail "L: dry run with exempt failed"
said '^#34 would get needs-human: .*no parent epic' || fail "L: hierarchy.exempt did not replace the default: $(cat "$work/out")"
# Enforcement off (the default): nothing changes.
cp "$work/config.plain" "$repo/.claude/senior-mode.json"
ready --dry-run || fail "L: dry run without enforcement failed"
said '^#30 would be Ready' || fail "L: an orphan is refused without hierarchy.enforce: $(cat "$work/out")"
said '^#32 would be Ready' || fail "L: a goalless milestone is refused without hierarchy.enforce: $(cat "$work/out")"
# A ticket under a parent that was full says `Part of #200` in its body (#614): it has a parent epic, with no
# sub-issue link; a `Part of` line elsewhere than on its own line does not count.
item 37 Backlog "P2 later" S - "docs/**" '[]' "$criteria$agent"$'\nPart of #200\n'
item 38 Backlog "P2 later" S - "docs/**" '[]' "$criteria$agent"$'\nThis is not Part of #200 at all\n'
board
jq '.hierarchy = {enforce: true}' "$work/config.plain" >"$repo/.claude/senior-mode.json"
ready --dry-run || fail "L: dry run with a Part of line failed"
said '^#37 would be Ready' || fail "L: a ticket with a Part of line is an orphan: $(cat "$work/out")"
said '^#38 would get needs-human: .*no parent epic' || fail "L: Part of in a sentence was taken for a parent: $(cat "$work/out")"
cp "$work/config.plain" "$repo/.claude/senior-mode.json"

# M: skill evals (#368). An improvement ticket (its body carries the `retro-cause:` line) that changes a skill or
# an agent needs a before/after eval table in its pull request: several runs, an after score not below the before.
mkdir -p "$repo/evals/knowledge" "$repo/evals/other"
: >"$repo/evals/knowledge/run.sh"
: >"$repo/evals/other/run.sh"
size 501 S
size 502 S
printf '{"body": "## Acceptance criteria\\n- Given a, then b.\\n\\nretro-cause: fuzzy-criterion tdd\\n"}' >"$FIX/issue-501.json"
printf '{"body": "## Acceptance criteria\\n- Given a, then b.\\n"}' >"$FIX/issue-502.json"
sr=$'\n\n## Self-review\n\n| Criterion | Evidence |\n|---|---|\n| 1 Given a | t |\n'
evalpr() { # pull-request ticket eval-section files...
  local n=$1 t=$2 e=$3
  shift 3
  delivery "$n" "Closes #$t$sr$e" "feat: a"
  changes "$n" "$@"
}
tbl=$'\n\n## Eval\n\n| Case | Before | After |\n|---|---|---|\n'
evalpr 500 501 "" plugins/senior-mode/skills/tdd/SKILL.md:10
ready --pr 500 && fail "M: an improvement pull request on a skill without an eval table is ready"
said 'pull request #500 is not ready: #501 answers a failure cause and changes a skill or agent \(plugins/senior-mode/skills/tdd/SKILL.md\) but its body has no Eval table' ||
  fail "M: the missing table is not said: $(cat "$work/out")"
said 'evals/compare.sh <case> \(knowledge, other\)' || fail "M: the cases to run are not named: $(cat "$work/out")"
evalpr 500 501 "$tbl| knowledge | 1/3 | 3/3 |" plugins/senior-mode/agents/implementer.md:10
ready --pr 500 || fail "M: an agent change with a better after score is not ready: $(cat "$work/out")"
evalpr 500 501 "$tbl| knowledge | 2/3 | 2/3 |" plugins/senior-mode/skills/tdd/SKILL.md:10
ready --pr 500 || fail "M: an equal after score is not ready: $(cat "$work/out")"
evalpr 500 501 "$tbl| knowledge | 3/3 | 2/3 |" plugins/senior-mode/skills/tdd/SKILL.md:10
ready --pr 500 && fail "M: an after score below the before score is ready"
said 'pull request #500 is not ready: the Eval table of #501 shows knowledge at 2/3 after, below 3/3 before' ||
  fail "M: the regression is not named: $(cat "$work/out")"
evalpr 500 501 "$tbl| knowledge | 0/1 | 1/1 |" plugins/senior-mode/skills/tdd/SKILL.md:10
ready --pr 500 && fail "M: a single run per side is ready"
said 'knowledge with fewer than 2 runs' || fail "M: the run count is not said: $(cat "$work/out")"
evalpr 500 501 "$tbl| knowledge | many | few |" plugins/senior-mode/skills/tdd/SKILL.md:10
ready --pr 500 && fail "M: a table with no score is ready"
said 'has no Eval table' || fail "M: a table with no score is not refused as missing: $(cat "$work/out")"
# Only a change to a skill or an agent is held to it, and only an improvement ticket.
evalpr 500 501 "" src/a.sh:10 docs/guide/skills.md:4
ready --pr 500 || fail "M: an improvement pull request that changes no skill is held to an eval: $(cat "$work/out")"
evalpr 500 502 "" plugins/senior-mode/skills/tdd/SKILL.md:10
ready --pr 500 || fail "M: a pull request of an ordinary ticket is held to an eval: $(cat "$work/out")"

# N (#632): a ticket that declares a tool absent from the machine (`Needs:`) is kept out of Ready, with that reason.
items="[]"
item 120 Backlog "P1 next" S - "docs/**" '[]' "$criteria"$'\nNeeds: sh, no-such-tool-632\n'
item 121 Backlog "P1 next" S - "docs/**" '[]' "$criteria"$'\nNeeds: sh\n'
board
pr 130 MERGED docs/wave-n "Framing: #120 #121"
ready --pr 130 || fail "N: ready failed: $(cat "$work/err")"
labelled 120 || fail "N: #120, whose tool is absent, is not held back"
said '^#120 needs-human: .*tool not installed: no-such-tool-632' || fail "N: the missing tool is not named: $(cat "$work/out")"
said '^#121 Status = Ready' || fail "N: #121, whose tool is there, is not Ready: $(cat "$work/out")"

# O (#610): the summary also ends a run with no candidate, and says why.
pr 131 MERGED docs/wave-o "Framing: nothing filed yet, see the board."
ready --pr 131 --dry-run || fail "O: ready failed: $(cat "$work/err")"
said '^no candidate: pull request #131 names no ticket; skipped 2: 2 not named in the pull request$' || fail "O: a pull request naming no ticket is not said: $(cat "$work/out")"
pr 132 MERGED docs/wave-o "Framing: #121."
ready --pr 132 || fail "O: ready failed: $(cat "$work/err")"
said '^ready: 1 considered, 1 set Ready, 0 needs-human; skipped 1: 1 not named in the pull request$' || fail "O: summary after one ticket: $(cat "$work/out")"
items="[]"
item 140 Backlog "P1 next" S - "docs/**" '[]' "$criteria"
item 141 Backlog "P1 next" S - "docs/**" '["needs-human"]' "$criteria$agent"
board
ready --dry-run || fail "O: ready failed: $(cat "$work/err")"
said '^no candidate: no open Backlog ticket filed by an agent can be considered; skipped 2: 1 needs-human, 1 not agent-filed$' ||
  fail "O: no agent ticket is not said: $(cat "$work/out")"
logged "item-add" && fail "O: a run with no candidate set a Status"

# P (#611): the criteria are found under `## Criteria` and `## Acceptance` as under `## Acceptance criteria`, by the
# Ready rule and by the Self-review check; a heading that only starts with the word is not one.
items="[]"
item 150 Backlog "P1 next" S - "docs/**" '[]' $'## Context\n\nx\n\n## Criteria\n\n- Given a, when b, then c.\n'
item 151 Backlog "P1 next" S - "docs/**" '[]' $'## Acceptance\n\n1. Given a, when b, then c.\n'
item 152 Backlog "P1 next" S - "docs/**" '[]' $'### criteria:\n- Given a, when b, then c.\n'
item 153 Backlog "P1 next" S - "docs/**" '[]' $'## Criteria for the rollout\n\n- not a list of criteria\n'
board
pr 160 MERGED docs/wave-p "Framing: #150 #151 #152 #153"
ready --pr 160 || fail "P: ready failed: $(cat "$work/err")"
for n in 150 151 152; do said "^#$n Status = Ready" || fail "P: #$n, whose criteria are under a common heading, is not Ready: $(cat "$work/out")"; done
labelled 153 || fail "P: #153, without a criteria heading, is not held back"
said '^#153 needs-human: .*acceptance criteria' || fail "P: #153 report: $(cat "$work/out")"
size 403 S
printf '{"body": "## Why\\nx\\n\\n## Criteria\\n- Given a, then b.\\n- Given c, then d.\\n\\n## Out of scope\\n- not this\\n"}' >"$FIX/issue-403.json"
delivery 420 "Closes #403" "feat: a"
changes 420 src/a.sh:10
ready --pr 420 && fail "P: a pull request without a Self-review table is ready"
said 'no row with evidence for #403.1, #403.2 ' || fail "P: the criteria under ## Criteria are not read: $(cat "$work/out")"

# Q (#637): the size budget weighs test lines at 0.5 and documentation lines at 0.25 (limits.diffWeights), and
# skips the globs of limits.diffExclude; a skill or an agent is code.
size 301 S
delivery 430 "Closes #301" "feat: a"
changes 430 src/a.sh:100 tests/test-a.sh:200 plugins/x/bin/tests/b.test.ts:200
ready --pr 430 || fail "Q: 100 code and 400 test lines (300 weighted) are not ready: $(cat "$work/out")"
changes 430 src/a.sh:100 tests/test-a.sh:402
ready --pr 430 && fail "Q: 100 code and 402 test lines (301 weighted) are ready"
said 'pull request #430 is not ready: 301 changed lines \(100 of code, 402 of tests counted at 0.5, 0 of docs counted at 0.25\), 1 over the size budget of 300' ||
  fail "Q: the code and test counts are not said: $(cat "$work/out")"
changes 430 src/a.sh:200 README.md:200 docs/guide/x.md:200
ready --pr 430 || fail "Q: 200 code and 400 doc lines (300 weighted) are not ready: $(cat "$work/out")"
changes 430 src/a.sh:100 plugins/x/skills/y/SKILL.md:201
ready --pr 430 && fail "Q: the Markdown of a skill was weighed as documentation"
changes 430 src/a.sh:10 src/gen/a.ts:1000 src/gen/deep/b.ts:1000
ready --pr 430 && fail "Q: unlisted generated files were not counted"
jq '.limits = {diffExclude: ["src/gen/*"]}' "$repo/.claude/senior-mode.json" >"$work/c" && mv "$work/c" "$repo/.claude/senior-mode.json"
ready --pr 430 || fail "Q: limits.diffExclude is not applied: $(cat "$work/out")"
jq '.limits = {diffWeights: {tests: 1}}' "$repo/.claude/senior-mode.json" >"$work/c" && mv "$work/c" "$repo/.claude/senior-mode.json"
changes 430 src/a.sh:100 tests/test-a.sh:201
ready --pr 430 && fail "Q: limits.diffWeights.tests = 1 not applied"
said '301 changed lines' || fail "Q: the configured weight is not applied: $(cat "$work/out")"
config '["auth/**"]'

# R (#687): an open issue that is not on the Project is added to Backlog by `ready`, once; one labelled wontfix, or on
# the Project already, is not; --dry-run only says it; --pr does not sweep.
orphan() { # number project-id|- label|-
  jq -nc --argjson n "$1" --arg p "$2" --arg l "$3" '{number: $n, labels: {nodes: ($l | if . == "-" then [] else [{name: .}] end)},
    projectItems: {nodes: ($p | if . == "-" then [] else [{project: {id: .}}] end)}}'
}
{ orphan 700 - -; orphan 701 PVT_1 -; orphan 702 - wontfix; orphan 703 PVT_9 -; } | jq -sc '{data: {repository: {issues: {pageInfo: {hasNextPage: false}, nodes: .}}}}' >"$FIX/orphans.json"
items="[]"
item 710 Backlog "P1 next" S - "docs/**" '[]' "$criteria"
board
ready --dry-run || fail "R: dry run failed: $(cat "$work/err")"
said '^would be added to the board: #700 #703$' || fail "R: the dry run does not name #700 and #703: $(cat "$work/out")"
logged "item-add" && fail "R: the dry run added an issue"
ready || fail "R: ready failed: $(cat "$work/err")"
said '^added to the board: #700 #703$' || fail "R: the orphans are not listed: $(cat "$work/out")"
logged "project item-add 3 --owner acme --url https://github.com/acme/app/issues/700" || fail "R: #700 not added"
grep -c 'item-edit.*--single-select-option-id o1' "$GH_LOG" | grep -qx 2 || fail "R: #700 and #703 are not set Backlog: $(cat "$GH_LOG")"
logged "issues/701" && fail "R: #701 is on the Project already"
logged "issues/702" && fail "R: #702 is wontfix"
pr 101 MERGED docs/wave "Framing: #710."
ready --pr 101 || fail "R: ready --pr failed: $(cat "$work/err")"
said 'added to the board' && fail "R: ready --pr swept the board"
logged "issues/700" && fail "R: ready --pr added #700"
rm -f "$FIX/orphans.json"
ready || fail "R: ready failed: $(cat "$work/err")"
said 'added to the board' && fail "R: something is added with no orphan: $(cat "$work/out")"
# S (#422): a refactor that edits the assertions a characterization commit pinned is not ready; a behaviour change, or a
# refactor that only adds to them, is.
commits_of() { # pull-request sha:subject...
  local n=$1 c
  shift
  for c in "$@"; do jq -nc --arg s "${c%%:*}" --arg m "${c#*:}" '{sha: $s, commit: {message: $m}}'; done | jq -sc . >"$FIX/commits-$n.json"
}
commit_files() { # sha filename patch
  jq -nc --arg f "$2" --arg p "$3" '{files: [{filename: $f, patch: $p}]}' >"$FIX/commit-$1.json"
}
size 601 S
delivery 600 "Closes #601" "feat: a"
changes 600 src/pricing.sh:6 tests/test-pricing.sh:8
commit_files c1 tests/test-pricing.sh $'@@ -0,0 +1,2 @@\n+price is 10'
commit_files c2 src/pricing.sh $'@@ -1 +1 @@\n-old\n+new'
commit_files c3 tests/test-pricing.sh $'@@ -1,2 +1,2 @@\n-price is 10\n+price is 12'
commits_of 600 "c1:test(pricing): characterize price" "c2:refactor(pricing): reshape" "c3:refactor(pricing): follow"
ready --pr 600 && fail "S: a refactor that edits a pinned assertion is ready"
said 'pull request #600 is not ready: a refactor edits what a characterization commit pinned: c3 \(tests/test-pricing.sh\)' ||
  fail "S: the pinned edit is not named: $(cat "$work/out")"
commits_of 600 "c1:test(pricing): characterize price" "c2:feat(pricing): reshape" "c3:feat(pricing): follow"
ready --pr 600 || fail "S: a behaviour change that edits an assertion is not ready: $(cat "$work/out")"
commit_files c3 tests/test-pricing.sh $'@@ -2,0 +3 @@\n+another case'
commits_of 600 "c1:test(pricing): characterize price" "c2:refactor(pricing): reshape" "c3:refactor(pricing): more"
ready --pr 600 || fail "S: a refactor that only adds a case is not ready: $(cat "$work/out")"
# No test file in the pull request: its commits are not read.
changes 600 src/pricing.sh:6
: >"$GH_LOG"
ready --pr 600 || fail "S: a pull request with no test file is not ready: $(cat "$work/out")"
logged "pulls/600/commits" && fail "S: the commits were read for a pull request with no test file"

[ "$failures" -eq 0 ] && echo "ready: all cases pass"
exit "$((failures > 0))"
