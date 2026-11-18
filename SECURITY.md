# Security policy

senior-mode runs inside Claude Code with your permissions: its hooks and its CLI execute shell
commands, call the GitHub API with your `gh` token, and can merge pull requests in autonomous runs.
A flaw that lets a prompt, a file or a pull request bypass its guardrails is a security issue.

## Supported versions

Only the latest release receives fixes.

## Reporting a vulnerability

Report it privately through GitHub:
[Security → Report a vulnerability](https://github.com/Sycatle/senior-mode/security/advisories/new).
Do not open a public issue.

Include what an attacker can do, the steps to reproduce, and the version or commit. You will get an
answer within a week; a fix and an advisory follow once the issue is confirmed, crediting you unless
you prefer otherwise.
