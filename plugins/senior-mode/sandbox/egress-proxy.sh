#!/usr/bin/env bash
# The egress proxy of sandboxed sessions (ADR 0025, #780). It needs bash and socat, nothing else.
#   egress-proxy.sh listen <port> [<bind>]   serves until killed: socat accepts, forks, and runs `handle` per connection
#   egress-proxy.sh handle                   one connection on stdin and stdout: CONNECT, or a plain http:// request
# The decision is lib/egress.sh's (the allowlist is SENIOR_MODE_EGRESS_ALLOW, refusals go to EGRESS_LOG). An allowed request
# is carried to the address that was checked, never to a second resolution of the name. A refusal is a 403 that says why.
# shellcheck source-path=SCRIPTDIR
set -uo pipefail

SELF=$(readlink -f "${BASH_SOURCE[0]}")
LIB=$(dirname "$SELF")/../bin/lib
# shellcheck source=../bin/lib/common.sh
. "$LIB/common.sh"
# shellcheck source=../bin/lib/state.sh
. "$LIB/state.sh"
# shellcheck source=../bin/lib/egress.sh
. "$LIB/egress.sh"

reply() { # status text body
  printf 'HTTP/1.1 %s %s\r\nContent-Type: text/plain\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s' "$1" "$2" "${#3}" "$3"
}

# The upstream of an allowed host: socat to the address that was checked.
upstream() { # ip port
  case $1 in
    *:*) printf 'TCP6:[%s]:%s,connect-timeout=10' "$1" "$2" ;;
    *) printf 'TCP:%s:%s,connect-timeout=10' "$1" "$2" ;;
  esac
}

handle() {
  local line method target host port path rest hostport hdr headers="" len=0
  IFS= read -r -t 30 line || exit 0
  line=${line%$'\r'}
  read -r method target _ <<<"$line"
  while IFS= read -r -t 30 hdr; do
    hdr=${hdr%$'\r'}
    [ -n "$hdr" ] || break
    case ${hdr,,} in
      proxy-connection:* | connection:* | proxy-authorization:*) ;;
      content-length:*) len=${hdr#*:}; len=${len// /}; headers+="$hdr"$'\r\n' ;;
      *) headers+="$hdr"$'\r\n' ;;
    esac
  done
  case $len in '' | *[!0-9]*) len=0 ;; esac
  if [ "$method" = CONNECT ]; then
    host=${target%:*} port=${target##*:} path=""
  else
    case $target in
      http://*) ;;
      *) reply 400 "Bad Request" $'egress: only CONNECT and http:// requests\n'; exit 0 ;;
    esac
    rest=${target#http://}
    hostport=${rest%%/*}
    case $rest in */*) path=/${rest#*/} ;; *) path=/ ;; esac
    case $hostport in *:*) host=${hostport%:*} port=${hostport##*:} ;; *) host=$hostport port=80 ;; esac
  fi
  case $port in '' | *[!0-9]*) reply 400 "Bad Request" $'egress: bad port\n'; exit 0 ;; esac
  if ! egress_check "$host"; then
    egress_log_refusal "$host" "$EGRESS_VERDICT"
    reply 403 "Forbidden" "egress: $host: $EGRESS_VERDICT"$'\n'
    exit 0
  fi
  if [ "$method" = CONNECT ]; then
    printf 'HTTP/1.1 200 Connection established\r\n\r\n'
    exec socat -T 300 - "$(upstream "$EGRESS_IP" "$port")"
  fi
  {
    printf '%s %s HTTP/1.1\r\nConnection: close\r\n%s\r\n' "$method" "$path" "$headers"
    [ "$len" -eq 0 ] || head -c "$len"
  } | socat -T 300 - "$(upstream "$EGRESS_IP" "$port")"
}

case ${1:-} in
  listen)
    [ -n "${2:-}" ] || { echo "usage: egress-proxy.sh listen <port> [<bind>]" >&2; exit 2; }
    exec socat "TCP-LISTEN:$2,bind=${3:-127.0.0.1},reuseaddr,fork" "EXEC:$SELF handle"
    ;;
  handle) handle ;;
  *) echo "usage: egress-proxy.sh listen <port> [<bind>] | handle" >&2; exit 2 ;;
esac
