# Only the main 4K screen (HDMI-A-1) switches virtual desktops. KWin has no
# per-screen desktops, so this KWin script pins every window on the smaller
# auxiliary screens to all desktops, and unpins it when it moves back to the
# main screen. Installed and enabled declaratively so a rebuild restores it.
{ ... }: {
  home-manager.users.niteris = {
    home.file.".local/share/kwin/scripts/aux-screens-sticky".source = ./aux-screens-sticky;
    programs.plasma.configFile.kwinrc.Plugins.aux-screens-stickyEnabled = true;
  };
}
