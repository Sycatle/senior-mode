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
  "api graphql --input -") cat >/dev/null; cat "$FIX/board.json" ;;
  "pr view "*) n=$(sed -E 's#^pr view ([0-9]+) .*#\1#' <<<"$*"); respond <"$FIX/pr-$n.json" ;;
  "project item-add"*) echo "ITEM_$(sed -E 's#.*/issues/([0-9]+).*#\1#' <<<"$*")" ;;
  "project item-edit"*) ;;
  "api repos/acme/app/issues/"*"/labels"*) echo '[]' ;;
  "api repos/acme/app/issues/"*"/comments"*) echo '{}' ;;
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
    '. + [{fieldValues: {nodes: $f}, content: {number: $n, state: $s, body: $b, labels: {nodes: ($l | map({name: .}))}}}]' <<<"$items")
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

[ "$failures" -eq 0 ] && echo "ready: all cases pass"
exit "$((failures > 0))"
