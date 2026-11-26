# shellcheck shell=bash
# The CODEOWNERS pattern of a `protected` glob (#171), or nothing when CODEOWNERS cannot say it.
# `protected` anchors a glob that has a slash at the root and matches one without a slash at any
# depth; CODEOWNERS, like .gitignore, anchors on a leading slash only, so one is added (`docs/` is
# then the root's docs, as in `protected`). Whitespace, a leading # or !, and brackets have no
# CODEOWNERS spelling.
codeowners_pattern() {
  case $1 in
    "" | *[[:space:]]* | \#* | \!* | *\[*) return 1 ;;
    /* | \*\*/*) printf '%s\n' "$1" ;;
    */*) printf '/%s\n' "$1" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# Maps the `protected` globs to the owner in a block of .github/CODEOWNERS delimited by
# `# senior-mode:begin` and `# senior-mode:end`; only that block is rewritten, so entries added by
# hand survive a rerun. The block goes last in a new one, where GitHub reads the last match first.
# Written, not committed: setup commits nothing, and the file protects once it is on the default branch.
# GitHub reads .github/CODEOWNERS before the root's and docs/'s: it never creates that shadow over a
# file of the project (the ownership there would be lost without a word), and names one it finds.
# The globs CODEOWNERS cannot spell are listed in the block too, so the file says what it leaves out.
# Sets codeowners_owns to true when the block owns a protected zone; review_reason decides on the review.
setup_codeowners() { # root owner globs-json slug
  local file=$1/.github/CODEOWNERS glob pat entries="" skipped="" block new verb shadow="" s there
  codeowners_owns=false
  for s in CODEOWNERS docs/CODEOWNERS; do [ ! -e "$1/$s" ] || shadow+="${shadow:+ and }$s"; done
  if [ -n "$shadow" ] && [ ! -e "$file" ]; then
    # GitHub reads the root's before docs/'s: with both, docs/ is already ignored and only the root's is lost.
    if [ -e "$1/CODEOWNERS" ] && [ -e "$1/docs/CODEOWNERS" ]; then
      shadow="CODEOWNERS would be shadowed by .github/CODEOWNERS, which GitHub reads first, and its ownership lost (docs/CODEOWNERS is already ignored by GitHub, the root's is read first)"
    else
      shadow="$shadow would be shadowed by .github/CODEOWNERS, which GitHub reads first, and its ownership lost"
    fi
    echo "CODEOWNERS: $shadow; .github/CODEOWNERS not written. Move it to .github/CODEOWNERS, then run setup github again, or add the protected zones to it by hand"
    return 0
  fi
  [ -z "$shadow" ] ||
    echo "CODEOWNERS: shadowed by .github/CODEOWNERS and ignored by GitHub: $shadow; merge its entries into .github/CODEOWNERS and delete it, or its ownership stays lost"
  while IFS= read -r glob; do
    if pat=$(codeowners_pattern "$glob"); then entries+="$pat @$2"$'\n'; else skipped+="${skipped:+, }$glob"; fi
  done < <(jq -r '.[]' <<<"$3")
  [ -z "$skipped" ] || echo "CODEOWNERS: no spelling for $skipped, left out; those zones are owned by no one, so code owner review does not cover them and they stay with the reviewer"
  block="# senior-mode:begin (managed from protected in .claude/senior-mode.json; edit outside this block)"$'\n'"$entries"
  [ -z "$skipped" ] || block+="# left to the reviewer, CODEOWNERS has no spelling for them: $skipped"$'\n'
  block+="# senior-mode:end"
  if [ ! -e "$file" ]; then
    [ -n "$entries$skipped" ] || return 0
    mkdir -p "$1/.github"
    printf '%s\n' "$block" >"$file"
    verb=created
  elif ! grep -qE '^# senior-mode:(begin|end)' "$file"; then
    [ -n "$entries$skipped" ] || return 0
    printf '%s\n\n%s\n' "$(cat "$file")" "$block" >"$file"
    verb=updated
  # One opening marker, then one closing marker, else awk refuses and the file is left alone.
  elif ! new=$(BLOCK=$block awk '
      /^# senior-mode:begin/ { if (seen++) bad = 1; print ENVIRON["BLOCK"]; skip = 1; next }
      /^# senior-mode:end/ { if (!skip) bad = 1; skip = 0; next }
      !skip { print } END { exit (bad || skip) }' "$file"); then
    echo "CODEOWNERS: senior-mode markers broken, file left untouched; restore one begin and one end marker"
    return 0
  elif [ "$new" != "$(cat "$file")" ]; then
    printf '%s\n' "$new" >"$file"
    verb=updated
  fi
  if [ -z "$entries" ]; then
    [ -z "${verb:-}" ] ||
      echo "CODEOWNERS: $verb .github/CODEOWNERS, no protected zone owned; commit it (setup commits nothing)"
    return 0
  fi
  codeowners_owns=true
  [ -z "${verb:-}" ] ||
    echo "CODEOWNERS: $verb .github/CODEOWNERS, protected zones owned by @$2; commit it (setup commits nothing), the ruleset reads the default branch's copy"
  # Said on every run, a rerun that changes nothing included: until the default branch holds this very
  # file, GitHub reads no CODEOWNERS from it and the review requirement binds nothing.
  # Only a 404 says the default branch has none; any other error leaves the question open.
  if there=$(gh_retry api "repos/$4/contents/.github/CODEOWNERS" -H "Accept: application/vnd.github.raw" 2>&1); then
    [ "$there" != "$(cat "$file")" ] || return 0
    there="the default branch holds another copy"
  elif grep -q 'HTTP 404' <<<"$there"; then
    there="the default branch has none"
  else
    there="could not read .github/CODEOWNERS on the default branch: $there"
  fi
  echo "CODEOWNERS: code owner review enforces nothing until .github/CODEOWNERS is on the default branch ($there): commit it and merge it"
}

# Whether the senior-mode ruleset of the repository already requires code owner review: status 0 when
# it does, 1 when it is absent, does not, or the plan refuses rulesets (there is none), 2 when it could
# not be read (an error that says nothing of its content).
ruleset_review_on() { # slug
  local id cur
  id=$(gh_retry api "repos/$1/rulesets" \
    --jq '[.[] | select(.name == "senior-mode" and .source_type == "Repository")][0].id // empty' 2>&1) ||
    { ruleset_refused <<<"$id" && return 1 || return 2; }
  [ -n "$id" ] || return 1
  cur=$(gh_retry api "repos/$1/rulesets/$id" \
    --jq '[.rules[]? | select(.type == "pull_request") | .parameters.require_code_owner_review] | any' 2>&1) ||
    return 2
  [ "$cur" = true ]
}

# Why the ruleset requires code owner review, said in words, or nothing and status 1 when no reason holds.
# Setup never lowers a protection: the review stays required when the block owns a zone, when the
# CODEOWNERS file GitHub reads (.github/, then the root, then docs/; a shadow refusal and broken markers
# included) has an owner entry, or when the ruleset already requires it or cannot be read.
review_reason() { # root block-owns slug
  local f rc
  [ "$2" != true ] || { echo "the block owns the protected zones"; return 0; }
  for f in .github/CODEOWNERS CODEOWNERS docs/CODEOWNERS; do
    [ -e "$1/$f" ] || continue
    ! grep -qE '^[[:space:]]*[^#[:space:]][^[:space:]]*[[:space:]]+[^#[:space:]]' "$1/$f" ||
      { echo "$f, the CODEOWNERS file GitHub reads, has an owner entry"; return 0; }
    break
  done
  ruleset_review_on "$3" && rc=0 || rc=$?
  case $rc in
    0) echo "the ruleset already requires it"; return 0 ;;
    2) echo "the current ruleset could not be read, so it may require it"; return 0 ;;
  esac
  return 1
}

# Creates the senior-mode ruleset of the repository, or updates it; $2 is whether it requires code
# owner review (true when CODEOWNERS owns the protected zones), $3 whether it requires the statuses
# (github.requiredChecks, default true): false leaves the rule out, and an update removes the one it had.
setup_ruleset() {
  local id body cur
  body=$(jq -c --argjson r "$2" '(.rules[] | select(.type == "pull_request") | .parameters.require_code_owner_review) = $r' \
    <<<"$RULESET")
  [ "${3:-true}" = true ] || body=$(jq -c '.rules |= map(select(.type != "required_status_checks"))' <<<"$body")
  # A project that merges another way (workflow.merge) is not held to rebase and linear history; with an existing CI
  # (ci.mode existing) its own required contexts stay next to ours.
  if [ -n "${4:-}" ] && [ -f "$4" ]; then
    body=$(jq -c --slurpfile c "$4" '($c[0].workflow.merge // "rebase") as $m
      | (if $m == "rebase" then . else .rules |= map(select(.type != "required_linear_history")) end)
      | (.rules[] | select(.type == "pull_request") | .parameters.allowed_merge_methods) = [$m]
      | if $c[0].ci.mode == "existing" then
          (.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks) |=
            (. as $ours | $ours + [($c[0].workflow.ci.required // [])[] | {context: .} | select(.context | IN($ours[].context) | not)])
        else . end' <<<"$body")
  fi
  id=$(gh_retry api "repos/$1/rulesets" \
    --jq '[.[] | select(.name == "senior-mode" and .source_type == "Repository")][0].id // empty') || return 1
  if [ -n "$id" ]; then
    # Required checks someone added by hand stay: ours are merged into them.
    if [ "${3:-true}" = true ]; then
      cur=$(gh_retry api "repos/$1/rulesets/$id" \
        --jq '[.rules[]? | select(.type == "required_status_checks") | .parameters.required_status_checks[]?]') || return 1
      body=$(jq -c --argjson c "${cur:-[]}" '(.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks) |=
        (. as $ours | $ours + [$c[] | select(.context | IN($ours[].context) | not)])' <<<"$body")
    fi
    gh_retry api -X PUT "repos/$1/rulesets/$id" --input - <<<"$body"
  else
    gh_retry api -X POST "repos/$1/rulesets" --input - <<<"$body"
  fi
}

# True when gh's error (stderr, on stdin) is the plan refusing rulesets: HTTP 403 and GitHub's message
# "Upgrade to GitHub Pro or make this repository public to enable this feature." (a Free account or
# organization, private repository). Matches the status and a stable fragment, not the whole sentence.
ruleset_refused() {
  local err
  err=$(cat)
  grep -q 'HTTP 403' <<<"$err" && grep -qiE 'upgrade to github (pro|team)|make this repository public' <<<"$err"
}

# Sets github.protection (spec 0001 §13): ruleset, or local when the plan refuses it (ADR 0032); local also forces
# ci.mode local, since the pre-push hook is then the only gate, and makes senior-mode itself the merge gate (statuses and
# an up-to-date branch checked by run_blocker, an audit of direct pushes). Prints the plain-words warning.
setup_protection() { # config-file ruleset|local
  local was=""
  [ "$(jq -r '.ci.mode' "$1")" != actions ] || was=" (changed from actions)"
  if [ "$2" = local ]; then
    json_update "$1" '.github.protection = "local" | .ci.mode = "local"' || [ $? -eq 2 ] || die "could not write .claude/senior-mode.json"
    echo "protection: NOT enforced on the server. GitHub offers no rulesets or branch protection on a private repository of a Free account or organization, so anyone with push access can push to the default branch. ci.mode is local$was: the pre-push hook is the only gate."
    echo "protection: github.protection is local: serve and run merge a pull request only when senior-mode/ci, senior-mode/review and senior-mode/security are green on its head and the branch is up to date with the base (senior-mode checks it, GitHub does not), and an audit workflow reports a push that belongs to no merged pull request. It reports after the fact and blocks nothing."
    echo "protection: to enforce it on the server, make the repository public, or upgrade to GitHub Pro or Team and run setup again; to stop merging on its own, set github.protection to none in .claude/senior-mode.json."
  else
    json_update "$1" '.github.protection = "ruleset"' || [ $? -eq 2 ] || die "could not write .claude/senior-mode.json"
  fi
}

# The audit of direct pushes (ADR 0032) written for github.protection local: .github/workflows/senior-mode-audit.yml, never
# replaced. Like CODEOWNERS it is a file for the project to commit: GitHub runs it from the default branch.
setup_audit() { # root
  local tpl out
  tpl=$(cd "$(dirname "$SELF")/.." && pwd)/templates
  out=$(place "$tpl/workflows/senior-mode-audit.yml" "$1/.github/workflows/senior-mode-audit.yml" "audit workflow senior-mode-audit.yml")
  echo "$out"
  case $out in
    *created*) echo "audit workflow: commit and merge .github/workflows/senior-mode-audit.yml (setup commits nothing); it opens a needs-human issue when a commit reaches the default branch outside a pull request" ;;
  esac
}

# The GitHub side of a project (spec 0001 §11, #11), idempotent: Project linked to the repository with
# Status, Priority, Size and Severity; labels; rebase-only merges; a ruleset requiring the three statuses
# (ADR 0006, 0015); ids cached in the config.
# ci.mode local: the checks run before each push, so the repository's own workflows are disabled
# (files kept) and spend no Actions budget. GitHub's built-in ones (dynamic/: Dependabot, Pages)
# are left alone. ci.mode actions: our workflow is turned back on if an earlier local run disabled it.
setup_workflows() { # slug mode
  local list id wname path state disabled="" err
  if ! list=$(gh_retry workflow list --all --limit 1000 --repo "$1" --json id,name,path,state \
    --jq '.[] | select(.path | startswith(".github/workflows/")) | "\(.id)\t\(.path)\t\(.state)\t\(.name)"'); then
    # A token without the Actions permission (#536): nothing is lost when the default branch has no workflow.
    err=$(gh api "repos/$1/contents/.github/workflows" 2>&1 >/dev/null) || true
    if [ "$2" = local ] && [[ $err == *"HTTP 404"* ]]; then
      echo "workflows: none on the default branch, nothing to disable (the token cannot read Actions)"
      return 0
    fi
    die "cannot list the workflows of $1: the token needs the Actions permission (read and write)"
  fi
  while IFS=$'\t' read -r id path state wname; do
    [ -n "$id" ] || continue
    # The audit of direct pushes (ADR 0032) is senior-mode's own and costs nothing to keep on.
    [ "$path" != .github/workflows/senior-mode-audit.yml ] || continue
    if [ "$2" = local ] && [ "$state" = active ]; then
      gh_retry workflow disable "$id" --repo "$1" >/dev/null || die "cannot disable workflow $wname"
      disabled+="${disabled:+, }$wname"
    elif [ "$2" = actions ] && [ "$path" = .github/workflows/senior-mode.yml ] && [ "$state" != active ]; then
      gh_retry workflow enable "$id" --repo "$1" >/dev/null || die "cannot enable workflow $wname"
      echo "workflows: $wname enabled again (ci.mode actions)"
    fi
  done <<<"$list"
  # Read only: the setting is the repository owner's call, and a token secret works around it.
  if [ "$2" = actions ] && [ "$(gh_retry api "repos/$1/actions/permissions/workflow" \
    --jq .can_approve_pull_request_reviews 2>/dev/null)" = false ] &&
    ! gh api "repos/$1/actions/secrets/RELEASE_PLEASE_TOKEN" >/dev/null 2>&1; then
    echo "releases: GitHub Actions may not open pull requests here, so the release job cannot open its PR; allow it in Settings > Actions > General, or store a token as the RELEASE_PLEASE_TOKEN secret"
  fi
  [ "$2" != existing ] || echo "workflows: none disabled, none written (ci.mode existing: the project's CI stays as it is)"
  [ -z "$disabled" ] || echo "workflows: disabled $disabled (ci.mode local: checks run before each push; files kept; \`gh workflow enable <name>\` turns one back on, and senior-mode setup github --ci actions stops setup from disabling them again)"
}

# Switches on one GitHub security feature. A refusal (the plan, a token without the permission) is
# said, not fatal: the other features and the rest of setup go on.
security_feature() { # label gh-api-arguments...
  local label=$1 err
  shift
  if err=$(gh_retry api "$@" 2>&1 >/dev/null); then
    echo "security: $label: on"
  else
    err=$(head -n 1 <<<"${err#gh: }")
    echo "security: $label: not enabled ($err); the plan or the token refuses it, setup goes on"
  fi
}

# GitHub's own scanners (ADR 0015, #172, amended by #222): Dependabot alerts, secret scanning and push
# protection. Each may be refused by the plan. Dependabot security updates stay off: GitHub has no severity
# filter for them, so alerts become issues only (#144 path, high and critical).
setup_security() { # root slug
  security_feature "Dependabot alerts" -X PUT "repos/$2/vulnerability-alerts"
  security_feature "secret scanning (with push protection)" -X PATCH "repos/$2" \
    -f "security_and_analysis[secret_scanning][status]=enabled" \
    -f "security_and_analysis[secret_scanning_push_protection][status]=enabled"
  setup_dependabot "$1"
}

# Version updates (#497, spec 471 section 8): a weekly npm entry, minor and patch in one group, majors ignored
# (serve files them as tickets). Nothing is written beside a Renovate config or a dependabot.yml, nor without a
# package.json. The file is left uncommitted.
setup_dependabot() { # root
  local root=$1 dep=$1/.github/dependabot.yml
  if [ -e "$dep" ]; then
    echo "dependabot.yml: untouched (kept as it is; security updates are not turned on, alerts become issues)"
  elif compgen -G "$root/renovate.json*" >/dev/null || [ -e "$root/.renovaterc" ] || [ -e "$root/.github/renovate.json" ] ||
    [ -e "$root/.github/renovate.json5" ]; then
    echo "renovate: untouched"
  elif [ -f "$root/package.json" ]; then
    mkdir -p "$root/.github"
    cat <<'YML' | state_write "$dep"
version: 2
updates:
  - package-ecosystem: "npm"
    directory: "/"
    schedule:
      interval: "weekly"
    groups:
      minor-and-patch:
        update-types:
          - "minor"
          - "patch"
    ignore:
      - dependency-name: "*"
        update-types: ["version-update:semver-major"]
YML
    echo "dependabot.yml: written (weekly npm, minor and patch grouped, majors left to tickets)"
  fi
}

# The labels `setup github` creates, as name|color|description; the type labels only on a personal account
# (organizations use issue types). `setup remove` deletes them again.
LABELS='needs-human|d93f0b|Waiting for a human decision or merge
needs-info|fbca04|Missing information before work can start
needs-decision|d93f0b|Waiting for the answer to a question the session could not settle
blocked|b60205|Blocked by something outside this ticket
security|ee0701|A security risk, with its Severity on the board
triage|fbca04|External report, not qualified yet: serve never picks it
qualified|0e8a16|Qualified by a collaborator: serve may pick it though its author is external'
TYPE_LABELS='type:feature|a2eeef|New capability for users
type:bug|d73a4a|Something does not work as specified
type:task|c5def5|Work that is neither a feature nor a bug
type:chore|ededed|Maintenance with no user-visible change
type:spike|d4c5f9|Timeboxed research: a note, an ADR or framed tickets, never merged code'

# `setup github --dry-run`: what a run would do, from the config and read-only calls; nothing is written, on GitHub or here.
setup_plan() { # config-file owner-type checks slug
  local file=$1 labels=$LABELS merge globs mode
  [ "$2" = Organization ] || labels+=$'\n'$TYPE_LABELS
  merge=$(jq -r '.workflow.merge // "rebase"' "$file")
  globs=$(jq -c '.protected // []' "$file")
  mode=$(jq -r '.ci.mode // "local"' "$file")
  echo "Project: found, or copied from the template, with the fields Status, Priority, Size, Severity, Paths and its cycle"
  echo "labels: $(cut -d'|' -f1 <<<"$labels" | paste -sd' ')"
  echo "merges: $merge$([ "$merge" != rebase ] || echo " only"), branches deleted after merge"
  [ "$globs" = "[]" ] || echo "CODEOWNERS: owner for the protected zones $globs"
  echo "default branch: ruleset senior-mode$([ "$3" = true ] || echo ", no status check required (github.requiredChecks is false)")"
  echo "workflows: ci.mode $mode"
  echo "security: Dependabot alerts, secret scanning with push protection, Dependabot version updates"
  echo "dry run: nothing changed; senior-mode setup github does it"
}

setup_github() {
  local root file slug owner name owner_type owner_node private template project number id how fields labels label color description err ci="" globs checks review=false codeowner codeowners_owns=false reason
  local migrate=false dry=false upgrade=false made merge ctx scratch=""
  while [ $# -gt 0 ]; do
    case $1 in
      --ci) [ "${2:-}" = local ] || [ "${2:-}" = actions ] || [ "${2:-}" = existing ] || usage; ci=$2; shift 2 ;;
      --migrate) migrate=true; shift ;;
      --upgrade) upgrade=true; shift ;;
      --dry-run) dry=true; shift ;;
      *) usage ;;
    esac
  done
  [ "$upgrade" = false ] || { [ "$migrate" = false ] && [ -z "$ci" ]; } || usage
  root=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repository"
  file=$root/.claude/senior-mode.json
  if [ "$dry" = true ] && [ "$migrate" = false ] && [ "$upgrade" = false ] && [ ! -f "$file" ]; then
    file=$(mktemp)
    echo '{}' >"$file"
    scratch=$file
  else
    mkdir -p "$root/.claude"
    [ -f "$file" ] || echo '{}' >"$file"
  fi
  jq empty "$file" 2>/dev/null || die "invalid .claude/senior-mode.json; fix or remove it, then run setup again"
  if [ -n "$ci" ] && [ "$dry" = false ]; then
    { jq --arg m "$ci" '.ci.mode = $m' "$file" >"$file.tmp" && mv "$file.tmp" "$file"; } ||
      die "could not write .claude/senior-mode.json"
  fi
  slug=$(repo_slug) owner=${slug%%/*} name=${slug#*/}
  IFS='|' read -r owner_type owner_node private < <(gh_retry api "repos/$slug" \
    --jq '[.owner.type, .owner.node_id, (.private | tostring)] | join("|")') || die "cannot read $slug on GitHub"
  template=$(jq -r --argjson d "$DEFAULTS" '($d * .).board.template' "$file")
  # The Project only: no ruleset, label, repository setting or workflow, whatever github.requiredChecks says.
  if [ "$upgrade" = true ]; then
    setup_upgrade "$file" "$dry" "$owner"
    return 0
  fi
  checks=$(jq -r --argjson d "$DEFAULTS" '($d * .).github.requiredChecks | tojson' "$file")
  [ "$checks" = true ] || [ "$checks" = false ] || die "github.requiredChecks in .claude/senior-mode.json must be true or false"

  if [ "$migrate" = true ]; then
    setup_migrate "$file" "$dry"
    [ "$dry" = false ] || return 0
  fi
  if [ "$dry" = true ]; then
    setup_plan "$file" "$owner_type" "$checks" "$slug"
    [ -z "$scratch" ] || rm -f "$scratch"
    return 0
  fi
  project=$(setup_project "$file" "$owner" "$name" "$slug") || die "could not find or copy the Project"
  read -r number id how <<<"$project"
  setup_fields "$id"
  fields=$(board_fields "$id") || die "could not read the fields of Project #$number"
  cache_project "$file" "$owner" "$number" "$id" "$fields" false
  echo "Project #$number $name: linked, fields Status, Priority, Size, Severity, Paths; ids cached in .claude/senior-mode.json"
  setup_board_template "$id" "$how"
  setup_board_readme "$id" "$slug" "$(jq -r '.language // "en"' "$file")"
  setup_cycle "$id" "$file"
  setup_board_workflows "$id"

  labels=$LABELS
  [ "$owner_type" = Organization ] || labels+=$'\n'$TYPE_LABELS
  # The project's own labels that stand for ours (workflow.labels) are not created a second time.
  made=""
  while IFS='|' read -r label color description; do
    [ -n "$label" ] || continue
    ! jq -e --arg l "$label" '(.workflow.labels // {}) | has($l)' "$file" >/dev/null || continue
    gh_retry label create "$label" --repo "$slug" --color "$color" --description "$description" --force >/dev/null
    made+="${made:+ }$label"
  done <<<"$labels"
  echo "labels: $made"
  ! jq -e '(.workflow.labels // {}) | length > 0' "$file" >/dev/null ||
    echo "labels: the project's own stand for $(jq -r '.workflow.labels | keys | join(" ")' "$file"), not created"

  merge=$(jq -r '.workflow.merge // "rebase"' "$file")
  if [ "$merge" = rebase ]; then
    gh_retry repo edit "$slug" --enable-rebase-merge --enable-merge-commit=false --enable-squash-merge=false \
      --delete-branch-on-merge >/dev/null
    echo "merges: rebase only, branches deleted after merge"
  else
    # The project's method (workflow.merge): the other methods the repository allows are kept.
    gh_retry repo edit "$slug" "--enable-$merge-merge" --delete-branch-on-merge >/dev/null
    echo "merges: $merge enabled (the repository's other methods are kept), branches deleted after merge"
  fi

  globs=$(jq -c '.protected // []' "$file")
  jq -e 'type == "array" and all(type == "string")' <<<"$globs" >/dev/null ||
    die "protected in .claude/senior-mode.json must be an array of globs"
  codeowner=""
  if [ "$globs" != "[]" ]; then
    # A user owns their repository; an organization is no CODEOWNERS owner, the signed-in user is.
    codeowner=$owner
    [ "$owner_type" != Organization ] || codeowner=$(gh_retry api user --jq .login) || die "cannot read your GitHub login"
  fi
  setup_codeowners "$root" "$codeowner" "$globs" "$slug"
  if [ "$globs" != "[]" ]; then
    if reason=$(review_reason "$root" "$codeowners_owns" "$slug"); then
      review=true
      [ "$codeowners_owns" = true ] ||
        echo "code owners: code owner review stays required: $reason; setup never lowers an existing protection, and .github/CODEOWNERS owns no protected zone"
    else
      echo "code owners: code owner review is not required, no CODEOWNERS entry owns anything and the ruleset did not require it (a rule requiring it would wait for an approval nobody can give)"
    fi
  fi

  # Before the workflows: a refused ruleset forces ci.mode local, which decides what happens to them.
  if err=$(setup_ruleset "$slug" "$review" "$checks" "$file" 2>&1 >/dev/null); then
    setup_protection "$file" ruleset
    ctx="senior-mode/ci, senior-mode/review and senior-mode/security"
    jq -e '.ci.mode == "existing" and ((.workflow.ci.required // []) | length) > 0' "$file" >/dev/null &&
      ctx+=" next to $(jq -r '.workflow.ci.required | join(", ")' "$file")"
    if [ "$merge" != rebase ] && [ "$checks" = true ]; then
      echo "default branch: ruleset senior-mode, pull requests only, $merge merges, $ctx on an up-to-date branch, no linear history requirement; admins may bypass with gh pr merge --admin; other protection untouched"
    elif [ "$checks" = true ]; then
      echo "default branch: ruleset senior-mode, pull requests only, rebase, $ctx on an up-to-date branch, linear history; admins may bypass with gh pr merge --admin; other protection untouched"
    else
      echo "default branch: ruleset senior-mode, pull requests only, $merge merges$([ "$merge" != rebase ] || echo ", linear history"); github.requiredChecks is false, so it requires no status check (senior-mode/ci, senior-mode/review and senior-mode/security are not required, and a required_status_checks rule it had is removed); admins may bypass with gh pr merge --admin; other protection untouched"
    fi
    [ "$review" = false ] || echo "code owners: a pull request touching a protected zone needs the owner's approval, and GitHub never lets an author approve their own pull request; agents act as the owner (#175 gives them an identity of their own), so merging one is the owner's call by hand, with gh pr merge --admin"
  elif ruleset_refused <<<"$err"; then
    setup_protection "$file" local
    setup_audit "$root"
  else
    die "ruleset on the default branch: $err"
  fi

  setup_workflows "$slug" "$(jq -r '.ci.mode // "local"' "$file")"
  setup_security "$root" "$slug"
}

# Writes `jq <filter> <file>` back to the file only when the JSON changes, so a file without real
# change keeps its formatting. Extra arguments go to jq.
json_update() {
  local file=$1 filter=$2 new
  shift 2
  new=$(jq "$@" "$filter" "$file") || return 1
  [ "$(jq -S . <<<"$new")" = "$(jq -S . "$file")" ] && return 2
  printf '%s\n' "$new" >"$file"
}

# Copies a template where nothing exists yet; never replaces a file. Prints what it did. A template that the
# project overrides (.claude/senior-mode/overrides/templates/..., #307) is written with its override applied.
place() { # template destination label
  local rel
  if [ -e "$2" ]; then echo "$3: kept"; return; fi
  mkdir -p "$(dirname "$2")"
  if rel=$(override_rel "$1") && override_has "$rel"; then
    override_content "$rel" >"$2"
    echo "$3: created (with the project's override)"
  else
    cp "$1" "$2"
    echo "$3: created"
  fi
}

# Installs or refreshes one of our scripts in .githooks/ (marked "# senior-mode:" on its second
# line); a file of the project's own with that name is kept.
githooks_install() { # root source label [name]
  local dest
  dest=$1/.githooks/${4:-$(basename "$2")}
  if [ -e "$dest" ] && ! grep -q '^# senior-mode:' "$dest"; then
    echo "$3: yours kept"
  elif ! cmp -s "$2" "$dest" || [ ! -x "$dest" ]; then
    mkdir -p "$1/.githooks"
    cp "$2" "$dest"
    chmod +x "$dest"
    echo "$3: installed"
  fi
}

# Whether the project has issue forms or templates of its own: a file in .github/ISSUE_TEMPLATE/ or an
# ISSUE_TEMPLATE.md that is not one of senior-mode's (never replaced, so a rerun still counts ours as ours).
setup_own_issue_templates() { # root templates
  local f t ours
  for f in "$1"/.github/ISSUE_TEMPLATE/* "$1"/.github/ISSUE_TEMPLATE.md "$1"/ISSUE_TEMPLATE.md; do
    [ -f "$f" ] || continue
    ours=false
    for t in "$2"/*/ISSUE_TEMPLATE/*.yml; do ! cmp -s "$f" "$t" || ours=true; done
    [ "$ours" = true ] || return 0
  done
  return 1
}

# Installs or refreshes the senior-mode git hooks; a hook of the project's own is kept. $3 is what owns the project's
# commit-msg hook when it is not ours (workflow_hook_owner): ours is then installed as `commit-subjects`, a script
# the `commit subjects` check runs, and core.hooksPath is not taken over.
setup_githooks() { # root templates [owner]
  local root=$1 tpl=$2 owner=${3:-} hook path
  for hook in commit-msg pre-push; do
    if [ "$hook" = commit-msg ] && [ -n "$owner" ]; then
      echo "git hook commit-msg: yours kept ($owner)"
      githooks_install "$root" "$tpl/githooks/commit-msg" "git hook commit-subjects" commit-subjects
    else
      githooks_install "$root" "$tpl/githooks/$hook" "git hook $hook"
    fi
  done
  path=$(git -C "$root" config core.hooksPath || true)
  if [ -n "${WF_ADOPTING:-}" ]; then
    echo "git hooks: wired by a later setup repo, once the adoption pull request is merged"
  elif [ -z "$path" ] && [ -n "$owner" ]; then
    echo "git hooks: core.hooksPath left alone ($owner owns the hooks); call .githooks/pre-push from there"
  elif [ -z "$path" ]; then
    git -C "$root" config core.hooksPath .githooks
  elif [ "$path" != .githooks ]; then
    echo "git hooks: core.hooksPath is $path; call .githooks/commit-msg and .githooks/pre-push from there"
  fi
}

# The project memory of the agents (`memory: project`) is written in the checkout the session runs in,
# never in a pull request: it stays on the machine, so git ignores it and the tree stays clean.
setup_gitignore() {
  local root=$1 ignore=$1/.gitignore
  git -C "$root" check-ignore -q .claude/agent-memory/x.md && return 0
  [ ! -s "$ignore" ] || [ -z "$(tail -c1 "$ignore")" ] || echo >>"$ignore"
  echo ".claude/agent-memory/" >>"$ignore"
  echo ".gitignore: .claude/agent-memory/ ignored (agent memory stays on the machine)"
}

# Adds the Principles block to CLAUDE.md, or refreshes it; a missing CLAUDE.md imports AGENTS.md when
# there is one, else starts from the skeleton that the setup skill fills from the code.
setup_claude_md() {
  local root=$1 tpl=$2 name=$3 claude=$1/CLAUDE.md block=$2/principles.md skeleton new lines
  if [ ! -e "$claude" ] && [ -f "$root/AGENTS.md" ]; then
    # The repository already has agent instructions (frameworks scaffold AGENTS.md): point to them.
    printf '# %s\n\n@AGENTS.md\n\n' "$name" >"$claude"
    cat "$block" >>"$claude"
    echo "CLAUDE.md: created, it imports the existing AGENTS.md, the skeleton is not needed"
  elif [ ! -e "$claude" ]; then
    skeleton=$(cat "$tpl/CLAUDE.md")
    # Split around the one placeholder: a pattern substitution would read & in the name (bash 5.2).
    { printf '%s\n\n' "${skeleton%%\{\{name\}\}*}$name${skeleton#*\{\{name\}\}}"; cat "$block"; } >"$claude"
    echo "CLAUDE.md: created from the skeleton; commands, code map and pitfalls to fill"
  elif ! grep -qE '^<!-- /?senior-mode:principles' "$claude"; then
    { echo; cat "$block"; } >>"$claude"
    echo "CLAUDE.md: Principles added, the rest kept"
  # One opening marker, then one closing marker, else awk refuses and the file is left alone.
  elif ! new=$(awk -v f="$block" '
      /^<!-- senior-mode:principles/ { if (seen++) bad = 1; while ((getline l < f) > 0) print l; close(f); skip = 1; next }
      /^<!-- \/senior-mode:principles -->/ { if (!skip) bad = 1; skip = 0; next }
      !skip { print } END { exit (bad || skip) }' "$claude"); then
    echo "CLAUDE.md: Principles markers broken, file left untouched; restore one opening and one closing marker"
  elif [ "$new" != "$(cat "$claude")" ]; then
    # Written in place, so a symlinked CLAUDE.md and its mode survive.
    printf '%s\n' "$new" >"$claude"
    echo "CLAUDE.md: Principles refreshed"
  fi
  lines=$(wc -l <"$claude")
  [ "$lines" -le 80 ] || echo "CLAUDE.md: $lines lines, over 80; trim it to what the code does not tell"
}

# Commands of a package.json project (spec 0001 §14, #13, #42): its scripts, run by the package
# manager of its lockfile; tsc --noEmit when a tsconfig has no typecheck script and typescript is a
# dependency (npx would otherwise fetch the unrelated "tsc" package), run without ever downloading;
# npm's placeholder test script is no test. Its install command is the lockfile's, frozen (npm install
# without one). Prints {commands, framework, typescript}.
# The package manager of the node project at $1, its binary runner and its install command, tab separated.
node_pm() {
  local root=$1 pm=npm exec="npx --no --" install="npm install"
  if [ -f "$root/pnpm-lock.yaml" ]; then pm=pnpm exec="pnpm exec" install="pnpm install --frozen-lockfile"
  elif [ -f "$root/yarn.lock" ]; then
    pm=yarn exec=yarn install="yarn install --frozen-lockfile"
    # Yarn 2 and later (a .yarnrc.yml) says --immutable.
    [ ! -f "$root/.yarnrc.yml" ] || install="yarn install --immutable"
  elif [ -f "$root/bun.lock" ] || [ -f "$root/bun.lockb" ]; then pm=bun exec="bun run" install="bun install --frozen-lockfile"
  elif [ -f "$root/package-lock.json" ]; then install="npm ci"
  fi
  printf '%s\t%s\t%s\n' "$pm" "$exec" "$install"
}

# shellcheck disable=SC2016 # jq program, not shell
node_detect() { # root [workspace-root]: the package manager is the one of the workspace root, its lockfile lives there
  # exec runs an installed binary only: npx and bunx would download a missing one.
  local root=$1 pm exec install tsconfig=false
  IFS=$'\t' read -r pm exec install < <(node_pm "${2:-$root}")
  [ ! -f "$root/tsconfig.json" ] || tsconfig=true
  jq -c --arg pm "$pm" --arg exec "$exec" --arg install "$install" --argjson tsconfig "$tsconfig" '(.scripts // {}) as $s
    | def run($n): if $s[$n] then "\($pm) run \($n)" else null end;
    ((.dependencies.typescript // .devDependencies.typescript) != null) as $ts
    # Next.js 15.5+ generates its route types only on build or dev: a fresh worktree needs
    # next typegen before typecheck (#112). A range without a version (latest, canary) is recent.
    | (.dependencies.next // .devDependencies.next) as $next
    | ($next != null and (($next | [scan("[0-9]+")]) as $n
        | if ($next | test("^[~^>=v ]*[0-9]")) then ($n[0] | tonumber) > 15
            or (($n[0] | tonumber) == 15 and (($n[1] // "0") | tonumber) >= 5)
          else true end)) as $typegen
    | {commands: ({
        lint: run("lint"),
        typecheck: ((run("typecheck") // run("type-check")
          // (if $tsconfig and $ts then "\($exec) tsc --noEmit" else null end))
          | if . and $typegen and (($s.typecheck // $s["type-check"] // "") | contains("typegen") | not)
            then "\($exec) next typegen && \(.)" else . end),
        test: (if ($s.test // "") | test("no test specified") then null else run("test") end),
        build: run("build"),
        e2e: (run("test:e2e") // run("e2e")),
        install: $install
      } | with_entries(select(.value != null))),
      framework: (if (.dependencies.next // .devDependencies.next) then "next" else null end),
      typescript: ($ts or $tsconfig)}' \
    "$root/package.json"
}

# The preset of a project that has no package.json and no stored preset (spec 0001 §14): the
# manifests that name one language first, then Python's files (a requirements.txt is common anywhere).
other_preset() {
  local root=$1 f
  [ ! -f "$root/go.mod" ] || { echo go; return; }
  [ ! -f "$root/Cargo.toml" ] || { echo rust; return; }
  for f in pyproject.toml setup.py requirements.txt; do
    [ ! -f "$root/$f" ] || { echo python; return; }
  done
  echo generic
}

# Whether a Python project uses a tool: a config file of its own, or its name as a word in the
# manifests (pytest-cov is not pytest).
py_uses() { # root tool [config-file...]
  local root=$1 tool=$2 f
  shift 2
  for f in "$@"; do [ ! -f "$root/$f" ] || return 0; done
  for f in "$root"/pyproject.toml "$root"/setup.cfg "$root"/setup.py "$root"/tox.ini "$root"/Pipfile "$root"/requirements*.txt; do
    if [ -f "$f" ] && grep -qiE "(^|[^A-Za-z0-9_-])$tool([^A-Za-z0-9_-]|\$)" "$f"; then return 0; fi
  done
  return 1
}

# Commands of a Python project (spec 0001 §14, #72): the tools it uses, run through uv or poetry
# when their lockfile exists. Ruff before flake8; black's format check before ruff's, as black is only
# named by projects that format with it; mypy before pyright; build when pyproject.toml has a
# build-system. Its install command is `uv sync` or `poetry install` with their lockfile, else none.
# Prints {commands}.
# shellcheck disable=SC2016 # jq program, not shell
python_detect() {
  local root=$1 run="" install="" lint="" format="" typecheck="" test="" build=""
  if [ -f "$root/uv.lock" ]; then run="uv run " install="uv sync"
  elif [ -f "$root/poetry.lock" ]; then run="poetry run " install="poetry install"
  fi
  if py_uses "$root" ruff ruff.toml .ruff.toml; then lint="${run}ruff check ."
  elif py_uses "$root" flake8 .flake8; then lint="${run}flake8"
  fi
  if py_uses "$root" black; then format="${run}black --check ."
  elif py_uses "$root" ruff ruff.toml .ruff.toml; then format="${run}ruff format --check ."
  fi
  if py_uses "$root" mypy mypy.ini .mypy.ini; then typecheck="${run}mypy ."
  elif py_uses "$root" pyright pyrightconfig.json; then typecheck="${run}pyright"
  fi
  ! py_uses "$root" pytest pytest.ini conftest.py || test="${run}pytest"
  ! grep -qs '^\[build-system\]' "$root/pyproject.toml" || build="${run}python -m build"
  jq -nc --arg lint "$lint" --arg format "$format" --arg typecheck "$typecheck" --arg test "$test" \
    --arg build "$build" --arg install "$install" '{commands: ({lint: $lint, format: $format, typecheck: $typecheck,
      test: $test, build: $build, install: $install} | with_entries(select(.value != "")))}'
}

# Commands of a Go module (spec 0001 §14, #72): vet, joined by golangci-lint when its config exists,
# then test and build over every package; its install command downloads the modules. Prints {commands}.
go_detect() {
  local root=$1 lint="go vet ./..." f
  for f in "$root"/.golangci.yml "$root"/.golangci.yaml "$root"/.golangci.toml "$root"/.golangci.json; do
    [ ! -f "$f" ] || lint="go vet ./... && golangci-lint run"
  done
  jq -nc --arg lint "$lint" '{commands: {lint: $lint, test: "go test ./...", build: "go build ./...",
    install: "go mod download"}}'
}

# Commands of a Cargo project (spec 0001 §14, #72): clippy denying warnings, rustfmt in check mode,
# test and build; its install command fetches the crates. Prints {commands}.
rust_detect() {
  jq -nc '{commands: {lint: "cargo clippy --all-targets -- -D warnings", format: "cargo fmt --check",
    test: "cargo test", build: "cargo build", install: "cargo fetch"}}'
}

# The preset of a project: the stored one (typescript, its former name, is node), else node when a
# package.json exists, else the one of its manifest (go, rust, python), else generic.
project_preset() {
  local root=$1 pname=""
  [ ! -f "$root/.claude/senior-mode.json" ] || pname=$(jq -r '.preset // empty' "$root/.claude/senior-mode.json" 2>/dev/null) || true
  [ "$pname" != typescript ] || pname=node
  if [ -n "$pname" ]; then :
  elif [ -f "$root/package.json" ]; then pname=node
  else pname=$(other_preset "$root")
  fi
  printf '%s\n' "$pname"
}

# What the preset $2 detects in the project at $1, as JSON ({} for a preset that detects nothing).
preset_detect() {
  case $2 in
    node) node_detect "$1" ;;
    python) python_detect "$1" ;;
    go) go_detect "$1" ;;
    rust) rust_detect ;;
    *) echo '{}' ;;
  esac
}

# The language server of a preset and the plugin that enables it in Claude Code (#341), as
# `<server>|<install of the server>|<plugin>`; nothing for generic. Setup prints it and installs nothing.
lsp_server() { # preset
  case $1 in
    node) echo 'typescript-language-server|npm install -g typescript typescript-language-server|typescript-lsp' ;;
    python) echo 'pyright|npm install -g pyright|pyright-lsp' ;;
    go) echo 'gopls|go install golang.org/x/tools/gopls@latest|gopls-lsp' ;;
    rust) echo 'rust-analyzer|rustup component add rust-analyzer|rust-analyzer-lsp' ;;
  esac
}

# The proposal of the language server of the stack, unless the owner answered (`lsp` in the config at $2, any value).
lsp_propose() { # preset config-file
  local line server rest
  line=$(lsp_server "$1")
  [ -n "$line" ] || return 0
  ! jq -e 'has("lsp")' "$2" >/dev/null 2>&1 || return 0
  server=${line%%|*} rest=${line#*|}
  echo "lsp: the language server for $1 is $server (on your PATH: ${rest%%|*})"
  echo "lsp: enable it in Claude Code with: claude plugin install ${rest#*|}@claude-plugins-official"
  echo "lsp: nothing was installed; answer with senior-mode setup answers --lsp yes (you enable it) or no (not proposed again)"
}

# The changed variant (#339) a preset gives the check $3 (lint or test) of the project at $1 when its command $4 is
# the one the preset detected: `<regex of the files it takes><TAB><command with {files}>`, nothing when the preset
# has none for it (the check then runs in full). node narrows to the files through the linter and the test runner
# its dependencies name (eslint or biome; vitest or jest, which find the tests that import the files), python
# through ruff or flake8 and pytest (a run that collects nothing is not a failure), go and rust through the
# packages and the crates the files belong to.
# shellcheck disable=SC2016 # commands for a shell, not this one
preset_changed() {
  local root=$1 preset=$2 name=$3 run=$4 pm exec deps pkgs crates
  pkgs='P=$(printf '"'"'%s\n'"'"' {files} | xargs -n1 dirname | sort -u | sed '"'"'s|^|./|'"'"'); '
  crates='for d in $(for f in {files}; do d=$(dirname "$f"); while [ ! -f "$d/Cargo.toml" ] && [ "$d" != . ]; do d=$(dirname "$d"); done; echo "$d"; done | sort -u); do '
  case $preset in
    node)
      IFS=$'\t' read -r pm exec _ < <(node_pm "$root")
      [ "$run" = "$pm run $name" ] && [ -f "$root/package.json" ] || return 0
      deps=" $(jq -r '[(.dependencies // {}), (.devDependencies // {}) | keys[]] | join(" ")' "$root/package.json") "
      case $name in
        lint)
          if [[ $deps == *" @biomejs/biome "* ]]; then printf '%s\t%s\n' '\.[cm]?[jt]sx?$' "$exec biome check {files}"
          elif [[ $deps == *" eslint "* ]]; then printf '%s\t%s\n' '\.[cm]?[jt]sx?$' "$exec eslint {files}"
          fi
          ;;
        test)
          if [[ $deps == *" vitest "* ]]; then printf '%s\t%s\n' '\.[cm]?[jt]sx?$' "$exec vitest related --run {files}"
          elif [[ $deps == *" jest "* ]]; then printf '%s\t%s\n' '\.[cm]?[jt]sx?$' "$exec jest --findRelatedTests {files}"
          fi
          ;;
      esac
      ;;
    python)
      case $name:$run in
        lint:*"ruff check .") printf '%s\t%s\n' '\.pyi?$' "${run% .} {files}" ;;
        lint:*flake8) printf '%s\t%s\n' '\.pyi?$' "$run {files}" ;;
        test:*pytest) printf '%s\t%s\n' '\.pyi?$' "$run {files} || [ \$? -eq 5 ]" ;;
      esac
      ;;
    go)
      case $name:$run in
        lint:"go vet ./...") printf '%s\t%s\n' '\.go$' "${pkgs}go vet \$P" ;;
        lint:"go vet ./... && golangci-lint run") printf '%s\t%s\n' '\.go$' "${pkgs}go vet \$P && golangci-lint run \$P" ;;
        test:"go test ./...") printf '%s\t%s\n' '\.go$' "${pkgs}go test \$P" ;;
      esac
      ;;
    rust)
      case $name:$run in
        lint:"cargo clippy --all-targets -- -D warnings")
          printf '%s\t%s\n' '\.(rs|toml)$' "${crates}cargo clippy --manifest-path \"\$d/Cargo.toml\" --all-targets -- -D warnings || exit 1; done" ;;
        test:"cargo test") printf '%s\t%s\n' '\.(rs|toml)$' "${crates}cargo test --manifest-path \"\$d/Cargo.toml\" || exit 1; done" ;;
      esac
      ;;
  esac
}

# The command that installs the dependencies of the project at $1 (#110): `commands.install` of its
# config, else the one its preset detects; empty when it has none.
install_command() {
  local root=$1 cmd=""
  [ ! -f "$root/.claude/senior-mode.json" ] || cmd=$(jq -r '.commands.install // empty' "$root/.claude/senior-mode.json" 2>/dev/null) || true
  [ -n "$cmd" ] || cmd=$(preset_detect "$root" "$(project_preset "$root")" 2>/dev/null | jq -r '.commands.install // empty') || true
  printf '%s\n' "$cmd"
}

# Whether the node project at $1 declares dependencies and has no node_modules (nor Yarn's Plug'n'Play).
deps_missing() {
  [ "$(project_preset "$1")" = node ] && [ -f "$1/package.json" ] && [ ! -d "$1/node_modules" ] && [ ! -e "$1/.pnp.cjs" ] &&
    jq -e '((.dependencies // {}) + (.devDependencies // {}) | length) > 0' "$1/package.json" >/dev/null 2>&1
}

# The static x.y.z version of a TOML table (the first of the tables given that has one), or 0.0.0.
toml_version() {
  local v
  v=$(awk -v tables="$2 ${3:-}" 'BEGIN { n = split(tables, t, " ") }
    /^\[/ { s = $0; sub(/[ \t]*#.*/, "", s); gsub(/[][ \t]/, "", s); on = 0; for (i = 1; i <= n; i++) if (s == t[i]) on = 1; next }
    on && /^version[ \t]*=[ \t]*"/ { match($0, /"[^"]*"/); print substr($0, RSTART + 1, RLENGTH - 2); exit }' "$1")
  [[ $v =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && printf '%s\n' "$v" || printf '0.0.0\n'
}

# The documents and checks of a project (spec 0001 §12, §14, #12), idempotent; whatever the project
# already has is extended, never replaced. The preset is the stored one (typescript, its former name,
# becomes node), else node when a package.json exists, else the one of its manifest (go, rust, python),
# else generic. `--command <name>=<command>` stores a command of the preset (lint, format, typecheck,
# test, build; e2e for node) and derives its check; `--command install=<command>` stores the command that
# installs the dependencies of a new worktree, which has no check.
# shellcheck disable=SC2016 # jq programs, not shell
setup_repo() {
  if [[ " $* " == *" --knowledge "* ]]; then
    local arg rest=()
    for arg in "$@"; do [ "$arg" = --knowledge ] || rest+=("$arg"); done
    setup_knowledge ${rest[@]+"${rest[@]}"}
    return
  fi
  local root file tpl pname preset lang name commands='{}' detected pkgs out ours guard owner subjects="" cmdmap dry=false adopt=false fwd=() fmt
  root=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repository"
  file=$root/.claude/senior-mode.json
  tpl=$(cd "$(dirname "$SELF")/.." && pwd)
  # A preset stored earlier wins over detection.
  pname=$(project_preset "$root")
  preset=$tpl/presets/$pname/preset.json
  [ -f "$preset" ] || die "unknown preset $pname in .claude/senior-mode.json"
  detected=$(preset_detect "$root" "$pname") || die "could not read package.json"
  pkgs=$(packages_detect "$root")
  tpl=$tpl/templates
  while [ $# -gt 0 ]; do
    case $1 in
      --dry-run) dry=true; shift; continue ;;
      --adopt) adopt=true; shift; continue ;;
    esac
    [ "$1" = --command ] && [[ ${2:-} == ?*=?* ]] || usage
    jq -e --arg k "${2%%=*}" '.commands + ["install"] | index($k)' "$preset" >/dev/null ||
      die "unknown command ${2%%=*}; expected one of $(jq -r '.commands + ["install"] | join(", ")' "$preset")"
    commands=$(jq -c --arg k "${2%%=*}" --arg v "${2#*=}" '.[$k] = $v' <<<"$commands")
    fwd+=("$1" "$2")
    shift 2
  done
  [ "$dry" = false ] || [ "$adopt" = false ] || usage
  [ ! -f "$file" ] || jq empty "$file" 2>/dev/null || die "invalid .claude/senior-mode.json; fix or remove it, then run setup again"
  # What the project already does (spec 409): read first, nothing written yet.
  cmdmap='{}'
  [ ! -f "$file" ] || cmdmap=$(jq -c '.commands // {}' "$file")
  cmdmap=$(jq -nc --argjson d "$detected" --argjson e "$cmdmap" --argjson c "$commands" '($d.commands // {}) + $e + $c')
  [ -n "${WF_DONE:-}" ] || workflow_detect "$root" "$cmdmap" "$tpl"
  if [ "$dry" = true ] || [ "$adopt" = true ]; then
    local cur=$file
    [ -f "$cur" ] || { cur=$(mktemp); echo '{}' >"$cur"; }
    workflow_settle "$cur"
    workflow_say
    if [ "$dry" = true ]; then
      echo
      echo "config: would write"
      workflow_merged "$cur" | jq '{workflow, adopt, ci}' | jq 'with_entries(select(.value != null))'
      [ "$cur" = "$file" ] || rm -f "$cur"
      echo "dry run: nothing changed"
      return 0
    fi
    [ "$cur" = "$file" ] || rm -f "$cur"
    workflow_adopt_pr "$root" "$(workflow_report)" ${fwd[@]+"${fwd[@]}"}
    return 0
  fi
  mkdir -p "$root/.claude"
  [ -f "$file" ] || echo '{}' >"$file"
  lang=$(jq -r '.language // "en"' "$file")
  [ -d "$tpl/$lang" ] || lang=en
  name=$(basename "$root")

  owner=$(workflow_hook_owner "$root")
  setup_githooks "$root" "$tpl" "$owner"
  # The environment guard: only when envGuard.forbidden lists something. The check stays when the
  # key is removed later, and then reports itself skipped.
  guard=false
  jq -e '(.envGuard.forbidden // []) | type == "array" and all(type == "string")' "$file" >/dev/null ||
    die "envGuard.forbidden in .claude/senior-mode.json must be a list of strings"
  if jq -e '(.envGuard.forbidden // []) | length > 0' "$file" >/dev/null; then
    guard=true
    githooks_install "$root" "$tpl/githooks/env-guard.sh" "check script env-guard.sh"
  fi
  # The commit subjects check runs our commit-msg hook; a project's own hook may not understand it.
  ours=false
  ! grep -q '^# senior-mode:' "$root/.githooks/commit-msg" 2>/dev/null || ours=true
  [ -z "$owner" ] || { ours=false; subjects=".githooks/commit-subjects --branch"; }
  out=0
  json_update "$file" '(if has("$schema") then . else {"$schema": $sch} + . end)
    | .preset = $pn | .commands = ($d.commands // {}) + (.commands // {}) + $c
    | if $d.framework then .framework = $d.framework else . end
    | if ($pk | length) > 0 then .packages = ((.packages // {}) as $e
        | reduce ($pk | keys[]) as $k ($e; .[$k] = (($e[$k] // {}) + {preset: ($e[$k].preset // $pk[$k].preset),
            commands: ($pk[$k].commands + ($e[$k].commands // {})), deps: $pk[$k].deps})))
      else . end
    | .commands as $all
    | ($p[0].commands | map(select($all[.] != null) | {name: ., run: $all[.]})) as $derived
    | ($derived + (if $ours then $p[0].checks else [] end)
        + (if $guard then [{name: "env guard", run: ".githooks/env-guard.sh"}] else [] end)) as $want
    | .checks = ((.checks // []) as $have
      | [$have[] | if $c[.name] then .run = $c[.name] else . end]
        + [$want[] | select(.name as $n | $have | any(.name == $n) | not)])
    | if has("protected") then .
      else (($p[0].protected // []) + ($p[0].frameworks[.framework // ""].protected // [])) as $g
        | if ($g | length) > 0 then .protected = $g else . end end' \
    --argjson c "$commands" --argjson ours "$ours" --arg sub "$subjects" --argjson guard "$guard" --slurpfile p "$preset" --arg pn "$pname" \
    --argjson d "$detected" --argjson pk "$pkgs" --arg sch "$CONFIG_SCHEMA_URL" || out=$?
  [ "$out" -ne 1 ] || die "could not write .claude/senior-mode.json"
  echo "preset: $pname$(jq -r --argjson d "$detected" '[if $d.typescript == true then "TypeScript"
    elif $d.typescript == false then "JavaScript" else empty end, .framework // empty]
    | select(length > 0) | " (\(join(", ")))"' "$file")"
  echo "checks: $(jq -r '[.checks[].name] | join(", ")' "$file")"
  [ "$pkgs" = '{}' ] || echo "packages: $(jq -r 'keys | join(", ")' <<<"$pkgs")"
  if [ -z "${WF_DONE:-}" ] || [ -n "${WF_ADOPTING:-}" ]; then
    workflow_settle "$file"
    workflow_write "$file"
    workflow_say
  fi
  deploy_apply "$root"
  fmt=$(jq -r '.workflow.commit.format // empty' "$file")
  # On a first setup `setup github` ran before `protected` existed: no block was written yet.
  ! jq -e '(.protected // []) | length > 0' "$file" >/dev/null || grep -qs '^# senior-mode:begin' "$root/.github/CODEOWNERS" ||
    echo "CODEOWNERS: the protected zones are not owned yet; rerun senior-mode setup github to write .github/CODEOWNERS"
  # The vision is the owner's (#342): a glob of `protected` keeps agent sessions from editing it.
  [ -n "$(protected_match "$(jq -c '.protected // []' "$file")" <<<"docs/vision.md")" ] ||
    echo "docs/vision.md: add it to protected in .claude/senior-mode.json, so that agent sessions cannot edit the goals and non-goals"
  [ "$pname" != node ] || jq -r --argjson d "$detected" '["lint", "typecheck", "test", "build"] - (.commands | keys)
    - (if $d.typescript then [] else ["typecheck"] end)
    | select(length > 0) | "missing: \(join(", ")) (no script; propose tools, never install without a yes)"' "$file"
  lsp_propose "$pname" "$file"

  setup_claude_md "$root" "$tpl/$lang" "$name"
  setup_gitignore "$root"
  if [ -n "$(find "$root" "$root/.github" "$root/docs" -maxdepth 1 -iname 'pull_request_template*' 2>/dev/null)" ]; then
    echo "pull request template: kept"
  else
    place "$tpl/$lang/pull_request_template.md" "$root/.github/pull_request_template.md" "pull request template"
  fi
  if setup_own_issue_templates "$root" "$tpl"; then
    echo "issue forms: the project's own are kept, senior-mode writes none"
  else
    place "$tpl/$lang/ISSUE_TEMPLATE/feature.yml" "$root/.github/ISSUE_TEMPLATE/feature.yml" "issue form feature"
    place "$tpl/$lang/ISSUE_TEMPLATE/bug.yml" "$root/.github/ISSUE_TEMPLATE/bug.yml" "issue form bug"
  fi
  # The system overview the docs skill keeps current (spec 0001 §8); never overwritten.
  place "$tpl/$lang/architecture.md" "$root/docs/architecture.md" "docs/architecture.md"
  # Other workflows are left as they are; local mode disables them on GitHub (setup github).
  [ "$(jq -r '.ci.mode // "local"' "$file")" != actions ] ||
    place "$tpl/workflows/senior-mode.yml" "$root/.github/workflows/senior-mode.yml" "workflow senior-mode.yml"

  [ -f "$root/.claude/settings.json" ] || echo '{}' >"$root/.claude/settings.json"
  out=0
  json_update "$root/.claude/settings.json" 'def add($xs): reduce $xs[] as $x (. // []; if index([$x]) then . else . + [$x] end);
    .permissions.allow |= add($s[0].permissions.allow) | .permissions.deny |= add($s[0].permissions.deny)' \
    --slurpfile s "$tpl/settings.json" || out=$?
  [ "$out" -ne 1 ] || die "could not update .claude/settings.json"
  [ "$out" -ne 0 ] || echo "settings: senior-mode permissions added to .claude/settings.json"

  if [ "$fmt" = free ]; then
    echo "releases: commits are free-form, so no release-please configuration is written"
  elif [ ! -e "$root/release-please-config.json" ]; then
    # Without a previous release, release-please would start at 1.0.0: a new project starts at 0.1.0.
    # A package.json version counts as the last release, so the manifest holds it and the next
    # release bumps it (initial-version would publish it again).
    local last=0.0.0 from=package.json
    if [ -f "$root/package.json" ]; then
      last=$(jq -r '.version // "0.0.0"' "$root/package.json" 2>/dev/null) || last=0.0.0
    elif [ -f "$root/Cargo.toml" ]; then
      from=Cargo.toml
      last=$(toml_version "$root/Cargo.toml" package)
    elif [ -f "$root/pyproject.toml" ]; then
      from=pyproject.toml
      last=$(toml_version "$root/pyproject.toml" project tool.poetry)
    fi
    if [ "$pname" = go ] && [ "$last" = 0.0.0 ]; then
      from="git tag"
      last=$(git -C "$root" tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname 2>/dev/null |
        grep -E -m1 '^v[0-9]+\.[0-9]+\.[0-9]+$' | sed 's/^v//') || true
      last=${last:-0.0.0}
    fi
    jq --arg n "$name" '.release | .packages["."] += {component: $n, "initial-version": "0.1.0"}' \
      "$preset" >"$root/release-please-config.json"
    if [ ! -e "$root/.release-please-manifest.json" ]; then
      jq -n --arg v "$last" '{".": $v}' >"$root/.release-please-manifest.json"
      if [ "$last" != 0.0.0 ] && [ -z "$(git -C "$root" tag --list)" ]; then
        echo "releases: first release follows $last ($from)$([ "$last" != 1.0.0 ] ||
          echo '; to start at 0.1.0, set "." to "0.0.0" in .release-please-manifest.json')"
      fi
    fi
    echo "releases: release-please configured"
  fi
  echo "secrets: keep only dev-only secrets on a machine where agents run; the secrets guard stops honest mistakes, not a determined reader"
}
