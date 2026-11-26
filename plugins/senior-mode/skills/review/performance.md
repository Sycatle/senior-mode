# Performance section

Read when the diff touches application code; not for a diff of docs, configuration or tests alone. Judge
only what the diff adds or changes: untouched slow code is not a finding of this PR, file it with
`senior-mode issue create`. Rules a tool already checks (`check` fails on `SELECT *`, `findMany` with no
`take`, I/O in a loop, a blocking call in a handler, a missing foreign-key index, a benchmark regression)
are not repeated here: this is what no tool decides. Every finding gives `file:line`, blocking or not,
and the fix; no evidence, no finding, and no guess about speed without a reason from the code.

## Database

- **Blocking: a list endpoint or a journey with no query-count assertion.** The test asserts the same
  query count for 1 and for 10 records through the project's helper (`performance.queries.helper`). Fix:
  add the assertion.
- **Blocking: a query filtering (`where`, `WHERE`, `filter`) or sorting (`orderBy`, `ORDER BY`,
  `order_by`) on a column with no index** in the schema or the migrations. Not blocking when the spec
  declares the table small, or when you say why the table stays small. Fix: an index, in a migration
  safe for a live table (`CREATE INDEX CONCURRENTLY` on Postgres).
- **Blocking: a rename or a drop that the previously deployed version still reads.** Fix: expand then
  contract, in separate pull requests (`compatibility.md`). Where `check` reports `migrations: not
  measured`, apply that checklist yourself: no `NOT NULL` column without a default, no type change in
  place, no long lock.
- **Flag, not blocking:** a SQLAlchemy `.all()` or a Django queryset returned from a view or handler
  with no slice or limit (no mechanical rule: too many false positives). Fix: paginate or limit.
- A new query inside a loop that `check` cannot see (a helper called per item, a lazy relation read in a
  template or serializer): the N+1 of the criterion above, blocking.

## Code

- **Complexity on data that grows:** nested loops over two collections, `includes` or `find` inside a
  loop, sorting inside a loop, string concatenation in a loop, a quadratic scan where a map or a set
  gives a lookup. Say what grows (rows, users, events) and the fix.
- **Repeated work** that a cache or a precomputation removes: the same call with the same arguments in
  a request, a value computed on every render or call that depends on nothing that changes, a
  configuration or file read on every request. A cache needs a key, a bound and an invalidation; one
  without them is a finding of its own.
- **Memory held for the life of a process:** a module-level map, array or cache that only grows, a
  listener or timer never removed, a whole file or result set loaded to read part of it. Fix: bound it,
  stream it, or scope it to the request.
- **Payloads that grow with data:** an endpoint, event or job that returns or sends every row or every
  field, with no pagination, no limit and no field selection. Fix: paginate and select.

## Report

Name `performance.md` under the sections applied, even with no finding ("Performance: no finding", and
what you checked). Say what you could not measure: a read is not a benchmark.
