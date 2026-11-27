# shellcheck shell=bash
# The plugin version of serve, frozen in a snapshot (spec 373 section 6, ADR 0021, #782). An update of the
# installed plugin rewrites the script bash is reading and the files the sessions load: serve copies the plugin to
# <serve dir>/plugin/<version>-<sha>/ at start, runs from the copy and gives it to every session.

# <version>-<sha> of the plugin at $1: the version of plugin.json and the first 12 characters of a hash over every file.
serve_plugin_id() {
  local root=$1 version sha
  [ -f "$root/.claude-plugin/plugin.json" ] || return 1
  version=$(jq -r '.version // empty' "$root/.claude-plugin/plugin.json" 2>/dev/null) || version=""
  sha=$(cd "$root" && find . -type f -print0 | LC_ALL=C sort -z | xargs -r -0 sha256sum | sha256sum | cut -c1-12) || return 1
  echo "${version:-unknown}-$sha"
}

# serve_plugin_snapshot <plugin root> <serve dir>: prints the directory holding a copy of the plugin, made if it is not
# there (the same version restarted reuses it). The copy is built beside it and moved into place, so a directory that
# exists is whole. Fails, saying why, when the copy cannot be written.
serve_plugin_snapshot() {
  local root=$1 sd=$2 id dest tmp err
  id=$(serve_plugin_id "$root") || {
    echo "serve: cannot read the plugin at $root" >&2
    return 1
  }
  dest=$sd/plugin/$id
  if [ ! -f "$dest/bin/senior-mode" ]; then
    if ! err=$(mkdir -p "$sd/plugin" 2>&1) || ! tmp=$(mktemp -d "$sd/plugin/.tmp.XXXXXX" 2>&1); then
      echo "serve: cannot write the plugin snapshot in $sd/plugin: ${tmp:-$err}" >&2
      return 1
    fi
    if ! err=$(cp -a "$root/." "$tmp/" 2>&1); then
      rm -rf "$tmp"
      echo "serve: cannot copy the plugin to $dest (disk full?): $err" >&2
      return 1
    fi
    mv -T "$tmp" "$dest" 2>/dev/null || rm -rf "$tmp" # another serve may have made it first
    [ -f "$dest/bin/senior-mode" ] || {
      echo "serve: cannot move the plugin snapshot to $dest" >&2
      return 1
    }
  fi
  printf '%s\n' "$dest"
}

# The start of `senior-mode serve` (the entry point calls it before the loop): runs from a snapshot of the plugin. Already
# in one (the daemon re-executed, or started from it), it copies nothing and executes nothing. Otherwise it copies, then
# replaces this process by the copy, with SENIOR_MODE_PLUGIN_DIR (the sessions' --plugin-dir) set. A snapshot that cannot be written stops serve.
serve_plugin_enter() {
  local common sd root snap
  common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 0
  sd=$common/senior-mode/serve
  root=$(cd "$(dirname "$SELF")/.." && pwd)
  if [[ $root == "$sd"/plugin/* ]]; then
    export SENIOR_MODE_PLUGIN_DIR=$root
    return 0
  fi
  snap=$(serve_plugin_snapshot "$root" "$sd") || die "serve does not start without a snapshot of the plugin"
  export SENIOR_MODE_PLUGIN_DIR=$snap
  exec "$snap/bin/senior-mode" serve
}

# A step of the loop, before the poll: records the running version in <serve dir>/version.
serve_step_05_plugin() {
  local root id
  root=$(cd "$(dirname "$SELF")/.." && pwd)
  [[ $root == "$SERVE_DIR"/plugin/* ]] || return 0
  id=${root##*/}
  [ "$(state_get "$SERVE_DIR/version" '.+')" = "$id" ] || state_put "$SERVE_DIR/version" "$id"
}
