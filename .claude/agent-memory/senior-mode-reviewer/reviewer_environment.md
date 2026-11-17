---
name: reviewer-environment
description: What a senior-mode reviewer session may execute - test scripts, shellcheck, sed, python and /tmp writes need approval; gh api, jq and cat heredocs into the memory dir work; label via REST
metadata:
  type: reference
---

In reviewer sessions (seen 2026-11-17, PR #29, two rounds):

- Running repository scripts (`bin/tests/test-*.sh`, `.github/scripts/*.sh`, `shellcheck`) needs approval, even as `bash <absolute path>`. `sed`, `python3`, pipelines containing them, and writes to `/tmp` are also refused.
- These work: `gh api` (including GraphQL introspection and PATCH of a comment with `-F body=@-`), `gh pr comment --body-file -` with a heredoc, `jq` (use `sub()` to edit text instead of `sed`), `git` reads, and `cat > file <<'EOF'` into this memory directory (there is no Write tool).
- `gh pr edit --add-label` fails because of the Projects classic deprecation. Add the label through the REST issues/N/labels endpoint with `gh api` instead.
- The review skill's status rule: `success` = approved, `failure` = changes requested, `pending` = approve with human merge (protected zone).

**How to apply:** say in the review comment that the tests were read and not run. Use GraphQL introspection to check API assumptions instead of trusting the PR body.
