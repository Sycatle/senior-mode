# Reliability section

Read when the diff touches handlers, routes, jobs, queues, queries, outbound calls or logging. Review
what the diff adds or changes. Every finding gives `file:line`, blocking or not, and the fix; no
evidence, no finding.

## Blocking

- **Personal data or a secret in a log or an error message:** a request body, header, token, email,
  phone, address or identifier written to a log, a trace or an error text. Fix: log the field names or
  an opaque id, never the value.
- **Unvalidated entry point:** a route, handler, webhook, job or form that reads its input without a
  schema (zod, pydantic, serde, the project's). Fix: parse at the entry, reject what does not match.
- **Retry without idempotence:** a retry of a write with no idempotency key, or with no backoff. Fix: a
  key, exponential backoff with a cap, retries only on idempotent operations.
- **Write across several tables outside a transaction**, or a concurrent read-then-write with no lock
  and no database constraint. Fix: one transaction; a row lock or a unique constraint.
- **Swallowed error:** caught and dropped, or turned into a bare string the caller cannot act on.

## To review

- Errors carry context (what failed, on which input) and a type the caller can act on; logged once, at
  the boundary, not at every layer that rethrows.
- Configuration is read and validated by a typed schema at boot and fails fast, not read ad hoc where it
  is used.
- Outbound calls have a timeout.
- A service has the minimum observability: structured logs with a correlation id per request, a health
  endpoint, errors sent to the project's tracker when it has one. Ask for it only when the diff creates
  the service or its entry points.

## Report

Name `reliability.md` under the sections applied, even with no finding ("Reliability: no finding", and
what you checked).
