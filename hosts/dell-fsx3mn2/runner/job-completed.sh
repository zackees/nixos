#!/usr/bin/env bash
# ACTIONS_RUNNER_HOOK_JOB_COMPLETED: leave _work/_temp empty and _work owned
# by the job uid for the next job. The runner's own temp cleanup cannot delete
# root-owned files that sibling containers (docker via the host socket) wrote.
set -uo pipefail
work="${OBS_RUNNER_STATE:?}/_work"
if [[ -d "$work/_temp" ]]; then
  echo "job-completed: emptying $work/_temp"
  sudo -n find "$work/_temp" -mindepth 1 -delete
fi
sudo -n find "$work" -not -user "$(id -u)" -exec chown -h "$(id -u):$(id -g)" {} +
exit 0
