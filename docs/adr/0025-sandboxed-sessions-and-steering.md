---
id: 0025
title: Sessions run in containers behind a credential broker, the daemon keeps a budget, and the owner steers from a phone
status: accepted
spec: 328
amends: 0015, 0017
---

## Context

ADR 0015 bounds an agent with hooks that read commands as written, and says so: "a guardrail for honest mistakes, not a sandbox".
A session runs as the owner, with `~/.ssh`, the `gh` login, every other clone and the daemon's own state within reach, and ADR
0024 opens the project to text from strangers that such a session reads. ADR 0017 lets the daemon start sessions for as long as
there are Ready tickets, with a cap on starts per hour and nothing on money. UI changes merge without anyone seeing the page, a
user journey in a spec has no test that keeps it true, and the owner learns what waits for them by opening the board. Spec 328
turns the owner's decisions of 2026-11-23 into behaviour; this ADR records the choices that change 0015 and 0017 and the ones the
owner left open.

## Decision (owner, 2026-11-23; marked *open* where the choice was left to this record)

Amending 0015 (what a session can reach):

- **One container per session, with only its checkout.** No `~/.ssh`, no `gh` login, no other repository, no daemon state: four
  mounts (the checkout, the main clone's objects read-only, a per-session `~/.claude`, the broker socket). The hooks keep running
  inside as a second layer. Dropped capabilities, no new privileges, read-only root, memory, CPU and process limits, never the
  runtime socket or `--privileged`.
- **A session has no GitHub credential; a broker acts for it.** A shim in the image sends `gh`, `git push` and a few `senior-mode`
  verbs to a per-session unix socket; the daemon runs a verb only when it is on an allowlist and its target is the session's own
  ticket, branch and pull request. Anything else exits 126 and is logged. (*open*, decided here)
- **The checkout is a private clone, not a linked worktree.** A worktree's `.git` leads into the main clone's, which holds the run
  token, the other tickets' logs and the hooks the host runs. The host takes the branch with `git fetch <checkout> <branch>` and
  pushes from its own clone; it runs nothing else in a directory a session wrote. (*open*, decided here)
- **The network is an allowlist.** Egress goes through a proxy that passes the model API, the preset's registries and
  `sandbox.allow`, resolves names itself and refuses private, loopback and link-local addresses. `open` is the owner's explicit
  choice and shows in `status`. (*open*)
- **`sandbox.mode` is `auto` by default**: a container when a runtime exists, the host otherwise, with a warning; `required` makes
  a missing runtime an environment hold; `off` is explicit. A ticket qualified from outside (ADR 0024) always needs a container, on
  the allowlist. Upgrading never stops a daemon that worked. (*open*)
- **The model credential is a long-lived token or key from a file**, passed by `--env-file`; the host's login is never copied.
- The daemon's own runs of the project's code (a train tip, main after a merge, an external pull request's head) are contained too.

Amending 0017 (the loop):

- **A budget stops the daemon, in tokens or USD, per day, week and ticket.** A ledger of sessions, rebuilt from the run files after
  a crash, feeds the caps. Past a day or week cap nothing launches until the window rolls (hold `budget`, alert, automatic
  recovery); past the ticket cap the session is killed and the ticket goes to a human. A running session is bounded by `drain`
  (default) or `kill`. Tokens are `input + output + cache creation`; USD is what `claude` reports. Caps are per repository and per
  machine. A ticket cap of 15 USD is the only default. (*open*)
- **A merge that turns main red is reverted by a pull request** that goes through every gate; at most one revert per red episode;
  an environment failure or a flaky one never reverts. A hotfix takes an extra slot, ignores the quota bands and the day and week
  caps, and nothing else: size, review, security and statuses stay.

Not an amendment (nothing in 0017, 0018 or 0024 changes):

- **UI pull requests carry a preview URL and before and after screenshots**, kept on an orphan branch and linked in one comment; the
  reviewer judges the rendering and a project that configured a preview cannot get `review` without it. A project that did
  not configure one is not blocked. In a public repository nothing is published without `preview.public`. (*open*)
- **Journeys are declared in a spec's front matter**; `check` runs the ones whose spec Paths the diff touches, and fails when one has
  no test; the test-author writes it first. (*open*)
- **Decisions are answered by one path**: a collaborator's `/decide <id> <key>` comment, or the daemon writing the same record on a
  button press. ntfy buttons carry an HMAC; Telegram checks the chat and user; both poll outbound, nothing listens. The phone never
  merges, approves, sets a status or lifts a hold. (*open*)
- **The dashboard is one static page**: escaped, no script, a content security policy, redacted when published or public, published
  only when the owner says so. The release summary is written by a session with no shell, verified against the range's tickets,
  falls back to a plain list, and goes at the top of the GitHub release. `demo` creates and deletes only repositories it recorded.
  (*open*)

## Alternatives considered

- **Keep the hooks and add more of them:** the hooks read commands as written; `bash -c`, `python -c` and a `curl` to anywhere defeat
  them, and they stay in reach of `~/.ssh`. A boundary the kernel enforces is the only one that holds.
- **Mount the whole repository and the git directory:** the simplest container, and it hands the session the run token, the logs of
  every ticket and the hooks the host will run. A private clone costs a clone and keeps the host out of untrusted directories.
- **Give the container a fine-grained GitHub token:** no broker to write, but a token in a prompt-injectable session, and GitHub
  scopes (a repository, pull requests, contents) are wider than "this branch and this ticket". The broker narrows to the ticket.
- **A GitHub Actions or hosted runner for sessions:** isolated, but the project has no Actions budget (ADR 0006) and the sessions
  need the owner's machine, slots and subscription.
- **Open network with a deny list:** a deny list is always one host short. An allowlist fails closed, and `open` stays one key away.
- **Hard cap that kills everything at once:** safe for the bill, wasteful for the work: a half-finished session is paid and thrown
  away. `drain` is the default; `kill` is a key.
- **Cap by the usage window only (spec 327 §6):** it protects the quota, not the money, and not a single runaway ticket.
- **Only a token cap, or only USD:** tokens exclude price and cache effects, USD is absent under some logins; both are accepted
  and the first reached applies.
- **Screenshots in the pull request body or as comments:** GitHub has no upload API for them. A branch of images costs one orphan
  branch and a cleanup, and works on private repositories for people who can see them.
- **Visual-regression baselines:** a baseline to maintain and approve per route; the model reading a before and after pair costs
  nothing to keep up and says what is wrong in words.
- **E2E tests for every route rather than every named journey:** the spec says what matters; the rest is the project's own suite.
- **An inbound webhook for phone answers:** needs a public address and authentication on the owner's machine. Outbound polling of ntfy
  and Telegram needs nothing open and survives a restart by the `since` cursor and GitHub's record.
- **Approve and merge from the phone:** the fastest steering, and a stolen phone or a leaked topic would merge to main. Questions with
  options can be wrong without damage; a merge cannot.
- **A hosted dashboard:** a service to run for a page that a file explains. A static page can be published when the owner wants.
- **A model-written release summary without a check:** it would invent. The check ties each line to a ticket of the range.
- **Revert by hand, always:** main stays red until the owner looks. A revert is a pull request that passes the same gates and can
  be reverted itself.

## Consequences

- `serve` gains the hold causes `sandbox` and `budget`, the alert events `budget`, `revert`, `hotfix`, `digest` and `decision`, a
  ledger, a broker and its log, an egress proxy, a decision poller and per-session directories. Each file follows ADR 0021's write and
  reconcile rules.
- A runtime (Podman or Docker) becomes a dependency of the daemon on machines that want the boundary. Without one nothing breaks,
  and `status` says the daemon is unsandboxed.
- The broker allowlist, the proxy's host list and the preset registries are data that grow with the verbs and package managers
  projects use; each gets a fixture when a message or a host changes.
- The model credential of a container is a long-lived token or key, the one secret inside; the allowlisted hosts are the remaining
  exfiltration route, which is why the list is short and the denials are counted.
- A UI ticket with a configured preview now takes longer (a deployment, two renderings, a review of images) and costs more; the ticket
  cap bounds it.
- The `browser` agent, `senior-mode shots`, `hotfix`, `demo` and `status --html` are new surfaces for the audit of #318.
- The numbers (15 USD, 80 percent, 50 lines, 7 days, 400 KB, 300 seconds) are first guesses measured by #299 and the proof (#468).
