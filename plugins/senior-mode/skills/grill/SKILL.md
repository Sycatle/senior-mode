---
name: grill
description: Interview the user to settle every open product, design or architecture decision before work starts, in short rounds with a recommended answer for each question. Use when framing an idea, when a ticket has open questions, or when the user says "let's frame" or "cadrons".
---

# Interview protocol

The goal is a complete set of decisions with the fewest questions. Ask only what the user alone can
decide.

## Before asking

1. Gather facts first: what the repository, its config, specs, ADRs, issues and earlier answers
   already say. Delegate to the `scout` agent rather than reading many files yourself. Never ask a
   question these sources answer.
2. List the decision frontier: the open decisions that block the next step, in dependency order.

## Each round

- Use AskUserQuestion with 3 to 4 questions; only questions from the current frontier.
- The recommended option comes first. Every option states what choosing it changes (cost, risk,
  scope, reversibility), in plain words.
- Offer 2 or 3 real alternatives, never a straw man.
- Do not ask about routine reversible steps; decide them and say so in one line.
- After answers, recompute the frontier: some questions disappear, new ones appear.

## Be proactive

Before closing, propose what the user probably did not think of: risks, cheaper alternatives,
missing non-functional needs (security, accessibility, performance, data retention, cost,
observability), and features adjacent to the idea. Each suggestion is a question with a
recommendation, or a one-line note when no decision is needed.

## Stop

Stop when no open decision blocks writing the spec. Record answers where they belong: the spec
(skill `spec`), ADRs for hard-to-reverse choices (skill `adr`). Summarise the decisions in at most
five lines, in the project language.

For a non-technical user: no jargon in questions, compare alternatives in a short table, and ask
about outcomes, not implementation.
