---
id: 0010
title: Generic core, client needs go through extension points
status: accepted
spec: 0001
---

## Context

Work for a given client brings stack vendors, regulations and governance rules. Putting them in the
plugin makes it specific to one use case and wrong for everyone else.

## Decision

The core names no client, no stack vendor and no regulation. Client needs plug in through:
- `checks`: project commands added to the check list (ADR 0006);
- project skills and agents in the project's `.claude/`;
- `review.sections`: project checklist files that `review` loads;
- `docs.extra`: additional documents `docs` maintains;
- `envGuard.forbidden`: patterns that must never appear in env files or environment variables.

Regulated, governance or stack-specific packs live in the client's repositories, built with the client.

## Alternatives considered

- **Companion plugins per domain:** clean separation, but rejected for now: there is one use case,
  and a plugin per domain would be speculative structure. Revisit when a second domain appears.

## Consequences

- The core stays small and testable without any client context.
- Extension points are a contract: each is a config key with a documented format, tested like the rest.
- Presets keep stack awareness (for example Next.js in `node`), never vendor lock-in.
