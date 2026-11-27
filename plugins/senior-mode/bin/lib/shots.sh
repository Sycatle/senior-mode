# UI pull requests and their screenshots (epic #389, spec §4, ADR 0025). Definitions only.
# A pull request is a UI pull request when its diff touches a glob of `ui.paths`, or when the ticket it closes
# carries the label `ui`. A project with neither has no UI tickets.

# The globs of `ui.paths` as JSON, [] when the project sets none.
ui_globs() {
  config_effective 2>/dev/null | jq -c '.ui.paths // []' 2>/dev/null || echo '[]'
}

# The open pull request that contains the commit $1, as JSON {number, branch, labels}, the labels of the tickets it
# closes included; fails when there is none.
# shellcheck disable=SC2016 # a GraphQL query, not shell
UI_ASSOC_QUERY='query($owner: String!, $name: String!, $sha: GitObjectID!) { repository(owner: $owner, name: $name) {
  object(oid: $sha) { ... on Commit { associatedPullRequests(first: 10) { nodes { number state headRefName
    closingIssuesReferences(first: 20) { nodes { labels(first: 30) { nodes { name } } } } } } } } } }'
ui_assoc() {
  local slug
  slug=$(repo_slug) || return 1
  jq -nc --arg q "$UI_ASSOC_QUERY" --arg o "${slug%%/*}" --arg n "${slug#*/}" --arg s "$1" \
    '{query: $q, variables: {owner: $o, name: $n, sha: $s}}' | gh_retry api graphql --input - |
    jq -ce '[.data.repository.object.associatedPullRequests.nodes[]? | select(.state == "OPEN")][0] | select(. != null)
      | {number, branch: .headRefName, labels: ([.closingIssuesReferences.nodes[]?.labels.nodes[]?.name] | unique)}'
}

# `ui_pr [<sha> [<base>]]`: whether the pull request that ends at the commit (default HEAD) is a UI pull request:
# the diff with the base (default: the default branch) touches a glob of `ui.paths`, or its ticket is labelled `ui`.
# The diff decides, never a prediction. Exit 0 and the reason on stdout when it is, 1 when it is not.
ui_pr() {
  local sha=${1:-HEAD} base=${2:-} globs files hit labels
  globs=$(ui_globs)
  if [ "$globs" != "[]" ]; then
    [ -n "$base" ] || base=$(default_branch) || return 1
    files=$(git -c core.quotePath=false diff --name-only --no-renames "$base...$sha") || return 1
    hit=$(protected_match "$globs" <<<"$files" | head -n 1) || true
    [ -z "$hit" ] || {
      echo "the diff touches $hit"
      return 0
    }
  fi
  labels=$(ui_assoc "$(git rev-parse "$sha^{commit}")" 2>/dev/null | jq -r '.labels[]') || labels=""
  if grep -qx ui <<<"$labels"; then
    echo "the ticket is labelled ui"
    return 0
  fi
  return 1
}

# `{{pr}}`, `{{branch}}`, `{{sha}}` and `{{slug}}` (the branch in lower case, anything but letters and digits as -) of
# the template $1 for the pull request $2 of the branch $3 at the commit $4.
preview_expand() {
  local t=$1 slug
  slug=$(tr '[:upper:]' '[:lower:]' <<<"$3" | sed 's/[^a-z0-9]\{1,\}/-/g; s/^-//; s/-$//')
  t=${t//\{\{pr\}\}/$2}
  t=${t//\{\{branch\}\}/$3}
  t=${t//\{\{sha\}\}/$4}
  printf '%s\n' "${t//\{\{slug\}\}/$slug}"
}

# The `environment_url` of a successful GitHub deployment status on the commit $1, nothing when there is none.
preview_deployed() {
  local slug id url
  slug=$(repo_slug) || return 0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    url=$(gh_retry api "repos/$slug/deployments/$id/statuses" \
      --jq '[.[] | select(.state == "success" and (.environment_url // "") != "") | .environment_url][0] // empty') || continue
    [ -z "$url" ] || {
      printf '%s\n' "$url"
      return 0
    }
  done < <(gh_retry api "repos/$slug/deployments?sha=$1" --jq '.[].id' 2>/dev/null)
  return 0
}

# The line of the preview comment for the pull request $2 of the branch $3 at the commit $1: `Preview: <url>`
# or `No preview: <reason>`. Sources, the first that answers: `preview.url` (a template), then the `environment_url` of
# a successful deployment status on the commit, polled every SENIOR_MODE_PREVIEW_POLL seconds (15) for
# `preview.waitSeconds` (300, or $4 seconds when given). A URL is shown only when one `curl` of it succeeds (2xx or 3xx).
preview_line() {
  local sha=$1 pr=$2 branch=$3 cfg tpl wait poll waited=0 url=""
  cfg=$(config_effective 2>/dev/null) || cfg='{}'
  tpl=$(jq -r '.preview.url // empty' <<<"$cfg")
  wait=${4:-$(jq -r '.preview.waitSeconds // 300' <<<"$cfg")}
  poll=${SENIOR_MODE_PREVIEW_POLL:-15}
  if [ -n "$tpl" ]; then
    url=$(preview_expand "$tpl" "$pr" "$branch" "$sha")
  else
    # Nothing is configured when there is no `preview` key and the project does not deploy previews on `ready`.
    if ! jq -e '(.preview != null) or (.deploy.previews == "ready")' <<<"$cfg" >/dev/null; then
      echo "No preview: not configured"
      return 0
    fi
    while :; do
      url=$(preview_deployed "$sha")
      [ -z "$url" ] || break
      [ "$waited" -lt "$wait" ] || break
      sleep "$poll"
      waited=$((waited + poll))
    done
    [ -n "$url" ] || {
      echo "No preview: not deployed within $wait s"
      return 0
    }
  fi
  if curl -fsS --max-time 10 -o /dev/null "$url" 2>/dev/null; then
    echo "Preview: $url"
  else
    echo "No preview: the preview URL did not answer with a 2xx or 3xx status"
  fi
}

# Sets the one comment of the pull request $2 that carries the marker, in place: created the first time, edited after.
PREVIEW_MARKER='<!-- senior-mode:preview -->'
preview_comment() { # sha pr line
  local slug id
  slug=$(repo_slug) || return 1
  id=$(gh_retry api "repos/$slug/issues/$2/comments" --paginate \
    --jq ".[] | select(.body | contains(\"$PREVIEW_MARKER\")) | .id") || return 1
  id=${id%%$'\n'*}
  if [ -n "$id" ]; then
    gh_retry api -X PATCH "repos/$slug/issues/comments/$id" -f body="$PREVIEW_MARKER
$3" >/dev/null
  else
    gh_retry api "repos/$slug/issues/$2/comments" -f body="$PREVIEW_MARKER
$3" >/dev/null
  fi
}

# What `publish` says of a commit once its statuses are set: one line when it is a UI pull request, and its preview
# comment, kept up to date after each push. A pull request that is not UI gets no comment.
ui_report() {
  local why info pr
  why=$(ui_pr "$1") || return 0
  echo "ui: UI pull request ($why)"
  info=$(ui_assoc "$(git rev-parse "$1^{commit}")" 2>/dev/null) || {
    echo "ui: no open pull request for this commit, no preview comment" >&2
    return 0
  }
  pr=$(jq -r '.number' <<<"$info")
  preview_comment "$1" "$pr" "$(preview_line "$(git rev-parse "$1^{commit}")" "$pr" "$(jq -r '.branch' <<<"$info")")" ||
    echo "ui: could not write the preview comment" >&2
  return 0
}

# Whether the ticket $1 (an item of ready_items) is predicted to be a UI ticket: it is labelled `ui`, or a glob of
# its Paths may reach one of the globs $2 of `ui.paths`. The diff decides at `publish`.
ui_predicted() {
  local p
  ! jq -e '.labels | index("ui")' <<<"$1" >/dev/null || return 0
  [ "$2" != "[]" ] || return 1
  while IFS= read -r p; do
    ! ready_in_zone "$2" "$p" || return 0
  done < <(jq -r '.paths[]' <<<"$1")
  return 1
}

# ---- senior-mode shots <pr> (#792) ----

SHOTS_BRANCH=senior-mode/shots

# The capturer of the project's own Playwright, else the global one (the image's). It reads the plan
# (SENIOR_MODE_SHOTS_PLAN: [{route, viewport, file}]), writes each file and results.json into SENIOR_MODE_SHOTS_DIR.
# shellcheck disable=SC2016 # JavaScript, not shell
SHOTS_PLAYWRIGHT_JS='
const fs = require("fs");
const { chromium } = require("playwright");
const plan = JSON.parse(fs.readFileSync(process.env.SENIOR_MODE_SHOTS_PLAN, "utf8"));
const base = process.env.SENIOR_MODE_SHOTS_URL.replace(/\/$/, "");
const dir = process.env.SENIOR_MODE_SHOTS_DIR;
(async () => {
  const browser = await chromium.launch();
  const results = [];
  for (const p of plan) {
    const [width, height] = p.viewport.split("x").map(Number);
    const context = await browser.newContext({ viewport: { width, height } });
    const page = await context.newPage();
    const r = { route: p.route, viewport: p.viewport, pageErrors: [], consoleErrors: 0, badRequests: [] };
    page.on("pageerror", (e) => r.pageErrors.push(String((e && e.message) || e)));
    page.on("console", (m) => { if (m.type() === "error") r.consoleErrors++; });
    page.on("response", (x) => { if (x.status() >= 400) r.badRequests.push({ url: x.url(), status: x.status() }); });
    await page.goto(base + p.route, { waitUntil: "networkidle", timeout: 30000 });
    await page.screenshot({ path: dir + "/" + p.file, fullPage: true });
    await context.close();
    results.push(r);
  }
  fs.writeFileSync(dir + "/results.json", JSON.stringify(results));
  await browser.close();
})().catch((e) => { console.error(String((e && e.message) || e).split("\n")[0]); process.exit(1); });
'

# Runs the preview command $2 of the project in the directory $1, in a slot of its own (`{{port}}` is the PORT of the
# slot's environment, .senior-mode/slot.env), and waits for it to answer on that port for $3 seconds. Sets SHOTS_URL and
# SHOTS_PID (a process group: stop it with shots_stop). On failure sets SHOTS_WHY and returns 1.
shots_serve() {
  local dir=$1 cmd=${2//\{\{port\}\}/\$PORT} wait=$3 pf waited=0 port=""
  pf=$(mktemp)
  SHOTS_LOG=$(mktemp)
  # shellcheck disable=SC2016 # the inner script is run by bash -c
  setsid bash -c 'cd "$1" && exec "$2" slot -- bash -c '"'"'echo "${PORT:-}" >"$1"; [ -n "${PORT:-}" ] || { echo "no PORT in the slot environment (.senior-mode/slot.env)" >&2; exit 97; }; exec bash -c "$2"'"'"' _ "$3" "$4"' \
    _ "$dir" "$SELF" "$pf" "$cmd" >"$SHOTS_LOG" 2>&1 </dev/null &
  SHOTS_PID=$!
  while [ "$waited" -lt "$wait" ]; do
    if ! kill -0 "$SHOTS_PID" 2>/dev/null; then
      SHOTS_WHY="preview.command exited: $(tail -n 1 "$SHOTS_LOG")"
      return 1
    fi
    [ -n "$port" ] || port=$(cat "$pf")
    if [ -n "$port" ] && curl -fsS --max-time 10 -o /dev/null "http://127.0.0.1:$port" 2>/dev/null; then
      SHOTS_URL=http://127.0.0.1:$port
      rm -f "$pf"
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  SHOTS_WHY="preview.command did not answer within $wait s"
  return 1
}

shots_stop() {
  local i
  [ -n "${SHOTS_PID:-}" ] || return 0
  kill -TERM -- "-$SHOTS_PID" 2>/dev/null || kill -TERM "$SHOTS_PID" 2>/dev/null || true
  for i in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$SHOTS_PID" 2>/dev/null || break
    sleep 0.2
  done
  kill -KILL -- "-$SHOTS_PID" 2>/dev/null || kill -KILL "$SHOTS_PID" 2>/dev/null || true
  wait "$SHOTS_PID" 2>/dev/null || true
  SHOTS_PID=""
}

# Captures the plan $4 on the base URL $2 into the directory $3 as the side $1 (before or after), through
# SENIOR_MODE_SHOTS_CMD when set (the test seam), else Playwright. Prints the reason and returns 1 when it fails.
shots_capture() {
  local side=$1 url=$2 dir=$3 plan=$4 rc=0 err f nodepath
  mkdir -p "$dir"
  jq -c --arg s "$side" '[.[] | .file = "\(.name)-\($s).png"]' "$plan" >"$dir/plan.json"
  err=$(mktemp)
  if [ -n "${SENIOR_MODE_SHOTS_CMD:-}" ]; then
    SENIOR_MODE_SHOTS_URL=$url SENIOR_MODE_SHOTS_DIR=$dir SENIOR_MODE_SHOTS_PLAN=$dir/plan.json SENIOR_MODE_SHOTS_SIDE=$side \
      bash -c "$SENIOR_MODE_SHOTS_CMD" >/dev/null 2>"$err" </dev/null || rc=$?
  else
    command -v node >/dev/null 2>&1 || { echo "no capturer: set SENIOR_MODE_SHOTS_CMD or install node and playwright"; return 1; }
    nodepath=$(npm root -g 2>/dev/null) || nodepath=""
    NODE_PATH=${NODE_PATH:-$nodepath} SENIOR_MODE_SHOTS_URL=$url SENIOR_MODE_SHOTS_DIR=$dir SENIOR_MODE_SHOTS_PLAN=$dir/plan.json \
      SENIOR_MODE_SHOTS_SIDE=$side node -e "$SHOTS_PLAYWRIGHT_JS" >/dev/null 2>"$err" </dev/null || rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    echo "the $side capture failed ($rc): $(grep -v '^$' "$err" | tail -n 1 | cut -c1-200)"
    return 1
  fi
  while IFS= read -r f; do
    [ -s "$dir/$f" ] || { echo "the $side capture wrote no $f"; return 1; }
  done < <(jq -r '.[].file' "$dir/plan.json")
  [ -f "$dir/results.json" ] || echo '[]' >"$dir/results.json"
}

# Shrinks the image $1 under $2 kilobytes with magick or convert; fails when neither is there or it stays too big.
shots_shrink() {
  local f=$1 max=$2 tool i
  for tool in magick convert; do command -v "$tool" >/dev/null 2>&1 && break || tool=""; done
  [ -n "$tool" ] || return 1
  for i in 1 2 3 4 5; do
    [ "$(($(wc -c <"$f") / 1024))" -gt "$max" ] || return 0
    "$tool" "$f" -resize 75% "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f" || { rm -f "$f.tmp"; return 1; }
  done
  [ "$(($(wc -c <"$f") / 1024))" -le "$max" ]
}

# The commit that puts the png files of the directory $2 (none when it is empty or absent) under pr-<$1> of the
# orphan branch senior-mode/shots, replacing what pr-<$1> held, pushed to origin. Plumbing only: no checkout, the
# index is a temporary file. Prints the commit, or nothing when the branch already says that; fails with the reason.
shots_update() {
  (
    cd "$(git rev-parse --show-toplevel)" || exit 1
    idx=$(mktemp -u "${TMPDIR:-/tmp}/shots-index.XXXXXX")
    trap 'rm -f "$idx"' EXIT
    export GIT_INDEX_FILE=$idx
    for attempt in 1 2; do
      git_bound fetch -q origin "+refs/heads/$SHOTS_BRANCH:refs/remotes/origin/$SHOTS_BRANCH" 2>/dev/null || true
      tip=$(git rev-parse -q --verify "refs/remotes/origin/$SHOTS_BRANCH^{commit}") || tip=""
      rm -f "$idx"
      if [ -n "$tip" ]; then
        git read-tree "$tip"
        git ls-files "pr-$1/" | while IFS= read -r f; do git update-index --force-remove -- "$f"; done
      fi
      if [ -n "${2:-}" ]; then
        for f in "$2"/*.png; do
          [ -f "$f" ] || continue
          git update-index --add --cacheinfo "100644,$(git hash-object -w "$f"),pr-$1/$(basename "$f")"
        done
      fi
      tree=$(git write-tree)
      if [ -n "$tip" ] && [ "$tree" = "$(git rev-parse "$tip^{tree}")" ]; then exit 0; fi
      if [ -z "$tip" ] && [ -z "$(git ls-tree -r "$tree" | head -n 1)" ]; then exit 0; fi
      name=()
      [ -n "$(git config user.name)" ] || name=(-c user.name=senior-mode -c user.email=senior-mode@users.noreply.github.com)
      commit=$(git "${name[@]}" commit-tree "$tree" ${tip:+-p "$tip"} -m "shots: pr-$1")
      if err=$(git_bound push -q origin "$commit:refs/heads/$SHOTS_BRANCH" 2>&1); then
        echo "$commit"
        exit 0
      fi
    done
    echo "could not push $SHOTS_BRANCH: $(head -n 1 <<<"${err:-}")" >&2
    exit 1
  )
}

# `shots <pr>` fails with the reason $2 after saying so in the comment of the pull request $1 (head commit $3).
shots_fail() {
  preview_comment "$3" "$1" "No screenshots: $2" || true
  echo "shots: $2" >&2
  return 1
}

# The route $1 as a file name: /about/team -> about-team, / -> index.
shots_name() {
  local n
  n=$(sed 's#^/*##; s#[^A-Za-z0-9]\{1,\}#-#g; s#^-##; s#-$##' <<<"$1")
  printf '%s\n' "${n:-index}"
}

# senior-mode shots <pr> (#792): before and after screenshots of the routes of `preview.routes` at the viewports
# of `preview.viewports`, in <git common dir>/senior-mode/shots/pr-<n> with shots.json (per route, viewport and side:
# pageErrors, consoleErrors, badRequests), then pushed to senior-mode/shots and shown in the preview comment.
shots() {
  [ $# -eq 1 ] && [[ $1 =~ ^[1-9][0-9]*$ ]] || usage
  local pr=$1 slug info sha branch base cfg routes viewports maxkb public cmd baseurl wait common out plan line="" url="" mb wt="" why
  local private commit="" f table="" row side rc r v n results=()
  slug=$(repo_slug)
  info=$(gh_retry pr view "$pr" --repo "$slug" --json headRefOid,headRefName,baseRefName) || die "cannot read pull request #$pr"
  sha=$(jq -r .headRefOid <<<"$info") branch=$(jq -r .headRefName <<<"$info") base=$(jq -r .baseRefName <<<"$info")
  cfg=$(config_effective) || die "invalid configuration"
  routes=$(jq -c '.preview.routes // ["/"]' <<<"$cfg")
  viewports=$(jq -c '.preview.viewports // ["390x844","1280x800"]' <<<"$cfg")
  maxkb=$(jq -r '.preview.maxKB // 400' <<<"$cfg")
  public=$(jq -r '.preview.public // false' <<<"$cfg")
  cmd=$(jq -r '.preview.command // empty' <<<"$cfg")
  baseurl=$(jq -r '.preview.baseUrl // empty' <<<"$cfg")
  wait=$(jq -r '.preview.waitSeconds // 300' <<<"$cfg")
  common=$(git rev-parse --path-format=absolute --git-common-dir) || die "not inside a git repository"
  out=$common/senior-mode/shots/pr-$pr
  rm -rf "$out"
  mkdir -p "$out"
  plan=$out/.plan.json
  # The plan: one entry per route and viewport, its file name without the side.
  : >"$plan.lines"
  while IFS= read -r r; do
    while IFS= read -r v; do
      jq -nc --arg r "$r" --arg v "$v" --arg n "$(shots_name "$r")-$v" '{route: $r, viewport: $v, name: $n}' >>"$plan.lines"
    done < <(jq -r '.[]' <<<"$viewports")
  done < <(jq -r '.[]' <<<"$routes")
  jq -sc . "$plan.lines" >"$plan"
  rm -f "$plan.lines"

  # After: the preview URL, else preview.command on the head.
  line=$(preview_line "$sha" "$pr" "$branch" "$([ -n "$cmd" ] && echo 0 || echo "$wait")")
  if [[ $line == "Preview: "* ]]; then
    url=${line#Preview: }
  elif [ -n "$cmd" ]; then
    git_bound fetch -q origin "$branch" 2>/dev/null || true
    wt=$(mktemp -d)
    git worktree add -q --detach "$wt/tree" "$sha" 2>/dev/null || { rm -rf "$wt"; shots_fail "$pr" "the head $sha is not in this clone" "$sha"; return; }
    shots_serve "$wt/tree" "$cmd" "$wait" && url=$SHOTS_URL
    [ -n "$url" ] || { shots_stop; git worktree remove --force "$wt/tree"; rm -rf "$wt"; shots_fail "$pr" "$SHOTS_WHY" "$sha"; return; }
    line="Preview: not published (served from preview.command)"
  else
    shots_fail "$pr" "no preview URL and no preview.command (${line#No preview: })" "$sha"
    return
  fi
  rc=0
  why=$(shots_capture after "$url" "$out/.after" "$plan") || rc=$?
  if [ -n "${wt:-}" ]; then
    shots_stop
    git worktree remove --force "$wt/tree" 2>/dev/null || true
    rm -rf "$wt"
    wt=""
  fi
  [ "$rc" -eq 0 ] || { shots_fail "$pr" "$why" "$sha"; return; }

  # Before: preview.baseUrl, else preview.command on the merge base.
  url=""
  if [ -n "$baseurl" ]; then
    url=$baseurl
  elif [ -n "$cmd" ]; then
    git_bound fetch -q origin "$base" 2>/dev/null || true
    mb=$(git merge-base "$sha" "origin/$base" 2>/dev/null) || mb=""
    if [ -n "$mb" ]; then
      wt=$(mktemp -d)
      git worktree add -q --detach "$wt/tree" "$mb" 2>/dev/null || mb=""
    fi
    if [ -n "$mb" ]; then
      shots_serve "$wt/tree" "$cmd" "$wait" && url=$SHOTS_URL || { shots_stop; git worktree remove --force "$wt/tree"; rm -rf "$wt"; shots_fail "$pr" "before: $SHOTS_WHY" "$sha"; return; }
    fi
  fi
  if [ -n "$url" ]; then
    rc=0
    why=$(shots_capture before "$url" "$out/.before" "$plan") || rc=$?
    if [ -n "${wt:-}" ]; then
      shots_stop
      git worktree remove --force "$wt/tree" 2>/dev/null || true
      rm -rf "$wt"
    fi
    [ "$rc" -eq 0 ] || { shots_fail "$pr" "$why" "$sha"; return; }
  fi

  # The images, and what was seen on each page.
  results=()
  for side in before after; do
    [ -d "$out/.$side" ] || continue
    mv "$out/.$side"/*.png "$out/"
    results+=("$(jq -c --arg s "$side" 'map(. + {side: $s})' "$out/.$side/results.json")")
  done
  printf '%s\n' "${results[@]}" | jq -sc 'add' >"$out/shots.json"
  rm -rf "$out/.before" "$out/.after"
  mkdir -p "$out/.push"
  for f in "$out"/*.png; do
    if [ "$(($(wc -c <"$f") / 1024))" -gt "$maxkb" ] && ! shots_shrink "$f" "$maxkb"; then
      echo "too large: $(basename "$f")" >>"$out/.toolarge"
    else
      cp "$f" "$out/.push/"
    fi
  done
  [ ! -f "$out/.toolarge" ] || sed -i 's/^too large: //' "$out/.toolarge"

  # Publishing: a public repository gets nothing unless preview.public.
  private=$(gh_retry api "repos/$slug" --jq '.private' 2>/dev/null) || private=""
  if [ "$private" != true ] && [ "$public" != true ]; then
    shots_comment_set "$sha" "$pr" "$line" "screenshots not published (public repository, preview.public is false); the files are in $out"
    echo "shots: $out (not pushed: public repository)"
    return 0
  fi
  commit=$(shots_update "$pr" "$out/.push" 2>"$out/.pusherr") || { shots_fail "$pr" "$(cat "$out/.pusherr" 2>/dev/null)" "$sha"; return; }
  [ -n "$commit" ] || commit=$(git rev-parse -q --verify "refs/remotes/origin/$SHOTS_BRANCH" 2>/dev/null) || commit=""
  table=$'| Route | Viewport | Before | After |\n| --- | --- | --- | --- |'
  while IFS=$'\t' read -r r v n; do
    row="| \`$r\` | $v |"
    for side in before after; do
      f=$n-$side.png
      if [ ! -f "$out/$f" ]; then row+=" none |"
      elif grep -qx "$f" "$out/.toolarge" 2>/dev/null; then row+=" too large |"
      else row+=" ![$side](https://github.com/$slug/blob/$commit/pr-$pr/$f?raw=true) |"
      fi
    done
    table+=$'\n'"$row"
  done < <(jq -r '.[] | [.route, .viewport, .name] | @tsv' "$plan")
  shots_comment_set "$sha" "$pr" "$line" "$table"
  echo "shots: $out ($(jq length "$out/shots.json") captures, pushed to $SHOTS_BRANCH)"
}

# The preview comment of the pull request $2: the preview line $3, then the screenshots part $4.
shots_comment_set() { # sha pr line body
  preview_comment "$1" "$2" "$3"$'\n\n'"$4" || echo "shots: could not write the preview comment" >&2
}

# Called by `clean`, with the pull requests (JSON) it read: removes pr-<n> from senior-mode/shots seven days after
# its pull request closed (merged or not). clean_act reports it and honours --dry-run.
shots_clean() {
  local prs=$1 cutoff n at
  cutoff=$(iso_time $(($(date +%s) - 7 * 86400)))
  git_bound fetch -q origin "+refs/heads/$SHOTS_BRANCH:refs/remotes/origin/$SHOTS_BRANCH" 2>/dev/null || return 0
  git rev-parse -q --verify "refs/remotes/origin/$SHOTS_BRANCH^{commit}" >/dev/null || return 0
  while IFS= read -r n; do
    at=$(jq -r --argjson n "$n" '[.[] | select(.number == $n and .state != "OPEN")][0] | .mergedAt // .closedAt // empty' <<<"$prs")
    { [ -n "$at" ] && [[ $at < $cutoff ]]; } || continue
    clean_act "screenshots pr-$n (pull request closed ${at%%T*})" shots_update "$n"
  done < <(git ls-tree --full-tree --name-only "refs/remotes/origin/$SHOTS_BRANCH" | sed -n 's/^pr-\([0-9][0-9]*\)$/\1/p')
}
