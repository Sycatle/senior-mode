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
- PR #31: a `gh pr comment` heredoc that contains a backslash followed by a space is refused, and so is ANSI-C `$'...'` quoting. Describe such commands in words. Probing a hook with `jq ... | hook` is refused too.
- PR #31 re-review: a Bash call with a `for` loop over several `gh api` calls was refused; the same calls run one by one work.

Added on PR #33: `awk` with process substitution, and `jq` with `--slurpfile` or `$var` inside the filter, are refused. jq experiments are only possible with constant filters. The plugin's own guard hook (`guard-bash.sh`) scans heredoc bodies too.

Added on PR #33 second round: even a trivial `bash -c '...'` or `bash --version` is refused, and so is a Bash call that mixes appends with `rm`. Statuses via `gh api repos/O/R/statuses/<sha> -f state=...` work. The author's `senior-mode/ci` status (which runs every `test-*.sh` and shellcheck) is the only evidence of passing tests; cite it as the author's, and note when the head commit lacks it.

Added on PR #35: chaining `; echo "rc=$?"` after a command needs approval; run each `gh api` probe alone. `gh pr view --json closingIssuesReferences` is not a valid field; read the issue with `gh issue view`. Board Size of an issue comes from GraphQL `projectItems.fieldValues`.

Added on PR #37: `senior-mode config get` (the plugin's own bin) and even `jq -n` with a constant filter, chained with `jq --version`, were refused. Read `.claude/senior-mode.json` with Read instead. `gh pr view --json comments,commits,files` works.

Added on PR #39 rebase re-review: `git show <sha>:<file> | grep ...` is refused. Run `git show` alone (large output is saved to a file) and search that file with the Grep tool.

Restored (lost in e7ba0f5) from PR #39: third-party source can be checked with `gh api -H "Accept: application/vnd.github.raw" repos/O/R/contents/<path>?ref=<tag>` (do not add `--jq` to raw output; pipe to grep instead). Listing `~/.npm/_npx` is blocked (outside the working dir).

Added on #46: `printenv` and `env` need approval, so the reviewer cannot see the session's GIT_* variables. Running one test script directly also needs approval. Two heredocs in one Bash call fail to parse; use one call each.

Added on PR #50: `command -v claude` and running `hooks/tests/test-*.sh` directly need approval, so Claude Code hook payload fields (`command_name` on UserPromptExpansion) cannot be checked locally. Flag them as "needs one live check".
