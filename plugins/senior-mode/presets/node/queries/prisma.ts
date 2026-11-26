// senior-mode: query-count helper for Prisma. A list must cost the same number of queries for 1 record and for 10.
//
//   const prisma = new PrismaClient().$extends(countQueries)
//   const one = await queriesOf(() => listUsers(prisma))   // 1 record seeded
//   await expectQueries(one, () => listUsers(prisma))      // 10 records seeded: same count, or the test fails
//
// It counts Prisma operations (`$allOperations`), the unit an N+1 multiplies.
let count = 0

export const countQueries = {
  name: 'senior-mode-query-count',
  query: {
    async $allOperations({ args, query }: { args: unknown; query: (args: unknown) => Promise<unknown> }) {
      count++
      return query(args)
    },
  },
}

export async function queriesOf(fn: () => Promise<unknown>): Promise<number> {
  const before = count
  await fn()
  return count - before
}

export async function expectQueries(expected: number, fn: () => Promise<unknown>): Promise<void> {
  const actual = await queriesOf(fn)
  if (actual !== expected) throw new Error(`expected ${expected} queries, got ${actual}`)
}
