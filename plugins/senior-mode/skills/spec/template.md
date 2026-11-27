---
id: <issue number>
title: <what the user gets, in plain words>
status: draft
size: M
paths: []
adrs: []
issue: <#n>
---

# <title>

## Problem

Who is affected, what they cannot do today, why it matters now.

## Acceptance criteria

- Given <context>, when <action>, then <observable outcome>.

## Out of scope

What this spec deliberately does not cover.

## Test seams

Where tests hook in: functions, endpoints, commands, pages.

## Hot paths (optional)

A path that must stay fast, the benchmark that measures it, and why it is hot. `check` fails when no benchmark of that name exists.

- `<path glob>`: benchmark `<name>`, <why it is hot>.

## Security (M and L)

Data handled and its sensitivity; who may read or change it; entry points (routes, commands, files,
third-party input); for each threat, the protection chosen. Empty only with the reason (no data, no
new entry point).

## Users and journeys (L only)

Who uses it and what each user does, one journey per line. Declare the journeys in the front matter, next to
`paths` (`id` unique in the spec, `test` a relative path with no `..`); `check` runs the ones the diff touches:

```yaml
journeys:
  - { id: J1, name: "A buyer pays an invoice", test: "e2e/pay-invoice.spec.ts" }
```

## Design (L only)

Components, data, interfaces; link ADRs for every hard-to-reverse choice.

## Rollout and risks (L only)

Migrations, flags, backward compatibility, what could go wrong.

## Open questions

None, or each with its recommended answer.
