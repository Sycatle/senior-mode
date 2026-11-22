# shellcheck shell=bash
# Shared fixture of test-run.sh and test-retro.sh: the outcome records `run` writes for a ticket
# (.git/senior-mode/runs/<stamp>/<n>.json, without finishedAt) and `retro` reads. test-run.sh checks
# what `run` writes against it; test-retro.sh writes it to disk and checks what `retro` makes of it.
# shellcheck disable=SC2034 # used by the scripts that source this file
RUN_OUTCOMES='
[
  { "ticket": 10, "outcome": "delivered", "escalated": false, "reason": null, "model": "sonnet" },
  { "ticket": 11, "outcome": "delivered", "escalated": true, "reason": "tests do not pass", "model": "opus" },
  { "ticket": 12, "outcome": "failed", "escalated": true, "reason": "still cannot build", "model": "opus" },
  { "ticket": 20, "outcome": "failed", "escalated": false, "reason": "the session said delivered but there is no open pull request for its branch", "model": "sonnet" },
  { "ticket": 30, "outcome": "outgrown", "escalated": false, "reason": "needs a data migration", "model": "sonnet" }
]
'
