# Journey that lists records: reference

A list endpoint, page or job that reads one query per record is correct and slow, and no assertion on the
returned rows notices. Its journey test asserts the number of queries instead, through the helper that
`senior-mode setup repo` offered at `performance.queries.helper` in `.claude/senior-mode.json`.

## The test

1. Seed 1 record, run the journey through the helper, keep the count.
2. Seed 10 records, run the same journey, assert the same count.
3. Run it red against the list as written: an N+1 fails with `expected <n> queries, got <m>`.

| ORM | Helper |
|---|---|
| Prisma | `const one = await queriesOf(() => list(prisma))`, then `await expectQueries(one, () => list(prisma))`; the client is built with `.$extends(countQueries)` |
| SQLAlchemy | `with count_queries(engine) as one:`, then `with expect_queries(engine, one.count):` |
| Django | `with count_queries() as one:`, then `with expect_queries(one.count):` |
| sqlx | `let (one, _) = queries_of(list(&pool)).await;`, then `expect_queries(one, list(&pool)).await` |

The first lines of the helper file show the same example. Without `performance.queries.helper`, the project
has no supported ORM (`queries: not measured`): say so in the test report and do not invent a counter.
