#!/usr/bin/env bash
# Tests for deploy.previews (#542): `setup answers --previews`, `setup repo` on stub Vercel, Netlify and Cloudflare Pages
# projects, the ignore step, `setup remove`'s undo, and `senior-mode preview`. Offline: gh is a stub, origin a bare repository.
# shellcheck disable=SC2016 # stub bodies and TOML text, not expanded here
set -u
cli=$(cd "$(dirname "$0")/.." && pwd)/senior-mode
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

mkdir -p "$work/stub"
cat >"$work/stub/gh" <<'STUB'
#!/usr/bin/env bash
jqf="" prev=""
for a in "$@"; do [ "$prev" = --jq ] && jqf=$a; prev=$a; done
case "$*" in
  "pr view "*) echo "{\"state\": \"${PR_STATE:-OPEN}\", \"headRefOid\": \"${PR_HEAD:-none}\"}" | jq -r "$jqf" ;;
  *) echo "gh stub: unexpected call: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$work/stub/gh"
export PATH="$work/stub:$PATH" HOME="$work/home" SENIOR_MODE_RETRY_DELAY=0 LANG=C LC_ALL=C
mkdir -p "$HOME"

origin="$work/github.com/acme/app.git"
repo="$work/app"
git init -q --bare -b main "$origin"
git init -q -b main "$repo"
git -C "$repo" remote add origin "$origin"
g() { git -C "$repo" -c core.hooksPath=/dev/null -c user.name=t -c user.email=t@t "$@"; }
sm() { (cd "$repo" && "$cli" "$@"); }
files_sum() { (cd "$repo" && sha1sum vercel.json netlify.toml .claude/senior-mode/ignore-build.sh 2>/dev/null); }

mkdir -p "$repo/.claude"
echo '{"language": "en"}' >"$repo/.claude/senior-mode.json"
cat >"$repo/vercel.json" <<'JSON'
{
  "$schema": "https://openapi.vercel.sh/vercel.json",
  "git": { "deploymentEnabled": { "dev": false } }
}
JSON
cat >"$repo/netlify.toml" <<'TOML'
[build]
  command = "npm run build"
  ignore = "exit 7"

[[redirects]]
  from = "/a"
  to = "/b"
TOML
printf 'name = "site"\npages_build_output_dir = "dist"\n' >"$repo/wrangler.toml"
cp "$repo/vercel.json" "$work/vercel.orig"
cp "$repo/netlify.toml" "$work/netlify.orig"
g add -A
g commit -q -m "chore: init"
g push -q origin main

# Detection lists the three platforms; the default changes nothing in their files.
sm setup detect --json | jq -e '.deploy.platforms == ["vercel","netlify","cloudflare-pages"]' >/dev/null || fail "platforms not detected"
sm setup detect | grep -q '^hosted previews: vercel, netlify, cloudflare-pages$' || fail "detect text without the platforms"
out=$(sm setup answers --dry-run)
grep -q 'previews: platform (kept; ready recommended' <<<"$out" || fail "no recommendation of ready: $out"
sm setup answers >/dev/null || fail "answers failed"
jq -e 'has("deploy") | not' "$repo/.claude/senior-mode.json" >/dev/null || fail "answers wrote deploy without an answer"
sm setup repo --command test=true >"$work/out" 2>&1 || fail "setup repo failed: $(cat "$work/out")"
{ cmp -s "$repo/vercel.json" "$work/vercel.orig" && cmp -s "$repo/netlify.toml" "$work/netlify.orig"; } || fail "the default changed the platform files"
[ ! -e "$repo/.claude/senior-mode/ignore-build.sh" ] || fail "the default wrote the ignore script"
grep -q '^previews:' "$work/out" && fail "the default talks about previews: $(cat "$work/out")"

# ready: Vercel git.deploymentEnabled, Netlify ignore composed with the project's, Cloudflare steps, the script.
sm setup answers --previews bogus >/dev/null 2>&1 && fail "a bad previews value accepted"
sm setup answers --previews ready >/dev/null || fail "answers --previews ready failed"
[ "$(jq -r .deploy.previews "$repo/.claude/senior-mode.json")" = ready ] || fail "deploy.previews not written"
sm config validate >/dev/null 2>"$work/err" || fail "config invalid with deploy.previews: $(cat "$work/err")"
sm setup repo >"$work/out" 2>&1 || fail "setup repo (ready) failed: $(cat "$work/out")"
jq -e '.git.deploymentEnabled | .dev == false and .["*/[0-9]*"] == false and .["preview/**"] == true' "$repo/vercel.json" >/dev/null ||
  fail "vercel.json: $(cat "$repo/vercel.json")"
jq -e '."$schema" != null' "$repo/vercel.json" >/dev/null || fail "vercel.json lost its keys"
grep -q '^  ignore = "sh \$(git rev-parse --show-toplevel)/.claude/senior-mode/ignore-build.sh || (exit 7)"$' "$repo/netlify.toml" ||
  fail "netlify.toml ignore not composed: $(cat "$repo/netlify.toml")"
{ grep -q 'command = "npm run build"' "$repo/netlify.toml" && grep -q '^\[\[redirects\]\]' "$repo/netlify.toml"; } || fail "netlify.toml lost content"
grep -q '^cloudflare-pages: no file controls it.*Include preview/\*' "$work/out" || fail "no Cloudflare steps: $(cat "$work/out")"
for url in vercel.com/docs/project-configuration/git-configuration docs.netlify.com/configure-builds/ignore-builds developers.cloudflare.com/pages/configuration/branch-build-controls; do
  grep -q "$url" "$work/out" || fail "docs link $url not printed"
done
[ -x "$repo/.claude/senior-mode/ignore-build.sh" ] || fail "script missing or not executable"

# The ignore step as Netlify runs it (exit 0 skips the build): work branches skip, production and others build,
# the preview ref builds, the project's own command still decides what ours lets through.
step=$(sed -n 's/^  ignore = "\(.*\)"$/\1/p' "$repo/netlify.toml")
run_step() { (cd "$repo" && env -u CONTEXT -u VERCEL_ENV "$@" sh -c "$step"); }
rc=0; run_step BRANCH=feat/542-previews || rc=$?; [ "$rc" -eq 0 ] || fail "a work branch builds (ready)"
rc=0; run_step BRANCH=fix/12 || rc=$?; [ "$rc" -eq 0 ] || fail "a work branch without slug builds"
rc=0; run_step BRANCH=main || rc=$?; [ "$rc" -eq 7 ] || fail "the default branch does not reach the project's own command"
rc=0; run_step BRANCH=feat/542-previews CONTEXT=production || rc=$?; [ "$rc" -eq 7 ] || fail "a production context is skipped"
rc=0; run_step BRANCH=preview/feat/542-previews || rc=$?; [ "$rc" -eq 7 ] || fail "the preview ref is skipped (ready)"
rc=0; run_step BRANCH=my-experiment || rc=$?; [ "$rc" -eq 7 ] || fail "a branch of a human is skipped"
rc=0; (cd "$repo" && BRANCH=preview/feat/1-x sh .claude/senior-mode/ignore-build.sh) || rc=$?; [ "$rc" -eq 1 ] || fail "script: preview ref does not build"
rc=0; (cd "$repo" && BRANCH=feat/1-x sh .claude/senior-mode/ignore-build.sh) || rc=$?; [ "$rc" -eq 0 ] || fail "script: work branch builds"
rc=0; (cd "$repo" && VERCEL_GIT_COMMIT_REF=feat/1-x sh .claude/senior-mode/ignore-build.sh) || rc=$?; [ "$rc" -eq 0 ] || fail "script: Vercel branch variable not read"
rc=0; (cd "$repo" && sh .claude/senior-mode/ignore-build.sh) || rc=$?; [ "$rc" -eq 1 ] || fail "script: unknown branch skipped"

# Idempotent.
files_sum >"$work/sum1"
sm setup repo >/dev/null 2>&1 || fail "rerun failed"
files_sum | cmp -s - "$work/sum1" || fail "rerun changed the files"
[ "$(grep -c 'senior-mode/ignore-build.sh' "$repo/netlify.toml")" = 1 ] || fail "ignore composed twice"

# off: no preview ref either; Vercel loses its `preview/**` key, Netlify keeps one composed command.
sm setup answers --previews off >/dev/null
sm setup repo >/dev/null 2>&1 || fail "setup repo (off) failed"
jq -e '.git.deploymentEnabled | has("preview/**") | not' "$repo/vercel.json" >/dev/null || fail "off keeps the preview ref key"
rc=0; (cd "$repo" && BRANCH=preview/feat/1-x sh .claude/senior-mode/ignore-build.sh) || rc=$?; [ "$rc" -eq 0 ] || fail "script off: preview ref builds"
[ "$(grep -c 'senior-mode/ignore-build.sh' "$repo/netlify.toml")" = 1 ] || fail "off composed twice"
sm preview | grep -q 'previews: off: nothing to request' || fail "preview under off"

# Back to platform: the files are what they were.
sm setup answers --previews platform >/dev/null
jq -e 'has("deploy") | not' "$repo/.claude/senior-mode.json" >/dev/null || fail "platform left the deploy key"
sm setup repo >"$work/out" 2>&1 || fail "setup repo (platform) failed"
[ "$(jq -S . "$repo/vercel.json")" = "$(jq -S . "$work/vercel.orig")" ] || fail "vercel.json not restored: $(cat "$repo/vercel.json")"
cmp -s "$repo/netlify.toml" "$work/netlify.orig" || fail "netlify.toml not restored: $(cat "$repo/netlify.toml")"
[ ! -e "$repo/.claude/senior-mode/ignore-build.sh" ] || fail "script left"
sm preview | grep -q 'previews: platform: nothing to request' || fail "preview under platform"

# Other shapes: no [build] table, files that only exist as folders, an ignore command senior-mode cannot compose, vercel.ts.
other="$work/other"
git init -q -b main "$other"
mkdir -p "$other/.claude" "$other/.netlify" "$other/.vercel"
echo '{"language": "en", "deploy": {"previews": "off"}}' >"$other/.claude/senior-mode.json"
printf '[[redirects]]\n  from = "/a"\n  to = "/b"\n' >"$other/netlify.toml"
cp "$other/netlify.toml" "$work/other.orig"
(cd "$other" && "$cli" setup repo --command test=true) >"$work/out" 2>&1 || fail "other: setup repo failed: $(cat "$work/out")"
{ grep -q '^\[build\]$' "$other/netlify.toml" && grep -q '^# senior-mode:previews$' "$other/netlify.toml"; } || fail "no [build] table made: $(cat "$other/netlify.toml")"
jq -e '.git.deploymentEnabled["*/[0-9]*"] == false' "$other/vercel.json" >/dev/null || fail "vercel.json not made from the .vercel folder"
(cd "$other" && "$cli" setup repo) >/dev/null 2>&1
[ "$(grep -c '^\[build\]' "$other/netlify.toml")" = 1 ] || fail "[build] added twice"
jq '.deploy.previews = "platform"' "$other/.claude/senior-mode.json" >"$work/c" && mv "$work/c" "$other/.claude/senior-mode.json"
(cd "$other" && "$cli" setup repo) >/dev/null 2>&1 || fail "other: restore failed"
cmp -s "$other/netlify.toml" "$work/other.orig" || fail "netlify.toml with no [build] not restored: $(cat "$other/netlify.toml")"
[ ! -e "$other/vercel.json" ] || fail "vercel.json made by setup not removed"

odd="$work/odd"
git init -q -b main "$odd"
mkdir -p "$odd/.claude"
echo '{"language": "en", "deploy": {"previews": "ready"}}' >"$odd/.claude/senior-mode.json"
printf '[build]\n  ignore = """\n  exit 1\n  """\n' >"$odd/netlify.toml"
: >"$odd/vercel.ts"
cp "$odd/netlify.toml" "$work/odd.orig"
(cd "$odd" && "$cli" setup repo --command test=true) >"$work/out" 2>&1 || fail "odd: setup repo failed: $(cat "$work/out")"
cmp -s "$odd/netlify.toml" "$work/odd.orig" || fail "an ignore command that cannot be composed was changed"
grep -q 'cannot compose' "$work/out" || fail "no word on the command left alone: $(cat "$work/out")"
grep -q 'vercel.ts is code' "$work/out" || fail "no word on vercel.ts"

# setup remove: the dry run lists the preview settings, and what it takes out is what setup added.
# shellcheck disable=SC1090,SC1091
(
  set +e
  # shellcheck disable=SC2034 # read by the modules
  SELF=$cli LIB=$(dirname "$cli")/lib
  . "$LIB/common.sh"; . "$LIB/config.sh"; . "$LIB/workflow.sh"; . "$LIB/setup-remove.sh"; . "$LIB/deploy.sh"
  cd "$repo" || exit 1
  jq '.deploy.previews = "ready"' .claude/senior-mode.json >"$work/c" && mv "$work/c" .claude/senior-mode.json
  deploy_apply "$repo" >/dev/null
  deploy_restore "$repo" false true >"$work/plan"
  grep -q 'would remove: the preview settings of vercel.json' "$work/plan" && grep -q 'would remove: the ignore step of netlify.toml' "$work/plan" &&
    grep -q 'would remove: .claude/senior-mode/ignore-build.sh' "$work/plan" || { echo "FAIL: remove plan: $(cat "$work/plan")"; exit 1; }
  deploy_restore "$repo" true true >/dev/null
  [ "$(jq -S . vercel.json)" = "$(jq -S . "$work/vercel.orig")" ] && cmp -s netlify.toml "$work/netlify.orig" && [ ! -e .claude/senior-mode/ignore-build.sh ] ||
    { echo "FAIL: remove did not restore"; exit 1; }
) || failures=$((failures + 1))

# senior-mode preview: one ref for the open pull request, the head unchanged, orphan refs pruned.
sm setup answers --previews ready >/dev/null
g switch -q -c feat/9-thing
g commit -q --allow-empty -m "feat: thing"
g push -q origin feat/9-thing
head=$(git -C "$repo" rev-parse HEAD)
g push -q origin "$head:refs/heads/preview/feat/8-gone"
PR_HEAD=$head sm preview >"$work/out" 2>&1 || fail "preview failed: $(cat "$work/out")"
grep -q 'requested on preview/feat/9-thing' "$work/out" || fail "preview not requested: $(cat "$work/out")"
[ "$(git -C "$origin" rev-parse refs/heads/preview/feat/9-thing)" = "$head" ] || fail "preview ref not on the head"
git -C "$origin" rev-parse -q --verify refs/heads/preview/feat/8-gone >/dev/null && fail "orphan preview ref kept"
[ "$(git -C "$origin" rev-parse refs/heads/feat/9-thing)" = "$head" ] || fail "the branch moved"
PR_HEAD=$head sm preview 2>&1 | grep -q 'already requested' || fail "a second request pushes again"
PR_HEAD=other sm preview >/dev/null 2>"$work/err" && fail "preview accepted a pull request head that is not this commit"
PR_STATE=CLOSED PR_HEAD=$head sm preview >/dev/null 2>&1 && fail "preview accepted a closed pull request"
g switch -q main
sm preview >/dev/null 2>&1 && fail "preview from the default branch"
sm preview extra >/dev/null 2>&1 && fail "preview accepted an argument"

[ "$failures" -eq 0 ] && echo "ok" || exit 1
