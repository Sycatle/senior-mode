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

# Builds image $1 from Dockerfile $2 with context $3 unless the runtime already has the tag (#763). $4... go to `build`.
# On a failure it prints the last 20 lines of the build output and fails.
sandbox_build() {
  local rt=$1 tag=$2 file=$3 ctx=$4 log
  shift 4
  "$rt" image inspect "$tag" >/dev/null 2>&1 && return 0
  log=$(mktemp) || return 1
  if "$rt" build -t "$tag" -f "$file" "$@" "$ctx" >"$log" 2>&1; then
    rm -f "$log"
    return 0
  fi
  tail -n 20 "$log"
  rm -f "$log"
  return 1
}

# The plugin's base image $2, built with the host's version $3 of the claude CLI when there is one.
sandbox_build_base() {
  sandbox_build "$1" "$2" "$(plugin_root)/sandbox/Dockerfile" "$(plugin_root)/sandbox" ${3:+--build-arg "CLAUDE_VERSION=$3"}
}

# The image of a session, built on demand, printed (run in the repository):
#   sandbox.image                                      that name, nothing is built
#   .senior-mode/Dockerfile                            senior-mode/<repo>:<first 12 hex of its sha256>
#   neither                                            senior-mode/base:<plugin version>, from the plugin's sandbox/Dockerfile
# A project Dockerfile that starts FROM senior-mode/base has the base built first. A failed build prints
# `hold <detail>` (the last 20 lines of the output), like sandbox_decide: the caller holds the launch with cause `sandbox`.
sandbox_image() {
  local img rt top repo file base ver cv out
  img=$(config_get sandbox.image 2>/dev/null) || img=""
  if [ -n "$img" ]; then
    echo "$img"
    return 0
  fi
  rt=$(sandbox_runtime) || {
    echo "hold sandbox: no container runtime to build the image (install podman)"
    return 1
  }
  top=$(git rev-parse --show-toplevel 2>/dev/null) || top=$PWD
  file=$top/.senior-mode/Dockerfile
  base=senior-mode/base:$(plugin_version)
  cv=$("${SENIOR_MODE_CLAUDE:-claude}" --version 2>/dev/null | awk '$1 ~ /^[0-9]+\.[0-9]+\.[0-9]+$/ {print $1; exit}') || cv=""
  if [ -f "$file" ] && grep -qiE '^FROM[[:space:]]+senior-mode/base' "$file"; then
    out=$(sandbox_build_base "$rt" "$base" "$cv") || {
      printf 'hold image build of %s failed:\n%s\n' "$base" "$out"
      return 1
    }
  fi
  if [ -f "$file" ]; then
    repo=$(basename "$top" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9._\n-' '-')
    ver=$(sha256sum "$file" | cut -c1-12)
    img=senior-mode/$repo:$ver
    out=$(sandbox_build "$rt" "$img" "$file" "$top/.senior-mode") || {
      printf 'hold image build of %s failed:\n%s\n' "$img" "$out"
      return 1
    }
    echo "$img"
    return 0
  fi
  out=$(sandbox_build_base "$rt" "$base" "$cv") || {
    printf 'hold image build of %s failed:\n%s\n' "$base" "$out"
    return 1
  }
  echo "$base"
}
