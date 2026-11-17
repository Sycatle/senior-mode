<!-- senior-mode:principles (kept up to date by senior-mode setup; edit outside this block) -->
## Principles
- Keep it simple: the smallest change that meets the acceptance criteria, no speculative abstraction.
- One responsibility per module and function; add an interface when a second implementation exists.
- Test first: a failing test, the code, then refactor; the test goes in the same commit as the code.
- Atomic Conventional Commits; the body says why.
- One pull request per issue, about 400 changed lines at most.
- Decisions that outlive a pull request go in `docs/adr/`; M and L features start from `docs/specs/`.
- Done means the checks ran and pass (`senior-mode check`, or `.githooks/pre-push`).
- Ask when a product or architecture decision is open; never guess.
<!-- /senior-mode:principles -->
