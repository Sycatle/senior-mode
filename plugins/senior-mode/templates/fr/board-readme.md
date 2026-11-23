<!-- senior-mode:begin (kept up to date by senior-mode setup github; edit outside this block) -->
## Comment fonctionne ce tableau

Chaque ticket est une issue avec un Status, une Priority (de P0 now à P3 someday) et une Size (S, M, L).

| Status | Sens |
| --- | --- |
| Backlog | Déposé, pas prêt à être travaillé |
| Ready | Respecte la Définition de Ready : un agent ou une personne peut le prendre |
| In progress | Quelqu'un y travaille, sur sa propre branche |
| In review | Sa pull request est ouverte et attend les checks, la revue ou le merge |
| Done | Fusionné et fermé |

### Définition de Ready

- Une spec dans [`docs/specs/`](https://github.com/{{repo}}/tree/HEAD/docs/specs) avec des critères d'acceptation Given / When / Then (une taille S demande à la place un comportement attendu clair dans l'issue).
- Taille S ou M : un L est une épopée, ce sont ses sous-issues qui sont Ready, pas elle.
- Aucune question ouverte, pas de label `needs-info`.
- Débloqué : toutes les issues dont il dépend sont fermées.
- Points d'accroche des tests : où les tests se branchent.

### Qui déplace quoi

- Un humain dépose et cadre les tickets, répond à `needs-info`, tranche ce qui attend avec `needs-human`, et fusionne les pull requests qui demandent un propriétaire.
- Un agent passe un ticket en Ready quand il respecte la Définition de Ready, en In progress quand il démarre, en In review quand il ouvre la pull request.
- Les workflows intégrés du Project passent un ticket fermé ou fusionné en Done.
<!-- senior-mode:end -->
