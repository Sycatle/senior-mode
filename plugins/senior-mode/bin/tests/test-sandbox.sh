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

[ "$failures" -eq 0 ] && echo "ok: sandbox" || exit 1
