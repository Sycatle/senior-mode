# shellcheck shell=bash
DEFAULTS='{
  "language": "en",
  "ci": { "mode": "local" },
  "autonomy": { "maxTickets": 3, "parallel": 1, "maxConsecutiveFailures": 2, "merge": false, "escalate": true, "sessionTimeout": 90, "schedule": "02:00", "sessionsPerHour": 6, "minMemoryMB": 1024 },
  "serve": { "interval": 60, "grace": 600, "breakerCooldown": 300 },
  "notify": { "mention": "", "webhook": "", "digest": true },
  "agent": { "command": "claude" },
  "e2e": { "slots": 2 },
  "limits": { "prLines": 400 },
  "wip": 1,
  "slot": "",
  "hygiene": { "days": 14 },
  "protected": [],
  "secrets": [],
  "audit": true,
  "board": { "template": "PVT_kwHOAZfEPs4Bs2sq", "archiveAfterDays": 14, "iterationDays": 14 },
  "envGuard": { "forbidden": [] },
  "review": { "sections": [] },
  "docs": { "extra": [] },
  "github": { "protection": "" }
}'
die() {
  echo "senior-mode: $*" >&2
  exit 1
}

config_file() {
  local root file
  root=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repository"
  file="$root/.claude/senior-mode.json"
  [ -f "$file" ] || die "no .claude/senior-mode.json here; run /senior-mode:setup"
  jq empty "$file" 2>/dev/null || die "invalid .claude/senior-mode.json; run /senior-mode:setup to repair it"
  printf '%s\n' "$file"
}

# Prints a config value (strings raw, anything else as JSON), falling back to DEFAULTS: the optional keys
# read as empty (`[]` for a list, an empty line for a string) when absent; any other key is an error.
config_get() {
  local key=$1 file path value
  file=$(config_file)
  path=$(jq -nc --arg k "$key" '$k | split(".")')
  value=$(jq -c --argjson d "$DEFAULTS" --argjson p "$path" '($d * .) | getpath($p)' "$file" 2>/dev/null) ||
    die "unknown config key: $key"
  [ "$value" != null ] || die "unknown config key: $key"
  jq -r 'if type == "string" then . else tojson end' <<<"$value"
}

# owner/name of the origin remote, from an https or ssh URL.
repo_slug() {
  local url
  url=$(git remote get-url origin 2>/dev/null) || die "no origin remote"
  url=${url%.git}
  printf '%s\n' "${url#*github.com[:/]}"
}

# Runs the command $2... for at most $1 seconds (coreutils timeout, which signals the whole process group); without
# timeout on the machine it runs unbounded. Exit code 124 when it was cut.
net_bound() {
  local secs=$1
  shift
  if command -v timeout >/dev/null; then timeout -k 5 "$secs" "$@"; else "$@"; fi
}

# Whether the exit code $1 is that of net_bound cutting a command (124, or 137 when it needed a KILL).
net_cut() {
  [ "$1" -eq 124 ] || [ "$1" -eq 137 ]
}

# gh for the calls of the daemon (#382): cut after SENIOR_MODE_GH_TIMEOUT seconds (default 60), so that a connection
# that died half-way cannot stall serve. A cut is a transient failure: "timed out" on stderr, as gh_retry reads it.
gh_bound() {
  local rc=0 secs=${SENIOR_MODE_GH_TIMEOUT:-60}
  net_bound "$secs" gh "$@" || rc=$?
  ! net_cut "$rc" || echo "gh timed out after ${secs}s" >&2
  return "$rc"
}

# git for the network calls of the daemon (fetch, push, ls-remote): cut after SENIOR_MODE_GIT_TIMEOUT seconds (default 120).
git_bound() {
  local rc=0 secs=${SENIOR_MODE_GIT_TIMEOUT:-120}
  net_bound "$secs" git "$@" || rc=$?
  ! net_cut "$rc" || echo "git timed out after ${secs}s" >&2
  return "$rc"
}

# Runs gh (bounded, gh_bound), retrying up to 3 times with a growing pause when GitHub fails transiently (#21) or does
# not answer in time (#382); any other error fails at once. SENIOR_MODE_RETRY_DELAY scales the pause (seconds, default 1).
gh_retry() {
  local attempt err out
  err=$(mktemp)
  for attempt in 1 2 3 4; do
    if out=$(gh_bound "$@" 2>"$err"); then
      rm -f "$err"
      [ -z "$out" ] || printf '%s\n' "$out"
      return 0
    fi
    grep -qiE 'unknown owner type|HTTP 5[0-9][0-9]|timeout|timed out|connection reset|unexpected EOF|secondary rate limit' "$err" &&
      [ "$attempt" -lt 4 ] || break
    sleep $((attempt * ${SENIOR_MODE_RETRY_DELAY:-1}))
  done
  cat "$err" >&2
  rm -f "$err"
  return 1
}

# Milliseconds on a clock that only goes forward; whole seconds where the shell has no EPOCHREALTIME.
now_ms() {
  if [ -n "${EPOCHREALTIME:-}" ]; then
    local t=${EPOCHREALTIME/[.,]/}
    echo $((t / 1000))
  else
    echo $((SECONDS * 1000))
  fi
}

# The time since $1 (a now_ms value) as "1.2s".
since_ms() {
  local ms=$(($(now_ms) - $1))
  printf '%d.%ds' $((ms / 1000)) $((ms % 1000 / 100))
}

# The sha256 of $1, as sha256sum or shasum prints it.
sha256() {
  if command -v sha256sum >/dev/null; then
    printf %s "$1" | sha256sum | cut -d' ' -f1
  else
    printf %s "$1" | shasum -a 256 | cut -d' ' -f1
  fi
}

file_owner() { stat -c %u "$1" 2>/dev/null || stat -f %u "$1"; }
file_mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

# The default branch to compare with: origin's HEAD, else the usual names, remote first.
default_branch() {
  local ref b
  if ref=$(git symbolic-ref --short -q refs/remotes/origin/HEAD); then
    printf '%s\n' "$ref"
    return 0
  fi
  for b in origin/main origin/master main master; do
    if git rev-parse -q --verify "$b^{commit}" >/dev/null; then
      printf '%s\n' "$b"
      return 0
    fi
  done
  return 1
}

# Lowercase ASCII words of a title joined by dashes, at most 40 characters cut at a word; a leading
# `type(scope): ` of a Conventional Commit title is dropped. Accents are transliterated with iconv when
# it can (under a UTF-8 locale, else it writes `?`), and any non-ASCII byte left is dropped, so a branch
# name is portable whatever the locale (#111).
slugify() {
  local full s
  full=$(LC_ALL=C.UTF-8 iconv -f UTF-8 -t ASCII//TRANSLIT <<<"$1" 2>/dev/null) || full=$1
  full=$(printf '%s' "$full" | LC_ALL=C tr -cd '\000-\177' | LC_ALL=C tr '[:upper:]' '[:lower:]' |
    LC_ALL=C sed -E 's/^[a-z]+(\([^)]*\))?!?: //; s/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
  s=${full:0:40}
  [ ${#full} -le 40 ] || [ "${full:40:1}" = - ] || s=${s%-*}
  printf '%s\n' "${s%-}"
}

# Seconds in a duration such as 90m, 12h, 7d or 2w.
duration_seconds() {
  [[ $1 =~ ^([0-9]+)([mhdw])$ ]] || die "not a duration: $1 (use for example 12h, 7d or 2w)"
  case ${BASH_REMATCH[2]} in
    m) echo $((BASH_REMATCH[1] * 60)) ;;
    h) echo $((BASH_REMATCH[1] * 3600)) ;;
    d) echo $((BASH_REMATCH[1] * 86400)) ;;
    w) echo $((BASH_REMATCH[1] * 604800)) ;;
  esac
}

# UTC ISO 8601 time of an epoch, the format GitHub uses (GNU date, then BSD).
iso_time() {
  date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ
}

# Modification time of a file, in epoch seconds (GNU stat, then BSD).
file_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"
}
