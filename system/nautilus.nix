# Nautilus (GNOME Files) as the file manager AND as every app's Open/Save
# dialog.
#
# Why not Dolphin: the gap was never Dolphin. The Save dialog an app shows on
# Plasma is KIO's KFileWidget, a separate widget that only shares a library
# with Dolphin. Its file views are QListView::DragOnly, and the one drop it
# takes is a single file or folder onto the list, which only navigates there
# (kdiroperator.cpp, KIO 6.29); more than one item, or a drop on the Name
# field (KDE bug 502405), is refused, and nothing dropped is ever copied.
# No Plasma setting changes that, and swapping the file manager alone would
# not either, because the dialog is not the file manager.
#
# Windows (the common item dialog is an Explorer view), macOS (NSSavePanel
# is Finder-backed) and, since GNOME 47, GNOME all make the dialog the file
# manager itself. Nautilus 47+ implements org.freedesktop.impl.portal
# .FileChooser in its own process, so the picker is a real Nautilus window:
# drag out of it, drop into it, tabs, the sidebar. Omarchy used Nautilus the
# same way until replacing it with Folio, its own file manager, in Nov 2026;
# Folio is a week old, not battle-tested, and not packaged.
#
# GNOME routes this through xdg-desktop-portal-gnome, which needs a GNOME
# session for its other interfaces. We skip it: Nautilus exports the
# interface at /org/freedesktop/portal/desktop on its own bus name, so a
# .portal file pointing at org.gnome.Nautilus is enough.
#
# Scope: this reaches apps that ask the PORTAL for a dialog -- Chromium,
# Brave, Electron apps, Flatpaks. Qt/KDE apps (Kdenlive, Kate, ...) draw
# KFileWidget in-process through the Plasma platform theme and keep it.
# Dolphin stays installed (Plasma pulls it in) and still answers Meta+E.
{ pkgs, ... }:
let
  nautilusPortal = pkgs.writeTextDir "share/xdg-desktop-portal/portals/nautilus.portal" ''
    [portal]
    DBusName=org.gnome.Nautilus
    Interfaces=org.freedesktop.impl.portal.FileChooser;
  '';
in
{
  environment.systemPackages = [
    pkgs.nautilus
    # Space-bar quick look in Nautilus.
    pkgs.sushi
  ];

  # Trash, MTP phones, network shares and "Other Locations" in Nautilus all
  # go through GVfs; without it the sidebar's Trash is dead.
  services.gvfs.enable = true;
  # Nautilus keeps its settings (view mode, sort, sidebar) in dconf.
  programs.dconf.enable = true;

  xdg.portal.extraPortals = [ nautilusPortal ];

  # The whole routing for a Plasma session. This file in /etc/xdg overrides
  # the kde-portals.conf that xdg-desktop-portal-kde ships, so everything
  # that one routes has to be repeated here, not just the FileChooser line.
  # "kde" after "nautilus" is the fallback if the Nautilus portal file is
  # ever missing. A ~/.config/xdg-desktop-portal/portals.conf would shadow
  # all of this; there must not be one.
  xdg.portal.config.kde = {
    default = [ "kde" "gtk" ];
    "org.freedesktop.impl.portal.FileChooser" = [ "nautilus" "kde" ];
    "org.freedesktop.impl.portal.Settings" = [ "kde" "gtk" ];
    "org.freedesktop.impl.portal.Secret" = [ "kwallet" ];
    "org.freedesktop.impl.portal.Notification" = [ "plasmanotify" ];
  };

  # Opening a folder from anywhere (a browser's "Show in folder", xdg-open)
  # lands in Nautilus. /etc/xdg/mimeapps.list outranks the kde-mimeapps.list
  # Plasma ships in share/applications, which names Dolphin.
  xdg.mime.defaultApplications."inode/directory" = "org.gnome.Nautilus.desktop";
}
