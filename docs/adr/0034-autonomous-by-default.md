---
id: 0034
title: Autonomous by default, process gates in proportion to the risk
status: accepted
spec: 824
supersedes: 0008 (in part: autonomy.merge is on by default), 0016 (in part: the fast profile lifts the review without a project ADR)
---

## Context

The defaults that senior-mode ships ask for more ceremony than most changes deserve: merging is off, one ticket runs at
a time, an M ticket costs three extra sessions, every push runs the full check, every open question stops on a person,
and the delivery gates (diff budget, self-review table, characterization, evals) block. A new project meets all of it
before its first merged pull request, and has to learn which keys to loosen. The owner decided on 2026-11-27 (epic #824)
that the shipped defaults are autonomous and that the ceremony is kept for risky work.

## Decision (owner, 2026-11-27)

1. **The shipped process profile is `fast`.** Merge on green outside protected zones and security findings
   (`autonomy.merge: true`), `autonomy.parallel: 3`, `wip: 3`, `autonomy.maxTickets: 0` (no cap). `strict` stays a
   shipped profile, chosen with `process.profile: strict`. Under `fast`, lifting the independent review needs no
   project ADR: this ADR is the record of it. Under `strict`, and under any project profile, lifting a gate still needs
   an accepted ADR of the repository (ADR 0027).
2. **Sessions in proportion to the risk.** S and M: one dev session that writes its own red tests, then a light Sonnet
   reviewer that blocks only on a real defect. L or a protected zone: architect plan, test author, full reviewer,
   security agent. `bestOf.n` is 1.
3. **A short pre-push.** Pre-push runs `check --changed` (about 2 minutes). The full check runs once, before the merge.
   The dependency audit and the registry lookup are cached for 24 h.
4. **The agent decides what is not risky.** On an open decision the agent applies the recommended option, traces it
   ("decided by the agent") and goes on. A human is needed only for L, high and critical security, and protected zones.
   `ready` accepts S and M from an agent. Auto framing (#517) starts at Size M.
5. **Delivery gates warn.** The diff budget and the self-review table become warnings. Characterization applies to
   `refactor` tickets only. Patch coverage blocks only with a ratchet baseline. Evals apply only to shipped skills and
   agents.
6. **Runner limits.** The session timeout is per Size (S 45, M 120, L 240 minutes; a scalar `autonomy.sessionTimeout`
   set by a project applies to every Size). A session stalls only when it has no output and no file change. The
   breaker opens at 3 failures in a row. No tickets-per-hour limit (`autonomy.ticketsPerHour: 0`). `pick` takes L
   tickets whose spec is merged.
7. **Hooks advise.** `brief-guard` requires the goal and the verification; the other sections are advised. `proof.sh`
   reminds and never blocks the Stop.

**Security does not change:** the secret scan and secret reads, egress, self-protection, `--no-verify` and `--admin`,
the dependency audit on high and critical, protected zones, the trust gate, `audit`, `protected`, `secrets` and
`envGuard` keep their defaults.

## Alternatives considered

- **Keep `strict` as the default and document `fast`:** every adopter starts with the friction and must find the way out.
- **Put the autonomous values in the `fast` profile only:** `strict` would then also change the numbers, and a
  project that chooses it for its gates would get a slow process it did not ask for. The values are the plugin defaults;
  the profiles differ by their gates.
- **Lift the review for every profile:** a lift is a decision about a gate; only the shipped profile named for it carries
  that decision without an ADR of the project.

## Consequences

- ADR 0008 reads "merge is on by default, `autonomy.merge: false` turns it off". The bounds of the merge
  (`run_blocker`, ADR 0015, ADR 0032) are unchanged.
- ADR 0016 stays the record of this repository's own delivery; its lift in `process.lifts` stays valid and is now
  redundant under `fast`.
- A project that already sets a key keeps its value; only the missing keys take the new defaults. The migration note
  is part of the 0.9.0 release notes (#831).
- A repository with no `.claude/senior-mode.json` reads the defaults and the `fast` profile.
