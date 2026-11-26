# Setup skill: reference

## No branch protection

`senior-mode setup github` prints `protection: NOT enforced` on a private repository of a Free
account or organization: GitHub offers no ruleset there, so anyone with push access can push to the
default branch, and the pre-push hook is the only gate. Setup records `github.protection: local`:
`serve` still merges, with senior-mode as the gate, and an audit workflow (`senior-mode-audit.yml`, to
commit) reports a push outside a pull request, after the fact. Relay it in plain words, with the two ways
out (make the repository public, or upgrade to Pro or Team and rerun setup), and get an explicit
acknowledgement before going on.

## Board

With no Project, `senior-mode setup github` copies the template Project (`board.template`): views,
fields and built-in workflows come with the copy. It then ensures the fields Status, Priority, Size,
Severity and Paths (text), keeping existing options, then Iteration (`board.iterationDays`, 26 iterations from this week's Monday), Start and End (dates). Relay `board: the copy lacks ...` (views to add
by hand, workflows to turn on in the Project's Workflows tab: no API does either). An existing Project is
never replaced: on `board: the Project lacks ...`, say what is missing and offer `--upgrade` (`--upgrade --dry-run` lists the fields and options it adds to the board; nothing
else is touched) or `--migrate` (show
`--migrate --dry-run` first: items, fields and options to create, nothing changed). It copies the template, adds
every item with its values, links the new Project and closes the old one, never deleting it; relay the
reopen command it prints. A rerun after an interruption goes on without adding anything twice.
It also writes the Project's short description and README in the project language; a rerun rewrites
only the block between the `senior-mode:begin` and `senior-mode:end` markers (`board README: ... markers broken`:
the README is left as it is, ask the user to restore the markers).

## Survey of a legacy project

`senior-mode setup repo --adopt` on a project recorded `adopt.kind: legacy` opens one pull request that also holds the survey.
Before it, run `senior-mode survey` (measures as JSON) and give the architect agent the output: it writes drafts under
`.claude/survey/` (map, notes, risk zones, retroactive ADRs, rules, `protected` proposal), see its prompt. `--adopt --dry-run`
prints the measures and the files that would be written. The pull request lists each file with its confidence and a
checkbox: tell the user that editing or deleting a file corrects it and that the merge validates it. A second run adds
only new findings, in a pull request of its own.

## Scanners

`senior-mode setup github` turns on Dependabot alerts, secret scanning and push
protection, and prints `security: <feature>: on` or `not enabled (<reason>)` for each: relay every
`not enabled` in plain words (the plan or the token refuses it; setup went on). It leaves Dependabot security updates off (GitHub cannot limit
them to high and critical severity, so alerts become issues only). For a project with a `package.json`, it writes a weekly `npm` `.github/dependabot.yml`
(minor and patch in one group, majors ignored: `serve` files each major as a `chore(deps)` ticket once a week); if the
project has its own, setup prints `dependabot.yml: untouched`, and `renovate: untouched` beside a Renovate config.

## Questions

Three (a fourth when `setup detect` lists `hosted previews`), asked once, in the project language, plain words, never a key name. The recommended answer is first;
`senior-mode setup answers` takes each as a flag and keeps what the repository already holds, so a rerun
asks only what changed.

1. How strict the process is: `--strictness strict` (recommended: an independent review before every merge) or
   `fast` (a pull request merges once check is green; the other guards stay). `fast` lifts the review: say so, and
   that setup then writes an accepted ADR (`docs/adr/`), which the user commits to the default branch. It maps to
   the `process.profile` of the repository layer; `strict` writes no key.
2. Which language: `--language en|fr`, recommended from `setup detect` (the user's `CLAUDE.md`, then the locale),
   else from the conversation; never `en` silently. It picks the templates `setup repo` writes. Another language
   than `en` or `fr` is not a setup answer: keep the conversation in it and use `en`.
3. May agents work alone: `--autonomy ask` (recommended: agents deliver pull requests, the user merges) or `alone`
   (the daemon merges what passed check and review). It maps to `autonomy.merge`.
4. Only when `setup detect` prints `hosted previews: ...` (Vercel, Netlify, Cloudflare Pages): should every branch the
   agents push start a preview deployment, which spends the platform's quotas? `--previews ready` (recommended: none
   until the pull request is open, then one preview for the review, asked with `senior-mode preview`), `off` (none) or
   `platform` (unchanged; what a rerun or a non-interactive setup keeps). It maps to `deploy.previews`; `setup repo`
   writes the platform files (`vercel.json`, `netlify.toml`, `.claude/senior-mode/ignore-build.sh`) and, for Cloudflare
   Pages, prints the dashboard steps: relay them. See docs/guide/configuration.md, "Hosted previews".

Not asked, shown in the summary: the owner decides on risky changes (protected zones wait for the owner's approval,
and no answer lifts that), checks `local` (`actions` spends the Actions budget: only on request), the work limits.
If `setup detect` says branch rules are not enforced, see "No branch protection".

## Existing project

`senior-mode setup repo` first reads the project's workflow (branch model, commit and pull request format, merge
method, CI jobs, labels, tracker, evergreen or legacy) and prints it with its evidence under `## Detected` and
`## Not mapped`. Relay both. Each `ask: ... (assumed)` line is a question it could not ask: it took the recommended
answer, so say which and offer to change the key in `.claude/senior-mode.json`. `--dry-run` shows the findings and the
config it would write and changes nothing: offer it first on a project with history. `--adopt` opens them as the pull
request `docs: adopt senior-mode`. When `ci.mode` is `existing` (the project's CI runs on pull requests), run
`senior-mode setup github --ci existing`: no workflow is disabled, none is written, and its required contexts are kept.
A commit-msg hook of the project's own is kept, and ours goes to `.githooks/commit-subjects`.

## Repository follow-ups

1. If `setup repo` prints `missing:`, propose a tool for each (Biome to lint, Vitest to test),
   added in its own commit on a yes; then rerun it.
2. If it says `created from the skeleton`, fill it from the scout agent's commands, code map and
   pitfalls. If the repository has an `AGENTS.md`, `CLAUDE.md` imports it (`@AGENTS.md`): keep the
   instructions there and never copy them. If it reports over 80 lines, propose cuts.
3. If it prints `lsp:` lines, relay them (server, the command that enables it in Claude Code; nothing is installed)
   and ask whether the user enables it. Record the answer: `senior-mode setup answers --lsp yes|no`; it is not
   proposed again. Run the enabling command yourself only on a yes.
4. Offer the status line.

`setup repo` adds `.claude/agent-memory/` to `.gitignore` (printed once). The agents' project memory
is written in the checkout the session runs in, never in a pull request, so it is kept on the machine
and the tree stays clean; `retro` reads it there.

## Status line

Offer a status line that shows the current ticket, the last check and the run in progress. It
is set for this project only (`.claude/settings.json` of this repository): it replaces the user's own
status line here, and their personal one stays untouched elsewhere. Say that before asking. On a yes,
run `senior-mode setup statusline`.

## Without a human

Nobody can answer in `claude -p` or a session with `SENIOR_MODE_RUN=1`. Take the recommended option
of each reversible question and say so in the report: `setup answers` with no flag (strict, the detected
language, agents ask), checks `local`, no status line (it edits settings). Never acknowledge `protection: NOT enforced`: finish the rest,
report that the gap awaits a human, stop there. The permissions that `setup repo` writes to
`.claude/settings.json` are ignored by a headless session in a workspace Claude Code does not trust
yet: open the folder interactively once and accept the trust prompt, or pass the permissions on the
command line.
