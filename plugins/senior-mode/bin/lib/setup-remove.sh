# shellcheck shell=bash
# `setup remove` (#300): takes senior-mode out of a repository, the way `setup github` and `setup repo` put it in. A dry
# run by default; --apply does it. The Project and the issues stay (history).

# Says what a step did ($1 true) or would do ($1 false).
remove_say() { # apply what
  if [ "$1" = true ]; then echo "removed: $2"; else echo "would remove: $2"; fi
}

# Removes the file $2 of the tree $1 when it exists.
remove_file() { # root file apply
  [ -e "$1/$2" ] || return 0
  [ "$3" != true ] || rm -f "$1/$2"
  remove_say "$3" "$2"
}

# Takes out of the file $2 of the tree $1 the lines from one matching the regex $3 to one matching $4; the file
# goes when nothing else is left. Markers that are not exactly one opening then one closing leave the file alone.
remove_block() { # root file begin end apply
  local path=$1/$2 new
  [ -f "$path" ] && grep -qE "$3" "$path" || return 0
  if ! new=$(awk -v b="$3" -v e="$4" '$0 ~ b { if (seen++) bad = 1; skip = 1; next }
      $0 ~ e { if (!skip) bad = 1; skip = 0; next }
      !skip { print } END { exit (bad || skip) }' "$path"); then
    echo "kept: $2 (senior-mode markers broken; take its block out by hand)"
    return 0
  fi
  if [ -z "${new//[[:space:]]/}" ]; then
    remove_file "$1" "$2" "$5"
    return 0
  fi
  [ "$5" != true ] || printf '%s\n' "$new" >"$path"
  remove_say "$5" "the senior-mode block of $2"
}

# What setup left in the files of the tree $1: removed (apply true) or listed. Edited documents and the release files stay.
# shellcheck disable=SC2016 # a jq program, not shell
remove_files() { # root apply
  local root=$1 apply=$2 tpl f path same lang new
  tpl=$(cd "$(dirname "$SELF")/.." && pwd)/templates
  for f in commit-msg commit-subjects pre-push env-guard.sh; do
    [ -f "$root/.githooks/$f" ] || continue
    if grep -q '^# senior-mode:' "$root/.githooks/$f"; then remove_file "$root" ".githooks/$f" "$apply"
    else echo "kept: .githooks/$f (yours)"
    fi
  done
  # Documents copied from a template: removed while they are still that template, kept once someone edited them.
  for f in .github/pull_request_template.md:pull_request_template.md .github/ISSUE_TEMPLATE/feature.yml:ISSUE_TEMPLATE/feature.yml \
    .github/ISSUE_TEMPLATE/bug.yml:ISSUE_TEMPLATE/bug.yml docs/architecture.md:architecture.md; do
    path=${f%%:*}
    [ -f "$root/$path" ] || continue
    same=false
    for lang in en fr; do ! cmp -s "$root/$path" "$tpl/$lang/${f#*:}" || same=true; done
    if [ "$same" = true ]; then remove_file "$root" "$path" "$apply"
    else echo "kept: $path (edited since setup, or not senior-mode's)"
    fi
  done
  deploy_restore "$root" "$apply" true
  remove_file "$root" .github/workflows/senior-mode.yml "$apply"
  remove_file "$root" .github/workflows/senior-mode-audit.yml "$apply"
  remove_block "$root" CLAUDE.md '^<!-- senior-mode:principles' '^<!-- /senior-mode:principles -->' "$apply"
  remove_block "$root" .github/CODEOWNERS '^# senior-mode:begin' '^# senior-mode:end' "$apply"
  # The permissions of templates/settings.json and the status line of senior-mode; the rest of the file stays.
  path=$root/.claude/settings.json
  if [ -f "$path" ]; then
    if new=$(jq --slurpfile s "$tpl/settings.json" 'def drop($xs): map(select(. as $x | ($xs | index([$x])) == null));
        del(.statusLine | select((.command // "") | contains("senior-mode")))
        | if .permissions then
            .permissions |= (with_entries(if .key == "allow" or .key == "deny" then (.key as $k | .value |= drop($s[0].permissions[$k])) else . end)
              | with_entries(select(.value != [])))
            | if .permissions == {} then del(.permissions) else . end
          else . end' "$path" 2>/dev/null); then
      if [ "$(jq -S . <<<"$new")" = "$(jq -S . "$path")" ]; then :
      elif jq -e '. == {}' <<<"$new" >/dev/null; then remove_file "$root" .claude/settings.json "$apply"
      else
        [ "$apply" != true ] || printf '%s\n' "$new" >"$path"
        remove_say "$apply" "the senior-mode permissions and status line of .claude/settings.json"
      fi
    else
      echo "kept: .claude/settings.json (not valid JSON)"
    fi
  fi
  remove_file "$root" .claude/senior-mode.json "$apply"
  if [ -e "$root/release-please-config.json" ] || [ -e "$root/.release-please-manifest.json" ]; then
    echo "kept: release-please-config.json and .release-please-manifest.json (release history; delete them if release-please goes too)"
  fi
}

# The senior-mode ruleset of the repository: deleted, or listed. A plan that offers no rulesets has none to delete.
remove_ruleset() { # slug apply
  local id
  id=$(gh_retry api "repos/$1/rulesets" \
    --jq '[.[] | select(.name == "senior-mode" and .source_type == "Repository")][0].id // empty' 2>&1) ||
    { ruleset_refused <<<"$id" && return 0; die "cannot read the rulesets of $1: $id"; }
  [ -n "$id" ] || return 0
  if [ "$2" = true ]; then
    gh_retry api -X DELETE "repos/$1/rulesets/$id" >/dev/null || die "cannot delete the ruleset senior-mode of $1"
  fi
  remove_say "$2" "ruleset senior-mode"
}

# The labels setup created, when they still have its description (a label of the project's own is not touched) and no issue
# or pull request uses them: deleted, or listed. The others are named.
remove_labels() { # slug apply
  local have label color description cur used gone="" kept=""
  have=$(gh_retry label list --repo "$1" --limit 1000 --json name,description --jq '.[] | [.name, .description] | @tsv') ||
    die "cannot list the labels of $1"
  while IFS='|' read -r label color description; do
    [ -n "$label" ] || continue
    cur=$(awk -F'\t' -v l="$label" '$1 == l { print $2; found = 1 } END { exit !found }' <<<"$have") || continue
    if [ "$cur" != "$description" ]; then kept+="${kept:+, }$label (not senior-mode's)"; continue; fi
    used=$(gh_retry api --method GET "repos/$1/issues" -f labels="$label" -f state=all -f per_page=1 --jq length) ||
      die "cannot read the issues labelled $label"
    if [ "$used" != 0 ]; then kept+="${kept:+, }$label (in use)"; continue; fi
    if [ "$2" = true ]; then gh_retry label delete "$label" --repo "$1" --yes >/dev/null || die "cannot delete the label $label"; fi
    gone+="${gone:+, }$label"
  done <<<"$LABELS"$'\n'"$TYPE_LABELS"
  [ -z "$gone" ] || remove_say "$2" "labels $gone"
  [ -z "$kept" ] || echo "kept: labels $kept"
}

# The workflows setup disabled in `local` mode (all but senior-mode's own, which goes with the files): turned on again, or
# listed. Which ones setup disabled is read off the config of the tree $3, so with no config nothing is touched.
remove_workflows() { # slug apply tree
  local list id name mode
  list=$(gh_retry workflow list --all --limit 1000 --repo "$1" --json id,name,path,state \
    --jq '.[] | select((.path | startswith(".github/workflows/")) and .path != ".github/workflows/senior-mode.yml" and .path != ".github/workflows/senior-mode-audit.yml" and .state == "disabled_manually")
      | "\(.id)\t\(.name)"') || die "cannot list the workflows of $1"
  [ -n "$list" ] || return 0
  if [ ! -f "$3/.claude/senior-mode.json" ]; then
    echo "kept: workflows disabled on GitHub ($(cut -f2 <<<"$list" | paste -sd, - | sed 's/,/, /g')): the config is gone, so which ones setup disabled is unknown; gh workflow enable <name> turns one on"
    return 0
  fi
  mode=$(jq -r '.ci.mode // "local"' "$3/.claude/senior-mode.json" 2>/dev/null) || mode=local
  if [ "$mode" != local ]; then return 0; fi
  while IFS=$'\t' read -r id name; do
    [ "$2" != true ] || gh_retry workflow enable "$id" --repo "$1" >/dev/null || die "cannot enable the workflow $name"
    if [ "$2" = true ]; then echo "enabled: workflow $name (setup had disabled it, ci.mode local)"
    else echo "would enable: workflow $name (setup disabled it, ci.mode local)"
    fi
  done <<<"$list"
}

# The files, through a pull request from a branch of its own, made in a temporary worktree of the default branch: the
# checkout of the user is not touched. A pull request already open is left as it is.
remove_pr() { # slug apply tree base
  local branch=chore/remove-senior-mode plan pr url
  plan=$(remove_files "$3" false)
  if ! grep -q '^would remove' <<<"$plan"; then
    [ -z "$plan" ] || echo "$plan"
    echo "files: nothing left to remove on $4"
    return 0
  fi
  if [ "$2" != true ]; then
    echo "$plan"
    echo "would open: a pull request on $4 with these files taken out"
    return 0
  fi
  pr=$(gh_retry pr list --repo "$1" --head "$branch" --state open --json url --jq '.[0].url // empty') || die "cannot list the pull requests of $1"
  if [ -n "$pr" ]; then
    echo "files: the pull request is already open: $pr"
    return 0
  fi
  # A branch left by an earlier run that stopped before the pull request.
  ! git -C "$3" ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1 ||
    git_bound -C "$3" push -q origin --delete "$branch" || die "cannot delete the stale branch $branch"
  git -C "$3" switch -q -c "$branch" || die "cannot create the branch $branch"
  remove_files "$3" true
  git -C "$3" add -A
  # Our own hooks are among the files taken out: neither commit nor push runs them.
  git -C "$3" -c core.hooksPath=/dev/null commit -q -m "chore: remove senior-mode" \
    -m "Takes out the files senior-mode added: git hooks, config, Principles block, CODEOWNERS block, templates." || die "cannot commit the removal"
  git_bound -C "$3" -c core.hooksPath=/dev/null push -q -u origin "$branch" || die "cannot push $branch"
  url=$(gh pr create --repo "$1" --base "$4" --head "$branch" --title "chore: remove senior-mode" \
    --body "Takes senior-mode out of the repository: its git hooks, config, Principles block, CODEOWNERS block, workflow and unedited templates. Generated by \`senior-mode setup remove --apply\`. The Project and the issues are kept.") ||
    die "cannot open the pull request"
  echo "files: pull request opened: $url"
}

# core.hooksPath of this checkout, when it names .githooks and nothing of the project's own is left in it.
remove_hooks_path() { # root tree apply
  local others
  [ "$(git -C "$1" config core.hooksPath 2>/dev/null || true)" = .githooks ] || return 0
  others=$(grep -L '^# senior-mode:' "$2"/.githooks/* 2>/dev/null || true)
  [ -z "$others" ] || { echo "kept: core.hooksPath .githooks (it holds hooks of yours)"; return 0; }
  [ "$3" != true ] || git -C "$1" config --unset core.hooksPath
  if [ "$3" = true ]; then echo "removed: core.hooksPath .githooks of this checkout"
  else echo "would remove: core.hooksPath .githooks of this checkout"
  fi
}

# Takes senior-mode out of the repository: the files through a pull request, then (after it is open, so that the ruleset
# cannot hold it) the ruleset, the unused labels and the workflows setup disabled. Every step is idempotent: a rerun after
# a partial removal does what is left. Without --apply only lists.
setup_remove() {
  local apply=false root slug base tmp
  while [ $# -gt 0 ]; do
    case $1 in
      --apply) apply=true; shift ;;
      *) usage ;;
    esac
  done
  root=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repository"
  slug=$(repo_slug)
  base=$(gh_retry api "repos/$slug" --jq .default_branch) || die "cannot read $slug on GitHub"
  git_bound -C "$root" fetch -q origin "$base" || die "cannot fetch $base from origin"
  tmp=$(mktemp -d)
  # shellcheck disable=SC2064 # the paths are those of now
  trap "$(printf 'git -C %q worktree remove --force %q >/dev/null 2>&1; rm -rf %q' "$root" "$tmp" "$tmp")" EXIT
  git -C "$root" worktree add -q --detach "$tmp" "origin/$base" || die "cannot read $base of $slug"
  if [ "$apply" = true ]; then echo "remove: $slug"; else echo "remove: $slug (dry run: nothing changes, --apply does it)"; fi
  remove_workflows "$slug" "$apply" "$tmp"
  remove_pr "$slug" "$apply" "$tmp" "$base"
  remove_ruleset "$slug" "$apply"
  remove_labels "$slug" "$apply"
  remove_hooks_path "$root" "$tmp" "$apply"
  echo "kept: the Project and the issues (history). On this machine: senior-mode serve --uninstall and senior-mode schedule remove stop the daemon and the cron entry."
  [ "$apply" = true ] || echo "remove: dry run, nothing changed; senior-mode setup remove --apply does it"
}
