# Zoom's windows open on DP-1, the lower-left side monitor, rather than the
# main 4K screen (asked for 2026-11-20). A KWin script rather than a window
# rule: ~/.config/kwinrulesrc holds hand-made rules (the bosn bubble), and a
# declared rules file would replace them wholesale. The aux-screens-sticky
# script then pins the window to all desktops, as it does for anything on a
# side screen. Matches on the window class, so it also catches a Zoom started
# from a browser link, not only the dock launcher.
{ ... }: {
  home-manager.users.niteris = {
    home.file.".local/share/kwin/scripts/zoom-screen".source = ./zoom-screen;
    programs.plasma.configFile.kwinrc.Plugins.zoom-screenEnabled = true;
  };
}
