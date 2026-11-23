# shellcheck shell=bash
# Pinned so a release does not change with the CLI's latest version; it needs Node 22 or later.
RELEASE_PLEASE=17.11.2

# Runs release-please locally (ADR 0006): tags and publishes a merged release PR, then opens or
# updates the next one. The token goes through a private file, out of the process list.
release() {
  local dry="" root slug token step
  case ${1:-} in "") ;; --dry-run) dry=--dry-run ;; *) usage ;; esac
  root=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repository"
  [ -f "$root/release-please-config.json" ] ||
    die "no release-please-config.json; run senior-mode setup repo"
  slug=$(repo_slug)
  token=$(mktemp)
  # shellcheck disable=SC2064 # expand now: $token is local and gone when the trap runs
  trap "rm -f '$token'" EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  gh auth token >"$token" || die "gh is not logged in; run gh auth login"
  for step in github-release release-pr; do
    (cd "$root" && npx --yes "release-please@$RELEASE_PLEASE" "$step" \
      --token "$token" --repo-url "$slug" ${dry:+"$dry"}) || die "release-please $step failed"
  done
}
