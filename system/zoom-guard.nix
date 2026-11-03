# zoom-guard: a settings profile ladder for Zoom, so a forced setting that
# breaks it steps down instead of wedging it in a crash/relaunch loop. The
# why and the thresholds are in zoom-guard/zoom_guard.py.
# Check: `zoom-guard status`; outcomes in `journalctl --user -u 'zoom-guard-watch-*'`.
# Black video with the camera on: `zoom-guard step-down`, restart Zoom.
{ pkgs }:

let
  src = pkgs.runCommand "zoom-guard-src" { } ''
    install -Dm644 ${./zoom-guard/zoom_guard.py} $out/zoom_guard.py
  '';
  # The state machine's tests run at build time with nixpkgs python (stdlib
  # only, and the build sandbox cannot fetch uv's); a failing test fails the
  # rebuild rather than the next meeting.
  tested = pkgs.runCommand "zoom-guard-tests" { } ''
    cp ${./zoom-guard/zoom_guard.py} zoom_guard.py
    cp ${./zoom-guard/test_zoom_guard.py} test_zoom_guard.py
    ${pkgs.python3}/bin/python3 test_zoom_guard.py > $out
  '';
in
pkgs.writeShellScriptBin "zoom-guard" ''
    # tests: ${tested}
    exec ${pkgs.uv}/bin/uv run --quiet --python-preference only-managed \
      --script ${src}/zoom_guard.py "$@"
''
