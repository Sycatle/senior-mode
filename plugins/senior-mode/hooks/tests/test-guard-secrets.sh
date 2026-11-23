#!/usr/bin/env bash
# Tests for guard-secrets.sh (PreToolUse on Read, Grep, Glob and Bash): JSON in, decision out.
# shellcheck disable=SC2016 # the commands under test are not expanded here
set -u
hook=$(cd "$(dirname "$0")/.." && pwd)/guard-secrets.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

repo="$work/repo"
plain="$work/plain"
mkdir -p "$repo/.claude" "$repo/sub" "$plain"
git init -q -b main "$repo"
echo '{"secrets": ["config/prod.*", "**/vault/*", "*.token"]}' >"$repo/.claude/senior-mode.json"

decide() { # json -> deny or allow
  out=$("$hook" <<<"$1")
  if [ "$(jq -r '.hookSpecificOutput.permissionDecision // empty' <<<"$out" 2>/dev/null)" = deny ]; then
    echo deny
  else
    echo allow
  fi
}
# expect <decision> <tool> <value> [cwd]: value is the command (Bash), file_path (Read), path (Grep, Glob)
# or, for Glob, the pattern.
expect() {
  local json
  case $2 in
    Bash) json=$(jq -nc --arg v "$3" --arg d "${4:-$repo}" '{tool_name: "Bash", tool_input: {command: $v}, cwd: $d}') ;;
    Read) json=$(jq -nc --arg v "$3" --arg d "${4:-$repo}" '{tool_name: "Read", tool_input: {file_path: $v}, cwd: $d}') ;;
    Grep) json=$(jq -nc --arg v "$3" --arg d "${4:-$repo}" '{tool_name: "Grep", tool_input: {pattern: "KEY", path: $v}, cwd: $d}') ;;
    GrepGlob) json=$(jq -nc --arg v "$3" --arg d "${4:-$repo}" '{tool_name: "Grep", tool_input: {pattern: "KEY", glob: $v}, cwd: $d}') ;;
    Glob) json=$(jq -nc --arg v "$3" --arg d "${4:-$repo}" '{tool_name: "Glob", tool_input: {pattern: $v}, cwd: $d}') ;;
    GlobPath) json=$(jq -nc --arg v "$3" --arg d "${4:-$repo}" '{tool_name: "Glob", tool_input: {pattern: "*", path: $v}, cwd: $d}') ;;
  esac
  got=$(decide "$json")
  [ "$got" = "$1" ] || fail "$2 $3${4:+ (in $4)}: expected $1, got $got"
}

# Read: denied
for f in .env .env.local .env.production .env.development.local app/.env "$repo/.env" \
  server.pem certs/site.key id_rsa id_rsa_work id_ed25519 ~/.ssh/id_ed25519 store.p12 cert.pfx \
  .npmrc "$HOME/.npmrc" .netrc credentials.json credentials-prod.json \
  service-account.json service-account-ci.json gcp/service-account-key.json /proc/self/environ; do
  expect deny Read "$f"
done
# Read: allowed
for f in .env.example .env.sample .env.template .env.local.example app/.env.example README.md src/env.ts \
  package.json id_rsa.pub .envrc src/credentials.ts docs/keys.md keyboard.json tsconfig.json; do
  expect allow Read "$f"
done

# Grep and Glob
expect deny Grep .env
expect deny Grep "$repo/certs/site.pem"
expect deny GrepGlob '.env*'
expect deny GrepGlob '**/*.pem'
expect deny GrepGlob '.env.local'
expect allow Grep src
expect allow Grep .env.example
expect allow GrepGlob '*.ts'
expect allow GrepGlob '.env.example'
expect deny Glob '**/.env*'
expect deny Glob '**/*.pem'
expect deny Glob 'id_rsa*'
expect deny Glob '**/credentials*.json'
expect deny GlobPath "$repo/.env"
expect allow Glob '**/*.ts'
expect allow Glob '**/.env.example'
expect allow Glob 'src/**/*.json'
expect allow GlobPath "$repo/src"

# Bash: dumping a file
expect deny Bash 'cat .env'
expect deny Bash 'cat .env.production'
expect deny Bash 'cat < .env'
expect deny Bash 'cat <.env'
expect deny Bash 'cat ".env"'
expect deny Bash "cat '.env.local'"
expect deny Bash 'less .env.local'
expect deny Bash 'head -n 5 .env'
expect deny Bash 'tail -f app/.env'
expect deny Bash 'grep KEY .env'
expect deny Bash 'grep -rn SECRET .env.local src'
expect deny Bash 'rg token .env'
expect deny Bash 'source .env'
expect deny Bash '. .env'
expect deny Bash 'set -a; source .env; set +a'
expect deny Bash 'cat ~/.ssh/id_rsa'
expect deny Bash 'cat "$HOME/.ssh/id_ed25519"'
expect deny Bash 'cat server.pem'
expect deny Bash 'cat certs/site.key | base64'
expect deny Bash 'cat .npmrc'
expect deny Bash 'cat ~/.netrc'
expect deny Bash 'cat credentials.json'
expect deny Bash 'cat config/service-account-prod.json'
expect deny Bash 'cat .env*'
expect deny Bash 'cat /proc/self/environ'
expect deny Bash 'npm test && cat .env; echo done'
expect deny Bash 'echo $(cat .env)'
expect deny Bash 'FOO=1 cat .env'
expect deny Bash 'sudo cat .env'
expect deny Bash $'cat \\\n  .env'
expect deny Bash '/bin/cat .env'

# Bash: dumping the environment
expect deny Bash 'printenv'
expect deny Bash 'printenv STRIPE_SECRET_KEY'
expect deny Bash 'env'
expect deny Bash 'env | grep KEY'
expect deny Bash 'env -0'
expect deny Bash 'set'
expect deny Bash 'set | grep KEY'
expect deny Bash 'export -p'
expect deny Bash 'export'
expect deny Bash 'declare -x'
expect deny Bash 'cd app && env'

# Bash: allowed
expect allow Bash 'cat .env.example'
expect allow Bash 'cat .env.sample .env.template'
expect allow Bash 'source .env.example'
expect allow Bash 'cat README.md'
expect allow Bash 'cat src/env.ts'
expect allow Bash 'grep -rn ".env" README.md'
expect allow Bash 'grep .env README.md'
expect allow Bash 'grep -e .env README.md'
expect allow Bash 'ls -a'
expect allow Bash 'git commit -m "docs: never cat .env or run printenv"'
expect allow Bash 'echo "cat .env; printenv"'
expect allow Bash 'echo cat .env'
expect allow Bash 'env FOO=1 npm test'
expect allow Bash 'env -i bash -c true'
expect allow Bash 'set -euo pipefail'
expect allow Bash 'set -a'
expect allow Bash 'export FOO=1'
expect allow Bash 'export PATH="$PATH:/opt/bin"'
expect allow Bash 'cat ~/.ssh/id_rsa.pub'
expect allow Bash 'ssh-keygen -t ed25519 -f ./id_work'
expect allow Bash 'ls .env'
expect allow Bash 'cat package.json | jq .name'
expect allow Bash 'npm run env'
expect allow Bash 'docker compose --env-file .env up'

# Extra globs from the `secrets` key: slash-less globs match the file name, others the path from the repo root.
expect deny Read "$repo/config/prod.yml"
expect deny Read "$repo/ops/vault/db.txt"
expect deny Read "$repo/sub/deploy.token"
expect deny Read 'config/prod.yml'
expect deny Bash 'cat config/prod.yml'
expect deny Bash 'cat deploy.token' "$repo/sub"
expect deny Glob '**/vault/*'
expect allow Read "$repo/config/dev.yml"
expect allow Read "$repo/src/prod.yml"
expect allow Bash 'cat config/dev.yml'
# Without the key, or outside a configured repository, only the defaults apply.
expect allow Read "$plain/config/prod.yml" "$plain"
expect allow Bash 'cat deploy.token' "$plain"
expect deny Read "$plain/.env" "$plain"
expect deny Bash 'cat .env' "$plain"
# Defaults stay when the key is not an array of strings.
echo '{"secrets": 3}' >"$repo/.claude/senior-mode.json"
expect deny Read "$repo/.env"
expect allow Read "$repo/config/prod.yml"
echo 'not json' >"$repo/.claude/senior-mode.json"
expect deny Read "$repo/.env"
expect allow Read "$repo/config/prod.yml"

# More credential files (#434).
for f in ~/.aws/credentials .aws/credentials ~/.ssh/id_ecdsa ~/.ssh/id_dsa ~/.ssh/id_work id_ecdsa_sk prod.tfvars \
  infra/terraform.tfstate terraform.tfstate.backup ~/.kube/config kubeconfig kubeconfig-prod secrets.yml \
  config/secrets.json .git-credentials ~/.pgpass ~/.docker/config.json; do
  expect deny Read "$f"
done
for f in ~/.ssh/id_work.pub ~/.ssh/known_hosts ~/.ssh/config prod.tfvars.example main.tf secrets.example.yml \
  secrets.yml.example secrets.sample secrets.template src/secrets.ts lib/secrets.py .docker/Dockerfile kube/config.md; do
  expect allow Read "$f"
done
expect deny Glob '**/*.tfstate'
expect deny Bash 'cat ~/.aws/credentials'
expect deny Bash 'head -5 infra/prod.tfvars'

# Business data (#433): the built-in names, as no `data` key is set here.
for f in app.sqlite app.sqlite3 data/prod.db backup.dump nightly.bak legacy.mdb legacy.accdb; do
  expect deny Read "$f"
done
for f in db/migrations/001_init.sql schema.prisma src/db.ts dbconfig.json; do
  expect allow Read "$f"
done
content() { jq -nc --arg v "$1" --arg m "$2" --arg d "$repo" '{tool_name: "Grep", tool_input: {pattern: "x", glob: $v, output_mode: $m}, cwd: $d}'; }
[ "$(decide "$(content '*.db' content)")" = deny ] || fail "Grep content on *.db allowed"
[ "$(decide "$(content '*.db' files_with_matches)")" = allow ] || fail "Grep files_with_matches on *.db denied"
[ "$(decide "$(content '*.db' count)")" = allow ] || fail "Grep count on *.db denied"
expect allow GrepGlob '*.db'
expect allow Glob '**/*.db'
expect allow GlobPath "$repo/data/prod.db"
expect deny Bash 'sqlite3 data/prod.db "select count(*) from users"'
expect deny Bash 'duckdb export.db'
expect deny Bash 'cat backup.dump | wc -l'
expect allow Bash 'ls -la data/prod.db'
expect allow Bash 'stat backup.dump'
expect allow Bash 'sqlite3 :memory: "select 1"'
reason=$(jq -r '.hookSpecificOutput.permissionDecisionReason' \
  <<<"$("$hook" <<<"$(jq -nc --arg d "$repo" '{tool_name: "Read", tool_input: {file_path: "app.db"}, cwd: $d}')")")
grep -q 'synthetic fixture' <<<"$reason" || fail "data reason does not point to a fixture: $reason"
# A `data` key replaces the built-in names.
datarepo=$work/datarepo
mkdir -p "$datarepo/.claude"
git init -q -b main "$datarepo"
echo '{"data": ["exports/**", "*.csv"]}' >"$datarepo/.claude/senior-mode.json"
expect deny Read "$datarepo/exports/2026/customers.json" "$datarepo"
expect deny Read customers.csv "$datarepo"
expect allow Read app.db "$datarepo"
expect allow Read .env.example "$datarepo"
expect deny Read .env "$datarepo"

# Other tools and empty input are left alone.
[ "$(decide '{"tool_name": "Edit", "tool_input": {"file_path": ".env"}, "cwd": "/tmp"}')" = allow ] || fail "Edit denied"
[ "$(decide '{}')" = allow ] || fail "empty input denied"

# The deny reason says why and what to do instead.
reason=$(jq -r '.hookSpecificOutput.permissionDecisionReason' \
  <<<"$("$hook" <<<"$(jq -nc --arg d "$repo" '{tool_name: "Read", tool_input: {file_path: ".env"}, cwd: $d}')")")
grep -qi secret <<<"$reason" || fail "reason does not say why: $reason"
grep -qi human <<<"$reason" || fail "reason does not say to ask the human: $reason"
grep -q '\.env\.example' <<<"$reason" || fail "reason does not point to .env.example: $reason"
reason=$(jq -r '.hookSpecificOutput.permissionDecisionReason' \
  <<<"$("$hook" <<<"$(jq -nc --arg d "$repo" '{tool_name: "Bash", tool_input: {command: "printenv"}, cwd: $d}')")")
grep -qi human <<<"$reason" || fail "environment reason does not say to ask the human: $reason"
grep -q '\.env\.example' <<<"$reason" || fail "environment reason does not point to .env.example: $reason"

# Registered for the tools it guards.
jq -e '.hooks.PreToolUse[] | select(.hooks[].command | contains("guard-secrets.sh"))
  | .matcher | split("|") | contains(["Read", "Grep", "Glob", "Bash"])' "$(dirname "$hook")/hooks.json" >/dev/null ||
  fail "guard-secrets.sh is not registered in hooks.json for Read, Grep, Glob and Bash"

[ "$failures" -eq 0 ] && echo "guard-secrets: all cases pass"
exit "$failures"
