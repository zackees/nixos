# Chromium as the everyday, logged-in browser, with Chrome DevTools Protocol
# open on 127.0.0.1:9222 so Playwright (or the Hermes agent) can attach to
# the live session when AI help is wanted:
#
#   browser = playwright.chromium.connect_over_cdp("http://127.0.0.1:9222")
#   page = browser.contexts[0].pages[0]     # the tabs that are already open
#
# Two constraints shape this:
#
# - Chromium 136+ refuses --remote-debugging-port on its *default* profile
#   directory (the cookie-theft hardening), so this profile lives in its own
#   --user-data-dir. That is also what makes it one stable, logged-in
#   profile rather than a throwaway one.
# - The port is loopback-only, but anything running as this user can drive
#   the browser -- including its logged-in sessions. That is the point, and
#   also the cost; do not bind it to anything but 127.0.0.1.
#
# Only this wrapper is installed, not pkgs.chromium's own desktop entry: a
# second launcher without the flags would open a separate, unattachable
# browser that looks identical.
{ pkgs, ... }:

let
  chromium-cdp = pkgs.writeShellApplication {
    name = "chromium-cdp";
    text = ''
      exec ${pkgs.chromium}/bin/chromium \
        --user-data-dir="$HOME/.local/share/chromium-cdp" \
        --remote-debugging-port=9222 \
        --remote-debugging-address=127.0.0.1 \
        --remote-allow-origins=http://127.0.0.1:9222 \
        --ozone-platform-hint=auto \
        --no-first-run \
        "$@"
    '';
  };

  desktop = pkgs.makeDesktopItem {
    name = "chromium-cdp";
    desktopName = "Chromium";
    genericName = "Web Browser";
    comment = "Logged-in Chromium that Playwright can attach to on 127.0.0.1:9222";
    exec = "${chromium-cdp}/bin/chromium-cdp %U";
    # By path: pkgs.chromium is not in systemPackages, so its themed icon is
    # not installed, and an unresolved dock icon draws as blank space.
    icon = "${pkgs.chromium}/share/icons/hicolor/256x256/apps/chromium.png";
    # Chromium's Wayland app_id; KWin groups its windows under this launcher.
    startupWMClass = "chromium-browser";
    categories = [ "Network" "WebBrowser" ];
    mimeTypes = [ "text/html" "application/xhtml+xml" "x-scheme-handler/http" "x-scheme-handler/https" ];
    actions.new-window = {
      name = "New Window";
      exec = "${chromium-cdp}/bin/chromium-cdp --new-window";
    };
  };
in
{
  environment.systemPackages = [ chromium-cdp desktop ];
}
