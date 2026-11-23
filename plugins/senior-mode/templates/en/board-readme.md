<!-- senior-mode:begin (kept up to date by senior-mode setup github; edit outside this block) -->
## How this board works

Every ticket is an issue with a Status, a Priority (P0 now to P3 someday) and a Size (S, M, L).

| Status | Meaning |
| --- | --- |
| Backlog | Filed, not ready to be worked on |
| Ready | Meets the Definition of Ready: an agent or a person can take it |
| In progress | Someone is working on it, on a branch of its own |
| In review | Its pull request is open and waits for checks, review or merge |
| Done | Merged and closed |

### Definition of Ready

- A spec in [`docs/specs/`](https://github.com/{{repo}}/tree/HEAD/docs/specs) with Given / When / Then acceptance criteria (a size S needs a clear expected behaviour in the issue instead).
- Size S or M: an L is an epic, its sub-issues are Ready, not itself.
- No open question, no `needs-info` label.
- Unblocked: every blocked-by issue is closed.
- Test seams: where the tests hook in.

### Who moves what

- A human files and frames tickets, answers `needs-info`, decides what waits with `needs-human`, and merges the pull requests that need an owner.
- An agent moves a ticket to Ready when it meets the Definition of Ready, to In progress when it starts, to In review when it opens the pull request.
- The Project's built-in workflows move a closed or merged ticket to Done.
<!-- senior-mode:end -->
