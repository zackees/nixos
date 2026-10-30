# Talos Bar is centered at the top, with Plasma desktop controls to its right.
# The cross-platform Python/Qt bar docks on the primary screen through
# layer-shell and starts automatically with the graphical session.
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
  # systemd import. Restart=always, not on-failure: on 2026-10-30 the bar
  # exited 0 fifteen seconds into login (cause unconfirmed; likely Qt quitting
  # once its layer-shell surface went away as the session settled), and
  # on-failure left the top edge empty all day. StartLimit still stops a tight crash loop.
  systemd.user.services.talos-bar = {
    description = "talos-bar desktop bar";
    wantedBy = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    # Glue shells out like a desktop app would: tasks_cli runs git (with
    # gh's credential helper), the agenda opens KOrganizer via kioclient.
    path = [ "/run/current-system/sw" ];
    environment.TALOS_BAR_ALIGN = "center";
    # The 4K primary, by connector name: Qt reports a side monitor as primary.
    environment.TALOS_BAR_SCREEN = "HDMI-A-1";
    serviceConfig = {
      ExecStart = "${talos-bar}/bin/talos-bar";
      Restart = "always";
      RestartSec = 3;
    };
  };
}
