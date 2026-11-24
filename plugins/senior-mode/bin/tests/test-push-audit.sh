#!/usr/bin/env bash
# Tests for the audit workflow of `github.protection: local` (ADR 0032, #523). Offline: gh is a stub answering from
# files in $FIX, and the script under test is the `run` step of templates/workflows/senior-mode-audit.yml itself.
set -u
tpl=$(cd "$(dirname "$0")/../.." && pwd)/templates/workflows/senior-mode-audit.yml
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0
fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

# The workflow is valid YAML, minimal in permissions, with no secret and no third-party action.
if python3 -c 'import yaml' 2>/dev/null; then
  python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$tpl" || fail "the workflow is not valid YAML"
else
  echo "skip: no PyYAML, the YAML syntax is not checked"
fi
perms=$(sed -n '/^permissions:/,/^$/p' "$tpl" | grep -v '^permissions:' | sed '/^$/d' | paste -sd, - | tr -d ' ')
[ "$perms" = "contents:read,issues:write,pull-requests:read" ] || fail "permissions are not minimal: $perms"
! grep -qE '^[[:space:]]*-?[[:space:]]*uses:' "$tpl" || fail "the workflow uses an action; none is needed"
! grep -q 'secrets\.' "$tpl" || fail "the workflow reads a secret"
grep -q 'default_branch' "$tpl" || fail "the job does not look at the default branch"

# The script of the step, as the runner sees it.
awk '/^ +run: \|$/ { on = 1; next } on { sub(/^          /, ""); print }' "$tpl" >"$work/audit.sh"
[ -s "$work/audit.sh" ] || fail "no script found in the workflow"

FIX=$work/fix GH_LOG=$work/gh.log
export FIX GH_LOG
mkdir -p "$work/stub" "$FIX"
cat >"$work/stub/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$GH_LOG"
jqf="" prev=""
for a in "$@"; do [ "$prev" = --jq ] && jqf=$a; prev=$a; done
respond() { if [ -n "$jqf" ]; then jq -r "$jqf"; else cat; fi; }
case "$*" in
  "api repos/acme/app/compare/"*) [ ! -f "$FIX/compare-fails" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    respond <"$FIX/compare.json" ;;
  "api repos/acme/app/commits/"*"/pulls"*)
    sha=$(sed -E 's#^api repos/acme/app/commits/([^/]+)/pulls.*#\1#' <<<"$*")
    # LAG=<n>: the first n answers are empty, as GitHub's association of a fresh merge may be.
    if [ -f "$FIX/lag" ] && [ "$(cat "$FIX/lag")" -gt 0 ]; then echo $(($(cat "$FIX/lag") - 1)) >"$FIX/lag"; echo '[]' | respond
    else respond <"$FIX/pulls-$sha.json"; fi ;;
  "api repos/acme/app/commits/"*) respond <"$FIX/commit.json" ;;
  "api repos/acme/app/issues?"*) respond <"$FIX/issues.json" ;;
  "api repos/acme/app/issues/"*"/comments "*) ;;
  "api repos/acme/app/issues "*) ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$work/stub/gh"

zero=0000000000000000000000000000000000000000
aaa=aaaaaaa1111111111111111111111111111111aa
bbb=bbbbbbb2222222222222222222222222222222bb
merged_pr='[{"number": 7, "merged_at": "2026-11-24T10:00:00Z", "base": {"ref": "main"}}]'
audit() { # BEFORE AFTER: runs the script as the workflow does
  : >"$GH_LOG"
  PATH="$work/stub:$PATH" GH_TOKEN=x REPO=acme/app BRANCH=main BEFORE=$1 AFTER=$2 PUSHER=mallory AUDIT_RETRY_SLEEP=0 \
    bash "$work/audit.sh" >"$work/out" 2>&1
}
commits() { jq -n --arg a "$aaa" --arg b "$bbb" '{commits: [{sha: $a, commit: {message: "feat: from a pull request\n\nbody"}},
  {sha: $b, commit: {message: "fix: straight to main"}}]}' >"$FIX/compare.json"; }
logged() { grep -qF -- "$1" "$GH_LOG"; }

# Every commit belongs to a merged pull request into main: nothing is opened.
commits
echo "$merged_pr" >"$FIX/pulls-$aaa.json"
echo "$merged_pr" >"$FIX/pulls-$bbb.json"
echo '[]' >"$FIX/issues.json"
audit "$aaa" "$bbb" || fail "A: the audit failed: $(cat "$work/out")"
logged "api repos/acme/app/issues " && fail "A: an issue opened for pushed pull requests: $(cat "$GH_LOG")"
grep -q "belongs to a merged pull request" "$work/out" || fail "A: not said: $(cat "$work/out")"

# One commit in no pull request, another in a pull request that is not merged or went to another branch: an issue,
# labelled needs-human, with the commit, its subject and the pusher; the compliant commit is not listed.
echo '[]' >"$FIX/pulls-$bbb.json"
audit "$aaa" "$bbb" || fail "B: the audit failed: $(cat "$work/out")"
logged 'api repos/acme/app/issues -f title=Direct push to main outside a pull request' || fail "B: no issue with the title: $(cat "$GH_LOG")"
logged "-f labels[]=needs-human" || fail "B: not labelled needs-human: $(cat "$GH_LOG")"
logged "\`bbbbbbb\` fix: straight to main" || fail "B: the commit is not listed: $(cat "$GH_LOG")"
logged "@mallory" || fail "B: the pusher is not named: $(cat "$GH_LOG")"
logged "\`aaaaaaa\`" && fail "B: a commit of a merged pull request is listed: $(cat "$GH_LOG")"
logged "blocks nothing" || fail "B: the report does not say it only reports: $(cat "$GH_LOG")"
echo '[{"number": 8, "merged_at": null, "base": {"ref": "main"}}, {"number": 9, "merged_at": "2026-11-24T10:00:00Z", "base": {"ref": "release"}}]' >"$FIX/pulls-$bbb.json"
audit "$aaa" "$bbb" || fail "B: the audit failed: $(cat "$work/out")"
logged 'api repos/acme/app/issues -f title=' || fail "B: a pull request not merged, or into another branch, counted: $(cat "$GH_LOG")"

# An issue about direct pushes is already open: a comment, not a second issue. Another title, or a pull request, does not count.
echo '[]' >"$FIX/pulls-$bbb.json"
echo '[{"number": 31, "title": "Something else", "pull_request": null}, {"number": 32, "title": "Direct push to main outside a pull request", "pull_request": {}},
  {"number": 33, "title": "Direct push to main outside a pull request", "pull_request": null}]' >"$FIX/issues.json"
audit "$aaa" "$bbb" || fail "C: the audit failed: $(cat "$work/out")"
logged 'api repos/acme/app/issues/33/comments -f body=' || fail "C: no comment on the open issue: $(cat "$GH_LOG")"
logged "api repos/acme/app/issues -f" && fail "C: a second issue opened: $(cat "$GH_LOG")"

# A new default branch (before is all zeros) and a force push (the range cannot be read): the pushed commit alone is audited.
echo '[]' >"$FIX/issues.json"
jq -n --arg b "$bbb" '{sha: $b, commit: {message: "chore: lone commit"}}' >"$FIX/commit.json"
audit "$zero" "$bbb" || fail "D: the audit failed: $(cat "$work/out")"
logged "api repos/acme/app/commits/$bbb --jq" || fail "D: the commit itself is not read: $(cat "$GH_LOG")"
logged 'lone commit' || fail "D: the commit is not listed: $(cat "$GH_LOG")"
touch "$FIX/compare-fails"
audit "$aaa" "$bbb" || fail "D: a range that cannot be read fails the audit: $(cat "$work/out")"
logged 'lone commit' || fail "D: the force pushed commit is not audited: $(cat "$GH_LOG")"
rm -f "$FIX/compare-fails"

# The association of a fresh merge may lag: an empty answer is asked again before the commit is called direct.
echo "$merged_pr" >"$FIX/pulls-$bbb.json"
echo 2 >"$FIX/lag"
audit "$aaa" "$bbb" || fail "E: the audit failed: $(cat "$work/out")"
logged "api repos/acme/app/issues -f" && fail "E: a merge whose association lagged is reported: $(cat "$GH_LOG")"
echo 9 >"$FIX/lag"
audit "$aaa" "$bbb" || fail "E: the audit failed: $(cat "$work/out")"
logged "api repos/acme/app/issues -f" || fail "E: a commit with no pull request after three tries is not reported: $(cat "$GH_LOG")"
rm -f "$FIX/lag"

[ "$failures" -eq 0 ] && echo "push-audit: all cases pass"
exit "$failures"
