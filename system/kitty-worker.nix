{ pkgs, ... }:
let
  # running-process's service client, for kitty's side. worker.py pins the
  # same release in its PEP 723 block (uv fetches it there); kitty's python
  # imports running_process_service from this unpacked wheel instead, since
  # code inside kitty cannot run uv. Bump the two together.
  runningProcessVersion = "4.10.17";
  runningProcessWheel = pkgs.fetchurl {
    url = "https://files.pythonhosted.org/packages/b2/3b/5be52799f939c509ba5f56fbf3a14a9fd28eac09b92ad645b0e029ca769f/running_process-4.10.17-cp310-abi3-manylinux_2_28_x86_64.whl";
    hash = "sha256-9j6rROg3DfJkw449hGuSf8rrNbdkt0eKxDIp06YCzpU=";
  };
  runningProcessSite = pkgs.stdenv.mkDerivation {
    pname = "running-process-kitty-site";
    version = runningProcessVersion;
    src = runningProcessWheel;
    dontUnpack = true;
    nativeBuildInputs = [ pkgs.unzip pkgs.autoPatchelfHook ];
    buildInputs = [ pkgs.stdenv.cc.cc.lib ];  # libgcc_s for the extension
    installPhase = ''
      mkdir -p $out
      unzip -q $src -d $out
    '';
  };
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
    grep -q '"running-process==${runningProcessVersion}"' $out/share/kitty-worker/worker.py
    ln -s ${runningProcessSite} $out/share/kitty-worker/site
    # The kitty-side import must load the extension and nothing else.
    PYTHONPATH=${runningProcessSite} python3 -I -c "
    import sys; sys.path.insert(0, '${runningProcessSite}')
    import running_process_service
    assert 'running_process' not in sys.modules"
  '';
in {
  # kitty_async.py is loaded from here by home/kitty/tab_bar.py.
  environment.systemPackages = [ kittyWorker ];

  # The worker itself: kitty asks through running-process's non-blocking
  # service client and reads the reply on a later tick, so a /proc read
  # stuck on a busy process or a write queued behind the ext4 journal stalls
  # this, never a terminal. A dead
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
