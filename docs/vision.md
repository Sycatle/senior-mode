# Vision

Status: draft (agent, 2026-11-27), owner validation pending

Drafted from the goals and non-goals of `docs/specs/*.md`, ADR 0034 and the owner decisions of 2026-11-27. Until the
owner validates it, `frame` and the briefing apply it as written; the owner changes it by editing this file.

## Goals

- G1: Turn an idea into a prioritised, milestone-ordered GitHub Project of ready tickets, through a short interview.
- G2: Deliver tickets with TDD, small conventional commits, fresh-context review and green checks, interactively or
  autonomously, day after day.
- G3: Autonomous by default, with process gates in proportion to the risk: the agent decides what is not risky, a
  human decides L tickets, high and critical security, and protected zones (ADR 0034).
- G4: Keep a project healthy when agents build it for months: a ranked briefing from the ticket's Paths, notes,
  ADRs, a generated architecture map, and debt that is measured, frozen and ticketed.
- G5: Adapt to the existing project (branch model, commit format, CI, debt) instead of imposing the defaults.
- G6: Stay fast and safe at scale: parallel tickets, one merge at a time, a daemon that survives crashes, sessions
  that cannot reach what they should not.
- G7: Keep every change auditable: commit, pull request, issue, spec, ADR.
- G8: Let a project shape the process (levers, profiles, roles, model routing) by adding checks, holds and
  reviewers, never by lifting a security rule.
- G9: Serve one product across several repositories under one board and one daemon, delivered from producer to
  consumers.

## Non-goals

- Not a project-management SaaS: GitHub is the only store of state; no other tracker, no hosted service, no database
  and no inbound endpoint. Everything runs on the owner's machines with `git`, `gh` and the shell.
- No estimation in hours or points: size is S, M or L.
- No hosting or deployment platform of its own; presets wire the project's existing one.
- No model API billing: sessions use the subscription's authentication only, and there is no API-key fallback.
  Spend caps (ticket, day, week) exist and are off by default.
- No paid GitHub organization required: organization and multi-repo features are built and proven on stubs and
  recorded answers; what needs a paid plan is documented, not claimed.
- No notification sent without a configured key, token or URL: ntfy, Telegram and healthchecks are opt-in and off by
  default.
- No change to who reviews or merges outside ADR 0034: a merge stays `gh pr merge --rebase --match-head-commit` on a
  head with `ci`, `review` and `security` success, with no bypass actor and no atomic merge across repositories.
- No lowering of a security rule: the secret scan, egress, protected zones, the trust gate and the dependency audit
  hold in every project; a lever adds, it never lifts (ADR 0027).
- No defence against a compromised machine or a malicious owner (ADR 0015): the host, the container runtime and the
  model credential stay trusted.
- No making an external contribution trusted: what comes from outside is data (ADR 0024).
- No migration of a project to senior-mode's workflow and no synchronisation of an external tracker; no fixing of
  existing debt during adoption.
- No plugin API, in-process extension, second agent CLI or domain pack in the core (ADR 0010).
- No several products on one Project and no agent identity of its own.

## Constraints

- The core is generic: no client, stack or regulation leaks into it.
- A repository that does nothing keeps working: every feature is off or inert until it is set up.
