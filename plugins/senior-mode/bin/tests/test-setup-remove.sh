#!/usr/bin/env bash
# Tests for `senior-mode setup remove`. Offline: gh is a stub simulating the API from files in $FIX; the repository
# is a real one, with a bare origin of its own at <work>/github.com/acme/app.git (so that the slug is acme/app).
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
  "api repos/acme/app/rulesets --jq"*) if [ -f "$FIX/rulesets.json" ]; then respond <"$FIX/rulesets.json"; else echo '[]' | respond; fi ;;
  "api -X DELETE repos/acme/app/rulesets/9")
    [ -z "${DELETE_ERR:-}" ] || { echo "$DELETE_ERR" >&2; exit 1; }
    echo '[]' >"$FIX/rulesets.json" ;;
  "label list "*) respond <"$FIX/labels.json" ;;
  "label delete "*) jq --arg n "$3" 'map(select(.name != $n))' "$FIX/labels.json" >"$FIX/f" && mv "$FIX/f" "$FIX/labels.json" ;;
  "api --method GET repos/acme/app/issues"*)
    for a in "$@"; do case $a in labels=*) l=${a#labels=} ;; esac; done
    cat "$FIX/used-$l" 2>/dev/null || echo 0 ;;
  "workflow list"*) respond <"$FIX/workflows.json" ;;
  "workflow enable "*) jq --argjson id "$3" 'map(if .id == $id then .state = "active" else . end)' "$FIX/workflows.json" >"$FIX/f" &&
    mv "$FIX/f" "$FIX/workflows.json" ;;
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

# A repository set up by senior-mode, with what its owner added: an edited architecture overview, a CLAUDE.md section, a
# CODEOWNERS entry, a setting and a hook of their own, a deleted-and-edited template left as it is.
mkdir -p "$repo/.claude"
echo '{"language": "en", "deploy": {"previews": "ready"}}' >"$repo/.claude/senior-mode.json"
echo '{"git": {"deploymentEnabled": {"dev": false}}}' >"$repo/vercel.json"
printf '[build]\n  ignore = "exit 7"\n' >"$repo/netlify.toml"
cp "$repo/netlify.toml" "$work/netlify.orig"
(cd "$repo" && "$cli" setup repo --command test=true --command lint=true) >"$work/setup.out" 2>&1 || fail "setup repo failed: $(cat "$work/setup.out")"
printf '# app\n\nMy own notes.\n\n' >"$work/claude.head"
{ cat "$work/claude.head"; sed -n '/^<!-- senior-mode:principles/,$p' "$repo/CLAUDE.md"; } >"$work/claude.new" && mv "$work/claude.new" "$repo/CLAUDE.md"
echo "## Mine" >>"$repo/docs/architecture.md"
mkdir -p "$repo/.github"
printf '* @owner\n\n# senior-mode:begin (managed)\n/auth/ @owner\n# senior-mode:end\n' >"$repo/.github/CODEOWNERS"
jq '.model = "opus"' "$repo/.claude/settings.json" >"$work/s" && mv "$work/s" "$repo/.claude/settings.json"
printf '#!/bin/sh\nexit 0\n' >"$repo/.githooks/post-commit"
mkdir -p "$repo/.claude" "$repo/.github/workflows"
cp "$(dirname "$cli")/../templates/workflows/senior-mode-audit.yml" "$repo/.github/workflows/senior-mode-audit.yml"
g add -A
g commit -q -m "chore: setup"
g push -q origin main
[ "$(git -C "$repo" config core.hooksPath)" = .githooks ] || fail "setup repo did not set core.hooksPath"

echo '[{"id": 9, "name": "senior-mode", "source_type": "Repository"}]' >"$FIX/rulesets.json"
# Labels: unused ones are ours to delete; blocked is in use; triage has a description of the owner's; bug is theirs.
jq -n '[{name: "needs-human", description: "Waiting for a human decision or merge"}, {name: "needs-info", description: "Missing information before work can start"},
  {name: "blocked", description: "Blocked by something outside this ticket"}, {name: "security", description: "A security risk, with its Severity on the board"},
  {name: "triage", description: "Mine, different"}, {name: "qualified", description: "Qualified by a collaborator: serve may pick it though its author is external"},
  {name: "type:feature", description: "New capability for users"}, {name: "bug", description: "Something is broken"}]' >"$FIX/labels.json"
echo 3 >"$FIX/used-blocked"
echo '[{"id": 11, "name": "CI", "path": ".github/workflows/ci.yml", "state": "disabled_manually"},
  {"id": 12, "name": "Dependabot Updates", "path": "dynamic/dependabot/dependabot-updates", "state": "disabled_manually"},
  {"id": 13, "name": "Release", "path": ".github/workflows/release.yml", "state": "active"}]' >"$FIX/workflows.json"

remove() { : >"$GH_LOG"; (cd "$repo" && "$cli" setup remove "$@") >"$work/out" 2>"$work/err"; }
tree_has() { git -C "$origin" cat-file -e "$1:$2" 2>/dev/null; }
snapshot() { (cd "$repo" && git status --porcelain && git worktree list && git config core.hooksPath && find . -path ./.git -prune -o -type f -print0 | sort -z | xargs -0 sha1sum); }

# A dry run lists what it would remove and changes nothing.
snapshot >"$work/before"
remove || fail "dry run failed: $(cat "$work/err")"
for want in "would remove: .githooks/commit-msg" "would remove: .githooks/pre-push" "would remove: .claude/senior-mode.json" "would remove: .github/workflows/senior-mode-audit.yml" \
  "would remove: the preview settings of vercel.json" "would remove: the ignore step of netlify.toml" "would remove: .claude/senior-mode/ignore-build.sh" \
  "would remove: .github/pull_request_template.md" "would remove: .github/ISSUE_TEMPLATE/feature.yml" "would remove: .github/ISSUE_TEMPLATE/bug.yml" \
  "would remove: the senior-mode block of CLAUDE.md" "would remove: the senior-mode block of .github/CODEOWNERS" \
  "would remove: the senior-mode permissions and status line of .claude/settings.json" "would remove: ruleset senior-mode" \
  "would remove: labels needs-human, needs-info, security, qualified, type:feature" "would enable: workflow CI" \
  "kept: core.hooksPath .githooks (it holds hooks of yours)" "would open: a pull request" "dry run, nothing changed"; do
  grep -qF -- "$want" "$work/out" || fail "dry run without '$want': $(cat "$work/out")"
done
grep -q "kept: docs/architecture.md (edited" "$work/out" || fail "an edited document not said to be kept: $(cat "$work/out")"
grep -q "kept: .githooks/post-commit" "$work/out" && fail "a hook of the owner listed as kept although senior-mode never named it"
grep -q "kept: release-please-config.json" "$work/out" || fail "release files not named: $(cat "$work/out")"
grep -q "kept: labels blocked (in use), triage (not senior-mode's)" "$work/out" || fail "labels kept not named: $(cat "$work/out")"
grep -q "workflow Dependabot" "$work/out" && fail "a GitHub built-in workflow enabled"
grep -q "workflow Release" "$work/out" && fail "an active workflow listed"
grep -q "kept: the Project and the issues" "$work/out" || fail "Project and issues not said to be kept"
logged "-X DELETE" && fail "dry run deleted the ruleset"
logged "label delete" && fail "dry run deleted a label"
logged "workflow enable" && fail "dry run enabled a workflow"
logged "pr create" && fail "dry run opened a pull request"
git -C "$origin" rev-parse -q --verify refs/heads/chore/remove-senior-mode >/dev/null && fail "dry run pushed a branch"
snapshot >"$work/after"
cmp -s "$work/before" "$work/after" || fail "dry run changed the checkout: $(diff "$work/before" "$work/after")"

# --apply: the files through a pull request from a branch, then the ruleset, the unused labels, the workflows.
# The ruleset cannot be deleted the first time: the removal stops there, after the pull request.
DELETE_ERR="gh: HTTP 403: Resource not accessible by personal access token" remove --apply && fail "apply succeeds although the ruleset cannot be deleted"
grep -q "cannot delete the ruleset senior-mode" "$work/err" || fail "the failure is not said: $(cat "$work/err")"
logged "pr create --repo acme/app --base main --head chore/remove-senior-mode" || fail "no pull request opened: $(cat "$GH_LOG")"
git -C "$origin" rev-parse -q --verify refs/heads/chore/remove-senior-mode >/dev/null || fail "branch not pushed"
b=chore/remove-senior-mode
for f in .githooks/commit-msg .githooks/pre-push .claude/senior-mode.json .github/pull_request_template.md .github/ISSUE_TEMPLATE/feature.yml .github/ISSUE_TEMPLATE/bug.yml; do
  ! tree_has "$b" "$f" || fail "$f still in the removal branch"
  tree_has main "$f" || fail "$f gone from main before the pull request is merged"
done
tree_has "$b" .githooks/post-commit || fail "a hook of the owner removed"
! tree_has "$b" .claude/senior-mode/ignore-build.sh || fail "the ignore script is still in the removal branch"
[ "$(git -C "$origin" show "$b:vercel.json" | jq -c .)" = '{"git":{"deploymentEnabled":{"dev":false}}}' ] || fail "vercel.json not restored: $(git -C "$origin" show "$b:vercel.json")"
[ "$(git -C "$origin" show "$b:netlify.toml")" = "$(cat "$work/netlify.orig")" ] || fail "netlify.toml not restored: $(git -C "$origin" show "$b:netlify.toml")"
tree_has "$b" docs/architecture.md || fail "an edited architecture overview removed"
tree_has "$b" release-please-config.json || fail "release-please config removed"
tree_has "$b" .claude/settings.json || fail "the settings of the owner removed with ours"
[ "$(git -C "$origin" show "$b:.claude/settings.json" | jq -c .)" = '{"model":"opus"}' ] || fail "settings: $(git -C "$origin" show "$b:.claude/settings.json")"
git -C "$origin" show "$b:CLAUDE.md" | grep -q "My own notes" || fail "the owner's CLAUDE.md text removed"
git -C "$origin" show "$b:CLAUDE.md" | grep -q "senior-mode:principles" && fail "the Principles block left"
[ "$(git -C "$origin" show "$b:.github/CODEOWNERS")" = $'* @owner' ] || fail "CODEOWNERS: $(git -C "$origin" show "$b:.github/CODEOWNERS")"
[ "$(git -C "$origin" log -1 --format=%s "$b")" = "chore: remove senior-mode" ] || fail "commit subject"
[ "$(git -C "$origin" rev-list --count main.."$b")" = 1 ] || fail "not exactly one commit"
[ "$(git -C "$repo" worktree list | wc -l)" = 1 ] || fail "the temporary worktree is left: $(git -C "$repo" worktree list)"
[ -f "$repo/.githooks/commit-msg" ] || fail "the checkout of the owner was touched"
[ "$(jq -r '.[0].id' "$FIX/rulesets.json" 2>/dev/null)" = 9 ] || fail "ruleset fixture changed"

# The rerun finishes the job: the pull request is open already (not opened twice), the ruleset goes, then the labels and the workflows.
remove --apply || fail "rerun failed: $(cat "$work/err")"
grep -q "the pull request is already open: https://github.com/acme/app/pull/12" "$work/out" || fail "open pull request not recognised: $(cat "$work/out")"
logged "pr create" && fail "a second pull request opened"
logged "-X DELETE repos/acme/app/rulesets/9" || fail "ruleset not deleted on the rerun"
grep -q "removed: ruleset senior-mode" "$work/out" || fail "ruleset deletion not said: $(cat "$work/out")"
[ "$(jq -r 'map(.name) | join(",")' "$FIX/labels.json")" = "blocked,triage,bug" ] || fail "labels left: $(jq -c . "$FIX/labels.json")"
grep -q "removed: labels needs-human, needs-info, security, qualified, type:feature" "$work/out" || fail "labels removal not said: $(cat "$work/out")"
logged "label delete bug" && fail "a label of the owner deleted"
[ "$(jq -r '.[] | select(.id == 11) | .state' "$FIX/workflows.json")" = active ] || fail "the workflow setup disabled is still off"
[ "$(jq -r '.[] | select(.id == 12) | .state' "$FIX/workflows.json")" = disabled_manually ] || fail "a built-in workflow enabled"
[ "$(git -C "$repo" config core.hooksPath)" = .githooks ] || fail "core.hooksPath unset although .githooks holds a hook of the owner"

# The pull request is merged; only the owner's own hook was left in .githooks, so core.hooksPath stays. Rerun once more: nothing to do, no error.
git -C "$origin" update-ref refs/heads/main "refs/heads/$b"
git -C "$origin" branch -q -D "$b"
rm -f "$FIX/open-pr"
git -C "$repo" config core.hooksPath .githooks
remove --apply || fail "rerun after the merge failed: $(cat "$work/err")"
grep -q "files: nothing left to remove on main" "$work/out" || fail "a finished removal not recognised: $(cat "$work/out")"
logged "pr create" && fail "a pull request opened for nothing"
logged "-X DELETE" && fail "a ruleset deleted that is gone"
logged "label delete" && fail "a label deleted that is gone or kept"
logged "workflow enable" && fail "a workflow enabled after the config is gone"
grep -q "kept: core.hooksPath .githooks (it holds hooks of yours)" "$work/out" || fail "the hooks path of an owner with a hook not kept: $(cat "$work/out")"
[ "$(git -C "$repo" config core.hooksPath)" = .githooks ] || fail "core.hooksPath unset although a hook of the owner remains"
grep -q "kept: labels blocked (in use), triage (not senior-mode's)" "$work/out" || fail "labels kept not named on the rerun: $(cat "$work/out")"

# Without a hook of the owner, core.hooksPath goes with the hooks.
tmp=$work/clone
git clone -q "$origin" "$tmp"
git -C "$tmp" -c core.hooksPath=/dev/null rm -q .githooks/post-commit
git -C "$tmp" -c core.hooksPath=/dev/null -c user.name=t -c user.email=t@t commit -q -m "chore: drop the hook"
git -C "$tmp" push -q origin main
remove --apply || fail "last rerun failed: $(cat "$work/err")"
grep -q "removed: core.hooksPath .githooks of this checkout" "$work/out" || fail "core.hooksPath not removed: $(cat "$work/out")"
git -C "$repo" config core.hooksPath >/dev/null 2>&1 && fail "core.hooksPath still set"

# Unknown arguments are refused, and a directory that is no repository is no place for it.
(cd "$repo" && "$cli" setup remove --force) >/dev/null 2>&1 && fail "an unknown argument accepted"
(cd "$work" && "$cli" setup remove) >/dev/null 2>&1 && fail "setup remove outside a repository"

[ "$failures" -eq 0 ] && echo "setup-remove: all cases pass"
exit "$failures"
