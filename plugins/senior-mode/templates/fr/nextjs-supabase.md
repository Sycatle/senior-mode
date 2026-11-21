<!-- senior-mode:nextjs-supabase (tenu à jour par senior-mode setup ; écrire hors de ce bloc) -->
## Supabase
- Tests et e2e tournent sur un projet Supabase de dev dédié, jamais la prod ; `supabase.prodProjectRef` dans `.claude/senior-mode.json` désigne le projet de prod, et `senior-mode check` échoue s'il apparaît dans un fichier `.env*`.
- Au plus `e2e.slots` exécutions e2e en même temps (2 par défaut).
<!-- /senior-mode:nextjs-supabase -->
