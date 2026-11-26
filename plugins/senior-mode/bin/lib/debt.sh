# shellcheck shell=bash
# Legacy debt into maintenance tickets (#424, spec 409 section 7). The debt a legacy project measured at adoption blocks
# nothing and is not forgotten: the ratchet baseline (lint findings, coverage), the architecture baseline and the survey's
# dormant zones become gardening tickets, one per metric and directory at depth 2, ranked by findings (or missing coverage)
# times the churn of the directory over 12 months, under the maintenance budget (`maintenance.maxOpen`). `setup repo --adopt
# --debt` files the first ones; `serve` files the next when a gardening ticket closes (`debt_poll`). A ticket carries a
# `debt-id: debt:<metric>:<dir>` line, its fingerprint: none is filed while an open ticket has it.

# The debt of the tree $1 as a JSON array, ranked: {metric, dir, score, title, paths, fingerprint, dead, body}. A `lint`
# ticket takes the rule with most findings in its directory, `coverage` the least covered file under `ratchet.patchCoverage`,
# `architecture` the most repeated violation; `dead` (a zone nothing imports and nothing changed for 12 months) comes last.
# shellcheck disable=SC2016 # a jq program, not shell
debt_candidates() { # tree
  local tree=$1 measures min lint cov arch
  measures=$(survey_measure "$tree")
  min=$(config_get ratchet.patchCoverage 2>/dev/null) || min=80
  lint=$(jq -c '.lint.files // {}' "$tree/$RATCHET_FILE" 2>/dev/null) || lint='{}'
  cov=$(jq -c '.coverage.files // {}' "$tree/$RATCHET_FILE" 2>/dev/null) || cov='{}'
  arch=$(jq -c '.violations // []' "$tree/.claude/architecture-baseline.json" 2>/dev/null) || arch='[]'
  jq -nc --argjson m "$measures" --argjson lint "$lint" --argjson cov "$cov" --argjson arch "$arch" --argjson min "$min" '
    def zone: split("/") | if length == 1 then "." elif length == 2 then .[0] else .[0] + "/" + .[1] end;
    def dirpath: if . == "." then "*" else . + "/**" end;
    def ticket($metric; $dir; $score; $title; $paths; $given; $then):
      {metric: $metric, dir: $dir, score: $score, title: $title, paths: $paths, dead: ($metric == "dead"),
       fingerprint: "debt:\($metric):\($dir)",
       body: "## Context\n\n\(($given[0:1] | ascii_upcase) + $given[1:]). Measured at adoption by `senior-mode setup repo --adopt --debt`; it blocks nothing, and this ticket works it off under the maintenance budget.\n\n## Acceptance criteria\n\n- Given \($given), when \($then), then `senior-mode check --update-baseline` lowers the baseline and no behaviour changes.\n\ndebt-id: debt:\($metric):\($dir)\n"};
    ($m.zones | map({key: .path, value: .touches}) | from_entries) as $churn
    | ([$lint | to_entries | map({dir: (.key | zone), rules: .value}) | group_by(.dir)[]
          | .[0].dir as $d
          | ([.[].rules | to_entries[]] | group_by(.key) | map({rule: .[0].key, n: (map(.value) | add)}) | sort_by([-.n, .rule])) as $r
          | ($r | map(.n) | add) as $total
          | ticket("lint"; $d; $total * ($churn[$d] // 0); "chore(lint): fix \($r[0].rule) findings in \($d)"; ($d | dirpath);
              "the baseline lists \($total) lint findings in `\($d)`, \($r[0].n) of them `\($r[0].rule)`";
              "every `\($r[0].rule)` finding in `\($d)` is fixed")]
       + [$cov | to_entries | map(select(.value < $min) | {dir: (.key | zone), file: .key, pct: .value}) | group_by(.dir)[]
          | .[0].dir as $d
          | (sort_by([.pct, .file])[0]) as $w
          | (map(100 - .pct) | add) as $missing
          | ticket("coverage"; $d; $missing * ($churn[$d] // 0); "chore(coverage): characterize \($w.file)"; $w.file;
              "the baseline records `\($w.file)` at \($w.pct)% line coverage, the least covered file of `\($d)` under \($min)%";
              "characterization tests pin the current behaviour of `\($w.file)` and no source line changes")]
       + [$arch | map({dir: (.file | zone), rule: .rule, file: .file, n: (.count // 1)}) | group_by(.dir)[]
          | .[0].dir as $d
          | (sort_by([-.n, .rule, .file])[0]) as $w
          | (map(.n) | add) as $total
          | ticket("architecture"; $d; $total * ($churn[$d] // 0); "chore(architecture): fix \($w.rule) violation in \($w.file)"; $w.file;
              "the architecture baseline lists \($total) violations in `\($d)`, \($w.n) of rule `\($w.rule)` in `\($w.file)`";
              "the `\($w.rule)` violation in `\($w.file)` is fixed")])
    | sort_by([-.score, .metric, .dir])
    | . + [$m.zones[] | select(.signals | any(startswith("dormant"))) | .path as $d
        | ticket("dead"; $d; 0; "chore(dead): confirm and remove unused code in \($d)"; ($d | dirpath);
            "`\($d)` has had no change in 12 months and nothing imports it (\(.files) source files)";
            "the owner confirms it is dead and it is deleted, or says why it stays")]'
}

# Files one debt ticket (the JSON of debt_candidates in $1) under the epic $2, labelled gardening. Size S, priority P2. A
# `dead` ticket stays in Backlog for the owner: not an agent's ticket, and `needs-human`, so `ready` and `pick` leave it.
# Prints `debt: ticket #n filed: <title>`; fails when it was not filed.
debt_ticket() { # candidate-json epic
  local c=$1 epic=$2 slug body title paths dead gl out n run
  slug=$(repo_slug)
  title=$(jq -r .title <<<"$c")
  paths=$(jq -r .paths <<<"$c")
  dead=$(jq -r .dead <<<"$c")
  gl=$(workflow_label "" gardening)
  body=$(mktemp)
  jq -r .body <<<"$c" >"$body"
  run=(env SENIOR_MODE_RUN=1)
  [ "$dead" != true ] || run=(env -u SENIOR_MODE_RUN)
  if out=$("${run[@]}" "$SELF" issue create --title "$title" --body-file "$body" --size S --priority "P2 later" --type chore \
    --paths "$paths" --parent "$epic" </dev/null) &&
    n=$(sed -nE '1s/^#([0-9]+) .*/\1/p' <<<"$out") && [ -n "$n" ]; then
    gh_retry api "repos/$slug/issues/$n/labels" -f "labels[]=$gl" >/dev/null || echo "debt: could not label #$n $gl" >&2
    [ "$dead" != true ] || gh_retry api "repos/$slug/issues/$n/labels" -f 'labels[]=needs-human' >/dev/null ||
      echo "debt: could not label #$n needs-human" >&2
    echo "debt: ticket #$n filed: $title"
    rm -f "$body"
    return 0
  fi
  echo "debt: ticket not filed: $title" >&2
  rm -f "$body"
  return 1
}

# Files the next ranked debt tickets of the tree $1 within `maintenance.maxOpen` (the open gardening tickets count), none for
# a fingerprint an open ticket carries; with --dry-run it only says which. Sets DEBT_FILED to the number filed. Fails
# when the issues cannot be read, or there is no open epic labelled maintenance (`setup repo --knowledge` creates it).
debt_file() { # tree [--dry-run]
  local tree=$1 dry=false issues epic open max gl ml cands c fp n=0
  [ "${2:-}" != --dry-run ] || dry=true
  DEBT_FILED=0
  max=$(config_get maintenance.maxOpen)
  [[ $max =~ ^[1-9][0-9]*$ ]] || { echo "debt: maintenance.maxOpen must be a positive whole number" >&2; return 1; }
  issues=$(gh_retry issue list --repo "$(repo_slug)" --state open --limit 1000 --json number,title,body,labels 2>/dev/null) || {
    echo "debt: cannot list the issues" >&2
    return 1
  }
  gl=$(workflow_label "" gardening)
  ml=$(workflow_label "" maintenance)
  epic=$(jq -r --arg l "$ml" 'first(.[] | select(any(.labels[]?; .name == $l)) | .number) // empty' <<<"$issues")
  [ -n "$epic" ] || {
    echo "debt: no open epic labelled $ml; none filed (senior-mode setup repo --knowledge creates it)" >&2
    return 1
  }
  open=$(jq -r --arg l "$gl" '[.[] | select(any(.labels[]?; .name == $l))] | length' <<<"$issues")
  if [ "$open" -ge "$max" ]; then
    echo "debt: $open open $gl tickets, maintenance.maxOpen is $max: none filed"
    return 0
  fi
  cands=$(debt_candidates "$tree") || cands='[]'
  [ -n "$cands" ] || cands='[]'
  while IFS= read -r c; do
    [ "$open" -lt "$max" ] || break
    fp=$(jq -r .fingerprint <<<"$c")
    ! jq -e --arg l "debt-id: $fp" 'any(.[]; ((.body // "") | split("\n") | index($l)) != null)' <<<"$issues" >/dev/null || continue
    if [ "$dry" = true ]; then
      echo "debt: would file: $(jq -r .title <<<"$c") ($fp)"
      open=$((open + 1))
    elif debt_ticket "$c" "$epic"; then
      open=$((open + 1))
      n=$((n + 1))
    fi
  done < <(jq -c '.[]' <<<"$cands")
  DEBT_FILED=$n
  [ "$dry" = true ] || [ "$n" -gt 0 ] || echo "debt: no debt left to file"
  return 0
}

# `setup repo --adopt --debt` (after the adoption pull request): the first debt tickets of a legacy project, none for an
# evergreen one. $1 the checkout, $2 --dry-run to only say which.
debt_adopt() { # root [--dry-run]
  local kind
  kind=${WF_ADOPT:-}
  [ -n "$kind" ] || kind=$(jq -r '.adopt.kind // empty' "$1/.claude/senior-mode.json" 2>/dev/null) || kind=""
  if [ "$kind" != legacy ]; then
    echo "debt: evergreen project, no debt ticket filed"
    return 0
  fi
  debt_file "$1" ${2:+"$2"} || echo "debt: no ticket filed" >&2
}

# serve's pass (#424): with `maintenance.debt` true and `adopt.kind` legacy on the base branch, files the next ranked debt
# tickets when a gardening ticket closed and the budget has room. A pass that files nothing is not repeated for an hour (the
# measures walk the tree); the time is kept in <serve dir>/debt-at.
debt_poll() {
  local now last base cfg tmp
  base=$RUN_BASE
  git rev-parse -q --verify "$base^{commit}" >/dev/null 2>&1 || return 0
  cfg=$(git show "$base:.claude/senior-mode.json" 2>/dev/null) || return 0
  jq -e '.maintenance.debt == true and .adopt.kind == "legacy"' <<<"$cfg" >/dev/null 2>&1 || return 0
  now=$(serve_now)
  last=$(cat "$SERVE_DIR/debt-at" 2>/dev/null || true)
  [[ $last =~ ^[0-9]+$ ]] && [ $((now - last)) -lt 3600 ] && return 0
  tmp=$(mktemp -d)
  if git -c core.hooksPath=/dev/null worktree add -q --detach "$tmp/tree" "$base" >/dev/null 2>&1; then
    debt_file "$tmp/tree" || DEBT_FILED=0
    git worktree remove --force "$tmp/tree" >/dev/null 2>&1 || true
  else
    echo "serve: cannot read the base branch; no debt tickets" >&2
    DEBT_FILED=1
  fi
  rm -rf "$tmp"
  git worktree prune >/dev/null 2>&1 || true
  [ "${DEBT_FILED:-0}" -gt 0 ] || state_put "$SERVE_DIR/debt-at" "$now"
}
