# shellcheck shell=bash
# Hosted previews (#542): `deploy.previews` says whether Vercel, Netlify and Cloudflare Pages deploy the branches
# senior-mode pushes. `platform` leaves them alone; `off` stops every deployment of a work branch; `ready` stops them
# until `senior-mode preview` pushes the head of a pull request to `preview/<branch>`, the one ref that deploys, so a
# review gets one preview. Nothing needs a secret: Vercel reads `git.deploymentEnabled` of vercel.json, Netlify runs
# the ignore step .claude/senior-mode/ignore-build.sh (also a hook for other hosts), Cloudflare Pages has no file for it
# and setup prints the dashboard steps. The script is the record of what setup added, so `setup remove` can undo it.

DEPLOY_TAG='senior-mode:previews'
DEPLOY_SCRIPT=.claude/senior-mode/ignore-build.sh
# shellcheck disable=SC2016 # run by the platform's shell, not ours
DEPLOY_CMD='sh $(git rev-parse --show-toplevel)/.claude/senior-mode/ignore-build.sh'
DEPLOY_DOCS='Vercel https://vercel.com/docs/project-configuration/git-configuration, Netlify https://docs.netlify.com/configure-builds/ignore-builds/, Cloudflare Pages https://developers.cloudflare.com/pages/configuration/branch-build-controls/'

# The hosted platforms the repository $1 is wired to, one per line: vercel, netlify, cloudflare-pages.
deploy_platforms() { # root
  local f
  if [ -e "$1/vercel.json" ] || [ -e "$1/vercel.ts" ] || [ -d "$1/.vercel" ]; then echo vercel; fi
  if [ -e "$1/netlify.toml" ] || [ -d "$1/.netlify" ]; then echo netlify; fi
  for f in wrangler.toml wrangler.json wrangler.jsonc; do
    if [ -f "$1/$f" ] && grep -q pages_build_output_dir "$1/$f"; then echo cloudflare-pages; break; fi
  done
}

# The globs of the branches senior-mode pushes, from the branch pattern of the project: one per line. A glob that
# would match every branch, or that holds anything but name characters and glob signs, is left out.
deploy_globs() { # root
  local pat short p g
  pat=$(workflow_branch_pattern "$1")
  short=${pat//-\{slug\}/}
  short=${short//_\{slug\}/}
  short=${short//\/\{slug\}/}
  for p in "$pat" "$short"; do
    g=${p//\{type\}/*}
    g=${g//\{issue\}/[0-9]*}
    g=${g//\{key\}/*}
    g=${g//\{slug\}/*}
    grep -qE '^[][A-Za-z0-9._/*-]+$' <<<"$g" || continue
    [ "${g//\*/}" != "" ] || continue
    echo "$g"
  done | awk '!seen[$0]++'
}

# The ignore step: exit 0 skips the build, 1 builds. $1 the mode, $2 the globs of the work branches, $3 the
# `<glob>=<true|false>` lines of vercel.json that setup added.
deploy_script_text() { # mode globs keys
  local g k arms=""
  printf '%s\n' '#!/bin/sh' "# $DEPLOY_TAG" \
    "# Written by senior-mode setup repo (deploy.previews: $1); setup remove takes it out. Exit 0 skips the build, 1 builds." \
    '# Ignore step of Netlify, and a hook for any host that skips a build on exit 0. No secret needed.'
  while IFS= read -r k; do
    [ -z "$k" ] || printf '# vercel-key: %s\n' "$k"
  done <<<"$3"
  while IFS= read -r g; do
    [ -z "$g" ] || arms+="${arms:+|}$g"
  done <<<"$2"
  printf 'mode=%s\n' "$1"
  cat <<'EOF'
branch=${BRANCH:-${VERCEL_GIT_COMMIT_REF:-${CF_PAGES_BRANCH:-${GITHUB_REF_NAME:-${CI_COMMIT_REF_NAME:-}}}}}
[ "${CONTEXT:-}" != production ] && [ "${VERCEL_ENV:-}" != production ] || exit 1
case $branch in
  preview/*) [ "$mode" = ready ] && exit 1; exit 0 ;;
EOF
  [ -z "$arms" ] || printf '  %s) exit 0 ;;\n' "$arms"
  printf 'esac\nexit 1\n'
}

# vercel.json $1 with the keys of $2 (JSON list of [glob, value]) taken out of git.deploymentEnabled, then the keys
# of $3 (JSON object) added where absent. Prints the new JSON.
# shellcheck disable=SC2016 # a jq program, not shell
deploy_vercel_text() { # file remove add
  jq --argjson rm "$2" --argjson add "$3" '
    (if (.git.deploymentEnabled | type) == "object" then
       .git.deploymentEnabled |= with_entries(select(. as $e | ($rm | index([[$e.key, $e.value]])) == null))
       | if .git.deploymentEnabled == {} then del(.git.deploymentEnabled) else . end
       | if .git == {} then del(.git) else . end
     else . end)
    | if ($add | length) == 0 or .git.deploymentEnabled == false then .
      else (if (.git.deploymentEnabled | type) == "object" then .git.deploymentEnabled else {} end) as $cur
        | .git.deploymentEnabled = $cur + ($add | with_entries(select($cur[.key] == null))) end' "$1"
}

# The `<glob>=<value>` lines that deploy_vercel_text would add to vercel.json $1 (already stripped) for $2.
# shellcheck disable=SC2016 # a jq program, not shell
deploy_vercel_added() { # file add
  jq -r --argjson add "$2" '(.git.deploymentEnabled) as $c
    | if $c == false then empty else ($c | if type == "object" then . else {} end) as $cur
      | $add | to_entries[] | select($cur[.key] == null) | "\(.key)=\(.value)" end' "$1"
}

# netlify.toml $1 with the ignore step of senior-mode taken out ($2 strip) or put in ($2 apply), on stdout. An ignore
# command of the project's own is composed (`<ours> || (<theirs>)`), and given back by strip. One that is not a single
# basic string is left as it is; apply then prints nothing and exits 3.
deploy_netlify_text() { # file op
  local state
  state=$(awk '
    /^[ \t]*\[/ { inb = ($0 ~ /^[ \t]*\[build\][ \t]*(#.*)?$/); if (inb) tbl = 1 }
    inb && /^[ \t]*ignore[ \t]*=/ { has = 1; if ($0 ~ /^[ \t]*ignore[ \t]*=[ \t]*"([^"\\]|\\.)*"[ \t]*$/) single = 1 }
    END { print (!tbl ? "notable" : !has ? "none" : single ? "single" : "other") }' "$1")
  if [ "$2" = apply ] && [ "$state" = other ]; then return 3; fi
  awk -v op="$2" -v state="$state" -v cmd="$DEPLOY_CMD" -v tag="# $DEPLOY_TAG" '
    function inner(s,   p, q) { p = index(s, "\""); q = length(s); while (substr(s, q, 1) ~ /[ \t]/) q--; return substr(s, p + 1, q - p - 1) }
    function prefix(s) { return substr(s, 1, index(s, "\"")) }
    { line[++n] = $0 }
    END {
      for (i = 1; i <= n; i++) {
        l = line[i]
        if (l ~ /^[ \t]*\[/) { inb = (l ~ /^[ \t]*\[build\][ \t]*(#.*)?$/) }
        if (inb && l ~ /^[ \t]*ignore[ \t]*=[ \t]*"([^"\\]|\\.)*"[ \t]*$/) {
          v = inner(l)
          if (index(v, cmd) == 1) {
            rest = substr(v, length(cmd) + 1)
            if (op == "strip") {
              if (rest == "") { continue }
              if (index(rest, " || (") == 1 && substr(rest, length(rest)) == ")") {
                l = prefix(l) substr(rest, 6, length(rest) - 6) "\""
              }
            }
          } else if (op == "apply") {
            l = prefix(l) cmd " || (" v ")\""
          }
        }
        out[++m] = l
        if (op == "apply" && state == "none" && !done && l ~ /^[ \t]*\[build\][ \t]*(#.*)?$/) {
          out[++m] = "  ignore = \"" cmd "\""
          done = 1
        }
      }
      if (op == "apply" && state == "notable") {
        if (m > 0) out[++m] = ""
        out[++m] = tag
        out[++m] = "[build]"
        out[++m] = "  ignore = \"" cmd "\""
      }
      # A [build] table that setup made (its tag above it) and that holds nothing now goes.
      for (i = 1; i <= m; i++) {
        if (op == "strip" && out[i] == tag && out[i + 1] ~ /^\[build\][ \t]*(#.*)?$/) {
          j = i + 2
          while (j <= m && out[j] !~ /^[ \t]*\[/ && out[j] ~ /^[ \t]*$/) j++
          if (j > m || out[j] ~ /^[ \t]*\[/) {
            if (i > 1 && out[i - 1] == "") skip[i - 1] = 1
            for (k = i; k < j; k++) skip[k] = 1
          }
        }
      }
      for (i = 1; i <= m; i++) if (!skip[i]) print out[i]
    }' "$1"
}

# Writes $2 to the file $1 when it differs; an empty text deletes the file ($3 true: it holds nothing).
deploy_write() { # file text kind
  if [ "$3" = json ]; then
    [ "$(jq -S . <<<"$2")" != "$(jq -S . "$1" 2>/dev/null || true)" ] || return 1
  else
    [ "$2" != "$(cat "$1" 2>/dev/null || true)" ] || return 1
  fi
  printf '%s\n' "$2" >"$1"
}

# Takes out of the tree $1 what an earlier setup put in for the previews: the keys in vercel.json, the ignore step in
# netlify.toml, the script. $2 true does it, else only lists; $3 true prints each step. Silent when there is nothing.
deploy_restore() { # root apply say
  local root=$1 script=$1/$DEPLOY_SCRIPT rm='[]' new
  [ ! -f "$script" ] || rm=$(sed -n 's/^# vercel-key: //p' "$script" |
    jq -Rn '[inputs | capture("^(?<k>.*)=(?<v>true|false)$") | [.k, (.v == "true")]]')
  if [ -f "$root/vercel.json" ] && new=$(deploy_vercel_text "$root/vercel.json" "$rm" '{}') &&
    [ "$(jq -S . <<<"$new")" != "$(jq -S . "$root/vercel.json")" ]; then
    if [ "$2" = true ]; then
      if [ "$(jq -S . <<<"$new")" = '{}' ]; then rm -f "$root/vercel.json"; else printf '%s\n' "$new" >"$root/vercel.json"; fi
    fi
    [ "$3" != true ] || remove_say "$2" "the preview settings of vercel.json"
  fi
  if [ -f "$root/netlify.toml" ] && grep -qF "$DEPLOY_CMD" "$root/netlify.toml" && new=$(deploy_netlify_text "$root/netlify.toml" strip); then
    if [ "$2" = true ]; then
      if [ -z "${new//[[:space:]]/}" ]; then rm -f "$root/netlify.toml"; else printf '%s\n' "$new" >"$root/netlify.toml"; fi
    fi
    [ "$3" != true ] || remove_say "$2" "the ignore step of netlify.toml"
  fi
  if [ -f "$script" ]; then
    [ "$2" != true ] || rm -f "$script"
    [ "$3" != true ] || remove_say "$2" "$DEPLOY_SCRIPT"
  fi
  return 0
}

# vercel.json of the tree $1 with the keys of the old record taken out and those of $3 (a JSON object) added where
# absent: sets DEPLOY_KEYS to the `<glob>=<value>` lines it added, the new record.
# shellcheck disable=SC2016 # a jq program, not shell
deploy_apply_vercel() { # root mode add
  local vj=$1/vercel.json old=$1/$DEPLOY_SCRIPT gone='[]' tmp new
  [ -f "$vj" ] || echo '{}' >"$vj"
  [ ! -f "$old" ] || gone=$(sed -n 's/^# vercel-key: //p' "$old" | jq -Rn '[inputs | capture("^(?<k>.*)=(?<v>true|false)$") | [.k, (.v == "true")]]')
  tmp=$(mktemp)
  deploy_vercel_text "$vj" "$gone" '{}' >"$tmp" || die "cannot read vercel.json"
  DEPLOY_KEYS=$(deploy_vercel_added "$tmp" "$3")
  new=$(deploy_vercel_text "$tmp" '[]' "$3")
  rm -f "$tmp"
  if deploy_write "$vj" "$new" json; then
    echo "previews: $2: vercel.json git.deploymentEnabled ($(jq -r '.git.deploymentEnabled | if type == "object" then keys | join(", ") else tostring end' <<<"$new"))"
  else
    echo "previews: $2: vercel.json already set"
  fi
}

# setup repo: puts the files of the tree $1 in line with deploy.previews of its config. `platform` (the default) takes
# out what an earlier setup added and touches nothing else.
# shellcheck disable=SC2016 # jq programs, not shell
deploy_apply() { # root
  local root=$1 file=$1/.claude/senior-mode.json mode globs add new platforms had=false ts DEPLOY_KEYS=""
  mode=$(jq -r '.deploy.previews // "platform"' "$file")
  case $mode in platform | ready | off) ;; *) die "deploy.previews in .claude/senior-mode.json must be platform, ready or off" ;; esac
  if [ "$mode" = platform ]; then
    [ ! -f "$root/$DEPLOY_SCRIPT" ] || had=true
    deploy_restore "$root" true true
    [ "$had" != true ] || echo "previews: platform: the platforms deploy every branch again"
    return 0
  fi
  platforms=$(deploy_platforms "$root")
  globs=$(deploy_globs "$root")
  if [ -z "$globs" ]; then
    echo "previews: the branch pattern of the project matches every branch, so no work branch can be told apart: nothing written"
    return 0
  fi
  add=$(jq -Rn --arg m "$mode" '[inputs | select(length > 0) | {(.): false}] | add // {} | if $m == "ready" then . + {"preview/**": true} else . end' <<<"$globs")
  if grep -qx vercel <<<"$platforms"; then
    if [ -f "$root/vercel.json" ] || [ -d "$root/.vercel" ]; then
      deploy_apply_vercel "$root" "$mode" "$add"
    else
      echo "previews: vercel.ts is code and is not edited; add git.deploymentEnabled: $(jq -c . <<<"$add")"
    fi
  fi
  # The script is written last: the record above is read from the old one.
  mkdir -p "$root/.claude/senior-mode"
  ts=$(deploy_script_text "$mode" "$globs" "${DEPLOY_KEYS:-}")
  if deploy_write "$root/$DEPLOY_SCRIPT" "$ts" text; then echo "previews: $mode: $DEPLOY_SCRIPT written"; fi
  chmod +x "$root/$DEPLOY_SCRIPT"
  if grep -qx netlify <<<"$platforms"; then
    [ -f "$root/netlify.toml" ] || : >"$root/netlify.toml"
    local nt
    nt=$(mktemp)
    deploy_netlify_text "$root/netlify.toml" strip >"$nt"
    if new=$(deploy_netlify_text "$nt" apply); then
      if deploy_write "$root/netlify.toml" "$new" text; then echo "previews: $mode: netlify.toml [build] ignore"; else echo "previews: $mode: netlify.toml already set"; fi
      [ "$mode" != ready ] || echo "netlify: the build of preview/<branch> needs branch deploys on for it (Site configuration, Build and deploy, Branches)"
    else
      echo "previews: netlify.toml has an ignore command senior-mode cannot compose (not a single quoted string): add '$DEPLOY_CMD ||' in front of it yourself"
    fi
    rm -f "$nt"
  fi
  if grep -qx cloudflare-pages <<<"$platforms"; then
    if [ "$mode" = ready ]; then
      echo "cloudflare-pages: no file controls it; in the dashboard (Workers and Pages, the project, Settings, Builds, Branch control) set Preview branch to Custom branches with Include preview/* and nothing else"
    else
      echo "cloudflare-pages: no file controls it; in the dashboard (Workers and Pages, the project, Settings, Builds, Branch control) set Preview branch to None"
    fi
  fi
  [ -n "$platforms" ] || echo "previews: no Vercel, Netlify or Cloudflare Pages project found: call $DEPLOY_SCRIPT from the ignore step of your host (exit 0 skips the build)"
  [ -z "$platforms" ] || echo "previews: docs: $DEPLOY_DOCS"
}

# `senior-mode preview`: with deploy.previews `ready`, asks the platforms for the one preview of the open pull request
# of this branch, by pushing its head to preview/<branch>. The head does not change, so statuses and review stand.
# Refs whose branch is gone are deleted on the way.
deploy_preview() {
  local mode branch slug head prhead ref remote
  [ $# -eq 0 ] || usage
  mode=$(config_get deploy.previews)
  if [ "$mode" != ready ]; then
    echo "previews: $mode: nothing to request$([ "$mode" = platform ] && echo ' (the platform deploys on its own)')"
    return 0
  fi
  branch=$(git branch --show-current)
  [ -n "$branch" ] || die "not on a branch"
  [ "$branch" != "$(repo_default_branch)" ] && [[ $branch != preview/* ]] || die "the preview is requested from the branch of a pull request, not from $branch"
  slug=$(repo_slug)
  head=$(git rev-parse HEAD)
  prhead=$(gh_retry pr view "$branch" --repo "$slug" --json state,headRefOid --jq 'select(.state == "OPEN") | .headRefOid') ||
    die "no pull request found for $branch; open it first"
  [ -n "$prhead" ] || die "the pull request of $branch is not open"
  [ "$prhead" = "$head" ] || die "the head of the pull request is not this commit; push $branch first"
  ref=preview/$branch
  remote=$(git_bound ls-remote origin "refs/heads/*") || die "cannot read the branches of origin"
  # A preview ref whose branch left origin.
  while read -r _ r; do
    [[ $r == refs/heads/preview/* ]] || continue
    awk -v r="refs/heads/${r#refs/heads/preview/}" '$2 == r { f = 1 } END { exit !f }' <<<"$remote" ||
      git_bound push -q origin --delete "${r#refs/heads/}" || true
  done <<<"$remote"
  if awk -v h="$head" -v r="refs/heads/$ref" '$1 == h && $2 == r { f = 1 } END { exit !f }' <<<"$remote"; then
    echo "preview: already requested on $ref (${head:0:7})"
    return 0
  fi
  git_bound push -q origin "+HEAD:refs/heads/$ref" || die "cannot push $ref"
  echo "preview: requested on $ref (${head:0:7}); the platform builds it once"
}
