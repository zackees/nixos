#!/usr/bin/env bash
set -euo pipefail

runner_state=${OBS_RUNNER_STATE:?}
runner_name=${OBS_RUNNER_NAME:?}
runner_agent="$runner_state/agent"
runner_image_version=2.338.2-uv0.13.7-full2604-r6

install -d -o 1001 -g 1001 -m 0750 \
  "$runner_agent" "$runner_state/_work" \
  "$runner_state/toolcache" "$runner_state/tools/bin"
if [[ ! -f "$runner_agent/.image-version" ]] || \
   [[ "$(cat "$runner_agent/.image-version")" != "$runner_image_version" ]]; then
  cp -a /opt/actions-runner/. "$runner_agent/"
  install -o 1001 -g 1001 -m 0755 /opt/runner-tools/uv /opt/runner-tools/uvx "$runner_state/tools/bin/"
  printf '%s\n' "$runner_image_version" > "$runner_agent/.image-version"
fi

# Match the host socket's GID; setpriv --init-groups reads the runner's groups anew.
runner_socket_gid=$(stat -c %g /var/run/docker.sock)
runner_docker_group=$(getent group "$runner_socket_gid" | cut -d: -f1 || true)
if [[ -z "$runner_docker_group" ]]; then
  groupadd --gid "$runner_socket_gid" host-docker
  runner_docker_group=host-docker
fi
usermod -aG "$runner_docker_group" runner

# Same HOME as GitHub-hosted runners and the base image passwd entry
# (/home/runner, where rustup/cargo/pipx are preinstalled); rustup refuses a
# HOME that differs from the passwd home.
export HOME=/home/runner
# Keep the base image RUNNER_TOOL_CACHE (/opt/hostedtoolcache, preinstalled).
export PATH="$runner_state/tools/bin:$PATH"
export ACTIONS_RUNNER_HOOK_JOB_STARTED=/usr/local/bin/obs-runner-job-started.sh
cd "$runner_agent"
# Jobs take PATH from .path (written once at registration); keep it equal to
# the image PATH so a base image change reaches jobs.
printf '%s\n' "$PATH" > .path
chown 1001:1001 .path
if [[ ! -f .runner ]]; then
  if [[ ! -s /run/obs-runner-secrets/registration-token ]]; then
    echo 'Missing registration token; provision it on the host before starting the runner.' >&2
    exit 1
  fi
  # The official runner consumes this variable and erases it during config.
  # The token never enters argv, the image, the repository, or the Nix store.
  export ACTIONS_RUNNER_INPUT_TOKEN
  ACTIONS_RUNNER_INPUT_TOKEN=$(cat /run/obs-runner-secrets/registration-token)
  setpriv --reuid=runner --regid=runner --init-groups -- ./config.sh --unattended \
    --url https://github.com/obs-rust \
    --name "$runner_name" \
    --runnergroup Dell-NixOS \
    --labels nixos-host,obs-ubuntu-2604,dell-fsx3mn2 \
    --work "$runner_state/_work" \
    --disableupdate \
    --replace
  unset ACTIONS_RUNNER_INPUT_TOKEN
fi
# setpriv execs in place (runuser stays as a parent), so run.sh is tini's
# direct child: docker stop's SIGTERM reaches run.sh, which sends INT to the
# listener so it deletes its GitHub session before exiting. run.sh only traps
# and forwards signals when RUNNER_MANUALLY_TRAP_SIG is set.
export RUNNER_MANUALLY_TRAP_SIG=1
exec setpriv --reuid=runner --regid=runner --init-groups -- ./run.sh
