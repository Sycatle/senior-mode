---
id: 0015
title: What senior-mode guarantees on security, what it blocks, what it alerts and what stays human
status: accepted
spec: 130
supersedes: 0008 (in part: a merge also needs senior-mode/security)
---

## Context

senior-mode runs agents with a shell, unattended, on a machine that holds credentials (ADR 0003,
0012). The owner only frames and reads the board. The risks are: an agent ships a vulnerable change
or dependency, leaks a secret in a commit, loosens the guards that bound it (hooks, rulesets,
statuses), or a risk is seen and silently dropped. Agents act under the owner's GitHub identity
for now (#175). Anything GitHub enforces can therefore be bypassed by a session that escapes the
hooks. The posture has to hold on GitHub Free as well as with GitHub's security features.

## Decision

- **Threat model.** We defend against the agent's own mistakes and against prompt injection
  through repository content, issues and dependencies. We do not defend against a compromised
  machine or a malicious owner.
- **Two review levels.** Every pull request gets the `review` Security section. Pull requests that
  touch a protected zone or close an L ticket also get a pass by the `security` agent, which runs on
  the strongest model (an addition to the routing of ADR 0004). It sets its own required status,
  `senior-mode/security`. `publish` sets that status to success, saying "not required", only when
  `protected` and the ticket's Size show that the pass is not due. A merge, by `run` or by a
  person through `next`, needs all three statuses (amends ADR 0008). Until the separate reviewer
  session (#150), a ticket session could post the status itself: the guard closes that there.
- **Threshold.** High and critical block: a red status, `needs-human`, a P0 or P1 issue. Moderate
  and low are reported and never block.
- **Local first, GitHub as a net.** The secret scan of the diff and the dependency audit run in
  `check`, before anything is pushed. A missing audit tool fails the check unless `audit: false`
  turns it off, and that setting shows in `status`. An advisory without a severity (several
  audit tools give none) is a warning, not a block; Dependabot covers it. GitHub's scanners (Dependabot alerts and
  security updates for high and critical only, secret scanning, push protection, CODEOWNERS) watch
  the whole repository and the CVEs published after a merge.
- **Exceptions are human.** Secret false positives are lifted by a sha256 in
  `.claude/secret-allowlist`, a protected zone no session can write.
- **Risks become issues.** Each risk becomes an issue with a Severity field and the label
  `security`, deduplicated by fingerprint, with no exploit detail in the body. A critical one in a
  public repository also gets a private security advisory.
- **Guards cannot be loosened from inside.** Hooks, rulesets, branch protection, the merge endpoint
  and the work-in-progress limit are denied to sessions. `run` refuses to start when it cannot
  prove the hooks are loaded. Sessions are bounded in time.
- **What stays human.** Allowlisting a secret, turning the audit off, accepting a security finding,
  merging a protected zone, and anything the separate identity (#175) would enforce.

## Alternatives considered

- **GitHub's scanners only:** less code, but nothing on private repositories without GitHub
  Advanced Security, and a secret is already pushed when the alert fires.
- **Local checks only:** works on any plan, but misses the CVEs published after a merge.
- **Security inside `senior-mode/review`:** one status, but the security pass becomes invisible and
  the author's reviewer could skip it.
- **Blocking on moderate:** safer on paper, but it floods the board and trains people to override
  the block.

## Consequences

- Three required statuses instead of two. `setup github` must add the third without blocking open
  pull requests.
- The plugin maintains the audit of each ecosystem (keyed on its lockfile) and the secret patterns.
- An Opus pass on L tickets and protected zones costs more, on purpose, where a miss costs most.
- Until #175, enforcement against a session that escapes the hooks rests on the hooks themselves.
