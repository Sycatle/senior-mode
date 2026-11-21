# Refactor-only ticket: reference

Read when a refactor is larger than a few steps, or the code is hard to pin with tests.

## Stating the invariant

Name what callers can observe, not how the code works inside:

- Public functions and their return values, thrown errors, exit codes.
- Side effects: writes, network calls, emitted events, log lines others parse.
- Ordering and timing others rely on.

Anything not in the list is free to change. When unsure whether something is observable, treat it as
observable. The PR states the goal and the invariant.

## Characterization tests

- Call the code through its public interface with realistic inputs; record the actual output as the
  expected value, then read it: if it looks wrong, open a bug ticket but keep asserting it.
- Cover the branches the refactor will touch, plus the edges (empty, null, large, error paths).
- Pin time, randomness and external services at the boundary, not inside the code under refactor.
- No seam: the first step is the smallest seam-creating move (extract a parameter, wrap a call), made
  with the best checks available (type checker, compiler, a manual run), and said so in the commit
  body.
- Snapshots are acceptable as a first net; replace them with explicit assertions on what matters.

## Step catalogue

Rename, extract function, inline function, move to a better module, replace a conditional with a
lookup or polymorphism, remove duplication of knowledge, narrow a visibility, delete dead code (after
confirming nothing calls it, including dynamic and cross-repository callers).

Order: make the change easy (preparatory steps), then make the easy change. No new abstraction
without a second use; match the style around the code.

## Commit hygiene

- One step, one `refactor(scope): subject`. A move plus an edit of the moved code is two commits, so
  history shows the move.
- The characterization tests commit comes first and passes on the unchanged code.
- The body says the invariant when it is not obvious.

## Signs you left the mode

- A test had to change to stay green.
- The diff includes a new option, a new default, or a fixed edge case.
- A dependency moved version.
- Output differs in a way a user could notice.

Revert to the last green commit, then report the step reached and the behaviour at stake, or open a
ticket. Also stop when the tests cannot pin the invariant or the change outgrows its size
(skill `triage`).
