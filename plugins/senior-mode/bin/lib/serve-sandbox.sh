# shellcheck shell=bash
# The hold of cause `sandbox` (#760) is not probed like the others: serve_probe knows no such cause. This step runs before the
# poll and decides again (sandbox_decide) whether the hold stands. When the runtime or the credential file is there, it lifts
# the hold with one `recovered` alert; else it keeps the hold (and its detail current) one more hour, so that the poll's own
# probe, which would read the environment as green, does not lift it. A hold for an image that does not build stays until
# `serve --resume`: building again at every poll is not a probe.
serve_step_05_sandbox() {
  local out detail
  [ "$(serve_held cause)" = sandbox ] || return 0
  out=$(serve_sandbox_decision)
  detail=$(serve_held detail)
  if [ "${out%% *}" != hold ] && [[ $detail != "image build"* ]]; then
    rm -f "$SERVE_DIR/held"
    echo "serve: the sandbox can run sessions again, launching again" >&2
    notify recovered "" "serve launches again: the container runtime and the model credential are there"
    project_post_update "senior-mode serve resumed: the sandbox can run sessions again." ON_TRACK >/dev/null 2>&1 || true
    return 0
  fi
  [ "${out%% *}" != hold ] || detail=${out#hold }
  state_update serve_hold_next "$(($(serve_now) + 3600))" "$detail" || true
}
