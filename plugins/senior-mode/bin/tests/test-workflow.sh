#!/usr/bin/env bash
# Tests for following the workflow of an existing project (spec 409, ADR 0022): the detection of `setup repo`, the branch
# `start` makes, `check --ci-only` and `publish` with the project's own CI, and the hooks. Offline: gh is a stub serving
# fixtures from $FIX and logging every call; origin is only a set of remote-tracking refs.
set -u
cli=$(cd "$(dirname "$0")/.." && pwd)/senior-mode
tpl=$(cd "$(dirname "$0")/../.." && pwd)/templates
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }
logged() { grep -qF -- "$1" "$GH_LOG"; }

mkdir -p "$work/stub" "$work/fix"
cat >"$work/stub/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$GH_LOG"
jqf="" prev=""
for a in "$@"; do [ "$prev" = --jq ] && jqf=$a; prev=$a; done
respond() { if [ -n "$jqf" ]; then jq -r "$jqf"; else cat; fi; }
case "$*" in
  "pr list"*"--state merged"*) respond <"$FIX/prs.json" ;;
  "pr list"*) echo '[]' | respond ;;
  "api repos/acme/app --jq"*) echo '{"allow_rebase_merge": false, "allow_squash_merge": true, "allow_merge_commit": false}' | respond ;;
  "label list"*) echo '[{"name": "bug"}, {"name": "enhancement"}]' | respond ;;
  "issue view "*) echo "$GH_ISSUE" ;;
  "api repos/acme/app/issues/"*) ;;
  "api repos/acme/app/rules/branches/"* | "api repos/acme/app/branches/"*"/protection/"*)
    # PROTECTION_403: like gh, the body of the error response goes to stdout, the status line to stderr
    case "$*" in
      *"/rules/branches/"*) [ -z "${PROTECTION_OK:-}" ] || { echo '[{"type": "required_status_checks", "parameters": {"required_status_checks": [{"context": "build"}]}}]' | respond; exit 0; } ;;
    esac
    if [ -n "${PROTECTION_404:-}" ]; then
      echo '{"message": "Branch not protected", "status": "404"}'
      echo "gh: Branch not protected (HTTP 404)" >&2; exit 1
    fi
    [ -n "${PROTECTION_403:-}" ] || exit 1
    echo '{"message": "Resource not accessible by personal access token", "status": "403"}'
    echo "gh: Resource not accessible by personal access token (HTTP 403)" >&2; exit 1 ;;
  "api repos/acme/app/commits/"*"/check-runs"*) respond <"$FIX/runs.json" ;;
  "api repos/acme/app/commits/"*"/status"*) respond <"$FIX/statuses.json" ;;
  "api repos/acme/app/statuses/"*) ;;
  "project item-add"*) echo ITEM ;;
  "project item-edit"*) ;;
  "api graphql --input -") cat >/dev/null
    echo '{"data": {"node": {"items": {"pageInfo": {"hasNextPage": false}, "nodes": []}}}}' ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$work/stub/gh"
export PATH="$work/stub:$PATH" GH_LOG="$work/gh.log" FIX="$work/fix" SENIOR_MODE_RETRY_DELAY=0 XDG_DATA_HOME="$work/xdg"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
: >"$GH_LOG"
echo '[]' >"$FIX/runs.json"
echo '{"statuses": []}' >"$FIX/statuses.json"

# A project that works on `dev`, names its branches `<KEY>-<slug>`, prefixes its commits with a ticket key and
# squash-merges its pull requests; origin is only the remote-tracking refs.
repo="$work/app"
git init -q -b main "$repo"
git -C "$repo" remote add origin https://github.com/acme/app.git
echo '{"name": "app", "scripts": {"test": "true"}}' >"$repo/package.json"
git -C "$repo" add -A
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do git -C "$repo" commit -q --allow-empty -m "ABC-$i work $i"; done
git -C "$repo" update-ref refs/remotes/origin/main HEAD
git -C "$repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
git -C "$repo" checkout -q -b dev
echo dev >"$repo/dev.txt"
git -C "$repo" add -A
git -C "$repo" commit -q -m "ABC-13 dev only"
git -C "$repo" update-ref refs/remotes/origin/dev HEAD
git -C "$repo" checkout -q main
jq -nc '[range(1; 11) | {number: ., title: "ABC-\(.) thing", body: "Closes #\(.)", baseRefName: "dev",
  headRefName: "ABC-\(.)-thing-\(.)", mergedAt: "2026-11-\(. + 1 | if . < 10 then "0\(.)" else "\(.)" end)T10:00:00Z"}]' >"$FIX/prs.json"

run() { (cd "$repo" && "$cli" "$@") >"$work/out" 2>"$work/err"; }

# Detection: nothing is written by --dry-run, the findings carry their evidence, a question the CLI cannot ask takes the
# recommended answer and says it is assumed.
run setup repo --dry-run || fail "setup repo --dry-run failed: $(cat "$work/err")"
[ ! -e "$repo/.claude/senior-mode.json" ] || fail "--dry-run wrote the config"
grep -q '10 of 10 merged pull requests target dev' "$work/out" || fail "integration branch not read from the pull requests: $(cat "$work/out")"
grep -q '^dry run: nothing changed' "$work/out" || fail "dry run not said: $(cat "$work/out")"
grep -q '^ask: .*merge.*(assumed)' "$work/out" || fail "the merge question was not taken as assumed: $(cat "$work/out")"
cfg=$(sed -n '/^config: would write/,/^dry run/p' "$work/out" | sed '1d;$d')
get() { jq -r "$1" <<<"$cfg"; }
[ "$(get '.workflow.integration + " " + .workflow.model')" = "dev integration" ] || fail "integration not detected: $cfg"
[ "$(get .workflow.commit.format)" = ticket-prefix ] || fail "commit format not detected: $cfg"
[ "$(get .workflow.branch.pattern)" = '{key}-{slug}' ] || fail "branch pattern not detected: $cfg"
[ "$(get .workflow.merge)" = squash ] || fail "merge method not within the allowed ones: $cfg"
[ "$(get '.workflow.labels["type:bug"]')" = bug ] || fail "the project's bug label not mapped: $cfg"
[ "$(get .workflow.tracker.key)" = ABC ] || fail "tracker key not detected: $cfg"
[ "$(get .adopt.kind)" = evergreen ] || fail "adopt.kind not detected: $cfg"
[ -z "$(git -C "$repo" status --porcelain)" ] || fail "--dry-run changed the checkout: $(git -C "$repo" status --porcelain)"
grep -q 'merge --admin\|--admin' "$GH_LOG" && fail "detection called a writing gh command: $(cat "$GH_LOG")"

# #609: the pull request conventions are not inferred from fewer than five merged pull requests; enough history keeps them.
[ "$(get '.workflow.pr.title // "unset"')" = commit ] || [ "$(get '.workflow.pr.title // "unset"')" = ticket ] || [ "$(get '.workflow.pr.title // "unset"')" = free ] ||
  fail "pr.title not detected from 10 merged pull requests: $cfg"
[ "$(get '.workflow.pr.link // "unset"')" = Closes ] || fail "pr.link not detected from 10 merged pull requests: $cfg"
cp "$FIX/prs.json" "$FIX/prs.all.json"
jq -c '.[:1]' "$FIX/prs.all.json" >"$FIX/prs.json"
run setup repo --dry-run || fail "setup repo --dry-run failed on one pull request: $(cat "$work/err")"
cfg=$(sed -n '/^config: would write/,/^dry run/p' "$work/out" | sed '1d;$d')
[ "$(get '.workflow.pr.title // "unset"')" = unset ] || fail "pr.title inferred from one pull request: $cfg"
[ "$(get '.workflow.pr.link // "unset"')" = unset ] || fail "pr.link inferred from one pull request: $cfg"
grep -q 'pr.title.* and .*pr.link.*not enough history (1 of 5 merged pull requests needed), default kept' "$work/out" ||
  fail "the lack of history is not said: $(cat "$work/out")"
mv "$FIX/prs.all.json" "$FIX/prs.json"

# A protection the token cannot read (403) is said; the body of the error is never taken for check names.
PROTECTION_403=1 run setup repo --dry-run || fail "setup repo --dry-run failed on a 403: $(cat "$work/err")"
grep -q 'config: would write' "$work/out" || fail "no config planned on a 403: $(cat "$work/out")"
grep -q 'Resource not accessible\|"message"' "$work/out" && fail "the body of a 403 reached the config: $(cat "$work/out")"
grep -q '"required":' "$work/out" && fail "ci.required recorded on a 403: $(cat "$work/out")"
grep -q 'required status checks: the token cannot read the protection' "$work/out" || fail "the refused read is not said: $(cat "$work/out")"

# A 404 (branch not protected) stays silent; the body is not read either.
PROTECTION_404=1 run setup repo --dry-run || fail "setup repo --dry-run failed on a 404: $(cat "$work/err")"
grep -q 'Branch not protected' "$work/out" && fail "the body of a 404 reached the config: $(cat "$work/out")"
grep -q 'token cannot read the protection' "$work/out" && fail "a 404 is reported as a refused read: $(cat "$work/out")"

# A readable ruleset is still recorded.
PROTECTION_OK=1 run setup repo --dry-run || fail "setup repo --dry-run failed on a readable ruleset: $(cat "$work/err")"
{ grep -q "required status checks of the protection" "$work/out" && grep -q "\"build\"" "$work/out"; } || fail "readable required checks not recorded: $(cat "$work/out")"
grep -q 'token cannot read the protection' "$work/out" && fail "a readable ruleset reported as refused: $(cat "$work/out")"

# A real run records it, keeps a key the owner holds, and installs the hook that follows the commit format.
mkdir -p "$repo/.claude"
echo '{"workflow": {"merge": "rebase"}}' >"$repo/.claude/senior-mode.json"
run setup repo || fail "setup repo failed: $(cat "$work/err")"
conf() { jq -r "$1" "$repo/.claude/senior-mode.json"; }
[ "$(conf .workflow.integration)/$(conf .workflow.merge)" = dev/rebase ] || fail "the config of the owner was not kept, or the findings not written: $(cat "$repo/.claude/senior-mode.json")"
[ "$(conf .adopt.kind)" = evergreen ] || fail "adopt.kind not written"
grep -q '(kept)' "$work/out" || fail "a key kept from the config is not said: $(cat "$work/out")"
[ -x "$repo/.githooks/commit-msg" ] || fail "the commit-msg hook is not installed executable"
(cd "$repo" && .githooks/commit-msg --subjects <<<"ABC-5 fix the thing") || fail "the installed hook refuses the project's own commit shape"
(cd "$repo" && .githooks/commit-msg --subjects <<<"feat: add") 2>/dev/null && fail "the installed hook accepts a Conventional Commit in a ticket-prefix project"
git -C "$repo" add -A
git -C "$repo" commit -q -m "ABC-14 adopt"

# `start`: the branch name follows the pattern with the tracker key, from origin/dev; no key, no branch.
git -C "$repo" config user.name t
git -C "$repo" config user.email t@t
git -C "$repo" update-ref refs/remotes/origin/dev "$(git -C "$repo" rev-parse dev)"
jq '.project = {id: "PVT_1", owner: "acme", number: 3, fields: {Status: {id: "F_S", options: {Backlog: "o1", Ready: "o2", "In progress": "o3"}}}}' \
  "$repo/.claude/senior-mode.json" >"$work/c" && cp "$work/c" "$repo/.claude/senior-mode.json"
git -C "$repo" add -A
git -C "$repo" commit -q -m "ABC-15 board"
issue() { # title labels body
  GH_ISSUE=$(jq -nc --arg t "$1" --arg b "${3:-}" --argjson l "[${2:-}]" '{title: $t, state: "OPEN", labels: $l, body: $b}')
  export GH_ISSUE
}
issue "Fix the login" '{"name": "bug"}' $'Details\n\nTracker: ABC-9'
: >"$GH_LOG"
run start 31 || fail "start failed: $(cat "$work/err")"
grep -qx 'branch ABC-9-fix-the-login' "$work/out" || fail "branch name does not follow the pattern: $(cat "$work/out")"
grep -qx 'base dev' "$work/out" || fail "the base of the pull request is not said: $(cat "$work/out")"
wt=$(sed -n 's/^worktree //p' "$work/out")
[ "$(git -C "$wt" rev-parse HEAD~0)" = "$(git -C "$repo" rev-parse refs/remotes/origin/dev)" ] || fail "the branch does not start from origin/dev"
run start 31 || fail "rerun failed: $(cat "$work/err")"
[ "$(git -C "$repo" worktree list | grep -c 'ABC-9-fix-the-login')" -eq 1 ] || fail "rerun added a second worktree"
issue "No key here" '' 'nothing to find'
: >"$GH_LOG"
run start 32 && fail "start went on without the tracker key the branch pattern needs"
grep -q 'Tracker: KEY-n' "$work/err" || fail "the missing key is not explained: $(cat "$work/err")"
logged 'labels[]=needs-info' || fail "the ticket without a key is not labelled needs-info: $(cat "$GH_LOG")"
issue "Old line fix" '' $'Base: prod\nTracker: ABC-10'
: >"$GH_LOG"
run start 33 && fail "start went on with a base that is no release line"
logged 'labels[]=needs-human' || fail "a base outside the workflow is not needs-human: $(cat "$GH_LOG")"

# check --ci-only: a check that a job of the project's CI covers is not run again, its state on HEAD is read instead.
ci="$work/ci"
git init -q -b main "$ci"
git -C "$ci" remote add origin https://github.com/acme/app.git
mkdir -p "$ci/.claude"
cat >"$ci/.claude/senior-mode.json" <<'JSON'
{"ci": {"mode": "existing"},
 "workflow": {"ci": {"jobs": [{"context": "ci / lint", "covers": ["lint"]}]}},
 "checks": [{"name": "lint", "run": "echo second lint >&2; exit 9"}, {"name": "subjects", "run": "true"}]}
JSON
git -C "$ci" add -A
git -C "$ci" commit -q -m "chore: config"
runci() { (cd "$ci" && "$cli" "$@") >"$work/out" 2>&1; }
jobs() { # the check-runs of the lint job in a state: success, pending, failure or none
  case $1 in
    none) echo '{"check_runs": []}' ;;
    *) jq -nc --arg s "$1" '{check_runs: [{name: "ci / lint", html_url: "https://ci/run/\($s)",
         status: (if $s == "pending" then "in_progress" else "completed" end),
         conclusion: (if $s == "success" then "success" elif $s == "failure" then "failure" else null end)}]}' ;;
  esac
}
runs_for() { jobs "$1" >"$FIX/runs.json"; }
runs_for success
runci check --ci-only || fail "check --ci-only fails with a green job: $(cat "$work/out")"
grep -q 'skip  lint: covered by ci / lint' "$work/out" || fail "the covered check is not skipped: $(cat "$work/out")"
grep -q 'second lint' "$work/out" && fail "the covered check ran again"
grep -q 'ok    ci / lint (CI)' "$work/out" || fail "the state of the job is not read: $(cat "$work/out")"
runs_for pending
runci check --ci-only
[ $? -eq 2 ] || fail "a pending job does not make check --ci-only wait (status 2)"
grep -q 'wait  ci / lint' "$work/out" || fail "wait not reported: $(cat "$work/out")"
runs_for none
runci check --ci-only
[ $? -eq 2 ] || fail "a job with no run yet is not pending"
runs_for failure
runci check --ci-only && fail "a failed job does not fail check --ci-only"
grep -q 'FAIL  ci / lint: https://ci/run/failure' "$work/out" || fail "the failed job is not named with its URL: $(cat "$work/out")"
# Without --ci-only the covered check runs as any other.
runci check && fail "check without --ci-only skipped a covered check"
grep -q 'second lint' "$work/out" || fail "check without --ci-only did not run the lint"
# Another CI mode does not read the jobs.
jq '.ci.mode = "local"' "$ci/.claude/senior-mode.json" >"$work/c"
(cd "$ci" && cp "$work/c" .claude/senior-mode.json && git commit -q -am "chore: local" && "$cli" check --ci-only) >"$work/out" 2>&1 && fail "ci.mode local skipped a check"
git -C "$ci" reset -q --hard HEAD~1

# publish: the status holds the jobs of the CI as they are now.
status_of() { grep -o -- "-f state=[a-z]* -f context=senior-mode/ci -f description=.*" "$GH_LOG" | tail -n 1; }
runs_for success
runci check --ci-only
: >"$GH_LOG"
runci publish || fail "publish failed: $(cat "$work/out")"
status_of | grep -q 'state=success' || fail "a green job does not give success: $(status_of)"
runs_for pending
: >"$GH_LOG"
runci publish || fail "publish failed with a pending job: $(cat "$work/out")"
status_of | grep -q 'state=pending -f context=senior-mode/ci -f description=wait ci / lint' || fail "a pending job does not leave the status pending: $(status_of)"
runs_for failure
: >"$GH_LOG"
runci publish || fail "publish failed with a failed job: $(cat "$work/out")"
status_of | grep -q 'state=failure.*https://ci/run/failure' || fail "a failed job does not fail the status with its URL: $(status_of)"

# The hooks follow the detected workflow: format free accepts any subject; the branch gate compares to the integration branch.
hooks="$work/hooks"
git init -q -b main "$hooks"
mkdir -p "$hooks/.claude" "$hooks/.githooks"
cp "$tpl/githooks/commit-msg" "$tpl/githooks/pre-push" "$hooks/.githooks/"
echo '{"workflow": {"commit": {"format": "free"}}}' >"$hooks/.claude/senior-mode.json"
(cd "$hooks" && .githooks/commit-msg --subjects <<<"whatever I wrote") || fail "format free refuses a subject"
echo '{}' >"$hooks/.claude/senior-mode.json"
(cd "$hooks" && .githooks/commit-msg --subjects <<<"whatever I wrote") 2>/dev/null && fail "no workflow accepts a free subject"
cat >"$hooks/.claude/senior-mode.json" <<'JSON'
{"workflow": {"integration": "dev", "branch": {"pattern": "{type}/{issue}-{slug}"},
  "commit": {"format": "ticket-prefix", "pattern": "^[A-Z]+-[0-9]+ .+$"}},
 "checks": [{"name": "paths", "run": "cat \"${SENIOR_MODE_CHANGED_FILES:-/dev/null}\" >\"$PWD/.changed\""}]}
JSON
echo '.changed' >"$hooks/.gitignore"
git -C "$hooks" add -A
git -C "$hooks" commit -q -m "ABC-1 base"
git -C "$hooks" update-ref refs/remotes/origin/main HEAD
git -C "$hooks" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
git -C "$hooks" checkout -q -b dev
echo d >"$hooks/dev.txt"
git -C "$hooks" add -A
git -C "$hooks" commit -q -m "ABC-2 on dev"
git -C "$hooks" update-ref refs/remotes/origin/dev HEAD
git -C "$hooks" checkout -q -b feat/5-thing
echo f >"$hooks/f.txt"
git -C "$hooks" add -A
git -C "$hooks" commit -q -m "ABC-3 the thing"
(cd "$hooks" && .githooks/commit-msg --branch) >"$work/out" 2>&1 || fail "the branch gate refuses commits of the project's format: $(cat "$work/out")"
git -C "$hooks" commit -q --allow-empty -m "feat: not a ticket"
(cd "$hooks" && .githooks/commit-msg --branch) >"$work/out" 2>&1 && fail "the branch gate accepts a subject out of the pattern"
grep -q 'feat: not a ticket' "$work/out" || fail "the gate checked the wrong range (main, not dev): $(cat "$work/out")"
grep -q 'ABC-2 on dev' "$work/out" && fail "the gate compared to main, not to the integration branch: $(cat "$work/out")"
git -C "$hooks" reset -q --hard HEAD~1
git -C "$hooks" checkout -q -b thing
(cd "$hooks" && .githooks/commit-msg --branch) >"$work/out" 2>&1
grep -q "branch thing does not follow the project's pattern" "$work/out" || fail "a branch out of the pattern is not said: $(cat "$work/out")"
head=$(git -C "$hooks" rev-parse HEAD)
(cd "$hooks" && .githooks/pre-push <<<"refs/heads/thing $head refs/heads/thing 0000000000000000000000000000000000000000") >"$work/out" 2>&1 ||
  fail "pre-push failed: $(cat "$work/out")"
[ "$(cat "$hooks/.changed")" = f.txt ] || fail "pre-push narrowed to the paths of main, not of the integration branch: $(cat "$hooks/.changed")"

[ "$failures" -eq 0 ] && echo "workflow: all cases pass"
exit "$failures"
