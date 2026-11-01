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
  talos-searchd = inputs.talos-bar.packages.${pkgs.stdenv.hostPlatform.system}.talos-searchd;
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
    # Default screen until one is picked from the bar's right-click menu
    # (saved in ~/.local/state/talos-bar/screen): the 4K, by connector name,
    # because Qt reports a side monitor as primary.
    environment.TALOS_BAR_SCREEN = "HDMI-A-1";
    serviceConfig = {
      ExecStart = "${talos-bar}/bin/talos-bar";
      Restart = "always";
      RestartSec = 3;
    };
  };

  # Meta+Space search (talos-bar docs/SEARCH.md): the daemon owns the hotkey
  # (XDG GlobalShortcuts portal through kernal-api), the app catalog and
  # launching; talos-bar draws the popup it asks for. Bound under the
  # `token_talos_search` kglobalaccel component, which KRunner no longer holds.
  systemd.user.services.talos-searchd = {
    description = "talos-bar search daemon (Meta+Space)";
    wantedBy = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    # Launched apps inherit this PATH, as from any desktop launcher.
    path = [ "/run/current-system/sw" ];
    serviceConfig = {
      # go/ links open in a new Brave window, as the KRunner go-runner did.
      ExecStart = "${talos-searchd}/bin/talos-searchd --hotkey Meta+Space --browser brave-browser.desktop";
      Restart = "always";
      RestartSec = 3;
    };
  };
  # KDE keeps a binding it has stored over the trigger the portal requests, so
  # pin Meta+Space here too (lands at the next login, like every shortcut).
  home-manager.users.niteris.programs.plasma.shortcuts.token_talos_search."talos-search" = "Meta+Space";
}
