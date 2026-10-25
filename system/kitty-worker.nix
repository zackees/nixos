{ pkgs, ... }:
let
  # Every module that runs INSIDE kitty, on its main thread -- the thread
  # that draws every terminal. check_kitty_side.py fails the build if any of
  # them touches the filesystem, /proc or a subprocess outside an `io-ok`
  # line; that work belongs in the worker. A new kitty-side module goes in
  # this list. (keys.py is not here: it runs as its own python3 overlay.)
  kittySide = [
    ../home/kitty/tab_bar.py
    ../home/kitty/window_title_bar.py
    ../home/kitty/paste.py
    ./kitty-resurrect/kitty_snapshot.py
    ./launch-origin/kitty_bridge.py
    ./kitty-worker/kitty_async.py
  ];
  kittyWorker = pkgs.runCommand "kitty-worker" { nativeBuildInputs = [ pkgs.python3 ]; } ''
    python3 -I ${./kitty-worker/check_kitty_side.py} ${pkgs.lib.concatStringsSep " " kittySide}
    install -Dm644 ${./kitty-worker/kitty_async.py} $out/share/kitty-worker/kitty_async.py
    install -Dm644 ${./kitty-worker/worker.py} $out/share/kitty-worker/worker.py
  '';
in {
  # kitty_async.py is loaded from here by home/kitty/tab_bar.py.
  environment.systemPackages = [ kittyWorker ];

  # The worker itself: kitty asks over a datagram socket and reads the reply
  # on a later tick, so a /proc read stuck on a busy process or a write
  # queued behind the ext4 journal stalls this, never a terminal. A dead
  # worker means stale labels and no image paste until it is back.
  systemd.user.services.kitty-worker = {
    description = "Blocking I/O on behalf of kitty's main thread";
    wantedBy = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    path = [ pkgs.uv pkgs.wl-clipboard pkgs.imagemagick ];
    serviceConfig = {
      ExecStart = "${pkgs.uv}/bin/uv run --quiet --python-preference only-managed --script ${kittyWorker}/share/kitty-worker/worker.py";
      Restart = "always";
      RestartSec = 1;
    };
  };
}
