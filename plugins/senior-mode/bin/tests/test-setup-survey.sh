#!/usr/bin/env bash
# Tests for the architecture survey of `senior-mode setup repo --adopt` on a legacy project (#419, spec 409 section 4),
# `senior-mode survey` and the `Project conventions` block of the briefing. Offline: gh is a stub; the repository is a real
# one with a bare origin of its own at <work>/github.com/acme/app.git (so that the slug is acme/app).
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
  *) exit 1 ;;
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
logged() { grep -qF -- "$1" "$GH_LOG"; }

# A legacy project: an api layer, an ui layer that reaches into the api layer (a violation of the rule the survey proposes),
# many fixes to the api, an old ADR, and a config that says it is legacy and caps the notes at 3.
mkdir -p "$repo/.claude" "$repo/src/api" "$repo/src/ui" "$repo/src/old" "$repo/docs/adr"
printf 'export const get = () => 1\n// TODO one\n' >"$repo/src/api/get.ts"
printf 'export const put = () => 2\n' >"$repo/src/api/put.ts"
printf 'import { get } from "../api/get"\nexport const view = () => get()\n' >"$repo/src/ui/view.ts"
printf 'export const old = 1\n' >"$repo/src/old/a.ts"
printf 'export const old = 2\n' >"$repo/src/old/b.ts"
printf 'export const old = 3\n' >"$repo/src/old/c.ts"
printf -- '---\nid: 0007\ntitle: Existing\nstatus: accepted\n---\n\n# Existing\n' >"$repo/docs/adr/0007-existing.md"
echo '{"language": "en", "adopt": {"kind": "legacy"}, "commands": {"test": "true"}, "survey": {"maxNotes": 3}}' >"$repo/.claude/senior-mode.json"
g add -A
g commit -q -m "chore: start"
for i in $(seq 1 16); do
  echo "// $i" >>"$repo/src/api/put.ts"
  g commit -q -am "fix: api bug $i"
done
g push -q origin main
b=docs/adopt-senior-mode

# The measures: JSON, one row per zone, with the signals.
(cd "$repo" && "$cli" survey) >"$work/m.json" 2>"$work/err" || fail "survey failed: $(cat "$work/err")"
[ "$(jq -r '.zones | map(select(.path == "src/api")) | .[0] | "\(.files) \(.tests) \(.touches) \(.fixes) \(.todo)"' "$work/m.json")" = "2 0 17 16 1" ] ||
  fail "src/api measures: $(jq -c '.zones' "$work/m.json")"
[ "$(jq -r '.zones | map(select(.path == "src/ui")) | .[0].imports["src/api"]' "$work/m.json")" = 1 ] || fail "import edge ui to api missing: $(jq -c '.zones' "$work/m.json")"
[ "$(jq -r '.zones | map(select(.path == "src/api")) | .[0].importedBy' "$work/m.json")" = 1 ] || fail "importedBy missing"
jq -e '.zones | map(select(.path == "src/old")) | .[0].signals | index("no tests")' "$work/m.json" >/dev/null || fail "no tests signal missing on src/old"

# The drafts of the architect agent.
s="$repo/.claude/survey"
mkdir -p "$s/notes" "$s/risks" "$s/adrs"
printf '# Architecture\n\n## Overview\nTwo layers: `src/api` and `src/ui`.\n\n## Components\n- `src/api`: handlers\n- `src/ui`: views\n' >"$s/map.md"
note() { # name kind heading
  printf -- '---\npaths: ["src/api/**"]\nverified: 1999-01-01\norigin: "#1"\nkind: %s\n---\n\n# %s\n\nEvidence: `src/api/get.ts`.\n' "$2" "$3" >"$s/notes/$1.md"
}
note convention-handlers convention "Handlers return a Result"
note n2 pitfall "Second"
note n3 context "Third"
note n4 context "Fourth, over the cap"
printf -- '---\npaths: ["src/old/**"]\nkind: pitfall\n---\n\n# Risk: src/old\n\nNo tests, no change in 12 months. Action: delete or cover it.\n' >"$s/risks/old.md"
printf -- '---\ntitle: Layers api and ui\nconfidence: high\npaths: ["src/**"]\nevidence: ["README.md: layering section"]\n---\n\n## Context\nTwo layers.\n\n## Decision\nWe keep ui above api.\n\n## Why\nThe README says so.\n' >"$s/adrs/layers.md"
printf -- '---\ntitle: Handlers return a Result\nconfidence: high\npaths: ["src/api/**"]\nevidence: []\n---\n\n## Context\nAll handlers return Result.\n\n## Decision\nWe return Result.\n\n## Why\nBecause errors are values.\n' >"$s/adrs/result.md"
printf -- '---\ntitle: Views are plain functions\nconfidence: low\npaths: ["src/ui/**"]\nevidence: []\n---\n\n## Context\nViews are functions.\n\n## Decision\nWe write views as functions.\n\n## Alternatives\nClasses.\n' >"$s/adrs/views.md"
jq -nc '[{id: "ui-not-api", forbidImport: {from: "src/ui/**", to: "src/api/**"}, why: "the ui goes through a service"},
  {id: "broken", forbidImport: {from: "src/ui/**"}}]' >"$s/rules.json"
echo '["src/auth/**", "src/payments/**"]' >"$s/protected.json"

snapshot() { (cd "$repo" && git status --porcelain && git worktree list && find . -path ./.git -prune -o -type f -print0 | sort -z | xargs -0 sha1sum); }
adopt() { : >"$GH_LOG"; (cd "$repo" && "$cli" setup repo "$@") >"$work/out" 2>"$work/err"; }
show() { git -C "$origin" show "$1:$2"; }
has() { git -C "$origin" cat-file -e "$1:$2" 2>/dev/null; }

# A dry run prints the files and the measures and writes nothing.
snapshot >"$work/before"
adopt --dry-run || fail "dry run failed: $(cat "$work/err")"
for want in "## Survey" "\`src/api\`: 2 files, 0 tests, 17 changes of which 16 fixes" "high churn and fixes" "no tests" \
  "docs/architecture.md" "docs/knowledge/convention-handlers.md" "docs/knowledge/n3.md" "docs/adr/0008-layers.md" \
  "docs/adr/0009-result.md" "docs/adr/0010-views.md" "rule \`ui-not-api\`" "protected" "dry run: nothing changed"; do
  grep -qF -- "$want" "$work/out" || fail "dry run without '$want': $(cat "$work/out")"
done
snapshot >"$work/after"
cmp -s "$work/before" "$work/after" || fail "dry run changed the checkout: $(diff "$work/before" "$work/after")"
logged "pr create" && fail "dry run opened a pull request"

# The run: one pull request on docs/adopt-senior-mode holding the map, notes, ADRs, rules, risk zones and the baseline.
adopt --adopt || fail "adopt failed: $(cat "$work/err")"
logged "pr create --repo acme/app --base main --head $b" || fail "no pull request: $(cat "$GH_LOG")"
[ "$(git -C "$origin" rev-list --count main.."$b")" = 1 ] || fail "not exactly one commit"
git -C "$origin" diff --name-only main "$b" | grep -q '^src/' && fail "the survey changed code: $(git -C "$origin" diff --name-only main "$b")"
show "$b" docs/architecture.md | grep -q 'Two layers' || fail "the map is not in docs/architecture.md: $(show "$b" docs/architecture.md)"
show "$b" docs/architecture.md | grep -q 'senior-mode:architecture sha=' || fail "no generated block after the map"
# Notes: the 3 first are written, with the survey origin and the day; the fourth and the risk zone are listed.
for n in convention-handlers n2 n3; do
  has "$b" docs/knowledge/$n.md || fail "note $n not written"
done
has "$b" docs/knowledge/n4.md && fail "the note over survey.maxNotes was written"
has "$b" docs/knowledge/risk-old.md && fail "the risk note over the cap was written"
show "$b" docs/knowledge/n2.md | grep -qx 'origin: "survey"' || fail "origin not survey: $(show "$b" docs/knowledge/n2.md)"
show "$b" docs/knowledge/n2.md | grep -q "^verified: $(date -u +%F)\$" || fail "verified not the survey day: $(show "$b" docs/knowledge/n2.md)"
body=$(grep -F -- '--body' "$GH_LOG" | head -n 1; sed -n '/--body/,$p' "$GH_LOG")
grep -qF 'Not written, over `survey.maxNotes` (3)' <<<"$body" || fail "the notes left out are not listed: $body"
grep -qF 'docs/knowledge/n4.md' <<<"$body" || fail "n4 not listed in the pull request"
grep -qF 'docs/knowledge/risk-old.md' <<<"$body" || fail "the risk zone left out is not listed"
# ADRs: numbered after the existing one; no stated reason is never high; low is proposed.
a1=$(show "$b" docs/adr/0008-layers.md)
grep -qx 'confidence: high' <<<"$a1" && grep -qx 'status: accepted' <<<"$a1" && grep -qx 'retroactive: true' <<<"$a1" || fail "ADR with a stated reason: $a1"
grep -q 'The README says so' <<<"$a1" || fail "the evidenced Why was rewritten: $a1"
a2=$(show "$b" docs/adr/0009-result.md)
grep -qx 'confidence: medium' <<<"$a2" || fail "high without evidence not downgraded: $a2"
grep -qi 'not documented' <<<"$a2" && ! grep -q 'errors are values' <<<"$a2" || fail "an invented Why was kept: $a2"
a3=$(show "$b" docs/adr/0010-views.md)
grep -qx 'confidence: low' <<<"$a3" && grep -qx 'status: proposed' <<<"$a3" || fail "low is not proposed: $a3"
grep -qi 'not documented' <<<"$a3" || fail "low without 'not documented': $a3"
# Rules and baseline; the invalid rule is refused; protected is only proposed.
[ "$(show "$b" .claude/senior-mode.json | jq -c '[.architecture.rules[].id]')" = '["ui-not-api"]' ] || fail "rules: $(show "$b" .claude/senior-mode.json)"
[ "$(show "$b" .claude/architecture-baseline.json | jq -c '.violations')" = '[{"rule":"ui-not-api","file":"src/ui/view.ts","count":1}]' ] ||
  fail "baseline: $(has "$b" .claude/architecture-baseline.json && show "$b" .claude/architecture-baseline.json)"
grep -qF 'not written: rule broken' <<<"$body" || grep -qF 'broken' <<<"$body" || fail "the invalid rule is not reported"
show "$b" .claude/senior-mode.json | jq -e '.protected // [] | index("src/auth/**") | not' >/dev/null || fail "protected was changed, it is only proposed"
grep -qF '"protected": ["src/auth/**","src/payments/**"]' <<<"$body" || fail "the protected proposal is not in the pull request: $body"
grep -qF -- '- [ ] `docs/adr/0010-views.md` — confidence low, proposed' <<<"$body" || fail "no checkbox with the confidence: $body"
[ -e "$repo/.claude/survey" ] && fail "the drafts are left after the pull request"
[ "$(git -C "$repo" worktree list | wc -l)" = 1 ] || fail "the temporary worktree is left"
# What it wrote passes the project's own checks.
clone="$work/clone"
git clone -q -b "$b" "$origin" "$clone"
for sub in knowledge-check architecture-check; do
  (cd "$clone" && "$cli" "$sub") >"$work/sub.out" 2>&1 || fail "$sub fails on the result: $(cat "$work/sub.out")"
done

# Merged, then a second run: nothing existing is rewritten, the new findings are a pull request of their own.
git -C "$origin" update-ref refs/heads/main "refs/heads/$b"
git -C "$repo" fetch -q origin
g merge -q --ff-only origin/main
rm -f "$FIX/open-pr"
mkdir -p "$s/notes" "$s/adrs"
note convention-handlers convention "Rewritten, must not land"
note n4 context "Fourth, now in"
printf -- '---\ntitle: Layers api and ui\nconfidence: high\npaths: ["src/**"]\nevidence: ["x"]\n---\n\n## Decision\nWe rewrote it.\n' >"$s/adrs/layers.md"
printf -- '---\ntitle: Money in cents\nconfidence: medium\npaths: ["src/**"]\nevidence: []\n---\n\n## Context\nIntegers.\n\n## Decision\nWe store cents.\n' >"$s/adrs/cents.md"
printf '# Architecture\n\nRewritten.\n' >"$s/map.md"
adopt --adopt || fail "second adopt failed: $(cat "$work/err")"
b2=$b
logged "pr create" || fail "no pull request for the new findings: $(cat "$GH_LOG")"
[ "$(show "$b2" docs/knowledge/convention-handlers.md)" = "$(git -C "$repo" show main:docs/knowledge/convention-handlers.md)" ] || fail "an existing note was rewritten"
[ "$(show "$b2" docs/adr/0008-layers.md)" = "$(git -C "$repo" show main:docs/adr/0008-layers.md)" ] || fail "an existing ADR was rewritten"
[ "$(show "$b2" docs/architecture.md)" = "$(git -C "$repo" show main:docs/architecture.md)" ] || fail "docs/architecture.md was rewritten"
has "$b2" docs/knowledge/n4.md || fail "the new note is not in the second pull request"
show "$b2" docs/adr/0011-cents.md | grep -qx 'confidence: medium' || fail "the new ADR is not numbered after the existing ones: $(git -C "$origin" diff --name-only main "$b2")"
git -C "$origin" diff --name-only main "$b2" | grep -qE '^docs/(adr/0008|knowledge/convention)' && fail "the second pull request touches existing files"

# Without drafts, the adoption says what to do; an evergreen project is not surveyed.
rm -rf "$s"
adopt --dry-run || fail "dry run without drafts failed"
grep -q 'No drafts in `.claude/survey/`' "$work/out" || fail "no word on the missing drafts: $(cat "$work/out")"
jq '.adopt.kind = "evergreen"' "$repo/.claude/senior-mode.json" >"$work/c" && cp "$work/c" "$repo/.claude/senior-mode.json"
adopt --dry-run || fail "evergreen dry run failed"
grep -q '## Survey' "$work/out" && fail "an evergreen project was surveyed"

# The briefing: a convention note on src/api/** opens the project block; the rest follows.
git -C "$repo" checkout -q -- .claude/senior-mode.json
g checkout -q -b feat/5-handler
gitdir=$(git -C "$repo" rev-parse --absolute-git-dir)
mkdir -p "$gitdir/senior-mode/ticket"
jq -nc '{number: 5, title: "Handler", state: "OPEN", body: "Paths: src/api/**\n\n## Acceptance criteria\n- Given a handler, then it returns a Result", projectItems: [], paths: ["src/api/**"], parent: null}' \
  >"$gitdir/senior-mode/ticket/5.json"
jq '.workflow = {integration: "main", commit: {format: "conventional"}, merge: "squash"}' "$repo/.claude/senior-mode.json" >"$work/c" && cp "$work/c" "$repo/.claude/senior-mode.json"
printf '# Repo\n' >"$repo/CLAUDE.md"
printf '{}' >"$repo/biome.json"
(cd "$repo" && "$cli" context) >"$work/ctx" 2>"$work/err" || fail "context failed: $(cat "$work/err")"
first=$(grep -n 'Project conventions' "$work/ctx" | head -n 1 | cut -d: -f1)
other=$(grep -nE '^(ADRs that govern|Knowledge notes on|Specs that govern)' "$work/ctx" | head -n 1 | cut -d: -f1)
[ -n "$first" ] || fail "no Project conventions block: $(cat "$work/ctx")"
[ -z "$other" ] || [ "$first" -lt "$other" ] || fail "the conventions do not come first: $(cat "$work/ctx")"
sed -n "$first,\$p" "$work/ctx" | sed -n '1,/^$/p' | grep -qF 'docs/knowledge/convention-handlers.md' || fail "the convention note is not under Project conventions: $(cat "$work/ctx")"
sed -n "$first,\$p" "$work/ctx" | sed -n '1,/^$/p' | grep -q 'workflow: .*commits conventional, merge squash' || fail "the workflow is not in the block: $(cat "$work/ctx")"
sed -n "$first,\$p" "$work/ctx" | sed -n '1,/^$/p' | grep -q 'architecture rules.*ui-not-api' || fail "the rules are not in the block"
sed -n "$first,\$p" "$work/ctx" | sed -n '1,/^$/p' | grep -q 'CLAUDE.md' || fail "CLAUDE.md is not in the block"
sed -n "$first,\$p" "$work/ctx" | sed -n '1,/^$/p' | grep -q 'biome.json' || fail "the lint configuration is not in the block"
grep -q 'Knowledge notes on these Paths' "$work/ctx" && sed -n '/Knowledge notes on these Paths/,/^$/p' "$work/ctx" | grep -q 'convention-handlers' && fail "the convention note is listed twice"

# The agents' prompts carry the rule.
agents=$(cd "$(dirname "$0")/../.." && pwd)/agents
for a in implementer test-author reviewer; do
  grep -q 'Project conventions' "$agents/$a.md" || fail "agents/$a.md does not say to follow the project's conventions"
done

[ "$failures" -eq 0 ] && echo "setup-survey: all cases pass"
exit "$failures"
