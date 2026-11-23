---
id: 0026
title: One Project and one daemon serve a product of several repositories, and an organization configures it once
status: accepted
spec: 329
amends: 0002, 0017
---

## Context

ADR 0002 puts state in one GitHub Project per repository and ADR 0017 makes `serve` one loop per repository, with its
state under that repository's `.git`. A product is often several repositories under one organization. Run as it is, it
gets a board and a daemon per repository, a change across two repositories is two unrelated tickets, and conventions are
copied into each repository. Spec 329 turns the owner's decisions of 2026-11-23 into behaviour; this ADR records the
choices that change 0002 and 0017 and the ones the owner left open (taken as the option closest to the standing goals:
throughput without loosening a gate, every choice a key, a daemon that survives, adoption without imposing, outside
input as data).

## Decision

Amending 0002 (state):

- **One Project per product.** A Project may hold the items of several repositories of its owner. A ticket is named by
  `owner/name#n`, and `board_data` keeps the items of one repository; the built-in Repository field is the key, nothing
  is created. A repository attaches to an existing Project (`setup github --project`): missing fields are added, missing
  options of existing fields are reported and never rewritten, and one repository, the home, holds the Project's duties.
  Milestones stay per repository and join by title where the critical path needs it; there is no product milestone.
- **Single-repository use is unchanged.** Every new behaviour is behind a key, a flag or a Project that has several
  repositories.

Amending 0017 (orchestration):

- **Scope is a key.** `serve.scope: project` makes one daemon serve every repository of the Project; the default `repo` is
  today's daemon. The product daemon takes each served repository's existing `serve.lock`, so the single-process rule of
  0017 holds per repository with no new mechanism, and per-repository state, leases and worktrees stay where they are.
- **A served repository is one that agrees to be.** It has an item on the Project, the Project's owner, and a config that
  names the Project (a two-way handshake). Anything else, even if an editor put its issue on the board, is never started.
- **One budget, per-repository failures.** Parallelism, hourly sessions, usage bands and slots are counted once for the
  product, slots from one machine-wide pool so ports never collide. Machine causes hold every repository; code causes
  (red main, breaker, a lost clone or repository) hold that repository only, and a repository whose poll fails is skipped
  while the others are served.
- **Cross-repo changes ship in order, never together.** The epic carries a contract and three roles (produce, consume,
  remove) with `blocked-by` edges; a step may require the previous one merged or released (`Available:`). One pull
  request closes one ticket of its own repository. A failed step stops the steps behind it and nothing else. No atomic
  merge exists.
- **The organization is a configuration layer, with limits.** `<owner>/.github`, directory `senior-mode`, read from its
  default branch (or a pinned ref), cached and never fatal, supplies base config, overrides, knowledge, ADRs and vision.
  Keys that run commands or call URLs, and keys that name the machine, are not inherited unless the repository opts in
  (`org.allowExec`); guard lists are unioned so a repository cannot remove an organization's entry; the locked safety base
  and the trust gate of ADR 0024 are not liftable by it.
- **Organizations are prepared explicitly, and their rules are respected.** `setup org` is a dry run unless `--apply`; it
  marks a real template Project and proposes the organization config as a pull request. It never writes an organization
  ruleset. `setup github` reads the effective rules of the default branch, creates only the rules that are missing, and
  reports, without working around them, those the daemon cannot satisfy (approvals, merge methods, unknown contexts):
  the daemon then does not merge in that repository.
- **One report.** `status --all` shows budget, one decision queue and one line per repository from GitHub alone.

Decisions the owner left open:

- **Where the clones come from.** `serve.repos` (a local map) first, else the daemon clones into its own data directory.
  Chosen over a required `~/Workspace` layout, which a server or a second machine does not have.
- **Who may be served.** The Project's owner only. Chosen over any repository that appears on the board, because the board
  is editable by people who do not own the code the daemon would run.
- **Budget scope.** Global caps from the anchor, a per-repository cap as a key. Chosen over per-repository budgets that add
  up to more than the machine or the account can bear.
- **Hold scope.** Repository-scoped for code causes. Chosen over one hold for the product, which lets the flakiest
  repository set the throughput of all.
- **Digest and project duties.** Under the home repository's `leader` lease. Chosen over one per daemon (a duplicate per
  machine) and over a new lease kind (nothing to add).
- **Attach.** Additive on fields, report-only on options, items moved only on `--move-items`. Chosen over a Project
  rebuilt to look like the template, which would reorder a team's board.
- **Organization actions.** Never applied by default. Chosen over automatic creation of the `.github` repository and of
  organization rulesets, which change shared infrastructure for people who did not ask.

## Alternatives considered

- **One Project per repository, joined by a script:** two boards to keep consistent, no shared queue, and drift between
  them is the thing the board exists to prevent.
- **A product daemon outside any repository (a service with its own database):** a new thing to run and secure for a tool
  whose only dependencies are `git`, `gh` and the shell, and a second source of truth (ADR 0002).
- **One daemon per repository, coordinated by leases:** correct, but each has its own budget, so three repositories on one
  machine overrun it, and a cross-repo epic has no common order.
- **Atomic cross-repo merge, by one pull request across repositories or a coordinated merge step:** GitHub has neither;
  simulating it makes a half-merged state possible with no way back. Producer-first ordering keeps every step deployable.
- **A custom Repository field:** the built-in one is already there, and a custom one would drift from it.
- **Org config fully inherited, commands included:** a write on `.github` would run code on every daemon machine. The
  opt-in costs one line per repository.
- **Reading the organization layer from any branch or from open pull requests:** unreviewed text would configure agents;
  only merged content is the organization's decision.
- **Requiring the organization's rulesets to be edited by senior-mode:** needs organization admin rights and changes other
  teams' protection; reading the effective rules is enough.
- **Pinning the organization layer by default:** every update would need a pull request in every repository, which defeats
  inheriting. `org.ref` pins where a team wants it.
- **Replacing `status` with `status --all`:** a flag keeps today's output and its scripts.

## Consequences

- Three state domains gain a scope: per repository (sessions, holds, breaker, leases, worktrees), per product (`product/`
  of the anchor: window, digest, served set) and per machine (disk, memory, auth, slot pool). Each follows the write and
  reconcile rules of ADR 0021 and spec 373, and invariant I2 now spans repositories.
- The daemon runs more code from more repositories, so the served-set handshake, the owner check and the per-item trust gate
  of ADR 0024 become the boundary; a mistake there is a security bug, and the sandbox proof includes external input in
  every repository.
- Two new modules in `bin/lib/` (`product.sh`, `org.sh`) and new refs in the CLI and the guide; the single `usage` line
  and `docs-drift` follow.
- A Project item from a repository that is not adopted is visible on the board but inert; `status` explains it. A
  repository renamed on GitHub is still served through its clone's origin.
- Cross-repository sub-issues and dependencies, `markProjectV2AsTemplate` and organization rulesets rest on GitHub
  behaviour the sandbox has to confirm (spec 329, open questions); a fallback is recorded for the first.
- The numbers that tune this (organization cache lifetimes, the number of polls before the home's duties move) are first
  values, measured by the proof and changed by configuration or a later ADR.
- ADR 0002 and 0017 are not edited; read them with this one.
