<!-- senior-mode:principles (tenu à jour par senior-mode setup ; écrire hors de ce bloc) -->
## Principes
- Au plus simple : le plus petit changement qui remplit les critères d'acceptation, aucune abstraction anticipée.
- Une responsabilité par module et par fonction ; une interface quand une seconde implémentation existe.
- Le test d'abord : un test qui échoue, le code, puis le nettoyage ; le test va dans le commit du code.
- Commits atomiques au format Conventional Commits ; le corps dit pourquoi.
- Une pull request par issue, environ 400 lignes modifiées au plus.
- Une décision qui survit à la PR va dans `docs/adr/` ; une fonctionnalité M ou L part de `docs/specs/`.
- Fini veut dire que les vérifications ont tourné et passent (`senior-mode check`, ou `.githooks/pre-push`).
- Demander quand une décision produit ou d'architecture est ouverte ; ne jamais deviner.
<!-- /senior-mode:principles -->
