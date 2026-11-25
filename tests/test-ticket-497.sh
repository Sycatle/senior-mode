#!/usr/bin/env bash
# Red skeleton of #497: one case per acceptance criterion. Replace each body with a real test; the ticket is not ready while one says "not implemented" or is skipped.
set -u
failures=0
skeleton() { echo "FAIL: $1: not implemented"; failures=$((failures + 1)); }

# Given a node project without `dependabot.yml`, when `setup github` runs, then the file has a weekly `npm` entry with a `minor-and-patch` group and an ignore on `version-update:semver-major`.
skeleton Given\ a\ node\ project\ without\ \`dependabot.yml\`\,\ when\ \`setup\ github\`\ runs\,\ then\ the\ file\ has\ a\ weekly\ \`npm\`\ entry\ with\ a\ \`minor-and-patch\`\ group\ and\ an\ ignore\ on\ \`version-update:semver-major\`.

# Given `renovate.json` present, then setup writes nothing and prints `renovate: untouched`; given an existing `dependabot.yml`, then `dependabot.yml: untouched`.
skeleton Given\ \`renovate.json\`\ present\,\ then\ setup\ writes\ nothing\ and\ prints\ \`renovate:\ untouched\`\;\ given\ an\ existing\ \`dependabot.yml\`\,\ then\ \`dependabot.yml:\ untouched\`.

# Given a major available for `next`, when the weekly pass runs twice, then exactly one open `chore(deps): next <from> to <to>` ticket exists.
skeleton Given\ a\ major\ available\ for\ \`next\`\,\ when\ the\ weekly\ pass\ runs\ twice\,\ then\ exactly\ one\ open\ \`chore\(deps\):\ next\ \<from\>\ to\ \<to\>\`\ ticket\ exists.

# Given a Dependabot pull request, then it still needs a human merge (ADR 0024).
skeleton Given\ a\ Dependabot\ pull\ request\,\ then\ it\ still\ needs\ a\ human\ merge\ \(ADR\ 0024\).

exit "$failures"
