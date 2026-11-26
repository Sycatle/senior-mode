#!/usr/bin/env bash
# Tests for `senior-mode setup repo --knowledge` (#369). Offline: gh is a stub simulating the API from files in $FIX; the
# repository is a real one, with a bare origin of its own at <work>/github.com/acme/app.git (so that the slug is acme/app).
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
  "api repos/acme/app --jq .default_branch") echo main ;;
  "label list "*) respond <"$FIX/labels.json" ;;
  "label create "*) jq --arg n "$3" '. + [{name: $n}]' "$FIX/labels.json" >"$FIX/f" && mv "$FIX/f" "$FIX/labels.json" ;;
  "issue list "*) if [ -f "$FIX/epic" ]; then jq -nc --argjson n "$(cat "$FIX/epic")" '[{number: $n}]' | respond; else echo '[]' | respond; fi ;;
  "issue create "*) echo 40 >"$FIX/epic"; echo "https://github.com/acme/app/issues/40" ;;
  "api graphql --input -") cat >"$FIX/graphql.in"; cat "$FIX/orphans.json" ;;
  "pr list"*) if [ -f "$FIX/open-pr" ]; then jq -nc --arg u "$(cat "$FIX/open-pr")" '[{url: $u}]' | respond; else echo '[]' | respond; fi ;;
  "pr create"*) echo "https://github.com/acme/app/pull/12" | tee "$FIX/open-pr" ;;
  *) echo "gh stub: unexpected call: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$work/stub/gh"
export PATH="$work/stub:$PATH" GH_LOG="$work/gh.log" FIX="$work/fix" SENIOR_MODE_RETRY_DELAY=0

origin="$work/github.com/acme/app.git"
repo="$work/repo"
git init -q --bare -b main "$origin"
git init -q -b main "$repo"
git -C "$repo" remote add origin "$origin"
g() { git -C "$repo" -c core.hooksPath=/dev/null -c user.name=t -c user.email=t@t "$@"; }
logged() { grep -qF -- "$1" "$GH_LOG"; }

# An existing project: a README, three ADRs (one has paths, one is cited by no spec), two specs that cite ADR 1, one
# architecture rule broken by one file, an untracked draft of an agent.
mkdir -p "$repo/.claude" "$repo/docs/adr" "$repo/docs/specs" "$repo/src/a" "$repo/src/b"
printf '# App\n\nApp does billing for small shops. It is fast and small.\n\nMore text.\n' >"$repo/README.md"
printf -- '---\nid: 0001\ntitle: One\nstatus: accepted\n---\n\n# One\n' >"$repo/docs/adr/0001-one.md"
printf -- '---\nid: 0002\ntitle: Two\nstatus: accepted\npaths: ["src/keep/**"]\n---\n\n# Two\n' >"$repo/docs/adr/0002-two.md"
printf -- '---\nid: 0003\ntitle: Three\nstatus: accepted\n---\n\n# Three\n' >"$repo/docs/adr/0003-three.md"
printf -- '---\nid: 10\ntitle: A\nstatus: accepted\npaths: ["src/a/**"]\nadrs: ["0001"]\n---\n\n# A\n' >"$repo/docs/specs/10-a.md"
printf -- '---\nid: 20\ntitle: B\nstatus: accepted\npaths: ["src/b/**", "src/a/**"]\nadrs: [1, 2]\n---\n\n# B\n' >"$repo/docs/specs/20-b.md"
printf 'one\ntwo\nthree\nfour\nfive\n' >"$repo/src/a/x.sh"
echo ok >"$repo/src/b/y.sh"
echo '{"language": "en", "architecture": {"rules": [{"id": "small", "maxLines": 3, "paths": ["src/**"], "why": "keep files short"}]}}' >"$repo/.claude/senior-mode.json"
g add -A
g commit -q -m "chore: start"
g push -q origin main
mkdir -p "$repo/.claude/agent-memory/reviewer"
printf -- '---\nname: pitfall\n---\nThe parser in `src/a/x.sh` drops the last line.\nUse `src/b` for fixtures.\n' >"$repo/.claude/agent-memory/reviewer/Parser Pitfall.md"
echo '[{"name": "bug"}]' >"$FIX/labels.json"
echo '{"data": {"repository": {"issues": {"pageInfo": {"hasNextPage": false, "endCursor": null}, "nodes": [
  {"number": 5, "title": "Loose ticket", "labels": {"nodes": []}, "subIssuesSummary": {"total": 0}, "parent": null},
  {"number": 6, "title": "Security fix", "labels": {"nodes": [{"name": "security"}]}, "subIssuesSummary": {"total": 0}, "parent": null},
  {"number": 7, "title": "Under a goalless epic", "labels": {"nodes": []}, "subIssuesSummary": {"total": 0},
    "parent": {"number": 8, "labels": {"nodes": []}, "milestone": {"description": "no goal here"}}},
  {"number": 8, "title": "The epic", "labels": {"nodes": []}, "subIssuesSummary": {"total": 1}, "parent": null},
  {"number": 9, "title": "Under the goal", "labels": {"nodes": []}, "subIssuesSummary": {"total": 0},
    "parent": {"number": 3, "labels": {"nodes": []}, "milestone": {"description": "Goal: G1"}}},
  {"number": 10, "title": "Gardening", "labels": {"nodes": []}, "subIssuesSummary": {"total": 0},
    "parent": {"number": 2, "labels": {"nodes": [{"name": "maintenance"}]}, "milestone": null}}]}}}}' >"$FIX/orphans.json"

know() { : >"$GH_LOG"; (cd "$repo" && "$cli" setup repo --knowledge "$@") >"$work/out" 2>"$work/err"; }
tree_has() { git -C "$origin" cat-file -e "$1:$2" 2>/dev/null; }
show() { git -C "$origin" show "$1:$2"; }
snapshot() { (cd "$repo" && git status --porcelain && git worktree list && find . -path ./.git -prune -o -type f -print0 | sort -z | xargs -0 sha1sum); }
b=docs/adopt-knowledge-layout

# A dry run prints the files, the orphans and the baseline, and changes nothing.
snapshot >"$work/before"
know --dry-run || fail "dry run failed: $(cat "$work/err")"
for want in "would write: docs/adr/0001-one.md" "paths [\"src/a/**\", \"src/b/**\"]" "specs 10, 20" \
  "would write: docs/knowledge/reviewer-parser-pitfall.md" "would write: docs/vision.md" "would write: .claude/architecture-baseline.json" \
  "would create: label gardening" "would create: label maintenance" "would create: the maintenance epic" \
  "would open: a draft pull request" "baseline: 1 violation in 1 file" "orphans: 2 open tickets" "#5 Loose ticket: no parent epic" \
  "#7 Under a goalless epic: its epic #8 has no milestone with a goal" "dry run, nothing changed"; do
  grep -qF -- "$want" "$work/out" || fail "dry run without '$want': $(cat "$work/out")"
done
for not in "docs/adr/0002-two.md" "docs/adr/0003-three.md" "#6 " "#9 " "#10 "; do
  grep -qF -- "$not" "$work/out" && fail "dry run mentions '$not': $(cat "$work/out")"
done
logged "pr create" && fail "dry run opened a pull request"
logged "label create" && fail "dry run created a label"
logged "issue create" && fail "dry run created an issue"
git -C "$origin" rev-parse -q --verify "refs/heads/$b" >/dev/null && fail "dry run pushed a branch"
snapshot >"$work/after"
cmp -s "$work/before" "$work/after" || fail "dry run changed the checkout: $(diff "$work/before" "$work/after")"

# The run: one pull request from a branch, a label and the epic on GitHub, no ticket touched.
know || fail "run failed: $(cat "$work/err")"
logged "pr create --repo acme/app --base main --head $b --draft --title docs(knowledge): adopt long-lived project layout" || fail "no pull request: $(cat "$GH_LOG")"
logged "--draft" || fail "the pull request is not a draft: the vision needs its owner"
[ "$(git -C "$origin" log -1 --format=%s "$b")" = "docs(knowledge): adopt long-lived project layout" ] || fail "commit subject"
[ "$(git -C "$origin" rev-list --count main.."$b")" = 1 ] || fail "not exactly one commit"
[ "$(show "$b" docs/adr/0001-one.md | sed -n 5,6p)" = $'paths: ["src/a/**", "src/b/**"]\n---' ] || fail "ADR 1 paths: $(show "$b" docs/adr/0001-one.md)"
[ "$(show "$b" docs/adr/0002-two.md)" = "$(git -C "$repo" show main:docs/adr/0002-two.md)" ] || fail "an ADR that has paths was changed"
[ "$(show "$b" docs/adr/0003-three.md)" = "$(git -C "$repo" show main:docs/adr/0003-three.md)" ] || fail "an ADR cited by no spec was changed"
tree_has "$b" docs/knowledge/reviewer-parser-pitfall.md || fail "no note for the draft"
show "$b" docs/knowledge/reviewer-parser-pitfall.md | grep -qx 'paths: \["src/a/x.sh", "src/b/\*\*"\]' || fail "note paths: $(show "$b" docs/knowledge/reviewer-parser-pitfall.md)"
show "$b" docs/knowledge/reviewer-parser-pitfall.md | grep -q 'drops the last line' || fail "the draft text is not in the note"
show "$b" docs/knowledge/reviewer-parser-pitfall.md | grep -q '^name: pitfall' && fail "the front matter of the draft is in the note"
show "$b" docs/vision.md | grep -q 'App does billing for small shops' || fail "vision without the README text: $(show "$b" docs/vision.md)"
[ "$(show "$b" .claude/architecture-baseline.json | jq -c .)" = '{"violations":[{"rule":"small","file":"src/a/x.sh","count":1}]}' ] ||
  fail "baseline: $(show "$b" .claude/architecture-baseline.json)"
logged "label create gardening --repo acme/app" || fail "no gardening label"
logged "label create maintenance --repo acme/app" || fail "no maintenance label"
{ logged "issue create --repo acme/app --title" && logged "--label maintenance"; } || fail "no maintenance epic: $(cat "$GH_LOG")"
logged "issue edit" && fail "a ticket was edited"
[ "$(git -C "$repo" worktree list | wc -l)" = 1 ] || fail "the temporary worktree is left"
# What it wrote passes the project's own checks.
clone="$work/clone"
git clone -q -b "$b" "$origin" "$clone"
for sub in knowledge-check vision-check context-hygiene architecture-check; do
  (cd "$clone" && "$cli" "$sub") >"$work/sub.out" 2>&1 || fail "$sub fails on the result: $(cat "$work/sub.out")"
done

# A second run before the merge: the pull request is open, nothing more is made.
know || fail "rerun failed: $(cat "$work/err")"
grep -q "already open" "$work/out" || fail "the open pull request is not said: $(cat "$work/out")"
logged "pr create" && fail "second pull request"
logged "label create" && fail "label created twice"
logged "issue create" && fail "epic created twice"

# Merged: a run changes nothing.
git -C "$origin" update-ref refs/heads/main "refs/heads/$b"
git -C "$repo" fetch -q origin
know || fail "run after the merge failed: $(cat "$work/err")"
grep -q "nothing to change" "$work/out" || fail "a repository already migrated: $(cat "$work/out")"
grep -q "would write\|wrote:" "$work/out" && fail "a second run writes: $(cat "$work/out")"
logged "pr create" && fail "pull request on a migrated repository"

# Without architecture rules there is no baseline; without a README, no vision.
two="$work/two"
git init -q --bare -b main "$two/github.com/acme/app.git"
git init -q -b main "$two/repo"
git -C "$two/repo" remote add origin "$two/github.com/acme/app.git"
mkdir -p "$two/repo/.claude"
echo '{"language": "en"}' >"$two/repo/.claude/senior-mode.json"
git -C "$two/repo" add -A
git -C "$two/repo" -c core.hooksPath=/dev/null -c user.name=t -c user.email=t@t commit -q -m "chore: bare"
git -C "$two/repo" push -q origin main
(cd "$two/repo" && "$cli" setup repo --knowledge --dry-run) >"$work/out2" 2>&1 || fail "dry run on a bare repository failed: $(cat "$work/out2")"
grep -q "baseline: no architecture.rules" "$work/out2" || fail "no word on the missing rules: $(cat "$work/out2")"
grep -q "vision: no README.md" "$work/out2" || fail "no word on the missing README: $(cat "$work/out2")"

(cd "$repo" && "$cli" setup repo --knowledge --adopt) >/dev/null 2>&1 && fail "--knowledge with --adopt accepted"

[ "$failures" -eq 0 ] && echo "setup-knowledge: all cases pass"
exit "$failures"
