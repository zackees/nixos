# talos-bar: the cross-platform Python/Qt bar that is replacing the Plasma
# top panel (~/dev/talos-hq/talos-bar). It runs side by side with that panel
# for now, docked top-right on the primary screen through layer-shell.
#
# Packaged by the talos-bar flake itself, not run through uv like the other
# Python here: it needs nixpkgs' PySide6/Qt and layer-shell-qt, and the PyPI
# PySide6 wheel does not load on NixOS.
{ pkgs, inputs, ... }:

let
  talos-bar = inputs.talos-bar.packages.${pkgs.stdenv.hostPlatform.system}.talos-bar;
in
{
  environment.systemPackages = [ talos-bar ];

  # Started with the Plasma session; Wayland env comes from the session's
  # systemd import. Restart covers a crash without looping on a bad config.
  systemd.user.services.talos-bar = {
    description = "talos-bar desktop bar";
    wantedBy = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    # Glue shells out like a desktop app would: tasks_cli runs git (with
    # gh's credential helper), the agenda opens KOrganizer via kioclient.
    path = [ "/run/current-system/sw" ];
    serviceConfig = {
      ExecStart = "${talos-bar}/bin/talos-bar";
      Restart = "on-failure";
      RestartSec = 3;
    };
  };
}
