# Frame skill: reference

## Facts from GitHub

```
gh issue list --state open --limit 200
gh api 'repos/{owner}/{repo}/milestones?state=all' --paginate --jq '.[]|"\(.number) \(.state) \(.title)"'
```

## A product request

Starts the skill: a plain wish to change the product ("je veux", "on devrait", "ajoute", "I want", "we
should", "add"), with or without the command. Does not: a question, a review request, a status
request. A bug report about existing behaviour is not a product request either: it goes through skill
`triage` and its regression test, not through framing.

## Facts

Besides the `scout` agent, read the open issues and milestones yourself (above). An idea that is an
existing issue keeps that issue as the anchor.

## Size S

No spec. Ask the round of questions first (nobody to ask: take the recommended options and write them
in the issue as assumed), then:

1. An existing issue is used as is; a new idea becomes one: the `ops` agent runs `senior-mode issue
   create` as in "Tickets" with `--size S`, the type of the idea and the expected behaviour as Given /
   When / Then criteria drafted from the idea and the answers.
2. `senior-mode item set <n> Size S`: it adds the issue to the board. Add `Priority "<option>"` only
   when the user gave one.
3. Each criterion must be a testable Given / When / Then. Missing or vague: draft them from the issue
   text and the answers and add them to the issue body.
4. Apply skill `ready`: it sets Status Ready, or says what is missing.
5. With a human: deliver it in this session. `go` cannot be invoked by the model, so read
   `${CLAUDE_SKILL_DIR}/../go/SKILL.md` and follow its steps 4-9 for this issue: `senior-mode start`,
   red test, green, pull request, review, merge only on a clear yes. Headless: stop at Ready, the daemon or `go`
   delivers it.

## Vision

`docs/vision.md` (goals `G1`..., `## Non-goals`; a human's file, never edited here) is read before the
questions, when it exists. An idea that contradicts a non-goal is not framed: quote the non-goal word for word
and ask it as the first framing question (keep the idea, drop it, or the owner changes the vision himself).
Nobody to ask: label the idea's issue `needs-human` (created first when it has none) with a comment quoting the
non-goal, and stop with no spec and no ticket. A wave's milestone also needs a goal: "Tickets", "Hierarchy". No file: skip.

## Decisions

Each question of the round and the option chosen go to `docs/decisions.md` (#310), one line each, once
the anchor issue exists (step 5; an S ticket: right after `senior-mode start`, in its worktree):

```
senior-mode frame decide <anchor> "<question>" "<answer>"
```

Nobody to ask: the recommended option, its answer ending with `(assumed)`. A rerun adds nothing. M and L:
run it in the framing worktree, so the file ships with the spec in the step 8 pull request; S: it ships with
the ticket's pull request. Never write it on the default branch. The body of each ticket created gets a final
`## Framing` section: the answers that shaped it, one line each, and "Logged in docs/decisions.md".

## Headless

No question is asked. The recommended options are recorded as assumed in the issue or the spec. An L
spec or an ADR stays `draft` / `proposed` and the anchor gets `needs-human`.

## Tickets

One `ops` call per ticket, body in `<<'SENIOR_MODE_BODY'`:

```
senior-mode issue create --title <t> --body-file - --size <S|M|L> --priority "<option>" \
  --milestone "<title>" --type <feature|bug|task|chore> --paths "<globs>" [--blocked-by <n>]... [--parent <n>]
```

`--priority` is one of `P0 now`, `P1 next`, `P2 later`, `P3 someday`; size is `S`, `M` or `L`.
`--paths` copies the `paths` of the spec, joined by commas; a slice that touches less narrows it to its
own files. Tickets whose paths overlap never run at the same time, and one with no paths runs alone, so
never leave it out when the spec has `paths`. Without a Paths field on the board (`senior-mode setup
github` creates it), `--paths` is refused.

The body holds what it gives (plain words), a link to the spec, the acceptance criteria as
Given / When / Then and the test seams. A size L has an epic (size L, the spec's summary), which is
the anchor; every slice takes `--parent <epic>`. A chosen milestone that is closed is reopened
(`-X PATCH .../milestones/<n> -f state=open`); one absent from the facts is created first with
`gh api repos/{owner}/{repo}/milestones -f title=<title>`.

### Hierarchy

With `docs/vision.md`, a wave is vision goal, milestone, epic, ticket (spec 325 section 7):

- A milestone created here gets `-f description="Goal: G<n>"` as its first line, `G<n>` being a goal of the vision
  file. Pick the goal that fits and put it in the question round, recommended option first. No goal fits: ask
  (keep the idea, add a goal to the vision yourself, or another milestone). Never invent a goal or
  a number. Nobody to ask: do not create the milestone, label the anchor `needs-human` with a comment naming
  the idea and the goals, and stop. A milestone that already exists is used as is; one with no `Goal:` line
  is said in the report, not edited.
- Each epic (size L) has one spec: its body links exactly one spec (`docs/specs/<anchor>-<slug>.md`), no more. A wave
  of several specs has one epic per spec.
- Every ticket of the wave is created with `--parent <epic>`; none is left without one.

No vision file: none of this applies, milestones and tickets are made as above.

## Spikes

An open technical question that blocks a decision becomes a spike ticket, not a guess in a spec:
`senior-mode issue create ... --type spike --timebox <30m|2h|20k tokens>` (the timebox is required, and refused for
other types). The body states the question and what a good answer lets the team decide. A spike ends in a note under
`docs/spikes/`, an ADR or framed tickets; its pull request changes `docs/` only, `ready` refuses any other file. A
duration timebox is enforced by the daemon, which stops the session, comments the notes found and sets `needs-human`.

## ADR numbers

Parallel framings must not share numbers. Write each ADR under a provisional name; when committing,
take the next number from what is on `origin/main`, not from the worktree:

```
git fetch -q origin && git ls-tree --name-only origin/main docs/adr/
```

Rename the file to the highest number plus one (several ADRs: in order), and update the spec's
`adrs`, the links between the spec and the ADR, and the ticket bodies that name it. Before pushing,
fetch again and run the same listing: a number now taken means renumber and amend. The spec needs
no number: its name carries the issue.
