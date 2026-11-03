# desktop-priority-guard: Zoom up, builds to SCHED_IDLE. See
# priority-guard/guard.py for the why; CLAUDE.md has the nice-19 trap.
# Check: `journalctl -u desktop-priority-guard` is quiet during a call, and
# `ps -L -o cls,ni,comm -p <a cc1plus pid>` says IDL.
{ pkgs, ... }:

let
  guard = pkgs.runCommand "priority-guard" { } ''
    install -Dm644 ${./priority-guard/guard.py} $out/share/priority-guard/guard.py
  '';
in
{
  systemd.services.desktop-priority-guard = {
    description = "Keep Zoom ahead of builds (Zoom nice -10, builds SCHED_IDLE)";
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.uv ];
    environment = {
      UV_CACHE_DIR = "/var/lib/desktop-priority-guard/uv-cache";
      UV_PYTHON_INSTALL_DIR = "/var/lib/desktop-priority-guard/python";
    };
    serviceConfig = {
      ExecStart = "${pkgs.uv}/bin/uv run --quiet --python-preference only-managed --script ${guard}/share/priority-guard/guard.py";
      StateDirectory = "desktop-priority-guard";
      Restart = "always";
      RestartSec = 5;
      # It has to get CPU on a saturated box to do its job.
      Nice = -15;
      CPUWeight = 1000;
    };
  };
}
