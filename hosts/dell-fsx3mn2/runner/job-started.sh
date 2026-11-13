#!/usr/bin/env bash
# ACTIONS_RUNNER_HOOK_JOB_STARTED: start every job from an empty workspace.
# A persistent runner reuses _work/<repo>/<repo>; a sparse/partial checkout
# left by one job survives actions/checkout in the next (core.sparseCheckout
# stays set), hiding files such as .github/actions/* from later jobs.
set -euo pipefail
work="${OBS_RUNNER_STATE:?}/_work"
ws="${GITHUB_WORKSPACE:-}"
case "$ws" in
  "$work"/?*) ;;
  *) echo "job-started: workspace '$ws' not under $work; not cleaning"; exit 0 ;;
esac
if [[ -d "$ws" ]]; then
  echo "job-started: emptying $ws"
  sudo -n find "$ws" -mindepth 1 -delete
fi
