---
id: 329
title: A product of several repositories is delivered as one, and an organization configures it once
status: accepted
size: L
paths: ["plugins/senior-mode/bin/senior-mode", "plugins/senior-mode/bin/lib/**", "plugins/senior-mode/bin/tests/**", "plugins/senior-mode/agents/**", "plugins/senior-mode/skills/**", "plugins/senior-mode/templates/**", "docs/guide/**", "docs/knowledge/**"]
adrs: ["0002", "0017", "0020", "0021", "0023", "0024", "0026"]
issue: "#329"
---

# A product of several repositories is delivered as one, and an organization configures it once

## 1. Goal and non-goals

Everything senior-mode does today assumes one repository: one Project, ticket numbers that are unique on the board, one
`serve` per clone with its state under that clone's `.git`, a config file with no parent. A product is rarely one
repository (an API, a web app, a mobile app, an infrastructure repository), and a team often owns many of them under one
GitHub organization. Run as it is, that team gets one board and one daemon per repository, a change that crosses two
repositories is two unrelated tickets, and the same conventions are written again in each repository. This spec lets one
Project and one daemon serve every repository of a product, delivers a cross-repo change in an order that keeps each
repository deployable, and lets an organization set its conventions once. Owner decisions of 2026-11-23 (issue #329) are
fixed; this turns them into testable behaviour. Every criterion is tagged **[v1.4]**, the milestone of the epic.

Goals: name a ticket by its repository (§2); serve only repositories that belong to the product (§3); one daemon, one
budget, failures contained per repository (§4); cross-repo epics delivered from producer to consumers (§5); an
organization layer for configuration and knowledge (§6) and for the template Project and rulesets (§7); one view of every
repository (§8). Throughput, resilience, configurability and untrusted input (ADR 0024) hold across repositories the same
as in one (§9).

Non-goals:

- Changing who reviews or merges, or any gate (ADR 0017, 0018, 0019): in each repository a merge is still
  `gh pr merge --rebase --match-head-commit` on a head with `ci`, `review` and `security` success. No atomic merge
  across repositories exists or is simulated (§5.2).
- Making an external contribution trusted: ADR 0024 holds in every repository of a product, and the organization layer
  cannot lift it (§6.1).
- Several products on one Project, a product-level milestone (GitHub has none: milestones stay per repository, the
  Project's iterations are the shared cycle), a hosted service or a database.
- An agent identity of its own (#175, deferred), and monorepos (spec 327 §10: one repository, many packages).
- Repositories under other owners than the Project's (§3).

Related work, reused and not redone:

- #307 (config layers: plugin defaults, profile, organization, repository, local; `config explain`; locked safety base).
  The organization layer exists from v1.0 and reads nothing; §6.1 fills it.
- Spec 325 (knowledge notes, briefing, vision, hierarchy), spec 373 (classification, `held`, reconciliation, state
  files; ADR 0021) and spec 327 (the order of §2, leases, quota bands, slots, the train; ADR 0023) are built on, not
  redone. Spec 409 (`ci.required`, what setup cannot map) is how §7 treats rulesets.
- Spec 176 (board projects: template copy, `--migrate`, views are not in the API) and ADR 0002 (state is in GitHub).

Conventions. A *ref* is `owner/name#n`; `#n` alone is a ticket of the current repository. The *anchor* is the repository
whose clone runs `serve`. A *product* is a Project and the repositories on it; its *served set* is §3. `serve dir` is
`<git common dir>/senior-mode/serve/` of one clone (spec 373). New configuration is gathered in §9.

## 2. One Project per product

Tickets: #450 (§2.1, §2.2), #398 (§2.3).

### 2.1 Naming a ticket

An issue number is unique per repository, not per Project: `board_data` reads `.content.number` of every item and would
mistake the #7 of another repository for its own, and `item set`, `start` and the `blockedBy` list name tickets by number
alone. A Project item now carries its repository (`content.repository.nameWithOwner`, also the built-in **Repository**
field of every Project, which senior-mode never creates) and a ticket is named by its ref. `owner/name#n` is accepted
wherever a number is: `item get|set`, `ready`, `start` and `run` (for the repository of the current clone only: another
repository's ref is refused with "run it in a clone of owner/name"), and `--parent`, `--blocked-by` and `--repo` of
`issue create`. `blockers` and the edges of spec 327 §2 are refs. Output that mixes repositories prints refs; output for
one repository prints numbers as today.

- **[v1.4]** Given a Project whose items include #7 of repositories `a` and `b`, when `board_data` runs in `a`, then only
  `a#7` is a ticket, `pick` never returns `b#7`, and `b`'s items are reported as other repositories in `status --json`.
- **[v1.4]** Given `senior-mode item set b#7 Size M` run from `a`, then the item of `b` changes and `a#7` does not.
- **[v1.4]** Given `senior-mode start b#7` in `a`, then it fails with "run it in a clone of b" and creates nothing.
- **[v1.4]** Given a Project with items of one repository, then every command prints and behaves as before.

### 2.2 Filing in another repository

`issue create --repo owner/name` files the ticket in that repository (it must be in the served set of §3 or, outside
`serve`, adopted with the same Project), adds it to the Project, sets its fields and milestone (a milestone is looked up
by title in the target repository) and links it to `--parent` and `--blocked-by`, whatever their repositories. Without
`--repo` the current repository, as today. The `Paths` of a ticket are relative to its own repository: tickets of two
repositories never collide on Paths, and `pick_free` compares Paths only inside one repository.

- **[v1.4]** Given `issue create --repo b --parent a#12 --blocked-by a#13`, then the issue exists in `b`, is on the
  Project with its Size and Priority, is a sub-issue of `a#12` and is blocked by `a#13`.
- **[v1.4]** Given two Ready tickets with the same Paths in two repositories, then `pick_free` lets them run together;
  in one repository it does not.
- **[v1.4]** Given `--repo` naming a repository that is not adopted, then nothing is created and the message names it.

### 2.3 Attaching a repository to an existing Project

`senior-mode setup github --project <number|url>` attaches the current repository to the Project of its owner instead
of creating or finding one by title. It:

- reads the Project and checks that it has the fields `Status` (with the senior-mode options), `Priority`, `Size`,
  `Severity` and `Paths`, as `board_lacks` compares with the template. Missing fields are **created** (additive); a
  missing option of an existing field is **reported, never rewritten**, since replacing the options of a shared field
  would move other repositories' items. What it reports says where to fix it;
- links the repository to the Project (`gh project link`), writes `project` in `.claude/senior-mode.json` (`owner`,
  `number`, `id`, `fields`, `home`), and runs the repository steps of `setup github` as today (labels, merges, ruleset,
  CODEOWNERS);
- sets `project.home` to the repository the Project was created for: the one named like the Project's title, else
  `--home owner/name`, else the first repository linked to it. The home holds the duties of the Project as a whole
  (§4.5). Every member's config names the same home;
- with `--move-items`, moves the repository's items from its previous Project (§9).

`--dry-run` prints all of it and changes nothing. A second run changes nothing. Without `--project`, `setup github` is
unchanged; in particular a repository whose Project exists keeps it. The Project must have the repository's owner
(GitHub links a repository only to a Project of its own owner); a Project of another owner is refused.

- **[v1.4]** Given an organization Project with the senior-mode fields and two other repositories, when `setup github
  --project 7` runs in a third, then it is linked, its config names Project 7 and the same `home`, and the two others'
  items are untouched.
- **[v1.4]** Given a Project lacking `Paths` and a `Status` without `In review`, then `Paths` is created and the missing
  option is reported with where to add it; no existing option changes.
- **[v1.4]** Given `--dry-run`, then it prints the fields, the link and the config it would write and changes nothing;
  given a second run, then nothing changes.
- **[v1.4]** Given a Project of another owner, then setup refuses and names both owners.

## 3. The served set, and what is never served

Tickets: #451. ADR 0024 applies.

A Project can hold an issue of any repository its editors can read, including a public repository of someone else. A
daemon that started whatever the board lists would run the code and the text of strangers with the owner's permissions.
The **served set** of a Project is therefore the intersection of four things, computed each poll from GitHub:

1. the repository has an item on the Project and is not archived;
2. its owner is the Project's owner;
3. it is adopted and names this Project: `.claude/senior-mode.json` on its default branch has `project.id` equal to the
   Project's (the handshake: the Project lists the repository and the repository names the Project);
4. it passes `serve.include` (globs of `owner/name`, default `["*"]`) and not `serve.exclude` (default `[]`).

A repository that fails 1 to 3 is **not served**: nothing is started, reviewed or merged in it, and `status` lists it once
with the failed condition (`foreign owner`, `not adopted`, `names another Project`, `archived`). One that fails only 4
is silent. Adoption is read in batched GraphQL calls (`object(expression: "HEAD:.claude/senior-mode.json")`), not by
cloning.

Clones. The daemon needs a clone per served repository. `serve.repos` (a map `owner/name` to a path, in the local layer
of #307, never inherited) names clones that exist; a missing one is cloned by `gh repo clone` into
`${XDG_DATA_HOME:-~/.local/share}/senior-mode/clones/<owner>/<name>` the first time a ticket of it is runnable, and
fetched before each launch. A clone is matched to a repository by its `origin` as GitHub resolves it, so a renamed
repository is still served (the stale URL is reported once). A clone whose `origin` is another repository, or that is
dirty on its default branch, is not used: the repository is held (§4.4) and `status` says why.

Trust. The gate of ADR 0024 (`trusted`, `TRUST_DEF`) applies to every item with its own repository's
`authorAssociation`, so an external issue is skipped in every repository exactly as in one. Text from other tickets is
data: a briefing, a prompt or an epic digest that quotes a sibling ticket (the epic's contract, a blocker's title) quotes
it only when it passes `trusted`, and otherwise says `omitted: not from a collaborator`. The integrator refuses an
external or fork pull request in any repository (`run_blocker`), even one that closes a ticket on which a cross-repo epic
waits.

- **[v1.4]** Given an item of a repository of another owner, a repository whose config names another Project, an
  archived one and an unadopted one, then none starts a session, and `status` lists each with its reason once.
- **[v1.4]** Given `serve.exclude: ["acme/legacy-*"]`, then `acme/legacy-api` is neither served nor listed as an error.
- **[v1.4]** Given a missing clone, then the daemon clones into the clones directory before the launch; given a clone
  whose origin is another repository, then that repository is held with the reason and the others go on.
- **[v1.4]** Given a repository renamed on GitHub with its clone's origin still the old URL, then it is served and the
  stale URL is reported once.
- **[v1.4]** Given an external issue with `triage` in a served repository, then `pick` skips it; given a ticket whose
  sibling in another repository has an external author and no `qualified`, then the briefing carries no text of it.
- **[v1.4]** Given an external pull request in a served repository that `Closes` the ticket a consumer waits for, then the
  daemon neither reviews it as trusted nor merges it, and flags it `needs-human` once.

## 4. One daemon per Project

Tickets: #402 (§4.1, §4.2, §4.5), #455 (§4.3), #453 (§4.4). Amends ADR 0017. Builds on spec 327.

### 4.1 Scope

`serve.scope` is `repo` (default: today's daemon, one repository) or `project`. In `project` scope `serve` run in the
anchor serves its served set (§3). A single-repository `serve` started in a repository that a product daemon serves
fails with the existing "already running" message naming the product daemon: the product daemon takes each served
repository's `serve.lock` (the `flock` that already makes `serve` single-process per repository) for as long as it
serves it, and releases it when the repository leaves the set. `serve --install` writes the unit with the scope; the
unit and the single process rule are otherwise unchanged. The poll walks the served set once per interval; a launch
choice sees the sessions launched earlier in the poll in every repository (spec 373 I5).

- **[v1.4]** Given `serve.scope: project` on a Project with three served repositories, when it polls, then Ready tickets
  of all three are candidates in one queue.
- **[v1.4]** Given the product daemon running, then `serve` in a member's clone exits with the "already running" message
  naming the product daemon and its pid, and starts nothing.
- **[v1.4]** Given no `serve.scope`, or `repo`, then `serve` behaves as today in a repository attached to a shared
  Project: it serves its own tickets only.

### 4.2 State and worktrees

Nothing about one repository's tickets moves. Each repository keeps its own serve dir (sessions `<n>.*`, `launches`,
`held`, `breaker`, `train`, `stack-<n>`, leases are refs of that repository), so ticket numbers never collide in files and
reconciliation (spec 373 §2) runs per repository against that repository's GitHub state. Product-level state is a
`product/` directory in the anchor's serve dir: the poll cursor, the global `launches` window, the product `held` for
machine-wide causes, the `digest` marker and the snapshot of the served set. All of it is written with `state_write` and
`state_update` (spec 373 §3). Worktrees keep `worktree_path`: `<data>/senior-mode/worktrees/<repo>-<hash>/<n>`, a name
that already separates repositories. Invariant I2 of spec 373 extends: no two live sessions share a ticket ref, a worktree
or a slot, and no pull request merges twice, across all repositories.

- **[v1.4]** Given tickets #7 of two served repositories running together, then each has its own session files, worktree
  and branch, and neither reads the other's `7.*`.
- **[v1.4]** Given `kill -9` of the daemon with sessions in two repositories, then the next polls reconcile each against
  its own GitHub state with no human action and I1 to I5 of spec 373 hold in both.
- **[v1.4]** Given the whole `product/` directory deleted, then the next poll rebuilds it and loses counters, never a
  ticket.

### 4.3 One budget, one slot pool, one order

The limits that protect the machine and the owner's account are counted once for the product:

- `autonomy.parallel`, `autonomy.sessionsPerHour`, `autonomy.minMemoryMB`, `autonomy.quotaReserve` and the usage bands
  of spec 327 §6 are read from the anchor (and its layers) and apply to the whole product. A repository can cap itself
  with its own `autonomy.repoParallel` (default 0: no cap beyond the product's), read from that repository's config.
- Slots (spec 327 §7) come from **one machine-wide pool** for the Project, `slots/<owner>-project-<number>/N`, with one
  `flock` per number and as many numbers as `autonomy.parallel`. A session takes the lowest free number and the template
  of its own repository's `.senior-mode/slot.env` is expanded with it, so `{{port:3000}}` is distinct across repositories
  that run together. `{{repo}}` and `{{slotdir}}` keep their meaning. Outside `project` scope slots stay per repository.
- The queue is the union of the served repositories' candidates, ordered by spec 327 §2 with refs for tickets. The
  critical path counts edges between tickets whose milestones share a **title** (milestones are per repository; `v1.4` of
  the producer and of a consumer are one milestone for `cp`), and the milestone due date of key 2 is the ticket's own. The
  order's last keys change to: Size, the position of the repository in `serve.repoOrder` (default `[]`, unlisted last),
  the repository name, the number. The order stays total, so the same board prints the same queue.
- Leases (spec 327 §8) are per repository and unchanged; so are trains, stacks and `review-<pr>` leases. Stacking never
  crosses repositories: a ticket whose open blocker is in another repository waits for that blocker to be Available (§5.2).

- **[v1.4]** Given `autonomy.parallel` 3 and Ready tickets in three repositories, then three sessions run and no fourth
  starts; given `autonomy.repoParallel` 1 in one of them and its three Ready tickets, then at most one of its sessions
  runs and the others fill the free slots.
- **[v1.4]** Given two sessions in two repositories with the template `PORT={{port:3000}}`, then they hold different slot
  numbers and different ports; given a crash of one, then its slot is free on the next claim.
- **[v1.4]** Given the same board read twice, then the queue is identical; given two tickets equal up to Size, then the
  repository earlier in `serve.repoOrder` goes first, and with `[]` the lexically first repository.
- **[v1.4]** Given a consumer whose only open blocker is a producer ticket with a green open pull request, then the
  consumer does not start on that branch and waits.

### 4.4 A failing repository does not stop the others

Spec 373 classifies why a session ended and holds launches for environment causes. In a product the scope of each cause
matters:

| Cause (spec 373) | Scope | Why |
|---|---|---|
| Disk, memory, gh or claude auth, network, usage limit, dependencies of the machine | machine: every repository | The machine or the account is the problem |
| Red main, install failing on the base head, ticket-failure breaker, `needs-human` | repository: only it | The code of one repository is the problem |
| Lost or foreign clone, repository archived or deleted, access revoked (`HTTP 403/404` on the repository, not on the API) | repository, with backoff | The repository is gone or unreachable |

A repository hold is a `held` file in that repository's serve dir with the same shape as spec 373's, so `status`, the alert
and the probe treat it as they do the machine hold; its probe is the repository's own. The circuit breaker is counted per
repository (`maxConsecutiveFailures` is per repository): three failed tickets of one repository pause that repository, not
the product. A poll step that fails for one repository (a `gh` timeout, a corrupt state file quarantined by spec 373 §3,
a clone that cannot fetch) is a transient end of that step for that repository: it is skipped for the poll with backoff,
logged with its ref, and the others are served. A repository removed from the set while sessions run is drained: its
sessions finish or end as transient, nothing new starts, its lock is released when the last one ends. Merges and reviews
in a healthy repository continue under a repository hold of another. Alerts say which repository: `{event, repo, number,
url, reason}` already carries `repo`.

- **[v1.4]** Given a red main in repository `a` of three, then `a` launches nothing and still merges its green pull
  requests, `b` and `c` launch as before, and `status` names `a` and the probe.
- **[v1.4]** Given disk below `autonomy.minDiskMB`, then no repository launches, one alert is sent, and every repository
  resumes when the probe is green.
- **[v1.4]** Given three failed tickets of `a` in a row, then `a` pauses with its own backoff and `b` is unaffected.
- **[v1.4]** Given repository `b` archived while its session runs, then the session ends as transient, `b` leaves the
  served set with one log line and one alert, and `a` and `c` keep their sessions.
- **[v1.4]** Given a `gh` timeout on `c`'s poll step, then `c` is skipped that poll and retried with backoff; the others are
  polled in the same pass.

### 4.5 Duties of the Project

Some duties are about the Project, not a repository: the daily digest (a Project status update), the Ready-by-rule pass
over the Project, and drift in the Project's own fields. They run under the `leader` lease (spec 327 §8) **of the home
repository** (`project.home`, §2.3; when absent: the repository named like the Project, else the first served repository
by `serve.repoOrder` then name); duties of one repository (filing its security alerts, its train) run under that
repository's own `leader`. If the home leaves the served set for three polls, its duties move to the next repository by
that rule and one line says so.

- **[v1.4]** Given two daemons on two machines serving one Project, then the digest is posted once a day and one train runs
  at a time per repository.
- **[v1.4]** Given the home archived, then after three polls the digest is posted by the next repository in order.

## 5. Cross-repo epics

Tickets: #457 (§5.1), #399 (§5.2, §5.3).

A change that crosses repositories (an API field the web app reads, an event a worker consumes) cannot be one pull request
or one merge: the repositories deploy separately and GitHub has no atomic merge. The only safe order keeps each repository
deployable at every step: the producer adds the new path while the old one still works; consumers migrate one by one; the old path is removed last. No
step needs another to be merged first for main to be green.

### 5.1 The shape, and framing it

A cross-repo epic is an issue (in the repository that owns the contract, or the home) with sub-issues in two or more
repositories and exactly one spec, as any epic (spec 325 §7). Its body has a `## Contract` section with four keys:

```
## Contract
Name: invoice-api
Version: v2 adds `POST /v2/invoices`; v1 keeps working until the removal step
Compatible: v1 clients are unaffected while both paths exist
Remove when: every consumer ticket is merged and released
```

The sub-issues are of three roles, named by a label `contract:produce`, `contract:consume` and `contract:remove`, with
`blocked-by` edges that run **produce, then every consume, then remove**: each consume is blocked by every produce; each
remove is blocked by every consume. A ticket may carry `Available: merged|released` on its own line (default
`epics.available`, `merged`): `merged` means its consumers may start when it is closed; `released` means also when a
release of its repository that contains the merge exists (§5.2). `frame` (the architect and the `frame` skill) files a
cross-repo idea this way with `issue create --repo`, putting each ticket's Paths in its own repository, and states in each
consume ticket which version of the contract it moves to. `ready` and `status` check the **shape** and refuse or flag
(`needs-human`, comment naming what is wrong) an epic that:

- spans two repositories and has no `## Contract` or lacks a key;
- has no `contract:remove` ticket, or a `remove` that is not blocked by every `consume`;
- has an edge from a `consume` or a `remove` to a `produce`, or a `consume` not blocked by every `produce`;
- has a sub-issue in a repository outside the served set (§3), which is also listed by `status` as waiting on a human.

An epic whose tickets are all in one repository is an ordinary epic and none of this applies.

- **[v1.4]** Given an idea that touches an API repository and two clients, when it is framed, then the epic has the
  contract section and four tickets: one produce, two consume, one remove, linked as sub-issues with the edges above, each
  with its own Paths.
- **[v1.4]** Given an epic with sub-issues in two repositories and no `remove` ticket, then `ready` does not set it Ready
  and the comment says `no contract:remove ticket`.
- **[v1.4]** Given a `consume` that is not blocked by the `produce`, then `ready` refuses and names the ticket.
- **[v1.4]** Given a sub-issue in an unadopted repository, then the epic is flagged and the reason names the repository.

### 5.2 Delivery

Scheduling is the existing `blocked-by` rule, now across repositories: a ticket with an open blocker is not picked, and the
blockers are refs (§2.1). What changes is when a blocker counts as done. A `blocked-by` edge from a ticket `p` with
`Available: merged` is resolved when `p` is closed. With `Available: released` it is resolved when `p` is closed **and**
a published release of `p`'s repository contains `p`'s merge commit (`gh api repos/<repo>/compare/<sha>...<tag>` says
`behind` or `identical`); with release-please (ADR 0005) this is the release pull request merged and tagged. `status` and
the digest show the waiting edge as `waiting for owner/name#n to be released`. Further rules:

- A consumer starts only after every produce is Available; a remove only after every consume is Available. Both
  `Available` defaults are the epic's `epics.available`, set on the epic or overridden per ticket.
- **No step spans repositories.** Each ticket is delivered by one pull request in its own repository, whose body has
  `Closes #n` of that ticket only. The integrator checks the pull request's closing references: any other repository's
  ticket makes it `needs-human`. A session never pushes to, or opens a pull request in, a repository other than its ticket's.
- A failed or `needs-human` step stops the steps behind it and nothing else: the old path stays, every repository stays
  deployable, and `status` and the digest name the epic, the stalled ref and the steps waiting.
- A ticket the owner closes as not planned releases its blockers, as for any blocker (spec 327 §2); the shape check of
  §5.1 runs again and flags an epic left with no produce.
- A consume ticket reads the contract from the epic's body at start (the briefing quotes the `## Contract` section when
  the epic's author is trusted, §3) and the version it must migrate to; the produce ticket's pull request description
  states what was published.

- **[v1.4]** Given an epic with one produce, two consumes and one remove, then the order in which the daemon starts them
  is produce, both consumes (together when budget allows), remove, and the remove never starts while a consume is open.
- **[v1.4]** Given `Available: released` on the produce, then its consumers wait after it is merged and start after the
  release containing it is published; given `merged`, they start at once.
- **[v1.4]** Given a pull request of a consume that `Closes` a ticket of another repository, then the integrator does not
  merge it and flags it `needs-human` once.
- **[v1.4]** Given a consume that fails twice, then the remove never starts, the other consume still completes, and `status`
  prints `epic #12 stalled at b#7 (needs-human), waiting: a#9`.
- **[v1.4]** Given the daemon killed between the merge of the produce and the start of a consume, then the next poll starts
  the consume once and no pull request is duplicated.

### 5.3 Untrusted input

An epic is the place where one repository's text steers an agent working in another. The epic's `## Contract` and the
titles of sibling tickets reach a session only when their author passes `trusted` (§3); a sub-issue of the epic whose
author does not pass it is not part of the shape, is omitted from every briefing and is listed by `status` as `untrusted
sub-issue`. The epic itself must pass `trusted` to be Ready. A cross-repo epic never makes an external pull request
mergeable (§3).

- **[v1.4]** Given a sub-issue added to a Ready epic by an external author without `qualified`, then no briefing quotes it,
  `status` lists it as `untrusted sub-issue`, and the epic's other tickets run as before.
- **[v1.4]** Given an epic whose `## Contract` was written by an external author, then `ready` does not set the epic Ready
  and no consume ticket starts.

## 6. Inheriting from the organization

Tickets: #400 (§6.1), #459 (§6.2).

### 6.1 The organization layer

Issue #307 gives configuration five layers: plugin defaults, process profile, **organization**, repository, local. The
organization layer is the directory `org.path` (default `senior-mode`) of the repository `<owner>/<org.repo>` (default
`.github`, which exists for a user account as well), read **from its default branch only**, or from `org.ref` (a branch,
tag or commit) when the repository pins one. A pull request, a fork or any other branch is never read: an organization
layer is what its maintainers merged. It holds:

- `config.json`: the base configuration, in the schema of `.claude/senior-mode.json` (#317);
- `overrides/`: same-name replacements or extensions of plugin files (#307);
- `knowledge/`, `adr/` and `vision.md` (§6.2).

Fetch and cache. One conditional API read (ETag) at most every 10 minutes per process and every hour for `serve`, stored in
`${XDG_CACHE_HOME:-~/.cache}/senior-mode/org/<owner>/<sha>/` with the commit it came from. With GitHub unreachable the last
good copy is used and one line says `org layer: cached <sha>, <age>`; with no copy the layer is empty and one line says so.
A missing repository or directory is an empty layer, cached as such for an hour. Reading the layer never fails a command,
and in `serve` an unreachable organization repository is a transient end of that step (spec 373). `org.inherit: false`
turns the read off; the `org.*` keys are read from the repository and local layers only, never from the organization.

What an organization may and may not set. A configuration that anyone with write access to one repository can change
must not run code on every machine that serves the others:

- **Commands do not inherit.** The keys that run a command or contact a URL on the machine (`commands`, `checks`,
  `agent.command`, `slot`, `slotUp`, `slotDown`, `notify.webhook`, and any added later to `ORG_EXEC_KEYS` in
  `bin/lib/common.sh`) are ignored when they come from the organization layer, unless the repository lists the key in
  `org.allowExec`. `config explain` says `ignored: runs commands, needs org.allowExec` and `status` lists it once.
- **Machine keys do not inherit**: `serve.repos`, `serve.worker`, `serve.scope` name this machine.
- **Guards only tighten.** The lists `protected`, `secrets` and `envGuard.forbidden` are the union of the layers: a
  repository adds to the organization's entries and cannot remove them. The locked safety base of #307 (secret scan,
  protected zones, bash guard, no force-push or `--no-verify`, `check` green before merge) is not liftable by the
  organization layer at all: only by a repository ADR referenced in its config, as #307 says, and flagged by `status`.
- The trust gate of ADR 0024 is not a key: no layer turns it off.
- `board.template` may come from the organization (§7.1): `setup github` then copies the organization's template.

- **[v1.4]** Given `autonomy.parallel: 2` in the organization's `config.json` and nothing in the repository, then
  `config get autonomy.parallel` is 2 and `config explain` names layer `org` and the commit; given `3` in the repository,
  then 3, with the shadowed 2 listed.
- **[v1.4]** Given `commands.test` in the organization's `config.json` and no `org.allowExec`, then it is ignored with the
  message above; given `org.allowExec: ["commands"]`, then it applies.
- **[v1.4]** Given `protected: ["infra/**"]` in the organization and `["docs/**"]` in the repository, then both are
  protected; given a repository `protected: []`, then `infra/**` still is.
- **[v1.4]** Given an organization key that lifts a locked gate, then it is refused with the reason; only a repository ADR
  referenced in the repository's own config lifts it.
- **[v1.4]** Given a default branch with value A and an open pull request with value B, then A is read; given `org.ref`
  pinned to a commit, then that commit's value.
- **[v1.4]** Given GitHub unreachable with a cache, then the cached layer is used and named; with no cache, commands run
  with an empty layer and `serve` does not stop.
- **[v1.4]** Given no `.github` repository, a repository without the directory, or `org.inherit: false`, then no command
  changes and none fails; given a user-owned repository with `<user>/.github/senior-mode/config.json`, then it applies.

### 6.2 Knowledge, decisions and vision

The same directory carries what is true of the whole organization, in the formats of spec 325:

- `knowledge/<slug>.md`: a note (§2 of spec 325: `paths`, `verified`, `origin`, `kind`, body bounded by
  `knowledge.maxLines`) with an optional `repos` list of globs of repository **names** (default all). `paths` are relative
  to the root of whichever repository the ticket is in.
- `adr/org-<NNNN>-<slug>.md`: a cross-cutting decision, with the front matter of an ADR, optional `paths` and `repos`. A
  spec or an ADR of a repository cites it as `adrs: ["org-0003"]`.
- `vision.md`: goals `G1...`, non-goals and constraints (spec 325 §6.3), for the product or the organization.

The briefing (spec 325 §3) draws candidates from both sources by the same rules, `accepted` only, `paths` and `repos`
matching; an organization item ranks **below** the repository's item of the same class, and all of it shares
`context.budget`. The vision is the repository's `docs/vision.md` when it exists, else the organization's; `Goal: org:G2`
on a milestone resolves in the organization's vision whatever the repository has. A superseded organization ADR is not
listed. `check` in a repository resolves `org-` ids from the cached layer and fails an unknown id only when a layer was
read; without a layer it warns. `check` in the `<owner>/<org.repo>` repository, detected by its name, validates the whole
`senior-mode/` directory with the same validators (notes, ADR front matter, vision, `config.json` against the schema)
and reports the keys of `ORG_EXEC_KEYS` that repositories must opt into. A repository's own `check` never fails
because of an invalid or stale organization note: the item is skipped with one line and `status` shows it.

- **[v1.4]** Given an organization note whose `paths` overlap the ticket's Paths and whose `repos` match, then the briefing
  lists it after the repository's notes and within `context.budget`; given `repos: ["web-*"]` in a repository named `api`,
  then it does not.
- **[v1.4]** Given a repository with no `docs/vision.md`, then its milestones' `Goal: G1` resolve in the organization's
  vision; given a vision of its own, then `Goal: org:G2` still resolves in the organization's.
- **[v1.4]** Given a spec citing `org-0003` that exists in the layer, then `check` passes; given `org-0099`, then it fails
  naming it; given no layer, then it warns only.
- **[v1.4]** Given an invalid organization note, then the repository's briefing skips it with one line and its `check`
  stays green; given `check` in the `.github` repository, then it fails naming the note.

## 7. Organizations: the template Project and rulesets

Tickets: #401.

### 7.1 `setup org`

`senior-mode setup org <owner> [--apply] [--print-ruleset]` prepares an organization once. Without `--apply` it prints
what it would do and changes nothing: an organization is shared infrastructure, so every action on it is explicit.

- For a user account there are no template Projects: it says so and exits 0.
- It looks for the organization's template Project (`template` true, titled like `board.template`'s source). Absent, with
  `--apply` it copies the plugin's template into the organization and calls `markProjectV2AsTemplate` on the copy, so
  organization members see it in the organization's Project templates. Present, it does nothing. A second `--apply`
  changes nothing.
- It then offers `board.template: <the organization's template id>` for the organization layer: with `--apply`, as a pull
  request on `<owner>/.github` (branch `chore/senior-mode-org`), never a push to its default branch; when that repository
  does not exist it prints the file to add and creates nothing. After merge, `setup github` in any repository of the
  organization copies the organization's template (§6.1), which the organization can extend with its own fields.
- A missing token scope (`project`) or a lack of organization permission is reported with the scope or role named and
  changes nothing.
- `--print-ruleset` prints the JSON of an organization ruleset with the rules of §7.2 for the organization's
  administrators to apply. senior-mode never creates, edits or deletes an organization ruleset.

- **[v1.4]** Given an organization with no template, then the dry run prints "would copy" and "would mark as template" and
  changes nothing; `--apply` does both once, and a second `--apply` changes nothing.
- **[v1.4]** Given a user-owned repository's owner, then `setup org` says there is nothing to do and exits 0.
- **[v1.4]** Given an organization layer with `board.template` set to the organization's template, then `setup github` in a
  new repository copies from it; given none, then from the plugin's.
- **[v1.4]** Given no `<owner>/.github` repository, then `--apply` prints the config to add and creates no repository.
- **[v1.4]** Given `--print-ruleset`, then valid JSON with the five rules of §7.2 is printed and no API write is made.

### 7.2 Organization rulesets: detect, respect, report

Protection is decided by the **effective rules** of the default branch, which GitHub computes from every ruleset that
applies (repository and organization) and the branch's own protection: `GET repos/<repo>/rules/branches/<default>`, read
with repository access only. senior-mode needs five rules there: `deletion`, `non_fast_forward`, `required_linear_history`,
`pull_request` with `rebase` among the allowed merge methods, and `required_status_checks` with strict policy and the
contexts `senior-mode/ci`, `senior-mode/review`, `senior-mode/security` (ADR 0006). `setup github`:

- Compares the effective rules with those five. A rule already provided, by an organization ruleset or otherwise, is not
  duplicated: the repository ruleset `senior-mode` is created with **only the missing rules**, or not at all when none is
  missing, and the output says which ruleset provides each (`rules: linear history from organization ruleset "base"`).
  An existing `senior-mode` ruleset is left as it is.
- Reports, without changing them, the rules it **cannot satisfy**: a required approving review count above 0 (the
  `review` gate is a status set by a reviewer session, not a GitHub approval), merge methods that exclude `rebase`,
  required status contexts senior-mode does not publish (recorded in `ci.required`, spec 409 §2.3), a merge queue, required
  signed commits. They go in the adoption pull request's `## Not mapped` (spec 409 §2.6) and in `workflow.unmapped`.
- With such a rule, `serve` and `run` do not merge in that repository: the pull request waits for a person with the
  reason `organization ruleset "<name>" requires <rule>`, `needs-human` once, never a retry, never an `--admin` merge or
  a bypass.

- **[v1.4]** Given effective rules that already contain all five, then no repository ruleset is created and each rule names
  its source.
- **[v1.4]** Given an organization ruleset with linear history and no status checks, then the repository ruleset is created
  with the other four rules and its output names the organization ruleset.
- **[v1.4]** Given an organization ruleset requiring one approving review, or allowing only `squash`, then setup reports
  it under `## Not mapped`, the daemon does not merge in that repository and flags `needs-human` once with the rule, and
  every other repository goes on.
- **[v1.4]** Given a second run, then nothing changes.

## 8. `status --all`

Tickets: #403.

`senior-mode status --all` prints one report for every repository of the Project's served set (§3), whatever the clone
the command runs in, and reads GitHub only: no clone of the other repositories is needed. It is one Project query plus one
batched repository query, bounded by `serve.callTimeout`. `--owner <login>` replaces the set by every repository of that
owner whose default branch has `.claude/senior-mode.json` (the way to see organizations that keep one Project per
repository). Three sections:

- **Budget.** Sessions running over `autonomy.parallel`, launches in the last hour over `sessionsPerHour`, the usage band
  (spec 327 §6) and every hold with its scope: machine, or the repository.
- **Decisions: one queue.** What waits for a person, across all repositories, one line each with its ref, how long, and
  the action: tickets and pull requests `needs-human`, external pull requests that cannot merge, `triage` issues (the one
  inbox for outside contributions), framing drafts to approve (spec 327 §9), epics stalled (§5.2), repositories held or
  not served with the reason, and `untrusted sub-issue`s. Ordered by urgency (P0, critical severity), then age.
- **Repositories.** One line each: Ready, In progress and In review counts, the last merge, held or `unreadable: <why>`.

`--json` has the same as `budget`, `decisions` and `repos`. A repository that cannot be read is one line and the exit
code stays 0; the others print. Without `--all`, `status` is unchanged.

- **[v1.4]** Given three served repositories with a `needs-human` ticket in two and a `triage` issue in the third, then
  Decisions lists the three in one queue with refs and ages, urgent first.
- **[v1.4]** Given a held repository and a running session count of 2 of 3, then Budget shows `2 of 3 sessions` and the hold
  with its repository.
- **[v1.4]** Given a repository that returns 404, then its line says `unreadable` and the report ends normally.
- **[v1.4]** Given `--owner acme` and three adopted repositories on two Projects, then all three appear; given a repository
  without `.claude/senior-mode.json`, then it does not.
- **[v1.4]** Given no `--all`, then the output is today's.

## 9. One repository stays as it is, and every choice is a key

Nothing changes for a repository with no `--project`, no `serve.scope`, no `epics` and no organization directory: its
Project, its `serve`, its slots, its order and its briefing are today's, as `autonomy.train: 1` keeps spec 327's merges.
The only addition is the conditional read of the organization layer, which costs one API call an hour and is turned off
by `org.inherit: false`. A repository that already has its own Project moves to a shared one with `setup github --project
<n> --move-items`, which adds its items to the shared Project, copies their field values with the mapping of `--migrate`
(spec 176) and unlinks the old Project without deleting it; `--dry-run` prints the mapping first.

- **[v1.4]** Given a repository with its own Project, when `--project 7 --move-items` runs, then its items are on Project 7
  with the same Status, Priority, Size and Paths, the old Project is unlinked and still exists; `--dry-run` writes nothing.
- **[v1.4]** Given a repository of a shared Project and no `serve.scope`, then `serve` there is the single-repository
  daemon.

New configuration, all optional, in `docs/guide/configuration.md` by the ticket that adds each:

| Key | Default | Meaning | Where |
|---|---|---|---|
| `serve.scope` | `repo` | `project`: serve every repository of the Project (§4) | repository, local |
| `serve.include`, `serve.exclude` | `["*"]`, `[]` | Globs of `owner/name` that bound the served set (§3) | repository, local |
| `serve.repos` | `{}` | Map `owner/name` to a clone path (§3) | local only |
| `serve.repoOrder` | `[]` | Repositories that win a tie in the queue (§4.3) | repository, organization |
| `autonomy.repoParallel` | `0` | Cap on one repository's sessions, 0 for none (§4.3) | repository |
| `epics.available` | `merged` | Default `Available:` of a cross-repo ticket (§5.1) | repository, organization |
| `org.inherit`, `org.repo`, `org.path`, `org.ref` | `true`, `.github`, `senior-mode`, default branch | The organization layer (§6.1); `org.path` selects one of several product directories | repository, local |
| `org.allowExec` | `[]` | Command keys accepted from the organization (§6.1) | repository, local |
| `project.home` | written by `setup` | The repository that holds the Project's duties (§2.3, §4.5) | repository |

CLI surface added: refs `owner/name#n`, `issue create --repo`, `setup github --project --home --move-items --dry-run`,
`setup org`, `status --all [--owner]`. The single `usage` line of the entry point and `docs/guide/commands.md` follow
(`docs-drift.sh`). Two modules are added to `bin/lib/`: `product.sh` (served set, clones, scope, the order of §4.3) and
`org.sh` (the organization layer, `setup org`); each ticket that adds a function says which module holds it, and the
module map of `CLAUDE.md` is updated by the first ticket that creates one.

## 10. The proof: a product on the sandbox

Tickets: #461. Each of §2 to §8 is first exercised on a sandbox organization (ADR 0011), with its faults injected on
purpose; stubbed counterparts of each fault run in `check`.

Setup. A sandbox organization with a `.github` repository (a `config.json`, one note, one ADR and a vision), a `producer`
and two consumers `web` and `worker`, one Project with all three attached through `setup github --project`, an external
account that files an issue and a pull request in each, `serve.scope: project` with `autonomy.parallel` 3. A cross-repo
epic with one produce, two consumes and one remove, `Available: released` on the produce, is framed by `frame` and run by
the daemon unattended.

Faults. During the epic: `kill -9` of `serve` between the merge of the produce and the start of the consumes; `web`
archived for a few minutes while its session runs, then unarchived; the network cut for five minutes; a red main in
`worker` (a commit that fails `check` pushed by the owner); a `commands.test` in the organization's `config.json`
without `org.allowExec`.

Pass criteria; failing one stops the proof:

1. No gate bypassed: each merged pull request had `ci`, `review` and `security` success on its merged head, `review` set by
   a reviewer session, no admin merge. The external pull requests were not merged by the daemon.
2. Order: the produce merged and its release was published before any consume started; the remove merged after both consumes.
3. Containment: during the archive and the red main, the other repositories kept launching and merging.
4. No duplicates: no ticket had two sessions and no pull request was created twice, from the leases and the pull request
   list, after the kill.
5. Untrusted input: no session started from the external issues, no briefing quoted them, and the organization's command
   was not run.
6. Resilience and drift: the board's drift count is zero at the end and every incident (hold, alert, `needs-human`) has an
   issue.

Acceptance criteria:

- **[v1.4]** Given the setup and the faults, then the six criteria hold and their evidence is a comment on #461.
- **[v1.4]** Given `senior-mode check`, then each fault of the list has a stubbed case that passes without the network.
- **[v1.4]** Each of §2 to §8 has a recorded sandbox session in the pull request that merged it. Epic #329 closes when its
  sub-issues are closed.

## Delivery

All of it ships in v1.4 (milestone "v1.4 Multi-repo and organizations"). Tickets and order:

| Ticket | Content | After |
|---|---|---|
| #447 | This spec and ADR 0026 | none |
| #450 | §2.1, §2.2: refs, repository-aware board, `issue create --repo` | #447 |
| #398 | §2.3, §9: attach, `--home`, `--move-items` | #450 |
| #451 | §3: served set, clones, trust | #450 |
| #402 | §4.1, §4.2, §4.5: scope, lock, state, Project duties | #450, #451 |
| #455 | §4.3: one budget, slot pool, order | #402 |
| #453 | §4.4: containment, scoped holds | #402 |
| #457 | §5.1: framing and the shape check | #450 |
| #399 | §5.2, §5.3: delivery from producer to consumers | #450, #402 |
| #400 | §6.1: the organization layer | none |
| #459 | §6.2: organization knowledge, ADRs, vision | #400 |
| #401 | §7: `setup org`, effective rules | none |
| #403 | §8: `status --all` | #450, #451 |
| #461 | §10: sandbox proof | #402, #453, #455, #399 |
| #463 | The guide | #461 |

Needs from earlier waves: #307 and #317 (v1.0, layers and schema), spec 373 (v1.0), spec 327's order, quota, slots and leases
(v1.2). #399 and #402 were L; they are M after this split and carry only the sections above.

## Out of scope

- Several owners on one Project; a repository of another owner is never served (§3).
- A product-level milestone or release train; cross-repo version pinning beyond what a consume ticket does in its own
  repository; rolling back a cross-repo epic (each step is deployable, a revert is a ticket per repository).
- An agent identity per repository or per organization (#175); creating an organization, its `.github` repository or
  its rulesets (§7); a dashboard.

## Test seams

`board_data`, `pick`, `pick_free`, `queue_lines`, `issue_create`, `setup_project`, `setup github`, `setup org`, the served
set, the clone registry, the slot pool, `serve_poll`, `serve_can_launch`, the hold scopes, `status --all`, `config explain`,
the organization layer reader and `check` in `bin/lib/*.sh`, through `bin/tests/test-*.sh` with the `gh`, `claude` and `git`
stubs and `SENIOR_MODE_SERVE_ONCE=1`, `SENIOR_MODE_NOW`. The `gh` stub gains a Project with items of several
repositories, `rules/branches/<branch>` answers, `compare` answers, release lists, a `.github` repository with a layer, and
a repository that turns archived or answers 404 at a chosen poll. Real GitHub semantics (cross-repo sub-issues and
dependencies, `markProjectV2AsTemplate`, organization rulesets) are exercised on the sandbox (ADR 0011).

## Open questions

- Cross-repository sub-issues and `blocked-by` links are believed to work between repositories of one owner; #450 confirms
  it on the sandbox first. Recommended fallback if they do not: the epic's body lists the edges (`Needs: owner/name#n`)
  and `board_data` reads them, at the cost of a second source for the graph.
- Organization rulesets may need a plan the sandbox does not have; recommended: test the effective-rules logic with the
  stub and a recorded real answer, and let the owner decide whether a paid sandbox organization is worth it.
- An organization with several products: recommended is one `org.path` per product (`senior-mode/billing`), chosen by
  each repository's `org.path`, with no product key in the schema until a real organization needs more.
- `Available: released` assumes a release of the producer's repository means its consumers can install it (a registry
  can lag); recommended: a consume ticket that cannot install the version is a ticket failure and ends `needs-human`,
  and a per-registry wait is added when the proof shows one is needed.
- The constants (10 minutes and an hour for the organization layer, three polls for the home) are first guesses; the proof
  measures them.
