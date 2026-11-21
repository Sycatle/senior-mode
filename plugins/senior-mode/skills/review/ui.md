# UI section

Read only when the diff touches front-end files. Review what the user will see, not only the diff.
Flag what the change introduces or makes worse; pre-existing problems go in a separate note.

## Find the pages

- Keep pages, routes, components, styles and copy files from `git diff --name-only <base>...HEAD`.
- Map each to the page(s) that render it (route files, then importers of a touched component).

## Look at it (only if Playwright is available)

- Use the project's own Playwright (`node_modules/.bin/playwright`, its config and browsers). Never
  install packages or browsers. None present: say "no browser tooling, code review only".
- Target a running dev server or preview; never production, never real accounts. If none runs and
  none is given, do not start one silently: say the pages were not seen.
- Shoot each touched page at 1280x800 and 390x844, full page, into a temporary directory outside the
  repository, never committed. Wait for a landmark or `networkidle`, not a fixed sleep. A page behind
  a login needs the project's dev account or fixtures; otherwise report it as unreachable.
- Read the screenshots and the code together.

## Check

- **Accessibility basics:** every input has a label (a placeholder is not one); errors are tied to
  their field and not shown by colour alone; images have `alt` (empty when decorative); icon-only
  buttons have an accessible name; focus is visible and follows reading order; modals trap and
  restore focus and close on Escape; clickable things are `button` or `a`, not `div onClick`; one
  `h1`, no skipped heading level; links say where they go; animation respects
  `prefers-reduced-motion`. Contrast around 4.5:1 for body text, 3:1 for large text and borders:
  measure with a tool, otherwise say "looks low" and mark it unverified.
- **Consistency:** look for an existing component before accepting a new one; colours, spacing and
  sizes come from the design tokens or theme, not hard-coded values; same action, same wording and
  placement as elsewhere.
- **States:** empty (says what belongs here, offers the next action); loading (no layout jump, no
  blank page, button disabled while submitting); error (says what happened, keeps the input, offers
  a retry); long text and large lists do not break the layout. Reach them when you can, otherwise
  read the code and say they were not seen.
- **Responsive:** no horizontal scroll or clipped content at 390, tap targets at least 44px, nothing
  essential hidden on mobile.
- **Copy:** in the project language, one form of address, verbs on buttons, no internal identifiers
  or raw error messages, dates and numbers formatted for the locale.

## Report

Under the verdict comment, findings ranked blocking, should fix, nit:

- Blocking: a user cannot finish the task (keyboard trap, unlabeled control, unreadable text, broken
  mobile layout, no error state on a failing action).
- Should fix: works but hurts (weak contrast, one-off style next to an existing component, unclear
  copy, layout shift).
- Nit: polish.

One line each: `file:line`, what is wrong, who it hurts, the fix, the screenshot path if any. End
with the pages covered and what could not be checked.
