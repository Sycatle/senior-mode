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
- **Later:** evals and marketplace (v1.0) after real use; release-please start version from
  Cargo.toml / pyproject.toml.

## Shared contract

Config keys: `autonomy.maxTickets` (3), `autonomy.parallel` (1), `autonomy.merge` (false),
`autonomy.maxConsecutiveFailures` (2), `autonomy.escalate` (true), `e2e.slots` (2), `protected`,
`secrets`, `envGuard.forbidden` (patterns that must never appear in env files or env vars),
`github.protection`, `review.sections` (project checklist files), `language`.
Env `SENIOR_MODE_RUN=1` during a run. Shared bin helper: `senior-mode pick`.

## Status (2026-11-22)

- Done: rework, wave 2, retro, ADRs 0007-0014, all in PR #113 (`integration/tonight`, 80 commits,
  closes #71-#111, supersedes #79 #82 #85). `check` 6/6.
- Dogfooded on Sycatle/senior-mode-sandbox: setup, frame (findings -> #101-#110).
- Not dogfooded: run, schedule, next, retro, review, docs (stubbed tests only).

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

## Next

Done 2026-11-22: #112, #114 and the two blocking review findings (run merge gates) went into #113,
reviewed twice, merged (rebase, main 3bed96e); #79 #82 #85 closed. Review follow-ups filed:
#115-#121 (security wave).

Done: #64 docs drift check + #58 docs pass (#122).

Framing 2026-11-22 (board rigour): the board had 24 closed tickets still In progress. From now on
senior-mode's own process applies strictly here: waves through `frame`, tickets through the `next`
flow with the board moved at each step, WIP 1. Spec `docs/specs/123-board-rigour.md`.

1. Board rigour, before 0.2.0: #123 Done on merge/close + setup checks Project workflows,
   #124 `status` board drift + `--fix`, #125 `wip` limit.
2. Release 0.2.0 (`senior-mode release`, ci.mode local).
3. Security wave (above): ADR, review section + security agent, check audits, #115-#121 -> 0.3.0.
4. Dogfood run, schedule, next, retro, review, docs on the sandbox from sya-dev-01; fix findings.
5. Evals green (`evals/run.sh`), then stop for the 1.0 release and marketplace publication.
