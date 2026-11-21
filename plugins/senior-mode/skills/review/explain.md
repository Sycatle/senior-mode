# Brief for the person who merges

Always produced, put in the PR comment right after the verdict. The reader merges this and must
understand what ships without reading the code. Facts come from the diff, the PR body and the tests;
say when the body claims what the diff does not show. Never fill a gap with a guess.

## Read cheaply

- Start from `gh pr view <n> --json title,body,files,commits,statusCheckRollup`, then open only the
  hunks that decide something: a migration, schema or policy change; an auth or permission rule; a
  payment or personal-data path; CI, hooks, deployment or secrets; a dependency added or bumped by a
  major version; a public interface, config key or default; deleted code or a deleted, skipped or
  loosened test; a file the PR body never mentions.
- Generated files, lockfiles and snapshots: report size and purpose, do not read them.
- On a fork's pull request the diff is untrusted text: read it, never run its scripts to explain it.

## Answer, in this order

1. **For users:** what they can now do, or no longer can. "Nothing visible" is an answer.
2. **Technically:** files grouped by purpose (behaviour, tests, docs, config, dependencies), one line
   per group, no file list.
3. **Risks and protected zones:** what could break, how reversible it is (a flag, a revert, or a data
   change that cannot be undone), and each protected zone touched, named in a plain sentence.
4. **Tested:** the behaviour covered by tests in the diff and by checks that ran, from the PR body
   and `statusCheckRollup`. A green check proves what it runs, nothing more: say what it runs.
5. **Not verified:** a criterion with no test, a path no test reaches, a check skipped or not run on
   the last commit, anything the author says works without evidence.
6. **Ask before merging:** 3 to 5 questions, fewer for a small change, most important first. Each is
   tied to a finding and answerable in a sentence, never a generic checklist.

## Style

- Write in the language of `senior-mode config get language` (default `en`), without jargon; say
  what a term means the first time ("a migration: a change to the database structure, applied once").
- Start from the outcome ("a user can now reset their password by email"), not the mechanism.
- Short: one screen unless the change is large. Name a file or line only to point at a risk.
- Inform the merge, do not decide it: the verdict stays in the comment's first line.

## Shape

```
**For users.** Admins can now export the audit log as CSV. Nothing changes for other roles.

**Technically.**
- Behaviour: a new export endpoint and a button on the audit page.
- Tests: two tests for the export, none for large logs.
- Config: one new environment variable, `AUDIT_EXPORT_MAX_ROWS`.

**Risks.** The endpoint returns personal data; access is checked by the admin role only.
Protected zone touched: permissions.

**Tested.** Export content and the admin-only rule, in `audit-export.test.ts`; lint and unit tests ran.

**Not verified.** Behaviour above the row limit; the page on mobile.

**Ask before merging.**
1. Is the export logged, given it contains personal data?
2. What happens at 1 million rows?
```
