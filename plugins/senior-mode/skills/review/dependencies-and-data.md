# Dependencies and data section

Read only when dependencies change or the diff handles data. Facts for a human who decides: whether a
licence or a data flow is acceptable is not your call, so list it under **For a human** with its
evidence. Every finding gives `file:line` or the lockfile entry; no evidence, no finding.

## Dependencies

Look up only what the diff adds or changes:

```sh
git diff <base>...HEAD -- package.json package-lock.json pnpm-lock.yaml yarn.lock \
  pyproject.toml requirements*.txt uv.lock poetry.lock Cargo.toml Cargo.lock go.mod go.sum
```

Get each licence from the ecosystem's own tool, only when the tool and the installed dependencies are
there; otherwise read the package metadata and say so.

| Ecosystem | Command | Notes |
|---|---|---|
| pnpm | `pnpm licenses list --prod --json` | Grouped by licence; drop `--prod` to include dev dependencies |
| npm | no licence command | `license` field of each entry in `package-lock.json` (lockfile v2+), or of `node_modules/<pkg>/package.json` |
| yarn 1 | `yarn licenses list` | Not in Yarn Berry: read `node_modules/<pkg>/package.json` |
| Python | `pip-licenses --format=json` | Third-party (`pip install pip-licenses`, or `uvx pip-licenses`); reads the active environment |
| Rust | `cargo deny list --format json` | Needs `cargo-deny`; lists `unlicensed` crates, including the project's own |
| Go | `go list -m -json all` | Built in; gives each module's `Dir` (module cache), where `LICENSE` is read. `go-licenses report ./...` when installed |

- Compare with the project's own `LICENSE` and how the code ships (a service, a library, a bundled
  app). Flag copyleft (GPL, AGPL, LGPL, MPL, EUPL, SSPL), non-commercial or "source available" terms,
  and missing or unknown licences (`UNLICENSED`, `SEE LICENSE IN ...`, a bare file, empty): list the
  unknown ones, do not interpret them. MIT, BSD, Apache-2.0 and ISC need no flag.
- A major version bump is a protected zone (see the protected-zone rule in `SKILL.md`).

## Secrets and personal data

Search the diff for:

- Fields, columns and models that hold names, emails, phone numbers, addresses, IPs, device or user
  identifiers, locations, payment or health data, or free text users fill.
- Logs, error reports, analytics events and traces that carry request bodies, headers, tokens or
  identifiers. A secret in a log, an export or a fixture is a blocking finding on its own.
- Exports and files (CSV, PDF, backups, seeds, fixtures) with real-looking data.
- Who can read it: access policies, roles, routes without authorisation, public buckets.
- Retention: TTLs, deletion paths, soft deletes that never purge. No evidence of deletion means "to
  confirm", not "none".

## New third-party services

APIs, SDKs, and scripts, fonts or trackers loaded from a third party, in the back end or the front
end. One line each: provider, purpose, data sent, where it is configured (`file:line`), hosting
region only if the repo states it. Whether the data may go there is a question for a human.

## Report

Under the verdict comment, in the project language: blocking, then to review, then **For a human**
(what the repo cannot answer: retention, region, contract, licence fit), then what could not run.
