# Frame skill: reference

## Facts from GitHub

```
gh issue list --state open --limit 200
gh api 'repos/{owner}/{repo}/milestones?state=all' --paginate --jq '.[]|"\(.number) \(.state) \(.title)"'
```

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
