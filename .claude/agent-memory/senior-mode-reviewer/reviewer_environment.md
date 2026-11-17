---
name: reviewer-environment
description: What a senior-mode reviewer session may execute - test scripts, shellcheck and /tmp writes need approval; gh api and jq -n work; label via REST
metadata:
  type: reference
---

In reviewer sessions (seen 2026-11-17, PR #29):

- Running repository scripts (`bin/tests/test-*.sh`, `.github/scripts/*.sh`, `shellcheck`) needs approval. Heredocs and writes to `/tmp` are also refused.
- These work: `gh api` (including GraphQL introspection), `gh pr comment --body-file -` with a heredoc, `jq -n` without `$` in the program, and `git` reads.
- `gh pr edit --add-label` fails because of the Projects classic deprecation. Add the label through the REST issues/N/labels endpoint with `gh api` instead.

**How to apply:** say in the review comment that the tests were read and not run. Use GraphQL introspection to check API assumptions instead of trusting the PR body.
