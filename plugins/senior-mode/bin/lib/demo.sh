# shellcheck shell=bash
# `senior-mode demo` (#806, spec §8.3, ADR 0025): the whole flow on a throwaway private repository, three toy tickets, about
# five minutes. Progress is recorded in demo.json, so an interrupted demo resumes. Definitions only.
#
# demo.json, in ${XDG_DATA_HOME:-~/.local/share}/senior-mode: {"repositories": [{repo, created, step, finished, issues}]}.
# `step` is the last narrated step of 7: 1 repository seeded, 2 setup, 3 tickets filed, 4 serve started, 5-7 a ticket delivered.
# Test hooks: SENIOR_MODE_DEMO_CLI (the senior-mode command, default this one), SENIOR_MODE_DEMO_POLL (seconds between two
# looks at the pull requests, default 10) and SENIOR_MODE_DEMO_TIMEOUT (seconds before the wait gives up, default 1800).

DEMO_MARKER="senior-mode demo (throwaway)"

demo_file() { printf '%s\n' "${XDG_DATA_HOME:-$HOME/.local/share}/senior-mode/demo.json"; }

# The recorded repository that is not finished (a new demo starts only when there is none): its JSON, else nothing.
demo_current() {
  jq -c '[.repositories[]? | select(.finished | not)] | first // empty' "$(demo_file)" 2>/dev/null || true
}

# demo_record <repo> <jq filter>: applies the filter to the entry of <repo>.
demo_record() {
  local file
  file=$(demo_file)
  mkdir -p "$(dirname "$file")"
  [ -f "$file" ] || echo '{"repositories": []}' >"$file"
  jq --arg r "$1" "(.repositories[] | select(.repo == \$r)) |= ($2)" "$file" | state_write "$file"
}

# [k/7] text, N s: N is the time since the previous line.
demo_say() {
  echo "[$1/7] $2, $((SECONDS - DEMO_T0)) s"
  DEMO_T0=$SECONDS
}

demo_confirm() {
  local answer
  if [ "$1" = true ]; then return 0; fi
  [ -t 0 ] || die "demo: no terminal to confirm and no --yes: nothing was created"
  printf 'Continue? [y/N] '
  read -r answer || answer=""
  [[ $answer == [yY] || $answer == [yY][eE][sS] ]] || die "demo: cancelled, nothing was created"
}

# The tiny shell project the tickets are about: its test runner is test.sh.
demo_seed() {
  mkdir -p lib tests
  cat >README.md <<'FILE'
# senior-mode demo

A tiny shell project for the senior-mode demo. `./test.sh` runs every `tests/test-*.sh`.
FILE
  cat >lib/greet.sh <<'FILE'
greet() { printf 'Hello, %s!\n' "${1:-world}"; }
FILE
  cat >lib/slug.sh <<'FILE'
# A lowercase, dash-separated form of a title.
slugify() { printf '%s' "$1" | tr 'A-Z ' 'a-z-' | tr -cd 'a-z-'; echo; }
FILE
  cat >tests/test-greet.sh <<'FILE'
#!/usr/bin/env bash
cd "$(dirname "$0")/.." || exit 1
. lib/greet.sh
[ "$(greet Ada)" = "Hello, Ada!" ] || { echo "FAIL: greet Ada"; exit 1; }
[ "$(greet)" = "Hello, world!" ] || { echo "FAIL: greet"; exit 1; }
FILE
  cat >test.sh <<'FILE'
#!/usr/bin/env bash
# Runs every tests/test-*.sh; fails when one does.
cd "$(dirname "$0")" || exit 1
rc=0
for t in tests/test-*.sh; do bash "$t" || rc=1; done
exit "$rc"
FILE
  chmod +x test.sh tests/test-greet.sh
}

# demo_tickets: one line per toy ticket: type|title|paths|body (\n for a line break).
demo_tickets() {
  cat <<'LIST'
feature|feat: farewell prints a goodbye|lib/farewell.sh,tests/test-farewell.sh|Add `farewell <name>` in `lib/farewell.sh`: it prints `Goodbye, <name>!` (`Goodbye, world!` without a name), with a test in `tests/test-farewell.sh`.\n\n## Acceptance criteria\n- Given `farewell Ada`, when it runs, then it prints `Goodbye, Ada!`.\n- Given no name, then it prints `Goodbye, world!`.
feature|feat: shout prints a greeting in capitals|lib/shout.sh,tests/test-shout.sh|Add `shout <name>` in `lib/shout.sh`: it prints the greeting of `greet` in capitals, with a test in `tests/test-shout.sh`.\n\n## Acceptance criteria\n- Given `shout Ada`, when it runs, then it prints `HELLO, ADA!`.\n- Given no name, then it prints `HELLO, WORLD!`.
bug|fix: slugify drops the digits|lib/slug.sh,tests/test-slug.sh|`slugify "Release 2 notes"` prints `release--notes`: the digits are lost.\n\nFailing test, to add as `tests/test-slug.sh` (it fails today):\n\n```bash\n#!/usr/bin/env bash\ncd "$(dirname "$0")/.." || exit 1\n. lib/slug.sh\n[ "$(slugify "Release 2 notes")" = "release-2-notes" ] || { echo "FAIL: slugify keeps digits"; exit 1; }\n```\n\n## Acceptance criteria\n- Given `slugify "Release 2 notes"`, when it runs, then it prints `release-2-notes`.
LIST
}

# demo_stop_serve <pid>: TERM, then KILL after 30 s.
demo_stop_serve() {
  local i
  kill -TERM "$1" 2>/dev/null || return 0
  for i in $(seq 1 150); do
    kill -0 "$1" 2>/dev/null || break
    sleep 0.2
  done
  kill -KILL "$1" 2>/dev/null || true
  wait "$1" 2>/dev/null || true
}

# senior-mode demo [--yes] [--budget <usd>]
demo() {
  local yes=false budget=3 login cur repo cli data dir log step title paths body type k out num
  local now pid merged delivered total poll limit started
  while [ $# -gt 0 ]; do
    case $1 in
      --yes) yes=true; shift ;;
      --budget) [ $# -ge 2 ] || usage; budget=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  [[ $budget =~ ^[0-9]+(\.[0-9]+)?$ ]] && awk -v b="$budget" 'BEGIN { exit !(b > 0) }' ||
    die "demo: --budget is a number of USD above 0, not '$budget'"
  cli=${SENIOR_MODE_DEMO_CLI:-$SELF}
  data=${XDG_DATA_HOME:-$HOME/.local/share}/senior-mode/demo
  poll=${SENIOR_MODE_DEMO_POLL:-10}
  limit=${SENIOR_MODE_DEMO_TIMEOUT:-1800}
  cur=$(demo_current)
  if [ -n "$cur" ]; then
    repo=$(jq -r .repo <<<"$cur")
    step=$(jq -r .step <<<"$cur")
    echo "senior-mode demo resumes on $repo (step $step of 7)."
  else
    login=$(gh_retry api user --jq .login) || die "demo: cannot read the GitHub account"
    repo=$login/senior-mode-demo-$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')
    step=0
    cat <<PLAN
senior-mode demo will create, on your GitHub account:
  - a private repository $repo ("$DEMO_MARKER")
  - a tiny shell project with its test script, and three toy tickets (two features, one bug)
  - the senior-mode setup of that repository (project board, labels, ruleset)
  then run serve on it (3 sessions at a time, merge on, day cap $budget USD) until the three pull requests are merged.
It takes about five minutes and spends subscription time of this machine. \`senior-mode demo --clean\` is not available yet.
PLAN
  fi
  demo_confirm "$yes"
  DEMO_T0=$SECONDS
  dir=$data/${repo#*/}
  log=$data/${repo#*/}.serve.log
  mkdir -p "$data"
  if [ -z "$cur" ]; then
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    demo_record_new "$repo" "$now"
  fi

  if [ "$step" -lt 1 ]; then
    gh_retry repo view "$repo" >/dev/null 2>&1 ||
      gh_retry repo create "$repo" --private --description "$DEMO_MARKER" >/dev/null || die "demo: cannot create $repo"
    [ -d "$dir/.git" ] || gh_retry repo clone "$repo" "$dir" >/dev/null || die "demo: cannot clone $repo"
    if ! git -C "$dir" rev-parse -q --verify HEAD >/dev/null 2>&1; then
      (cd "$dir" && demo_seed && git add -A && git commit -q -m "chore: seed the demo project" &&
        git branch -M main && git push -q -u origin main) || die "demo: cannot seed $repo"
    fi
    demo_record "$repo" '.step = 1'
    step=1
    demo_say 1 "repository $repo created and seeded"
  fi

  if [ "$step" -lt 2 ]; then
    (cd "$dir" && "$cli" setup github) || die "demo: setup github failed on $repo"
    (cd "$dir" && "$cli" setup repo) || die "demo: setup repo failed on $repo"
    (cd "$dir" && git add -A && { git diff --cached --quiet || git commit -q -m "chore: set up senior-mode"; } &&
      git push -q origin HEAD:main) || die "demo: cannot push the setup of $repo"
    demo_record "$repo" '.step = 2'
    step=2
    demo_say 2 "senior-mode set up on the repository"
  fi

  if [ "$step" -lt 3 ]; then
    while IFS='|' read -r type title paths body; do
      [ "$(jq -r --arg t "$title" '[.repositories[] | select(.repo == $ARGS.positional[0]) | .issues[] | select(.title == $t)] | length' \
        --args "$repo" <"$(demo_file)")" = 0 ] || continue
      out=$(cd "$dir" && printf '%b\n' "$body" >"$dir/.demo-body" &&
        "$cli" issue create --title "$title" --body-file .demo-body --size S --priority P2 --status Ready \
          --type "$type" --paths "$paths" </dev/null) || die "demo: could not file '$title'"
      rm -f "$dir/.demo-body"
      num=$(sed -nE 's/^#([0-9]+) .*/\1/p' <<<"$out" | head -1)
      [ -n "$num" ] || die "demo: could not read the number of '$title' from: $out"
      demo_record "$repo" ".issues += [{title: \"$title\", number: $num}]"
      fault_point demo-issue
    done < <(demo_tickets)
    demo_record "$repo" '.step = 3'
    step=3
    demo_say 3 "three tickets filed"
  fi

  mkdir -p "$dir/.claude"
  jq -n '{autonomy: {parallel: 3, merge: true}}' >"$dir/.claude/senior-mode.local.json"
  if declare -F sandbox_enabled >/dev/null && sandbox_enabled; then export SENIOR_MODE_SANDBOX=1; fi
  (cd "$dir" && SENIOR_MODE_DAY_BUDGET_USD=$budget exec "$cli" serve) >"$log" 2>&1 &
  pid=$!
  if [ "$step" -lt 4 ]; then
    demo_record "$repo" '.step = 4'
    step=4
    demo_say 4 "serve started: 3 sessions at a time, merge on, day cap $budget USD"
  fi

  delivered=$((step - 4))
  started=$SECONDS
  merged='[]'
  while [ "$delivered" -lt 3 ]; do
    merged=$(gh_retry pr list --repo "$repo" --state merged --json number,url,closingIssuesReferences \
      --jq 'sort_by(.number) | map({number, url, ticket: (.closingIssuesReferences[0].number // .number)})') || merged='[]'
    total=$(jq 'length' <<<"$merged")
    while [ "$delivered" -lt "$total" ] && [ "$delivered" -lt 3 ]; do
      delivered=$((delivered + 1))
      k=$((4 + delivered))
      demo_record "$repo" ".step = $k"
      demo_say "$k" "ticket #$(jq -r ".[$((delivered - 1))].ticket" <<<"$merged") delivered"
    done
    [ "$delivered" -lt 3 ] || break
    if [ $((SECONDS - started)) -ge "$limit" ]; then
      demo_stop_serve "$pid"
      die "demo: $delivered of 3 tickets delivered after $limit s; rerun senior-mode demo to resume (serve log: $log)"
    fi
    kill -0 "$pid" 2>/dev/null || die "demo: serve stopped before the tickets were delivered (serve log: $log)"
    sleep "$poll"
  done
  demo_stop_serve "$pid"
  demo_record "$repo" '.finished = true'
  echo "senior-mode demo done."
  echo "https://github.com/$repo"
  gh_retry pr list --repo "$repo" --state merged --json number,url --jq 'sort_by(.number)[].url'
}

# demo_record_new <repo> <created>: the entry of a demo that starts.
demo_record_new() {
  local file
  file=$(demo_file)
  mkdir -p "$(dirname "$file")"
  [ -f "$file" ] || echo '{"repositories": []}' >"$file"
  jq --arg r "$1" --arg c "$2" '.repositories += [{repo: $r, created: $c, step: 0, finished: false, issues: []}]' "$file" | state_write "$file"
}
