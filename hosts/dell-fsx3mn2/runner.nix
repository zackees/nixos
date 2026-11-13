{ lib, pkgs, ... }:
let
  runnerImage = "localhost/obs-rust-runner:2.338.2-uv0.13.7-r2";
  # Parallel runner instances. Each gets its own state, work dir and
  # registration (name dell-fsx3mn2-<n>) under /var/lib/obs-runner/r<n> on
  # the NVMe root, so credentials survive reboots.
  instances = lib.range 1 6;
  docker = "${pkgs.docker}/bin/docker";
  mkInstance = n:
    let
      name = "obs-rust-runner-${toString n}";
      state = "/var/lib/obs-runner/r${toString n}";
    in
    lib.nameValuePair name {
      description = "obs-rust Ubuntu 26.04 GitHub Actions runner ${toString n}";
      wantedBy = [ "multi-user.target" ];
      after = [ "docker.service" "network-online.target" "obs-rust-runner-image.service" ];
      requires = [ "docker.service" "obs-rust-runner-image.service" ];
      wants = [ "network-online.target" ];
      unitConfig = {
        ConditionPathExists = [
          "|${state}/agent/.runner"
          "|/var/lib/obs-runner-secrets/registration-token"
        ];
        StartLimitIntervalSec = 300;
        StartLimitBurst = 3;
      };
      preStart = "${docker} rm --force ${name} >/dev/null 2>&1 || true";
      # Host and container see the workspace at the identical path, so local
      # `uses: ./...` actions and docker bind mounts from jobs resolve.
      serviceConfig = {
        ExecStart = "${docker} run --rm --init --name ${name} --shm-size=2g --env OBS_RUNNER_STATE=${state} --env OBS_RUNNER_NAME=dell-fsx3mn2-${toString n} --volume ${state}:${state} --volume /var/lib/obs-runner-secrets:/run/obs-runner-secrets:ro --volume /var/run/docker.sock:/var/run/docker.sock ${runnerImage}";
        ExecStop = "${docker} stop --time 30 ${name}";
        Restart = "on-failure";
        RestartSec = 10;
        TimeoutStartSec = 300;
        TimeoutStopSec = 60;
      };
    };
in
{
  users.groups.obs-runner.gid = 1001;
  users.users.obs-runner = {
    isSystemUser = true;
    uid = 1001;
    group = "obs-runner";
    home = "/var/lib/obs-runner/home";
  };
  systemd.tmpfiles.rules = [
    "d /var/lib/obs-runner 0750 obs-runner obs-runner -"
    "d /var/lib/obs-runner-secrets 0700 root root -"
  ] ++ map (n: "d /var/lib/obs-runner/r${toString n} 0750 obs-runner obs-runner -") instances;

  # Ubuntu matches obs-rust's apt-based CI while NixOS owns the host. Docker
  # socket access is privileged; use a selected-repository GitHub runner group.
  # The image is built once; every instance runs it.
  systemd.services = {
    obs-rust-runner-image = {
      description = "Build the obs-rust runner image";
      after = [ "docker.service" "network-online.target" ];
      requires = [ "docker.service" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${docker} build --tag ${runnerImage} ${./runner}";
        TimeoutStartSec = 1800;
      };
    };
  } // lib.listToAttrs (map mkInstance instances);
}
