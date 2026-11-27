#!/usr/bin/env bash
# Tests for the UI pull requests of epic #389 (lib/shots.sh): `ui.paths`, the label `ui`, the prediction of `ready`,
# the verdict of `publish`, the preset of `setup repo`. Offline: gh is a stub that serves $FIX and logs its arguments.
# shellcheck disable=SC2016 # jq programs and stub bodies, not expanded here
set -u
cli=$(cd "$(dirname "$0")/.." && pwd)/senior-mode
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

mkdir -p "$work/stub" "$work/fix" "$work/home"
cat >"$work/stub/gh" <<'STUB'
#!/usr/bin/env bash
all="$*"
echo "$all" >>"$GH_LOG"
case "$all" in
  "api graphql --input -")
    q=$(cat)
    if grep -q closingIssuesReferences <<<"$q"; then cat "$FIX/assoc" 2>/dev/null || exit 1
    elif grep -q projectItems <<<"$q"; then exit 1
    else cat "$FIX/board.json"; fi ;;
  "api repos/acme/app/commits/"*"/status --jq "*) ;;
  "api repos/acme/app/issues/7/comments --paginate --jq "*) jq -r "${all#*--jq }" "$FIX/comments.json" ;;
  "api repos/acme/app/issues/7/comments -f body="*)
    jq --arg b "${all#*-f body=}" '. + [{id: (length + 100), body: $b}]' "$FIX/comments.json" >"$FIX/c.tmp" && mv "$FIX/c.tmp" "$FIX/comments.json" ;;
  "api -X PATCH repos/acme/app/issues/comments/"*" -f body="*)
    id=${all%% -f body=*} id=${id##*/}
    jq --argjson i "$id" --arg b "${all#*-f body=}" 'map(if .id == $i then .body = $b else . end)' "$FIX/comments.json" >"$FIX/c.tmp" && mv "$FIX/c.tmp" "$FIX/comments.json" ;;
  "api repos/acme/app/deployments?sha="*" --jq "*) jq -r "${all#*--jq }" "$FIX/deployments.json" ;;
  "api repos/acme/app/deployments/"*"/statuses --jq "*) jq -r "${all#*--jq }" "$FIX/statuses.json" ;;
esac
STUB
chmod +x "$work/stub/gh"
cat >"$work/stub/curl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$CURL_LOG"
exit "$(cat "$FIX/curl-rc" 2>/dev/null || echo 0)"
STUB
chmod +x "$work/stub/curl"
echo '[]' | tee "$work/fix/comments.json" "$work/fix/deployments.json" "$work/fix/statuses.json" >/dev/null
export PATH="$work/stub:$PATH" HOME="$work/home" GH_LOG="$work/gh.log" CURL_LOG="$work/curl.log" SENIOR_MODE_PREVIEW_POLL=1 FIX="$work/fix" SENIOR_MODE_RETRY_DELAY=0 LANG=C LC_ALL=C

repo="$work/repo"
origin="$work/github.com/acme/app.git"
git init -q --bare -b main "$origin"
git init -q -b main "$repo"
git -C "$repo" remote add origin "$origin"
mkdir -p "$repo/.claude"
g() { git -C "$repo" -c core.hooksPath=/dev/null -c user.name=t -c user.email=t@t "$@"; }
config() { # json
  printf '%s\n' "$1" >"$repo/.claude/senior-mode.json"
  g add -A
  g commit -q -m "chore: config" --allow-empty
}
run() { (cd "$repo" && "$cli" "$@") >"$work/out" 2>&1; }
ok='"checks":[{"name":"lint","run":"true"}]'
config "{$ok}"
g push -q origin main
g checkout -q -b feat/790-x

assoc() { # labels of the ticket the open pull request closes
  jq -nc --argjson l "$1" '{data: {repository: {object: {associatedPullRequests: {nodes: [{number: 7, state: "OPEN", headRefName: "feat/790-x",
    closingIssuesReferences: {nodes: [{number: 9, labels: {nodes: ($l | map({name: .}))}}]}}]}}}}}' >"$FIX/assoc"
}
published() { # config json, file to add in the commit: check then publish on a fresh branch
  g checkout -q -B feat/790-x main
  config "$1"
  mkdir -p "$repo/$(dirname "$2")"
  echo x >"$repo/$2"
  g add -A
  g commit -q -m "feat: x"
  run check || fail "check: $(cat "$work/out")"
  : >"$GH_LOG"
  run publish || fail "publish: $(cat "$work/out")"
}
said_ui() { grep -q '^ui: UI pull request' "$work/out"; }

# A: ui.paths and the diff: components/Button.tsx is UI, src/server.ts is not, the label ui is whatever the diff.
assoc '[]'
published "{$ok,\"ui\":{\"paths\":[\"components/**\"]}}" components/Button.tsx
said_ui || fail "A: a diff in components/** is not UI: $(cat "$work/out")"
grep -q 'components/Button.tsx' "$work/out" || fail "A: the reason does not name the file: $(cat "$work/out")"
published "{$ok,\"ui\":{\"paths\":[\"components/**\"]}}" src/server.ts
! said_ui || fail "A: a diff in src/server.ts only is UI: $(cat "$work/out")"
assoc '["ui"]'
published "{$ok,\"ui\":{\"paths\":[\"components/**\"]}}" src/other.ts
said_ui || fail "A: the label ui does not make a UI pull request: $(cat "$work/out")"

# B: no ui.paths and no label: not UI for any diff; the label alone still counts.
assoc '["bug"]'
published "{$ok}" components/Card.tsx
! said_ui || fail "B: UI with no ui.paths and no ui label: $(cat "$work/out")"
assoc '["ui"]'
published "{$ok}" docs/x.md
said_ui || fail "B: the label ui alone is not enough: $(cat "$work/out")"

# C: a ticket predicted UI by its Paths whose final diff touches no UI file: the diff decides.
assoc '[]'
published "{$ok,\"ui\":{\"paths\":[\"components/**\"]}}" lib/only.ts
! said_ui || fail "C: predicted UI, no UI file in the diff, yet UI: $(cat "$work/out")"

# D: ready predicts a UI ticket from its Paths, or from its label.
crit=$'## Acceptance criteria\n\n- Given a, when b, then c.\n'
items="[]"
item() { # number paths labels-json
  items=$(jq -c --argjson n "$1" --arg p "$2" --argjson l "$3" --arg b "$crit" \
    '. + [{fieldValues: {nodes: [{name: "Backlog", field: {name: "Status"}}, {name: "P1 next", field: {name: "Priority"}},
      {name: "S", field: {name: "Size"}}, {text: $p, field: {name: "Paths"}}]},
      content: {authorAssociation: "OWNER", number: $n, state: "OPEN", body: $b, labels: {nodes: ($l | map({name: .}))},
        milestone: null, blockedBy: {nodes: []}}}]' <<<"$items")
}
item 10 "components/Button.tsx, docs/guide/x.md" '[]'
item 11 "src/server.ts" '[]'
item 12 "src/server.ts" '["ui"]'
jq -nc --argjson i "$items" '{data: {node: {items: {pageInfo: {hasNextPage: false}, nodes: $i}}}}' >"$FIX/board.json"
proj='"project":{"id":"PVT_1","owner":"acme","number":3,"fields":{"Status":{"id":"F_S","options":{"Backlog":"o1","Ready":"o2"}}}}'
config "{$proj,\"ui\":{\"paths\":[\"components/**\"]}}"
run ready --dry-run 10 11 12 || fail "D: ready failed: $(cat "$work/out")"
grep -q '^#10 UI ticket (predicted)$' "$work/out" || fail "D: Paths in ui.paths, no prediction: $(cat "$work/out")"
! grep -q '^#11 UI ticket (predicted)' "$work/out" || fail "D: Paths that match nothing, yet predicted: $(cat "$work/out")"
grep -q '^#12 UI ticket (predicted)$' "$work/out" || fail "D: the label ui does not predict a UI ticket: $(cat "$work/out")"
config "{$proj}"
run ready --dry-run 10 11 || fail "D: ready failed: $(cat "$work/out")"
! grep -q 'UI ticket (predicted)' "$work/out" || fail "D: a prediction without ui.paths: $(cat "$work/out")"

# G: the preview comment of a UI pull request (#791).
uipaths='"ui":{"paths":["components/**"]}'
comments() { jq '[.[] | select(.body | contains("<!-- senior-mode:preview -->"))] | length' "$FIX/comments.json"; }
body() { jq -r '.[0].body' "$FIX/comments.json"; }
assoc '[]'
echo '[]' >"$FIX/comments.json"
echo 0 >"$FIX/curl-rc"
: >"$CURL_LOG"
published "{$ok,$uipaths,\"preview\":{\"url\":\"https://{{branch}}.example.test\"}}" components/A.tsx
body | grep -qx 'Preview: https://feat/790-x.example.test' || fail "G: no preview from preview.url: $(body)"
grep -q -- '-fsS --max-time 10' "$CURL_LOG" || fail "G: the URL was not checked with curl -fsS --max-time 10: $(cat "$CURL_LOG")"
[ "$(comments)" = 1 ] || fail "G: $(comments) preview comments after one push"
echo '[{"id": 5}]' >"$FIX/deployments.json"
echo '[{"state": "success", "environment_url": "https://dep.example.test"}]' >"$FIX/statuses.json"
published "{$ok,$uipaths,\"preview\":{\"waitSeconds\":1}}" components/B.tsx
body | grep -qx 'Preview: https://dep.example.test' || fail "G: no preview from the deployment status: $(body)"
[ "$(comments)" = 1 ] || fail "G: a second push made $(comments) preview comments, not one edited in place"
echo '[]' >"$FIX/deployments.json"
published "{$ok,$uipaths,\"preview\":{\"waitSeconds\":1}}" components/C.tsx
body | grep -qx 'No preview: not deployed within 1 s' || fail "G: no 'not deployed' reason: $(body)"
published "{$ok,$uipaths}" components/D.tsx
body | grep -qx 'No preview: not configured' || fail "G: no 'not configured' reason: $(body)"
echo 22 >"$FIX/curl-rc"
published "{$ok,$uipaths,\"preview\":{\"url\":\"https://down.example.test\"}}" components/E.tsx
body | grep -q '^No preview: ' || fail "G: a URL that fails is shown as a preview: $(body)"
body | grep -q 'down.example.test' && fail "G: a URL that failed curl is shown: $(body)"
[ "$(comments)" = 1 ] || fail "G: $(comments) preview comments after five pushes"
echo '[]' >"$FIX/comments.json"
published "{$ok,$uipaths,\"preview\":{\"url\":\"https://x.example.test\"}}" src/plain.ts
[ "$(jq length "$FIX/comments.json")" = 0 ] || fail "G: a comment on a pull request that is not UI: $(body)"
echo 0 >"$FIX/curl-rc"

# E: setup repo writes ui.paths from the preset of a Next.js project, never over a set value, nothing for Rust.
project() { # name package.json
  git init -q -b main "$work/$1"
  printf '%s\n' "$2" >"$work/$1/package.json"
}
setup() { (cd "$work/$1" && "$cli" setup repo) >"$work/out" 2>&1 || fail "E: setup repo: $(cat "$work/out")"; }
project next '{"dependencies": {"next": "16"}}'
setup next
[ "$(jq -c '.ui.paths' "$work/next/.claude/senior-mode.json")" = '["app/**/*.tsx","components/**","**/*.css","public/**"]' ] ||
  fail "E: the Next.js preset did not write ui.paths: $(jq -c .ui "$work/next/.claude/senior-mode.json")"
project own '{"dependencies": {"next": "16"}}'
mkdir -p "$work/own/.claude"
echo '{"ui": {"paths": ["web/**"]}}' >"$work/own/.claude/senior-mode.json"
setup own
[ "$(jq -c '.ui.paths' "$work/own/.claude/senior-mode.json")" = '["web/**"]' ] || fail "E: a set ui.paths was overwritten"
git init -q -b main "$work/crate"
: >"$work/crate/Cargo.toml"
setup crate
jq -e 'has("ui") | not' "$work/crate/.claude/senior-mode.json" >/dev/null || fail "E: a Rust project got ui.paths"

# F: config validate accepts an array of globs for ui.paths, refuses another type.
(cd "$work/next" && "$cli" config validate) >"$work/out" 2>&1 || fail "F: ui.paths from the preset does not validate: $(cat "$work/out")"
echo '{"ui": {"paths": "components/**"}}' >"$work/own/.claude/senior-mode.json"
! (cd "$work/own" && "$cli" config validate) >"$work/out" 2>&1 || fail "F: ui.paths as a string validates"

[ "$failures" -eq 0 ] && echo "ok" || exit 1
