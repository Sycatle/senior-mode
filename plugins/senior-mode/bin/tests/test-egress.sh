#!/usr/bin/env bash
# Tests for the egress allowlist and its proxy (lib/egress.sh, sandbox/egress-proxy.sh, #780). Offline: DNS is replaced by
# SENIOR_MODE_EGRESS_RESOLVE (a file of `name ip` lines) and the proxy listens on 127.0.0.1, so only refusals go through it.
#   egress_decide <host>   prints `allow` or `refuse: <reason>`; status 0 when allowed
#   egress_start <n>       starts the proxy, sets EGRESS_PORT and EGRESS_PID; <serve dir>/<n>.egress lists refused hosts
#   egress_stop <n>        stops it: the port is closed and no process stays
set -u
bin=$(cd "$(dirname "$0")/.." && pwd)
lib=$bin/lib
work=$(mktemp -d)
failures=0

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

repo=$work/repo
serve=$work/serve
mkdir -p "$repo/.claude" "$serve"
git init -q "$repo"
echo '{"name":"app"}' >"$repo/package.json"
echo '{"preset":"node"}' >"$repo/.claude/senior-mode.json"
cat >"$work/resolve" <<'RES'
registry.npmjs.org 104.16.0.1
api.anthropic.com 160.79.104.10
pypi.org 151.101.0.223
example.org 93.184.216.34
api.stripe.com 52.0.0.1
a.example.dev 52.0.0.2
example.dev 52.0.0.3
private10.npmjs.org 10.0.0.5
RES
export SENIOR_MODE_EGRESS_RESOLVE=$work/resolve SERVE_DIR=$serve SELF=$bin/senior-mode
unset ANTHROPIC_BASE_URL SENIOR_MODE_EGRESS_ALLOW

# in_repo <function> args...: runs a function of the modules in the repository.
modules="common config workflow state setup packages egress"
in_repo() { (cd "$repo" && bash -c 'for m in $2; do . "$1/$m.sh"; done; shift 2; "$@"' _ "$lib" "$modules" "$@"); }
decide() { in_repo egress_decide "$1" 2>&1; }
expect() { # host verdict
  local got
  got=$(decide "$1")
  [ "$got" = "$2" ] || fail "$1: '$got', wanted '$2'"
}

proxy_pid=""
cleanup() {
  [ -z "$proxy_pid" ] || in_repo egress_stop 1 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT

[ -r "$lib/egress.sh" ] || fail "lib/egress.sh does not exist"

# 1. The default allowlist of a Node repository: the model API and the npm registry pass, the rest does not.
expect registry.npmjs.org allow
expect api.anthropic.com allow
expect example.org "refuse: not allowlisted"
expect pypi.org "refuse: not allowlisted"
expect REGISTRY.npmjs.org allow
in_repo egress_decide registry.npmjs.org >/dev/null || fail "an allowed host does not exit 0"
in_repo egress_decide example.org >/dev/null && fail "a refused host exits 0"

# 2. sandbox.allow: an exact host, and `*.suffix` for subdomains but not the apex.
echo '{"preset":"node","sandbox":{"allow":["api.stripe.com","*.example.dev"]}}' >"$repo/.claude/senior-mode.json"
expect api.stripe.com allow
expect a.example.dev allow
expect example.dev "refuse: not allowlisted"
expect example.org "refuse: not allowlisted"
echo '{"preset":"node"}' >"$repo/.claude/senior-mode.json"

# 3. An allowlisted name that resolves to a private address, and an IP literal, are refused.
for ip in 10.0.0.5 127.0.0.1 169.254.169.254 172.17.0.2 10.88.0.1 192.168.1.1 ::1 fe80::1; do
  echo "registry.npmjs.org $ip" >"$work/resolve.priv"
  got=$(SENIOR_MODE_EGRESS_RESOLVE=$work/resolve.priv decide registry.npmjs.org)
  [ "$got" = "refuse: private address" ] || fail "registry.npmjs.org -> $ip: '$got'"
done
printf 'registry.npmjs.org 104.16.0.1\nregistry.npmjs.org 10.0.0.5\n' >"$work/resolve.mixed"
[ "$(SENIOR_MODE_EGRESS_RESOLVE=$work/resolve.mixed decide registry.npmjs.org)" = "refuse: private address" ] ||
  fail "a name with one private address among public ones passes"
for lit in 93.184.216.34 127.0.0.1 '[::1]' 2001:db8::1; do
  case $(decide "$lit") in refuse*) ;; *) fail "IP literal $lit passes" ;; esac
done

# 4. The proxy: a refused host fails at curl with the proxy's refusal, and the log names it once however often it is asked.
if command -v socat >/dev/null && command -v curl >/dev/null; then
  # egress_start leaves the proxy to the shell that runs it: run it here, with the modules loaded.
  # shellcheck disable=SC1090 # the modules named in $modules
  for m in $modules; do . "$lib/$m.sh"; done
  (cd "$repo" && egress_start 1 2>"$work/err") || fail "the proxy did not start: $(cat "$work/err")"
  proxy_pid=$(cat "$serve/1.egress.pid" 2>/dev/null)
  port=$(cat "$serve/1.egress.port" 2>/dev/null)
  [ -n "$port" ] || fail "no port recorded"
  for _ in 1 2 3; do
    curl -sS -o /dev/null --max-time 10 --proxy "http://127.0.0.1:$port" https://example.org/ 2>"$work/curl" && fail "curl got through to a refused host"
  done
  grep -q 403 "$work/curl" || fail "curl does not report the refusal: $(cat "$work/curl")"
  out=$(curl -s --max-time 10 --proxy "http://127.0.0.1:$port" http://example.org/ 2>&1)
  grep -q "not allowlisted" <<<"$out" || fail "a plain http request is not refused with the reason: $out"
  curl -s -o /dev/null --max-time 10 --proxy "http://127.0.0.1:$port" http://93.184.216.34/
  [ "$(cut -f1 "$serve/1.egress" | grep -cx example.org)" -eq 1 ] || fail "example.org is not logged exactly once: $(cat "$serve/1.egress" 2>&1)"
  grep -q "^example.org	refuse: not allowlisted$" "$serve/1.egress" || fail "the log line lacks the reason: $(cat "$serve/1.egress")"
  [ "$(grep -c . "$serve/1.egress")" -eq 2 ] || fail "the log has other lines than example.org and the literal: $(cat "$serve/1.egress")"

  # 5. Stopped, the port is closed and no process stays.
  egress_stop 1
  proxy_pid=""
  (: </dev/tcp/127.0.0.1/"$port") 2>/dev/null && fail "the port is still open after egress_stop"
  pgrep -f "TCP-LISTEN:$port" >/dev/null && fail "a process of the proxy stays after egress_stop"
  [ ! -e "$serve/1.egress.pid" ] || fail "the pid file stays"

  # 6. Two sessions of the repository share one proxy; it stops with the last one (#783).
  (cd "$repo" && egress_proxy_acquire 11 2>"$work/err") || fail "the shared proxy did not start: $(cat "$work/err")"
  shared_pid=$(cat "$serve/proxy.egress.pid" 2>/dev/null)
  shared_port=$(cat "$serve/proxy.egress.port" 2>/dev/null)
  [ -n "$shared_port" ] || fail "no port recorded for the shared proxy"
  (: </dev/tcp/127.0.0.1/"${shared_port:-0}") 2>/dev/null || fail "the shared proxy does not listen"
  (cd "$repo" && egress_proxy_acquire 12 2>"$work/err") || fail "the second session failed: $(cat "$work/err")"
  [ "$(cat "$serve/proxy.egress.pid")" = "$shared_pid" ] || fail "a second proxy was started for the second session"
  [ "$(egress_proxy_url)" = "http://host.containers.internal:$shared_port" ] || fail "proxy url: $(egress_proxy_url)"
  egress_proxy_release 11
  (: </dev/tcp/127.0.0.1/"$shared_port") 2>/dev/null || fail "the proxy stopped while a session still uses it"
  egress_proxy_release 12
  (: </dev/tcp/127.0.0.1/"$shared_port") 2>/dev/null && fail "the proxy is still up after the last session"
  [ ! -e "$serve/proxy.egress.pid" ] && [ ! -e "$serve/proxy.sessions" ] || fail "the shared proxy left files: $(ls "$serve")"
  # With sandbox.allow, that repository's proxy allows the host and still refuses the others.
  echo '{"preset":"node","sandbox":{"allow":["api.stripe.com"]}}' >"$repo/.claude/senior-mode.json"
  (cd "$repo" && egress_proxy_acquire 13 2>"$work/err") || fail "the proxy with sandbox.allow did not start"
  sp=$(cat "$serve/proxy.egress.port")
  curl -s --max-time 10 --proxy "http://127.0.0.1:$sp" http://example.org/ 2>&1 | grep -q "not allowlisted" || fail "the shared proxy lets example.org through"
  curl -s --max-time 10 --proxy "http://127.0.0.1:$sp" http://api.stripe.com/ 2>&1 | grep -q "not allowlisted" && fail "the shared proxy refuses api.stripe.com"
  egress_proxy_release 13
  echo '{"preset":"node"}' >"$repo/.claude/senior-mode.json"
else
  echo "SKIP: socat or curl missing, the proxy cases did not run"
fi

[ "$failures" -eq 0 ] || exit 1
echo "test-egress: ok"
