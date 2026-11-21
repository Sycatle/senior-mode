#!/usr/bin/env bash
# Tests for `senior-mode statusline` and `senior-mode setup statusline`. Offline: gh would log any call.
set -u
cli=$(cd "$(dirname "$0")/.." && pwd)/senior-mode
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

mkdir -p "$work/stub"
cat >"$work/stub/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$GH_LOG"
exit 1
STUB
chmod +x "$work/stub/gh"
export PATH="$work/stub:$PATH" GH_LOG="$work/gh.log"
unset SENIOR_MODE_RUN

repo="$work/repo"
git init -q -b main "$repo"
mkdir -p "$repo/.claude"
echo '{}' >"$repo/.claude/senior-mode.json"
git -C "$repo" add -A
git -C "$repo" -c user.name=t -c user.email=t@t commit -q -m "chore: start"
git -C "$repo" switch -q -c feat/75-pick-status

line() { (cd "$repo" && "$cli" statusline </dev/null 2>"$work/err"); }
record() { # <state> <description>: a check result for HEAD
  mkdir -p "$repo/.git/senior-mode/checks"
  printf '%s\n%s\n' "$1" "$2" >"$repo/.git/senior-mode/checks/$(git -C "$repo" rev-parse HEAD)"
}

# On a ticket branch, nothing checked yet.
[ "$(line)" = "#75 · no check" ] || fail "no check recorded: '$(line)'"
record success "3/3 checks passed"
[ "$(line)" = "#75 · check ok" ] || fail "passing check: '$(line)'"
record failure "failed: lint"
[ "$(line)" = "#75 · check FAILED" ] || fail "failing check: '$(line)'"
record success "3/3 checks passed"

# An edit after the check makes the result stale.
echo change >"$repo/file.txt"
[ "$(line)" = "#75 · check stale" ] || fail "dirty tree: '$(line)'"
rm "$repo/file.txt"

# A run in progress is shown, and the line never calls GitHub.
[ "$(cd "$repo" && SENIOR_MODE_RUN=1 "$cli" statusline </dev/null)" = "#75 · check ok · run in progress" ] ||
  fail "run in progress"
[ ! -s "$GH_LOG" ] || fail "statusline calls GitHub: $(cat "$GH_LOG")"

# Off a ticket branch the branch name shows; a detached HEAD shows its hash.
git -C "$repo" switch -q main
[ "$(line)" = "main · check ok" ] || fail "default branch: '$(line)'"
git -C "$repo" switch -q --detach
[ "$(line)" = "$(git -C "$repo" rev-parse --short HEAD) · check ok" ] || fail "detached HEAD: '$(line)'"
git -C "$repo" switch -q feat/75-pick-status

# The directory comes from the JSON Claude Code sends on stdin.
out=$(cd "$work" && echo "{\"workspace\": {\"current_dir\": \"$repo\"}}" | "$cli" statusline)
[ "$out" = "#75 · check ok" ] || fail "cwd from stdin: '$out'"

# Silent where senior-mode is not set up, and never an error.
out=$(cd "$work" && "$cli" statusline </dev/null) || fail "outside a repository exits non-zero"
[ -z "$out" ] || fail "outside a repository prints '$out'"
mv "$repo/.claude/senior-mode.json" "$work/cfg"
out=$(line) || fail "no config exits non-zero"
[ -z "$out" ] || fail "no config prints '$out'"
mv "$work/cfg" "$repo/.claude/senior-mode.json"
out=$(cd "$repo" && echo 'not json' | "$cli" statusline) || fail "garbage on stdin exits non-zero"
[ "$out" = "#75 · check ok" ] || fail "garbage on stdin: '$out'"

# setup statusline writes a command that survives plugin updates.
settings="$repo/.claude/settings.json"
echo '{"permissions": {"allow": ["Bash(ls:*)"]}}' >"$settings"
(cd "$repo" && "$cli" setup statusline) >"$work/out" 2>&1 || fail "setup statusline failed: $(cat "$work/out")"
[ "$(jq -r '.statusLine.type' "$settings")" = command ] || fail "no statusLine written: $(cat "$settings")"
[ "$(jq -r '.permissions.allow[0]' "$settings")" = "Bash(ls:*)" ] || fail "other settings lost"
cmd=$(jq -r '.statusLine.command' "$settings")
grep -qE '/(Users|home)/|[0-9]+\.[0-9]+\.[0-9]+' <<<"$cmd" && fail "command hard-codes a path or version: $cmd"
grep -q "senior-mode" "$settings" || fail "command does not name senior-mode"
sum=$(sha256sum "$settings")
(cd "$repo" && "$cli" setup statusline) >"$work/out" 2>&1 || fail "second setup statusline failed"
[ "$(sha256sum "$settings")" = "$sum" ] || fail "setup statusline is not idempotent"
grep -q "already" "$work/out" || fail "second run does not say so: $(cat "$work/out")"

# The command finds the installed plugin: through the registry, whatever the version, else the cache.
home="$work/home"
plugin() { # <dir>: a fake installed plugin whose script prints where it ran from
  mkdir -p "$1/bin"
  cat >"$1/bin/senior-mode" <<'PLUGIN'
#!/bin/sh
echo "ran $(cd "$(dirname "$0")/.." && pwd) $* $(cat)"
PLUGIN
  chmod +x "$1/bin/senior-mode"
}
runcmd() { echo in | HOME="$home" sh -c "$cmd"; }
mkdir -p "$home/.claude/plugins"
plugin "$home/.claude/plugins/cache/mkt/senior-mode/0.2.0"
jq -n --arg p "$home/.claude/plugins/cache/mkt/senior-mode/0.2.0" \
  '{version: 2, plugins: {"other@mkt": [{installPath: "/nowhere"}], "senior-mode@mkt": [{scope: "user", installPath: $p}]}}' \
  >"$home/.claude/plugins/installed_plugins.json"
[ "$(runcmd)" = "ran $home/.claude/plugins/cache/mkt/senior-mode/0.2.0 statusline in" ] || fail "registry lookup: '$(runcmd)'"
plugin "$home/.claude/plugins/cache/mkt/senior-mode/0.3.0"
jq --arg p "$home/.claude/plugins/cache/mkt/senior-mode/0.3.0" '.plugins["senior-mode@mkt"][0].installPath = $p' \
  "$home/.claude/plugins/installed_plugins.json" >"$work/reg" && mv "$work/reg" "$home/.claude/plugins/installed_plugins.json"
[ "$(runcmd)" = "ran $home/.claude/plugins/cache/mkt/senior-mode/0.3.0 statusline in" ] || fail "after an update: '$(runcmd)'"
rm "$home/.claude/plugins/installed_plugins.json"
plugin "$home/.claude/plugins/cache/mkt/senior-mode/0.10.0"
[ "$(runcmd)" = "ran $home/.claude/plugins/cache/mkt/senior-mode/0.10.0 statusline in" ] || fail "cache fallback takes the newest: '$(runcmd)'"
rm -rf "$home/.claude/plugins/cache"
out=$(runcmd) || fail "no plugin installed: the command exits non-zero"
[ -z "$out" ] || fail "no plugin installed prints '$out'"

# A statusLine of the project's own is kept; our own is refreshed.
echo '{"statusLine": {"type": "command", "command": "my-line.sh"}}' >"$settings"
(cd "$repo" && "$cli" setup statusline) >"$work/out" 2>&1 || fail "setup with another statusLine failed"
[ "$(jq -r '.statusLine.command' "$settings")" = my-line.sh ] || fail "another statusLine replaced"
grep -q "kept" "$work/out" || fail "kept not reported: $(cat "$work/out")"
jq -n --arg c "old senior-mode statusline" '{statusLine: {type: "command", command: $c}}' >"$settings"
(cd "$repo" && "$cli" setup statusline) >/dev/null 2>&1 || fail "refresh failed"
[ "$(jq -r '.statusLine.command' "$settings")" = "$cmd" ] || fail "our own statusLine not refreshed"
rm "$settings"
(cd "$repo" && "$cli" setup statusline) >/dev/null 2>&1 || fail "setup without settings.json failed"
[ "$(jq -r '.statusLine.command' "$settings")" = "$cmd" ] || fail "settings.json not created"

[ "$failures" -eq 0 ] && echo "statusline: all cases pass"
exit "$failures"
