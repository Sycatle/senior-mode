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
  "pr view 7 "*) cat "$FIX/prview.json" ;;
  "api repos/acme/app --jq .private") cat "$FIX/private" ;;
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
cat >"$work/stub/magick" <<'STUB'
#!/usr/bin/env bash
if [ -n "${SHRINK_FAIL:-}" ]; then cp "$1" "$4"; else head -c 100 "$1" >"$4"; fi
STUB
chmod +x "$work/stub/magick"
cat >"$work/capturer.sh" <<'STUB'
#!/usr/bin/env bash
echo "$SENIOR_MODE_SHOTS_SIDE $SENIOR_MODE_SHOTS_URL" >>"$CAP_LOG"
[ -z "${CAP_FAIL:-}" ] || { echo "browser crashed" >&2; exit 3; }
jq -r '.[].file' "$SENIOR_MODE_SHOTS_PLAN" | while read -r f; do head -c "${PNG_BYTES:-100}" /dev/zero | tr '\0' x >"$SENIOR_MODE_SHOTS_DIR/$f"; done
jq -c '[.[] | {route, viewport, pageErrors: [], consoleErrors: 1, badRequests: [{url: "/x", status: 404}]}]' "$SENIOR_MODE_SHOTS_PLAN" >"$SENIOR_MODE_SHOTS_DIR/results.json"
STUB
chmod +x "$work/capturer.sh"
echo '[]' | tee "$work/fix/comments.json" "$work/fix/deployments.json" "$work/fix/statuses.json" >/dev/null
export PATH="$work/stub:$PATH" HOME="$work/home" GH_LOG="$work/gh.log" CURL_LOG="$work/curl.log" CAP_LOG="$work/cap.log" SENIOR_MODE_SHOTS_CMD="$work/capturer.sh" SENIOR_MODE_PREVIEW_POLL=1 FIX="$work/fix" SENIOR_MODE_RETRY_DELAY=0 LANG=C LC_ALL=C

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

# H: senior-mode shots <pr> (#792).
g checkout -q -B feat/790-x main
echo y >"$repo/y.txt"
g add -A
g commit -q -m "feat: shots"
head=$(g rev-parse HEAD)
jq -nc --arg h "$head" '{headRefOid: $h, headRefName: "feat/790-x", baseRefName: "main"}' >"$FIX/prview.json"
echo '[]' >"$FIX/comments.json"
echo 0 >"$FIX/curl-rc"
shotcfg() { # extra preview keys (JSON object), merged into the preview block
  config "$(jq -nc --argjson e "$1" '{checks: [{name: "lint", run: "true"}], preview: ({url: "https://after.example.test", baseUrl: "https://before.example.test",
    routes: ["/", "/about"], viewports: ["390x844", "1280x800"]} + $e)}')"
}
shotsrun() { : >"$GH_LOG"; : >"$CAP_LOG"; (cd "$repo" && "$cli" shots 7) >"$work/out" 2>"$work/err"; }
branch_files() { git -C "$origin" ls-tree -r --name-only senior-mode/shots 2>/dev/null; }
branch_tip() { git -C "$origin" rev-parse -q --verify senior-mode/shots 2>/dev/null || echo none; }
local_dir="$repo/.git/senior-mode/shots/pr-7"

# H1: a private repository: eight files under pr-7, none over maxKB, four rows with ?raw=true links, shots.json per page.
echo true >"$FIX/private"
shotcfg '{}'
shotsrun || fail "H: shots failed: $(cat "$work/err")"
[ "$(branch_files | grep -c '^pr-7/')" = 8 ] || fail "H: the branch holds $(branch_files | grep -c '^pr-7/') files under pr-7: $(branch_files)"
branch_files | grep -qx 'pr-7/about-390x844-before.png' || fail "H: no pr-7/about-390x844-before.png: $(branch_files)"
big=0
for f in $(branch_files); do [ "$(git -C "$origin" cat-file -s "senior-mode/shots:$f")" -le 409600 ] || big=1; done
[ "$big" = 0 ] || fail "H: a file is over preview.maxKB"
[ "$(body | grep -c '^| `')" = 4 ] || fail "H: the table does not have four rows: $(body)"
[ "$(body | grep -o '?raw=true' | wc -l)" = 8 ] || fail "H: the table does not have eight links: $(body)"
body | grep -q "blob/$(branch_tip)/pr-7/index-1280x800-after.png?raw=true" || fail "H: a link does not name the commit of the branch: $(body)"
{ grep -q '^after https://after.example.test$' "$CAP_LOG" && grep -q '^before https://before.example.test$' "$CAP_LOG"; } || fail "H: wrong URLs captured: $(cat "$CAP_LOG")"
jq -e '[.[] | select(.side == "after" and .route == "/about" and .viewport == "1280x800")] | length == 1 and (.[0] | has("pageErrors") and .consoleErrors == 1 and (.badRequests | length) == 1 and .badRequests[0].status == 404)' \
  "$local_dir/shots.json" >/dev/null || fail "H: shots.json lacks the per-page results: $(cat "$local_dir/shots.json")"
[ "$(jq length "$local_dir/shots.json")" = 8 ] || fail "H: shots.json has $(jq length "$local_dir/shots.json") entries, not 8"
[ "$(comments)" = 1 ] || fail "H: $(comments) preview comments"

# H2: a public repository pushes nothing unless preview.public; the files stay local.
tip=$(branch_tip)
echo false >"$FIX/private"
shotsrun || fail "H: shots failed on a public repository: $(cat "$work/err")"
[ "$(branch_tip)" = "$tip" ] || fail "H: a public repository was pushed to"
body | grep -q 'screenshots not published' || fail "H: no 'screenshots not published': $(body)"
[ "$(find "$local_dir" -maxdepth 1 -name '*.png' | wc -l)" = 8 ] || fail "H: the files did not stay local"
shotcfg '{"public": true}'
shotsrun || fail "H: shots failed with preview.public: $(cat "$work/err")"
[ "$(branch_tip)" != "$tip" ] || [ "$(branch_files | grep -c '^pr-7/')" = 8 ] || fail "H: preview.public did not push"

# H3: a capturer that fails: non-zero exit with the reason, the comment says so, nothing pushed.
echo true >"$FIX/private"
shotcfg '{}'
tip=$(branch_tip)
: >"$CAP_LOG"
(cd "$repo" && CAP_FAIL=1 "$cli" shots 7) >"$work/out" 2>"$work/err" && fail "H: shots succeeded with a failing capturer"
grep -q 'browser crashed' "$work/err" || fail "H: the reason is not said: $(cat "$work/err")"
body | grep -q '^No screenshots: .*browser crashed' || fail "H: no 'No screenshots' comment: $(body)"
[ "$(branch_tip)" = "$tip" ] || fail "H: something was pushed after a failed capture"

# H4: an image over maxKB is scaled down (magick), or not pushed and the row says too large.
shotcfg '{"maxKB": 1}'
(cd "$repo" && PNG_BYTES=3000 "$cli" shots 7) >"$work/out" 2>"$work/err" || fail "H: shots failed with big images: $(cat "$work/err")"
big=0
for f in $(branch_files | grep '^pr-7/'); do [ "$(git -C "$origin" cat-file -s "senior-mode/shots:$f")" -le 1024 ] || big=1; done
[ "$big" = 0 ] && [ "$(branch_files | grep -c '^pr-7/')" = 8 ] || fail "H: big images were not scaled down: $(branch_files)"
(cd "$repo" && PNG_BYTES=3000 SHRINK_FAIL=1 "$cli" shots 7) >"$work/out" 2>"$work/err" || fail "H: shots failed when it cannot scale: $(cat "$work/err")"
[ "$(branch_files | grep -c '^pr-7/')" = 0 ] || fail "H: an image that stays too large was pushed"
[ "$(body | grep -o 'too large' | wc -l)" = 8 ] || fail "H: the rows do not say too large: $(body)"

# H5: no preview URL, preview.command: it is served in a slot (its {{port}} is the slot's PORT) and stopped after the capture.
if command -v python3 >/dev/null && command -v setsid >/dev/null; then
  mkdir -p "$repo/.senior-mode"
  echo 'PORT={{port:18740}}' >"$repo/.senior-mode/slot.env"
  g add -A
  g commit -q -m "chore: slot"
  jq -nc --arg h "$(g rev-parse HEAD)" '{headRefOid: $h, headRefName: "feat/790-x", baseRefName: "main"}' >"$FIX/prview.json"
  config '{"checks": [{"name": "lint", "run": "true"}], "preview": {"command": "python3 -m http.server {{port}} --bind 127.0.0.1", "baseUrl": "https://before.example.test", "waitSeconds": 20}}'
  shotsrun || fail "H: shots with preview.command failed: $(cat "$work/err")"
  grep -q '^after http://127.0.0.1:18741$' "$CAP_LOG" || fail "H: the command was not captured on the port of its slot: $(cat "$CAP_LOG")"
  for _ in 1 2 3 4 5 6; do pgrep -f 'http.server 1874[1]' >/dev/null || break; sleep 1; done
  ! pgrep -f 'http.server 1874[1]' >/dev/null || fail "H: the preview server is still running after the capture"
fi

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
