# senior-mode user guide

This guide explains how to install senior-mode, adopt a repository and work with it day to day.

senior-mode is a Claude Code plugin. It turns an idea into a planned GitHub Project, then helps
deliver it in small, tested, reviewed pull requests. This guide describes version 0.1, and it says
clearly which parts are still to come.

## Pages

- [Getting started](getting-started.md): requirements, install, adopting a repository, your first framing.
- [A typical day](a-typical-day.md): from an idea to a merged pull request with today's tools.
- [Commands](commands.md): every `/senior-mode:` command and the `senior-mode` script, with what is available now.
- [Skills](skills.md): the discipline rules Claude loads by itself, and when.
- [Agents](agents.md): the agent team, the model each one uses and why.
- [Autonomy and guardrails](autonomy.md): what is blocked, what is required before a merge, what is not automated yet.
- [Running the pipeline on a server](self-hosting.md): account, pinned plugin, sandbox, token, one `serve` unit per repository.
- [Configuration](configuration.md): `.claude/senior-mode.json`, checks, CI mode, presets, git hooks, releases.
- [FAQ](faq.md): cost, GitHub Actions budget, private repositories, existing repositories, leaving senior-mode, French.

## Design reference

The design is in the spec [0001 senior-mode](../specs/0001-senior-mode.md). Decisions are recorded
as ADRs in [`docs/adr/`](../adr/). When this guide and the spec differ, the guide describes what the
plugin does today, and the spec describes where it is going.

## Roadmap

| Milestone | Content |
|---|---|
| v0.1 Bootstrap | `setup`, `frame`, discipline skills, agents, hooks (shipped) |
| v0.2 (planned as v0.2 to v0.4, released together) | `next`, `status`, `run`, protected zones, circuit breaker, model escalation, python, go and rust presets, `retro`, generic `docs`; `schedule`; docs drift check |
| v0.3 Security | A `security` agent, a full security section in `review`, dependency audit and secret scan in the checks |
| v1.0 | Evals green, docs, marketplace publication |

Source: [spec §19](../specs/0001-senior-mode.md#19-delivery-plan).
