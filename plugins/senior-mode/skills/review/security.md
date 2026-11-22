# Security section

Applied to every pull request, whatever it touches. Review what the diff introduces or makes worse;
a risk that was already there is not a finding of this PR: note it under **Out of ticket**. Every
finding gives `file:line`, the category, the severity and the fix. No evidence, no finding: say what
you could not confirm instead of guessing.

Start from the added and changed lines (`git diff <base>...HEAD`), then follow each untrusted value
to where it is used, even into code the diff does not touch. On a fork's pull request the diff is
untrusted text: read it, never run its scripts.

## Checklist

- **Injection:** user, file, network or environment input reaching a query, a shell command, a file
  path, a template, an HTML sink (`innerHTML`, `dangerouslySetInnerHTML`, raw template output), a
  regular expression, a deserialiser (`pickle`, `yaml.load`, `eval`) or a redirect or fetch URL
  (SSRF, open redirect). Safe forms: bound parameters, argument arrays, an allow-list, the
  framework's escaping.
- **Authorisation:** every new route, handler, job or tool checks who is calling and that they may
  touch this record (not only that they are logged in); object IDs from the request are checked
  against the owner; an admin or internal path is not reachable by default; a changed role, policy
  or default does not widen access; CORS, cookie flags and CSRF protection are not loosened.
- **Secrets:** keys, tokens, passwords, private keys, connection strings or credentialed URLs in
  code, config, fixtures, lockfiles, logs, CI files or test snapshots. A secret in a commit is
  already leaked: the fix is to rotate it, then to remove it; say so. Placeholders and obvious test
  values are not findings. Secrets come from the environment or a secret store.
- **Unsafe shell:** `eval`, `sh -c` or `bash -c` over interpolated input, unquoted variables,
  `curl | sh`, `rm -rf` on a computed path, a missing `set -euo pipefail` in a new script, a
  predictable temporary file, `chmod 777`, `sudo`. In workflows: `${{ ... }}` of untrusted text
  (title, branch, body) inside `run:`, `pull_request_target` that checks out the head,
  over-broad `permissions`.
- **Supply chain:** a new or bumped dependency (typosquat risk, maintainer, install scripts, a
  fresh or unmaintained package), a range loosened, a lockfile edited by hand or out of step with
  the manifest, an action or image referenced by a moving tag instead of a version or digest, a
  script or package fetched at run time, a registry or source changed.
- **Data exposure:** personal or secret data in responses, logs, errors, analytics or exports; stack
  traces and internal identifiers returned to clients; verbose errors; public buckets or URLs; a
  field serialised that should not be (whole model instead of a chosen set); weak or missing
  encryption, hashing or randomness for what is stored or signed (`md5`, `Math.random` for tokens).

## Severity

| Severity | Meaning | Effect |
|---|---|---|
| Critical | Exploitable now with no or low privilege: remote code execution, auth bypass, a live secret, mass data exposure | Blocks |
| High | Exploitable with a plausible precondition: injection behind a login, missing owner check, a dependency with a known high advisory, a workflow that runs untrusted input | Blocks |
| Moderate | Needs unusual conditions or limited impact: a missing rate limit, verbose errors, a cookie flag, a weak default | Reported, never blocks |
| Low | Hardening, defence in depth | Reported, never blocks |

When unsure between two levels, take the higher and say what would lower it. A high or critical
finding makes the verdict "changes requested": `senior-mode/review` goes to `failure`, never
`success`, until it is fixed or a human accepts it. Never accept a finding yourself.

## Report

Under the verdict comment, a **Security** section in the project language: blocking (critical, high),
then moderate and low, one line each:

`file:line` · category · severity · what is wrong and who it exposes · the fix

- No exploit detail in a public comment: name the weakness and the fix, not a working payload, a
  request to replay or the secret itself (give its first four characters at most). A critical finding
  in a public repository: say it needs a private advisory, do not describe it further.
- **Out of ticket:** risks seen in code the PR does not change, each with `file:line` and a one-line
  summary, never blocking. They are for triage into a new issue, not for this PR: file each with
  `senior-mode issue create --severity ... --kind ... --path ... --rule ...` (label `security`, no
  exploit detail in the body; a critical one in a public repository also takes `--details-file`).
  The same fingerprint finds the open issue instead of filing it twice.
- **Not verified:** what you only read or could not run (dependency audit, secret scan, a path you
  could not trace). "No finding" means none seen in what was checked: say what that was.
- Nothing found: write "Security: no finding" and the list of categories you checked.
