# shellcheck shell=bash
# The sandbox decision (spec 328 section 2.1, ADR 0025): does a session run in a container, on the host, or is the launch held.
# Pure decision and detection only: no container is started here, and serve's hold wiring reads sandbox_decide.
# Subscription auth only (owner decision 2026-11-27): the credential is a token of `claude setup-token`, never an API key.

# The configured mode: auto (default), required or off.
sandbox_mode() {
  config_get sandbox.mode 2>/dev/null || echo auto
}

# The container runtime on this machine, printed, or return 1. sandbox.runtime names one when it is not `auto`; else
# SENIOR_MODE_RUNTIME (a stub in tests), else podman (rootless, the reference), else docker.
sandbox_runtime() {
  local want=${SENIOR_MODE_RUNTIME:-} cfg c
  cfg=$(config_get sandbox.runtime 2>/dev/null) || cfg=auto
  case $cfg in auto | '') ;; *) want=$cfg ;; esac
  if [ -n "$want" ]; then
    command -v "$want" >/dev/null 2>&1 || return 1
    echo "$want"
    return 0
  fi
  for c in podman docker; do
    if command -v "$c" >/dev/null 2>&1; then
      echo "$c"
      return 0
    fi
  done
  return 1
}

# Succeeds when sessions run in a container: not `off` (the runtime is not looked for then) and a runtime exists.
sandbox_enabled() {
  [ "$(sandbox_mode)" != off ] || return 1
  sandbox_runtime >/dev/null
}

sandbox_credential_file() {
  local f
  f=$(config_get sandbox.credentialFile 2>/dev/null) || f=""
  : "${f:=~/.config/senior-mode/credentials.env}"
  echo "${f/#\~/$HOME}"
}

# Succeeds when the credential file is mode 0600 and has a model credential line: NAME=value, NAME matching
# ^(ANTHROPIC_|CLAUDE_CODE_)[A-Z_]*$, and never ANTHROPIC_API_KEY (no API billing, no fallback to one).
sandbox_credential_ok() {
  local f
  f=${1:-$(sandbox_credential_file)}
  [ -f "$f" ] && [ "$(stat -c %a "$f" 2>/dev/null)" = 600 ] || return 1
  grep -E '^(ANTHROPIC_|CLAUDE_CODE_)[A-Z_]*=.' "$f" | grep -qv '^ANTHROPIC_API_KEY='
}

# The decision, pure: sandbox_decide <mode> <runtime or ""> <credential yes|no>. One line on stdout:
#   container                  the session runs in a container
#   host <note>                it runs on the host as today; the note is what `serve` logs once a day
#   hold <detail>              launches are held, hold cause `sandbox`; approved pull requests still merge
# `auto` never holds: without a runtime or a credential it runs on the host. Only `required` holds.
sandbox_decide() {
  local mode=$1 runtime=$2 cred=$3
  case $mode in
    off) echo "host sandbox: off (configured)" ;;
    required)
      if [ -z "$runtime" ]; then
        echo "hold sandbox required: no container runtime (install podman)"
      elif [ "$cred" != yes ]; then
        echo "hold no model credential for containers: run claude setup-token"
      else
        echo container
      fi
      ;;
    *)
      if [ -z "$runtime" ]; then
        echo "host sandbox: off (no runtime)"
      elif [ "$cred" != yes ]; then
        echo "host sandbox: off (no model credential)"
      else
        echo container
      fi
      ;;
  esac
}
