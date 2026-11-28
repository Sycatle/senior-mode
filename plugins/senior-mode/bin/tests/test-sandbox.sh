#!/usr/bin/env bash
# Tests for the sandbox decision (lib/sandbox.sh, #760, spec 328 section 2.1). Offline: runtimes are stubs on a private PATH.
# shellcheck disable=SC2016,SC2088 # bash -c programs and the literal ~ of a default are not shell expansions
set -u
bin=$(cd "$(dirname "$0")/.." && pwd)
cli=$bin/senior-mode
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

repo=$work/repo
git init -q -b main "$repo"
mkdir -p "$repo/.claude" "$work/bin" "$work/empty"
for t in podman docker mystub; do printf '#!/bin/sh\nexit 0\n' >"$work/bin/$t"; chmod +x "$work/bin/$t"; done
config() { printf '%s\n' "$1" >"$repo/.claude/senior-mode.json"; }
# fn <PATH> <function and arguments>: a function of the module, run in the repository with the real tools after the stubs.
fn() {
  local p=$1
  shift
  (cd "$repo" && PATH="$p:$PATH" bash -c '. "$1"; . "$2"; . "$3"; shift 3; "$@"' _ "$bin/lib/common.sh" "$bin/lib/config.sh" "$bin/lib/sandbox.sh" "$@")
}
# A PATH with the tools the module needs and no runtime: podman and docker of the host are hidden.
for t in bash jq git stat grep sed cat env dirname mktemp tr awk sort head wc date readlink; do
  p=$(command -v "$t") && ln -s "$p" "$work/empty/$t"
done
nort() { (cd "$repo" && env -u SENIOR_MODE_RUNTIME PATH="$work/empty" bash -c '. "$1"; . "$2"; . "$3"; shift 3; "$@"' _ "$bin/lib/common.sh" "$bin/lib/config.sh" "$bin/lib/sandbox.sh" "$@"); }

# A runtime named by SENIOR_MODE_RUNTIME is found, mode unset: enabled.
config '{}'
out=$(SENIOR_MODE_RUNTIME=mystub fn "$work/bin" sandbox_runtime) || fail "a stub runtime is not found"
[ "$out" = mystub ] || fail "runtime: $out"
SENIOR_MODE_RUNTIME=mystub fn "$work/bin" sandbox_enabled || fail "sandbox_enabled fails with a runtime"
# Else podman before docker; sandbox.runtime overrides auto.
out=$(env -u SENIOR_MODE_RUNTIME bash -c 'cd "$1" && PATH="$2:$PATH" && . "$3" && . "$4" && . "$5" && sandbox_runtime' _ "$repo" "$work/bin" "$bin/lib/common.sh" "$bin/lib/config.sh" "$bin/lib/sandbox.sh")
[ "$out" = podman ] || fail "podman first: $out"
config '{"sandbox":{"runtime":"docker"}}'
out=$(SENIOR_MODE_RUNTIME=mystub fn "$work/bin" sandbox_runtime)
[ "$out" = docker ] || fail "sandbox.runtime overrides auto: $out"
# No runtime at all.
config '{}'
nort sandbox_runtime >/dev/null && fail "a runtime is found on an empty PATH"
nort sandbox_enabled && fail "enabled without a runtime"

# off: fails without looking for a runtime (a stub is on the PATH).
config '{"sandbox":{"mode":"off"}}'
SENIOR_MODE_RUNTIME=mystub fn "$work/bin" sandbox_enabled && fail "enabled with mode off"
[ "$(fn "$work/bin" sandbox_mode)" = off ] || fail "mode off not read"
# The lookup is `command -v`, which never runs the stub, so check the order in the function.
body=$(sed -n '/^sandbox_enabled()/,/^}/p' "$bin/lib/sandbox.sh")
[ "$(grep -n 'sandbox_mode' <<<"$body" | head -1 | cut -d: -f1)" -lt "$(grep -n 'sandbox_runtime' <<<"$body" | head -1 | cut -d: -f1)" ] ||
  fail "mode is not read before the runtime"

# The credential file: mode 0600, a NAME=value line of the model, never an API key.
cred=$work/credentials.env
config "{\"sandbox\":{\"credentialFile\":\"$cred\"}}"
fn "$work/bin" sandbox_credential_ok && fail "no file passes"
printf 'CLAUDE_CODE_OAUTH_TOKEN=abc\n' >"$cred"
chmod 644 "$cred"
fn "$work/bin" sandbox_credential_ok && fail "a file readable by others passes"
chmod 600 "$cred"
fn "$work/bin" sandbox_credential_ok || fail "a 0600 token file fails"
printf 'ANTHROPIC_API_KEY=sk-x\nHOME=/x\nexport CLAUDE_CODE_X=1\n' >"$cred"
fn "$work/bin" sandbox_credential_ok && fail "an API key or foreign names pass"
config '{"sandbox":{"credentialFile":"~/.cfg/c.env"}}'
[ "$(HOME=/h fn "$work/bin" sandbox_credential_file)" = /h/.cfg/c.env ] || fail "~ not expanded"

# The decision, pure.
d() { fn "$work/bin" sandbox_decide "$@"; }
[ "$(d required "" yes)" = "hold sandbox required: no container runtime (install podman)" ] || fail "required, no runtime: $(d required "" yes)"
[ "$(d required podman no)" = "hold no model credential for containers: run claude setup-token" ] || fail "required, no credential"
[ "$(d required podman yes)" = container ] || fail "required, all there"
[ "$(d auto "" yes)" = "host sandbox: off (no runtime)" ] || fail "auto, no runtime: $(d auto "" yes)"
[ "$(d auto podman no | cut -d' ' -f1)" = host ] || fail "auto, no credential holds"
[ "$(d auto podman yes)" = container ] || fail "auto, all there"
[ "$(d off podman yes | cut -d' ' -f1)" = host ] || fail "off runs in a container"

# config validate: the keys with their defaults, a bad mode rejected.
config '{"sandbox":{"mode":"required","runtime":"podman","image":"x:1","credentialFile":"~/c","memory":"2g","cpus":"1.5","pids":100}}'
(cd "$repo" && "$cli" config validate) >"$work/out" 2>&1 || fail "valid sandbox config rejected: $(cat "$work/out")"
config '{}'
[ "$(cd "$repo" && "$cli" config get sandbox.mode)" = auto ] || fail "default mode"
[ "$(cd "$repo" && "$cli" config get sandbox.memory)" = 4g ] || fail "default memory"
[ "$(cd "$repo" && "$cli" config get sandbox.pids)" = 512 ] || fail "default pids"
[ "$(cd "$repo" && "$cli" config get sandbox.credentialFile)" = "~/.config/senior-mode/credentials.env" ] || fail "default credentialFile"
config '{"sandbox":{"mode":"always"}}'
(cd "$repo" && "$cli" config validate) >"$work/out" 2>&1 && fail "a bad mode passes"
grep -q 'sandbox.mode' "$work/out" || fail "bad mode not named: $(cat "$work/out")"

# sandbox_image (#763): the runtime is a stub that logs its arguments and remembers the tags it built.
rt=$work/rt
mkdir -p "$rt/state"
cat >"$rt/podman" <<'STUB'
#!/bin/sh
echo "$*" >>"$RT_LOG"
tag() { printf %s "$1" | tr '/:' '__'; }
if [ "$1 $2" = "image inspect" ]; then [ -e "$RT_STATE/$(tag "$3")" ]; exit $?; fi
if [ "$1 $2" = "network inspect" ]; then [ -e "$RT_STATE/net_$3" ]; exit $?; fi
if [ "$1 $2" = "network create" ]; then touch "$RT_STATE/net_$4"; exit 0; fi
if [ "$1" = build ]; then
  if [ -e "$RT_STATE/fail" ]; then
    i=1
    while [ "$i" -le 30 ]; do echo "step $i"; i=$((i + 1)); done
    exit 1
  fi
  shift
  while [ $# -gt 0 ]; do
    [ "$1" = -t ] && touch "$RT_STATE/$(tag "$2")"
    shift
  done
fi
exit 0
STUB
printf '#!/bin/sh\necho "9.9.9 (Claude Code)"\n' >"$rt/claude"
chmod +x "$rt/podman" "$rt/claude"
export RT_LOG=$work/rt.log RT_STATE=$rt/state
img() { fn "$rt" sandbox_image; }
builds() { grep -c "^build " "$RT_LOG" 2>/dev/null || true; }
: >"$RT_LOG"

# sandbox.image set: its name, no build.
config '{"sandbox":{"image":"my/img:1"}}'
[ "$(SENIOR_MODE_RUNTIME=podman SELF=$bin/senior-mode img)" = my/img:1 ] || fail "sandbox.image not printed"
[ -z "$(cat "$RT_LOG")" ] || fail "a runtime call with sandbox.image set: $(cat "$RT_LOG")"

# A project Dockerfile: one build of senior-mode/<repo>:<12 hex of its sha256>, none when unchanged, one more when changed.
config '{}'
export SENIOR_MODE_RUNTIME=podman SELF=$bin/senior-mode SENIOR_MODE_CLAUDE=$rt/claude
mkdir -p "$repo/.senior-mode"
printf 'FROM senior-mode/base:0.0.0\n# RUN apt-get install -y make\n' >"$repo/.senior-mode/Dockerfile"
sum1=$(sha256sum "$repo/.senior-mode/Dockerfile" | cut -c1-12)
out=$(img) || fail "sandbox_image failed on a project Dockerfile: $out"
[ "$out" = "senior-mode/repo:$sum1" ] || fail "project image: $out"
[ "$(grep -c "^build -t senior-mode/repo:" "$RT_LOG")" = 1 ] || fail "not exactly one project build: $(cat "$RT_LOG")"
[ "$(grep -c "^build -t senior-mode/base:" "$RT_LOG")" = 1 ] || fail "the base it starts FROM is not built first"
: >"$RT_LOG"
img >/dev/null
[ "$(builds)" = 0 ] || fail "a build for an unchanged Dockerfile: $(cat "$RT_LOG")"
printf '# RUN apt-get install -y cmake\n' >>"$repo/.senior-mode/Dockerfile"
sum2=$(sha256sum "$repo/.senior-mode/Dockerfile" | cut -c1-12)
out=$(img)
[ "$out" = "senior-mode/repo:$sum2" ] && [ "$sum1" != "$sum2" ] || fail "changed Dockerfile, same tag: $out"
[ "$(grep -c "^build -t senior-mode/repo:" "$RT_LOG")" = 1 ] || fail "not one build for a changed Dockerfile: $(cat "$RT_LOG")"

# Neither: the plugin's base, built from its Dockerfile with the host's version of claude.
rm -rf "$repo/.senior-mode"
rm -f "$rt"/state/*
: >"$RT_LOG"
version=$(jq -r .version "$bin/../.claude-plugin/plugin.json")
out=$(img)
[ "$out" = "senior-mode/base:$version" ] || fail "base image: $out"
grep -q "^build -t senior-mode/base:$version -f $bin/../sandbox/Dockerfile --build-arg CLAUDE_VERSION=9.9.9 " "$RT_LOG" || fail "base build: $(cat "$RT_LOG")"

# The base Dockerfile: the tools, Node LTS, the claude CLI, a non-root user last.
df=$bin/../sandbox/Dockerfile
for w in bash git jq curl ca-certificates; do grep -qE "apt-get install .*\b$w\b" "$df" || fail "base Dockerfile lacks $w"; done
grep -qE '^FROM node:lts' "$df" || fail "base Dockerfile is not on Node LTS"
grep -q '@anthropic-ai/claude-code' "$df" || fail "base Dockerfile lacks the claude CLI"
[ "$(grep -E '^USER ' "$df" | tail -n 1)" != "USER root" ] && [ "$(grep -vE '^(#|$)' "$df" | tail -n 1 | cut -d' ' -f1)" = USER ] || fail "base Dockerfile does not end with a non-root USER"
# A real runtime also builds it (SENIOR_MODE_TEST_NO_BUILD=1 skips: it pulls Node and the CLI).
real=$(PATH=$(dirname "$(command -v bash)"):/usr/bin command -v podman || PATH=/usr/bin command -v docker) || real=""
if [ -n "$real" ] && [ -z "${SENIOR_MODE_TEST_NO_BUILD:-}" ] && "$real" info >/dev/null 2>&1; then
  tagr=senior-mode/test-base:$$
  "$real" build -q -t "$tagr" -f "$df" "$bin/../sandbox" >"$work/real.log" 2>&1 || fail "the base image does not build: $(tail -n 5 "$work/real.log")"
  out=$("$real" run --rm "$tagr" sh -c 'id -u; command -v git jq curl node claude' 2>&1) || fail "base image tools: $out"
  [ "$(head -n 1 <<<"$out")" != 0 ] || fail "base image runs as root"
  "$real" rmi -f "$tagr" >/dev/null 2>&1
fi

# A failing build: hold with the last 20 lines of the output, no image printed.
rm -f "$rt"/state/*
touch "$rt/state/fail"
out=$(img) && fail "sandbox_image succeeds on a failed build"
[ "$(head -n 1 <<<"$out" | cut -d' ' -f1)" = hold ] || fail "a failed build does not hold: $out"
[ "$(grep -c '^step ' <<<"$out")" = 20 ] || fail "not 20 lines: $out"
grep -q '^step 30$' <<<"$out" || fail "the last line is missing: $out"
grep -q '^step 10$' <<<"$out" && fail "an early line is kept: $out"
rm -f "$rt/state/fail"
unset SENIOR_MODE_RUNTIME SENIOR_MODE_CLAUDE SELF

# The network of a container (#783): an internal network created once per repository, the proxy variables only for allowlist.
: >"$RT_LOG"
rm -f "$rt"/state/*
net=$(fn "$rt" sandbox_network_name "$repo")
[[ $net == senior-mode-repo-???????? ]] || fail "network name: $net"
[ "$(fn "$rt" sandbox_network_name "$repo")" = "$net" ] || fail "the network name changes between calls"
[ "$(fn "$rt" sandbox_network_name "$work/other/repo")" != "$net" ] || fail "two repositories share a network name"
fn "$rt" sandbox_network_ensure podman "$net"
fn "$rt" sandbox_network_ensure podman "$net"
[ "$(grep -c "^network create --internal $net\$" "$RT_LOG")" = 1 ] || fail "the internal network is not created exactly once: $(cat "$RT_LOG")"
purl=http://host.containers.internal:3128
args=$(fn "$rt" sandbox_net_args allowlist "$net" "$purl")
[ "$(head -n 2 <<<"$args" | tr '\n' ' ')" = "--network $net " ] || fail "allowlist: not the internal network: $args"
for v in HTTPS_PROXY HTTP_PROXY https_proxy http_proxy GIT_CONFIG_VALUE_0; do grep -qx -- "$v=$purl" <<<"$args" || fail "allowlist: $v not set: $args"; done
grep -qx 'GIT_CONFIG_KEY_0=http.proxy' <<<"$args" || fail "allowlist: git's proxy is not set: $args"
grep -q -- '--dns' <<<"$args" && fail "allowlist: a --dns is passed: $args"
args=$(fn "$rt" sandbox_net_args none "$net" "$purl")
[ "$args" = $'--network\nnone' ] || fail "none: $args"
args=$(fn "$rt" sandbox_net_args open "$net" "$purl")
[ "$args" = $'--network\nbridge' ] || fail "open: $args"
config '{}'
[ "$(fn "$rt" sandbox_network)" = allowlist ] || fail "default network"
config '{"sandbox":{"network":"open","allow":["api.stripe.com"]}}'
[ "$(fn "$rt" sandbox_network)" = open ] || fail "network open not read"
(cd "$repo" && "$cli" config validate) >"$work/out" 2>&1 || fail "sandbox.network/allow rejected: $(cat "$work/out")"
for bad in '{"sandbox":{"network":"all"}}' '{"sandbox":{"allow":"api.stripe.com"}}' '{"sandbox":{"allow":[1]}}'; do
  config "$bad"
  (cd "$repo" && "$cli" config validate) >"$work/out" 2>&1 && fail "a bad value passes: $bad"
  grep -q 'sandbox\.' "$work/out" || fail "bad value not named: $bad: $(cat "$work/out")"
done
config '{}'

[ "$failures" -eq 0 ] && echo "ok: sandbox" || exit 1
