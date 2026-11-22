#!/usr/bin/env bash
# Tests for the secret scan of `senior-mode check` (#143): the added lines of <base>...HEAD against the
# patterns of the plugin, lifted by an allowlist read from the base. Offline. The secrets below are built
# at run time from pieces, so that this file holds none and push protection has nothing to flag.
set -u
cli=$(cd "$(dirname "$0")/.." && pwd)/senior-mode
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }
rep() { local s="" k; for ((k = 0; k < $2; k++)); do s+=$1; done; printf %s "$s"; }
git_() { git -C "$repo" -c user.name=t -c user.email=t@t "$@"; }
run() { (cd "$repo" && "$cli" check) >"$work/out" 2>&1; }
sha() { printf %s "$1" | sha256sum | cut -d' ' -f1; }

repo="$work/repo"
git init -q -b main "$repo"
mkdir -p "$repo/.claude" "$repo/src"
echo '{"checks":[{"name":"lint","run":"true"}]}' >"$repo/.claude/senior-mode.json"
printf 'one\ntwo\nthree\n' >"$repo/src/app.txt"
git_ add -A
git_ commit -q -m "chore: base"

n=0
# branch <file> <content>: a branch off main whose only commit writes the content into the file.
branch() {
  n=$((n + 1))
  git_ checkout -q main
  git_ checkout -q -b "t$n"
  mkdir -p "$(dirname "$repo/$1")"
  printf '%s\n' "$2" >>"$repo/$1"
  git_ add -A
  git_ commit -q -m "feat: change $n"
}

# kind <label> <value> <line>: the scan fails naming file, line and kind, and never prints the value.
kind() {
  branch src/app.txt "$3"
  run && fail "$1: the scan passes on $1"
  grep -q "^FAIL  secret scan$" "$work/out" || fail "$1: scan not reported as failed: $(cat "$work/out")"
  grep -q "src/app.txt:4: $1" "$work/out" || fail "$1: file, line and kind not given: $(cat "$work/out")"
  ! grep -qF -- "$2" "$work/out" || fail "$1: the secret is printed: $(cat "$work/out")"
}

p=AKIA
aws="${p}$(rep Q7ZK2M9X 2)"
kind "AWS access key" "$aws" "aws = $aws"
p=ghp_
gh="${p}$(rep aB3x9Zq2 5)"
kind "GitHub token" "$gh" "export GH=$gh"
p=sk_live_
stripe="${p}$(rep aB3x9Zq2 3)"
kind "Stripe key" "$stripe" "stripe: $stripe"
p=xoxb-
slack="${p}123456789012-$(rep aB3x9Zq2 3)"
kind "Slack token" "$slack" "SLACK=$slack"
p=AIza
google="${p}$(rep aB3x9Zq2 4)xyz"
kind "Google API key" "$google" "key: $google"
p=sk-
openai="${p}$(rep aB3x9Zq2 5)"
kind "OpenAI key" "$openai" "OPENAI=$openai"
p=sk-ant-api03-
anthropic="${p}$(rep aB3x9Zq2 5)"
kind "Anthropic key" "$anthropic" "ANTHROPIC=$anthropic"
p='-----BEGIN RSA '
key="${p}PRIVATE KEY-----"
kind "private key" "$key" "$key"
generic=$(rep Zx9kQ4mW 2)
kind "generic secret" "$generic" "  password = \"$generic\""
kind "generic secret" "$generic" "API_TOKEN=$generic"

# A hunk in the middle of a file: the line number is the one of the new file, and a deleted line does not shift it.
git_ checkout -q main
printf 'a\nb\nc\nd\ne\nf\ng\nh\n' >"$repo/src/long.txt"
git_ add -A
git_ commit -q -m "chore: long file"
git_ checkout -q -b mid
sed -i -e '2d' -e "5a token=$generic" "$repo/src/long.txt"
git_ commit -q -a -m "feat: mid"
run && fail "a secret in the middle of a file passes"
grep -q "src/long.txt:5: generic secret" "$work/out" || fail "wrong line number: $(cat "$work/out")"
# An added line that starts with "++" is a line, not a file header.
git_ checkout -q main
branch src/app.txt "++ plus plus"
printf '+++ b/other\n' >>"$repo/src/app.txt"
printf '%s\n' "x = $aws" >>"$repo/src/app.txt"
git_ commit -q -a -m "feat: plus"
run && fail "a secret after a '+++' line passes"
grep -q "src/app.txt:6: AWS access key" "$work/out" || fail "a '+++' line shifted the report: $(cat "$work/out")"

# A clean change passes and the scan shows as ok; names that only look like secrets are not flagged.
branch src/app.txt 'password = process.env.DB_PASSWORD_1'
run || fail "an environment lookup is flagged: $(cat "$work/out")"
grep -q "^ok    secret scan$" "$work/out" || fail "ok not shown: $(cat "$work/out")"
for line in 'password = "changeme"' 'token = "your-token-here"' 'secret = "<generated at deploy>"' 'const token = getToken()'; do
  branch src/app.txt "$line"
  run || fail "placeholder flagged: $line: $(cat "$work/out")"
done

# Only lines added since the base are read: a secret already on the base, or removed by the branch, passes.
git_ checkout -q main
echo "old = $aws" >>"$repo/src/app.txt"
git_ commit -q -a -m "chore: old secret on main"
git_ checkout -q -b touch
echo "more" >>"$repo/src/app.txt"
git_ commit -q -a -m "feat: touch"
run || fail "a secret already on the base fails the branch: $(cat "$work/out")"
git_ checkout -q -b drop
sed -i '$d' "$repo/src/app.txt"
sed -i "/^old = /d" "$repo/src/app.txt"
git_ commit -q -a -m "fix: drop it"
run || fail "removing a secret fails the branch: $(cat "$work/out")"
git_ checkout -q main
git_ reset -q --hard HEAD~1

# The allowlist is read from the base: a sha256 and a reason lift the finding.
allow() { # line...: committed on main
  git_ checkout -q main
  printf '%s\n' "$@" >"$repo/.claude/secret-allowlist"
  git_ add -A
  git_ commit -q -m "chore: allowlist"
}
allow "# fixtures" "$(sha "$aws") test fixture of the AWS parser"
branch src/app.txt "aws = $aws"
run || fail "an allowlisted secret fails: $(cat "$work/out")"
branch src/app.txt "other = $gh"
run && fail "the allowlist lifts another secret"
# A pull request cannot allowlist its own secret.
allow "# fixtures"
branch src/app.txt "aws = $aws"
printf '%s test\n' "$(sha "$aws")" >"$repo/.claude/secret-allowlist"
git_ add -A
git_ commit -q -m "chore: allowlist my own secret"
run && fail "a branch allowlisted its own secret"
# An entry needs a reason.
allow "$(sha "$aws")"
branch src/app.txt "aws = $aws"
run && fail "an allowlist entry without a reason lifts the finding"

# No base branch to compare with: the scan says so and skips.
other="$work/other"
git init -q -b trunk "$other"
mkdir "$other/.claude"
echo '{"checks":[{"name":"lint","run":"true"}]}' >"$other/.claude/senior-mode.json"
echo "aws = $aws" >"$other/a.txt"
git -C "$other" add -A
git -C "$other" -c user.name=t -c user.email=t@t commit -q -m "chore: init"
(cd "$other" && "$cli" check) >"$work/out" 2>&1 || fail "check fails with no base branch: $(cat "$work/out")"
grep -q "^skip  secret scan: no base branch$" "$work/out" || fail "skip not reported: $(cat "$work/out")"

[ "$failures" -eq 0 ] && echo "secret scan: all cases pass"
exit "$failures"
