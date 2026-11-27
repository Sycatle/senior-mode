---
id: 824
title: Autonomous defaults, process gates in proportion to the risk
status: accepted
size: L
paths: ["plugins/senior-mode/bin/**", "plugins/senior-mode/hooks/**", "plugins/senior-mode/profiles/**", "plugins/senior-mode/schema/**", "plugins/senior-mode/skills/frame/**", "docs/guide/**"]
adrs: ["0034", "0008", "0016", "0027"]
issue: "#824"
---

# Autonomous defaults, process gates in proportion to the risk

## 1. Goal and non-goals

The defaults that ship with senior-mode carry the ceremony of a risky change on every change: merge off, one ticket at
a time, extra sessions on every M ticket, a full check on every push, a human stop on every open question, blocking
delivery gates. The goal is a first run that goes from ticket to merged pull request with no key set, and ceremony
only where the risk is. The owner decisions of 2026-11-27 (ADR 0034) are fixed; this spec makes them testable.

Non-goals:

- Any change to the security gates: secret scan and secret reads, egress, self-protection, `--no-verify` and `--admin`,
  the dependency audit on high and critical, protected zones, the trust gate.
- Removing the `strict` profile: it stays shipped and chosen with `process.profile: strict`.

## 2. Decisions

| # | Decision | Value |
|---|----------|-------|
| 1 | Shipped profile | `fast`; `autonomy.merge` true, `autonomy.parallel` 3, `wip` 3, `autonomy.maxTickets` 0 (no cap); `fast` lifts `review` with no project ADR |
| 2 | Sessions by risk | S and M: dev session with its own red tests, light Sonnet reviewer; L or protected zone: plan, test author, full reviewer, security agent; `bestOf.n` 1 |
| 3 | Check | pre-push runs `check --changed`; full check once before the merge; audit and registry cached 24 h |
| 4 | Open decisions | the agent applies the recommended option and traces it; a human for L, high and critical security, protected zones; `ready` accepts S and M from an agent; auto framing from M |
| 5 | Delivery gates | diff budget and self-review table warn; characterization for `refactor` only; patch coverage blocks only with a ratchet baseline; evals for shipped skills and agents only |
| 6 | Runner | timeout S 45, M 120, L 240 minutes; stall needs no output and no file change; breaker 3; `autonomy.ticketsPerHour` 0 (no limit); `pick` takes L tickets with a merged spec |
| 7 | Hooks | `brief-guard` needs goal and verification; `proof.sh` reminds, never blocks |

## 3. Children

| Child | Ticket | Scope |
|-------|--------|-------|
| A | #825 | defaults and profiles: decisions 1 and 6 (values) |
| B | #826 | run sessions by risk: decisions 2 and 4 |
| C | #827 | check and pre-push: decision 3 |
| D | #828 | ready and delivery gates: decisions 4 (ready side), 5 and 6 (`pick`) |
| E | #829 | runner limits: decision 6 |
| F | #830 | process hooks and frame: decisions 4 (framing) and 7 |
| G | #831 | docs and the migration note of 0.9.0 |

## 4. Acceptance

- Each child states its criteria in its own ticket; none lowers a security gate.
- A project that sets a key keeps its value; only missing keys take the new defaults.
