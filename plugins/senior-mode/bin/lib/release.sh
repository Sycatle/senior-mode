# shellcheck shell=bash
# Pinned so a release does not change with the CLI's latest version; it needs Node 22 or later.
RELEASE_PLEASE=17.11.2

# Runs release-please locally (ADR 0006): tags and publishes a merged release PR, then opens or
# updates the next one. The token goes through a private file, out of the process list. `--patch` (#322, after a
# hotfix) opens that release pull request as the next patch of the latest release (`--release-as`), whatever
# the commits since say.
release() {
  local dry="" patch="" root slug token step tag as=() as_step=()
  case ${1:-} in "") ;; --dry-run) dry=--dry-run ;; --patch) patch=true ;; *) usage ;; esac
  root=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repository"
  [ -f "$root/release-please-config.json" ] ||
    die "no release-please-config.json; run senior-mode setup repo"
  slug=$(repo_slug)
  if [ -n "$patch" ]; then
    tag=$(gh_retry api "repos/$slug/releases/latest" --jq .tag_name) || die "no latest release to patch"
    [[ $tag =~ ([0-9]+)\.([0-9]+)\.([0-9]+)([^0-9]|$) ]] || die "the latest release $tag has no x.y.z version"
    as=(--release-as "${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.$((BASH_REMATCH[3] + 1))")
  fi
  token=$(mktemp)
  # shellcheck disable=SC2064 # expand now: $token is local and gone when the trap runs
  trap "rm -f '$token'" EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  gh auth token >"$token" || die "gh is not logged in; run gh auth login"
  for step in github-release release-pr; do
    [ "$step" = release-pr ] || as_step=()
    [ "$step" != release-pr ] || as_step=("${as[@]+"${as[@]}"}")
    (cd "$root" && npx --yes "release-please@$RELEASE_PLEASE" "$step" \
      --token "$token" --repo-url "$slug" ${dry:+"$dry"} ${as_step[@]+"${as_step[@]}"}) || die "release-please $step failed"
  done
}
