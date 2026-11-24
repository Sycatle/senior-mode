# shellcheck shell=bash
# Detecting the workflow of an existing project (spec 409 §2 and §8, ADR 0022): `setup repo` reads the repository and
# GitHub, never changes them, and writes `workflow`, `adopt.kind` and `ci.mode existing` into the config. Without an
# origin remote or gh only the repository is read.
#
# The state of one detection, set by workflow_detect:
#   WF_JSON      the detected `workflow` object
#   WF_ROWS      one line per finding: path, JSON value, evidence, status (new, assumed or kept), tab separated
#   WF_UNMAPPED  what senior-mode cannot follow, with what it does instead
#   WF_ASKS      the questions the CLI cannot ask: it takes the recommended answer and marks it assumed
#   WF_ND        true when something differs from senior-mode's defaults (only then is `workflow` written)
#   WF_ADOPT     evergreen or legacy
#   WF_CI_MODE   existing when the project's CI runs on pull requests

wf_put() { # path json evidence [assumed]
  WF_JSON=$(jq -c --arg p "$1" --argjson v "$2" 'setpath($p | split("."); $v)' <<<"$WF_JSON")
  WF_ROWS+=("$1"$'\t'"$2"$'\t'"$3"$'\t'"${4:-new}")
}

wf_ask() { # question recommended other
  WF_ASKS+=("$1 (recommended: $2; or: $3)")
}

wf_days_ago() {
  date -u -d "$1 days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-"$1"d +%Y-%m-%dT%H:%M:%SZ
}

# Percent of the lines of stdin matching the pattern $1 (extended regex), as an integer; 0 for no line.
wf_share() {
  local lines n m
  lines=$(cat)
  n=$(grep -c '' <<<"$lines" || true)
  [ -n "$lines" ] || { echo 0; return; }
  m=$(grep -cE "$1" <<<"$lines" || true)
  echo $((m * 100 / n))
}

# The merged pull requests (last 50) as JSON, [] without gh.
wf_load_prs() {
  WF_PRS='[]'
  [ -z "$WF_SLUG" ] || WF_PRS=$(gh_retry pr list --repo "$WF_SLUG" --state merged --limit 50 \
    --json number,title,body,baseRefName,headRefName,mergedAt 2>/dev/null) || WF_PRS='[]'
  jq -e 'type == "array"' <<<"$WF_PRS" >/dev/null 2>&1 || WF_PRS='[]'
}

# §2.1: the branch model.
wf_model() {
  local def b r age total top topn share second secn last lines long="" cand="" rel hot n
  def=${WF_REF#origin/}
  for b in dev develop development staging; do
    r=""
    git -C "$WF_ROOT" rev-parse -q --verify "origin/$b^{commit}" >/dev/null 2>&1 && r=origin/$b
    [ -n "$r" ] || { git -C "$WF_ROOT" rev-parse -q --verify "refs/heads/$b^{commit}" >/dev/null 2>&1 && r=$b; }
    [ -n "$r" ] || continue
    age=$(git -C "$WF_ROOT" log -1 --format=%ct "$r")
    long+="$b "
    # A live branch the default branch lacks: the candidate when no pull request says otherwise.
    if [ $(($(date +%s) - age)) -lt $((90 * 86400)) ] && ! git -C "$WF_ROOT" merge-base --is-ancestor "$r" "$WF_REF" 2>/dev/null; then
      [ -n "$cand" ] || cand=$b
    fi
  done
  # The pull requests of the main flow: those aimed at a release line are counted apart.
  lines=$(jq -r '[.[] | select(.baseRefName | test("^(release|hotfix|support)/") | not)]
    | group_by(.baseRefName) | map({b: .[0].baseRefName, n: length, last: (map(.mergedAt) | max)})
    | sort_by(-.n, .last) | .[] | "\(.b)\t\(.n)\t\(.last)"' <<<"$WF_PRS")
  total=$(jq -r '[.[] | select(.baseRefName | test("^(release|hotfix|support)/") | not)] | length' <<<"$WF_PRS")
  rel=$(jq -r '[.[] | select(.baseRefName | test("^release/"))] | length' <<<"$WF_PRS")
  # The model: integration branch (empty for trunk), and why.
  local model=trunk int=$def why="no merged pull request to read, no live integration branch"
  if [ "$total" -gt 0 ]; then
    IFS=$'\t' read -r top topn _ <<<"$(sed -n 1p <<<"$lines")"
    share=$((topn * 100 / total))
    IFS=$'\t' read -r second secn last <<<"$(sed -n 2p <<<"$lines")"
    secn=${secn:-0}
    if [ "$share" -ge 80 ]; then
      int=$top
      why="$topn of $total merged pull requests target $top"
    elif [ $((secn * 100 / total)) -gt 30 ] && [ "$share" -gt 30 ]; then
      # Two bases, each above 30%: the one merged last is the recommended answer.
      local lastb other
      lastb=$(sort -t$'\t' -k3,3r <<<"$(sed -n '1,2p' <<<"$lines")" | head -n 1 | cut -d$'\t' -f1)
      other=$top
      [ "$lastb" != "$top" ] || other=$second
      int=$lastb
      why="$topn of $total merged pull requests target $top, $secn target $second; $lastb was merged last"
      wf_ask "Which branch do tickets start from and merge into: $lastb or $other?" "$lastb" "$other"
      WF_ASSUME_INT=1
    else
      int=$top
      why="$topn of $total merged pull requests target $top (no base reaches 80%)"
    fi
  elif [ -n "$cand" ]; then
    int=$cand
    why="branch $cand has a commit in the last 90 days and is not merged into $def; no merged pull request to read"
  fi
  model=trunk
  [ "$int" = "$def" ] || model=integration
  # A live integration branch idle for 90 days: asked.
  if [ "$model" = integration ]; then
    r=origin/$int
    git -C "$WF_ROOT" rev-parse -q --verify "$r^{commit}" >/dev/null 2>&1 || r=$int
    if age=$(git -C "$WF_ROOT" log -1 --format=%ct "$r" 2>/dev/null) && [ $(($(date +%s) - age)) -ge $((90 * 86400)) ]; then
      wf_ask "Branch $int has had no commit for 90 days: still the integration branch?" "$int" "$def"
      WF_ASSUME_INT=1
    fi
  fi
  rel=$(( rel + $(git -C "$WF_ROOT" for-each-ref --format='%(refname:short)' 'refs/remotes/origin/release/*' | grep -c '' || true) ))
  hot=$(( $(jq -r '[.[] | select(.headRefName | startswith("hotfix/"))] | length' <<<"$WF_PRS") +
    $(git -C "$WF_ROOT" for-each-ref --format='%(refname:short)' 'refs/remotes/origin/hotfix/*' | grep -c '' || true) ))
  if [ "$model" = integration ] && { [ "$rel" -gt 0 ] || [ "$hot" -gt 0 ]; }; then
    model=gitflow
    why="$why; ${rel} release and ${hot} hotfix lines"
  elif [ "$model" = trunk ] && [ "$rel" -gt 0 ]; then
    model=release-branches
    why="$why; $rel release lines"
  fi
  n=new
  [ -z "${WF_ASSUME_INT:-}" ] || n=assumed
  wf_put model "\"$model\"" "$why" "$n"
  wf_put base "\"$def\"" "the default branch of the repository"
  wf_put integration "\"$int\"" "$why" "$n"
  [ "$model" = trunk ] || WF_ND=true
  if [ "$rel" -gt 0 ] || [ "$hot" -gt 0 ]; then
    [ "$rel" -eq 0 ] || wf_put release.branches '["release/*"]' "$rel release branches or pull requests"
    [ "$hot" -eq 0 ] || wf_put release.hotfix '"hotfix/*"' "$hot hotfix branches or pull requests"
    WF_ND=true
  fi
}

# The commitlint configuration of the project: prints a JSON {types, scopes}, fails when there is none.
wf_commitlint() {
  local f text="" src=""
  for f in commitlint.config.js commitlint.config.cjs commitlint.config.mjs commitlint.config.ts .commitlintrc \
    .commitlintrc.json .commitlintrc.yml .commitlintrc.yaml .commitlintrc.js .commitlintrc.cjs .commitlintrc.ts; do
    [ -f "$WF_ROOT/$f" ] || continue
    text=$(tr '\n' ' ' <"$WF_ROOT/$f") src=$f
    break
  done
  if [ -z "$src" ] && [ -f "$WF_ROOT/package.json" ] && jq -e '.commitlint' "$WF_ROOT/package.json" >/dev/null 2>&1; then
    text=$(jq -c '.commitlint' "$WF_ROOT/package.json") src="package.json"
  fi
  [ -n "$src" ] || return 1
  jq -nc --arg s "$src" --argjson t "$(wf_enum "$text" type-enum)" --argjson c "$(wf_enum "$text" scope-enum)" \
    '{source: $s, types: $t, scopes: $c}'
}

# The values of an enum rule ([2, 'always', ['a', 'b']]) in a configuration text, as a JSON array.
wf_enum() { # text rule
  sed -nE "s/.*['\"]?$2['\"]?[[:space:]]*:[[:space:]]*\\[[[:space:]]*[0-9][[:space:]]*,[[:space:]]*['\"]?[a-z]+['\"]?[[:space:]]*,[[:space:]]*\\[([^]]*)\\].*/\\1/p" <<<"$1" |
    grep -oE "['\"][^'\"]+['\"]" | tr -d "'\"" | jq -Rsc 'split("\n") | map(select(length > 0))' || echo '[]'
}

# Prints what owns the commit-msg hook of the project when it is not senior-mode's, nothing otherwise.
workflow_hook_owner() { # root
  local root=$1 path
  if [ -e "$root/.husky/commit-msg" ]; then echo husky
  elif grep -qsE '^[[:space:]]*commit-msg:' "$root/lefthook.yml" "$root/lefthook.yaml" "$root/.lefthook.yml" "$root/.lefthook.yaml"; then echo lefthook
  elif grep -qs 'commit-msg' "$root/.pre-commit-config.yaml"; then echo pre-commit
  elif [ -e "$root/.githooks/commit-msg" ] && ! grep -q '^# senior-mode:' "$root/.githooks/commit-msg"; then echo ".githooks/commit-msg"
  else
    path=$(git -C "$root" config core.hooksPath 2>/dev/null || true)
    if [ -n "$path" ] && [ "$path" != .githooks ] && [ -e "$root/$path/commit-msg" ] &&
      ! grep -q '^# senior-mode:' "$root/$path/commit-msg" 2>/dev/null; then
      echo "core.hooksPath $path"
    fi
  fi
}

# §2.2: the commit format.
wf_commit() {
  local subjects n conv tick top share cfg fmt="" pat why scopes='[]' key keys types
  subjects=$(git -C "$WF_ROOT" log "$WF_REF" --no-merges -n 100 --format=%s 2>/dev/null) || subjects=""
  n=$(grep -c '' <<<"$subjects" || true)
  [ -n "$subjects" ] || n=0
  conv='^[a-z]+(\([^)]*\))?!?: .+'
  tick='^\[?[A-Z][A-Z0-9]+-[0-9]+\]?[ :]'
  if cfg=$(wf_commitlint); then
    fmt=conventional
    why="commitlint config in $(jq -r .source <<<"$cfg")"
    scopes=$(jq -c .scopes <<<"$cfg")
    types=$(jq -r '.types | join("|")' <<<"$cfg")
    pat='^[a-z]+(\([^)]+\))?!?: [^ ].*$'
    [ -z "$types" ] || pat="^($types)(\\([^)]+\\))?!?: [^ ].*\$"
  elif [ "$n" -gt 0 ]; then
    local pc pt
    pc=$(wf_share "$conv" <<<"$subjects")
    pt=$(wf_share "$tick" <<<"$subjects")
    if [ "$pc" -ge 80 ]; then
      fmt=conventional why="$pc% of the last $n commit subjects are Conventional Commits"
    elif [ "$pt" -ge 80 ]; then
      fmt=ticket-prefix why="$pt% of the last $n commit subjects start with a ticket key"
    elif [ "$pc" -ge 50 ] || [ "$pt" -ge 50 ]; then
      local first=conventional other=free
      [ "$pc" -ge "$pt" ] || first=ticket-prefix
      fmt=$first why="$pc% Conventional Commits, $pt% ticket-prefixed among the last $n commit subjects"
      wf_ask "Which commit format should new commits follow: $first or $other?" "$first" "$other"
      WF_ASSUME_FMT=1
    else
      fmt=free why="no commit shape reaches 50% among the last $n commit subjects"
    fi
    case $fmt in
      conventional) pat='^[a-z]+(\([^)]+\))?!?: [^ ].*$' ;;
      ticket-prefix)
        keys=$(grep -oE '^\[?[A-Z][A-Z0-9]+-' <<<"$subjects" | tr -d '[' | sort -u)
        if [ "$(grep -c '' <<<"$keys")" -eq 1 ] && [ -n "$keys" ]; then
          key=${keys%-}
          pat="^\\[?$key-[0-9]+\\]?[ :] ?[^ ].*\$"
        else
          pat='^\[?[A-Z][A-Z0-9]+-[0-9]+\]?[ :] ?[^ ].*$'
        fi
        ;;
    esac
  else
    return 0
  fi
  local st=new
  [ -z "${WF_ASSUME_FMT:-}" ] || st=assumed
  wf_put commit.format "\"$fmt\"" "$why" "$st"
  [ -z "${pat:-}" ] || wf_put commit.pattern "$(jq -Rn --arg p "$pat" '$p')" "the shape the subjects follow" "$st"
  [ "$scopes" = '[]' ] || wf_put commit.scopes "$scopes" "scope-enum of the commitlint config"
  [ "$fmt" = conventional ] || WF_ND=true
}

# §2.2: the pull request conventions and the merge method.
wf_pr() {
  local f tpl="" own t ours titles style cs ts links total with kw allowed shape m a merged
  for f in .github/pull_request_template.md .github/PULL_REQUEST_TEMPLATE.md docs/pull_request_template.md \
    pull_request_template.md PULL_REQUEST_TEMPLATE.md; do
    [ -f "$WF_ROOT/$f" ] && { tpl=$f; break; }
  done
  if [ -z "$tpl" ]; then
    f=$(find "$WF_ROOT/.github/PULL_REQUEST_TEMPLATE" -maxdepth 1 -type f -name '*.md' 2>/dev/null | sort | head -n 1) || f=
    [ -z "$f" ] || tpl=${f#"$WF_ROOT"/}
  fi
  if [ -n "$tpl" ]; then
    own=true
    for t in "$WF_TPL"/*/pull_request_template.md; do ! cmp -s "$WF_ROOT/$tpl" "$t" || own=false; done
    [ "$own" = false ] || { wf_put pr.template "\"$tpl\"" "the pull request template of the repository"; WF_ND=true; }
  fi
  merged=$(jq -r 'length' <<<"$WF_PRS")
  if [ "$merged" -gt 0 ]; then
    titles=$(jq -r '.[].title' <<<"$WF_PRS")
    cs=$(wf_share '^[a-z]+(\([^)]*\))?!?: .+' <<<"$titles")
    ts=$(wf_share '^\[?[A-Z][A-Z0-9]+-[0-9]+' <<<"$titles")
    if [ "$cs" -ge 80 ]; then style=commit
    elif [ "$ts" -ge 80 ]; then style=ticket
    else style=free
    fi
    wf_put pr.title "\"$style\"" "$cs% of the last $merged merged pull request titles are commit-shaped, $ts% start with a ticket key"
    [ "$style" = commit ] || WF_ND=true
    with=$(jq -r '[.[] | select((.body // "") | test("(close[sd]?|fix(e[sd])?|resolve[sd]?)[: ]+#?[0-9]+"; "i"))] | length' <<<"$WF_PRS")
    if [ $((with * 100 / merged)) -ge 30 ]; then
      kw=$(jq -r '[.[] | (.body // "") | capture("(?<k>close[sd]?|fix(e[sd])?|resolve[sd]?)[: ]+#?[0-9]+"; "i") | .k | ascii_downcase
        | if startswith("close") then "Closes" elif startswith("fix") then "Fixes" else "Resolves" end]
        | group_by(.) | max_by(length) | .[0]' <<<"$WF_PRS")
    else
      kw=none
    fi
    wf_put pr.link "\"$kw\"" "$with of the last $merged merged pull requests link their issue"
    [ "$kw" = Closes ] || WF_ND=true
  fi
  # The merge method: the shape of the base's history, within the methods the repository allows.
  allowed=""
  if [ -n "$WF_SLUG" ]; then
    allowed=$(gh_retry api "repos/$WF_SLUG" --jq '[(if .allow_rebase_merge then "rebase" else empty end),
      (if .allow_squash_merge then "squash" else empty end), (if .allow_merge_commit then "merge" else empty end)] | join(" ")' 2>/dev/null) || allowed=""
  fi
  total=$(git -C "$WF_ROOT" rev-list --count --max-count=100 "$WF_REF" 2>/dev/null || echo 0)
  shape=""
  if [ "$total" -ge 5 ]; then
    m=$(git -C "$WF_ROOT" log "$WF_REF" -n 100 --merges --format=%h | grep -c '' || true)
    a=$(git -C "$WF_ROOT" log "$WF_REF" -n 100 --no-merges --format=%s | grep -cE '\(#[0-9]+\)$' || true)
    if [ $((m * 100 / total)) -ge 30 ]; then shape=merge
    elif [ $((a * 100 / total)) -ge 50 ]; then shape=squash
    else shape=rebase
    fi
  fi
  if [ -n "$shape" ] && { [ -z "$allowed" ] || [[ " $allowed " == *" $shape "* ]]; }; then
    wf_put merge "\"$shape\"" "shape of the last $total commits of $WF_REF${allowed:+; allowed: $allowed}"
    [ "$shape" = rebase ] || WF_ND=true
  elif [ -n "$allowed" ]; then
    m=${allowed%% *}
    if [ -n "$shape" ]; then
      wf_ask "The history looks $shape-merged but the repository allows only: $allowed. Which method?" "$m" "$shape"
      wf_put merge "\"$m\"" "history shape $shape is not allowed; allowed: $allowed" assumed
      [ "$m" = rebase ] || WF_ND=true
    elif [ "$allowed" = "$m" ]; then
      wf_put merge "\"$m\"" "the only method the repository allows"
      [ "$m" = rebase ] || WF_ND=true
    fi
  fi
}

# §2.1: the branch names.
wf_branch() {
  local names total pat="" i n k alt cnt types='{}' st
  names=$( { { jq -r '.[].headRefName' <<<"$WF_PRS"
    git -C "$WF_ROOT" for-each-ref --format='%(refname:short)' refs/remotes/origin | sed 's#^origin/##'; } |
    grep -vE '^(HEAD|main|master|dev|develop|development|staging|release/|hotfix/|support/|dependabot/|renovate/|release-please)' || true; } | sort -u | head -n 200)
  total=$(grep -c '' <<<"$names" || true)
  [ -n "$names" ] && [ "$total" -ge 3 ] || return 0
  n=$(wf_share '^[a-z]+/[0-9]+(-|$)' <<<"$names")
  if [ "$n" -lt 50 ]; then
    if [ "$(wf_share '^[a-z]+/[A-Za-z][A-Za-z0-9]*-[0-9]+(-|$)' <<<"$names")" -ge 50 ]; then pat='{type}/{key}-{slug}'
    elif [ "$(wf_share '^[A-Za-z][A-Za-z0-9]*-[0-9]+(-|$)' <<<"$names")" -ge 50 ]; then pat='{key}-{slug}'
    elif [ "$(wf_share '^[a-z]+/[^/]+$' <<<"$names")" -ge 50 ]; then pat='{type}/{slug}'
    fi
  fi
  # The project's names for senior-mode's types: feature/ for feat/, bugfix/ for fix/.
  for k in feat:feature,features fix:bugfix,bug chore:chores,task; do
    st=${k%%:*}
    grep -q "^$st/" <<<"$names" && continue
    for alt in $(tr ',' ' ' <<<"${k#*:}"); do
      cnt=$(grep -c "^$alt/" <<<"$names" || true)
      if [ "$cnt" -gt 0 ]; then types=$(jq -c --arg k "$st" --arg v "$alt" '.[$k] = $v' <<<"$types"); break; fi
    done
  done
  if [ -n "$pat" ] || [ "$types" != '{}' ]; then
    wf_put branch.pattern "$(jq -Rn --arg p "${pat:-$WORKFLOW_DEFAULT_PATTERN}" '$p')" "$total remote or merged branch names read"
    [ "$types" = '{}' ] || wf_put branch.types "$types" "type prefixes the branches use"
    WF_ND=true
  fi
}

# The jobs of the workflows that run on pull requests: workflow name, job id, job name, run steps, one line per job.
wf_workflow_jobs() {
  local f
  for f in "$WF_ROOT"/.github/workflows/*.yml "$WF_ROOT"/.github/workflows/*.yaml; do
    [ -f "$f" ] || continue
    [ "$(basename "$f")" != senior-mode.yml ] || continue
    awk '
      function flush() { if (id != "") { n++; jobs[n] = id "\t" name "\t" run } id = ""; name = ""; run = ""; inrun = 0 }
      { sub(/\r$/, ""); ind = match($0, /[^ ]/) - 1 }
      /^[A-Za-z"\047][^:]*:/ {
        key = $0; sub(/:.*/, "", key); gsub(/["\047]/, "", key)
        flush(); injobs = (key == "jobs"); inon = (key == "on" || key == "true")
        if (key == "name" && wf == "") { v = $0; sub(/^[^:]*:[ ]*/, "", v); gsub(/^["\047]|["\047]$/, "", v); wf = v }
        if (inon && $0 ~ /pull_request/) pr = 1
        next
      }
      inon && /pull_request/ { pr = 1 }
      injobs && ind == 2 && /^  [A-Za-z0-9_-]+:[ ]*(#.*)?$/ { flush(); id = $0; sub(/^  /, "", id); sub(/:.*/, "", id); next }
      injobs && id != "" {
        if (ind == 4 && $0 ~ /^    name:/) { v = $0; sub(/^    name:[ ]*/, "", v); gsub(/^["\047]|["\047]$/, "", v); if (v !~ /\$\{\{/) name = v; next }
        if (inrun) { if ($0 ~ /^[ ]*$/ || ind > runind) { run = run " " $0; next } inrun = 0 }
        if ($0 ~ /^[ ]*(- )?run:/) {
          runind = match($0, /run:/) - 1; v = $0; sub(/^[ ]*(- )?run:[ ]*/, "", v)
          if (v ~ /^[|>][+-]?[ ]*$/) inrun = 1; else run = run " " v
        }
      }
      END { flush(); if (pr) for (i = 1; i <= n; i++) print wf "\t" jobs[i] }' "$f"
  done
}

# §2.3: the CI of the project.
wf_ci() {
  local jobs ctx req="" b prs=0 any=0 cutoff ts f count=0 other
  for f in "$WF_ROOT"/.github/workflows/*.yml "$WF_ROOT"/.github/workflows/*.yaml; do
    [ -f "$f" ] && [ "$(basename "$f")" != senior-mode.yml ] && count=$((count + 1))
  done
  [ -e "$WF_ROOT/.gitlab-ci.yml" ] && WF_UNMAPPED+=(".gitlab-ci.yml: GitLab CI jobs are not read; senior-mode/ci stays the local check")
  [ -e "$WF_ROOT/Jenkinsfile" ] && WF_UNMAPPED+=("Jenkinsfile: Jenkins jobs are not read; senior-mode/ci stays the local check")
  [ -d "$WF_ROOT/.circleci" ] && WF_UNMAPPED+=(".circleci: CircleCI jobs are not read; senior-mode/ci stays the local check")
  jobs=$(wf_workflow_jobs | jq -Rsc --argjson cmds "$WF_CMDS" '
    def esc: gsub("(?<c>[^A-Za-z0-9 ])"; "\\\(.c)");
    def kw: {lint: "lint|eslint|ruff|clippy|golangci|flake8|biome", typecheck: "tsc|typecheck|type-check|mypy|pyright|cargo check|go vet",
             test: "test|pytest|jest|vitest|mocha|rspec", build: "build|compile", e2e: "playwright|cypress|e2e"};
    split("\n") | map(select(length > 0) | split("\t")) | map({wf: .[0], id: .[1], name: .[2], run: (.[3] // "")})
    | map(. as $j | ((if $j.name != "" then $j.name else $j.id end) as $n
      | {context: (if $j.wf != "" then "\($j.wf) / \($n)" else $n end),
         covers: ([kw | to_entries[] | .key as $k | ($cmds[$k] // "") as $c
           | select(($c != "" and ($j.run | test(($c | esc) + "($|[^:A-Za-z0-9_-])")))
             or ($c != "" and ($j.run | test("\\b(" + .value + ")\\b"; "i")))) | $k]
           | if index("test") and ($j.run | test("playwright|cypress|e2e"; "i"))
               and (($cmds.test // "") == "" or ($j.run | contains($cmds.test) | not)) then map(select(. != "test")) else . end)}))
    | map(select(.covers | length > 0))')
  if [ -n "$WF_SLUG" ]; then
    for b in "$(jq -r '.integration // empty' <<<"$WF_JSON")" "$(jq -r '.base // empty' <<<"$WF_JSON")"; do
      [ -n "$b" ] || continue
      req+=$'\n'$(gh_bound api "repos/$WF_SLUG/rules/branches/$b" --jq '[.[]? | select(.type == "required_status_checks")
        | .parameters.required_status_checks[]?.context] | .[]' 2>/dev/null || true)
      req+=$'\n'$(gh_bound api "repos/$WF_SLUG/branches/$b/protection/required_status_checks" --jq '.contexts[]?' 2>/dev/null || true)
    done
    req=$(printf '%s\n' "$req" | grep -v '^senior-mode/' | grep -v '^$' | sort -u | jq -Rsc 'split("\n") | map(select(length > 0))') || req='[]'
    cutoff=$(wf_days_ago 30)
    while read -r ts; do
      [ -n "$ts" ] && [[ $ts > $cutoff ]] && prs=$((prs + 1))
    done < <(gh_bound run list --repo "$WF_SLUG" --event pull_request --limit 20 --json createdAt --jq '.[].createdAt' 2>/dev/null || true)
    while read -r ts; do
      [ -n "$ts" ] && [[ $ts > $cutoff ]] && any=$((any + 1))
    done < <(gh_bound run list --repo "$WF_SLUG" --limit 20 --json createdAt --jq '.[].createdAt' 2>/dev/null || true)
    [ "$req" != '[]' ] || req=""
    # Merge queue and more than one reviewer have no counterpart in senior-mode.
    other=$(gh_bound api "repos/$WF_SLUG/rules/branches/$(jq -r '.integration // empty' <<<"$WF_JSON")" 2>/dev/null || true)
    if [ -n "$other" ]; then
      jq -e 'any(.[]?; .type == "merge_queue")' <<<"$other" >/dev/null 2>&1 &&
        WF_UNMAPPED+=("merge queue: senior-mode merges with the method of the project and does not use the queue")
      jq -e 'any(.[]?; .type == "pull_request" and ((.parameters.required_approving_review_count // 0) > 1))' <<<"$other" >/dev/null 2>&1 &&
        WF_UNMAPPED+=("more than one required reviewer: senior-mode holds one independent review; the other approvals stay with the team")
    fi
  fi
  if [ "$count" -gt 0 ] && [ "$prs" -gt 0 ]; then
    WF_CI_MODE=existing
    wf_put ci.jobs "$jobs" "$count workflow files run on pull requests ($prs runs in the last 30 days); the jobs that cover a check"
    WF_ND=true
  elif [ "$count" -gt 0 ] && [ "$any" -gt 0 ]; then
    wf_ask "The workflows ran $any times in the last 30 days but not on a pull request: reuse them as the CI?" "no, ci.mode stays local" "yes, ci.mode existing"
    wf_put ci.jobs "$jobs" "workflows present, no pull request run in 30 days (not reused)" assumed
  fi
  if [ -n "${req:-}" ]; then
    wf_put ci.required "$req" "required status checks of the protection or rulesets of the branch"
    WF_ND=true
  fi
  if [ "$(git -C "$WF_ROOT" for-each-ref --format='%(refname:short)' 'refs/remotes/origin/staging' 'refs/remotes/origin/production' \
    'refs/remotes/origin/prod' 'refs/remotes/origin/preprod' | grep -c '' || true)" -gt 0 ]; then
    WF_UNMAPPED+=("deploy or environment branches: senior-mode neither merges into nor promotes them; they stay a human step")
  fi
}

# §2.4: the labels of the repository that stand for senior-mode's.
wf_labels() {
  local names map='{}' want cand c hit
  [ -n "$WF_SLUG" ] || return 0
  names=$(gh_retry label list --repo "$WF_SLUG" --limit 200 --json name --jq '.[].name' 2>/dev/null) || return 0
  [ -n "$names" ] || return 0
  for want in "type:bug|bug" "type:feature|enhancement feature" "type:chore|chore maintenance"; do
    c=${want%%|*}
    grep -qxF "$c" <<<"$names" && continue
    hit=""
    for cand in ${want#*|}; do
      hit=$(grep -ixF "$cand" <<<"$names" | head -n 1) && [ -n "$hit" ] && break
    done
    [ -z "$hit" ] || map=$(jq -c --arg k "$c" --arg v "$hit" '.[$k] = $v' <<<"$map")
  done
  [ "$map" = '{}' ] || { wf_put labels "$map" "the repository's own labels stand for senior-mode's; setup github creates none of them"; WF_ND=true; }
}

# §2.5: an external tracker, from the keys of the subjects and branches.
wf_tracker() {
  local subjects branches share key kind text
  subjects=$(git -C "$WF_ROOT" log "$WF_REF" --no-merges -n 100 --format=%s 2>/dev/null || true)
  branches=$({ jq -r '.[].headRefName' <<<"$WF_PRS"
    git -C "$WF_ROOT" for-each-ref --format='%(refname:short)' refs/remotes/origin | sed 's#^origin/##'; } | { grep -v '^HEAD$' || true; } | sort -u)
  share=$(wf_share '[A-Z][A-Z0-9]+-[0-9]+' <<<"$subjects")
  [ "$share" -ge 50 ] || share=$(wf_share '(^|/)[A-Za-z][A-Za-z0-9]*-[0-9]+' <<<"$branches")
  [ "$share" -ge 50 ] || return 0
  key=$({ grep -oE '[A-Z][A-Z0-9]+-[0-9]+' <<<"$subjects"; grep -oiE '(^|/)[A-Za-z][A-Za-z0-9]*-[0-9]+' <<<"$branches" | sed 's#^/##'; } |
    sed -E 's/-[0-9]+$//' | tr 'a-z' 'A-Z' | sort | uniq -c | sort -rn | head -n 1 | awk '{print $2}')
  [ -n "$key" ] || return 0
  text=$(cat "$WF_ROOT"/README* "$WF_ROOT"/.github/*.md "$WF_ROOT"/.github/ISSUE_TEMPLATE/* 2>/dev/null || true)
  if grep -qiE 'atlassian\.net|jira' <<<"$text"; then kind=jira
  elif grep -qiE 'linear\.app|linear' <<<"$text"; then kind=linear
  else kind=other
  fi
  wf_put tracker "$(jq -nc --arg k "$kind" --arg key "$key" '{kind: $k, key: $key}')" "$share% of the subjects or branches carry a $key-<n> key"
  WF_UNMAPPED+=("tracker $kind ($key): issues stay on GitHub and the key travels in the \`Tracker:\` line of the issue; nothing is synchronised")
  WF_ND=true
}

# §8: evergreen or legacy.
wf_adopt() {
  local commits first age files lint test sig=0 says="" rc=0 src
  commits=$(git -C "$WF_ROOT" rev-list --no-merges --count HEAD 2>/dev/null || echo 0)
  first=$(git -C "$WF_ROOT" log --max-parents=0 --format=%ct HEAD | sort -n | head -n 1)
  age=$(( ($(date +%s) - ${first:-$(date +%s)}) / 86400 ))
  files=$(git -C "$WF_ROOT" ls-files | grep -cE '\.(ts|tsx|js|jsx|mjs|cjs|py|go|rs|java|kt|rb|php|cs|swift|c|cc|cpp|h|hpp|scala|vue|svelte)$' || true)
  src=$files
  [ "$commits" -lt 100 ] || { sig=$((sig + 1)); says+="commits $commits (>=100), "; }
  [ "$age" -lt 90 ] || { sig=$((sig + 1)); says+="age ${age}d (>=90), "; }
  [ "$files" -lt 100 ] || { sig=$((sig + 1)); says+="source files $files (>=100), "; }
  local s4=0
  if [ "$src" -gt 0 ]; then
    lint=$(jq -r '.lint // empty' <<<"$WF_CMDS")
    test=$(jq -r '.test // empty' <<<"$WF_CMDS")
    if [ -z "$test" ]; then s4=1 says+="no test command, "
    elif [ -n "$lint" ] && ! deps_missing "$WF_ROOT"; then
      (cd "$WF_ROOT" && net_bound 120 bash -c "$lint") >/dev/null 2>&1 </dev/null || rc=$?
      if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] && [ "$rc" -lt 126 ]; then s4=1 says+="lint fails, "; fi
    fi
  fi
  sig=$((sig + s4))
  if [ "$sig" -ge 2 ]; then WF_ADOPT=legacy
  elif [ "$sig" -eq 0 ]; then WF_ADOPT=evergreen
  elif [ "$s4" -eq 1 ]; then
    WF_ADOPT=legacy WF_ADOPT_ASSUMED=1
    wf_ask "Is this a legacy project (held to a ratchet) or an evergreen one?" legacy evergreen
  else
    WF_ADOPT=evergreen WF_ADOPT_ASSUMED=1
    wf_ask "Is this a legacy project (held to a ratchet) or an evergreen one?" evergreen legacy
  fi
  WF_ADOPT_WHY="$sig of 4 signals true: ${says%, }${says:+; }commits $commits, age ${age}d, source files $files"
}

# Reads the repository and GitHub. $1 the root of the checkout, $2 a JSON object of the commands (name to command),
# $3 the templates directory of the plugin. Sets the WF_* state; nothing is written.
workflow_detect() {
  WF_ROOT=$1 WF_CMDS=$2 WF_TPL=$3
  WF_JSON='{}' WF_ROWS=() WF_UNMAPPED=() WF_ASKS=() WF_ND=false WF_ADOPT="" WF_ADOPT_WHY="" WF_CI_MODE="" WF_SLUG="" WF_PRS='[]'
  WF_ADOPT_ASSUMED="" WF_ASSUME_INT="" WF_ASSUME_FMT=""
  git -C "$WF_ROOT" rev-parse -q --verify HEAD >/dev/null 2>&1 || return 0
  if git -C "$WF_ROOT" remote get-url origin >/dev/null 2>&1 && command -v gh >/dev/null; then
    WF_SLUG=$(cd "$WF_ROOT" && repo_slug 2>/dev/null) || WF_SLUG=""
  fi
  WF_REF=$(cd "$WF_ROOT" && repo_default_branch) || return 0
  wf_load_prs
  wf_model
  wf_commit
  wf_pr
  wf_branch
  wf_ci
  wf_labels
  wf_tracker
  wf_adopt
}

# Settles the findings against the config $1: a key the owner already holds is kept (its value shown), the others are new.
workflow_settle() {
  local i row path cur
  for i in "${!WF_ROWS[@]}"; do
    row=${WF_ROWS[$i]}
    path=${row%%$'\t'*}
    cur=$(jq -c --arg p "$path" 'getpath(["workflow"] + ($p | split("."))) // empty' "$1" 2>/dev/null || true)
    [ -z "$cur" ] || WF_ROWS[i]=$path$'\t'$cur$'\t'"set in the config"$'\t'kept
  done
  [ -n "$WF_ADOPT" ] || return 0
  if jq -e '.adopt.kind' "$1" >/dev/null 2>&1; then
    WF_ADOPT=$(jq -r '.adopt.kind' "$1")
    WF_ADOPT_WHY="set in the config"
    WF_ADOPT_ASSUMED=kept
  fi
}

# The config that setup would write: the findings under the keys the owner holds.
workflow_merged() { # file
  jq -c --argjson w "$WF_JSON" --arg adopt "$WF_ADOPT" --arg mode "$WF_CI_MODE" --argjson nd "$WF_ND" '
    (if $nd and ($w | length) > 0 then .workflow = ($w * (.workflow // {})) else . end)
    | (if $adopt != "" then .adopt = ({kind: $adopt} * (.adopt // {})) else . end)
    | (if $mode != "" and ((.ci.mode // null) == null) then .ci.mode = $mode else . end)' "$1"
}

# Writes the findings into the config $1.
workflow_write() {
  local new
  new=$(workflow_merged "$1") || die "could not merge the workflow into .claude/senior-mode.json"
  [ "$(jq -S . <<<"$new")" = "$(jq -S . "$1")" ] || { jq . <<<"$new" >"$1.tmp" && mv "$1.tmp" "$1"; }
}

# The report, as the adoption pull request carries it: what was detected with its evidence, and what is not mapped.
workflow_report() {
  local row path val ev st line
  echo "## Detected"
  echo
  for row in "${WF_ROWS[@]}"; do
    IFS=$'\t' read -r path val ev st <<<"$row"
    case $st in assumed) st=" (assumed)" ;; kept) st=" (kept)" ;; *) st="" ;; esac
    echo "- \`$path\`: \`$val\` — $ev$st"
  done
  if [ -n "$WF_ADOPT" ]; then
    st=""
    [ -z "$WF_ADOPT_ASSUMED" ] || st=" (assumed)"
    [ "$WF_ADOPT_ASSUMED" != kept ] || st=" (kept)"
    echo "- \`adopt.kind\`: \`\"$WF_ADOPT\"\` — $WF_ADOPT_WHY$st"
  fi
  [ -z "$WF_CI_MODE" ] || echo "- \`ci.mode\`: \`\"$WF_CI_MODE\"\` — the project's CI runs on pull requests"
  [ "${#WF_ROWS[@]}" -gt 0 ] || [ -n "$WF_ADOPT" ] || echo "- nothing to read: no commit yet"
  echo
  echo "## Not mapped"
  echo
  if [ "${#WF_UNMAPPED[@]}" -eq 0 ]; then
    echo "- nothing"
  else
    for line in "${WF_UNMAPPED[@]}"; do echo "- $line"; done
  fi
}

# What `setup repo` prints for the workflow: the questions it did not ask, the report.
workflow_say() {
  local q
  for q in "${WF_ASKS[@]}"; do echo "ask: $q; took the recommended answer (assumed)"; done
  workflow_report
  [ "$WF_ND" = true ] || echo "workflow: nothing differs from senior-mode's defaults, so no workflow key is recorded"
}

# `setup repo --adopt`: the adoption pull request, `docs: adopt senior-mode`, on the integration branch and named by
# the detected conventions. $1 the root of the main checkout, $2 the report. The setup runs in a worktree of its
# own on that branch, so the pull request holds only what setup changed and the checkout is not touched.
workflow_adopt_pr() { # root report args...
  local root=$1 report=$2 base branch pr url tree
  shift 2
  [ -n "$WF_SLUG" ] || die "--adopt needs an origin remote on GitHub"
  base=$(jq -r '.integration // empty' <<<"$WF_JSON")
  [ -n "$base" ] || base=${WF_REF#origin/}
  branch=$(workflow_branch_name "$root" docs "" "adopt-senior-mode" "")
  [ -n "$branch" ] || branch=docs/adopt-senior-mode
  pr=$(gh_retry pr list --repo "$WF_SLUG" --head "$branch" --state open --json url --jq '.[0].url // empty') || die "cannot list the pull requests of $WF_SLUG"
  if [ -n "$pr" ]; then
    echo "adoption: the pull request is already open: $pr"
    return 0
  fi
  git_bound -C "$root" fetch -q origin "$base" || die "cannot fetch $base"
  ! git -C "$root" ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1 ||
    git_bound -C "$root" push -q origin --delete "$branch" || die "cannot delete the stale branch $branch"
  tree=$(mktemp -d)
  git -C "$root" worktree add -q -B "$branch" "$tree" "origin/$base" || die "cannot create the worktree for $branch"
  (
    cd "$tree" || exit 1
    WF_ADOPTING=1 WF_DONE=1 setup_repo "$@" >/dev/null || exit 1
    git add -A
    git diff --cached --quiet && exit 3
    git -c core.hooksPath=/dev/null commit -q -m "docs: adopt senior-mode" \
      -m "Records the workflow senior-mode detected in this repository, and the files it adds. Generated by \`senior-mode setup repo --adopt\`." || exit 1
    git_bound -c core.hooksPath=/dev/null push -q -u origin "$branch" || exit 1
  )
  case $? in
    0) ;;
    3) echo "adoption: setup changes nothing on $base"; git -C "$root" worktree remove --force "$tree"; return 0 ;;
    *) git -C "$root" worktree remove --force "$tree"; die "could not prepare the adoption branch $branch" ;;
  esac
  git -C "$root" worktree remove --force "$tree"
  url=$(gh pr create --repo "$WF_SLUG" --base "$base" --head "$branch" --title "docs: adopt senior-mode" --body "$report") ||
    die "cannot open the adoption pull request"
  echo "adoption: pull request opened: $url"
}
