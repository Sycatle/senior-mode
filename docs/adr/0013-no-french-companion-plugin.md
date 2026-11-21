---
id: 0013
title: No French companion plugin, French through triggers and a language key
status: accepted
spec: 0001
---

## Context

The spec planned `senior-mode-fr`, a second plugin of one-line aliases (`/cadre`, `/suivant`, …). A
second plugin doubles the release and validation surface for what is a matter of wording.

## Decision

There is no `senior-mode-fr`. French users are served by:
- French trigger phrases in the skill descriptions ("cadrons", "enchaîne"), within the size budget;
- the `language` config key, which sets the language of replies and generated documents.

Commands stay in English, and so do prompts, commits, issues and PRs (CONTRIBUTING.md).

## Alternatives considered

- **Companion plugin with aliases:** shorter French command names, but a second package to version,
  validate and keep in sync with every rename.

## Consequences

- One plugin to release.
- French command names (`/cadre`) are not provided; natural-language triggers cover the use.
