// senior-mode: axe accessibility check for the journey E2E tests (Playwright, @axe-core/playwright).
//
//   await expectAccessible(page, 'checkout')    // after each page the journey visits
//
// Serious and critical violations fail the test, naming the axe rule id, the selector and the page. Moderate and minor
// ones are printed and never fail. A serious violation counted in `.claude/ratchet-baseline.json` under `a11y`
// ({"total": n, "journeys": {"<journey>": {"<rule>": n}}}) passes up to its count; `senior-mode check --update-baseline`
// only lowers it. What a journey measured goes to `test-results/a11y/<journey>.json` (SENIOR_MODE_A11Y_DIR, or
// `ratchet.a11y.report`), which the baseline update reads.
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'

export type AxeResult = { violations: { id: string; impact?: string | null; nodes: { target: unknown[] }[] }[] }
export type Finding = { journey: string; page: string; rule: string; impact: string; selector: string }
export type Baseline = { a11y?: { journeys?: Record<string, Record<string, number>> } }

const gating = new Set(['serious', 'critical'])
const measured = new Map<string, Finding[]>()

export function findings(journey: string, page: string, result: AxeResult): Finding[] {
  return result.violations.flatMap((v) =>
    v.nodes.map((n) => ({ journey, page, rule: v.id, impact: v.impact ?? 'minor', selector: n.target.flat().join(' ') })),
  )
}

const line = (f: Finding) => `${f.rule} (${f.impact}) ${f.selector} on ${f.page}`

// The serious and critical findings of a journey beyond what its baseline allows per rule fail; the rest is reported.
export function judge(all: Finding[], baseline: Baseline): { failures: string[]; reports: string[] } {
  const allowed = (f: Finding) => baseline.a11y?.journeys?.[f.journey]?.[f.rule] ?? 0
  const gated = all.filter((f) => gating.has(f.impact))
  const count = (f: Finding) => gated.filter((g) => g.journey === f.journey && g.rule === f.rule).length
  const failures = gated.filter((f) => count(f) > allowed(f)).map(line)
  const reports = all.filter((f) => !gating.has(f.impact) || count(f) <= allowed(f)).map(line)
  return { failures, reports }
}

export function readBaseline(path = '.claude/ratchet-baseline.json'): Baseline {
  try {
    return JSON.parse(readFileSync(path, 'utf8'))
  } catch {
    return {}
  }
}

export async function expectAccessible(
  page: { url(): string },
  journey: string,
  opts: { baseline?: string; dir?: string } = {},
): Promise<void> {
  const { default: AxeBuilder } = await import('@axe-core/playwright')
  const result = (await new AxeBuilder({ page } as never).analyze()) as AxeResult
  const all = [...(measured.get(journey) ?? []), ...findings(journey, page.url(), result)]
  measured.set(journey, all)
  const dir = opts.dir ?? process.env.SENIOR_MODE_A11Y_DIR ?? 'test-results/a11y'
  mkdirSync(dir, { recursive: true })
  writeFileSync(`${dir}/${journey}.json`, JSON.stringify(all.filter((f) => gating.has(f.impact))))
  const { failures, reports } = judge(all, readBaseline(opts.baseline))
  if (reports.length) console.warn(`a11y (not failing):\n${reports.map((r) => `  ${r}`).join('\n')}`)
  if (failures.length) throw new Error(`a11y violations:\n${failures.map((r) => `  ${r}`).join('\n')}`)
}
