#!/usr/bin/env bash
set -euo pipefail

runner_state=${OBS_RUNNER_STATE:?}
runner_name=${OBS_RUNNER_NAME:?}
runner_agent="$runner_state/agent"
runner_image_version=2.338.2-uv0.13.7-r2

install -d -o 1001 -g 1001 -m 0750 \
  "$runner_agent" "$runner_state/home" "$runner_state/_work" \
  "$runner_state/toolcache" "$runner_state/tools/bin"
if [[ ! -f "$runner_agent/.image-version" ]] || \
   [[ "$(cat "$runner_agent/.image-version")" != "$runner_image_version" ]]; then
  cp -a /opt/actions-runner/. "$runner_agent/"
  install -o 1001 -g 1001 -m 0755 /opt/runner-tools/uv /opt/runner-tools/uvx "$runner_state/tools/bin/"
  printf '%s\n' "$runner_image_version" > "$runner_agent/.image-version"
fi

# Match the host socket's GID; runuser initializes the runner's groups anew.
runner_socket_gid=$(stat -c %g /var/run/docker.sock)
runner_docker_group=$(getent group "$runner_socket_gid" | cut -d: -f1 || true)
if [[ -z "$runner_docker_group" ]]; then
  groupadd --gid "$runner_socket_gid" host-docker
  runner_docker_group=host-docker
fi
usermod -aG "$runner_docker_group" runner

export HOME="$runner_state/home"
export RUNNER_TOOL_CACHE="$runner_state/toolcache"
export PATH="$runner_state/tools/bin:$PATH"
export ACTIONS_RUNNER_HOOK_JOB_STARTED=/usr/local/bin/obs-runner-job-started
cd "$runner_agent"
if [[ ! -f .runner ]]; then
  if [[ ! -s /run/obs-runner-secrets/registration-token ]]; then
    echo 'Missing registration token; provision it on the host before starting the runner.' >&2
    exit 1
  fi
  # The official runner consumes this variable and erases it during config.
  # The token never enters argv, the image, the repository, or the Nix store.
  export ACTIONS_RUNNER_INPUT_TOKEN
  ACTIONS_RUNNER_INPUT_TOKEN=$(cat /run/obs-runner-secrets/registration-token)
  runuser --preserve-environment --user runner -- ./config.sh --unattended \
    --url https://github.com/obs-rust \
    --name "$runner_name" \
    --runnergroup Dell-NixOS \
    --labels nixos-host,obs-ubuntu-2604,dell-fsx3mn2 \
    --work "$runner_state/_work" \
    --disableupdate \
    --replace
  unset ACTIONS_RUNNER_INPUT_TOKEN
fi
exec runuser --preserve-environment --user runner -- ./run.sh
