{ pkgs, ... }:
let
  runnerImage = "localhost/obs-rust-runner:2.338.2-uv0.13.7";
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
  ];

  # Ubuntu matches obs-rust's apt-based CI while NixOS owns the host. Docker
  # socket access is privileged; use a selected-repository GitHub runner group.
  systemd.services.obs-rust-runner = {
    description = "obs-rust Ubuntu 26.04 GitHub Actions runner";
    wantedBy = [ "multi-user.target" ];
    after = [ "docker.service" "network-online.target" ];
    requires = [ "docker.service" ];
    wants = [ "network-online.target" ];
    unitConfig = {
      ConditionPathExists = [
        "|/var/lib/obs-runner/agent/.runner"
        "|/var/lib/obs-runner-secrets/registration-token"
      ];
      StartLimitIntervalSec = 300;
      StartLimitBurst = 3;
    };
    preStart = ''
      ${pkgs.docker}/bin/docker build --tag ${runnerImage} ${./runner}
    '';
    serviceConfig = {
      ExecStart = "${pkgs.docker}/bin/docker run --rm --init --name obs-rust-runner --shm-size=2g --volume /var/lib/obs-runner:/var/lib/obs-runner --volume /var/lib/obs-runner-secrets:/run/obs-runner-secrets:ro --volume /var/run/docker.sock:/var/run/docker.sock ${runnerImage}";
      ExecStop = "${pkgs.docker}/bin/docker stop --time 30 obs-rust-runner";
      Restart = "on-failure";
      RestartSec = 10;
      TimeoutStartSec = 1800;
      TimeoutStopSec = 60;
    };
  };
}
