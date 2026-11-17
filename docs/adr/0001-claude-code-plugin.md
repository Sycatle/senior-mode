---
id: 0001
title: Ship as a Claude Code plugin with a marketplace
status: proposed
spec: 0001
---

## Context

The workflow needs commands, discipline rules, specialised agents, enforced guardrails and templates.
A single skill can carry instructions but cannot enforce anything or pin models per role.

## Decision

senior-mode is a Claude Code plugin distributed through a marketplace in its own public repository
(MIT). It ships skills (commands are user-invocable skills), agents, hooks, a `bin/` script and
templates. A companion plugin `senior-mode-fr` adds French aliases. Prompts and docs are in English;
everything written for the user (issues, PRs, commits, answers) follows the project language.
Claude Code comes first; other harnesses (opencode) may get adapters later.

## Alternatives considered

- **Single skill:** simplest to install, but no hooks, no pinned agents, no guardrails.
- **Harness-agnostic core (AGENTS.md) with thin adapters:** most portable, but loses hooks and model
  pinning, the two features that make autonomy safe and cheap.
- **Aliases inside the main plugin:** no extra install, but doubles every entry in the command menu.

## Consequences

- Install is one command; versions follow semver through release-please.
- Plugin agents cannot declare their own hooks or permission mode: guardrails live in the plugin's
  hooks, which apply to all agents.
- Supporting another harness later means adapters, not a rewrite.
