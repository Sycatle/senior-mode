# shellcheck shell=bash
# The egress allowlist of sandboxed sessions (ADR 0025, spec §2.3, #780): the decision on a host as a function, and the start
# and stop of the filtering proxy (plugins/senior-mode/sandbox/egress-proxy.sh, which socat runs once per connection). A host
# passes when it is the model API, a registry of the project's preset or in `sandbox.allow`, and when every address its name
# resolves to is public: the proxy resolves the name itself and connects to that address, so a name cannot be pointed at the
# host's own network after the check. Definitions only.
EGRESS_MODEL_HOST=api.anthropic.com

# The patterns one per line: exact hosts, or `*.suffix` for any subdomain but not the apex. SENIOR_MODE_EGRESS_ALLOW (set by
# egress_start for the proxy process) replaces the computation.
egress_allowlist() {
  local root preset base host list
  if [ -n "${SENIOR_MODE_EGRESS_ALLOW:-}" ]; then
    printf '%s\n' "$SENIOR_MODE_EGRESS_ALLOW"
    return
  fi
  echo "$EGRESS_MODEL_HOST"
  base=${ANTHROPIC_BASE_URL:-}
  if [ -n "$base" ]; then
    host=${base#*://}
    host=${host%%[/:]*}
    echo "$host"
  fi
  if declare -F project_preset >/dev/null; then
    root=$(git rev-parse --show-toplevel 2>/dev/null) || root=$PWD
    preset=$(project_preset "$root" 2>/dev/null) || preset=""
    case $preset in
      node) echo registry.npmjs.org ;;
      python) printf '%s\n' pypi.org files.pythonhosted.org ;;
      rust) printf '%s\n' crates.io static.crates.io ;;
      go) printf '%s\n' proxy.golang.org sum.golang.org ;;
    esac
  fi
  list=$( (config_get sandbox.allow 2>/dev/null || true) | jq -r '.[]? | strings' 2>/dev/null) || list=""
  [ -z "$list" ] || printf '%s\n' "$list"
}

# 0 when the host ($1, lowercase) is an IP literal: dotted digits, or anything with a colon or a bracket.
egress_is_literal() {
  case $1 in
    *[:\[]*) return 0 ;;
    *[!0-9.]*) return 1 ;;
    *) return 0 ;;
  esac
}

# 0 when the host ($1, lowercase) is allowed by one of the patterns on stdin.
egress_listed() {
  local host=$1 pat
  while IFS= read -r pat; do
    pat=${pat,,}
    case $pat in
      \*.*)
        pat=${pat#\*}
        case $pat in *[!a-z0-9.-]* | . | .. ) continue ;; esac
        [[ $host == *"$pat" && ${#host} -gt ${#pat} ]] && return 0
        ;;
      '' | *[!a-z0-9.-]*) ;;
      *) [ "$host" = "$pat" ] && return 0 ;;
    esac
  done
  return 1
}

# The addresses of a name, one per line: from the `name ip` lines of SENIOR_MODE_EGRESS_RESOLVE when it is set (tests), else
# from the system resolver.
egress_resolve() {
  if [ -n "${SENIOR_MODE_EGRESS_RESOLVE:-}" ]; then
    awk -v h="$1" '$1 == h { print $2 }' "$SENIOR_MODE_EGRESS_RESOLVE" 2>/dev/null
  else
    getent ahosts "$1" 2>/dev/null | awk '{ print $1 }' | sort -u
  fi
}

# 0 when the address is not public: loopback, private (this covers the bridges of Docker, 172.17.0.0/16, and of Podman,
# 10.88.0.0/16), shared, link-local (169.254.0.0/16, the cloud metadata address), multicast and reserved ranges, and any
# address that is not well formed.
egress_private() {
  local ip=${1,,} a b c d
  case $ip in ::ffff:*.*) ip=${ip#::ffff:} ;; esac
  case $ip in
    *:*)
      case $ip in :: | ::1 | fe[89ab]* | f[cd]* | ff*) return 0 ;; esac
      return 1
      ;;
  esac
  [[ $ip =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 0
  a=${BASH_REMATCH[1]} b=${BASH_REMATCH[2]} c=${BASH_REMATCH[3]} d=${BASH_REMATCH[4]}
  [ $((10#$a)) -lt 256 ] && [ $((10#$b)) -lt 256 ] && [ $((10#$c)) -lt 256 ] && [ $((10#$d)) -lt 256 ] || return 0
  a=$((10#$a)) b=$((10#$b))
  [ "$a" -eq 0 ] || [ "$a" -eq 10 ] || [ "$a" -eq 127 ] || [ "$a" -ge 224 ] && return 0
  [ "$a" -eq 100 ] && [ "$b" -ge 64 ] && [ "$b" -le 127 ] && return 0
  [ "$a" -eq 169 ] && [ "$b" -eq 254 ] && return 0
  [ "$a" -eq 172 ] && [ "$b" -ge 16 ] && [ "$b" -le 31 ] && return 0
  [ "$a" -eq 192 ] && [ "$b" -eq 168 ] && return 0
  return 1
}

# The verdict on a host: sets EGRESS_VERDICT (`allow` or `refuse: <reason>`) and, when allowed, EGRESS_IP (the first address,
# which the proxy connects to). Status 0 when allowed.
egress_check() {
  local host=${1,,} ip ips
  EGRESS_IP=""
  host=${host%.}
  if egress_is_literal "$host"; then
    EGRESS_VERDICT="refuse: ip literal"
    return 1
  fi
  if ! egress_allowlist | egress_listed "$host"; then
    EGRESS_VERDICT="refuse: not allowlisted"
    return 1
  fi
  ips=$(egress_resolve "$host")
  if [ -z "$ips" ]; then
    EGRESS_VERDICT="refuse: unresolved"
    return 1
  fi
  while IFS= read -r ip; do
    if egress_private "$ip"; then
      EGRESS_VERDICT="refuse: private address"
      return 1
    fi
  done <<<"$ips"
  EGRESS_IP=${ips%%$'\n'*}
  EGRESS_VERDICT=allow
}

# `egress_decide <host>`: prints `allow` or `refuse: <reason>`; status 0 when allowed.
egress_decide() {
  local rc=0
  egress_check "$1" || rc=$?
  printf '%s\n' "$EGRESS_VERDICT"
  return "$rc"
}

# A refusal goes to the log of the session ($EGRESS_LOG, <serve dir>/<n>.egress) once per host: `<host><TAB><reason>`.
egress_log_refusal() { # host reason
  [ -n "${EGRESS_LOG:-}" ] || return 0
  state_update egress_log_once "$EGRESS_LOG" "$(printf '%s' "$1" | tr -c 'A-Za-z0-9.:_[]-' '?')" "$2"
}
egress_log_once() { # file host reason
  if [ -f "$1" ] && cut -f1 "$1" | grep -qxF "$2"; then return 0; fi
  state_append_now "$1" "$(printf '%s\t%s' "$2" "$3")"
}

# `egress_start <n> [<port>]`: starts the proxy of ticket n in its own process group, on 127.0.0.1 (SENIOR_MODE_EGRESS_BIND
# changes it) and a free port unless one is given; sets EGRESS_PORT and EGRESS_PID and records them in
# <serve dir>/<n>.egress.pid and .port. The proxy needs `socat`.
egress_start() {
  local n=$1 port=${2:-} proxy pid i
  [ -n "${SERVE_DIR:-}" ] || { echo "senior-mode: egress: no serve dir" >&2; return 1; }
  command -v socat >/dev/null 2>&1 || { echo "senior-mode: egress: the proxy needs socat" >&2; return 1; }
  proxy=$(dirname "$SELF")/../sandbox/egress-proxy.sh
  if [ -z "$port" ]; then
    for i in $(seq 1 50); do
      port=$((20000 + RANDOM % 40000))
      (: </dev/tcp/127.0.0.1/"$port") 2>/dev/null || break
    done
  fi
  SENIOR_MODE_EGRESS_ALLOW=$(egress_allowlist) EGRESS_LOG="$SERVE_DIR/$n.egress" \
    setsid "$proxy" listen "$port" "${SENIOR_MODE_EGRESS_BIND:-127.0.0.1}" </dev/null >/dev/null 2>&1 9>&- &
  pid=$!
  for i in $(seq 1 50); do
    (: </dev/tcp/127.0.0.1/"$port") 2>/dev/null && break
    kill -0 "$pid" 2>/dev/null || { echo "senior-mode: egress: the proxy did not start on port $port" >&2; return 1; }
    sleep 0.1
  done
  EGRESS_PORT=$port EGRESS_PID=$pid
  state_put "$SERVE_DIR/$n.egress.pid" "$pid"
  state_put "$SERVE_DIR/$n.egress.port" "$port"
}

# `egress_stop <n>`: stops the proxy of ticket n and every connection it holds (its process group): the port is closed and no
# process stays.
egress_stop() {
  local n=$1 pid i
  pid=$(state_num "$SERVE_DIR/$n.egress.pid")
  if [ "$pid" -gt 0 ]; then
    kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
    for i in $(seq 1 30); do
      wait "$pid" 2>/dev/null || true
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
    kill -0 "$pid" 2>/dev/null && kill -KILL -- "-$pid" 2>/dev/null
    wait "$pid" 2>/dev/null || true
  fi
  rm -f "$SERVE_DIR/$n.egress.pid" "$SERVE_DIR/$n.egress.port"
  return 0
}

# One proxy per repository, shared by its sessions (#783): `egress_proxy_acquire <session>` records the session in
# <serve dir>/proxy.sessions and starts the proxy (files proxy.egress.*, refusals in proxy.egress) when none is alive;
# `egress_proxy_release <session>` drops it and stops the proxy with the last one. Both run under the state lock.
egress_proxy_acquire() {
  state_update egress_proxy_acquire_locked "$1"
}
egress_proxy_acquire_locked() {
  local pid
  grep -qxF "$1" "$SERVE_DIR/proxy.sessions" 2>/dev/null || echo "$1" >>"$SERVE_DIR/proxy.sessions"
  pid=$(state_num "$SERVE_DIR/proxy.egress.pid")
  if [ "$pid" -gt 0 ] && kill -0 "$pid" 2>/dev/null; then return 0; fi
  egress_start proxy
}
egress_proxy_release() {
  state_update egress_proxy_release_locked "$1"
}
egress_proxy_release_locked() {
  local left
  left=$(grep -vxF "$1" "$SERVE_DIR/proxy.sessions" 2>/dev/null) || left=""
  if [ -n "$left" ]; then
    printf '%s\n' "$left" >"$SERVE_DIR/proxy.sessions"
    return 0
  fi
  rm -f "$SERVE_DIR/proxy.sessions"
  egress_stop proxy
}

# The URL of the shared proxy as a container sees it: the host name that reaches the machine from a container
# (SENIOR_MODE_PROXY_HOST, `host.containers.internal` by default) and the recorded port.
egress_proxy_url() {
  printf 'http://%s:%s\n' "${SENIOR_MODE_PROXY_HOST:-host.containers.internal}" "$(state_num "$SERVE_DIR/proxy.egress.port")"
}
