# shellcheck shell=bash
# Once a day (notify.digest, default true) `status --since 24h` is posted as a Project status update (#155). The
# time of the attempt is kept in <serve dir>/digest, so a failure waits for the next day and a restart does not
# post twice.
serve_digest() {
  local now last body
  [ "$(config_get notify.digest)" = true ] || return 0
  now=$(serve_now)
  last=$(state_num "$SERVE_DIR/digest")
  [ $((now - last)) -ge 86400 ] || return 0
  state_put "$SERVE_DIR/digest" "$now"
  if body=$("$SELF" status --since 24h 2>/dev/null) && [ -n "$body" ] && project_post_update "$body"; then
    echo "serve: daily digest posted as a Project status update"
  else
    echo "serve: could not post the daily digest; trying again tomorrow" >&2
  fi
}

# Dependency freshness (#497, spec 471 section 8). Once a week, `npm outdated --json` of a project with a package.json
# gives the majors available; each becomes one `chore(deps): <package> <from> to <to>` ticket, unless an open issue
# has that title. The time of the pass is kept in <serve dir>/deps-at.
serve_deps() {
  local now last root out slug open line title body
  now=$(serve_now)
  last=$(cat "$SERVE_DIR/deps-at" 2>/dev/null || true)
  [[ $last =~ ^[0-9]+$ ]] && [ $((now - last)) -lt 604800 ] && return 0
  root=$(git rev-parse --show-toplevel 2>/dev/null) && [ -f "$root/package.json" ] || return 0
  state_put "$SERVE_DIR/deps-at" "$now"
  out=$(cd "$root" && npm outdated --json 2>/dev/null) || true
  slug=$(repo_slug)
  open=$(gh_retry issue list --repo "$slug" --state open --limit 500 --json title 2>/dev/null) || open='[]'
  while IFS= read -r title; do
    [ -n "$title" ] || continue
    jq -e --arg t "$title" 'any(.[]; .title == $t)' <<<"$open" >/dev/null && continue
    body=$(mktemp)
    printf '## Context\n\nA new major is available.\n\n## Acceptance criteria\n\n- Given the major is available, when the project is moved to it, then check passes.\n' >"$body"
    "$SELF" issue create --title "$title" --body-file "$body" --size S --priority "P2 later" --type chore </dev/null >/dev/null ||
      echo "serve: dependency ticket not filed: $title" >&2
    rm -f "$body"
  done < <(jq -r 'to_entries[] | select((.value.current // "") != "" and (.value.latest // "") != "" and
    ((.value.latest | split(".")[0]) != (.value.current | split(".")[0])))
    | "chore(deps): \(.key) \(.value.current) to \(.value.latest)"' <<<"${out:-{\}}" 2>/dev/null)
}

# The commits of the base branch $1 after the day $2 (YYYY-MM-DD) that touch a file matched by the globs $3 (a JSON list).
serve_note_churn() {
  local files matched
  files=$(git -c core.quotePath=false log --since="$(date -u -d "$2 23:59:59" +%s)" --name-only --no-renames --format= "$1" | sort -u)
  matched=$(protected_match "$3" <<<"$files")
  [ -n "$matched" ] || { echo 0; return 0; }
  git -c core.quotePath=false log --since="$(date -u -d "$2 23:59:59" +%s)" --name-only --no-renames --format=@%H "$1" |
    awk -v m="$matched" 'BEGIN { n = split(m, a, "\n"); for (i = 1; i <= n; i++) set[a[i]] = 1 }
      /^@/ { if (hit) c++; hit = 0; next } NF && ($0 in set) { hit = 1 } END { if (hit) c++; print c + 0 }'
}

# Files one gardening ticket (#357): $1 its title, $2 its body, $3 its Paths, $4 the maintenance epic, $5 the
# gardening label. Size S, priority P2, filed as an agent's ticket, so `ready` takes it. Fails when it was not filed.
serve_garden_file() {
  local title=$1 text=$2 paths=$3 epic=$4 gl=$5 body out n
  body=$(mktemp)
  printf '%s' "$text" >"$body"
  if out=$(SENIOR_MODE_RUN=1 "$SELF" issue create --title "$title" --body-file "$body" --size S --priority "P2 later" --type chore \
    --paths "$paths" --parent "$epic" </dev/null) && n=$(sed -nE '1s/^#([0-9]+) .*/\1/p' <<<"$out") && [ -n "$n" ]; then
    gh_retry api "repos/$RUN_SLUG/issues/$n/labels" -f "labels[]=$gl" >/dev/null || echo "serve: could not label #$n $gl" >&2
    echo "serve: gardening ticket #$n filed: $title"
    rm -f "$body"
    return 0
  fi
  echo "serve: gardening ticket not filed: $title" >&2
  rm -f "$body"
  return 1
}

# Does the generated block of docs/architecture.md on the base branch $1 differ from the map of its tree (#347)? The map is read
# from a detached worktree of the base branch, as `senior-mode architecture --check` would; nothing without the file or its block.
serve_architecture_drift() {
  local tmp warn
  git show "$1:docs/architecture.md" 2>/dev/null | grep -qE "$ARCH_OPEN_RE" || return 1
  tmp=$(mktemp -d)
  if git -c core.hooksPath=/dev/null worktree add -q --detach "$tmp/tree" "$1" >/dev/null 2>&1; then
    warn=$(cd "$tmp/tree" && "$SELF" architecture --check 2>/dev/null) || warn=""
    git worktree remove --force "$tmp/tree" >/dev/null 2>&1 || true
  else
    warn=""
    echo "serve: cannot read the base branch to compare docs/architecture.md; no architecture gardening" >&2
  fi
  rm -rf "$tmp"
  git worktree prune >/dev/null 2>&1 || true
  [ -n "$warn" ]
}

# Gardening of the knowledge notes (#357, spec 325 section 5). Once a day, each note of docs/knowledge on the base branch
# with more than knowledge.churnCommits commits on its `paths` since `verified`, or verified more than knowledge.staleMonths
# ago, gets one S ticket `chore(knowledge): re-verify <slug>`, labelled gardening, under the open epic labelled maintenance,
# with the note as Paths. None is filed for a note whose title is open already, once maintenance.maxOpen gardening tickets
# are open, nor without the epic (`setup repo --knowledge` creates it). The same pass files `chore(architecture): regenerate
# docs/architecture.md` (#347, spec 325 section 6.4) when the generated block of docs/architecture.md on the base branch is out
# of date, for the docs skill, which runs `senior-mode architecture --write`; it counts in the same budget and dedup.
# The time of the pass is kept in <serve dir>/gardening-at.
serve_gardening() {
  local now last base months churn max cutoff issues epic gl ml open note slug title raw verified globs why n body fm notes=false arch=false
  now=$(serve_now)
  last=$(cat "$SERVE_DIR/gardening-at" 2>/dev/null || true)
  [[ $last =~ ^[0-9]+$ ]] && [ $((now - last)) -lt 86400 ] && return 0
  base=$RUN_BASE
  git rev-parse -q --verify "$base^{commit}" >/dev/null 2>&1 || return 0
  ! git cat-file -e "$base:docs/knowledge" 2>/dev/null || notes=true
  serve_architecture_drift "$base" && arch=true
  [ "$notes" = true ] || [ "$arch" = true ] || return 0
  state_put "$SERVE_DIR/gardening-at" "$now"
  months=$(config_get knowledge.staleMonths)
  churn=$(config_get knowledge.churnCommits)
  max=$(config_get maintenance.maxOpen)
  [[ $months =~ ^[1-9][0-9]*$ && $churn =~ ^[1-9][0-9]*$ && $max =~ ^[1-9][0-9]*$ ]] || {
    echo "serve: knowledge.staleMonths, knowledge.churnCommits and maintenance.maxOpen must be positive whole numbers; no gardening" >&2
    return 0
  }
  cutoff=$(date -u -d "$(date -u -d "@$now" +%F) $months months ago" +%F)
  issues=$(gh_retry issue list --repo "$RUN_SLUG" --state open --limit 1000 --json number,title,labels 2>/dev/null) || {
    echo "serve: cannot list the issues; no gardening until tomorrow" >&2
    return 0
  }
  gl=$(workflow_label "" gardening)
  ml=$(workflow_label "" maintenance)
  epic=$(jq -r --arg l "$ml" 'first(.[] | select(any(.labels[]?; .name == $l)) | .number) // empty' <<<"$issues")
  [ -n "$epic" ] || {
    echo "serve: no open epic labelled $ml; no gardening (senior-mode setup repo --knowledge creates it)" >&2
    return 0
  }
  open=$(jq -r --arg l "$gl" '[.[] | select(any(.labels[]?; .name == $l))] | length' <<<"$issues")
  title="chore(architecture): regenerate docs/architecture.md"
  if [ "$arch" = true ] && [ "$open" -lt "$max" ] && ! jq -e --arg t "$title" 'any(.[]; .title == $t)' <<<"$issues" >/dev/null; then
    body=$(printf '## Context\n\nThe generated block of `docs/architecture.md` is out of date: the tree, the architecture rules or the ADR list changed since it was written (`senior-mode architecture --check` warns).\n\n## Acceptance criteria\n\n- Given `docs/architecture.md` out of date, when the `docs` skill runs `senior-mode architecture --write`, then `senior-mode architecture --check` prints no warning and only the block between the markers changed, in one pull request.\n')
    serve_garden_file "$title" "$body" docs/architecture.md "$epic" "$gl" && open=$((open + 1))
  fi
  [ "$notes" = true ] || return 0
  while IFS= read -r note; do
    [ "$open" -lt "$max" ] || break
    slug=$(basename "$note" .md)
    title="chore(knowledge): re-verify $slug"
    jq -e --arg t "$title" 'any(.[]; .title == $t)' <<<"$issues" >/dev/null && continue
    fm=$(git show "$base:$note" 2>/dev/null | awk 'NR == 1 && $0 != "---" { exit } NR > 1 && $0 == "---" { exit } NR > 1 { print }')
    verified=$(sed -n 's/^verified:[[:space:]]*//p' <<<"$fm" | head -n 1 | tr -d "\"'\r")
    [[ $verified =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && [ "$(date -u -d "$verified" +%F 2>/dev/null)" = "$verified" ] || continue
    raw=$(sed -n 's/^paths:[[:space:]]*//p' <<<"$fm" | head -n 1 | tr -d '\r')
    globs=$(jq -c 'select(type == "array" and length > 0 and all(.[]; type == "string"))' <<<"$raw" 2>/dev/null) && [ -n "$globs" ] || continue
    if [[ $verified < $cutoff ]]; then
      why="was last verified on $verified, more than $months months ago (\`knowledge.staleMonths\`)"
    else
      n=$(serve_note_churn "$base" "$verified" "$globs")
      [ "${n:-0}" -gt "$churn" ] || continue
      why="has $n commits on its \`paths\` since it was verified on $verified (more than \`knowledge.churnCommits\`, $churn)"
    fi
    body=$(printf '## Context\n\nThe knowledge note `%s` %s. A note is true only when someone checked it against the code.\n\n## Acceptance criteria\n\n- Given the note `%s`, when the session re-reads it against its paths %s, then it bumps `verified` to today, edits the note to match the code, or deletes it, in one pull request.\n' \
      "$note" "$why" "$note" "$(jq -r 'join(", ")' <<<"$globs")")
    serve_garden_file "$title" "$body" "$note" "$epic" "$gl" && open=$((open + 1))
  done < <(git ls-tree --name-only "$base" docs/knowledge/ | grep -E '^docs/knowledge/[^/]+\.md$' | LC_ALL=C sort)
}

# The digest of the day through the webhook (#309). Once notify.digestAt (HH:MM, the local time of the daemon) has
# passed and none was sent today, one JSON POST {event: "digest", repo, number: null, url: null, reason: <text>,
# digest: {...}} to the notify webhook with, over the last 24 hours, the pull requests merged, the tickets that wait
# for a human, the tokens and their estimated cost (#299) and the board (work in progress, drift). Nothing is sent
# when nothing was merged or closed and no token was used, nor without a webhook. The day of the attempt is kept in
# <serve dir>/digest-at: a failure waits for tomorrow and a restart does not send twice.
# shellcheck disable=SC2016 # jq programs, not shell
serve_digest_at() {
  local at hook now day st usage digest text
  at=$(config_get notify.digestAt)
  hook=${SENIOR_MODE_NOTIFY_WEBHOOK:-$(config_get notify.webhook)}
  [ -n "$at" ] && [ -n "$hook" ] || return 0
  now=$(serve_now)
  [[ ! $(date -d "@$now" +%H:%M 2>/dev/null || date -r "$now" +%H:%M) < $at ]] || return 0
  day=$(date -d "@$now" +%F 2>/dev/null || date -r "$now" +%F)
  [ "$(cat "$SERVE_DIR/digest-at" 2>/dev/null)" != "$day" ] || return 0
  state_put "$SERVE_DIR/digest-at" "$day"
  if ! st=$("$SELF" status --json --since 24h 2>/dev/null) || ! usage=$(retro_usage "$SERVE_COMMON" "$(iso_time $((now - 86400)))" ""); then
    echo "serve: could not build the daily digest; trying again tomorrow" >&2
    return 0
  fi
  digest=$(jq -c --argjson u "$usage" '{merged: .mergedPullRequests, done: [.done[] | {number, title}],
    waiting: [.waiting[] | {kind, number, title, why}],
    tokens: ($u.total | {input, output, cacheRead, cacheWrite: (.cacheWrite5m + .cacheWrite1h), usd, unpriced}),
    board: {inProgress: (.inProgress | length), wip: .wip.limit, inReview: (.inReview | length), blocked: (.blocked | length),
      drift: [.drift[] | {number, title, why}]}}' <<<"$st") || {
    echo "serve: could not build the daily digest; trying again tomorrow" >&2
    return 0
  }
  jq -e '.merged > 0 or (.done | length) > 0 or (.tokens.input + .tokens.output + .tokens.cacheRead + .tokens.cacheWrite) > 0' <<<"$digest" >/dev/null ||
    return 0
  text=$(jq -r 'def l($a): if ($a | length) == 0 then "none" else ($a | map("#\(.number) \(.title)") | join(", ")) end;
    "Daily digest of senior-mode, last 24 hours",
    "Merged pull requests: \(.merged)" + (if (.done | length) > 0 then " · done: \(l(.done))" else "" end),
    "Needs a human: \(if (.waiting | length) == 0 then "nothing" else (.waiting | map("\(.kind) #\(.number) \(.title): \(.why)") | join("; ")) end)",
    "Token cost: \(if .tokens.usd == null then "no price" else "$\(.tokens.usd * 100 | round / 100)" end) (\(.tokens.input + .tokens.output + .tokens.cacheRead + .tokens.cacheWrite) tokens)",
    "Board: \(.board.inProgress) in progress (limit \(.board.wip)), \(.board.inReview) in review, \(.board.blocked) blocked, drift: \(l(.board.drift))"' <<<"$digest")
  curl -fsS -m 10 -X POST -H 'Content-Type: application/json' "$hook" -d "$(jq -nc --arg r "$RUN_SLUG" --arg t "$text" --argjson d "$digest" \
    '{event: "digest", repo: $r, number: null, url: null, reason: $t, digest: $d}')" >/dev/null ||
    echo "notify: the webhook did not answer (digest)" >&2
}

# Run by state_update: the questions of the file $1 as one JSON array, the file emptied (an alert added meanwhile is not lost).
serve_questions_take() {
  jq -sc 'map(.reason |= (gsub("[[:cntrl:]]"; " ") | .[:300]))' "$1" && state_write "$1" </dev/null
}

# The questions that serve queued (notify, #308) go out as one notification, once the oldest has waited
# notify.batchMinutes (default 60; 0 sends at each poll): at most one per window, whatever the number of questions. The
# text is plain, control characters stripped and 300 characters at most (a title can come from an outsider). The label and
# the comment of each question were already on GitHub; only the webhook waits. The queue is emptied even without a webhook.
serve_questions() {
  local file=$SERVE_DIR/questions now minutes first items count text
  [ -s "$file" ] || return 0
  now=$(serve_now)
  minutes=$(serve_int notify.batchMinutes 0)
  first=$(jq -rs 'map(.at) | min' "$file") || return 0
  [ $((now - first)) -ge $((minutes * 60)) ] || return 0
  items=$(state_update serve_questions_take "$file") || return 0
  count=$(jq 'length' <<<"$items")
  text=$(jq -r 'map("#\(.number) \(.reason)") | join("; ") | gsub("[[:cntrl:]]"; " ")' <<<"$items")
  text="$count decision$([ "$count" = 1 ] || echo s) wait for you: $text"
  notify_post decisions "" "" "${text:0:300}" "$(jq -nc --argjson i "$items" '{count: ($i | length), items: $i}')"
}
