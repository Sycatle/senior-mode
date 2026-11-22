---
id: 176
title: The board is a full GitHub Project, configured once, healthy at a glance
status: accepted
size: M
paths: ["plugins/senior-mode/bin/senior-mode", "plugins/senior-mode/skills/setup/**", "plugins/senior-mode/skills/status/**", "plugins/senior-mode/skills/retro/**", "plugins/senior-mode/skills/run/**", "plugins/senior-mode/presets/**"]
adrs: []
issue: "#176"
---

# The board is a full GitHub Project, configured once, healthy at a glance

## Problem

`setup github` creates the Project and its fields through the API, but GitHub offers no API for
views or built-in workflows: every user rebuilds BACKLOG, KANBAN and ROADMAP by hand and must find
the workflows to turn on (the senior-mode board had them off until #123). Once running, the board
says nothing about the project's health unless someone runs `status`; Done items pile up in every
view; there is no notion of cycle, so `retro` and the roadmap work on loose periods and the daemon
has nothing to plan against. The human should open the Project page and see the process, the
health and the plan without running anything.

## Acceptance criteria

Template copy (#176) and migration (#181):

- Given no Project, when `setup github` runs, then it copies the template Project
  (`copyProjectV2`, without draft issues), links it to the repository, makes it public when the
  repository is, writes its id in `.claude/senior-mode.json`, then checks the copy: the views and
  workflows the template has are there, and any missing one is named with where to fix it.
- The template is "senior-mode template", public, on the Sycatle account; its id ships in the
  presets and `board.template` overrides it (an organisation's own template).
- Given an existing Project, when `setup github` runs, then it is never replaced: setup lists the
  views and workflows the template has and it lacks, and says `--migrate` exists.
- Given `setup github --migrate --dry-run`, then it prints the mapping (items, fields, options,
  what will be created) and changes nothing.
- Given `setup github --migrate`, then a Project is created from the template; every item of the old
  Project is added with its field values (Status, Priority, Size and the rest); a field or a
  single-select option the template lacks is created as is and listed in the report; the new
  Project is linked and recorded in the config; the old one is closed (`updateProjectV2 closed`),
  not deleted, and the report says how to reopen it.
- Given a migration interrupted halfway, when it is rerun, then items already in the new Project are
  not added twice.

Project health (#177):

- Given `status --publish`, then a `createProjectV2StatusUpdate` posts a status, a start date, a
  target date (the earliest open milestone's due date, if any) and a short body: counts per Status,
  needs-human items, failing pull requests, drift.
- Off track when an open milestone is past due with open issues, or the run breaker is paused.
  At risk when a `needs-human` item has waited more than 24 hours, an open pull request fails its
  checks, or there is drift. On track otherwise. The body says which rule decided.
- Given `retro` runs, then it publishes the same update at the end of each pass.
- `status` alone never publishes.

README (#178):

- Given `setup github`, then the Project's short description and README are written in the project
  `language`: what each Status means, the Definition of Ready, who moves what (human or agent) and a
  link to `docs/specs/`. The senior-mode part sits between markers; rerunning rewrites only that
  part and keeps everything else.

Archiving (#179):

- Given `board.archiveAfterDays` (default 14), when `run` starts, then items Done whose issue
  closed more than that many days ago are archived (`archiveProjectV2Item`) and listed in the run
  log; open items and items not Done are never archived.
- Given archived items, then `retro` still counts them in its period.

Iterations and dates (#180):

- Given `setup github`, then the Project has an Iteration field of two weeks (`board.iterationDays`,
  default 14) and Start and End date fields; existing fields are reused, not duplicated.
- Given `start <n>`, then the item gets the current iteration and Start is today; given a merge by
  `run` or `next`, then End is today.
- Given `retro --iteration` (current) or `--iteration <name>`, then it reports that iteration
  instead of a `--since` period. The ROADMAP view uses Start and End; milestones stay releases.

## Out of scope

- The daemon publishing health once a day and archiving on each loop: `serve` does not exist yet;
  its ticket #149 carries both, calling the same functions.
- Moving issues between repositories, or migrating anything but Project items and their fields.
- Deleting the old Project: it is closed, a human may delete it.
- Agent identity and server-side review (#175, #171).

## Test seams

`setup_github` (copy, `--migrate`, `--dry-run`, README, fields), `status --publish`, `run` start,
`start`, `run_merge` and `retro` in `bin/senior-mode`, through `test-setup-github.sh`,
`test-status.sh`, `test-start.sh`, `test-run.sh` and `test-retro.sh`, all with
the gh stub and board fixtures; the template's real content checked once by hand at setup.

## Open questions

- What `copyProjectV2` copies (views, workflows, auto-add) is checked against the real API in the
  first slice and the criteria above adjusted if it differs; recommended: keep the post-copy check
  either way, it is what tells the user.
