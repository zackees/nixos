{ pkgs, ... }:
# Meta+Space: a Spotlight-style popup (#40). It is KRunner -- already the
# best launcher here, with apps, files, windows and calculators -- floated
# mid-screen, plus go-runner/runner.py for go/* links and the tiling editor.
let
  goRunner = pkgs.runCommand "go-runner" { } ''
    install -Dm644 ${./go-runner/runner.py} $out/share/go-runner/runner.py
  '';
in {
  systemd.user.services.go-runner = {
    description = "KRunner plugin: go/* links and the tiling editor";
    wantedBy = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    path = [ pkgs.uv pkgs.brave pkgs.kdePackages.qttools ];
    serviceConfig = {
      ExecStart = "${pkgs.uv}/bin/uv run --quiet --python-preference only-managed --script ${goRunner}/share/go-runner/runner.py";
      Restart = "always";
      RestartSec = 2;
    };
  };

  home-manager.users.niteris = {
    home.file.".local/share/krunner/dbusplugins/go-runner.desktop".source = ./go-runner/go-runner.desktop;
    programs.plasma = {
      # Global shortcuts land at the next login, not at switch: KWin holds
      # them in memory (see the shortcuts.kwin trap in CLAUDE.md).
      # Meta+Space moved to talos-searchd (talos-bar.nix); KRunner keeps Alt+Space.
      shortcuts."services/org.kde.krunner.desktop"._launch = [ "Alt+Space" ];
      configFile.krunnerrc.General.FreeFloating = true;
    };
  };
}
