# Keep ordinary side-monitor windows visible across desktops. Kitty windows
# follow their own desktop assignments on every monitor.
{ ... }: {
  home-manager.users.niteris = {
    home.file.".local/share/kwin/scripts/aux-screens-sticky".source = ./aux-screens-sticky;
    home.file.".local/share/kwin/scripts/desktop-window-visit".source = ./desktop-window-visit;
    programs.plasma.configFile.kwinrc.Plugins.desktop-window-visitEnabled = true;
    programs.plasma.configFile.kwinrc.Plugins.aux-screens-stickyEnabled = true;
  };
}
