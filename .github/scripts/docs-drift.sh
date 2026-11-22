#!/usr/bin/env bash
# Fails when the docs drift from the plugin (#64): every skill, agent and script command has its entry
# in the guide, every command marked available exists, and the two READMEs have the same sections.
# Run from the repository root.
# shellcheck disable=SC2016 # backquotes in patterns are Markdown, not shell
set -euo pipefail
plugin=plugins/senior-mode
guide=docs/guide
status=0
drift() { echo "$1" >&2; status=1; }

for dir in "$plugin"/skills/*/; do
  s=$(basename "$dir")
  grep -qE "^## \`$s\`" "$guide/skills.md" "$guide/commands.md" ||
    drift "skill $s: no section in $guide/skills.md or $guide/commands.md"
done

for file in "$plugin"/agents/*.md; do
  a=$(basename "$file" .md)
  grep -qE "^## \`$a\`" "$guide/agents.md" || drift "agent $a: no section in $guide/agents.md"
done

# The script's commands are the alternatives of its usage line, up to their first argument.
usage=$(sed -n 's/^ *die "usage: senior-mode \(.*\)"$/\1/p' "$plugin/bin/senior-mode")
[ -n "$usage" ] && [ "$(wc -l <<<"$usage")" = 1 ] || {
  drift "$plugin/bin/senior-mode: not exactly one main usage line (die \"usage: senior-mode ...\")"
  exit 1
}
while IFS= read -r alt; do
  cmd=$(awk '{ for (i = 1; i <= NF && $i !~ /^[-<[]/; i++) printf "%s%s", (i > 1 ? " " : ""), $i }' <<<"$alt")
  [ -n "$cmd" ] || continue
  # The command then a space or the closing backquote: `status` is not found in a `statusline` row.
  grep -qE "^\| \`senior-mode ${cmd}[ \`]" "$guide/commands.md" || drift "script command '$cmd': no row in $guide/commands.md"
done <<<"${usage// | /$'\n'}"

for file in README.md README.fr.md "$guide/commands.md"; do
  while IFS= read -r c; do
    [ -f "$plugin/skills/$c/SKILL.md" ] || drift "$file: /senior-mode:$c is marked available but has no skill"
  done < <(sed -nE 's/^\| `\/senior-mode:([a-z-]+)`.*\| (Available|Disponible) \|$/\1/p' "$file")
done

en=$(grep -c '^## ' README.md || true)
fr=$(grep -c '^## ' README.fr.md || true)
[ "$en" = "$fr" ] || drift "README.md has $en sections, README.fr.md $fr: keep them in sync"

exit "$status"
