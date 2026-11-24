# shellcheck shell=bash
# `setup detect` and `setup answers` (#320): setup detects the stack, the visibility and the plan of the repository,
# asks three plain questions (how strict the process is, which language, may agents work alone) and takes documented
# defaults for the rest. The answers land in the process profile (#307) and in the repository layer.

# The language of the user's CLAUDE.md files (project, then personal), else of the locale, as "<code>|<source>";
# nothing when none says (the skill then reads the conversation).
language_detect() { # root
  local pair f label fr en
  for pair in "$1/CLAUDE.md|the project CLAUDE.md" "${HOME:-/nonexistent}/.claude/CLAUDE.md|your personal CLAUDE.md"; do
    f=${pair%%|*} label=${pair#*|}
    [ -f "$f" ] || continue
    fr=$(grep -oiwE 'le|la|les|des|une|est|pour|avec|dans|que|qui|pas|du' "$f" | wc -l)
    en=$(grep -oiwE 'the|and|is|for|with|that|this|are|not|you|of' "$f" | wc -l)
    if [ "$fr" -ge 3 ] && [ "$fr" -gt "$en" ]; then echo "fr|$label"; return 0; fi
    if [ "$en" -ge 3 ] && [ "$en" -gt "$fr" ]; then echo "en|$label"; return 0; fi
  done
  case ${LC_ALL:-${LANG:-}} in
    fr*) echo "fr|the locale" ;;
    en*) echo "en|the locale" ;;
  esac
  return 0
}

# What GitHub says about the repository $1, as JSON: {visibility, ownerType, plan, rulesets}. Each is "unknown" when the
# API does not say. Rulesets exist on a public repository and on a paid plan, never on a private one of a Free plan.
github_detect() { # slug
  local owner=${1%%/*} info type vis plan="" who
  if ! info=$(gh_retry api "repos/$1" --jq '[.owner.type, (.private | tostring)] | join("|")' 2>/dev/null); then
    echo '{"visibility":"unknown","ownerType":"unknown","plan":"unknown","rulesets":"unknown"}'
    return 0
  fi
  type=${info%%|*} vis=public
  [ "${info#*|}" != true ] || vis=private
  if [ "$type" = Organization ]; then
    plan=$(gh_retry api "orgs/$owner" --jq '.plan.name // ""' 2>/dev/null) || plan=""
  else
    who=$(gh_retry api user --jq '[.login, (.plan.name // "")] | join("|")' 2>/dev/null) || who=""
    [ "${who%%|*}" != "$owner" ] || plan=${who#*|}
  fi
  jq -nc --arg v "$vis" --arg t "$type" --arg p "$plan" '{visibility: $v, ownerType: $t, plan: ($p | if . == "" then "unknown" else ascii_downcase end)}
    | .rulesets = (if .visibility == "public" then "yes" elif .plan == "free" then "no" elif .plan == "unknown" then "unknown" else "yes" end)'
}

# Everything setup detects, as JSON: {stack: {preset, framework, typescript}, github, language: {code, source}}.
setup_facts() { # root
  local root=$1 pname detected gh="" lang
  pname=$(project_preset "$root")
  detected=$(preset_detect "$root" "$pname" 2>/dev/null) || detected='{}'
  if git -C "$root" remote get-url origin >/dev/null 2>&1; then gh=$(github_detect "$(repo_slug)"); fi
  [ -n "$gh" ] || gh='{"visibility":"unknown","ownerType":"unknown","plan":"unknown","rulesets":"unknown"}'
  lang=$(language_detect "$root")
  jq -nc --arg p "$pname" --argjson d "$detected" --argjson g "$gh" --arg l "$lang" '{
    stack: {preset: $p, framework: ($d.framework // null), typescript: ($d.typescript // null)},
    github: $g,
    language: {code: ($l | split("|")[0] | if . == "" then null else . end), source: ($l | split("|")[1] // null)}}'
}

# `senior-mode setup detect [--json]`: what setup reads from the repository and from GitHub, before asking anything.
setup_detect() {
  local root json=false facts
  [ $# -eq 0 ] || { [ $# -eq 1 ] && [ "$1" = --json ]; } || usage
  [ "${1:-}" != --json ] || json=true
  root=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repository"
  facts=$(setup_facts "$root")
  if $json; then
    printf '%s\n' "$facts"
    return 0
  fi
  jq -r '"stack: \(.stack.preset)\([.stack.framework, (if .stack.typescript == true then "TypeScript" elif .stack.typescript == false then "JavaScript" else null end)] | map(select(. != null)) | if length > 0 then " (\(join(", ")))" else "" end)",
    "repository: \(.github.visibility), owned by \(if .github.ownerType == "Organization" then "an organization" elif .github.ownerType == "User" then "a user" else "unknown" end), plan \(.github.plan)",
    "branch rules: \(if .github.rulesets == "yes" then "GitHub enforces a ruleset on this repository" elif .github.rulesets == "no" then "not enforced: GitHub offers no ruleset on a private repository of a Free plan" else "unknown" end)",
    "language: \(if .language.code then "\(.language.code) (from \(.language.source))" else "not found, ask or read the conversation" end)"' <<<"$facts"
}

# The number of the next ADR of the project at $1: one more than the highest four-digit prefix, 0001 when none.
adr_next() { # root
  local n=0 f b
  for f in "$1"/docs/adr/[0-9][0-9][0-9][0-9]-*.md; do
    [ -f "$f" ] || continue
    b=${f##*/}
    [ "$((10#${b:0:4}))" -le "$n" ] || n=$((10#${b:0:4}))
  done
  printf '%04d\n' $((n + 1))
}

# The decision that the `fast` profile needs to lift the independent review (ADR 0027): written from the answer.
adr_lift_review() { # number
  cat <<EOF
---
id: $1
title: A pull request merges once check is green, without an independent review
status: accepted
---

## Context

The default process has an independent review before every merge. The owner of this repository chose the \`fast\`
process profile when setting senior-mode up, knowing that it lifts that gate.

## Decision ($(date +%F), owner)

The \`review\` gate is lifted: a pull request merges once \`senior-mode check\` is green. The other gates stay locked:
the secret scan, the protected zones, the bash guard, no force push, a green check and the trust gate.

## Consequences

- \`process.profile\` is \`fast\` and \`process.lifts\` names this ADR; \`senior-mode status\` reports the lifted gate.
- Going back is one answer: \`senior-mode setup answers --strictness strict\`.
EOF
}

# `senior-mode setup answers [--strictness strict|fast] [--language en|fr] [--autonomy ask|alone] [--lsp yes|no] [--dry-run]`.
# `--lsp` records the answer to the language server proposal of `setup repo` (#341); left out, the key is untouched.
# An answer left out keeps the value of the repository, else takes the recommended one. Prints one summary (what was
# detected, what each answer changes, the defaults that apply) and writes it unless --dry-run.
# shellcheck disable=SC2016 # jq programs, not shell
setup_answers() {
  local root file facts strict="" lang="" auto="" lsp="" dry=false rec_lang cur_strict cur_auto adr="" write=false
  while [ $# -gt 0 ]; do
    case $1 in
      --strictness) [ "${2:-}" = strict ] || [ "${2:-}" = fast ] || usage; strict=$2; shift 2 ;;
      --language) [ "${2:-}" = en ] || [ "${2:-}" = fr ] || usage; lang=$2; shift 2 ;;
      --autonomy) [ "${2:-}" = ask ] || [ "${2:-}" = alone ] || usage; auto=$2; shift 2 ;;
      --lsp) [ "${2:-}" = yes ] || [ "${2:-}" = no ] || usage; lsp=$2; shift 2 ;;
      --dry-run) dry=true; shift ;;
      *) usage ;;
    esac
  done
  root=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repository"
  file=$root/.claude/senior-mode.json
  if [ -f "$file" ]; then
    jq empty "$file" 2>/dev/null || die "invalid .claude/senior-mode.json; fix or remove it, then run setup again"
  fi
  facts=$(setup_facts "$root")
  cur_strict=strict cur_auto=ask
  if [ -f "$file" ]; then
    cur_strict=$(jq -r '.process.profile // "strict"' "$file")
    jq -e '.autonomy.merge == true' "$file" >/dev/null && cur_auto=alone
    rec_lang=$(jq -r '.language // empty' "$file")
  fi
  [ -n "${rec_lang:-}" ] || rec_lang=$(jq -r '.language.code // "en"' <<<"$facts")
  [ "$rec_lang" = en ] || [ "$rec_lang" = fr ] || rec_lang=en
  [ -n "$strict" ] || strict=$cur_strict
  [ "$strict" = strict ] || [ "$strict" = fast ] || die "process.profile is $strict in .claude/senior-mode.json: setup answers only sets strict or fast"
  [ -n "$lang" ] || lang=$rec_lang
  [ -n "$auto" ] || auto=$cur_auto

  # The lift of the review that `fast` needs: kept when the repository already has an accepted one.
  if [ "$strict" = fast ]; then
    adr=$(jq -r '[.process.lifts[]? | select(type == "object" and .rule == "review") | .adr][0] // empty' "$file" 2>/dev/null) || adr=""
    if [ -z "$adr" ] || [ "$(adr_status "$adr")" != accepted ]; then
      adr=docs/adr/$(adr_next "$root")-lift-independent-review.md
      write=true
    fi
  fi

  echo "Detected"
  setup_detect | sed 's/^/  /'
  echo "Your answers (recommended first)"
  if [ "$strict" = strict ]; then
    echo "  process: strict (recommended): every guard stands, an independent review before each merge. Writes no process key."
  else
    echo "  process: fast: no independent review, a pull request merges once check is green; the other guards stay. Writes process.profile fast and process.lifts, with the accepted ADR $adr."
  fi
  echo "  language: $lang$([ "$lang" != "$rec_lang" ] || echo ' (recommended)'): templates and what Claude writes for you. Writes language."
  if [ "$auto" = alone ]; then
    echo "  agents alone: yes: the daemon merges a pull request that passed check and review, with nobody there. Writes autonomy.merge true; /senior-mode:go auto starts it."
  else
    echo "  agents alone: no (recommended): agents deliver pull requests, you merge. Writes autonomy.merge false."
  fi
  [ -z "$lsp" ] || echo "  language server: $lsp: $([ "$lsp" = yes ] && echo 'you enable it in Claude Code' || echo 'not proposed again'); setup installs nothing. Writes lsp."
  echo "Defaults (documented in docs/guide/configuration.md, change them in .claude/senior-mode.json)"
  echo "  risky changes: you decide; a pull request that touches a protected zone waits for your approval, and no answer lifts that."
  jq -nr --argjson d "$DEFAULTS" '"  checks: \($d.ci.mode), before each push (free); setup github --ci actions also runs them on GitHub Actions and spends its budget",
    "  work: \($d.autonomy.maxTickets) tickets per run, \($d.autonomy.parallel) at a time, \($d.wip) in progress at once, \($d.limits.prLines) changed lines per pull request",
    "  board: a Project copied from the template, with Status, Priority, Size, Severity, Paths and Iteration"'
  if $dry; then
    echo "Dry run: nothing written."
    return 0
  fi

  mkdir -p "$root/.claude"
  [ -f "$file" ] || echo '{}' >"$file"
  json_update "$file" '.language = $l | .autonomy.merge = ($a == "alone") | if $lsp == "" then . else .lsp = ($lsp == "yes") end
    | if $s == "fast" then .process.profile = "fast"
        | .process.lifts = ([(.process.lifts // [])[] | select((type == "object" and .rule == "review") | not)] + [{rule: "review", adr: $adr}])
      else del(.process.profile) | .process.lifts = [(.process.lifts // [])[] | select((type == "object" and .rule == "review") | not)]
        | if (.process.lifts | length) == 0 then del(.process.lifts) else . end
        | if (.process | length) == 0 then del(.process) else . end end' \
    --arg l "$lang" --arg a "$auto" --arg s "$strict" --arg adr "$adr" --arg lsp "$lsp" || [ $? -eq 2 ] || die "could not write .claude/senior-mode.json"
  echo "written: .claude/senior-mode.json"
  if [ "$write" = true ]; then
    mkdir -p "$root/docs/adr"
    adr_lift_review "$(basename "$adr" | cut -c1-4)" >"$root/$adr"
    echo "written: $adr (commit it to the default branch: the daemon reads the base branch)"
  fi
}
