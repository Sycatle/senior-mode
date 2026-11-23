---
id: 0027
title: Customization through hooks, roles and routing that add to the safety base and never lift it
status: accepted
spec: 330
amends: 0004, 0010, 0014
---

## Context

ADR 0010 gave client needs five extension points (`checks`, project skills and agents, `review.sections`, `docs.extra`,
`envGuard.forbidden`). They cover what to check, not when to react, who else reviews, or which model does the work. ADR 0004
pins a model per agent in its front matter and ADR 0014 retries a failed ticket once on Opus; a team cannot say that docs
tickets run on Haiku, that a UI change needs a designer's review, that a merge waits for a release freeze, or that a
local model takes the small chores. The owner decided on 2026-11-23 (epic #330) that every part of the experience is
configurable, with one limit: the safety base. The daemon also runs unattended on the owner's machine and reads text
from outside the team (ADR 0024), so each lever is code or a prompt that must not be a way in.

## Decision (owner, 2026-11-23, with the choices taken in the spec)

- **Four keys and a directory are the customization surface.** `hooks`, `roles`, `models` and `providers` in
  `.claude/senior-mode.json`, with their files under `.claude/senior-mode/{hooks,roles,overrides}/`. Each is in the
  schema (#317), documented in `configuration.md`, and shown by `config explain` and `doctor`.
- **Read from the base branch, reviewed by the owner.** The daemon and its sessions read the customization from
  `origin/<base>`, never from a pull request head. The files are `protected` by default (CODEOWNERS), and an agent cannot
  edit them during a run. A hook defined by a layer above the repository runs only when the repository lists it in
  `hooks.enable`.
- **Levers add; none lifts.** The locked base is the secret scan, the protected zones, the bash guard, no force-push or
  `--no-verify`, a green `check` before a merge, the independent review and, added here, the trust gate of ADR 0024. A hook
  can hold or refuse, never approve; a role adds a reviewer or a step and never replaces the built-in reviewer or sets a
  status; a routing row stays inside the floors. Lifting a rule stays the explicit repository ADR of #307, flagged by
  `status` and `doctor`.
- **Event hooks.** Nine events with one versioned JSON payload on stdin (no bodies or comments, `external` flagged). Scripts
  live under `.claude/senior-mode/hooks/`, run from their blob on the base branch with a scrubbed environment and a timeout;
  a `url` form signs the body with an HMAC. Two events block, `ticket.starting` and `pr.merging`, with exit codes 0 (no
  objection), 10 (hold, evaluated again next poll) and 11 (refuse, `needs-human`); an error or timeout of a blocking hook
  fails closed. Non-blocking delivery is at least once from a journal, with a stable event id, off the poll's critical
  path. Within a payload version fields are only added; a breaking change is a new version, with the old one kept for two minor
  releases.
- **Custom roles.** A role is an agent file plus triggers (`paths`, `labels`, `sizes`, `types`), a model and effort, a budget
  and a kind: `reviewer` (read-only, runs beside the reviewer on the head) or `step` (a session before or after the ticket
  session, under the implementer's guards). A blocking reviewer role's `approve` for the head is a condition of the daemon's
  merge gate, recorded as a comment by the daemon's account so GitHub stays the truth; the commit statuses and the ruleset
  do not change. No role runs on an outside pull request.
- **One routing table.** `models` rows match on role, size and type; the most specific wins, then the higher layer. The
  plugin's defaults are rows and reproduce ADR 0004 and 0014. Rows carry escalation steps, a fallback model for transient
  overload and a budget (sessions, minutes, API-equivalent cost), checked between sessions; an exhausted budget is
  `needs-human` and does not count for the breaker. Models have a tier (`haiku` 1, `sonnet` 2, `opus` 3, or declared); the
  reviewer and security roles are never below the implementer's tier nor on its model. Other providers are environment
  variables of the same Claude Code session (`providers`, secrets by variable name only), so the guards still hold.
- **Customization never stops the daemon.** A faulty customization is classed and handled, not escalated to a ticket
  failure: a rejected model is class `config` and uses the plugin's default row once; an invalid config merged into the base
  leaves the last valid snapshot in force with one alert. Its cases join the chaos suite of spec 373.

This amends ADR 0004 (the per-role model is the default row of a table, not only the agent front matter), ADR 0010 (the
extension points gain hooks, roles and routing, still with no client or vendor in the core) and ADR 0014 (escalation is a
row's list; `autonomy.escalate: false` stays the master switch).

## Alternatives considered

- **A plugin API with in-process extensions:** the most flexible, but a second language and runtime in a bash CLI, no sandbox,
  and a bar to review that few owners meet. Scripts with a JSON contract cover the cases the owner named, at a boundary
  that can be tested and killed.
- **A shell command string per event in the config:** simple, but a title or label interpolated into a command is an
  injection from outside the team. A script that reads JSON on stdin removes the interpolation.
- **Let a hook approve (return "merge it"):** it would let a script replace a gate. A veto-only hook covers the freeze and
  compliance needs and cannot weaken anything.
- **Run hooks from the working tree or the pull request head:** a pull request could then run code on the agent machine before
  review. The base branch's blob is what the owner reviewed.
- **Webhooks only (what `notify.webhook` is):** no way to block, and a local script needs a server. Both forms stay, and `notify.*`
  is unchanged.
- **A required status per role:** it shows in the ruleset, but adds contexts that every repository must configure and that
  the local CI of ADR 0006 does not publish. The merge gate and a marker comment carry the same decision without touching the ruleset.
- **A role may set `senior-mode/review`:** it would break the rule that the status is set by the independent reviewer session.
- **Replace built-in agents through `roles`:** a role named `reviewer` would sidestep the floors. Replacement stays an
  override file (#307), which keeps them.
- **The model only in each agent's front matter (today):** no size or type dimension, no budget, no escalation to choose.
  Adaptive routing (#365) also needs a table it can edit as data.
- **Fail closed on an invalid config (stop the daemon):** safe but it halts all work for a typo merged on a Friday. The last
  valid snapshot keeps the owner's last reviewed rules in force and says so.
- **Fall back silently to the plugin default on any hook error:** blocking hooks are the owner's controls (a freeze); an
  error that releases the action would defeat them. They fail closed unless `onError: "ignore"` says otherwise.

## Consequences

- More surface in `serve`, `run`, `check`, `status` and `doctor`, in two modules (`events.sh`, `routing.sh`); the schema and the
  frozen payload fixtures become a contract that a test guards.
- A project can change behaviour without forking, and the changes are visible in one place: `doctor`, `status` and `config explain`.
- A hold by a hook can delay work indefinitely; the 24 h alert and `doctor` make it visible, and the owner removes the hook by a
  reviewed change.
- Roles and steps lengthen a ticket's pipeline and cost sessions; budgets, triggers and the parallel review bound it.
- Setup now protects `.claude/senior-mode.json` and `.claude/senior-mode/**`, so an adaptive-routing proposal (#365) or a
  config change always waits for a human merge.
- A provider's models are only as guarded as Claude Code's hooks make them; routing a judging role to a lower tier or the
  implementer's model is refused rather than allowed.
