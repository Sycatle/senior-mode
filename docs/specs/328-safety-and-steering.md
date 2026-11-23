---
id: 328
title: The daemon runs sessions in containers, stays inside a budget, shows the UI it builds and takes the owner's decisions from a phone
status: accepted
size: L
paths: ["plugins/senior-mode/bin/**", "plugins/senior-mode/agents/**", "plugins/senior-mode/skills/**", "plugins/senior-mode/hooks/**", "plugins/senior-mode/sandbox/**", "plugins/senior-mode/templates/**", "plugins/senior-mode/presets/**", "docs/guide/**", "docs/incidents/**"]
adrs: ["0011", "0015", "0017", "0018", "0021", "0023", "0024", "0025"]
issue: "#328"
---

# The daemon runs sessions in containers, stays inside a budget, shows the UI it builds and takes the owner's decisions from a phone

## 1. Goal and non-goals

The daemon of specs 131, 327 and 373 is fast and survives its environment; it still runs every session with the owner's whole
account, spends without a limit, merges UI changes nobody has seen and asks its questions on a board the owner has to open.
Four things stand between "it works" and "it can be left alone for a month": a session that cannot reach what it should not
(§2), a bill that stops where the owner said (§3), proof that what was built looks and behaves right (§4, §5), and a way to
steer from a phone (§6 to §8). The owner decisions of 2026-11-23 (issue #328) are fixed; this spec makes them testable. Every
criterion is tagged **[v1.3]**, the milestone of the epic.

Non-goals:

- Changing who reviews or merges, or any gate (ADR 0017, 0018, 0019, 0023): no status is skipped, no bypass actor is added. The
  phone answers questions; it never merges, approves or sets a status (§6.5).
- A defence against a compromised machine or a malicious owner (ADR 0015). The container bounds what a session can reach; the
  host, the Docker or Podman daemon and the model credential stay trusted.
- A hosted service or an inbound endpoint. Everything runs on the owner's machines with `git`, `gh`, a container runtime and the
  shell; §6 polls outbound only.
- Several repositories in one budget or one dashboard (#329, v1.4); here each repository has its own.

Reused, not redone: specs 130 (guards, statuses), 373 (`held`, classification, state files, `claude --resume`, the PR
checkpoint), 327 (train, bisection, slots and `slot.env`, `leader`, flaky rule), 325 (briefing), 409 (`workflow`: branch model,
hotfix branches, CI mapping) and ADR 0024 (what comes from outside is data). Tickets already filed: #308 (inbox), #309
(digest), #312 (revert), #322 (hotfix), #324 (demo), #385, #387, #389, #391, #393, #396, #397; #449 is the spec ticket.

New configuration, all optional with a safe default, documented in `docs/guide/configuration.md` by the ticket that adds each
key. Today's behaviour is what an unset key gives, except where a section says otherwise.

| Key | Default | Section |
|---|---|---|
| `sandbox.mode` | `auto` (`required`, `off`) | §2.1 |
| `sandbox.runtime`, `sandbox.image`, `sandbox.credentialFile` | `auto`, built from `.senior-mode/Dockerfile`, `~/.config/senior-mode/credentials.env` | §2.1 |
| `sandbox.memory`, `sandbox.cpus`, `sandbox.pids` | `4g`, `2`, `512` | §2.1 |
| `sandbox.verbs` | `[]` (extra read-only verbs; never a denied one) | §2.2 |
| `sandbox.network`, `sandbox.allow` | `allowlist` (`open`), `[]` | §2.3 |
| `budget.day`, `budget.week`, `budget.ticket` | `{}`, `{}`, `{"usd": 15}`; keys `usd`, `tokens`; `0` or absent is off | §3 |
| `budget.onCap`, `budget.warn` | `drain` (`kill`), `80` | §3.2 |
| `ui.paths` | preset globs, else `[]` | §4.1 |
| `preview.command`, `preview.url`, `preview.baseUrl`, `preview.routes`, `preview.viewports` | none, none, none, `["/"]`, `["390x844","1280x800"]` | §4 |
| `preview.waitSeconds`, `preview.maxKB`, `preview.required`, `preview.public` | `300`, `400`, `auto`, `false` | §4 |
| `journeys.required` | `true` | §5.2 |
| `decision.ttl` | `168h` | §6.1 |
| `notify.batchMinutes`, `notify.digestAt` | `60`, none | §6.1, §7.1 |
| `notify.ntfy.server`, `.topic`, `.replyTopic`, `.secretFile`, `.tokenFile` | `https://ntfy.sh`, none, none, `~/.config/senior-mode/ntfy.secret`, none | §6.3 |
| `notify.telegram.tokenFile`, `.chat`, `.users` | none, none, the chat | §6.4 |
| `dashboard.path`, `dashboard.interval`, `dashboard.publish`, `dashboard.branch`, `dashboard.costs`, `dashboard.redact` | none, `900`, `false`, `gh-pages`, `false`, `auto` | §7.2 |
| `release.summary`, `release.summaryLanguage` | `true`, `en` | §7.3 |
| `autonomy.revert` | `true` | §8.1 |
| `hotfix.slots` | `1` | §8.2 |

Conventions: `serve dir` is `<git common dir>/senior-mode/serve/` (spec 373); a *session* is one `claude -p` from `run_launch`
and has a role (`ticket`, `review`, `integrate`, `frame`, `docs`, `browser`); `held` is the environment hold of spec 373 §1, which
gains the causes `sandbox` and `budget`. Every new state file follows spec 373 §3 (`state_write`, `state_update`, tolerant
readers) and is rebuilt from GitHub or the run files where it can be.

## 2. Sessions in containers

Tickets: #385 (runner), #452 (broker), #454 (egress), #456 (the daemon's own checks), #458 (setup, status, external tickets).
Amends ADR 0015.

Today a session is `claude -p --permission-mode bypassPermissions` in a worktree, as the owner, with `~/.ssh`, the `gh` login,
every other clone and the daemon's own state one `cd ..` away. The guards (ADR 0015) are hooks that read commands as written:
"a guardrail for honest mistakes, not a sandbox". A container is the sandbox. It is not the hooks' replacement; they keep
running inside it.

### 2.1 What a session can see

`sandbox.mode`:

- `auto` (default): a session runs in a container when `sandbox.runtime` (`auto` finds `podman`, then `docker`) exists; with no
  runtime it runs on the host as today, `serve` says so once a day and `status` shows `sandbox: off (no runtime)`.
- `required`: no runtime, no image or no way to start one is the environment hold `sandbox` (spec 373 §1) with the exact cause;
  nothing launches. Reviews and merges of already approved pull requests go on, they need no session.
- `off`: never, and `status` says `sandbox: off (configured)`.

`setup repo` writes `required` when it finds a runtime on a machine that runs `serve`; it never changes a value that is set.

One container per session, `--rm`, named `senior-mode-<repo hash>-<n>-<role>`, labelled `senior-mode.repo=<hash>` and
`senior-mode.ticket=<n>`. Flags: non-root user (the owner's uid mapped), `--cap-drop ALL`, `--security-opt no-new-privileges`,
`--read-only` root file system with a tmpfs on `/tmp` and `$HOME`, `--init`, `--memory`, `--cpus`, `--pids-limit`, network per
§2.3. Never `--privileged`, a device, the runtime socket, the host network or the host PID namespace.

Mounts, and nothing else:

1. the session's checkout, read-write, at the same absolute path (paths in `slot.env`, in logs and in the PR checkpoint stay
   valid);
2. the main clone's object directory, read-only, at its own path (the checkout borrows objects from it through
   `objects/info/alternates`);
3. a per-session directory `<serve dir>/<n>.home` as `$HOME/.claude` (settings, transcript, `claude --resume` state), read-write,
   kept until the ticket ends;
4. the broker socket of the session (§2.2).

Not mounted: `$HOME`, `~/.ssh`, `~/.config/gh`, `~/.config/senior-mode`, the main clone's working tree and `.git`, the serve
dir, every other worktree and every other repository.

The checkout in a container is a private clone (`git clone --shared --no-checkout` of the main clone, then the branch), not a
linked worktree: a linked worktree's `.git` points into the main clone's `.git`, which holds the run token, the other tickets'
logs and the hooks that the host runs. The host never runs `git` inside a session's checkout except `git fetch <checkout>
<branch>` into the trusted clone (upload-pack honours no configuration of the repository it reads), and pushes from the trusted
clone only. `start` makes the clone when a container will run the session; `status` and `clean` find it by its registry entry in
the serve dir, as they find worktrees.

The model credential is the one secret in the container. It comes from `sandbox.credentialFile` (mode 0600, outside every
repository): lines `NAME=value` where `NAME` matches `^(ANTHROPIC_|CLAUDE_CODE_)[A-Z_]*$` (an API key or the long-lived token of
`claude setup-token`), passed with `--env-file`, never on the command line. The host's `~/.claude` login is never copied: a refresh
inside the container could invalidate the host's copy. Without the file and a runtime, the session does not start: hold `sandbox`,
"no model credential for containers: run `claude setup-token`".

Image. `sandbox.image` names one; else `.senior-mode/Dockerfile` is built as `senior-mode/<repo>:<first 12 hex of its sha256>` when
that tag is absent, else the plugin's base (`plugins/senior-mode/sandbox/Dockerfile`: a slim Debian with `bash`, `git`, `jq`, `curl`,
CA certificates, Node LTS, the `claude` CLI at the host's version, and the shims of §2.2) as `senior-mode/base:<plugin version>`.
A failed build is the hold `sandbox` with the last 20 lines. `setup repo` writes a `.senior-mode/Dockerfile` stub (`FROM
senior-mode/base:<plugin version>` plus the preset's toolchain lines, commented) and never overwrites.

Lifecycle. The watchdog and `run_timeout` of spec 373 §4 kill by container name (`<runtime> kill`), then remove it. Startup
reconciliation (spec 373 §2) removes the containers labelled for this repository that have no live session, and the broker
sockets of ended sessions.

Acceptance criteria:

- **[v1.3]** Given a runtime stub that records its arguments, then a launch has exactly the flags above, exactly the four mounts,
  no `--privileged`, no `-v` of `$HOME`, `~/.ssh` or the runtime socket, and the credential only as `--env-file`.
- **[v1.3]** Given a real runtime on the sandbox, a canary file `~/.ssh/canary`, a `gh` login and a second clone, when the session
  runs `cat ~/.ssh/canary; gh auth token; ls ..; git -C ../other log`, then each fails and the canary text appears in no log,
  transcript or pull request.
- **[v1.3]** Given `required` and no runtime, then `held` has cause `sandbox` naming it, nothing launches, a ready pull request
  still merges, and installing the runtime lifts the hold with one `recovered` alert. Given `auto`, the session runs on the host
  and the warning is logged once a day.
- **[v1.3]** Given a session killed by the watchdog, then its container is gone before the ticket is relaunched. Given `kill -9` of
  `serve`, then the next start removes the orphan container and keeps `<n>.home`.
- **[v1.3]** Given an unchanged Dockerfile, then no rebuild; given a changed one, one rebuild and a new tag.
- **[v1.3]** Given the host process listing during a session, then no model credential appears in any command line.

### 2.2 The credential broker

Tickets: #452.

The session has no GitHub credential, yet its prompt (spec 131, `run_prompt`) tells it to `gh issue view`, push, open a pull
request, `publish` and move the ticket. The daemon does these on its behalf. The image has shims named `gh`, `git` (for `push`;
every other `git` command runs the real one) and `senior-mode` (for the verbs below; the rest of the CLI runs in the container). A shim
sends `{argv, cwd}` as one JSON line to the unix socket `<serve dir>/broker/<n>.sock` (mode 0600, one per session, so the
session's identity is the socket, not a claim of the client), and prints what comes back with the exit code.

The decision is one function, `broker_allow <session> <argv...>`, with the allowlist as data like `serve_patterns`. A verb runs
only when it is listed and its target is the session's own:

- `gh issue view|list` (repository read), `gh issue comment` on the session's ticket; `gh pr create` with head the session's
  branch and base the workflow's base branch; `gh pr view|diff|checks|comment|edit` on the session's pull request, and `view|diff`
  on any pull request of the repository for the `review` role; `gh api` with `GET` on `repos/<slug>/{issues,pulls,commits,
  statuses,check-runs,contents}` only. `GH_REPO` is forced, `--repo` and `GH_HOST` overrides are refused.
- `git push` of the session's branch, plain: `git fetch <checkout> <branch>` into the trusted clone, then the push from there.
  No force, no delete, no other ref, no tag.
- `senior-mode publish` (the sha must be the session's branch tip), `item set <own ticket> Status ...`, `issue create` with the
  security flags (risk filing), `red-tests record`, and for the `review` and security roles the verb that sets their own status.
  The rules the hooks enforce today (who may set `senior-mode/review`, spec 130) hold in the broker too.
- Everything else, in particular `gh pr merge`, `gh auth token`, `gh repo`, `gh api` with any method but `GET`, `gh api graphql`,
  `git push --force`, `git push origin :branch`, and any `gh`/`git` target of another repository, exits 126: `denied: <verb> is
  not on the sandbox allowlist`. `sandbox.verbs` can add read-only verbs; it cannot add anything in this paragraph.

The broker execs argument arrays, never a shell string. Output is capped at 1 MiB. Each request is one line in `<serve dir>/
broker.log`: epoch, session, verb, `allow` or `deny`, exit code. Sockets are removed when the session ends and by reconciliation.
What the broker returns from GitHub (an outsider's issue body) is data, as everywhere (ADR 0024).

Acceptance criteria:

- **[v1.3]** Given the `gh` and `git` stubs, then each listed verb for the session's own ticket, branch and pull request runs
  once with `GH_REPO` set, and the stub never sees a token argument.
- **[v1.3]** Given `gh pr merge 5`, `gh auth token`, `gh api -X DELETE repos/o/r/git/refs/heads/main`, `gh api graphql`, `git push
  --force`, `git push origin other-branch`, `git push origin :ticket-branch`, `gh pr create --head other` and `gh issue comment
  <another ticket>`, then each exits 126 and has a `deny` line.
- **[v1.3]** Given the sockets of sessions 12 and 13, then 12's socket cannot comment on 13's pull request or publish 13's sha.
- **[v1.3]** Given a session that ended, then its socket file is gone; given a stale socket after `kill -9`, the next poll removes
  it.
- **[v1.3]** Given the delivery prompt of `run_prompt` replayed against the stubs in a container, then it reaches `delivered` with
  the pull request open and the three statuses set through the broker.

### 2.3 Network

Tickets: #454.

`sandbox.network: allowlist` (default): the container is on an internal network with no route out and `HTTPS_PROXY`,
`HTTP_PROXY` and `GIT_*` proxy variables pointing to a proxy the daemon runs per repository. The proxy lets a `CONNECT` or request
through only to: the model API host, the registries of the repository's presets (`registry.npmjs.org` and the other hosts of
the package managers it detects: `pypi.org`, `files.pythonhosted.org`, `crates.io`, `static.crates.io`, `proxy.golang.org`,
`sum.golang.org`), and `sandbox.allow` (exact host or `*.suffix`). It resolves names itself (the container has no resolver), and
refuses any name that resolves to a loopback, private, link-local (`169.254.0.0/16`, the metadata services) or runtime-bridge
address, allowlisted or not. A refused request is logged once per host and session in `<n>.egress`; `status` counts them.
`open` is the bridge network with no proxy; it is the owner's explicit choice and `status` warns `sandbox network: open`.

The proxy implementation is the ticket's choice (a small allowlist proxy that needs nothing beyond what the base image or the
host already has); the behaviour above is the contract.

Acceptance criteria:

- **[v1.3]** Given the default and a session that runs `curl https://example.org`, then it fails with the proxy's refusal and
  `<n>.egress` names `example.org`; `npm install` from the registry works on a Node project.
- **[v1.3]** Given `sandbox.allow: ["api.stripe.com"]`, then that host passes and `example.org` still does not.
- **[v1.3]** Given an allowlisted name that resolves to `10.0.0.5` or `169.254.169.254`, then the request is refused.
- **[v1.3]** Given `open`, then the session reaches `example.org` and `status` shows the warning.
- **[v1.3]** Given no DNS server reachable from the container, then a lookup of an outside name fails (no DNS exfiltration path).

### 2.4 The daemon's own checks

Tickets: #456.

The daemon runs the project's code on its own: `check` on a train tip (spec 327 §4), on main after a merge (§8.1) and, when a
maintainer asks, on an external pull request's head ("the check runs your code with their GitHub token", CONTRIBUTING). Those
runs go in a container too: the checkout mounted read-only apart from `/tmp` and the declared cache directories, the network of
§2.3, no broker and no GitHub credential. The result is the exit code and the summary, written to a file mounted for it; the
daemon, outside, publishes `senior-mode/ci` on the sha it fetched itself.

Acceptance criteria:

- **[v1.3]** Given a project test that tries `cat ~/.ssh/canary`, `curl https://example.org` and `gh auth token`, then in a train
  tip check each fails, and the check is red if the test asserts on them.
- **[v1.3]** Given an external pull request whose `package.json` has a `postinstall` that writes outside the checkout, then the
  write fails and the host is unchanged.
- **[v1.3]** Given `sandbox.mode: off`, then these checks run on the host as today.

### 2.5 Setup, status and tickets from outside

Tickets: #458.

`status` and `status --json` show `sandbox: <runtime> (rootless|rootful), image <tag>, network <mode>`, the egress refusals and the
broker denials of the last day. A rootful Docker is allowed and flagged. A ticket qualified from outside (ADR 0024: its author is
not a collaborator and a collaborator added `qualified`) never runs outside a container, whatever `sandbox.mode` says, and never
with `sandbox.network: open`: without a runtime it is not launched, it gets `needs-human` once with "needs a sandbox", and the
daemon goes on with the others. `setup repo` writes the Dockerfile stub (§2.1) and records the detected runtime.

Acceptance criteria:

- **[v1.3]** Given `sandbox.mode: off` and a `qualified` ticket from a non-collaborator, then it is not launched and says why;
  given a runtime, it runs in a container on `allowlist` even if `open` is configured.
- **[v1.3]** Given a repository with a Dockerfile stub, then a second `setup repo` changes nothing.
- **[v1.3]** `status --json` carries `sandbox` with mode, runtime, image, network, `egressDenied` and `brokerDenied`.

## 3. Cost caps

Tickets: #460 (ledger), #387 (caps). Uses spec 373's `held`. #299 (retro per ticket) reads the ledger.

The usage window of spec 327 §6 protects the owner's quota; it does not say what a day of the daemon cost. The owner caps the
spend in tokens or in USD, per day, per week and per ticket; past a cap the daemon stops and tells the owner.

### 3.1 The ledger

`<serve dir>/ledger-YYYY-MM`, one JSON line per session, appended once when the session ends:
`{session, ticket, role, model, started, ended, input, output, cacheCreate, cacheRead, usd, source}`. `source` is `result` (the
`usage` and `total_cost_usd` of `<n>-<model>.json`) or `transcript` (summed from the usage records of the session's transcript
when the result file is missing: `kill -9`, timeout, watchdog). `usd` is null when no cost is reported. A session id appears once:
the ledger is rebuilt from the run files by startup reconciliation, so a crash neither loses nor doubles a line.

Definitions. *Tokens* are `input + output + cacheCreate` (cache reads are cheap and dominate the count; USD is the complete
measure). *USD* is what `claude` reports; under a subscription it is the API-equivalent cost (#299), still the best measure of
effort. The ticket's spend is the sum over all its sessions (roles, escalation, resumes, fix rounds) since its first session or the
last time a person took `needs-human` off it. A running session's spend is read from its transcript at every poll.

### 3.2 Caps

`budget.day`, `budget.week` and `budget.ticket` each take `usd` and `tokens`; the first one reached applies. Day is the local calendar
day, week the ISO week from Monday 00:00 local time. Default: `budget.ticket.usd` 15 (a first guess, measured by #299 and the
proof), day and week off.

- Before each launch `serve_can_launch` adds the ledger and the running sessions' transcripts. At or over a day or week cap
  nothing launches, reviewers and integrators included: `held` gets cause `budget` with the cap, the spend and the time it ends,
  one `budget` alert is sent, and the hold lifts by itself when the window rolls (`recovered`). Merges of approved pull requests
  need no session and continue. A hotfix is exempt from day and week caps (§8.2).
- `budget.onCap: drain` (default): running sessions finish, bounded by the ticket cap and the session timeout. `kill`: they are
  killed at the next poll as an interruption (spec 373 §1: transient, ticket back to Ready, session directory kept, nothing counted).
- At `budget.warn` percent (80) of a day or week cap, one `budget` alert says so.
- A running session whose ticket passes `budget.ticket` is killed at the next poll; the ticket gets `needs-human` with a comment
  "ticket budget: $X of $Y over N sessions", it is not escalated to Opus, and it counts toward the breaker as a ticket failure.
- With no cost in the result, USD caps log "no cost signal" once a day and token caps still apply.
- Caps are per repository and per machine (§1; the digest sums machines).
- `status` shows `budget` (spent, cap, percent per window, the hold) and the spend of each in-progress ticket; `retro --json` totals
  equal the ledger.

Acceptance criteria:

- **[v1.3]** Given a result file with usage and `total_cost_usd`, then one ledger line has them; given a killed session with only a
  transcript, then one line with `source: transcript`; after a restart no line is duplicated.
- **[v1.3]** Given the day's ledger at 10.00 USD and `budget.day.usd` 10, then no launch happens, `held.cause` is `budget` with
  the next local midnight, one alert is sent; at midnight the hold lifts with one `recovered`.
- **[v1.3]** Given `drain` and two running sessions at the cap, then they end normally; given `kill`, both are killed, their tickets
  are Ready, and no `needs-human` is set.
- **[v1.3]** Given a ticket with 16 USD over three sessions, `budget.ticket.usd` 15 and a running session, then it is killed within
  a poll, the comment names 16 and 15, and no Opus retry starts.
- **[v1.3]** Given 80 percent of the week cap, then exactly one warning is sent for that week.
- **[v1.3]** Given no cap keys but the default, then a day and a week never hold; the ticket default still applies.
- **[v1.3]** Given a result with no `total_cost_usd` and only a USD cap, then nothing is blocked and "no cost signal" is logged once.

## 4. UI tickets: a preview and before and after screenshots

Tickets: #389 (preview and screenshots), #462 (the reviewer checks the rendering).

### 4.1 What is a UI ticket

A pull request is a UI pull request when its diff touches a glob of `ui.paths`, or its ticket carries the label `ui`. `setup repo`
writes `ui.paths` from the preset (Next.js: `app/**/*.tsx`, `components/**`, `**/*.css`, `public/**`) and from the framework it
detects in an existing project, and never overwrites. `ready` predicts it from the ticket's Paths; the diff decides at
`publish`. A project with no `ui.paths` and no `ui` label has no UI tickets: nothing in §4 applies.

### 4.2 The preview URL

Sources, first that answers: (1) `preview.url`, a template with `{{pr}}`, `{{branch}}`, `{{sha}}`, `{{slug}}`; (2) the
`environment_url` of a successful GitHub deployment status on the head sha, polled every 15 s for `preview.waitSeconds` (a hosted
preview such as Vercel's is the project's own and arrives from GitHub, not from CI, which does not exist here, ADR 0006); (3)
none. A URL is shown only after one `curl -fsS --max-time 10` returns 2xx or 3xx. It goes in the one comment the daemon keeps
on the pull request, found by `<!-- senior-mode:preview -->` and edited in place after each push: `Preview: <url>`, or `No
preview: <reason>` (not deployed within 300 s, nothing configured).

### 4.3 Screenshots

`senior-mode shots <pr>` renders each route of `preview.routes` (the `screens` list of the spec's front matter is added) at each of
`preview.viewports`. After: the preview URL, else `preview.command` run in the session's slot (spec 327 §7, `{{port}}`), in a
container. Before: `preview.baseUrl` (production or staging), else `preview.command` on the merge base in a second slot. The tool is
Playwright (the project's, else the image's) driven by the `browser` agent, a Bash-and-Read agent of the plugin that runs
`shots`, reads its failures and retries once; a screen that needs state (a login, a click) is covered by a journey (§5), whose
Playwright run saves its screenshots into `SENIOR_MODE_SHOTS_DIR`. Besides the PNGs, `shots.json` records per route and viewport
the page errors, `console.error` count and requests with status 400 or more.

Storage. Images of at most `preview.maxKB` (scaled down until they fit) go to the orphan branch `senior-mode/shots`, under
`pr-<n>/<route>-<viewport>-{before,after}.png`, pushed by the daemon, and the preview comment shows a before and after table with
`.../blob/<sha>/pr-<n>/...?raw=true` links. `clean` removes `pr-<n>` seven days after the pull request closes. In a public
repository nothing is pushed unless `preview.public` is true (the previewed app is public): the comment says "screenshots not
published" and the reviewer reads the local files.

### 4.4 The reviewer checks the rendering

For a UI pull request the reviewer opens each before and after pair (an image is readable by the model) and `shots.json`, and its
review has a **Rendering** section: one line per route and viewport, `ok` or a finding. Blocking: an empty or error page, content
overflowing the viewport, overlapping text, an element a criterion names that is missing, a new page error or `console.error`, a
new request with status 400 or more (compared with before). `preview.required` `auto` means true when `preview.command` or
`preview.url` is set: then a UI pull request with no screenshots cannot get `senior-mode/review` success, and the status says
"rendering not verified: <reason>". With nothing configured the section says "not configured" and does not block.

Acceptance criteria:

- **[v1.3]** Given a diff touching `components/Button.tsx` and `ui.paths` with `components/**`, then the pull request is UI; given a
  diff in `src/server.ts` only, then it is not; given the label `ui`, then it is.
- **[v1.3]** Given `preview.url` `https://{{branch}}.example.test` and a stub answering 200, then the comment says `Preview: ...`;
  given a deployment status with `environment_url`, the same; given neither within `preview.waitSeconds`, `No preview: not
  deployed within 300 s`. A second push edits the comment, never adds one.
- **[v1.3]** Given a stub capturer (`SENIOR_MODE_SHOTS_CMD`) that writes two routes and two viewports, then the branch holds eight
  files under `pr-<n>`, none over `preview.maxKB`, and the comment table has four rows.
- **[v1.3]** Given a public repository and `preview.public` false, then nothing is pushed and the comment says so.
- **[v1.3]** Given `preview.command` set and no screenshots, then the review status is not success and says "rendering not
  verified"; given nothing configured, the review is not blocked. Given an after image of a blank page, then the reviewer reports a
  blocking finding.
- **[v1.3]** Given a `shots.json` with a new `console.error`, then the Rendering section lists it as blocking.
- **[v1.3]** Given a closed pull request older than seven days, then `clean` removes its `pr-<n>` directory.

## 5. End-to-end tests for the user journeys

Tickets: #391 (declaration, `check`), #464 (the test-author writes them).

### 5.1 A journey is declared

A spec names its journeys in its front matter, next to `paths`:

```yaml
journeys:
  - { id: J1, name: "A buyer pays an invoice", test: "e2e/pay-invoice.spec.ts" }
```

The spec's body describes each one (its id appears in the body, in "Users and journeys"). `id` is unique in the spec, `test` is a
relative path with no `..`. Only specs with `status: accepted` count. A spec without `journeys` is untouched; a legacy project
with no specs has no journeys, and `setup repo` still records an `e2e` command when it finds a Playwright or Cypress
configuration.

### 5.2 `check` runs the journeys of the touched Paths

A new `check` step `journeys` runs before the `e2e` check:

1. A journey is *selected* when a file of `git diff --name-only <base>...HEAD` matches a glob of its spec's `paths`, or its test file
   is in the diff; `check --all` selects every journey. A pull request that only adds or edits a spec (docs only) selects nothing
   unless it touches the spec's `paths`.
2. A selected journey's test file must exist and carry the id in a test title (`J1`); otherwise the check fails with
   `journey J1 of spec 328 has no test at e2e/pay-invoice.spec.ts`. With `journeys.required: false` this is a warning.
3. The selected test files run through `e2e.command`, `{{files}}` replaced by the files (without the placeholder, the whole suite
   runs once if any journey is selected), under the `e2e` lock and a slot environment (spec 327 §7), in a container as §2.4 says.
   A journey test that fails fails the check. A file that fails is run once more; a pass on the second run is reported
   `flaky` in the summary and counted for `status`, and the check passes (spec 327's flaky rule: one rebuild).
4. Journeys declared and no `e2e.command`: the check fails with "journeys declared and no e2e command: senior-mode setup repo
   --command e2e=...".

Kept up to date: `status` hygiene lists a journey whose test file is missing on the base branch, a journey whose spec `paths`
match no file, and test titles with a journey id that no spec declares (orphans, a warning). `retro` shows journeys and tests.

### 5.3 The test-author writes them

For a ticket whose spec has selected journeys (by the ticket's Paths), the test-author agent writes or updates the journey's E2E test
first, from the journey text in the spec and not from the code, records the red run (spec 130) and commits it; the implementer
then makes it pass. A journey that already has a test is edited only when the ticket's criteria change the journey.

Acceptance criteria:

- **[v1.3]** Given a spec with `journeys` and a diff in its `paths`, then `check` runs exactly that spec's test files and no others;
  given a diff elsewhere, the `journeys` step says `skip: no journey on the touched paths`.
- **[v1.3]** Given a selected journey whose file is missing, or exists without the id in a title, then `check` fails naming the
  journey, spec and path; given the file added, it passes.
- **[v1.3]** Given a docs-only pull request that adds a spec with journeys whose tests do not exist yet, then `check` passes.
- **[v1.3]** Given a test that fails once and passes on rerun, then `check` passes and the summary has `flaky: J1`; given one that
  fails twice, `check` fails.
- **[v1.3]** Given `check --all`, then every declared journey runs. Given `journeys.required: false`, a missing test is a warning.
- **[v1.3]** Given a ticket on a spec's Paths with a declared journey and no test, then the red tests recorded for it include the E2E
  test and the implementer's prompt says the test is read-only (spec 131).

## 6. Steering from a phone

Tickets: #308 (inbox), #466 (`/decide`), #393 (ntfy), #467 (Telegram). Builds on spec 327 §9 (drafts) and #363.

### 6.1 Decisions

A *decision* is something waiting for the owner: an issue with `needs-human`, a pull request that cannot merge on its own (external,
protected zone), a ticket in framing, a `framing-draft` pull request. `status` has one **Decisions** section, `--json` a `decisions`
array `{number, kind, age, question, options, recommended, id}`; the list is sorted by Priority then age (#308).

A *question with options* is a decision the daemon or an agent can word: the comment that raises it (`notify` takes `--option
key=label` and `--recommended key`) ends with a marker the daemon reads:

```
<!-- senior-mode:decision {"id":"d12-1","options":[{"key":"a","label":"Keep SQLite","recommended":true},{"key":"b","label":"Move to Postgres"}]} -->
```

`id` is `d<ticket>-<sequence>`, the options are at most 5, one marked recommended. Without a marker the question is the first line
of the reason and the item has no options (it is answered on GitHub). A decision with options expires after `decision.ttl`: the
daemon comments "decision expired", the ticket stays `needs-human`.

Notifications. New decisions raised within `notify.batchMinutes` (60) go out as one notification; `budget`, red main, `revert` and
`hotfix` events go out at once. A notification carries plain text only, control characters stripped and 300 characters at most (an
outsider's title can be in it).

### 6.2 One answer path

Every answer, from any transport, ends as the same act. A comment `/decide <id> <key>` by an author whose `author_association` is
OWNER, MEMBER or COLLABORATOR, on the issue or pull request that holds the open decision, is read by the daemon at each poll. It checks
that the id is open and the key is one of its options, then comments `<!-- senior-mode:answer {"id","key","by","via"} -->` "Decision
d12-1: Keep SQLite (by @owner)", removes `needs-human`, and applies the effect: the ticket goes back to Ready, and the next
session's briefing (spec 325) starts with the decision; a session that was interrupted resumes (`claude --resume`, else the PR
checkpoint) with "The owner decided: ...". A second answer to an answered id, an unknown id or key, an expired decision, and a
comment by anyone else are ignored without a reply and counted in `status` (ADR 0024: an outsider's text is never an order). The
daemon's own answer comment for ntfy and Telegram (§6.3, §6.4) is the record: GitHub holds the truth, the transports hold nothing.

### 6.3 ntfy, one tap

`notify.ntfy` (`server`, `topic` for the questions, `replyTopic` for the answers; both topics random 24 characters, written by
`setup`; `secretFile`, 32 random bytes, mode 0600 outside the repository). A decision with options is sent with up to three `http`
actions (ntfy's limit; with more than three options the third is a link "Open on GitHub"), recommended first. Each action POSTs
`<id>|<key>|<mac>` to `<server>/<replyTopic>`, where `mac` is the first 32 hex characters of HMAC-SHA256 of `<id>|<key>` under the
secret. The daemon streams `<server>/<replyTopic>/json?since=<last>` (outbound only: no open port, no tunnel), reconnecting with the
backoff of spec 373 (transient). A message whose MAC does not verify (constant-time compare), or whose id is not open, is dropped
and counted. A valid one runs §6.2 with `via: ntfy`. `tokenFile` is the bearer token of a protected ntfy server.

### 6.4 Telegram

`notify.telegram` (`tokenFile` of the bot, `chat`, `users`). The bot sends the question with an inline keyboard, one button per
option (`callback_data` `<id>:<key>`, under 64 bytes); the daemon long-polls `getUpdates` (outbound only). It accepts a callback
only when `chat.id` is the configured chat and `from.id` is in `users` (default: the chat's id); it then runs §6.2 with `via:
telegram`, confirms with `answerCallbackQuery` and edits the message to show the choice.

### 6.5 What the phone cannot do

Buttons answer questions with options. They never merge, approve a pull request, set a status, lift a hold or change a label other
than `needs-human` on the decision they answer. A pull request waiting for the owner (a draft, a protected zone, an external pull
request) gets one "Open" link button to GitHub, where the merge stays a human act (ADR 0018, 0024). A transport that is down
changes nothing: the question is still in `status` and on GitHub, and `/decide` still works. `status` shows `ntfy: unreachable
since <time>` and the rejected-message count.

Acceptance criteria:

- **[v1.3]** (#308) Given a `needs-human` ticket, a blocked external pull request and a ticket in framing, then `status` has one
  Decisions section with each item's age and question, and `--json` carries the same. Given five questions raised in 20 minutes,
  one notification goes out; given a `budget` alert, it goes out at once.
- **[v1.3]** (#466) Given an open decision `d12-1` and `/decide d12-1 a` by a collaborator, then at the next poll an answer comment
  exists, `needs-human` is gone, the ticket is Ready and its briefing starts with the decision. Given the same comment by a
  non-collaborator, an unknown key, an expired id or a second answer, then nothing changes.
- **[v1.3]** (#393) Given a decision with two options and a stub ntfy server, then the notification has two `http` actions whose
  bodies carry a valid MAC; given the recommended action's POST on the reply topic, then the decision is answered once with `via:
  ntfy`. Given the same POST replayed, a wrong MAC, an expired decision, or an answer for an id that is not open, then nothing
  changes and `status` counts one rejection each.
- **[v1.3]** (#393) Given a decision with four options, then the notification has two option buttons, the third option and "Open on
  GitHub" are merged into one link, and the answer on GitHub still works for the others. Given the server unreachable for ten
  minutes, then no decision is lost and the stream reconnects with backoff.
- **[v1.3]** (#467) Given a callback from the configured chat and user, then the decision is answered with `via: telegram`; given
  another chat or user, nothing changes.
- **[v1.3]** Given a notification for a decision whose title contains markup or control characters, then the text sent is plain,
  stripped and at most 300 characters. Given any button, then no merge, approval or status is ever set from the phone.

## 7. Seeing what the daemon did

Tickets: #309 (digest), #396 (dashboard), #397 (release summary).

### 7.1 The digest

`notify.digestAt` (`"08:00"`, local time): once per local day, from that time, `serve` (on the `leader`, spec 327 §8) sends the
digest through the webhook (event `digest`), ntfy and Telegram, and, as today, posts it as a Project status update when
`notify.digest` is true. Content: pull requests merged (count, up to 10 titles), tickets needing a human with the oldest age,
open decisions, the day's spend against its caps (§3), holds, breaker trips, reverts and hotfixes, the drift count, and a release
made that day. Nothing is sent when nothing happened (no merge, session, decision or incident). The Project status update carries
`<!-- senior-mode:digest YYYY-MM-DD -->`, so a lost state file does not send a second one.

### 7.2 `status --html`

`senior-mode status --html [--out <file>]` writes one self-contained page (`status.html` by default) from the same snapshot as
`status --json`, the ledger and the `blocked-by` graph. Sections: **Health** (hold cause, breaker, heartbeat age, version,
sandbox, workers), **Queue** (runnable tickets in `pick` order with the reason a ticket waits), **Live sessions** (ticket, role,
model, running time, spend), **Costs** (day, week and per ticket against the caps, 14 days as an inline SVG), **Decisions**,
**Graph** (the open tickets of the current milestone as a layered `blocked-by` DAG in inline SVG, coloured by Status) and
**Recent** (merged in 7 days).

The page has no script and no external request, a `<meta http-equiv="Content-Security-Policy" content="default-src 'none';
style-src 'unsafe-inline'; img-src data:">`, a viewport meta tag for the phone, a light and dark colour scheme and "generated at"
with the age of the data. Every dynamic string is HTML-escaped (`& < > " '`): titles and labels come from outsiders (ADR 0024).
The same snapshot gives the same bytes. 500 tickets stay under 1 MB.

`dashboard.path` makes `serve` regenerate the page every `dashboard.interval` seconds, written atomically. `dashboard.publish: true`
also pushes it to `dashboard.branch` as `index.html`, from the trusted clone; GitHub Pages is the owner's to enable. When the page
is published or the repository is public (`dashboard.redact` `auto`), it is redacted: no USD amount unless `dashboard.costs`, a
`security`-labelled issue as "security item #n" with no title, no host name, path or log excerpt, no `held` detail beyond the cause.

### 7.3 The release summary

When `release` publishes a version (or `release --summary [<tag>]` on a tag made by hand), a `docs` session with Read and Write on two
files only (no Bash, no network) turns the range's work into a summary for someone who does not code, in
`release.summaryLanguage`: from the closed tickets of the range (title, goal, type), the user-visible ones (`feat`, `fix`, `perf`,
breaking). At most 250 words, sections "What's new", "What's fixed", "What you need to do" (only when something breaking or a
migration exists), each bullet ending with `(#n)`. A deterministic check follows: every `feat` and `fix` ticket of the range is
cited at least once, every cited number is in the range, no backtick, no conventional-commit prefix, within the limit. One retry
with the list of faults; then the fallback, a plain list of the titles marked "(automatic list)", so a release is never
without one. A range with no `feat`, `fix` or `perf` gets "Maintenance release" and no session. The text is put at the top of the
GitHub release body under `## Summary` with `<!-- senior-mode:summary -->` (replaced, not repeated, on a rerun); the technical
changelog stays below, untouched. Titles in the prompt are data (ADR 0024). The next digest includes it.

Acceptance criteria:

- **[v1.3]** (#309) Given `notify.digestAt` "08:00" and activity, then one digest at or after 08:00 on each channel, once a day, also
  after a restart that lost the state file; given a quiet day, nothing; given two workers, one digest.
- **[v1.3]** (#396) Given a snapshot with an issue titled `<script>alert(1)</script>` and another titled `a "b" & 'c'`, then the page
  contains them escaped and no `<script`; it has no `http://` or `https://` resource reference, the CSP tag and the viewport tag.
- **[v1.3]** (#396) Given the same snapshot twice, then the same bytes. Given a held daemon, a running session, a spend and a three-
  node `blocked-by` chain, then Health, Live sessions, Costs and Graph show them (three nodes, two edges in the SVG).
- **[v1.3]** (#396) Given `dashboard.publish: true` on a public repository, then the pushed page has no USD, no host name or path and
  shows the security issue without a title; given `dashboard.path` and a kill during the write, the previous file is intact.
- **[v1.3]** (#397) Given a range with two `feat`, one `fix` and one `chore` ticket and a stub session that writes a faithful text,
  then the release body starts with the summary and keeps the changelog; given a text that omits one `fix`, one retry; given two
  bad texts, the fallback list. A rerun leaves one summary.
- **[v1.3]** (#397) Given a range with only `chore` and `docs`, then "Maintenance release" and no session. Given
  `release.summaryLanguage: "fr"`, then the prompt asks for French and the check is unchanged.

## 8. Reverting, hotfixing and demonstrating

Tickets: #312 (revert), #322 (hotfix), #324 (demo).

### 8.1 A merge that turns main red is reverted

`autonomy.revert` (true). After each merge `serve` makes sure the new head of the branch it merged into (the base, or the
`workflow` integration branch of spec 409) has a passing `check`: it runs it, in a container (§2.4), unless a check already
passed on the same tree (the train's carried status, spec 327 §4). When it fails:

1. Classify (spec 373 §1). Environment: the `held` of spec 373, no revert. Transient: retry. Ticket-class: run it once more; a pass is
   flaky and nothing else happens.
2. Find the culprit among the merges since the last head with `senior-mode/ci` success: one merge, it; several, the bisection of spec
   327 §4 over them, at most `revert.maxProbes` (4) checks, else `needs-human` on a "main is red" issue listing the range.
3. The merge passed on its parent (a status or one more check on the parent). If not, the red predates it: no revert.
4. Open `revert/<n>`: `git revert --no-edit` of each commit of the merged pull request in reverse order, title `revert: <subject>
   (#n)`, body `Reverts #n.`, `Refs #<ticket>`, the failing check's name and the last 40 lines of its output (secret-scanned). It
   goes through every gate as any pull request, by a reviewer session, and the daemon merges it like any other; it is exempt from
   the red-main merge pause (a fix has to land), as is a hotfix.
5. The ticket is reopened with `needs-human`, Status Backlog, and the failing output in a comment; one `revert` alert is sent.
6. After the revert merges, main is checked again: green, the hold lifts (`recovered`); still red, the culprit was not that merge: no
   further revert for this red episode, one issue "main is red", `needs-human`.

At most one revert is in flight; a revert that fails its own check or conflicts is not retried.

Acceptance criteria:

- **[v1.3]** Given a merge whose head fails `check` while its parent passed, then a `revert/<n>` pull request exists with the title,
  body and output above, the ticket is reopened with `needs-human`, and new merges (but the revert) pause until main is green.
- **[v1.3]** Given a failing check that passes on the second run, then no revert. Given a failure classified as environment (disk
  full), then `held` and no revert.
- **[v1.3]** Given three merges since the last green head and the second one at fault, then the bisection names it within 4 checks
  and only it is reverted.
- **[v1.3]** Given a revert whose own check fails, or main still red after it, then there is no second revert, one issue and one
  `needs-human`. Given `autonomy.revert: false`, only the issue and the pause.
- **[v1.3]** Given `kill -9` of `serve` after the revert pull request opened, then the next poll finds it and does not open a second.

### 8.2 The hotfix lane

`senior-mode hotfix <issue>`, for a collaborator's ticket (the trust gate of ADR 0024 applies): it sets the label `hotfix`, Priority
P0 and Status Ready, and checks the ticket is a `fix`. The daemon then:

- starts it at once in a reserved slot beyond `autonomy.parallel` (`hotfix.slots`, default 1), ignoring the quota bands (spec 327
  §6) and the day and week caps (§3), but not the ticket cap and not memory;
- branches from and targets the branch the workflow gives for hotfixes (`workflow.release.hotfix`, else the base);
- holds the change to the S diff budget (50 lines, tests included): `ready` and `publish` refuse a larger diff, `needs-human` says
  to split or to lift the label;
- requires the review whatever `process.profile` says, and the security pass when a protected zone is touched;
- merges it alone, first, as a train of one, with the three statuses as ever;
- after the merge runs `release` once so that a patch release follows (the commit is `fix:`), the release pull request going
  through the same gates;
- has the docs session open `docs/incidents/YYYY-MM-DD-<slug>.md` in a pull request: what happened (from the issue), impact, cause,
  the fix (#pr), the timeline (reported, started, pull request opened, merged, released) and follow-up tickets.

A `hotfix` alert is sent at once. A hotfix is allowed while main is red.

Acceptance criteria:

- **[v1.3]** Given `parallel` 2 and two sessions running, then a hotfix starts in the extra slot within one poll; given the
  usage band 0.9 and a day cap reached, it still starts; given the ticket cap, it is stopped.
- **[v1.3]** Given a hotfix diff of 51 lines, then `publish` refuses it and `needs-human` says so; given 50, it passes.
- **[v1.3]** Given `process.profile: fast`, then the hotfix still has a `review` session and cannot merge without
  `senior-mode/review`.
- **[v1.3]** Given a merged hotfix, then `release` runs once, a patch release pull request exists, and an incident pull request has
  the sections and a timeline in order. Given a non-`fix` ticket, `hotfix` refuses with the reason.
- **[v1.3]** Given a project with `workflow.release.hotfix` `hotfix/*` and a `main`, then the branch is `hotfix/<issue>-<slug>` and
  the pull request targets what the workflow says.

### 8.3 `senior-mode demo`

`senior-mode demo` shows the whole flow on a throwaway repository in about five minutes. It prints what it will create and asks
`[y/N]` (`--yes` skips; unattended without `--yes` it refuses). It creates a private repository `<owner>/senior-mode-demo-<6 hex>`
with the description `senior-mode demo (throwaway)`, seeds a tiny shell project with its test script and three toy tickets (an S
feature, an S feature, an S bug with a failing test), runs `setup github` and `setup repo` on it, then `serve` with `parallel 3`,
merge on, and a budget of `--budget` USD (default 3) as the day cap. It narrates each step with its time (`[3/7] ticket #2 delivered, 41 s`),
and ends with the links. Progress is recorded in `~/.local/share/senior-mode/demo.json`, so an interrupted demo resumes.
`demo --clean` lists the repositories recorded there, checks each one's description marker through the API, asks, and deletes
those and only those with `gh repo delete` (it names the `delete_repo` scope to add when it is missing); it never deletes a repository
that `demo` did not record. The demo uses the container sandbox when a runtime exists.

Acceptance criteria:

- **[v1.3]** Given `gh` and `claude` stubs, then `demo --yes` creates the repository, three issues and reaches three merged pull
  requests with the narration lines in order; `demo` with no terminal and no `--yes` creates nothing.
- **[v1.3]** Given an interrupted demo, then a second run resumes without a second repository.
- **[v1.3]** Given `demo --clean` with one recorded repository and one other repository whose name starts with `senior-mode-demo-`,
  then only the recorded one, with the marker, is deleted. Given the marker missing, nothing is deleted and it says why.
- **[v1.3]** On the sandbox, the whole demo ends within 6 minutes and costs under its budget.

## 9. What comes from outside

ADR 0024 makes external text data and external pull requests human-merged. This spec adds the surfaces, and each is covered above:

- Containers for a ticket qualified from outside, mandatory and never on an open network (§2.5); the daemon's checks of an external
  pull request in a container (§2.4).
- A ticket cap, so a qualified ticket cannot spend without limit (§3.2).
- Answers are accepted from collaborators only, or from a MAC-checked button or an allowlisted chat; any other text, `/decide`
  included, is ignored (§6.2).
- Notification, dashboard and release-summary text are plain or escaped, with an outsider's title as data (§6.1, §7.2, §7.3).
- Screenshots of a UI from an external pull request are produced by the container flow and the reviewer reads them; none is
  published from a public repository's private app (§4.3).

## 10. The proof

Tickets: #468. Each of §2 to §8 is first exercised on `Sycatle/senior-mode-sandbox` with its faults injected on purpose (ADR 0011).

- §2: a canary secret, a session prompted by a ticket body to read `~/.ssh`, to `curl` an outside host, to `gh pr merge` and to
  `git push --force`: none succeeds, the broker log shows each denial. A session killed with `kill -9`: no orphan container.
- §3: caps set low are crossed by day, week and ticket: the hold, the alert, the recovery and the killed session.
- §4 and §5: a UI ticket on a sample app with a preview and screenshots; a deliberately broken layout blocked by the reviewer; a
  journey with a flaky test.
- §6: the owner answers one real decision with one tap on a phone (ntfy), and one with Telegram; a forged answer is rejected.
- §7 and §8: a dashboard with a `<script>` title; a release summary with one deliberately faulty first text; a merge that turns
  main red and is reverted; a hotfix with its incident note; `demo` then `demo --clean`.

Acceptance criteria:

- **[v1.3]** Each of §2 to §8 has a recorded sandbox session in the pull request that merged it. The proof's observations are
  copied to #468, and #328 closes when its sub-issues and #468 are closed.

## Delivery

| Version | Content | Tickets |
|---|---|---|
| v1.3 | All sections | #449 spec and ADR 0025; §2 #385, #452, #454, #456, #458; §3 #460, #387; §4 #389, #462; §5 #391, #464; §6 #308, #466, #393, #467; §7 #309, #396, #397; §8 #312, #322, #324; §10 #468 |

Order. #460 (the ledger) and #308 (the inbox) first, they have no blocker. #385 before #452, #454, #456 and #458. #387 after #460;
#466 after #308, then #393 and #467. #389 before #462, #391 before #464. #312 needs #456 for its container and spec 373's `held`;
#322 needs spec 327's slots and #387's exemption; #396 needs #460; #324 uses #387 and, when present, the sandbox. #468 last.
The sizes of #385, #387 and #397 were raised to M by this spec, which gives each its scope.

## Out of scope

Several repositories in one budget, slot pool or dashboard (#329); an agent identity (#175), which would make the broker's
GitHub calls a separate account; sessions in virtual machines or on remote hosts; a hosted inbox or any inbound endpoint; answering
by e-mail or SMS; approving or merging from the phone; image diffing and visual-regression baselines (the reviewer reads the pair);
a price table for models (USD is what `claude` reports); a spend cap across machines (the digest sums them).

## Test seams

`serve_can_launch`, `serve_classify`, the launch script of `run_launch`, the ledger and `budget_*` functions, `broker_allow`,
`decisions`, the ntfy and Telegram pollers, `check` and `setup repo`, `release` and the summary verifier, `status --html`
(`bin/lib/*.sh`), through `bin/tests/test-*.sh` with the `gh`, `claude`, `git`, `curl`, runtime (`SENIOR_MODE_RUNTIME`), capturer
(`SENIOR_MODE_SHOTS_CMD`), ntfy and Telegram stubs, `SENIOR_MODE_SERVE_ONCE=1` and `SENIOR_MODE_NOW`. Real containers, real
network refusal, GitHub's deployment statuses, a phone and the model's reading of an image run on the sandbox (ADR 0011).

## Open questions

- The base image's size and where it is built (locally on first use is assumed, no registry); recommended: measure on the
  proof and publish an image only if the build exceeds two minutes.
- Whether a subscription token from `claude setup-token` is enough for an unattended `claude -p` in a container; recommended:
  the proof decides, an API key being the fallback and the cost cap (§3) bounding it either way.
- Rootless Docker without `--userns` remapping may not map the owner's uid cleanly on every host; recommended: document Podman
  rootless as the reference and test Docker rootless on the proof.
- The private clone's cost on a very large repository (alternates make it cheap on objects, not on the working tree); recommended:
  keep the clone, revisit a linked worktree with a synthetic git directory only if the proof shows it.
- A preview behind a protection bypass header (Vercel and others); recommended: `preview.headers` naming an environment variable,
  added when the first project needs it.
- The ticket default of 15 USD, the 80 percent warning, the 50-line hotfix budget and the 7-day expiry of decisions are first
  guesses, measured by #299 and the proof.
