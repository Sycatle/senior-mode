#!/usr/bin/env bash
# senior-mode: fails when the production Supabase project (config key supabase.prodProjectRef of
# .claude/senior-mode.json) shows up in a .env* file of the worktree, tracked or not, or in
# NEXT_PUBLIC_SUPABASE_URL / SUPABASE_URL. Prints file names, variable names and line numbers,
# never a value. Standalone: needs only bash, jq, find and awk.
set -u
root=$(git rev-parse --show-toplevel 2>/dev/null) || root=$PWD
config=$root/.claude/senior-mode.json
command -v jq >/dev/null || { echo "supabase-prod-ref: jq is needed to read $config" >&2; exit 1; }
ref=$(jq -r '.supabase.prodProjectRef // empty' "$config" 2>/dev/null) || ref=
if [ -z "$ref" ]; then
  echo "skipped: supabase.prodProjectRef is not set in .claude/senior-mode.json"
  exit 0
fi

hits=
while IFS= read -r -d '' file; do
  # The variable name when the line is VAR=value, else the line number; the ref goes through the
  # environment and is matched literally.
  names=$(REF=$ref awk '
    BEGIN { ref = ENVIRON["REF"] }
    index($0, ref) {
      line = $0
      sub(/^[ \t]*(export[ \t]+)?/, "", line)
      key = line
      sub(/=.*/, "", key)
      if (line ~ /=/ && key ~ /^[A-Za-z_][A-Za-z0-9_]*$/ && !index(key, ref)) print key
      else print "line " NR
    }' "$file" | sort -u | paste -sd, -)
  [ -z "$names" ] || hits+="  ${file#"$root"/}: ${names//,/, }"$'\n'
done < <(find "$root" \( -name .git -o -name node_modules -o -name .next \) -prune -o -type f -name '.env*' -print0)

for var in NEXT_PUBLIC_SUPABASE_URL SUPABASE_URL; do
  [[ ${!var:-} != *"$ref"* ]] || hits+="  environment: $var"$'\n'
done

if [ -n "$hits" ]; then
  echo "the production Supabase project (supabase.prodProjectRef) is referenced in:"
  printf '%s' "$hits"
  echo "Point these at the dedicated Supabase dev project."
  exit 1
fi
echo "ok: no reference to the production Supabase project"
