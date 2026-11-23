---
id: 330
title: Every part of the workflow can be customized, and none of it can weaken the safety base
status: accepted
size: L
paths: ["plugins/senior-mode/bin/senior-mode", "plugins/senior-mode/bin/lib/**", "plugins/senior-mode/agents/**", "plugins/senior-mode/hooks/**", "plugins/senior-mode/presets/**", "plugins/senior-mode/schema/**", "docs/guide/**"]
adrs: ["0004", "0010", "0014", "0021", "0022", "0024", "0027"]
issue: "#330"
---

# Every part of the workflow can be customized, and none of it can weaken the safety base

## 1. Goal and non-goals

senior-mode has a few extension points (ADR 0010): `checks`, `review.sections`, `docs.extra`, `envGuard.forbidden`,
project skills and agents. They are fixed: a project cannot react to an event, add a reviewer that its domain needs
(design, legal, performance, accessibility), or say which model does which work. The agent roles pick their model from
their front matter (ADR 0004) and `run` retries once on Opus (ADR 0014). The owner framing of 2026-11-23 (epic #330) is
fixed; this spec makes it testable. Every criterion is tagged **[v1.5]**, the epic's milestone. What it builds on ships
earlier: config layers, file overrides, `config explain` and process profiles (#307), the configuration schema and its
validation (#317) and `doctor` (#316), all v1.0.

Goals: three levers that let a team shape the daemon without forking the plugin, event hooks (§3), custom roles (§4) and a
model routing table (§5); one rule that bounds all of them (§2); a way to see what is changed (§6) and to learn how (§7).
The standing goals of the owner govern the design: maximum throughput with the workflow intact, every behaviour
configurable, autonomy that survives its own customization, adoption of existing projects, and outside input treated as
untrusted (ADR 0024).

Non-goals:

- Lifting a locked rule. A lever adds checks, holds, reviewers and reports; it never removes a gate (§2.2). The lift by
  repository ADR is the mechanism of #307; here only its interplay with the levers is specified.
- A plugin API, in-process extensions or a second agent CLI. Everything runs as a script, a URL or a Claude Code session.
- Domain packs in the core (ADR 0010). The guide's recipes (§7) are examples a project copies; none is a default.
- Changing who reviews or merges (ADR 0017, 0018, 0019, 0023).

Reused, not redone: #307 (layers, overrides, profiles, `config explain`, the lift ADR), #317 (schema and validation), #316
(`doctor`), #299 (cost per ticket and role, used by budgets), #365 (adaptive routing edits the table of §5),
#304 (reviewer never on the implementer's model), spec 373 (failure classes, `held`, `state_write`, the chaos suite),
`notify.*` of spec 131 (unchanged), ADR 0024 (the trust gate).

Conventions: `serve dir` is `<git common dir>/senior-mode/serve/`; a *session* one `claude -p` process group; `base` the
branch tickets merge into (spec 409); *customization* is the keys `hooks`, `roles`, `models`, `providers` and the files
under `.claude/senior-mode/hooks/`, `.claude/senior-mode/roles/` and `.claude/senior-mode/overrides/`.

## 2. Rules every lever obeys

### 2.1 Read from the base, reviewed by the owner (#443)

Customization runs on the agent machine with the owner's permissions, so it is code the owner must have reviewed. The
daemon and every session read it from the base branch (`git show origin/<base>:<path>`, as `review.sections` already does),
never from a pull request's head or a worktree, so a pull request cannot change what runs before it merges. Defaults:
`.claude/senior-mode.json` and `.claude/senior-mode/**` are in `protected` (setup writes the globs and `setup github` maps them to
CODEOWNERS), and the self-protect hook already refuses an agent's edit under `.claude/` during a run. A `run` hook found
in a layer above the repository (plugin profile, organization) does not execute until the repository names it
under `hooks.enable`; a layer may define roles and routing rows, which only select sessions.

- **[v1.5]** Given a pull request that adds a hook and a routing row, when the daemon fires an event or resolves a model
  for its ticket, then it uses the base branch's customization; after the merge the next poll uses the new one.
- **[v1.5]** Given a fresh `setup repo`, then `protected` lists `.claude/senior-mode.json` and `.claude/senior-mode/**`; given an
  existing `protected` list, setup adds them without removing an entry.
- **[v1.5]** Given a plugin profile that defines a `run` hook, then it does not run; given `hooks.enable: ["<name>"]` in the
  repository config, then it does.

### 2.2 Add, never lift (#443)

The locked base is: the secret scan, the protected zones, the bash guard, no force-push and no `--no-verify`, a green
`check` before a merge, the independent review, and the trust gate of ADR 0024 (tickets and pull requests from outside
the team). No lever changes it:

- A hook answers *no objection*, *hold* or *refuse* (§3.4). Exit 0 never overrides a failed gate; it only declines to add one.
- A role adds a reviewer or a step. Its approval does not replace the built-in reviewer's, and it never sets a commit
  status (§4.4).
- A routing row picks a model and effort, within the floors of §5.4.
- Validation (#317) refuses a customization that names a locked rule (`lift`, `skip`, `bypass` keys do not exist), and the
  runtime ignores one that got past it, logging the rule.

The lift itself (an ADR on the base branch referenced by the config) stays #307's, and `doctor` and `status` flag it (§6).

- **[v1.5]** Given a hook that exits 0 on `pr.merging` for a pull request whose `senior-mode/ci` is `failure`, then the
  daemon does not merge it.
- **[v1.5]** Given a role that approves while the reviewer requested changes, then the pull request is not merged and
  `senior-mode/review` is not `success`.
- **[v1.5]** Given a routing row that gives the reviewer the implementer's model, then validation fails naming both rows.
- **[v1.5]** Given a hook entry with a key that names a locked rule, then validation fails with the closest known key.

### 2.3 Validation and the schema

The schema of #317 covers `hooks`, `roles`, `models` and `providers`, plus the event payloads (§3.2). Validation runs in
`check`, `doctor` and, before a customization is used, in the daemon. Errors name the key path, the value and the nearest
valid key or enum value.

- **[v1.5]** Given `"evnet": "needs-human"` in a hook, then `check` fails with `hooks.on[0].evnet: unknown key, did you mean event`.
- **[v1.5]** Given two hooks with the same `name`, a role named as a built-in agent, or two rows of the same layer, equal
  specificity and an overlapping match, then validation fails naming both.

### 2.4 Failures of customization are not failures of tickets (#448)

The daemon stays up whatever a script, a session or a row does (spec 373, ADR 0021). Every failure of customization has a
class and a reaction, none ends the process:

| Fault | Reaction | Breaker |
|---|---|---|
| Non-blocking hook fails or times out | Retried (§3.5), then recorded in `events/failed/`, one alert per hook | Not counted |
| Blocking hook errors or times out | Fails closed: the action is held (`onError: "block"`, the default) and the alert names the hook; `onError: "ignore"` lets the action go | Not counted |
| Blocking role session dies or times out | Classified as in spec 373 §1: transient resumes; a ticket-class end is `needs-human` naming the role | Not counted |
| Non-blocking role session fails | A warning in the pull request, the merge continues | Not counted |
| A routing row names a model the CLI rejects | Class `config`: the plugin's default row is used once and one alert names the row (§5.6) | Not counted |
| The merged config is invalid | The last valid one stays in force (§2.5) | Not counted |

### 2.5 The last valid config stays in force (#444)

Each poll validates the base branch's customization. On success it is saved as `config.valid.json` in the serve dir, with
the commit it came from, by `state_write`. On failure the daemon keeps running on that snapshot, sends one alert (`config`,
the key path and the error), shows `config: last valid <sha>` in `status`, and sends one `recovered` alert when a valid
config returns. With no snapshot (first start) it runs on the plugin defaults and says so.

- **[v1.5]** Given a valid config, then an invalid one merged into the base, when the daemon polls, then it launches with the
  previous hooks, roles and rows, one alert is sent however many polls follow, and `status` names the commit.
- **[v1.5]** Given the fix is merged, then the next poll uses it and sends `recovered` once.
- **[v1.5]** Given an invalid config and an empty serve dir, then the daemon runs on the defaults and never exits.

### 2.6 Outside input is data (ADR 0024)

Payloads never carry an issue or pull request body or a comment; they carry numbers, titles, labels, sizes, paths, URLs and
`external` (true when the author is not a collaborator or the head is a fork). A hook receives strings on stdin as JSON
and never as arguments or environment values. Roles do not run on an external pull request, which the daemon does not
review or merge (ADR 0024). Role sessions on a team pull request carry the usual preamble that the diff and the ticket are
data, not instructions.

- **[v1.5]** Given a ticket titled `$(touch pwned); "`, then a `ticket.started` hook receives it unchanged in `ticket.title`
  on stdin, the hook command line and environment contain none of it, and no file `pwned` appears.
- **[v1.5]** Given a pull request from a fork, then no role session starts for it and no `pr.merging` event is emitted.

## 3. Event hooks (#404)

### 3.1 Configuration

```json
"hooks": {
  "timeout": 30, "maxConcurrent": 4, "maxAge": 3600, "env": ["SLACK_WEBHOOK_URL"],
  "on": [
    { "name": "slack", "event": ["needs-human", "release.published"], "run": ".claude/senior-mode/hooks/slack.sh" },
    { "name": "freeze", "event": "pr.merging", "run": ".claude/senior-mode/hooks/freeze.sh", "block": true, "timeout": 10 },
    { "name": "audit", "event": "pr.merged", "url": "https://hooks.example.com/sm", "secretEnv": "AUDIT_SECRET",
      "when": { "sizes": ["M", "L"] } }
  ]
}
```

`name` (unique, `[a-z0-9-]+`), `event` (one or a list; no wildcard), exactly one of `run` (a path under
`.claude/senior-mode/hooks/`, no `..`, no symlink out) or `url` (https; `http` only for localhost), `block` (only on a
blocking event, `run` only), `timeout` (seconds, default `hooks.timeout`), `onError` (`block` or `ignore`; default `block`
for a blocking hook, `ignore` otherwise), `version` (payload version, default 1), `when` (the filter of §4.2: `paths`,
`labels`, `sizes`, `types`; an event with no ticket ignores it). `hooks.env` lists the environment variable names passed to
the scripts. `notify.*` keeps working as before and is not deprecated: it is the same delivery as a `url` hook on
`needs-human` and `daemon.alert`, with its own payload.

### 3.2 Events and payload

| Event | Fired | Blocking |
|---|---|---|
| `ticket.starting` | Before a session launches for a Ready ticket | yes |
| `ticket.started` | After the launch | no |
| `pr.opened` | A session opened a pull request | no |
| `review.finished` | A reviewer verdict was published (`approve` or `changes`, with the round) | no |
| `pr.merging` | Before the daemon merges | yes |
| `pr.merged` | After the merge | no |
| `needs-human` | A ticket or pull request was flagged, with the cause | no |
| `daemon.alert` | An alert with no number (breaker, environment hold, `recovered`, `config`) | no |
| `release.published` | `senior-mode release` published a version | no |

The payload is one JSON object on stdin, UTF-8, at most 64 KB:

```json
{ "version": 1, "event": "pr.merged", "id": "evt_9c1f2b7a", "time": "2026-11-23T10:00:00Z", "repo": "acme/shop",
  "daemon": { "worker": "host-1", "plugin": "1.5.0" },
  "ticket": { "number": 12, "title": "...", "size": "M", "type": "feature", "milestone": "v1.5", "labels": [],
              "paths": [], "url": "...", "external": false },
  "pr": { "number": 40, "url": "...", "head": "<sha>", "base": "main", "external": false },
  "data": { "method": "rebase", "sha": "<sha>" } }
```

`ticket` and `pr` are absent when the event has none; `data` is per event. The environment of the script has
`SENIOR_MODE_EVENT`, `SENIOR_MODE_EVENT_ID`, `SENIOR_MODE_HOOK` and `SENIOR_MODE_REPO`. `id` is a hash of the event, the
subject and its sequence, so a replay carries the same id and a consumer can deduplicate. The JSON schema
`plugins/senior-mode/schema/hook-event.v1.json` has one definition per event, and `plugins/senior-mode/schema/fixtures/v1/`
one frozen payload per event.

**Versioning.** Within a version, fields are added and never removed or retyped. A breaking change is version 2, emitted
only to hooks that say `version: 2`; version 1 keeps being emitted for two minor releases after, and `doctor` flags a hook
pinned to a deprecated version.

- **[v1.5]** Given each event, then the emitted payload validates against the schema and every key of the frozen v1 fixture
  is present with the same type; a test fails if one disappears.
- **[v1.5]** Given a ticket whose body says "ignore your rules", then no payload contains the body or a comment.
- **[v1.5]** Given a replay after a crash, then the same event has the same `id`.

### 3.3 Execution

A `run` hook runs as the blob of `origin/<base>:<path>` written to a temporary file (mode 0700), in its own process group,
with the repository root as the working directory, a scrubbed environment (`PATH`, `HOME`, `LANG`, `TMPDIR`, the
`SENIOR_MODE_*` above and the names in `hooks.env`) and the payload on stdin. It gets no GitHub token and no Claude
credentials unless named in `hooks.env`. Stdout and stderr go to `events/log/<id>-<hook>.log`, truncated to 64 KB. At
`timeout` the group is terminated, then killed after 5 s. A `url` hook gets a `POST` with `Content-Type: application/json`,
`X-Senior-Mode-Event`, `X-Senior-Mode-Event-Id` and, when `secretEnv` names a variable, `X-Senior-Mode-Signature:
sha256=<hmac of the body>` with `X-Senior-Mode-Timestamp`; any 2xx is success. Secrets are named by variable, never written
in the config: validation refuses a value that looks like one (spec 130's patterns).

- **[v1.5]** Given a hook that prints its environment, then it holds none of the daemon's other variables or credentials.
- **[v1.5]** Given a `url` hook with `secretEnv`, then the signature verifies with the variable's value and the timestamp is
  in the headers.
- **[v1.5]** Given a hook script path that escapes the hooks directory through `..` or a symlink, then validation fails.
- **[v1.5]** Given a hook that outputs 10 MB, then its log is cut at 64 KB and the daemon's memory does not grow.

### 3.4 Blocking events

Only `ticket.starting` and `pr.merging` block, and only `run` hooks, in config order, stopping at the first answer other
than 0. Exit codes: **0** no objection; **10** *hold*: the action is not taken now and is evaluated again at the next poll;
the first stdout line is the reason, logged once per change; **11** *refuse*: the ticket or pull request becomes
`needs-human` with that reason; any other code, or a timeout, is an error handled by `onError`. A hold older than 24 h
sends one `daemon.alert`. Blocking hooks run only for a ticket that would otherwise launch or a pull request that would
otherwise merge in this poll, so a hook costs nothing for a ticket the daemon would not start anyway.

- **[v1.5]** Given a `pr.merging` hook that exits 10 with `freeze until Monday`, then the pull request is not merged, stays
  green and the log says `held by freeze: freeze until Monday` once; the next poll after the hook exits 0 merges it.
- **[v1.5]** Given a hook that exits 11, then the ticket is `needs-human` with the reason, and not counted by the breaker.
- **[v1.5]** Given a blocking hook that exceeds `timeout`, then the action is held, one alert names the hook, and with
  `onError: "ignore"` the action proceeds.
- **[v1.5]** Given `block: true` on `pr.merged`, then validation fails (not a blocking event).

### 3.5 Delivery: at least once, off the critical path

A non-blocking event is written to `events/pending/<id>.json` by `state_write` before the step that produced it returns,
and a runner drains the directory with at most `hooks.maxConcurrent` hooks at once. Events of one ticket are delivered in
order; there is no global order. A failure is retried after 30, 120 and 600 s (the same shape as spec 373's backoff), then the
event moves to `events/failed/` and counts in `status`. An event older than `hooks.maxAge` is dropped with a log line. At
start the daemon replays `pending/`, so a `kill -9` loses no event and delivers one twice at most. The poll never waits for
a non-blocking hook.

- **[v1.5]** Given 10 non-blocking hooks that sleep 60 s, then a poll takes less than 1 s longer than with none, and at most
  `maxConcurrent` run at once.
- **[v1.5]** Given `kill -9` of the daemon after the event is written and before the hook ran, then on restart the hook runs
  once with the same id.
- **[v1.5]** Given a hook failing 4 times, then the event is in `events/failed/` and `status` shows the count.

## 4. Custom roles and agents (#405, #445)

### 4.1 Declaring a role

```json
"roles": {
  "designer": {
    "agent": ".claude/senior-mode/roles/designer.md", "kind": "reviewer", "blocking": true,
    "checklist": "docs/review/design.md", "model": "opus", "effort": "medium",
    "when": { "paths": ["src/ui/**", "**/*.css"], "labels": ["ui"], "sizes": ["M", "L"], "types": ["feature"] },
    "budget": { "sessions": 2, "minutes": 30 }
  },
  "legal": { "agent": ".claude/senior-mode/roles/legal.md", "kind": "step", "position": "after-implement",
             "when": { "labels": ["privacy"] }, "blocking": false }
}
```

`agent` is a Claude Code agent file (front matter `name`, `description`, `tools`, optional `model` and `effort`; the body is
the prompt), read from the base branch. `kind` is `reviewer` (reads the pull request, reports a verdict) or `step` (a
session in the ticket's pipeline at `position` `before-implement` or `after-implement`; it works in the ticket's worktree
and may commit, under the same guards as the implementer, including the red tests and self-protect). `checklist` is a
Markdown file the session reads, as `review.sections` is. `blocking` (default `true` for a reviewer, `false` for a step)
says whether a failed or missing verdict holds the pull request. A reviewer's `tools` can only narrow the built-in
reviewer's read-only set. `model` and `effort` are the default of a row `{role: <name>}`; a row of §5 that matches wins. A role is
named `[a-z0-9-]+` and never as a built-in agent (`architect`, `implementer`, `ops`, `researcher`, `reviewer`, `scout`,
`security`, `test-author`): replacing a built-in agent is an override file (#307), which keeps its floor (§5.4).

- **[v1.5]** Given a role with no `when` and no `always: true`, a role named `reviewer`, or a `kind` outside the two,
  then validation fails.
- **[v1.5]** Given a reviewer role whose `tools` include `Edit`, then validation fails.

### 4.2 Triggers

`when` has four dimensions, `paths`, `labels`, `sizes`, `types`. Dimensions are ANDed, the values of one are ORed, an
absent dimension matches anything, and `always: true` stands for no dimension at all. `paths` globs use the semantics of
`protected`; a `step` before the work matches them against the ticket's Paths, a reviewer or an `after-implement` step
against the diff of the head against the base. The selection is a pure function of the ticket, the diff and the config; the pull request
body gets a `## Roles` block listing each selected role and the trigger that matched, so a review shows why a role ran.

- **[v1.5]** Given a ticket of size M labelled `ui` and a diff touching `src/ui/Button.tsx`, then `designer` is selected and
  listed under `## Roles` with `paths, labels, sizes`; given size S, then it is not selected.
- **[v1.5]** Given the same inputs twice, then the same roles are selected in the same order (config order).

### 4.3 Steps in the pipeline

The pipeline today is: test author (M tickets), ticket session, reviewer, integrator. A step is inserted before or after
the ticket session, one at a time per ticket, with its own session and its own budget. It does not hold a slot while it
waits for another role, and it counts in `sessionsPerHour` (not in `ticketsPerHour`, #355). A step that commits does so
on the ticket's branch with `<type>(<scope>): ...` in the project's commit format (spec 409); the diff it produced is the
reviewer's input, so its work is reviewed with the rest.

- **[v1.5]** Given an `after-implement` step `legal` triggered by `privacy`, then its session starts after the ticket
  session ends with a delivered pull request and before the reviewer, in the ticket's worktree.
- **[v1.5]** Given a step whose session commits a change to a protected path, then the guards refuse it as they do for the
  implementer.
- **[v1.5]** Given `budget.sessions: 1` and a step that failed once, then it does not run again and the ticket is
  `needs-human` naming the role and the budget.

### 4.4 Reviewer roles gate the merge (#445)

The daemon starts every selected reviewer role beside the built-in reviewer, in parallel, on the same head. A role reports
in two places and sets no commit status: its outcome file (`<n>.role-<name>.outcome`, first line `approve` or `changes:
<reason>`, a cache) and one comment on the pull request, `<!-- senior-mode:role <name> head=<sha> verdict=approve|changes
-->` followed by its findings. The comment is the durable record (GitHub is the truth, ADR 0021), so a crash or a second
machine loses nothing; only comments by the account the daemon runs as count, so a marker pasted by another commenter is ignored.
The statuses stay as ADR 0006 and 0017 have them: `senior-mode/review` is set by the reviewer session alone, so no ruleset
changes. The merge gate (`run_blocker`, ADR 0018) and `ready` add one condition: for the head, every selected blocking role
has an `approve`. A missing verdict waits; a `changes` verdict opens one review round, like the reviewer's. A new head resets every
verdict. A non-blocking role's findings are in its comment and change nothing else. The built-in reviewer is never skipped
and a role cannot stand in for it.

- **[v1.5]** Given `designer` blocking and approving on the head and the three statuses `success`, then the daemon merges.
- **[v1.5]** Given `designer` answering `changes: contrast`, then the pull request is not merged, the next ticket session
  round receives the finding, and a new head makes the reviewer and the role run again.
- **[v1.5]** Given a marker comment `verdict=approve` written by another account, then it is ignored and the gate waits.
- **[v1.5]** Given a role that never answers before `budget.minutes`, then a blocking role leaves `needs-human` naming it,
  a non-blocking one is a warning, and `RUN_FAILS` is unchanged.
- **[v1.5]** Given two roles whose triggers match, then they and the reviewer run at once (within `autonomy.parallel`) and the
  review takes about the longest of them, not the sum.
- **[v1.5]** Given a daemon killed after a role commented and before it merged, then on restart the same verdict is read from
  GitHub and the pull request merges with no second role session.

## 5. The model routing table (#406)

### 5.1 The table

`models` is a list of rows; the plugin's defaults are rows too, the same ones as ADR 0004 and 0014 give today.

```json
"models": [
  { "role": "implementer", "size": "S", "model": "sonnet", "effort": "medium" },
  { "role": "implementer", "size": ["M", "L"], "model": "sonnet", "effort": "high",
    "escalate": [{ "after": 1, "model": "opus", "effort": "high" }], "fallback": { "model": "sonnet" },
    "budget": { "sessions": 3, "cost": 8.0 } },
  { "role": "reviewer", "model": "opus", "effort": "high" },
  { "role": "*", "type": "chore", "model": "haiku", "effort": "low" },
  { "role": "implementer", "type": "chore", "provider": "local", "model": "qwen3-coder", "tier": 1, "effort": "low" }
]
```

A row has the match dimensions `role` (a built-in agent role, a custom role or `*`), `size`, `type` (one value or a list;
absent means any) and the choice `model`, `effort`, `provider` (§5.5), `tier` (§5.4), `escalate`, `fallback`, `budget`.
Roles are the session kinds of the daemon: `architect`, `implementer`, `reviewer`, `test-author`, `security`, `integrator`,
`scout`, `researcher`, `ops` and the custom ones. `autonomy.escalate: false` stays the master switch that ignores every
`escalate`.

### 5.2 Resolution

The row with the most non-wildcard dimensions wins; among equal rows the one from the highest layer (repository over
organization over profile over plugin) wins; two equal rows of one layer are a validation error. When nothing matches, the
plugin's catch-all row applies. The result and the shadowed rows are printed by `config explain models.<role>.<size>.<type>`.

- **[v1.5]** Given the table above, then `implementer` on a bug of size M resolves to the second row, a chore of size S to
  the last row, and `config explain models.implementer.M.bug` names the winner and the three shadowed rows with their layers.
- **[v1.5]** Given no `models` key, then every role, size and type resolves exactly as in ADR 0004 and 0014 (the existing
  routing tests pass unchanged).
- **[v1.5]** Given a repository row and a profile row of equal specificity, then the repository's wins.

### 5.3 Escalation, fallback and budget

`escalate` is a list of steps `{after, model, effort, provider}`: after that many ticket-class failed sessions of the role on
the ticket, the next session uses the step. A step cannot lower the tier (§5.4). `fallback` is the model used when the
row's model fails as transient (spec 373 §1) `serve.fallbackAfter` times in a row (default 3), until a
session on the first model succeeds again on a later ticket. `budget`: `sessions` (all sessions of the role on the ticket,
transient ends not counted), `minutes` (the session timeout for this row, replacing `autonomy.sessionTimeout`) and `cost`
(API-equivalent dollars of #299 for the role on the ticket). Budgets are checked between sessions, not inside one. An
exhausted budget stops that role's sessions on the ticket: `needs-human` with the cause `budget`, the row and the figures; it
is the owner's own limit working, so it does not count for the breaker.

- **[v1.5]** Given `escalate: [{after: 1, model: opus}]` and one failed session, then the second runs on Opus; given
  `autonomy.escalate: false`, then it runs on the first model.
- **[v1.5]** Given a row on `sonnet` with `fallback: haiku` and 3 transient ends in a row, then the 4th launch uses `haiku`,
  none of the transient ends is counted, and the log says `fallback`.
- **[v1.5]** Given `budget.cost: 8.0` and a ticket whose implementer sessions cost 8.40, then no further implementer session
  starts, the ticket is `needs-human` with `budget`, and `RUN_FAILS` is unchanged.
- **[v1.5]** Given `budget.cost` on a model with no known price, then validation warns and the budget is not enforced; `sessions`
  and `minutes` are.

### 5.4 Floors that no row can lower

Models have a tier: `haiku` 1, `sonnet` 2, `opus` 3 (aliases and full model ids containing the family name); a row for another
model declares `tier`. For one ticket: the resolved model of `reviewer`, of `security` and of every blocking reviewer role is
different from the implementer's (#304) and of a tier at least as high (ADR 0004); an escalation never lowers the tier. The
floors are checked statically for every role, size and type by validation, and again at launch, where a violation refuses
the launch with the cause `config` (a hold of that role, §5.6).

- **[v1.5]** Given `reviewer` on `sonnet` and `implementer` on `opus` for size L, then validation fails naming the two rows
  and the size.
- **[v1.5]** Given a custom model with no `tier` in a row for `reviewer`, then validation fails.
- **[v1.5]** Given a launch where the floors would be violated although validation passed (the layers changed between the
  two), then nothing launches for that role, the ticket stays Ready and one `config` alert is sent.

### 5.5 Other providers and local models

`providers` maps a name to environment variables a session gets, so that the same Claude Code runs against a gateway, Bedrock,
Vertex or a local server, wherever Claude Code supports it:

```json
"providers": { "local": { "env": { "ANTHROPIC_BASE_URL": "http://localhost:11434", "ANTHROPIC_AUTH_TOKEN": "$LOCAL_TOKEN" } } }
```

Only the variable names of the schema's allowlist are accepted; a value starting with `$` is read from the daemon's
environment, and a literal for a name that looks secret (`TOKEN`, `KEY`, `SECRET`) is refused. The session is always
`agent.command` (Claude Code), so the guards hold; a provider cannot change the command, and a model the guards do not
cover is out of scope (the rule of `agent.command` today). `doctor` can probe a row with a one-token session.

- **[v1.5]** Given a row with `provider: "local"`, then its session is launched with those variables and no other row's, and
  `ps` of the session does not show the token.
- **[v1.5]** Given `"ANTHROPIC_AUTH_TOKEN": "sk-..."`, then validation fails; given a `provider` that is not declared, validation fails.

### 5.6 A row the CLI rejects (class `config`)

A model the CLI rejects (`issue with the selected model`, `model_not_found`, an unreachable provider) is a fault of the
configuration, not of the ticket, the model or the world, so it is not retried as a ticket failure and does not escalate.
It is class `config`: the role's plugin default row is used once for the ticket and one alert names the row; if that
would break a floor (§5.4), the role is held for the ticket with `needs-human` and the cause `config`. `status` lists the
rejected rows until a valid config replaces them.

- **[v1.5]** Given a row naming `claud-opus`, then the first session ends with the CLI's error, the second runs on the default
  row, one alert names the row, `RUN_FAILS` is unchanged and the ticket is delivered.
- **[v1.5]** Given that the default row for the reviewer equals the implementer's configured model, then the reviewer is held
  and the ticket is `needs-human` with `config`.

### 5.7 Adaptive routing edits this table

The proposal of #365 is a change to `models`, validated by `check` like any other (§2.3) and held for a human because
`.claude/senior-mode.json` is protected (§2.1); it never edits a floor and never routes `reviewer` onto the implementer's model.

- **[v1.5]** Given a retro proposal that sets `reviewer` below `implementer`, then `check` fails on it.

## 6. What is overridden: `doctor` and `status` (#446)

`doctor` (#316) gains a section `Customization` that lists, with the file and the layer (#307) of each: hooks, roles, rows of
`models` and providers that differ from the plugin's, override files, profile and layer values that differ from the defaults, and
each lifted safety rule with its ADR. It flags a lift whose ADR is missing, not `accepted` or not on the base branch, a hook
pinned to a deprecated payload version, a role never selected in the last 90 days (from the PR bodies), a routing row never
matched, and the rejected rows of §5.6. `status` shows one line, `customized: 2 hooks, 1 role, 3 rows; lifted: none`, and a
warning line per lifted rule. `--json` carries the same content.

- **[v1.5]** Given a hook, a role and a row, then `doctor` lists the three with their files and layers; given none, it says
  `nothing overridden`.
- **[v1.5]** Given a lift whose ADR is `proposed`, then `doctor` exits 1 naming the rule and the ADR, and `status` says so.
- **[v1.5]** Given a hook with `version: 1` after version 3 shipped, then `doctor` warns that it is deprecated.

## 7. The customizing guide (#407)

`docs/guide/customizing.md`, linked from the guide index and from `configuration.md`, explains the layers, the three levers
and the locked base, with one recipe per need. Each recipe is a fenced block that a test extracts and exercises, so none rots:

| Recipe | Lever |
|---|---|
| Notify a chat on `needs-human` and `release.published` | hook |
| Freeze merges outside office hours or during a release | blocking hook |
| Add a designer reviewer on UI paths | reviewer role |
| Add an accessibility reviewer on `a11y`-labelled tickets | reviewer role |
| A performance budget check on `src/**` hot paths | reviewer role and `check` |
| A legal or privacy step on labelled tickets | step role |
| Haiku for docs and chores, Opus for security | routing |
| Fall back to Sonnet when Opus is overloaded | routing |
| A local model for S chores | provider |
| A project profile derived from `strict` | #307 |
| Replace a template or a skill | override file (#307) |
| Lift a safety rule, and why you probably should not | the ADR of #307 |

- **[v1.5]** Given each `json` recipe, then it validates against the schema; each script recipe passes `shellcheck` and runs
  against the matching frozen payload with the expected exit code; each role file parses as an agent.
- **[v1.5]** Given a key of the schema for `hooks`, `roles`, `models` or `providers`, then `configuration.md` has its row, and
  `docs-drift.sh` fails when one is missing.
- **[v1.5]** Given the guide, then it states what is locked and how it is lifted, and every link resolves.

## 8. Security

Data handled: payloads (numbers, titles, labels, paths, URLs: no bodies), routing and provider environment (credentials by
reference only), role files (prompts). Who may change it: the owner, through a reviewed change to the base branch. Threats
and protections:

| Threat | Protection |
|---|---|
| A pull request adds a hook, a role or a routing row | Read from the base (§2.1); protected paths; self-protect during runs; owner review |
| Injection through a title or label into a script | Payload on stdin as JSON, never argv or env (§2.6, §3.3) |
| A hook leaks secrets | Scrubbed environment, no token unless named in `hooks.env`, secrets only by variable name |
| Prompt injection into a role session from an outside pull request | No role on an external pull request; the data-not-instructions preamble on team ones |
| A shared (organization) layer ships a hook that runs everywhere | `hooks.enable` in the repository (§2.1) |
| A forged or replayed webhook delivery | HMAC signature, timestamp and stable event id (§3.3) |
| A hook or a role starves the daemon | Timeouts, `maxConcurrent`, output caps, off the critical path (§3.5), role budgets |
| A routing change weakens review | Floors checked at validation and launch (§5.4) |
| A custom role or hook is used to skip a gate | Veto-only and additive semantics (§2.2), tested per gate |
| A bad customization stops the daemon | Last valid config, class `config`, chaos tests (§2.4, §2.5, §9) |

## 9. The proof: resilience and throughput (#448)

The cases of §2.4 join the chaos suite of spec 373 as stubs in `check`, and the sandbox release checklist (ADR 0011) lists them
with real faults: a hook that hangs, exits 1, floods its output and is killed with the daemon mid-delivery; a role session
that dies, hits the usage limit or times out; a routing row naming a missing model; an invalid config merged into the base.
Each ends healthy, with the right alert, no breaker count and no human.

- **[v1.5]** Given each case above on the stubs, then the end state holds: no ticket half-done, one alert per cause, `RUN_FAILS`
  unchanged, events delivered once more at most.
- **[v1.5]** Given a sandbox run with a freeze hook, a designer role and a local-model row enabled, then 5 tickets are delivered
  with the three in effect and the report shows each at work (§6's lists).
- **[v1.5]** Given 5 tickets that no hook, role or row matches, then the time from Ready to merged with the customization
  enabled is within 5 percent of the time with it disabled: a lever costs nothing where it does not apply.

## Delivery

#443 §2.1 and §2.2, #444 §2.5 first; then #404 §3 and #406 §5, in parallel; #405 §4.1 to §4.3 after #406; #445 §4.4 after
#405; #446 §6 after #404, #405 and #406; #448 §9 after those and #444; #407 §7 last. The v1.0 work they rest on is #307,
#316 and #317.

## Out of scope

A plugin SDK or in-process extensions; a hook or role marketplace; blocking `url` hooks; a hook that can approve or
alter a gate; routing by file, directory or time of day; a second agent CLI (`agent.command` keeps its rule); a graphical
editor for the table.

## Test seams

`bin/lib/*.sh` through `bin/tests/test-*.sh` with the `gh` and `claude` stubs, `SENIOR_MODE_SERVE_ONCE=1` and `SENIOR_MODE_NOW`:
the event emitter and runner (`event_emit`, `event_block`), the selection of roles (`role_select`), the resolution of rows
(`model_resolve`), the validation of #317, `doctor` and `status`, and `docs-drift.sh` for the guide; the payload schema and
frozen fixtures under `plugins/senior-mode/schema/`. Real sessions of roles and models, and a provider, are exercised on the
sandbox before merge (ADR 0011).

## Open questions

- Whether a `url` hook may block (an HTTP status as the answer) waits for a real request; recommended: keep it `run` only,
  where the exit code and timeout are unambiguous.
- Hook ordering across events, and batching many `pr.merged` events of a train (spec 327 §4) into one delivery, wait for the
  first use; recommended: one event per pull request, as written.
- The tier of a model the owner knows better than the plugin: `tier` in the row is the answer today; a shared registry can
  come with the organization layer (v1.4).
- Per-milestone or time-based routing rows are out of scope; recommended: revisit when a team asks for them.
