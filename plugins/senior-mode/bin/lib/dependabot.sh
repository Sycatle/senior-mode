# shellcheck shell=bash
# The judgement of one Dependabot pull request (#721, part 1 of #680; owner decision 2026-11-27): is it ready to merge, and
# when. Patch and minor bumps are ready once the new version is as old as the release age; a major bump, a changed file in a
# protected zone, or a release whose age cannot be read goes to a human (needs-human). No serve wiring here. Definitions only.

DEPENDABOT_MIN_DAYS=7

# The release age in days: serve.dependabot.minReleaseDays, else the workspace's own minimumReleaseAge (pnpm-workspace.yaml,
# in minutes, rounded up to whole days), else 7.
dependabot_min_days() {
  local days root minutes
  days=$(config_effective 2>/dev/null | jq -r '.serve.dependabot.minReleaseDays // empty' 2>/dev/null) || days=""
  if [[ $days =~ ^[0-9]+$ ]]; then
    echo "$days"
    return 0
  fi
  root=$(git rev-parse --show-toplevel 2>/dev/null) || root=.
  minutes=$(sed -n 's/^minimumReleaseAge:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$root/pnpm-workspace.yaml" 2>/dev/null | head -n 1)
  if [[ $minutes =~ ^[0-9]+$ ]]; then
    echo $(((minutes + 1439) / 1440))
    return 0
  fi
  echo "$DEPENDABOT_MIN_DAYS"
}

# The packages of the `updated-dependencies:` trailers of the commit messages on stdin, as a JSON array of {name, version,
# update} (update: major, minor, patch, or "" when the trailer does not say).
dependabot_trailer() {
  awk '
    function flush() { if (name != "") printf "%s\t%s\t%s\n", name, ver, typ; name = ""; ver = ""; typ = "" }
    function val(s) { sub(/^[^:]*:[ \t]*/, "", s); gsub(/["\047]/, "", s); sub(/[ \t]+$/, "", s); return s }
    /^updated-dependencies:/ { on = 1; next }
    on && /^- dependency-name:/ { flush(); name = val($0); next }
    on && /^[ \t]+dependency-version:/ { ver = val($0); next }
    on && /^[ \t]+update-type:/ { typ = val($0); sub(/^version-update:semver-/, "", typ); next }
    on && (/^(---|\.\.\.)[ \t]*$/ || /^[ \t]*$/) { flush(); on = 0 }
    END { flush() }' |
    jq -Rsc 'split("\n") | map(select(. != "") | split("\t") | {name: .[0], version: .[1], update: .[2]}) | unique'
}

# The publish times of the package $1 on the registry, as the JSON of `npm view <name> time --json` (SENIOR_MODE_NPM stands
# in for npm); nothing when the name is not a package name or the registry does not answer.
dependabot_times() {
  [[ $1 =~ ^(@[a-z0-9._~-]+/)?[a-z0-9][a-z0-9._~-]*$ ]] || return 1
  net_bound 60 "${SENIOR_MODE_NPM:-npm}" view "$1" time --json 2>/dev/null </dev/null
}

# dependabot_assess <pr>: the verdict on one Dependabot pull request, as one JSON line:
#   {verdict: ready|wait|human, major, minReleaseDays, packages: [{name, version, update, published, readyAt, ageDays}],
#    until (wait: the instant, ISO 8601 UTC, at which the youngest version passes), reason (human)}
# SENIOR_MODE_NOW stands in for the clock.
dependabot_assess() {
  local pr=${1:-} slug msgs pkgs files globs zones days now times="{}" p name version enriched
  [[ $pr =~ ^[0-9]+$ ]] || die "usage: dependabot_assess <pull request number>"
  slug=$(repo_slug)
  msgs=$(gh_retry api "repos/$slug/pulls/$pr/commits" --paginate --jq '.[].commit.message') ||
    die "cannot read the commits of pull request #$pr"
  files=$(gh_retry api "repos/$slug/pulls/$pr/files" --paginate --jq '.[].filename') ||
    die "cannot read the files of pull request #$pr"
  pkgs=$(dependabot_trailer <<<"$msgs")
  globs=$(config_effective 2>/dev/null | jq -c '.protected // []') || globs=""
  [ -n "$globs" ] || globs="[]"
  zones=$(protected_match "$globs" <<<"$files" | paste -sd, -) || zones=""
  days=$(dependabot_min_days)
  now=${SENIOR_MODE_NOW:-$(date +%s)}
  while IFS=$'\t' read -r name version; do
    [ -n "$name" ] || continue
    p=$(dependabot_times "$name") && jq -e 'type == "object"' >/dev/null 2>&1 <<<"$p" || p="{}"
    times=$(jq -c --arg k "$name@$version" --argjson p "$p" --arg v "$version" '. + {($k): ($p[$v] // null)}' <<<"$times")
  done < <(jq -r '.[] | [.name, .version] | @tsv' <<<"$pkgs")
  # shellcheck disable=SC2016 # a jq program, not shell
  jq -nc --argjson pkgs "$pkgs" --argjson times "$times" --argjson now "$now" --argjson days "$days" --arg zones "$zones" '
    def epoch: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
    ($pkgs | map(. + {published: ($times["\(.name)@\(.version)"] // null)}
      | . + {ready: (if .published then (.published | epoch) + $days * 86400 else null end)}
      | . + {ageDays: (if .published then (($now - (.published | epoch)) / 86400 * 10 | floor) / 10 else null end)})) as $all
    | ($all | map(select(.update == "major") | .name)) as $majors
    | ($all | map(select(.update == "" or .update == null or .published == null) | .name)) as $unknown
    | ($all | map(select(.ready != null and .ready > $now) | .ready) | max) as $until
    | {verdict: (if ($all | length) == 0 or ($majors | length) > 0 or $zones != "" or ($unknown | length) > 0 then "human"
                 elif $until != null then "wait" else "ready" end),
       major: (($majors | length) > 0), minReleaseDays: $days,
       packages: ($all | map({name, version, update, published, readyAt: (.ready | if . then todate else null end), ageDays}))}
    | . + (if .verdict == "human" then
        {reason: (if ($all | length) == 0 then "no updated-dependencies trailer in the commits"
                  elif ($majors | length) > 0 then "major bump of \($majors | join(", "))"
                  elif $zones != "" then "changes a protected file: \($zones | split(",") | join(", "))"
                  else "release age unknown for \($unknown | join(", "))" end)}
      elif .verdict == "wait" then {until: ($until | todate)} else {} end)'
}
