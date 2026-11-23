---
id: 123
title: The board tells the truth, and work in progress stays small
status: accepted
size: M
paths: ["plugins/senior-mode/bin/senior-mode", "plugins/senior-mode/skills/next/**", "plugins/senior-mode/skills/setup/**", "plugins/senior-mode/skills/status/**"]
adrs: []
issue: "#123"
---

# The board tells the truth, and work in progress stays small

## Problem

The board is the source of truth for state (ADR 0002), yet nothing kept it true when work ended. On
2026-11-22 the senior-mode board had 24 closed tickets still In progress and 8 more in In review,
Ready or no status: the Project's built-in "Item closed" and "Pull request merged" workflows were
off, `run` and `next` never set Done, and `status` dropped the closed board items (it kept only
the open ones), so it showed nothing wrong. Everyone reading the board (the user, `next`, `run`,
`retro`) was misled, and nothing limited how much work was started at once.

## Acceptance criteria

Done on merge and close (#123):

- Given `run` merges a pull request, when the merge succeeds, then its ticket's Status is Done.
- Given `next` merges with the user's yes, when the merge succeeds, then the skill sets the ticket
  Done.
- Given a Project whose built-in workflows "Item closed" or "Pull request merged" are off, when
  `setup` runs, then it names them and says where to turn them on (the API cannot enable them).

Board drift (#124):

- Given a closed issue whose Status is not Done, when `status` runs, then a "Board drift" section
  lists it, and `status --fix` sets it Done and says so.
- Given an open issue whose Status is Done, then it is listed as drift; `--fix` leaves it and says
  a human decides.
- Given an open issue In progress or In review with no open pull request and no branch
  `<type>/<n>-*` on origin, then it is listed as stale; `--fix` leaves it.
- Given no drift, then the section is absent and `status --json` has `drift: []`.
- Given `--fix` with `--json`, then the JSON lists what was fixed under `fixed`; `--fix` with
  `--watch` is refused (a repair runs once, on purpose).

Work-in-progress limit (#125):

- Given `wip` is 1 (default) and one open issue is In progress, when `senior-mode start <other>`
  runs outside a run, then it refuses, names the ticket in progress and suggests finishing it; the
  board is unchanged.
- Given `start` on the ticket already In progress, then it proceeds.
- Given `run` opens its tickets (`run_start` calls `start` with `SENIOR_MODE_RUN=1` set for that
  call, as the sessions have it), then `start` does not apply `wip`: `autonomy.parallel` bounds the
  run. With `parallel: 2`, `wip: 1` and a ticket already In progress, both run tickets start.
- Given more open issues In progress than `wip`, then `status` shows the count against the limit.
  `status --json` always has `wip: {limit, count}`. `wip` gets its default 1 in the config defaults.

## Out of scope

- Enabling the Project's built-in workflows: GitHub offers no API for it; `setup` only says so.
- Repairing anything but "closed and not Done": other drift needs a human's judgement.
- Per-person limits: `wip` counts the whole board, which is what one person and their agents share.

## Test seams

`run_merge`, `run_start`, `start`, `status` and `setup github` in `bin/senior-mode`, through `test-run.sh`,
`test-start.sh`, `test-status.sh` and `test-setup-github.sh` with board fixtures; the `next` and
`setup` skills for the steps a model performs.
