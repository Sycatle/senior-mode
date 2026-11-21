<!-- senior-mode:nextjs-supabase (kept up to date by senior-mode setup; edit outside this block) -->
## Supabase
- Tests and e2e run against a dedicated Supabase dev project, never prod; `supabase.prodProjectRef` in `.claude/senior-mode.json` names the prod project, and `senior-mode check` fails if it shows up in a `.env*` file.
- At most `e2e.slots` e2e runs at once (2 by default).
<!-- /senior-mode:nextjs-supabase -->
