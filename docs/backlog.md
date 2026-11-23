# Backlog

Framed on 2026-11-21, re-framed the same evening. senior-mode is the working method of a top-tier
engineering team in the age of AI agents, packaged as a plugin. It is generic: no client, stack or
regulation leaks into its core.

## Principles (re-framing)

- **Lifecycle + roles, few skills.** Every skill is a step of the lifecycle and a role of the team:
  lead (triage, frame, spec, adr, grill, ready), developer (tdd, verify, commit), reviewer (review),
  release and ops (run, next, status, docs), learning (retro). Anything that fits no step leaves.
- **Generalise or remove.** `explain`, `ui-review` and the licence/personal-data part of `compliance`
  become sections of `review`; `refactor` becomes a mode of `tdd`; `docs` is generic living docs
  (README, architecture, user-facing changelog, ADRs), no auditor templates; the nextjs-supabase preset
  becomes Next.js awareness in `node` plus a generic environment guard ("no production environment
  on an agent machine"); `mirror` is ops, out.
- **Extension points for client needs.** Project checks (`checks`), project skills and agents in the
  project's `.claude/`, and project review sections loaded by `review`. Regulated, governance or
  stack-specific packs live in the client's repositories, built with the client.
- **Dogfooding before merge.** Besides `check`, every command and skill runs in a real `claude -p`
  session on a sandbox repository with a board; the result goes in the PR. Unverified = not merged.

## Decisions

- **Orchestration (hybrid):** `run` launches one headless `claude -p` per ticket in its own worktree
  and tmux window; the agent team runs as subagents inside. ADR 0007.
- **Merge:** configurable, off by default (`autonomy.merge: false`; the spec's `autoMerge` is renamed).
  ADR 0008, partially supersedes 0003.
- **Scheduled runs:** local systemd timer or cron, subscription login; no Actions, no API key.
- **Model escalation:** a ticket that fails on Sonnet is retried once on Opus.
- **French:** no `senior-mode-fr`; French triggers in descriptions + `language` key.
- **Visibility:** `status --watch` + statusline; rich UI left to syacode.
- **Digest for non-technical readers:** user-facing changelog of `docs` + `status --since`.
- **Agent machines:** non-root user, `claude` resolved outside non-login PATH; GitHub Free fallback.
- **Later:** evals and marketplace (v1.0) after real use. The release-please start version from
  Cargo.toml / pyproject.toml is delivered (#99, #168).

## Shared contract

Config keys: `autonomy.maxTickets` (3), `autonomy.parallel` (1), `autonomy.merge` (false),
`autonomy.maxConsecutiveFailures` (2), `autonomy.escalate` (true), `e2e.slots` (2), `protected`,
`secrets`, `envGuard.forbidden` (patterns that must never appear in env files or env vars),
`github.protection`, `review.sections` (project checklist files), `language`.
Env `SENIOR_MODE_RUN=1` during a run. Shared bin helper: `senior-mode pick`.

## Status (2026-11-23)

- Released: 0.2.0 (2026-11-22), 0.3.0, 0.4.0 and 0.5.0 (2026-11-23). Milestones v0.1 to v0.5 are closed
  with no open issue.
- Done: rework, wave 2, retro, ADRs 0007-0014, all in PR #113 (`integration/tonight`, 80 commits,
  closes #71-#111, supersedes #79 #82 #85); the security wave (0.3.0), the autonomy daemon `serve`
  (0.4.0) and the board wave (0.5.0).
- Dogfooded on Sycatle/senior-mode-sandbox: setup, frame, and run, schedule, next, retro, review, docs
  (#133-#138); the daemon with parallel tickets and provoked conflicts (#157).
- Left: milestone v1.0 (#132, #158, #159, #160), and #169 and #175, deferred by the owner, no milestone.

## Decisions (framing 2026-11-22)

- **Exception to ADR 0011:** #113 is merged without dogfooding run, schedule, next, retro, review and
  docs; they are dogfooded on main afterwards. Say so in the PR.
- #112 and #114 go into #113 before the merge.
- #58 docs pass and #64 spec/doc drift land after the merge, before the release.
- Release 0.2.0 right after; 1.0 stays for evals + marketplace after real use.

## Security wave (framing 2026-11-22, after 0.2.0, ships as 0.3.0)

Mission: a proactive team, pragmatic, paranoid about quality and above all security.

- **Two levels:** `review` gets a full Security section (threats, OWASP, supply chain), always applied;
  a dedicated `security` agent runs on L tickets and protected zones (threat model + blocking findings).
- **`check` presets:** native dependency audit (npm/pnpm audit, pip-audit, govulncheck, cargo audit)
  and a secret scan of the diff with no new dependency; blocking on high and critical only.
- **Proactivity:** a risk outside the current ticket becomes a triaged board issue (severity, size,
  proposed fix), never code in the current ticket; critical security issues go to the top of Ready.
- ADR on the security posture.

## Road to 1.0 (framing 2026-11-22)

- **Scope:** 0.2.0, security wave (0.3.0), dogfooding of the six untested commands with fixes,
  evals green, 1.0 on the marketplace (spec §19). Spec/code drift stays planned, not in 1.0.
- **Autonomy:** PR, reviewer agent, rebase merge and 0.x releases chain without asking. Stop before
  the 1.0 release and the marketplace publication, and on any blocking finding that needs a decision.
- **Dogfooding:** real `claude -p --plugin-dir` sessions on Sycatle/senior-mode-sandbox, run and
  schedule with `autonomy.merge: false`, on sya-dev-01 as a non-root user. Findings become issues.

## Autonomy target (framing 2026-11-22, wave v0.4, delivered in 0.4.0)

Goal: the human only frames; on the VPS, sessions run continuously over every Ready issue by
priority, massively parallel, isolated, with senior-level rigour enforced by the tool, not advised.

- **Orchestration:** `senior-mode serve`, a systemd service that polls the board and launches ticket,
  reviewer and integrator sessions within the ceilings; `run`/`schedule` become one-pass cases.
  ADR partially superseding 0007 and 0012.
- **Independent review:** a separate reviewer session (fresh context, Opus) is the only one allowed to
  set `senior-mode/review`; the guard denies `gh api .../statuses` to ticket sessions. Changes
  requested: the ticket session resumes with the findings, 2 rounds max, then `needs-human`. The
  `security` agent adds a mandatory pass on L or sensitive pull requests.
- **Integrator:** a sequential merge queue by priority: rebase on main, resolve conflicts (Opus),
  rerun checks, re-review when the resolution changed code, merge one at a time; unresolved conflict
  or protected zone: `needs-human`.
- **Collisions:** tickets declare the paths they touch (spec `paths` or architect estimate at
  framing); overlapping tickets never run at the same time.
- **Isolation:** worktree + slot per session; slot-derived env (PORT, database/schema, cache dir)
  through a project `slot` hook in `.claude/senior-mode.json`; non-root user.
- **Ready without the human:** after the framing PR merges, tickets passing the Definition of Ready
  become Ready; agent-created issues too when S, not high/critical security and outside protected
  zones; otherwise `needs-human`.
- **Alerts:** configurable: GitHub (`needs-human` label + mention, daily `status --since 24h`
  digest) and/or a generic `notify.webhook` (JSON POST).
- **Ceilings:** `autonomy.parallel` slots, sessions per hour, pause on subscription rate limit and
  resume at reset, circuit breaker pauses and alerts instead of stopping, CPU/memory checked before
  each launch.
- **Merge:** in daemon mode `autonomy.merge` is on for S and M with everything green, no protected
  zone and no security finding; L, ADRs and protected zones wait for the human. Amends ADR 0008.
- **Proof:** sandbox first (parallel toy tickets, provoked conflicts), then the daemon develops
  senior-mode itself on sya-dev-01; 1.0 after a week of daemon on our own backlog without incident.

Order: board rigour -> 0.2.0 -> security 0.3.0 -> autonomy daemon 0.4.0 -> proof -> evals -> 1.0.

## Decisions (framing 2026-11-22, the backlog lives on the board)

- Everything still to come is an issue on the board; this file keeps the why, not the list.
  Waves not yet framed are an L epic with their known pieces as Backlog sub-issues: none is Ready
  before the wave's framing (spec, ADRs, human acceptance).
- Dogfooding of run, schedule, next, retro, review and docs was in v0.3, before the security work:
  its findings fed both waves. Claude being logged in on sya-dev-01 (#132) is now a v1.0 item.
- Reviewer unavailable (usage window, rate limit): wait, `senior-mode/review` stays pending. The
  author may review only on the owner's explicit request, says so in the comment, and an
  independent re-review is filed (first case: #128 and #129, re-review #166). ADR in #148.
- Milestone 4 is "v0.4 Autonomy" (was "v0.4 Breadth", empty).
- GitHub used fully, by wave: v0.3 CODEOWNERS from `protected` with code owner review (#171) and
  native security, critical and important only so the board is not flooded (#172); v0.4 native
  auto-merge for S and M (#173), Paths and Severity fields (#174); v0.5 Board: template Project
  copy (#176), Project status updates (#177), README (#178), archiving (#179), iterations (#180).
- Agents keep the owner's identity for now; a separate identity stays open (#175, P3, an L).

## Next

Done: 0.2.0 (#167), 0.3.0 (security epic #130, dogfooding #133-#138), 0.4.0 (autonomy epic #131,
sandbox proof #157), 0.5.0 (board #176-#181).

1. v1.0: Claude logged in on sya-dev-01 (#132, a human), a week of the daemon on senior-mode (#158),
   evals green (#159), then the human releases 1.0 on the marketplace (#160).
2. Later, no milestone, deferred by the owner: #169 (spec/code drift), #175 (agent identity).
