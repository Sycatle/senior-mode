# Compatibility section

Read when the diff touches a public API, an exported package interface, a schema or migration, a config
or file format, or an event or message. The question: does the change work with the version that is
deployed now, and with the one that rolls back to? Every finding gives `file:line`, blocking or not,
and the fix; no evidence, no finding.

## Blocking

- **A breaking change in one step:** a column or table renamed or dropped, a type narrowed, a column
  made `NOT NULL` without a default, a field removed or renamed in an API response, an event, a config
  key or a file format that the previous version still reads or writes. Fix: expand, then contract,
  across separate pull requests: add the new shape and write both, migrate the data, switch the
  readers, then remove the old shape in a later pull request. Or put the change behind a feature flag.
- **A removal with no deprecation:** a public function, endpoint, option or export deleted at once.
  Fix: deprecate it first (a warning, a documented replacement), remove it in a later release.

## To review

- A migration can run while the old code still serves: no table lock held for long, no backfill in the
  same transaction as the schema change.
- A new required input of a public API has a default, or the version is bumped.
- The version or the changelog says so: a breaking change bumps the major version (or is named as such
  by the project's rule), a deprecation is listed.
- A consumer that is not in this repository (a client, a webhook receiver, a stored file) is named as
  a risk under **For a human**, not guessed at.

## Report

Name `compatibility.md` under the sections applied, even with no finding ("Compatibility: no finding",
and what you checked).
