#!/usr/bin/env bash
# Red skeleton of #477: one case per acceptance criterion. Replace each body with a real test; the ticket is not ready while one says "not implemented" or is skipped.
set -u
failures=0
skeleton() { echo "FAIL: $1: not implemented"; failures=$((failures + 1)); }

# Given an Agent call whose prompt has the seven headings, each followed by text, then it runs and `briefs.jsonl` has its line (time, session, agent type, model, Goal).
skeleton Given\ an\ Agent\ call\ whose\ prompt\ has\ the\ seven\ headings\,\ each\ followed\ by\ text\,\ then\ it\ runs\ and\ \`briefs.jsonl\`\ has\ its\ line\ \(time\,\ session\,\ agent\ type\,\ model\,\ Goal\).

# Given a call missing `## Verify`, then the hook exits 2 with `brief: missing ## Verify (skill brief)` and the subagent does not start.
skeleton Given\ a\ call\ missing\ \`##\ Verify\`\,\ then\ the\ hook\ exits\ 2\ with\ \`brief:\ missing\ ##\ Verify\ \(skill\ brief\)\`\ and\ the\ subagent\ does\ not\ start.

# Given a call with an empty section, then the hook refuses it the same way.
skeleton Given\ a\ call\ with\ an\ empty\ section\,\ then\ the\ hook\ refuses\ it\ the\ same\ way.

# Given a repository without `.claude/senior-mode.json`, then the hook lets every call through.
skeleton Given\ a\ repository\ without\ \`.claude/senior-mode.json\`\,\ then\ the\ hook\ lets\ every\ call\ through.

exit "$failures"
