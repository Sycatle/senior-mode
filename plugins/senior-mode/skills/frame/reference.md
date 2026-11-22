# Frame skill: reference

## Facts from GitHub

```
gh issue list --state open --limit 200
gh api 'repos/{owner}/{repo}/milestones?state=all' --paginate --jq '.[]|"\(.number) \(.state) \(.title)"'
```

## Size S

An S issue needs no spec but must reach Ready, or it never gets picked. A new S idea with nobody to
ask (headless) first becomes that issue, else `next` and `run` never see it: the `ops` agent runs
`senior-mode issue create` as in "Tickets" with `--size S`, the type of the idea and its Given / When /
Then criteria drafted from the idea. With a human, a new S idea only gets the offer to do the same.

1. `senior-mode item set <n> Size S`: it adds the issue to the board. Add `Priority "<option>"` only
   when the user gave one.
2. Read its acceptance criteria: each must be a testable Given / When / Then. Missing or vague:
   draft them from the issue text and offer to add them to the issue body (headless: add them).
3. Apply skill `ready`: it sets Status Ready, or says what is missing.

## Tickets

One `ops` call per ticket, body in `<<'SENIOR_MODE_BODY'`:

```
senior-mode issue create --title <t> --body-file - --size <S|M|L> --priority "<option>" \
  --milestone "<title>" --type <feature|bug|task|chore> [--blocked-by <n>]... [--parent <n>]
```

`--priority` is one of `P0 now`, `P1 next`, `P2 later`, `P3 someday`; size is `S`, `M` or `L`.

The body holds what it gives (plain words), a link to the spec, the acceptance criteria as
Given / When / Then and the test seams. A size L has an epic (size L, the spec's summary), which is
the anchor; every slice takes `--parent <epic>`. A chosen milestone that is closed is reopened
(`-X PATCH .../milestones/<n> -f state=open`); one absent from the facts is created first with
`gh api repos/{owner}/{repo}/milestones -f title=<title>`.

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
